#!/usr/bin/env bash
# Runs ON the Module LLM (as root). Installs deps, builds LVA, installs units.
set -euo pipefail

DEST="$(cd "$(dirname "$0")" && pwd)"
LVA_DIR=/opt/linux-voice-assistant
SVC_USER=root  # module ships a single-user Ubuntu; revisit if a service user is added

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

echo ">> clone + build linux-voice-assistant (pinned tag)"
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
install -m 644 "$DEST/config/lva.env" /etc/default/lva
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
  for i in $(seq 1 20); do
    [ -S /run/user/0/pulse/native ] && break
    sleep 1
  done
  if [ -S /run/user/0/pulse/native ]; then
    echo ">> pulse socket ready: /run/user/0/pulse/native"
    # Drop any state saved while the card was stuck on the useless ACP
    # 'pro-audio' profile, then let WirePlumber re-enumerate with ACP off.
    rm -f /root/.local/state/wireplumber/default-profile
    XDG_RUNTIME_DIR=/run/user/0 systemctl --user restart wireplumber 2>/dev/null || true
    for i in $(seq 1 20); do
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
systemctl enable --now lva-audio-init.service
systemctl enable --now linux-voice-assistant.service
systemctl enable --now lva-led-bridge.service

echo ">> verify"
systemctl --no-pager status lva-audio-init.service linux-voice-assistant.service lva-led-bridge.service | head -40
echo ">> codec state:"
for c in "INPUT MUX" "ALC ENABLE" "TX LEFT DIG GAIN" "TX RIGHT DIG GAIN"; do
  printf '   %-20s ' "$c"; amixer -c 0 sget "$c" 2>/dev/null | tail -1
done
echo ">> audio devices:"
aplay -L | grep -E 'plughw|default' | head; arecord -L | grep -E 'plughw|default' | head
echo ">> LED devices:"
ls /sys/class/leds/ || echo "NO LEDS FOUND - check LP5562 driver"

echo ">> done. Satellite endpoint: $(hostname -I | awk '{print $1}'):6053"
