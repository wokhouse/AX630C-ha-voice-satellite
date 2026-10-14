#!/bin/bash
# Keep a stable secondary address on the module's Ethernet interface, so the
# address HA's ESPHome entry is pinned to survives a reboot.
#
# Why this needs more than an ifupdown `post-up ip addr add`: the vendor image
# has no DHCP reservation and the lease moves across power cycles, and anything
# that re-runs the DHCP state machine wipes secondary addresses off the
# interface. Observed on a boot: ~80 s in, NTP stepped the clock, dhclient
# restarted its binding, dhclient-script flushed eth0's IPv4 addresses, and
# avahi logged "Withdrawing address record for the alias" - the alias was gone
# for the rest of the uptime and HA could never reach the satellite. ifplugd
# then only says "interface eth0 already configured", so ifup's post-up hooks
# never run again. So: re-assert from a dhclient exit hook (covers every
# rebind) and from a systemd timer (covers anything else).
set -u

# Single source of truth for the address, shared with the systemd unit and the
# dhclient exit hook (which is sourced by dhclient-script and so cannot read an
# EnvironmentFile itself).
[ -r /etc/default/lva-net-alias ] && . /etc/default/lva-net-alias

DEV="${NET_DEV:-eth0}"
# No fallback literal: setup-module.sh always writes the address into the
# config file above, and a site-specific default here would be wrong for
# everyone else.
ADDR="${LVA_ALIAS_IP:?LVA_ALIAS_IP is not set in /etc/default/lva-net-alias}/24"

# When called from a dhclient exit hook the interface is already up, and waiting
# there would stall the DHCP state machine.
nowait=0
[ "${1:-}" = "--nowait" ] && nowait=1

if [ "$nowait" = 0 ]; then
  for _ in $(seq 1 60); do
    ip link show "$DEV" 2>/dev/null | grep -q "state UP" && break
    sleep 1
  done
fi

if ip -4 addr show dev "$DEV" | grep -q "inet ${ADDR%/*}/"; then
  echo "lva-net-alias: alias $ADDR already present on $DEV"
  exit 0
fi

if ip addr add "$ADDR" dev "$DEV" 2>/dev/null; then
  echo "lva-net-alias: alias $ADDR added on $DEV"
  exit 0
fi

echo "lva-net-alias: could not add $ADDR on $DEV (interface down?)" >&2
exit 1
