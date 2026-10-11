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
```

`install.sh` rsyncs this repo to the module and runs `setup-module.sh` there. Setup installs apt deps, clones and builds linux-voice-assistant, pins audio to the onboard card, installs both systemd units, and enables them.

Then in Home Assistant: **Settings → Devices & services → ESPHome → Set up another instance**, enter `<MODULE_IP>:6053`. The satellite appears as a device. Select "okay nabu" as the wake word in your voice assistant settings.

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
- `setup-module.sh` — module-side: deps, LVA build, systemd units
- `config/lva.env` — environment for the LVA service (wake model, audio devices)
- `systemd/linux-voice-assistant.service`, `systemd/lva-led-bridge.service`
- `led/led_status.py` — peripheral API → LP5562 sysfs bridge
- `docs/bringup.md` — first bring-up over serial console

## Known unknowns (verify at bring-up)

- Exact `/sys/class/leds/` names for the LP5562 channels — `led_status.py` auto-detects by name pattern; confirm on first boot.
- ALSA device string for the MSM421A mic (expected `plughw:0,0`) and speaker (`plughw:0,1`).
- Whether M5's stock image ships PipeWire; setup installs it if missing.
- 1 GB usable RAM: run LVA bare metal, no Docker. Stop M5's stock `llm-*` services to free memory.

## Upstream

- [OHF-Voice/linux-voice-assistant](https://github.com/OHF-Voice/linux-voice-assistant) — the satellite runtime (this repo does not fork it)
- [OHF-Voice/wyoming-satellite](https://github.com/rhasspy/wyoming-satellite) — deprecated predecessor
- [screamnAbdab/lva-led-bridge](https://github.com/screamnAbdab/lva-led-bridge) — LED bridge pattern reference (APA102)
