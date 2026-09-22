---
name: imagine
description: Use the imagine CLI to generate images and videos — OpenAI-compatible image APIs via config-file models or ephemeral env (IMAGINE_BASE_URL + IMAGINE_MODEL + AZURE_OPENAI_APIKEY), plus built-in Volcengine Ark (Seedance video, Seedream images via ARK_API_KEY) and Google Gemini Omni video (GEMINI_API_KEY) with no config file. Use for text-to-image, text-to-video, image-to-video, batch jobs, model discovery via `imagine models`, and --json results. Always discover models with `imagine models` first — do not hardcode model names. Check whether the imagine binary is installed first.
---

# imagine - Universal Image & Video Generation CLI Skill

`imagine` is a universal image- and video-generation CLI for AI agents. It
provides one frontend parameter set, routes requests to backends by
**configured** model name, and can distribute one logical model across multiple
endpoints (URL + key) for concurrent scheduling. It is a single static Zig
binary and does not require `curl`, `jq`, or `base64`.

Model names are **not** fixed in the binary. They come from either:

1. **Config file** — `~/.imagine/config.toml` (or `$IMAGINE_CONFIG` / `--config`)
2. **Ephemeral env** — when no config file exists: `IMAGINE_BASE_URL` +
   `IMAGINE_MODEL` + credential (`AZURE_OPENAI_APIKEY` / `IMAGINE_API_KEY` /
   `IMAGINE_API_KEY_ENV`)
3. **Built-in presets** — first-party models (Volcengine Ark, Google Gemini) that
   work with nothing but their API key in the environment

Always run `imagine models` (or `imagine models --json`) before generating.
Check the `source` field (`file` | `ephemeral` | `preset`) and the `media` field
(`image` | `video`).

## When To Use This Skill

- Generate one or more images from a text prompt and save them to disk.
- Generate a video from a text prompt, or from a first-frame image
  (Seedance / Gemini Omni) — video tasks are asynchronous and take minutes.
- Run batch generation from a JSON manifest with multiple jobs (mixed image and
  video jobs are fine).
- Overlay an SVG on a PNG with `compose` when the binary was built with optional
  `resvg` support.
- Use `--json` when an agent needs structured output.
- Inspect or initialize config, or troubleshoot missing models and credentials.
- Zero-file agent/CI runs via ephemeral env or presets (no `config init`).

## Step 0: Check The Binary

Before using any feature, verify that `imagine` is available:

```bash
command -v imagine && imagine version
```

- If this prints a path and version, continue to the usage steps.
- If the command is missing, do not try to generate images yet. Tell the user it
  is not installed and ask for approval before helping install it.

### Installation Guidance

Explain that installation will place the binary in `~/.local/bin` and the agent
skill in `~/.agents/skills/imagine`. After the user approves, use one of these:

```bash
# Option A: one-line install, recommended. It auto-detects OS/arch, downloads
# prebuilt artifacts from the GitHub release, and verifies SHA-256 checksums.
curl -fsSL https://raw.githubusercontent.com/jamiesun/imagine/main/install.sh | sh

# Option B: source install for development or unsupported prebuilt platforms.
# Requires Zig >= 0.16.0.
make install
```

After installation, make sure `~/.local/bin` is on PATH if needed, then verify
again with `imagine version`.

Linux and macOS can use the one-line installer. Windows users should download
`imagine-windows-x86_64.exe` or `imagine-windows-aarch64.exe` from the latest
release and put it on PATH. The one-line installer only downloads prebuilt
artifacts; use `IMAGINE_VERSION=v0.2.0` to pin a release. If no prebuilt binary
exists for the platform, build from source with Zig >= 0.16.0.

## Step 1: Discover Models (required)

```bash
imagine models               # config models + built-in presets, with readiness
imagine models --json        # machine-readable; each item has "source", "media", "ready"
imagine config show          # effective config (no presets); includes "source"
```

Pick a model name where `ready` is true. Use that exact name for `-m` / batch
`"model"`. If exactly one model is configured (typical for ephemeral), `-m` may
be omitted. Do **not** invent model names from this skill.

`source` is `file` (config), `ephemeral` (IMAGINE_* env), or `preset` (built-in
catalog). A config model with the same name as a preset always wins. Presets need
no config file — just the credential env:

