#!/usr/bin/env bash
# Runs ON the Module LLM (as root). Installs deps, builds LVA, installs units.
set -euo pipefail

DEST="$(cd "$(dirname "$0")" && pwd)"
LVA_DIR=/opt/linux-voice-assistant

# The address HA's ESPHome entry is pinned to. The vendor image's DHCP lease is
# not stable (observed .230 then .100 across a power cycle), so we keep a static
# secondary address on the interface and bind the satellite endpoint to it.
# If you have made a DHCP reservation on the router, set ALIAS_IP to that address
# (or leave NET_DEV/ALIAS_IP as they are and the units still work).
NET_DEV="${NET_DEV:-eth0}"
ALIAS_IP="${ALIAS_IP:-192.168.1.230}"

# Ethernet MAC to pin on NET_DEV. Leave empty to keep the MAC the box is
# already using (LVA derives its ESPHome node name from it, so do not invent
# one). See lva-net-mac.sh for why this is needed at all: the
# board has no MAC in hardware, so it changes every boot and a router-side
# reservation cannot hold. Set this to whatever you reserved in the router.
LVA_MAC="${LVA_MAC:-}"

echo ">> apt dependencies"
export DEBIAN_FRONTEND=noninteractive
# The vendor image ships /etc/apt/apt.conf.d/01proxy pointing at a now-dead
# 127.0.0.1:8888. With Ethernet attached the module has direct internet, so the
# proxy only breaks apt. Disable it (keeping a backup) if it is still active.
if [ -f /etc/apt/apt.conf.d/01proxy ] && grep -q '^Acquire' /etc/apt/apt.conf.d/01proxy; then
  cp -n /etc/apt/apt.conf.d/01proxy /etc/apt/apt.conf.d/01proxy.disabled-by-lva
  sed -i 's|^Acquire|// disabled by ax630c-ha-voice-satellite setup // Acquire|' /etc/apt/apt.conf.d/01proxy
fi
# git config on this image also points at the dead 127.0.0.1:8888 proxy.
for scope in --system --global; do
  if git config $scope --get http.proxy >/dev/null 2>&1; then
    git config $scope --unset http.proxy 2>/dev/null || true
    git config $scope --unset https.proxy 2>/dev/null || true
  fi
done
# pip carries the same dead proxy in /etc/pip.conf, which breaks venv installs.
if [ -f /etc/pip.conf ] && grep -q '127.0.0.1:8888' /etc/pip.conf; then
  cp -n /etc/pip.conf /etc/pip.conf.disabled-by-lva
  sed -i '/^proxy *=/d' /etc/pip.conf
fi
# --no-remove: this image's vendor llm-* stack is installed via apt, and a plain
# `install -y` resolves the new deps by REMOVING whatever it thinks conflicts
# (observed: it wants to drop llm-openai-api). Losing those packages breaks the
# stock AI services and the python3 module set the vendor image ships.
apt-get update
# NOTE: jammy has no pipewire-alsa package; the ALSA compatibility layer lives in
# pipewire-audio-client-libraries. LVA itself only needs a PulseAudio socket.
apt-get install -y --no-remove \
  avahi-utils pulseaudio-utils alsa-utils \
  pipewire pipewire-pulse wireplumber \
  pipewire-audio-client-libraries libpipewire-0.3-modules \
  build-essential libmpv-dev libasound2-plugins libasound2-dev \
  ca-certificates iproute2 procps git jq curl wget \
  python3-dev python3-websockets pkg-config rsync

echo ">> ensure Python 3.11+ (LVA requires >=3.11; jammy ships 3.10)"
if ! command -v python3.11 >/dev/null; then
  # jammy-updates carries only 3.11.0~rc1, which pip rejects for
  # requires-python>=3.11.0. Use deadsnakes, which has a real 3.11.17 for arm64.
  apt-get install -y --no-remove software-properties-common
  add-apt-repository -y ppa:deadsnakes/ppa
  apt-get update
  apt-get install -y --no-remove python3.11 python3.11-venv python3.11-dev
fi
PY311="$(command -v python3.11)"
echo ">> using $PY311 ($($PY311 --version 2>&1))"

echo ">> free memory: stop M5 stock AI services (they hold the 3GB NPU reservation)"
for s in llm-llm llm-asr llm-whisper llm-melotts llm-openai-api llm-audio llm-kws llm-tts llm-vlm llm-yolo llm-camera; do
  systemctl stop "$s" 2>/dev/null || true
  systemctl disable "$s" 2>/dev/null || true
done

echo ">> clone + build linux-voice-assistant (latest release tag)"
if [ ! -d "$LVA_DIR" ]; then
  git clone https://github.com/OHF-Voice/linux-voice-assistant.git "$LVA_DIR"
