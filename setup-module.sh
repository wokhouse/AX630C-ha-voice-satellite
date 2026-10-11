#!/usr/bin/env bash
# Runs ON the Module LLM (as root). Installs deps, builds LVA, installs units.
set -euo pipefail

DEST="$(cd "$(dirname "$0")" && pwd)"
LVA_DIR=/opt/linux-voice-assistant
SVC_USER=root  # module ships a single-user Ubuntu; revisit if a service user is added

echo ">> apt dependencies"
apt-get update
apt-get install -y \
  avahi-utils pulseaudio-utils alsa-utils \
  pipewire-bin pipewire-alsa pipewire-pulse \
  build-essential libmpv-dev libasound2-plugins \
  ca-certificates iproute2 procps git jq curl wget \
  python3-venv python3-dev python3-websockets rsync

echo ">> free memory: stop M5 stock AI services (they hold the 3GB NPU reservation)"
for s in llm-llm llm-asr llm-whisper llm-melotts llm-openai-api; do
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
# 2x A53 @1.2GHz: keep compilation cheap per upstream guidance
script/setup --cxxflags="-O1 -g0" --makeflags="-j1"

echo ">> install our config + units"
install -m 644 "$DEST/config/lva.env" /etc/default/lva
install -m 644 "$DEST/systemd/linux-voice-assistant.service" /etc/systemd/system/
install -m 644 "$DEST/systemd/lva-led-bridge.service" /etc/systemd/system/
install -d /opt/lva-led-bridge
install -m 755 "$DEST/led/led_status.py" /opt/lva-led-bridge/

systemctl daemon-reload
systemctl enable --now linux-voice-assistant.service
systemctl enable --now lva-led-bridge.service

echo ">> verify"
systemctl --no-pager status linux-voice-assistant.service lva-led-bridge.service | head -40
echo ">> audio devices:"
aplay -L | grep -E 'plughw|default' | head; arecord -L | grep -E 'plughw|default' | head
echo ">> LED devices:"
ls /sys/class/leds/ || echo "NO LEDS FOUND - check LP5562 driver"

echo ">> done. Satellite endpoint: $(hostname -I | awk '{print $1}'):6053"
