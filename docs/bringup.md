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
arecord -D plughw:0,0 -f S16_LE -r 16000 -d 3 /tmp/t.wav && aplay /tmp/t.wav
```

The record-then-playback round trip is the audio gate. Do not continue until it works.

## 4. Verify the LEDs

```sh
ls /sys/class/leds/
# for each entry with a brightness file:
echo 100 > /sys/class/leds/<name>/brightness
```

Record the exact channel names. `led/led_status.py` auto-detects them, but the
first run must be checked by eye: run it with `--debug`, say "okay nabu" once
HA is wired up, and confirm the color follows the pipeline state.

## 5. Install from the PC

```sh
cd ~/ha-llm-satellite
MODULE_IP=192.168.1.X ./install.sh
```

The LVA build compiles on-device (2x Cortex-A53). Expect 10-20 minutes.

## 6. Wire into Home Assistant

1. Settings -> Devices & services -> Add Integration -> **ESPHome**.
2. "Set up another instance" -> `<MODULE_IP>:6053`.
3. Settings -> Voice assistants -> your assistant -> wake word "okay nabu" ->
   assign the new satellite.

## 7. Measure before tuning

- Wake-word false positives: 10 minutes of normal room conversation, count
  triggers via `journalctl -u linux-voice-assistant -f`.
- Wake-to-chime latency and end-of-speech-to-answer latency: time two runs,
  compare against the Voice PE in the same room.
- If mic volume is low, raise `MIC_AUTO_GAIN` in `/etc/default/lva` in steps
  of 5 and re-measure. Do not raise `MIC_VOLUME` past 1.0 (clipping).
