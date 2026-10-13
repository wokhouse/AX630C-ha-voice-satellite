#!/usr/bin/env bash
# Host-side bootstrap. Run from this directory.
#   MODULE_IP=192.168.1.X ./install.sh
#
# The vendor image's root login wants a specific key, and plain `ssh root@...`
# fails with "Operation not permitted". Pass it through:
#   MODULE_IP=192.168.1.X SSH_OPTS="-i ~/.ssh/id_ed25519_m5llm" ./install.sh
#
# ALIAS_IP (default: last octet 230 on the subnet of MODULE_IP) is the stable
# address the satellite is bound to and the address to give Home Assistant;
# see docs/bringup.md section 10.
#
# LVA_MAC (default: the MAC the box is already using) is the MAC pinned on the
# interface. The board has no MAC in hardware, so it is random every boot until
# this is pinned; set it to whatever you reserved in your router.
set -euo pipefail

: "${MODULE_IP:?set MODULE_IP to the Module LLM address}"
MODULE_USER="${MODULE_USER:-root}"
SSH_OPTS="${SSH_OPTS:-}"
# Passed through to setup-module.sh, which pins this address to the interface and
# binds the satellite endpoint to it. Home Assistant's ESPHome entry must use
# THIS address, not MODULE_IP - MODULE_IP is only how you reach the box once.
# Derived from MODULE_IP so the final hint below names the real address;
# setup-module.sh derives it from the interface's lease when run without it.
NET_DEV="${NET_DEV:-eth0}"
ALIAS_LAST_OCTET="${ALIAS_LAST_OCTET:-230}"
ALIAS_IP="${ALIAS_IP:-${MODULE_IP%.*}.${ALIAS_LAST_OCTET}}"
LVA_MAC="${LVA_MAC:-}"
export NET_DEV ALIAS_IP LVA_MAC
DEST=/opt/ax630c-ha-voice-satellite
# shellcheck disable=SC2086
module_ssh() { ssh $SSH_OPTS "$MODULE_USER@$MODULE_IP" "$@"; }

echo ">> copying repo to ${MODULE_USER}@${MODULE_IP}:${DEST}"
module_ssh "mkdir -p ${DEST}"
# shellcheck disable=SC2086
rsync -a --exclude '.git' -e "ssh $SSH_OPTS" ./ "${MODULE_USER}@${MODULE_IP}:${DEST}/"

echo ">> running setup-module.sh on the module (this takes a while: build on 2x A53)"
# shellcheck disable=SC2086
ssh -t $SSH_OPTS "$MODULE_USER@$MODULE_IP" "cd ${DEST} && bash setup-module.sh"

echo ">> done. In Home Assistant: Settings -> Devices & services -> ESPHome -> Set up another instance -> ${ALIAS_IP}:6053"