fi
cd "$LVA_DIR"
LVA_VERSION="$(curl -s https://api.github.com/repos/OHF-Voice/linux-voice-assistant/releases/latest | jq -r .tag_name)"
git fetch --tags
git checkout "$LVA_VERSION"
chmod +x docker-entrypoint.sh
# script/setup creates .venv with whichever 3.11+ it finds, so put python3.11
# first on PATH and point it at the interpreter explicitly.
# 2x A53 @1.2GHz: keep compilation cheap per upstream guidance
PATH="$(dirname "$PY311"):$PATH" script/setup --cxxflags="-O1 -g0" --makeflags="-j1"

# --------------------------------------------------------------- audio server
# LVA talks to a PulseAudio-compatible socket, not to ALSA directly. PipeWire
# runs as a *user* service, so on this headless root-only image it will not start
# unless lingering is enabled for root and the session bus exists. That matters:
# without it LVA silently loses audio the moment SSH disconnects.
echo ">> enable PipeWire user session for root (linger + 16 kHz clock)"
loginctl enable-linger root 2>/dev/null || mkdir -p /var/lib/systemd/linger && touch /var/lib/systemd/linger/root
mkdir -p /etc/pipewire/pipewire.conf.d
cat > /etc/pipewire/pipewire.conf.d/50-linux-voice-assistant.conf <<'PIPEWIRE'
context.properties = {
    default.clock.rate = 16000
}
PIPEWIRE

# Let ALSA applications reach the PulseAudio/PipeWire socket by default.
mkdir -p /etc/alsa/conf.d
if [ -f /usr/share/alsa/alsa.conf.d/50-pipewire.conf ] && [ ! -e /etc/alsa/conf.d/50-pipewire.conf ]; then
  ln -s /usr/share/alsa/alsa.conf.d/50-pipewire.conf /etc/alsa/conf.d/50-pipewire.conf
fi

# The vendor Axera codec ships no UCM/ACP profile, so ACP enumerates only 'off'
# and 'pro-audio' and the card sits permanently 'off' -- HAL then sees a dummy
# auto_null device and the microphone never opens. Even when 'pro-audio' is set
# by hand it is lost whenever the card is rebound. Disabling ACP makes WirePlumber
# expose the raw ALSA PCMs directly, which is deterministic across restarts.
#
# Two extra details matter: with ACP off the ALSA monitor defaults
# `audio.channels` to 64 for every node, and the codec already reports a bogus
# 64-channel TDM layout, so the stereo channel map ends up scrambled (channel 0
# reads as pure silence). Pin the channel count, and capture mono in lva.env.
mkdir -p /etc/wireplumber/main.lua.d
cat > /etc/wireplumber/main.lua.d/51-lva-codec.lua <<'WIREPLUMBER'
alsa_monitor.rules = alsa_monitor.rules or {}
table.insert(alsa_monitor.rules, {
  matches = {
    {
      { 'device.name', 'matches', 'alsa_card.platform-sound' },
    },
  },
  apply_properties = {
    ['api.alsa.use-acp'] = false,
    ['api.acp.auto-profile'] = false,
    ['audio.channels'] = 2,
    ['audio.format'] = 'S32LE',
  },
})

-- Axera I2S master PCM (playback) stalls its DMA on every hardware period when
-- the ALSA period equals PipeWire's quantum (1024 frames @ 16 kHz = 64 ms). The
-- dw_i2s driver then logs a START/STOP pair per period (visible in dmesg as
-- "dw_i2s_trigger"), and every restart is audible, so merely opening a sink
-- stream produces a continuous click/tick train -- most obvious right after the
-- wake chime, because that is the first time the stream is opened. Shrinking the
-- hardware period to 256 frames lets the 1024-frame quantum span four periods,
-- so the PCM is started once and runs continuously (verified: ~227 DMA triggers
-- for a 10 s tone before, 1 after).
table.insert(alsa_monitor.rules, {
  matches = { { { 'api.alsa.path', 'matches', 'hw:0,1' } } },
  apply_properties = { ['api.alsa.period-size'] = 256 },
})
WIREPLUMBER

# ------------------------------------------------------------ config + units
echo ">> install our config + units"
# HOST must match the address we bind the alias to (see the lva.env comment: LVA
# advertises whatever HOST is over mDNS), so rewrite it rather than shipping a
# site-specific literal.
install -m 644 "$DEST/config/lva.env" /etc/default/lva
sed -i "s|^HOST=.*|HOST=$ALIAS_IP|" /etc/default/lva
install -m 644 "$DEST/systemd/linux-voice-assistant.service" /etc/systemd/system/
install -m 644 "$DEST/systemd/lva-led-bridge.service" /etc/systemd/system/
install -d /opt/lva-led-bridge
install -m 755 "$DEST/led/led_status.py" /opt/lva-led-bridge/