```bash
export ARK_API_KEY="..."        # Seedance video + Seedream images (Volcengine Ark)
export GEMINI_API_KEY="..."     # Gemini Omni video
imagine models --json           # these show source="preset", media="video"|"image"
```

### Path A — Config file (multi-model / multi-endpoint)

```bash
imagine config path
imagine config init          # starter; --force to overwrite
# edit ~/.imagine/config.toml, then:
export AZURE_OPENAI_APIKEY="your-azure-key"
```

### Path B — Ephemeral env (no config file)

Only used when **no** config file is found (`--config` / `$IMAGINE_CONFIG` /
`~/.imagine/config.toml` / legacy JSON all absent).

```bash
export IMAGINE_BASE_URL="https://host/.../images/generations"
export IMAGINE_MODEL="MAI-Image-2.6-Flash"   # logical name (+ default api_model)
export AZURE_OPENAI_APIKEY="..."             # or IMAGINE_API_KEY=... / IMAGINE_API_KEY_ENV=...
# optional: IMAGINE_API_MODEL, IMAGINE_BACKEND, IMAGINE_AUTH, IMAGINE_SIZE, IMAGINE_STEPS, ...
imagine models --json
imagine generate -p "a red fox" -o fox.png   # -m optional (single model)
```

Precedence: `--config` > `$IMAGINE_CONFIG` > default file > ephemeral env.

Credential precedence (file endpoints): `api_key` literal > `api_key_env`.
Ephemeral credential: `IMAGINE_API_KEY` > env named by `IMAGINE_API_KEY_ENV` >
`AZURE_OPENAI_APIKEY`.

An endpoint with `auth = "none"` (or `IMAGINE_AUTH=none` when ephemeral) takes
**no credential at all** — that is how a local model server is wired, and such a
model reports `ready: true` without any key set.

Typical backends:

| backend | Protocol | Common params |
|---------|----------|---------------|
| `openai_image` | OpenAI-compatible `/v1/images/generations` | `--size`, `--format`, `--quality` |
| `azure_flux` | Azure FLUX | `--width` / `--height`, optional `--seed` |
| `qwen_image` | Local Qwen-Image-2.1 server (`/v1/images/generations`) | `--size` (`WxH` or ratio token), `--steps`, `--seed`, `--format` |
| `volcengine_image` | Volcengine Ark Seedream (sync) | `--size` (tier `1K`/`2K`/`4K` or `WxH`), `--format`, `--no-watermark`, `--image` |
| `seedance` | Volcengine Ark video task (async) | `--duration`, `--resolution`, `--ratio`, `--image`, `--no-watermark` |
| `gemini_video` | Google Gemini Interactions API / Omni (async) | `--duration`, `--resolution`, `--ratio`, `--image`, `--seed` |

Legacy config value `azure_image` is accepted as an alias of `openai_image`.
Video backends (`seedance`, `gemini_video`) report `media: "video"` and write
`.mp4` by default.

#### Video backends (`seedance`, `gemini_video`)

Both are **asynchronous**: `imagine` creates a provider task, polls it until it
succeeds, then downloads the clip. Expect minutes per clip. Relevant knobs:

| Flag | Meaning |
|------|---------|
| `--duration <sec>` | Clip length (Ark: 2–30 s depending on model) |
| `--resolution <r>` | `480p` / `720p` / `1080p` / `4k` (model-dependent) |
| `--ratio <r>` | `16:9` / `9:16` / `1:1` / … (`--size 16:9` also works for video) |
| `--image <path\|url>` | First-frame image (image-to-video); local files are inlined |
| `--poll-interval <sec>` | Seconds between status polls (default 5; config `poll_interval`) |
| `--timeout <sec>` | Give up on one task after N seconds (default 600; config `task_timeout`) |

Progress prints `start <model> -> <path> (polling every Ns, up to Ms)` per task,
then `ok`/`FAIL`. A timeout is a normal failure: it appears in `errors[]` as
`task <id> did not finish within <n>s`. Provider-side failures (content policy,
expired task) arrive as HTTP 200 with a failure status and surface in `errors[]`
with the provider's message.

