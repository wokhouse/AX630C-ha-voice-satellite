#!/usr/bin/env python3
"""LED status bridge: LVA peripheral WebSocket API -> LP5562 sysfs LEDs.

Subscribes to linux-voice-assistant's peripheral API and drives the three
onboard RGB LEDs on the M5Stack Module LLM (LP5562 LED driver, kernel
leds-lp5562 driver exposes /sys/class/leds/<name>/brightness).

State map:
  idle                  -> off
  wake_word_detected /
  listening             -> cyan
  thinking              -> yellow
  tts_speaking          -> green
  pipeline_error        -> red, 3 blinks, then previous state
  disconnected          -> red steady
  snapshot with
  ha_connected=true, or
  zeroconf status=
  "connected"           -> follow pipeline state

Channel names are auto-detected: any /sys/class/leds entry whose name
contains R/G/B (case-insensitive) is treated as one channel. Verify the
detected names on first bring-up (docs/bringup.md).
"""

import argparse
import asyncio
import json
import os
import signal
import sys
import time

import websockets

LED_ROOT = "/sys/class/leds"
MAX_BRIGHTNESS = 120  # 0-255; the 2020 LEDs are bright, keep it low indoors

# (r, g, b) per state
COLORS = {
    "idle": (0, 0, 0),
    "wake_word_detected": (0, 255, 255),
    "listening": (0, 255, 255),
    "thinking": (255, 255, 0),
    "tts_speaking": (0, 255, 0),
    "idle_after_error": (0, 0, 0),
    "disconnected": (255, 0, 0),
}


def find_channels():
    """Return {'r': path, 'g': path, 'b': path} of LED sysfs dirs.

    Handles the bare one-letter channels this Module LLM exposes
    (/sys/class/leds/R|G|B, from the LP5562 driver), as well as the usual
    long forms (red, led-r, lp5562:G, ...).
    """
    channels = {}
    if not os.path.isdir(LED_ROOT):
        return channels
    for name in sorted(os.listdir(LED_ROOT)):
        path = os.path.join(LED_ROOT, name)
        if not os.path.isdir(path) or not os.path.exists(os.path.join(path, "brightness")):
            continue
        low = name.lower()
        # Exact bare channel names first: R, G, B (case-insensitive).
        if low in ("r", "g", "b"):
            channels[low] = path
            continue
        for word, ch in (("red", "r"), ("green", "g"), ("blue", "b")):
            if word in low:
                channels[ch] = path
                continue
        for ch, letter in (("r", "r"), ("g", "g"), ("b", "b")):
            if ch in channels:
                continue
            # led-r, lp5562:R, rgb:blue-style suffixes.
            if low.endswith(f":{letter}") or low.endswith(f"_{letter}") or low.endswith(f"-{letter}"):
                channels[ch] = path
    return channels


def reset_triggers(channels):
    """Set each channel's trigger to 'none' so brightness writes take effect."""
    for ch, path in channels.items():
        trigger = os.path.join(path, "trigger")
        if not os.path.exists(trigger):
            continue
        try:
            with open(trigger, "w") as f:
                f.write("none")
        except OSError as e:
            print(f"led trigger reset failed {ch}: {e}", file=sys.stderr)


class Led:
    def __init__(self, channels):
        self.channels = channels  # {'r': dir, ...}
        reset_triggers(channels)

    def _write(self, ch, value):
        path = self.channels.get(ch)
        if path is None:
            return
        try:
            with open(os.path.join(path, "brightness"), "w") as f:
                f.write(str(int(value)))
        except OSError as e:
            print(f"led write failed {ch}: {e}", file=sys.stderr)

    def set_rgb(self, rgb, scale=1.0):
        r, g, b = rgb
        cap = int(MAX_BRIGHTNESS * scale)
        self._write("r", r * cap // 255)
        self._write("g", g * cap // 255)
        self._write("b", b * cap // 255)

    def off(self):
        self.set_rgb((0, 0, 0))


async def blink_error(led: Led, state_after, stop: asyncio.Event):
    led.set_rgb((255, 0, 0))
    for _ in range(3):
        await asyncio.sleep(0.25)
        led.off()
        await asyncio.sleep(0.25)
        led.set_rgb((255, 0, 0))
    await asyncio.sleep(0.5)
    led.set_rgb(COLORS.get(state_after, COLORS["idle"]))


async def run(uri: str, led: Led, debug: bool):
    state = "disconnected"
    blink_task = None
    while True:
        try:
            async with websockets.connect(uri) as ws:
                if debug:
                    print("connected to peripheral API", file=sys.stderr)
                async for raw in ws:
                    msg = json.loads(raw)
                    event = msg.get("event")
                    data = msg.get("data", {})
                    if debug:
                        print(f"event={event} data={data}", file=sys.stderr)

                    if event == "snapshot":
                        state = "idle" if data.get("ha_connected") else "disconnected"
                    elif event == "zeroconf":
                        # There is no `connected` event in LVAEvent. The documented
                        # "HA is reachable" signal is zeroconf with status
                        # "connected" (satellite.py emits it on the HA handshake;
                        # __main__.py emits "getting_started" at startup). Handling
                        # only `disconnected` leaves the LED red after boot even
                        # when HA is connected, until some pipeline event arrives.
                        state = "idle" if data.get("status") == "connected" else "disconnected"
                    elif event == "disconnected":
                        state = "disconnected"
                    elif event == "pipeline_error":
                        if blink_task:
                            blink_task.cancel()
                        blink_task = asyncio.create_task(blink_error(led, "idle", asyncio.Event()))
                        continue  # do not repaint while blinking
                    elif event in COLORS:
                        state = event

                    if blink_task and not blink_task.done():
                        continue
                    led.set_rgb(COLORS.get(state, COLORS["idle"]))
        except (OSError, websockets.exceptions.WebSocketException) as e:
            if debug:
                print(f"ws error: {e}; retrying", file=sys.stderr)
            state = "disconnected"
            led.set_rgb(COLORS["disconnected"])
            await asyncio.sleep(5.0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--uri", default="ws://127.0.0.1:6055")
    ap.add_argument("--debug", action="store_true")
    args = ap.parse_args()

    channels = find_channels()
    if not channels:
        print(f"no LED channels found under {LED_ROOT}", file=sys.stderr)
        sys.exit(1)
    print(f"led channels: {channels}", file=sys.stderr)
    led = Led(channels)

    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    for s in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(s, lambda: (led.off(), sys.exit(0)))
    try:
        loop.run_until_complete(run(args.uri, led, args.debug))
    finally:
        led.off()


if __name__ == "__main__":
    main()
