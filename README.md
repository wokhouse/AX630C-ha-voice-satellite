# AX630C-ha-voice-satellite

Home Assistant voice satellite firmware layer for the **M5Stack Module LLM** (AX630C) + **LLM Mate** (Ethernet).

Turns the Module LLM into an `assist_satellite` device in Home Assistant, matching the Voice Preview Edition feature set as closely as the hardware allows.

## Architecture

```
Module LLM (Ubuntu, aarch64)                     Home Assistant (192.168.1.116)
+-------------------------------------------+    +--------------------------+
| linux-voice-assistant (OHF-Voice)         |--ESPHome protocol (TCP 6053)->| ESPHome integration |
|  - on-device wake word: okay_nabu         |    |  - Assist pipeline       |
|    (openWakeWord, .tflite)                |    |  - STT / LLM / TTS       |
|  - PipeWire -> ALSA card0 (mic/speaker)   |<---|  - wake word = "okay     |
|  - peripheral WebSocket API :6055         |    |    nabu" in pipeline     |
| led/led_status.py --WS client-------------+    +--------------------------+
|  - writes /sys/class/leds (LP5562)        |
+-------------------------------------------+
```

- All intelligence (STT/LLM/TTS) runs in HA. The module does wake word, audio I/O, and LED state only.
- HA discovers the satellite through the **existing ESPHome integration** — no Wyoming entries, no new HA integration.

## Feature parity vs Voice PE

| Feature | Status |
|---|---|
| On-device wake word ("okay nabu") | yes — openWakeWord, bundled model |
| Streaming audio to HA pipeline | yes — ESPHome protocol |
| Announcements / timers / continue-conversation | yes — LVA built-in |
| LED status indicator | yes — LP5562 via peripheral API (this repo) |
| Wake chime / processing sound | yes — LVA built-in sounds |
| Barge-in (AEC) | no — single omni mic, no echo cancellation |
| Far-field pickup | worse than PE — one MSM421A mic, no array |

## Prerequisites

- Module LLM flashed with M5's stock Ubuntu image (any current image; no re-flash needed — this is a software layer, not an OS image).
- LLM Mate attached: Ethernet cable + 5 V supply (not a laptop USB port).
- SSH reachable from the machine running `install.sh`.

## Install

From this repo on your PC:

```sh
# 1. discover the module (serial console: `ip a`), then:
MODULE_IP=192.168.1.X ./install.sh

# with a dedicated key (this is what the module's root login uses here):
MODULE_IP=192.168.1.X SSH_OPTS="-i ~/.ssh/id_ed25519_m5llm" ./install.sh
```

`install.sh` rsyncs this repo to the module and runs `setup-module.sh` there. Setup installs apt deps, clones and builds linux-voice-assistant, pins audio to the onboard card, pins a stable secondary address (`192.168.1.230`) to `eth0`, installs the systemd units, and enables them.

Then in Home Assistant: **Settings → Devices & services → ESPHome → Set up another instance**, enter `192.168.1.230:6053` — the alias, not the DHCP lease. The satellite appears as a device. Select "okay nabu" as the wake word in your voice assistant settings.

## Verify it without Home Assistant

Wake-word detection only runs while *some* client is connected, so a module with
nothing attached looks dead. `tools/ha-test-client.py` is a real `aioesphomeapi`
client that arms detection, prints the wake event, and drives the rest of the
pipeline with synthetic HA events:

```sh
# install.sh already put tools/ on the module; /tmp is wiped on reboot, this is not
ssh -i ~/.ssh/id_ed25519_m5llm root@ <ALIAS_IP>\
  '/opt/linux-voice-assistant/.venv/bin/python /opt/ax630c-ha-voice-satellite/tools/ha-test-client.py --drive'
# then, from a second shell, say "okay nabu" — or play the committed stimulus:
#   XDG_RUNTIME_DIR=/run/user/0 paplay --device=alsa_output.platform-sound.playback.1.0 \
#     /opt/ax630c-ha-voice-satellite/tools/okay-nabu.wav
```

Wait for the client's `subscribed` line before making a sound — detection is armed
by the subscription, and the first connection after a boot takes ~10 s.

Expected output, and the rest of the bring-up sequence, is in
[`docs/bringup.md`](docs/bringup.md).

## LED states

`led/led_status.py` subscribes to LVA's peripheral WebSocket API and drives the three RGB LEDs (LP5562, `/sys/class/leds`):

| State | Color |
|---|---|
| idle | off |
| listening | cyan |
| thinking | yellow |
| speaking | green |
| pipeline error | red, 3 blinks |
| disconnected from HA | red steady |

## Layout

- `install.sh` — host-side: rsync + ssh bootstrap
- `setup-module.sh` — module-side: deps, LVA build, systemd units, mixer state, stable address
- `lva-audio-init.sh` — codec state at boot (hardware ALC on, DAC unmuted, mic gain), verified by readback
- `lva-net-alias.sh` — idempotently pins `192.168.1.230` to `eth0`
- `config/lva.env` — environment for the LVA service (wake model, audio devices, bind address)
- `config/dhclient-exit-hooks.d/lva-net-alias` — re-pin the alias on every DHCP state change
- `config/udev-rules.d/90-alsa-restore.rules` — empty file that shadows the vendor ALSA state restorer
- `systemd/linux-voice-assistant.service`, `systemd/lva-led-bridge.service`,
  `systemd/lva-audio-init.service`, `systemd/lva-net-alias.service`, `systemd/lva-net-alias.timer`
- `led/led_status.py` — peripheral API → LP5562 sysfs bridge
- `tools/ha-test-client.py` — real `aioesphomeapi` client: proves the pipeline without HA
- `tools/okay-nabu.wav` — fixed "okay nabu" stimulus (16 kHz mono) for that test
- `docs/bringup.md` — first bring-up over serial console, and everything measured since

## Verified on this hardware

- LED channels are `/sys/class/leds/{R,G,B}` — auto-detection finds them.
- Capture is `hw:0,0` (PipeWire `alsa_input.platform-sound.capture.0.0`), playback
  `hw:0,1` (`alsa_output.platform-sound.playback.1.0`). The mic is on capture
  channel 1; channel 0 is silent.
- The stock image ships PipeWire/WirePlumber, but its units carry
  `ConditionUser=!root` and root is the only user — `setup-module.sh` overrides that.
- Wake word works after a real reboot: `Okay Nabu` at probability 0.87–0.91 across
  runs (threshold 0.850), chime audible, LED state machine correct, one I2S DMA
  start/stop for the whole interaction.
- `192.168.1.230` survives boot and DHCP rebinds; mDNS advertises it on :6053.

## Still open

- Home Assistant has never connected to this module — the ESPHome entry has to be
  added/reloaded in the HA UI against `192.168.1.230:6053`. Everything on the
  module side is verified with `tools/ha-test-client.py`.
- No DHCP reservation for the module's MAC on the router yet. The alias works
  around it; a reservation is still the right fix for the primary address.
- 1 GB usable RAM: LVA runs bare metal, no Docker; M5's stock `llm-*` services are
  stopped.

## Upstream

- [OHF-Voice/linux-voice-assistant](https://github.com/OHF-Voice/linux-voice-assistant) — the satellite runtime (this repo does not fork it)
- [OHF-Voice/wyoming-satellite](https://github.com/rhasspy/wyoming-satellite) — deprecated predecessor
- [screamnAbdab/lva-led-bridge](https://github.com/screamnAbdab/lva-led-bridge) — LED bridge pattern reference (APA102)