`--image` accepts a path or an `http(s)` URL. Ark takes URLs and base64 data URLs;
Gemini takes bytes only, so `imagine` downloads the URL first. Local files are
read and inlined (keep them under ~30 MB). The declared image type comes from the
file's magic bytes, so an extension-less URL is fine.

`--format` picks the container where the provider supports it (Seedance 2.5:
`mp4` or `mov`). Gemini Omni has no container parameter and always writes
`.mp4`. `--size`/`--ratio` both set the aspect ratio for video.

#### Local Qwen-Image-2.1 (`qwen_image`)

Only usable once a Qwen-Image-2.1 server is installed and running on the
machine — the model does not live in the `imagine` binary:

```bash
integrations/qwen-image/install.sh --prefetch   # venv + deps + weights (~20 GB)
qwen-image-server                               # http://127.0.0.1:8000
# alternative: vllm serve Qwen/Qwen-Image-2.1 --omni --port 8091
```

Then, with no config file at all:

```bash
IMAGINE_BASE_URL=http://127.0.0.1:8000/v1/images/generations \
IMAGINE_MODEL=qwen-image-2.1 IMAGINE_BACKEND=qwen_image IMAGINE_AUTH=none \
  imagine generate -p "a neon Qwen sign" --size 1024x1024 --steps 20 -o sign.png
```

The server default is **1024x1024** (~1 minute per image on an M2 Ultra); native
ratio tokens (`1:1`, `4:3`, `3:4`, `3:2`, `2:3`, `16:9`, `9:16`) resolve to 2K
pixel sizes and cost roughly 6x the time, so ask for them explicitly.
Transparent RGBA output is asked for in the prompt and needs `--format png`.
Full details: `integrations/qwen-image/README.md`.

To distribute requests across multiple endpoints, use a config file with
multiple `endpoints` tables under the same model.

## Step 2: Generate

Replace `<model>` with a name from `imagine models`:

```bash
# Single image
imagine generate -m <model> -p "A photograph of a red fox in an autumn forest" -o fox.png

# Dimensions via width/height (typical for azure_flux; also ok for openai_image)
imagine generate -m <model> -p "a city at dusk" --width 1024 --height 1024 -o city.png

# Multiple images with concurrency; filenames get numbered automatically
imagine generate -m <model> -p "logo concept" -n 4 -o logo.png -c 4

# Video (check `imagine models --json` for media="video" first)
imagine generate -m doubao-seedance-2-5-260628 -p "a fox running through snow" \
  --duration 5 --resolution 720p --ratio 16:9 -o fox.mp4
imagine generate -m gemini-omni-1.1-flash -p "the fox turns and looks at us" \
  --image fox.png -o fox-turn.mp4

# Inspect the request body without calling the API (video: also prints the poll settings)
imagine generate -m <model> -p "test" --dry-run

# Structured output for agents
imagine generate -m <model> -p "a red fox" -o fox.png --json
```

Common options:

| Option | Description |
|--------|-------------|
| `-m, --model` | Model name from config. Required. Discover with `imagine models`. |
| `-p, --prompt` | Prompt text. Required, or pass it as a positional argument. |
| `-o, --output` | Output file for one image, or output stem for multiple images. |
| `-n, --n` | Number of images. Default: 1. |
| `-s, --size` | Size string for `openai_image` (e.g. `1024x1024`). Provider-specific. |
| `--width / --height` | Dimensions for `azure_flux` (and optional size derivation for `openai_image`). |
| `--format` | `png` or `jpeg` for `openai_image` output. WebP is not supported. |
| `--compression` | Output compression from `0` to `100` for `openai_image` output. |
| `--quality` | `low`, `medium`, `high`, or `auto` for `openai_image` output. |
| `--seed` | Seed where supported. |
| `--steps` | Denoising steps for `qwen_image` (`num_inference_steps`; server default 40). |
| `--image` | First-frame / reference image: path or URL. Only for backends that take one (`seedance`, `gemini_video`, `volcengine_image`); others reject it with a usage error. |
| `--watermark` / `--no-watermark` | Force the Ark watermark on/off. |
| `--duration` / `--resolution` / `--ratio` | Video length, resolution token, aspect ratio. |
| `--poll-interval` / `--timeout` | Async video tasks: poll cadence and per-task deadline. |
| `-c, --concurrency` | Parallel requests. Default: endpoint count. |
| `--config` | Use a specific config file. |
| `--json` | Emit a JSON result object. |
| `--dry-run` | Print the request body without calling the API. |
| `-q, --quiet` | Suppress progress output. |

