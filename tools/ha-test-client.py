#!/usr/bin/env python3
"""Stand-in Home Assistant client for the Module LLM satellite.

Why this exists
---------------
linux-voice-assistant implements the *device* side of the ESPHome native API;
Home Assistant is the client that drives the pipeline. Two consequences make
bring-up hard to test without HA:

  * `VoiceSatelliteProtocol(state)` is instantiated per TCP connection, and its
    `__init__` is what sets `state.satellite`. The microphone thread in
    `process_audio()` does `if state.satellite is None: continue` *before* the
    wake-word block, so **wake-word detection does not run at all until some
    client connects**. A silent box with nobody talking to it is expected
    behaviour, not a broken mic.
  * The pipeline events that light the LED bridge (thinking / processing /
    speaking) are sent by the client, not generated locally.

This script is a ~200 line client that does the minimum HA does, so the
acoustic path and the LED state machine can be exercised from a shell:

    python3 ha-test-client.py --host  <ALIAS_IP>--port 6053 --drive

Then say "okay nabu" to the module (or play a recording of it into the mic).
Expected: wake chime from the speaker, `WAKE_WORD_DETECTED` / `LISTENING` on
the peripheral API, and — with --drive — THINKING/TTS events.
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import sys
import time
import wave

from aioesphomeapi import APIClient
from aioesphomeapi.api_pb2 import (  # type: ignore[attr-defined]
    VOICE_ASSISTANT_INTENT_END,
    VOICE_ASSISTANT_INTENT_START,
    VOICE_ASSISTANT_RUN_END,
    VOICE_ASSISTANT_RUN_START,
    VOICE_ASSISTANT_STT_END,
    VOICE_ASSISTANT_STT_VAD_END,
    VOICE_ASSISTANT_TTS_END,
    VOICE_ASSISTANT_TTS_START,
    VoiceAssistantEvent,
    VoiceAssistantEventData,
    VoiceAssistantEventResponse,
)


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def event(event_type: int, data: dict[str, str] | None = None):
    return VoiceAssistantEventResponse(
        event_type=event_type,
        data=[VoiceAssistantEventData(name=k, value=str(v)) for k, v in (data or {}).items()],
    )


async def drive_pipeline(cli: APIClient, tts_url: str | None, stt_text: str) -> None:
    """Replay the event sequence HA sends after a wake word.

    Kept deliberately literal: RUN_START -> VAD_END -> STT_END -> INTENT_* ->
    TTS_* -> RUN_END. The LED bridge keys off INTENT_START (thinking) and
    TTS_START (speaking), so this is what proves those states reach it.
    """
    steps = [
        (VOICE_ASSISTANT_RUN_START, {}),
        (VOICE_ASSISTANT_STT_VAD_END, {}),
        (VOICE_ASSISTANT_STT_END, {"text": stt_text}),
        (VOICE_ASSISTANT_INTENT_START, {}),
        (VOICE_ASSISTANT_INTENT_END, {}),
        (VOICE_ASSISTANT_TTS_START, {"text": stt_text}),
        # LVA reads the playable URL off TTS_END (satellite.py handle_voice_event),
        # not off RUN_START; RUN_START's url is only a pre-fetch hint.
        (VOICE_ASSISTANT_TTS_END, {"url": tts_url} if tts_url else {}),
        (VOICE_ASSISTANT_RUN_END, {}),
    ]
    for et, data in steps:
        cli.send_voice_assistant_event(et, data or None)
        log(f"-> event {VoiceAssistantEvent.Name(et)} {data}")
        await asyncio.sleep(0.4)


async def run(args: argparse.Namespace) -> int:
    audio_frames: list[bytes] = []
    woke = asyncio.Event()
    keep: list = []  # sockets to hold open until we are done

    async def handle_start(conversation_id: str, flags: int, audio_settings, wake_word_phrase):
        log(f"VoiceAssistantRequest(start) conversation={conversation_id} flags={flags} wake_word={wake_word_phrase!r}")
        woke.set()
        # HA returns the port of a socket it streams TTS audio over. LVA plays
        # TTS from a URL instead, so we just need *a* port that exists.
        server = await asyncio.start_server(lambda r, w: None, "127.0.0.1", 0)
        port = server.sockets[0].getsockname()[1]
        keep.append(server)
        return port

    async def handle_stop(aborted: bool) -> None:
        log(f"VoiceAssistantRequest(stop) aborted={aborted}")

    async def handle_audio(data: bytes, data2: bytes | None = None) -> None:
        audio_frames.append(data)

    cli = APIClient(args.host, args.port, None)
    log(f"connecting to {args.host}:{args.port}")
    await cli.connect(login=False)

    try:
        info, entities, *_ = await cli.device_info_and_list_entities()
        log(f"connected: name={info.name!r} model={info.model!r} version={info.esphome_version!r}")
        log(f"voice_assistant_feature_flags={info.voice_assistant_feature_flags}")
        log(f"entities advertised: {len(entities)}")
        for e in entities[:40]:
            name = getattr(e, "name", None) or getattr(e, "object_id", "?")
            log(f"  {type(e).__name__}: {name}")
    except Exception as exc:  # pragma: no cover - diagnostics only
        log(f"device_info_and_list_entities failed: {exc}")

    unsub = cli.subscribe_voice_assistant(
        handle_start=handle_start,
        handle_stop=handle_stop,
        handle_audio=handle_audio,
    )
    log("subscribed to voice_assistant (wake-word detection is now armed)")

    deadline = time.monotonic() + args.timeout
    try:
        while time.monotonic() < deadline:
            try:
                await asyncio.wait_for(woke.wait(), timeout=1.0)
            except asyncio.TimeoutError:
                continue
            log("wake word reached the client")
            if args.drive:
                await drive_pipeline(cli, args.tts_url, args.stt_text)
            break
        else:
            log(f"no wake word within {args.timeout}s")
    finally:
        unsub()
        if audio_frames and args.save_audio:
            with wave.open(args.save_audio, "wb") as wf:
                wf.setnchannels(1)
                wf.setsampwidth(2)
                wf.setframerate(16000)
                wf.writeframes(b"".join(audio_frames))
            log(f"saved {len(b''.join(audio_frames))} bytes of mic audio to {args.save_audio}")
        else:
            log(f"mic audio chunks received: {len(audio_frames)}")
        with contextlib.suppress(Exception):
            await cli.disconnect()

    return 0 if woke.is_set() else 1


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--host", default="192.168.1.230")
    p.add_argument("--port", type=int, default=6053)
    p.add_argument("--timeout", type=float, default=60.0, help="seconds to wait for a wake word")
    p.add_argument("--drive", action="store_true", help="send the HA pipeline events back after a wake word")
    p.add_argument("--tts-url", default=None, help="URL/file LVA should play as the TTS response")
    p.add_argument("--stt-text", default="test transcription")
    p.add_argument("--save-audio", default=None, help="write received mic audio to this wav")
    args = p.parse_args()
    try:
        return asyncio.run(run(args))
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
