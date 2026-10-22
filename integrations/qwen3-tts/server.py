#!/usr/bin/env python3
"""Adapter from imagine.tts_http.v1 to the official Qwen3-TTS Python API.

The default mock process is dependency-free and is only for protocol tests.
Run with ``--real`` to lazily load official Qwen3TTSModel checkpoints. Qwen's
``non_streaming_mode=False`` does not stream generated audio, so this adapter
never advertises or fabricates streaming support.
"""

import argparse
import array
import base64
import binascii
import gc
import io
import json
import math
import numbers
import os
import sys
import threading
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


DEFAULT_MODEL_IDS = {
    "speech": "Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice",
    "voice_design": "Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign",
    "voice_clone": "Qwen/Qwen3-TTS-12Hz-1.7B-Base",
}
MODEL_IDS = dict(DEFAULT_MODEL_IDS)
DEVICE_MAP = None
DTYPE = None
ATTN_IMPLEMENTATION = None
DEFAULT_SPEAKER = "Vivian"

MOCK = True
_MODEL = None
_MODEL_MODE = None
_MODEL_LOCK = threading.RLock()


class AdapterError(Exception):
    def __init__(self, message, status=400):
        super().__init__(message)
        self.status = status


def tiny_wav():
    output = io.BytesIO()
    with wave.open(output, "wb") as target:
        target.setnchannels(1)
        target.setsampwidth(2)
        target.setframerate(8000)
        target.writeframes(b"\x00\x00\x01\x00")
    return output.getvalue()


WAV = tiny_wav()


def normalize_language(value):
    if value is None or value == "":
        return None
    if not isinstance(value, str):
        raise AdapterError("language must be a string")
    aliases = {
        "zh": "Chinese", "zh-cn": "Chinese", "zh-tw": "Chinese",
        "en": "English", "en-us": "English", "en-gb": "English",
        "ja": "Japanese", "ko": "Korean", "de": "German", "fr": "French",
        "ru": "Russian", "pt": "Portuguese", "es": "Spanish", "it": "Italian",
    }
    return aliases.get(value.strip().lower(), value.strip())


def normalize_request(body):
    if not isinstance(body, dict):
        raise AdapterError("request body must be a JSON object")
    mode = body.get("mode") or "speech"
    if not isinstance(mode, str) or mode not in DEFAULT_MODEL_IDS:
        raise AdapterError("mode must be one of: speech, voice_design, voice_clone")
    text = body.get("text")
    if not isinstance(text, str) or not text.strip():
        raise AdapterError("text must be a non-empty string")

    style = body.get("style")
    if style is not None and not isinstance(style, str):
        raise AdapterError("style must be a string")
    if mode == "voice_design" and not (style or "").strip():
        raise AdapterError("voice_design requires a non-empty style instruction")

    voice = body.get("voice")
    if voice is not None and not isinstance(voice, str):
        raise AdapterError("voice must be a string")

    reference = None
    reference_text = body.get("reference_text")
    if mode == "voice_clone":
        ref = body.get("reference_audio")
        if not isinstance(ref, dict) or not isinstance(ref.get("data"), str):
            raise AdapterError("voice_clone requires reference_audio.data as base64 audio")
        encoded = ref["data"]
        if encoded.startswith("data:"):
            if "," not in encoded:
                raise AdapterError("reference_audio.data has an invalid data URL")
            encoded = encoded.split(",", 1)[1]
        try:
            raw = base64.b64decode(encoded, validate=True)
        except (binascii.Error, ValueError) as exc:
            raise AdapterError("reference_audio.data is not valid base64") from exc
        if not raw:
            raise AdapterError("reference_audio.data is empty")
        # Qwen3TTSModel accepts reference audio as a base64 string and decodes
        # it internally with soundfile, preserving the original sample rate.
        reference = base64.b64encode(raw).decode("ascii")
        if reference_text is not None and not isinstance(reference_text, str):
            raise AdapterError("reference_text must be a string")
        if not (reference_text or "").strip():
            raise AdapterError("voice_clone requires reference_text for ICL cloning")
    elif reference_text is not None and not isinstance(reference_text, str):
        raise AdapterError("reference_text must be a string")

    return {
        "mode": mode,
        "text": text,
        "language": normalize_language(body.get("language")),
        "voice": voice.strip() if isinstance(voice, str) and voice.strip() else None,
        "style": style,
        "reference_audio": reference,
        "reference_text": reference_text,
    }


