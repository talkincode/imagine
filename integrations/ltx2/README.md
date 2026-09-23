# LTX-2 — the optional self-hosted video backend

LTX-2 is an open-weights video model that people run locally (on Apple Silicon
usually through an MLX build). `imagine` reaches a local runtime through the
`ltx2_video` backend: it speaks HTTP to a service you run, exactly like
`integrations/qwen-image` does for images. No weights, no Python, and no model
code live in the `imagine` binary, and nothing here is required for the cloud
backends to work.

```bash
imagine generate -m ltx-2 --image ./portrait.png \
  -p "a lawyer speaking to camera" --duration 6 -o clip.mp4
```

That command works once a service implementing the contract below is listening
and the model is in your config (both are covered here).

## 1. The service contract

`ltx2_video` is an asynchronous backend: it creates a task, polls it, then
downloads the finished MP4. Your service owns the model and the inference
runtime; `imagine` owns config, routing, output naming, `--json` and `batch`.

### Create

```http
POST <base_url>            # e.g. http://127.0.0.1:8100/v1/videos/generations
Content-Type: application/json

{
  "model": "ltx-2",                    # api_model from your config
  "prompt": "a lawyer speaking to camera",
  "duration": 6,                        # seconds, optional
  "resolution": "720p",                 # optional
  "ratio": "16:9",                      # optional (--ratio, or a ratio-shaped --size)
  "seed": 17,                           # optional
  "image": {                            # optional; present = image-to-video
    "mime_type": "image/png",
    "data": "<base64 of the first frame>"
  }
}
```

Fields `imagine` does not have a value for are omitted, so your service decides
its own defaults. `duration`/`resolution`/`ratio` come from the CLI flags or the
model's `defaults` block.

Response — any 2xx with a task id:

```json
{ "id": "ltx-1" }
```

### Poll

```http
GET <base_url>/<id>
```

```json
{ "id": "ltx-1", "status": "running" }
```

| `status` | Meaning for `imagine` |
|----------|----------------------|
| `queued`, `running` (or any unknown value) | keep polling |
| `succeeded` | download `video_url` |
| `failed`, `cancelled` | terminal: report `error.message` in `errors[]` |

```json
{ "id": "ltx-1", "status": "succeeded",
  "video_url": "http://127.0.0.1:8100/v1/videos/ltx-1/content" }
```

A terminal failure is HTTP 200 with a failure status, not an HTTP error — the
same convention Ark and Gemini use:

```json
{ "id": "ltx-1", "status": "failed",
  "error": { "message": "denoising ran out of memory" } }
```

### Download

The `video_url` is fetched with no credential (the backend is for local
services). Serve the MP4 bytes with `Content-Type: video/mp4`; `imagine` writes
them to the `-o` path verbatim and never re-encodes.

### Errors

HTTP-level failures should use `{"error": {"message": "..."}}` (a plain
`message` string also works). The message reaches the user and `--json`
`errors[]` unchanged, so put the actionable part there.

### Timing

Generation takes minutes. Polling is driven by the client: `--poll-interval`
(default 5 s) and `--timeout` (default 600 s, config `poll_interval` /
`task_timeout`). A task that never leaves `running` is reported as
`task <id> did not finish within <n>s`.

## 2. Run the reference service

`server.py` in this directory implements the contract with no dependencies
beyond the Python standard library. Inference itself is a command *you* supply,
so it fits any local runtime — including a CLI such as `ltxgen`:

```bash
python3 integrations/ltx2/server.py --port 8100 \
  --t2v-cmd "ltxgen t2v {prompt} --duration {duration} --output {output}" \
  --i2v-cmd "ltxgen i2v {image} {prompt} --duration {duration} --output {output}"
```

| Placeholder | Value |
|-------------|-------|
| `{prompt}` | request prompt |
| `{image}` | path of a temporary file holding the decoded first frame (image-to-video only) |
| `{duration}` `{resolution}` `{ratio}` `{seed}` | the matching request fields, empty when unset |
| `{output}` | path the command must write the MP4 to |

The template is split into argv words and executed **without a shell**, so a
prompt with spaces, quotes or `$` arrives intact; a placeholder that resolves to
an empty value drops its own argument. Adjust the flags to match your runtime
(`--help` shows the defaults, `GET /healthz` echoes the commands in use).

Check the wiring before loading weights:

```bash
python3 integrations/ltx2/server.py --port 8100 --mock   # placeholder bytes, no model
```

`--jobs N` allows N concurrent generations; the default is 1 because denoising
saturates one device, and `imagine -n 4` will queue them rather than thrash the
GPU.

## 3. Point imagine at it

```toml
[models."ltx-2"]
backend = "ltx2_video"
api_model = "ltx-2"

[[models."ltx-2".endpoints]]
base_url = "http://127.0.0.1:8100/v1/videos/generations"
auth = "none"            # a local service takes no credential — no key needed

[models."ltx-2".defaults]
duration = 6
resolution = "720p"
ratio = "16:9"
```

```bash
imagine models                        # ltx-2 ... [credentials=not_required, availability=unknown]
imagine generate -m ltx-2 -p "a fox in snow" -o fox.mp4
imagine generate -m ltx-2 --image fox.png -p "the fox turns to camera" -o turn.mp4
```

Or with no config file at all:

```bash
IMAGINE_BASE_URL=http://127.0.0.1:8100/v1/videos/generations \
IMAGINE_MODEL=ltx-2 IMAGINE_BACKEND=ltx2_video IMAGINE_AUTH=none \
  imagine generate -p "a neon fox" --duration 6 --ratio 16:9 -o fox.mp4
```

Because the endpoint declares `auth = "none"`, these runs are **not** gated by
`--authorize-spend`: nothing leaves the machine and nothing is billable. If you
put the same backend behind a paid proxy, give the endpoint a credential and the
spend boundary applies again.

## 4. Unified parameters

| imagine | Request field | Notes |
|---------|---------------|-------|
| `-p, --prompt` | `prompt` | required |
| `-m, --model` | `model` | logical name from config; `api_model` is sent |
| `--image <path\|url>` | `image.data` + `mime_type` | local file or URL; the bytes are inlined as base64, and the type comes from the file's magic bytes |
| `--duration <sec>` | `duration` | omitted when unset |
| `--resolution <r>` | `resolution` | omitted when unset |
| `--ratio <r>` (or `--size 16:9`) | `ratio` | pixel `--size` has no video meaning and is ignored |
| `--seed <int>` | `seed` | omitted when unset |
| `-n`, `-c` | — | fan out into N independent tasks (each polls its own job) |
| `--format` | — | the output is always named `.mp4` |
| `--watermark` | — | not part of this contract; a local runtime adds its own if any |

`--dry-run` prints the exact create body, and `--json` reports per-task results
and errors for both `generate` and `batch`.

The contract covers text-to-video and image-to-video. Audio-conditioned
generation (a runtime's `a2v` mode) is not part of it yet: `imagine` has no
audio input, so such a request would need an extra field here first.

## 5. Troubleshooting

| Symptom | Cause |
|---------|-------|
| `request failed: ConnectionRefused` | nothing is listening on `base_url` — start the service |
| `HTTP 404: no route for /v1/...` | `base_url` does not point at the create route |
| `task ltx-1 failed: ...` | the runtime command failed; the message is its stderr tail |
| `task ltx-1 did not finish within 600s` | raise `--timeout`; a first run also loads weights |
| `HTTP 400: prompt is required` | the request never carried a prompt (a client-side bug, not a model one) |

Logs: run the service in the foreground (`GET /healthz` reports liveness and the
commands in use), and `imagine --dry-run` shows the request body it would send.
