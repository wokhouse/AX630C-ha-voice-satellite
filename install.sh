#!/usr/bin/env bash
# Host-side bootstrap. Run from this directory.
#   MODULE_IP=192.168.1.X ./install.sh
set -euo pipefail

: "${MODULE_IP:?set MODULE_IP to the Module LLM address}"
MODULE_USER="${MODULE_USER:-root}"
DEST=/opt/ax630c-ha-voice-satellite

echo ">> copying repo to ${MODULE_USER}@${MODULE_IP}:${DEST}"
ssh "${MODULE_USER}@${MODULE_IP}" "mkdir -p ${DEST}"
rsync -a --exclude '.git' ./ "${MODULE_USER}@${MODULE_IP}:${DEST}/"

echo ">> running setup-module.sh on the module (this takes a while: build on 2x A53)"
ssh -t "${MODULE_USER}@${MODULE_IP}" "cd ${DEST} && bash setup-module.sh"

echo ">> done. In Home Assistant: Settings -> Devices & services -> ESPHome -> Set up another instance -> ${MODULE_IP}:6053"