def _model_load_kwargs():
    kwargs = {}
    if DEVICE_MAP:
        kwargs["device_map"] = DEVICE_MAP
    if DTYPE:
        if DTYPE == "auto":
            kwargs["dtype"] = "auto"
        else:
            try:
                import torch

                kwargs["dtype"] = getattr(torch, DTYPE)
            except (ImportError, AttributeError) as exc:
                raise AdapterError(f"cannot use dtype {DTYPE!r}: {exc}", status=503) from exc
    if ATTN_IMPLEMENTATION:
        kwargs["attn_implementation"] = ATTN_IMPLEMENTATION
    return kwargs


def _drop_loaded_model():
    global _MODEL, _MODEL_MODE
    _MODEL = None
    _MODEL_MODE = None
    gc.collect()
    # Best effort only: CPU and MPS installs need not have CUDA available.
    torch = sys.modules.get("torch")
    if torch is not None:
        try:
            if torch.cuda.is_available():
                torch.cuda.empty_cache()
        except Exception:
            pass


def get_model(mode):
    """Load the checkpoint that implements this API mode, one at a time."""
    global _MODEL, _MODEL_MODE
    model_id = MODEL_IDS[mode]
    if _MODEL is not None and _MODEL_MODE == mode:
        return _MODEL

    _drop_loaded_model()
    try:
        from qwen_tts import Qwen3TTSModel
    except ImportError as exc:
        raise AdapterError(
            "cannot import Qwen3TTSModel; install the official qwen-tts package in this environment",
            status=503,
        ) from exc

    try:
        _MODEL = Qwen3TTSModel.from_pretrained(model_id, **_model_load_kwargs())
    except Exception as exc:
        _MODEL = None
        _MODEL_MODE = None
        raise AdapterError(f"failed to load Qwen3-TTS checkpoint {model_id!r}: {exc}", status=503) from exc
    _MODEL_MODE = mode
    return _MODEL


def _pcm16_wav(samples, sample_rate):
    if isinstance(sample_rate, bool) or not isinstance(sample_rate, numbers.Integral) or sample_rate <= 0:
        raise AdapterError(f"Qwen returned an invalid sample rate: {sample_rate!r}", status=500)
    sample_rate = int(sample_rate)
    is_numpy_float = getattr(getattr(samples, "dtype", None), "kind", None) == "f"
    if hasattr(samples, "tolist"):
        samples = samples.tolist()
    if not isinstance(samples, (list, tuple)) or not samples:
        raise AdapterError("Qwen returned empty or unsupported audio samples", status=500)

    first = samples[0]
    if isinstance(first, (list, tuple)):
        first_sample = first[0] if first else None
        channels = len(first)
        if channels < 1 or channels > 8:
            raise AdapterError(f"Qwen returned unsupported channel count: {channels}", status=500)
        rows = samples
    else:
        first_sample = first
        channels = 1
        rows = ((sample,) for sample in samples)
    float_samples = is_numpy_float or isinstance(first_sample, float)

    pcm = array.array("h")
    frames = 0
    for row in rows:
        if not isinstance(row, (list, tuple)) or len(row) != channels:
            raise AdapterError("Qwen returned a malformed audio array", status=500)
        for value in row:
            try:
                sample = float(value)
            except (TypeError, ValueError, OverflowError) as exc:
                raise AdapterError("Qwen returned non-numeric audio samples", status=500) from exc
            if not math.isfinite(sample):
                raise AdapterError("Qwen returned non-finite audio samples", status=500)
            if float_samples:
                sample = round(max(-1.0, min(1.0, sample)) * 32767.0)
            else:
                sample = round(sample)
            pcm.append(max(-32768, min(32767, int(sample))))
        frames += 1
    if frames == 0:
        raise AdapterError("Qwen returned no audio frames", status=500)
    if sys.byteorder != "little":
        pcm.byteswap()

    output = io.BytesIO()
    with wave.open(output, "wb") as target:
        target.setnchannels(channels)
        target.setsampwidth(2)
        target.setframerate(sample_rate)
        target.writeframes(pcm.tobytes())
    return output.getvalue(), channels, frames


