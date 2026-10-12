#!/bin/bash
# Deterministic Axera codec init for the LVA satellite.
#
# Why this exists: the vendor image applies no usable mixer state, so a fresh
# boot leaves hardware ALC off and the DAC muted. With ALC off the onboard
# MSM421A signal never crosses microWakeWord's 0.85 cutoff for "okay nabu"
# (measured max 0.17-0.57); with it on the same audio scores 0.92-0.95. A muted
# DAC means no wake chime and no TTS, i.e. the satellite looks dead. Both are
# asserted here and verified, with retries, because the codec can be re-inited
# shortly after sound.target comes up.
#
# The retries alone are not enough - a late `alsactl restore` can still land
# after this script finishes, which is why setup-module.sh also removes
# /var/lib/alsa/asound.state, masks alsa-restore.service and shadows the
# 90-alsa-restore udev rule. See docs/bringup.md.
set -u
C=0

sset() { amixer -c "$C" sset "$1" "$2" >/dev/null 2>&1; }

get() { amixer -c "$C" sget "$1" 2>/dev/null | tail -1; }

apply() {
  # Input path: analog mic (the DMIC mux rails to 32768 and is unusable).
  sset "INPUT MUX" "FROM AMIC"
  sset "ADC MUTE" off
  sset "TX LR SWAP" off
  # Hardware ALC: the decisive control for wake-word level.
  sset "ALC ENABLE" on
  sset "ALC GAIN MAX" 140
  sset "ALC TARGET LEVEL" 18
  sset "ALC GATE THRESHOLD" 140
  sset "ALC RMS MAX" 20
  # Capture digital gain (the mic is physically on capture channel 1).
  sset "TX LEFT DIG GAIN" 15
  sset "TX RIGHT DIG GAIN" 15
  # Playback: unmute the DAC and set a sane digital gain, else no chime/TTS.
  sset "DAC MUTE" off
  sset "RX LEFT DIG GAIN" 30
  sset "RX RIGHT DIG GAIN" 30
}

# The card can appear after this unit is started, so wait for its control device
# before trying to talk to it.
for _ in $(seq 1 30); do
  [ -e /dev/snd/controlC$C ] && break
  sleep 1
done

# Apply, verify the two controls that actually matter, retry a few times.
ok=0
for attempt in $(seq 1 10); do
  apply
  sleep 1
  alc="$(get 'ALC ENABLE')"
  dac="$(get 'DAC MUTE')"
  case "$alc" in *"[on]"*) a=1;; *) a=0;; esac
  case "$dac" in *"[off]"*) d=1;; *) d=0;; esac
  if [ "$a" = 1 ] && [ "$d" = 1 ]; then
    ok=1; break
  fi
  echo "lva-audio-init: attempt $attempt not settled (ALC=$alc DAC=$dac)" >&2
  sleep 2
done

if [ "$ok" = 1 ]; then
  echo "lva-audio-init: ALC on and DAC unmuted"
else
  echo "lva-audio-init: FAILED to settle mixer after retries" >&2
  exit 1
fi
