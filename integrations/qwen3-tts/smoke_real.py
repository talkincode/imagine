#!/usr/bin/env python3
"""Opt-in HTTP smoke gate for actual Qwen3-TTS checkpoints.

Start server.py with --real before running this script. It exercises all three
model modes, validates the returned WAV metadata, and rejects silence or a
mock server. The clone case requires a user-authorized reference recording.
"""

import argparse
import array
import base64
import json
import os
import struct
import urllib.error
import urllib.request
import wave
from io import BytesIO


def request_json(url, body=None):
    data = None if body is None else json.dumps(body).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json"} if data is not None else {},
    )
    try:
        response = urllib.request.urlopen(request, timeout=900)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"{url} returned HTTP {exc.code}: {detail}") from exc
    with response:
        return json.loads(response.read())


def check_wav(payload, declared_rate, declared_channels):
    with wave.open(BytesIO(payload), "rb") as wav:
        sample_rate = wav.getframerate()
        channels = wav.getnchannels()
        sample_width = wav.getsampwidth()
        frames = wav.getnframes()
        pcm = wav.readframes(frames)
    if sample_width != 2:
        raise RuntimeError(f"expected PCM16 WAV, got {sample_width * 8}-bit samples")
    if sample_rate != declared_rate or channels != declared_channels:
        raise RuntimeError(
            "response metadata disagrees with WAV header: "
            f"metadata={declared_rate}Hz/{declared_channels}ch, "
            f"header={sample_rate}Hz/{channels}ch"
        )
    if frames < max(1, sample_rate // 100):
        raise RuntimeError(f"generated WAV is too short ({frames} frames)")
    samples = array.array("h")
    samples.frombytes(pcm)
    if struct.pack("=h", 1) != struct.pack("<h", 1):
        samples.byteswap()
    if not any(samples):
        raise RuntimeError("generated WAV is silent")
    return sample_rate, channels, frames


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:8712")
    parser.add_argument("--reference-audio", required=True, help="authorized local WAV/FLAC reference recording")
    parser.add_argument("--reference-text", required=True, help="exact transcript of the reference recording")
    parser.add_argument("--language", default="Chinese")
    parser.add_argument("--output-dir", default="qwen3-tts-real-smoke")
    args = parser.parse_args()
    base_url = args.url.rstrip("/")

    health = request_json(f"{base_url}/healthz")
    if health.get("mock") is not False:
        raise SystemExit("FAIL: server is in mock mode; restart it with --real")

    with open(args.reference_audio, "rb") as source:
        reference = base64.b64encode(source.read()).decode("ascii")
    if not reference:
        raise SystemExit("FAIL: reference audio file is empty")

    requests = [
        ("speech", {
            "mode": "speech",
            "text": "本地 Qwen3-TTS 真实模型验收。",
            "language": args.language,
            "voice": "Vivian",
        }),
        ("voice_design", {
            "mode": "voice_design",
            "text": "本地 Qwen3-TTS 真实模型验收。",
            "language": args.language,
            "style": "自然、清晰、温和的成年女性声音",
        }),
        ("voice_clone", {
            "mode": "voice_clone",
            "text": "本地 Qwen3-TTS 真实模型验收。",
            "language": args.language,
            "reference_audio": {"mime_type": "audio/wav", "data": reference},
            "reference_text": args.reference_text,
        }),
    ]
    os.makedirs(args.output_dir, exist_ok=True)
    for mode, body in requests:
        response = request_json(f"{base_url}/generate", body)
        if response.get("mime") != "audio/wav":
            raise RuntimeError(f"{mode} returned unexpected mime type {response.get('mime')!r}")
        audio = base64.b64decode(response.get("audio", ""), validate=True)
        rate, channels, frames = check_wav(
            audio,
            response.get("sample_rate_hz"),
            response.get("channels"),
        )
        state = request_json(f"{base_url}/healthz")
        if (state.get("mock") is not False or not state.get("model_loaded")
                or state.get("model_mode") != mode):
            raise RuntimeError(f"{mode} did not load the expected real model: {state}")
        output = os.path.join(args.output_dir, f"{mode}.wav")
        with open(output, "wb") as target:
            target.write(audio)
        print(f"PASS {mode}: {rate} Hz, {channels} ch, {frames} frames -> {output}")

    print("PASS all three real Qwen3-TTS modes")


if __name__ == "__main__":
    main()