# ------------------------------------------------------------------ codec init
# The vendor image applies NO mixer state at boot, so every power cycle comes up
# with hardware ALC OFF and capture TX digital gain at its low default. With ALC
# off the onboard MSM421A signal is too low/noisy for microWakeWord: measured
# max 'okay nabu' probability 0.17-0.57 against the model's 0.85 cutoff, i.e.
# the wake word never fires. With ALC ON the same audio scores 0.92-0.95 and
# detection is reliable. Apply the known-good state from a oneshot unit that
# runs before LVA, so it survives reboots instead of only manual `amixer` calls.
install -m 755 "$DEST/lva-audio-init.sh" /usr/local/sbin/lva-audio-init.sh
install -m 644 "$DEST/systemd/lva-audio-init.service" /etc/systemd/system/

# ...and the ALSA state save/restore that keeps undoing it.
#
# alsa-restore.service runs `alsactl restore` at boot and `alsactl store` at
# shutdown, and /lib/udev/rules.d/90-alsa-restore.rules runs `alsactl restore
# <card>` on every controlC* add. The stored state is whatever the codec was
# doing at the last shutdown; on this card that includes 'DAC MUTE' = true, i.e.
# no chime and no TTS. After=alsa-restore.service does not save us: the card is
# probed late and the udev restore can land after lva-audio-init has already
# applied and verified its settings. So remove the state, stop it being written
# again, and shadow the udev rule. LVA's own init is then the only writer.
install -m 644 "$DEST/config/udev-rules.d/90-alsa-restore.rules" /etc/udev/rules.d/90-alsa-restore.rules
rm -f /var/lib/alsa/asound.state
systemctl mask alsa-restore.service

# ------------------------------------------------------------- ethernet MAC
# The board has no MAC in hardware (ethtool -P is 00:00:00:00:00:00, the DT has
# no local-mac-address, U-Boot has no ethaddr), so the driver invents a random
# one every boot and a router-side reservation cannot hold. Pin one from a unit
# ordered before ifupdown - see lva-net-mac.sh for why a udev rule does not work
# here (the kernel refuses the write while the interface is IFF_UP).
#
# Default to the MAC the box is using right now rather than inventing a new one:
# LVA derives its ESPHome node name from the MAC, so a new MAC means a new node
# name and Home Assistant sees a different device.
ETH_MAC="${LVA_MAC:-$(cat "/sys/class/net/$NET_DEV/address")}"
echo ">> will pin the ethernet MAC to $ETH_MAC on every boot"

# ------------------------------------------------------------------ addressing
# Keep  <ALIAS_IP>present. A `post-up ip addr add` in /etc/network/interfaces
# is not enough: dhclient rebinds without ifup (observed ~80 s after boot, when
# NTP stepped the clock) and dhclient-script flushes the interface's addresses,
# which takes the unlabelled secondary with it. Re-assert from a dhclient exit
# hook plus a slow timer, and drop the now-misleading post-up hook.
echo ">> install the stable-address units"
printf 'NET_DEV=%s\nLVA_ALIAS_IP=%s\nLVA_ETHERNET_MAC=%s\n' "$NET_DEV" "$ALIAS_IP" "$ETH_MAC" > /etc/default/lva-net-alias
install -m 755 "$DEST/lva-net-mac.sh" /usr/local/sbin/lva-net-mac.sh
install -m 644 "$DEST/systemd/lva-net-mac.service" /etc/systemd/system/
install -m 755 "$DEST/lva-net-alias.sh" /usr/local/sbin/lva-net-alias.sh
install -m 644 "$DEST/systemd/lva-net-alias.service" /etc/systemd/system/
install -m 644 "$DEST/systemd/lva-net-alias.timer" /etc/systemd/system/
install -d /etc/dhcp/dhclient-exit-hooks.d
install -m 644 "$DEST/config/dhclient-exit-hooks.d/lva-net-alias" /etc/dhcp/dhclient-exit-hooks.d/lva-net-alias
if [ -f /etc/network/interfaces ] && grep -q "$ALIAS_IP" /etc/network/interfaces; then
  echo ">> removing the superseded post-up alias hook from /etc/network/interfaces"
  # Exactly what an earlier revision of this repo wrote there.
  sed -i -e "/ip addr \(add\|del\) $ALIAS_IP/d" \
         -e "/# Keep a second, stable address at/d" \
         -e "/# pinned to it and the module DHCP lease is not guaranteed/d" \
         /etc/network/interfaces
fi

