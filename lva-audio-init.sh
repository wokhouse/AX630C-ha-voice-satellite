#!/bin/bash
# Deterministic Axera codec init for the LVA satellite.
# The vendor image applies no mixer state, so every boot comes up with the
# hardware ALC OFF and capture TX digital gain at 15/120. With ALC off the
# onboard MSM421A signal lands far too low/noisy for microWakeWord
# (okay_nabu @ 0.85) -- measured ww=0.17-0.57. With ALC ON it reaches
# ww=0.92-0.95 and the wake word fires reliably.
set -u
C=0
sset() { amixer -c $C sset "$1" "$2" >/dev/null 2>&1 || echo "warn: unable to set $1=$2" >&2; }

# Input path: the analog mic (DMIC is unused and saturates).
sset "INPUT MUX" "FROM AMIC"
sset "ADC MUTE" off
sset "TX LR SWAP" off
# Hardware ALC: the decisive control for wake-word level.
sset "ALC ENABLE" on
sset "ALC GAIN MAX" 140
sset "ALC TARGET LEVEL" 18
sset "ALC GATE THRESHOLD" 140
sset "ALC RMS MAX" 20
# Capture digital gain (mic is physically on capture channel 1 = TX RIGHT).
sset "TX LEFT DIG GAIN" 15
sset "TX RIGHT DIG GAIN" 15
# Playback digital gain (leave analogue gains at their power-on values).
sset "RX LEFT DIG GAIN" 30
sset "RX RIGHT DIG GAIN" 30
sset "DAC MUTE" off