def _one_audio(result, method_name):
    if not isinstance(result, tuple) or len(result) != 2:
        raise AdapterError(
            f"Qwen {method_name} returned an invalid result; expected (audio_arrays, sample_rate)",
            status=500,
        )
    wavs, sample_rate = result
    if not isinstance(wavs, (list, tuple)) or len(wavs) != 1:
        raise AdapterError(
            f"Qwen {method_name} must return exactly one audio array for one text input",
            status=500,
        )
    audio, channels, frames = _pcm16_wav(wavs[0], sample_rate)
    return audio, sample_rate, channels, frames


def synthesize(body):
    request = normalize_request(body)
    if MOCK:
        return WAV, 8000, 1, 0

    mode = request["mode"]
    method_name = {
        "speech": "generate_custom_voice",
        "voice_design": "generate_voice_design",
        "voice_clone": "generate_voice_clone",
    }[mode]

    # Qwen model instances are not assumed to be thread-safe. Keeping the lock
    # through inference also prevents concurrent requests from swapping models.
    with _MODEL_LOCK:
        model = get_model(mode)
        try:
            if mode == "speech":
                speakers = model.get_supported_speakers()
                if not speakers:
                    raise AdapterError("the selected CustomVoice model exposes no supported speakers", status=500)
                speaker_by_fold = {speaker.casefold(): speaker for speaker in speakers if isinstance(speaker, str)}
                selected_voice = request["voice"] or DEFAULT_SPEAKER
                canonical_voice = speaker_by_fold.get(selected_voice.casefold())
                if canonical_voice is None:
                    available = ", ".join(speakers)
                    raise AdapterError(
                        f"unsupported CustomVoice speaker {selected_voice!r}; available: {available}"
                    )
                result = model.generate_custom_voice(
                    text=request["text"],
                    speaker=canonical_voice,
                    language=request["language"],
                    instruct=request["style"],
                    non_streaming_mode=True,
                )
            elif mode == "voice_design":
                result = model.generate_voice_design(
                    text=request["text"],
                    instruct=request["style"],
                    language=request["language"],
                    non_streaming_mode=True,
                )
            else:
                result = model.generate_voice_clone(
                    text=request["text"],
                    ref_audio=request["reference_audio"],
                    ref_text=request["reference_text"],
                    language=request["language"],
                    non_streaming_mode=True,
                )
        except AdapterError:
            raise
        except Exception as exc:
            raise AdapterError(f"Qwen {method_name} failed: {exc}", status=500) from exc

        audio, sample_rate, channels, frames = _one_audio(result, method_name)
        return audio, sample_rate, channels, frames * 1000 // sample_rate


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        return

    def send_bytes(self, code, payload, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def send_json(self, code, obj):
        self.send_bytes(code, json.dumps(obj).encode(), "application/json")

    def send_failure(self, exc):
        status = exc.status if isinstance(exc, AdapterError) else 500
        print(f"Qwen3-TTS request failed ({status}): {exc}", file=sys.stderr, flush=True)
        self.send_json(status, {"error": {"message": str(exc) or exc.__class__.__name__}})

    def do_GET(self):
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        if path == "/capabilities":
            return self.send_json(200, {
                "protocol": "imagine.tts_http.v1",
                "modes": ["speech", "voice_design", "voice_clone"],
                "streaming": False,
                "formats": ["wav"],
                "style": True,
            })
        if path == "/voices":
            if MOCK:
                return self.send_json(200, {"voices": ["default"]})
            try:
                with _MODEL_LOCK:
                    model = get_model("speech")
                    voices = model.get_supported_speakers()
                if not voices:
                    raise AdapterError("the selected CustomVoice model exposes no supported speakers", status=500)
                return self.send_json(200, {"voices": voices})
            except Exception as exc:
                return self.send_failure(exc)
        if path == "/healthz":
            return self.send_json(200, {
                "ok": True,
                "mock": MOCK,
                "streaming": False,
                "model_loaded": _MODEL is not None,
                "model_mode": _MODEL_MODE,
            })
        return self.send_json(404, {"error": {"message": self.path}})

    def do_POST(self):
        path = self.path.split("?", 1)[0].rstrip("/")
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n)
        if path != "/generate":
            return self.send_json(404, {"error": {"message": self.path}})
        try:
            body = json.loads(raw.decode() or "{}")
        except (UnicodeDecodeError, json.JSONDecodeError):
            return self.send_json(400, {"error": {"message": "body is not valid JSON"}})
        if isinstance(body, dict) and body.get("stream"):
            return self.send_json(400, {"error": {"message": "this Qwen3-TTS adapter does not support incremental audio streaming"}})
        try:
            audio, sample_rate, channels, duration_ms = synthesize(body)
        except Exception as exc:
            return self.send_failure(exc)
        return self.send_json(200, {
            "audio": base64.b64encode(audio).decode("ascii"),
            "mime": "audio/wav",
            "sample_rate_hz": sample_rate,
            "channels": channels,
            "duration_ms": duration_ms,
        })


