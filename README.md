# AX630C-ha-voice-satellite

Home Assistant voice satellite firmware layer for the **M5Stack Module LLM** (AX630C) + **LLM Mate** (Ethernet).

Turns the Module LLM into an `assist_satellite` device in Home Assistant, It matches the Voice Preview Edition feature set as closely as the hardware allows.

## Architecture

```
Module LLM (Ubuntu, aarch64)                     Home Assistant
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
- HA discovers the satellite through the **existing ESPHome integration**. No Wyoming entries, no new HA integration.

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

## Provisioning: out of the box to voice satellite

Do this once per module. [docs/bringup.md](docs/bringup.md) has the long version:
serial console details, hardware quirks, and everything measured.

1. **Assemble.** Slide the Module LLM's speaker aside and attach the FPC-8P
   cable to the LLM Mate. Ethernet to the LAN, and a 5 V supply (not a laptop
   USB port). You do not need to re-flash the module. M5's stock Ubuntu image is the
   base. This repo is a software layer on top of it.
2. **Console.** Mate Type-C to your PC, then `picocom -b 115200 /dev/ttyUSB0`
   (115200 8N1). Log in as `root` / `123456`, change the password, and note
   the eth0 address from `ip a`.
3. **Install.** From this repo on your PC:

   ```sh
   MODULE_IP=192.168.1.X ./install.sh
   # if the module's root login wants a specific key:
   MODULE_IP=192.168.1.X SSH_OPTS="-i ~/.ssh/your_key" ./install.sh
   ```

   `install.sh` rsyncs this repo to the module and runs `setup-module.sh`
   there. It:
   - installs the apt dependencies,
   - clones and builds linux-voice-assistant (takes a while on the 2x A53),
   - applies the codec state the vendor image never sets: hardware ALC.
     Without ALC the wake word never fires,
   - pins a stable secondary address to `eth0` (default: last octet 230 on
     the module's subnet. Override with `ALIAS_IP=...`),
   - installs and enables the systemd units.

   It prints the alias address at the end.
4. **Add to Home Assistant.** Settings → Devices & services → ESPHome →
   Set up another instance, enter `<ALIAS_IP>:6053`. Use the alias, not the DHCP
   lease. Select "okay nabu" as the wake word in your voice assistant
   settings. The first connection after a boot takes ~10 s.
5. **Say "okay nabu".** The LED turns cyan, the wake chime plays, and HA's
   Assist pipeline takes it from there.

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

## Upstream

- [OHF-Voice/linux-voice-assistant](https://github.com/OHF-Voice/linux-voice-assistant) — the satellite runtime (this repo does not fork it)
- [rhasspy/wyoming-satellite](https://github.com/rhasspy/wyoming-satellite) — deprecated predecessor
- [screamnAbdab/lva-led-bridge](https://github.com/screamnAbdab/lva-led-bridge) — LED bridge pattern reference (APA102)