# Start PipeWire + WirePlumber + pipewire-pulse in root's user session and verify
# the socket appears before starting LVA (its entrypoint waits up to 30 s).
#
# Ubuntu's PipeWire user units ship `ConditionUser=!root`, so they refuse to run
# for root -- which is the only user on this image. Override that condition, then
# point the defaults at the nodes exposed by the ACP-bypass rule above.
if command -v pipewire >/dev/null; then
  for u in pipewire pipewire-pulse wireplumber; do
    mkdir -p "/etc/systemd/user/${u}.service.d"
    printf '[Unit]\nConditionUser=\n' > "/etc/systemd/user/${u}.service.d/override.conf"
  done
  su -s /bin/bash root -c 'XDG_RUNTIME_DIR=/run/user/0 systemctl --user daemon-reload' 2>/dev/null || true
  su -s /bin/bash root -c 'XDG_RUNTIME_DIR=/run/user/0 systemctl --user enable --now pipewire pipewire-pulse wireplumber' 2>/dev/null \
    || XDG_RUNTIME_DIR=/run/user/0 systemctl --user enable --now pipewire.socket pipewire-pulse.socket wireplumber 2>/dev/null || true
  for _ in $(seq 1 20); do
    [ -S /run/user/0/pulse/native ] && break
    sleep 1
  done
  if [ -S /run/user/0/pulse/native ]; then
    echo ">> pulse socket ready: /run/user/0/pulse/native"
    # Drop any state saved while the card was stuck on the useless ACP
    # 'pro-audio' profile, then let WirePlumber re-enumerate with ACP off.
    rm -f /root/.local/state/wireplumber/default-profile
    XDG_RUNTIME_DIR=/run/user/0 systemctl --user restart wireplumber 2>/dev/null || true
    for _ in $(seq 1 20); do
      XDG_RUNTIME_DIR=/run/user/0 pactl list sources short 2>/dev/null | grep -q 'capture\.0\.0' && break
      sleep 1
    done
    SINK="$(XDG_RUNTIME_DIR=/run/user/0 pactl list sinks short 2>/dev/null | awk '$2 ~ /playback\.1\.0$/ {print $2; exit}')"
    SRCE="$(XDG_RUNTIME_DIR=/run/user/0 pactl list sources short 2>/dev/null | awk '$2 ~ /capture\.0\.0$/ {print $2; exit}')"
    [ -n "$SINK" ] && XDG_RUNTIME_DIR=/run/user/0 pactl set-default-sink "$SINK" 2>/dev/null || true
    [ -n "$SRCE" ] && XDG_RUNTIME_DIR=/run/user/0 pactl set-default-source "$SRCE" 2>/dev/null || true
    echo ">> audio sink=$SINK source=$SRCE"
  else
    echo ">> WARNING: no /run/user/0/pulse/native; LVA may fail to open audio" >&2
  fi
fi

systemctl daemon-reload
systemctl daemon-reexec 2>/dev/null || true
systemctl enable --now lva-audio-init.service
# The MAC unit must be enabled (not started now): it only matters before
# ifupdown runs, i.e. on the next boot. Starting it here would take eth0 down
# and drop this SSH session.
systemctl enable lva-net-mac.service
systemctl enable --now lva-net-alias.service lva-net-alias.timer
/usr/local/sbin/lva-net-alias.sh --nowait || true
systemctl enable --now linux-voice-assistant.service
systemctl enable --now lva-led-bridge.service

# udev rules are read by the running manager, so hand it the new file.
udevadm control --reload-rules 2>/dev/null || true

echo ">> verify"
systemctl --no-pager status lva-audio-init.service lva-net-alias.service linux-voice-assistant.service lva-led-bridge.service | head -40
echo ">> codec state:"
for c in "INPUT MUX" "ALC ENABLE" "DAC MUTE" "TX LEFT DIG GAIN" "TX RIGHT DIG GAIN"; do
  printf '   %-20s ' "$c"; amixer -c 0 sget "$c" 2>/dev/null | tail -1
done
echo ">> alsactl must not be able to undo the above:"
systemctl is-enabled alsa-restore.service; ls -l /var/lib/alsa/asound.state 2>&1 | head -1
echo ">> addresses on $NET_DEV (expect $ALIAS_IP present):"
ip -4 addr show "$NET_DEV"
echo ">> MAC on $NET_DEV is $(cat /sys/class/net/$NET_DEV/address);"
echo "   $ETH_MAC is pinned on every boot from the next boot onwards (a running"
echo "   interface refuses a MAC change, which is why this needs a boot-time unit):"
systemctl is-enabled lva-net-mac.service
echo ">> audio devices:"
aplay -L | grep -E 'plughw|default' | head; arecord -L | grep -E 'plughw|default' | head
echo ">> LED devices:"
ls /sys/class/leds/ || echo "NO LEDS FOUND - check LP5562 driver"

echo ">> done. Satellite endpoint: $ALIAS_IP:6053"
echo ">> Reserve this MAC in your router if you want a stable lease: $ETH_MAC"
echo "   (the board has no MAC in hardware, so until the pinning unit runs on the"
echo "    next boot the address can be random - that is why a reservation never"
echo "    matched before)"
