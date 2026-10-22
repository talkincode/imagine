# Qwen3-TTS adapter (`tts_http`)

This process adapts Imagine's `imagine.tts_http.v1` protocol to the official
Qwen3-TTS Python API. It does not bundle model weights.

## Modes and checkpoints

The adapter loads the checkpoint required by the requested mode. The defaults
are the official 1.7B models:

| Imagine mode | Official API | Default checkpoint |
| --- | --- | --- |
| `speech` | `generate_custom_voice` | `Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice` |
| `voice_design` | `generate_voice_design` | `Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign` |
| `voice_clone` | `generate_voice_clone` | `Qwen/Qwen3-TTS-12Hz-1.7B-Base` |

Use the matching `--custom-voice-model`, `--voice-design-model`, or
`--voice-clone-model` option to point at a different compatible Hugging Face
model ID or local model directory. Qwen also publishes 0.6B CustomVoice and
Base checkpoints. A single checkpoint is kept in memory; changing modes
releases the previous checkpoint and loads the one required by the new mode.

`speech` defaults to the official `Vivian` CustomVoice speaker. `/voices`
returns the supported speaker list from the loaded CustomVoice checkpoint.
Set `--default-speaker` if a selected compatible checkpoint uses a different
speaker set. `voice_design` requires a natural-language `style` instruction.
`voice_clone` requires `reference_audio.data` and its matching
`reference_text` for Qwen's ICL clone mode.

The adapter maps common language codes such as `zh`, `zh-CN`, and `en-US` to
Qwen's language names (`Chinese`, `English`). Full Qwen language names pass
through unchanged.

## Install and run

Install Qwen's published runtime in an isolated Python environment, following
the official Qwen3-TTS installation guidance:

```bash
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -U qwen-tts
```

Start the deterministic protocol mock (default; no Qwen package or weights are
imported):

```bash
python3 integrations/qwen3-tts/server.py --mock
```

Start real model inference with the default runtime placement:

```bash
python3 integrations/qwen3-tts/server.py --real
```

For a CUDA host, Qwen's documented loading options can be passed through:

```bash
python3 integrations/qwen3-tts/server.py --real \
  --device-map cuda:0 --dtype bfloat16 \
  --attn-implementation flash_attention_2
```

The loader options and model IDs can also be set with
`QWEN3_TTS_DEVICE_MAP`, `QWEN3_TTS_DTYPE`,
`QWEN3_TTS_ATTN_IMPLEMENTATION`, `QWEN3_TTS_CUSTOM_VOICE_MODEL`,
`QWEN3_TTS_VOICE_DESIGN_MODEL`, and `QWEN3_TTS_VOICE_CLONE_MODEL`.
`--device-map`, dtype, and attention implementation are optional; choose them
for the installed PyTorch/runtime and available hardware. The first request
for each mode may download its model and fail if the checkpoint is unavailable
or the host cannot load it.

`/healthz` reports `mock`, `model_loaded`, and `model_mode`. A real model is
loaded lazily on the first request for its mode. Model load failures return
HTTP 503; invalid requests return HTTP 400; inference or output failures
return HTTP 500. Failed inference never returns an audio payload or substitutes
the mock WAV.

## Imagine configuration

```toml
[models."qwen3-tts"]
backend = "tts_http"
api_model = "qwen3-tts"

[[models."qwen3-tts".endpoints]]
base_url = "http://127.0.0.1:8712/generate"
auth = "none"
```

```bash
imagine generate -m qwen3-tts -p "你好。" --language zh --voice Vivian -o hello.wav
imagine voices -m qwen3-tts
```

The adapter encodes Qwen's returned sample array as PCM16 WAV and reports the
sample rate returned by the model in both the WAV header and JSON response.
Qwen's `non_streaming_mode=False` does not stream generated audio, so
`/capabilities` always reports `streaming: false` and a request with
`stream: true` is rejected.

## Tests and acceptance

Fast regression tests use a fake `Qwen3TTSModel` that records checkpoint IDs,
method names, keyword arguments, and returns a non-silent sample array. They
run without downloading weights or installing Qwen/PyTorch:

```bash
python3 -m unittest discover -s integrations/qwen3-tts/tests -v
```

These tests verify the adapter contract; they do **not** show that any real
checkpoint or hardware backend is usable. For a separate real-model acceptance
gate, start the server with `--real`, then provide an authorized reference
recording and its exact transcript:

```bash
python3 integrations/qwen3-tts/smoke_real.py \
  --reference-audio ./authorized-reference.wav \
  --reference-text "The exact words spoken in the reference recording."
```

The smoke gate refuses a mock server, calls all three modes over HTTP, checks
that each request loaded the matching real mode, verifies a valid non-silent
PCM16 WAV and matching sample-rate/channel metadata, and writes the three
outputs for listening review. Run it on the actual target hardware; a pass on
one machine does not establish availability on another.