### Size notes

Size limits depend on the provider and deployment, not on imagine. Prefer model
`defaults` in config, use `--dry-run` to inspect the request body, and parse
`errors[]` from `--json` when a run fails.

## Step 3: Batch Generation

```bash
imagine batch jobs.json -c 4
```

`jobs.json` format (use model names from `imagine models`):

```json
{
  "jobs": [
    { "model": "<model-a>", "prompt": "a fox",  "output": "out/fox.png" },
    { "model": "<model-b>", "prompt": "a city", "output": "out/city.png", "width": 1024, "height": 1024, "n": 2 },
    { "model": "<model-c>", "prompt": "a tree", "output": "out/tree.png", "size": "512x512" }
  ]
}
```

Each job supports: `model`, `prompt`, `output`, `size`, `width`, `height`, `n`,
`format`, `compression`, `quality`, `seed`, `steps`, and the video keys
`duration`, `resolution`, `ratio`, `image`, `watermark`:

```json
{
  "jobs": [
    { "model": "doubao-seedance-2-5-260628", "prompt": "a fox in snow",
      "output": "out/fox.mp4", "duration": 5, "resolution": "720p", "ratio": "16:9" },
    { "model": "gemini-omni-1.1-flash", "prompt": "the fox turns",
      "output": "out/turn.mp4", "image": "fox.png", "resolution": "1080p" }
  ]
}
```

`--poll-interval` / `--timeout` apply to every video job in the manifest.

## Step 4: SVG/PNG Composition

Image composition is split into two reusable commands:

- `svg render`: render an SVG to a transparent PNG at a controlled size.
- `text render`: generate a styled text layer and render it to a transparent PNG.
- `png compose`: overlay one or more PNG layers on top of a base PNG, in layer
  order, with optional opacity and blend modes.

Both require a binary built with optional `resvg` C API support when SVG
rendering is involved:

```bash
zig build -Dsvg-overlay=true
```

A matching `resvg.h` is vendored. If you need to use headers or libraries from
another location, pass:

```bash
zig build -Dsvg-overlay=true -Dresvg-include=/path/to/include -Dresvg-lib=/path/to/lib
```

Render SVG to PNG:

```bash
imagine svg render --input badge.svg -o badge.png --width 256
```

Render text to PNG:

```bash
imagine text render --text "Summer Sale\nBuy 2 Save 50%" -o copy.png --width 900 \
  --font "PingFang SC" --size 72 --color "#ffffff" \
  --stroke "#111111" --stroke-width 3 --align center --line-height 1.18
```

Compose multiple PNG layers:

```bash
imagine png compose --base photo.png \
  --layer badge.png,x=24,y=24,opacity=1,blend=normal \
  --layer copy.png,x=80,y=120,opacity=1,blend=normal \
  --layer shadow.png,x=20,y=28,opacity=0.45,blend=multiply \
  -o composed.png
```

Shortcut for one SVG over one PNG:

```bash
imagine compose --base photo.png --svg badge.svg -o composed.png --x 24 --y 24 --width 256 --blend=normal
```

Options and layer specs:

| Option | Description |
|--------|-------------|
| `svg render --input <svg>` | SVG input path. Required. |
| `svg render -o, --output <png>` | Rendered PNG output path. Required. |
| `svg render --width / --height <px>` | Rendered dimensions. If only one side is provided, aspect ratio is preserved. |
| `text render --text <text>` | Text content. Literal `\n` is treated as a line break. |
| `text render --width <px>` | Canvas width. Required. |
| `text render --font / --size / --color` | Font family, font size, and fill color. |
| `text render --stroke / --stroke-width` | Optional SVG text stroke. |
| `text render --align / --line-height / --padding` | Alignment, line-height multiplier, and canvas padding. |
| `png compose --base <png>` | Base PNG image. Required. |
| `png compose --layer <spec>` | PNG layer spec. Repeat for multiple layers. |
| `png compose -o, --output <png>` | Output PNG path. Required. |
| Layer `x` / `y` | Overlay offset in pixels. Default: `0`. |
| Layer `opacity` | `0` to `1`. Default: `1`. |
| Layer `blend` | `normal`, `multiply`, `screen`, `overlay`, `darken`, or `lighten`. Default: `normal`. |

