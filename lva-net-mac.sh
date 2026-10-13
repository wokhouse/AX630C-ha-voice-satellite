#!/bin/sh
# Pin a stable MAC on the ethernet interface, BEFORE ifupdown/dhclient run.
#
# Why this exists at all: the Axera EMAC has no MAC programmed anywhere.
#   ethtool -P eth0                              -> Permanent address: 00:00:00:00:00:00
#   /proc/device-tree/soc/ethernet@104C0000/     -> no local-mac-address property
#   fw_printenv                                  -> no ethaddr
# so the driver falls back to random_ether_addr() at probe and hands out a fresh
# locally-administered MAC on every boot. Observed probe MACs across four boots:
#   <random-mac-1>  <random-mac-2>  <random-mac-3>  <random-mac-4>
#
# systemd's /lib/systemd/network/99-default.link (MACAddressPolicy=persistent)
# does compute a stable MAC from /etc/machine-id, and it usually wins - but it
# loses the race against ifupdown sometimes. From the journal, the MAC that
# dhclient actually put on the wire:
#   boot -3  Listening on LPF/eth0/<random-mac-1>    <- random, reservation missed
#   boot -2  Listening on LPF/eth0/<random-mac-2>    <- random, reservation missed
#   boot -1  Listening on LPF/eth0/<PINNED_MAC>      <- persistent, hit
#   boot  0  Listening on LPF/eth0/<PINNED_MAC>      <- persistent, hit
# That is the whole reason a router-side reservation "keeps not holding": the
# router sees a different client most of the time.
#
# A udev rule is the obvious place, and it does not work here: writing
# ATTR{address} fails with EACCES because the kernel refuses while the interface
# is IFF_UP, and something has already brought eth0 up by the time udev gets the
# add event. So do it from a unit that is explicitly ordered before the units
# that configure the interface, when nothing has had the chance to bring it up.
#
# The MAC to pin is in /etc/default/lva-net-alias as LVA_ETHERNET_MAC. Pin the
# address the box already uses (setup-module.sh records it) rather than inventing
# a new one: LVA derives its ESPHome node name from the MAC
# (device_name = f"lva-{mac_without_colons}" in __main__.py), so a new MAC means
# a new node name and Home Assistant sees a different device.
set -eu

CONF=/etc/default/lva-net-alias
# shellcheck source=/dev/null
[ -r "$CONF" ] && . "$CONF"

NET_DEV="${NET_DEV:-eth0}"
MAC="${LVA_ETHERNET_MAC:-}"

if [ -z "$MAC" ]; then
  echo "lva-net-mac: LVA_ETHERNET_MAC not set in $CONF, nothing to pin" >&2
  exit 0
fi

current="$(cat "/sys/class/net/$NET_DEV/address" 2>/dev/null || true)"
if [ "$current" = "$MAC" ]; then
  echo "lva-net-mac: $NET_DEV already $MAC"
  exit 0
fi

# A running interface refuses a MAC change (EACCES), so take it down first. At
# boot nothing has brought it up yet and the down is a no-op.
ip link set "$NET_DEV" down 2>/dev/null || true
ip link set "$NET_DEV" address "$MAC"
ip link set "$NET_DEV" up
echo "lva-net-mac: $NET_DEV $current -> $MAC"