def configure(args):
    global MOCK, DEVICE_MAP, DTYPE, ATTN_IMPLEMENTATION, DEFAULT_SPEAKER
    MOCK = not args.real
    MODEL_IDS.update({
        "speech": args.custom_voice_model,
        "voice_design": args.voice_design_model,
        "voice_clone": args.voice_clone_model,
    })
    DEVICE_MAP = args.device_map
    DTYPE = args.dtype
    ATTN_IMPLEMENTATION = args.attn_implementation
    DEFAULT_SPEAKER = args.default_speaker


def main():
    parser = argparse.ArgumentParser(description="imagine tts_http Qwen3-TTS adapter")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8712)
    runtime = parser.add_mutually_exclusive_group()
    runtime.add_argument("--mock", action="store_true", help="serve deterministic protocol-test audio (default)")
    runtime.add_argument("--real", action="store_true", help="load official Qwen3TTSModel checkpoints on demand")
    parser.add_argument("--custom-voice-model", default=os.getenv("QWEN3_TTS_CUSTOM_VOICE_MODEL", DEFAULT_MODEL_IDS["speech"]))
    parser.add_argument("--voice-design-model", default=os.getenv("QWEN3_TTS_VOICE_DESIGN_MODEL", DEFAULT_MODEL_IDS["voice_design"]))
    parser.add_argument("--voice-clone-model", default=os.getenv("QWEN3_TTS_VOICE_CLONE_MODEL", DEFAULT_MODEL_IDS["voice_clone"]))
    parser.add_argument("--default-speaker", default=os.getenv("QWEN3_TTS_DEFAULT_SPEAKER", "Vivian"))
    parser.add_argument("--device-map", default=os.getenv("QWEN3_TTS_DEVICE_MAP"))
    parser.add_argument("--dtype", choices=("auto", "float32", "float16", "bfloat16"), default=os.getenv("QWEN3_TTS_DTYPE"))
    parser.add_argument("--attn-implementation", default=os.getenv("QWEN3_TTS_ATTN_IMPLEMENTATION"))
    args = parser.parse_args()
    configure(args)
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"qwen3-tts listening on http://{args.host}:{args.port} mock={MOCK} streaming=False", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
