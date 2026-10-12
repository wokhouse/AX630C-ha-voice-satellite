# First bring-up of the Module LLM

Do this once, before `./install.sh`.

## 1. Power and console

- Slide the Module LLM's speaker aside and attach the FPC-8P cable to the LLM Mate.
- Ethernet to the LAN. 5 V supply (not a laptop USB port — idle 0.5 W, load 1.5 W).
- Console: Mate Type-C to the PC -> `/dev/ttyUSB0`, 115200 8N1.
  Login: `root` / `123456`.

```sh
picocom -b 115200 /dev/ttyUSB0   # or: python -m serial.tools.miniter /dev/ttyUSB0 115200
```

## 2. Change the password, get the IP

```sh
passwd
ip a      # note the eth0 address, e.g. 192.168.1.X
```

## 3. Verify audio (from the console or SSH)

```sh
arecord -L | grep plughw          # expect plughw:0,0 (MSM421A mic)
aplay -L  | grep plughw           # expect plughw:0,1 (AW8737 speaker)
arecord -D plughw:0,0 -f S32_LE -r 16000 -c 2 -d 3 /tmp/t.raw
```

Two hardware quirks to expect (both confirmed on the shipped image):

- **The mic is on capture channel 1, and channel 0 is dead silence.** Capture is
  fixed stereo S32_LE; `arecord -c 1` fails outright with `Channels count non
  available`. LVA therefore captures mono through PipeWire, which downmixes
  ch0+ch1, so the real signal arrives at roughly half amplitude.
- **`TX LR SWAP` does nothing on this codec.** It stays `off`; use
  `TX RIGHT DIG GAIN` to affect the mic.

## 4. Set the codec mixer state (REQUIRED for the wake word)

**The vendor image applies no mixer state at boot.** Out of the box the hardware
ALC is OFF, and microWakeWord's "okay nabu" never crosses its 0.85 cutoff on
this signal. Measured max probability, same stimulus and same mic:

| `ALC ENABLE` | max `okay nabu` probability |
|---|---|
| off (ship default) | 0.17 - 0.57 |
| on | 0.92 - 0.95 |

So ALC on is the difference between "never wakes" and "wakes reliably".
`setup-module.sh` installs `lva-audio-init.service`, a oneshot unit that applies
the known-good state before LVA starts. Verify it after install, and re-check
after any reboot:

```sh
for c in "INPUT MUX" "ALC ENABLE" "TX LEFT DIG GAIN" "TX RIGHT DIG GAIN"; do
  printf '%-20s ' "$c"; amixer -c 0 sget "$c" | tail -1
done
# expect: FROM AMIC / on / 15 / 15
```

If you ever need to reapply by hand: `/usr/local/sbin/lva-audio-init.sh`.

Note: capture TX digital gain (0-120) moves the level only a few dB across its
whole range and did not change wake-word scores; the hardware ALC is the lever.

## 5. Verify the LEDs

```sh
ls /sys/class/leds/
# for each entry with a brightness file:
echo 100 > /sys/class/leds/<name>/brightness
```

Record the exact channel names. `led/led_status.py` auto-detects them, but the
first run must be checked by eye: run it with `--debug`, say "okay nabu" once
HA is wired up, and confirm the color follows the pipeline state.

## 6. Install from the PC

```sh
cd ~/AX630C-ha-voice-satellite
MODULE_IP=192.168.1.X ./install.sh
```

The LVA build compiles on-device (2x Cortex-A53). Expect 10-20 minutes.

## 7. Wire into Home Assistant

1. Settings -> Devices & services -> Add Integration -> **ESPHome**.
2. "Set up another instance" -> `<MODULE_IP>:6053`.
3. Settings -> Voice assistants -> your assistant -> wake word "okay nabu" ->
   assign the new satellite.

**Do not rely on DHCP:** the module's lease can change across a power cycle
(observed .230 -> .100). HA's ESPHome entry stores the address, so a changed IP
silently disconnects the satellite. Give the module a DHCP reservation before
wiring it up, or expect to re-add the ESPHome instance after a reboot.

## 8. Measure before tuning

- Wake-word false positives: 10 minutes of normal room conversation, count
  triggers via `journalctl -u linux-voice-assistant -f`.
- Wake-to-chime latency and end-of-speech-to-answer latency: time two runs,
  compare against the Voice PE in the same room.

Wake-word detection only runs while Home Assistant is connected: LVA sets
`state.satellite` on connect and skips the whole wake-word block when it is
`None`. If `journalctl` shows `Opening audio input device` with no detections at
all, check the HA side first. `journalctl -u linux-voice-assistant | grep
'Connected to Home Assistant'` confirms the handshake.

Tuning notes, in order of usefulness:

1. `ALC ENABLE` on/off (`amixer -c 0 sset 'ALC ENABLE' on`) - by far the
   biggest lever.
2. `ALC TARGET LEVEL` / `ALC GAIN MAX` - small effect, tune by measurement.
3. `TX RIGHT DIG GAIN` - a few dB, mostly not worth it.
4. `MIC_AUTO_GAIN` / `MIC_NOISE_SUPPRESSION` in `/etc/default/lva` - the WebRTC
   extras sat within noise of each other (0.948 vs 0.942) and did not help.