For product images, use `normal` for copy/text layers, `multiply` for shadows,
`screen` for highlights, and lower `opacity` for watermarks.

## Agent Integration Contract

- Exit codes: `0` success, `1` runtime failure including partial failure, `2`
  usage error.
- `--json` result object:
  ```json
  { "ok": true, "media": "image", "model": "...", "backend": "openai_image",
    "requested": 1, "succeeded": 1, "failed": 0,
    "images": [ { "path": "fox.png", "bytes": 12345 } ],
    "videos": [], "errors": [] }
  ```
- Parse `images[].path` (or `videos[].path` when `media` is `video`) to find
  generated files. Both arrays are always present; the unused one is empty.
  `batch` returns `tasks[]` with a per-task `media` field.
- When `ok=false`, read `errors[]` — provider messages are passed through, and
  video tasks report the provider task id.
- **Always** run `imagine models --json` first and only generate with a model
  that has `ready=true`.
- Use `--dry-run` when parameters are uncertain (for video it also prints the
  poll interval and deadline that will be used).

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `IMAGINE_CONFIG` | Override the config path. Default: `~/.imagine/config.toml`. |
| `AZURE_OPENAI_APIKEY` | Default credential for OpenAI/Azure backends (starter config + ephemeral). |
| `ARK_API_KEY` | Credential for `volcengine_image` and `seedance`; also the default ephemeral credential when `IMAGINE_BACKEND` is one of them. |
| `GEMINI_API_KEY` | Credential for `gemini_video` (sent as `x-goog-api-key`). |
| `IMAGINE_BASE_URL` | Ephemeral: endpoint URL (required when no file; the *create* URL for video). |
| `IMAGINE_MODEL` | Ephemeral: logical model name (required when no file). |
| `IMAGINE_API_MODEL` | Ephemeral: API `model` field (default: `IMAGINE_MODEL`). |
| `IMAGINE_BACKEND` | Ephemeral: backend name (default `openai_image`). |
| `IMAGINE_AUTH` | Ephemeral: `bearer` \| `api-key` \| `google_api_key` \| `none` (default `bearer`). |
| `IMAGINE_STEPS` | Ephemeral: denoising steps for `qwen_image`. |
| `IMAGINE_DURATION` / `IMAGINE_RESOLUTION` / `IMAGINE_RATIO` / `IMAGINE_WATERMARK` | Ephemeral: video defaults. |
| `IMAGINE_POLL_INTERVAL` / `IMAGINE_TASK_TIMEOUT` | Ephemeral: async video task poll cadence and deadline. |
| `IMAGINE_API_KEY` | Ephemeral: inline API key. |
| `IMAGINE_API_KEY_ENV` | Ephemeral: name of env var holding the key. |
| `IMAGINE_SIZE` / `IMAGINE_WIDTH` / `IMAGINE_HEIGHT` / `IMAGINE_FORMAT` / `IMAGINE_QUALITY` / `IMAGINE_COMPRESSION` | Ephemeral model defaults. |

## Troubleshooting

- `model 'X' not found`: run `imagine models`, or set `IMAGINE_MODEL` for ephemeral.
- `no config` / ephemeral incomplete: set file via `config init`, or set
  `IMAGINE_BASE_URL` + `IMAGINE_MODEL` + `AZURE_OPENAI_APIKEY`.
- `missing credential`: set the env named in the message (`ARK_API_KEY`,
  `GEMINI_API_KEY`, `AZURE_OPENAI_APIKEY`), `IMAGINE_API_KEY`, or endpoint
  `api_key`.
- `HTTP 4xx/5xx`: the error comes from the provider API, such as policy,
  quota, or authentication failures.
- Video `task <id> did not finish within <n>s`: the clip is still generating
  upstream. Raise `--timeout` (or `task_timeout`) and/or `--poll-interval`.
- Video `task <id> failed: …`: the provider rejected or blocked the output
  (content policy, expired task) — change the prompt; retrying unchanged will
  fail again.
- Slow generation or rate limits: configure multiple `endpoints` for the model
  and increase `-c`.
