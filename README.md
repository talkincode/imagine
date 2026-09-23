# imagine

[![CI](https://github.com/talkincode/imagine/actions/workflows/ci.yml/badge.svg)](https://github.com/talkincode/imagine/actions/workflows/ci.yml)
[![Release](https://github.com/talkincode/imagine/actions/workflows/release.yml/badge.svg)](https://github.com/talkincode/imagine/actions/workflows/release.yml)

---

![](imagine.png)

---

A universal **image- and video-generation CLI for AI agents**. Unified
front-end parameters, routed to different backends by **configured** model
name. One model can have multiple endpoints (URL + key) for concurrent
scheduling. Single static Zig binary — no `curl`/`jq`/`base64` dependencies.

- **Unified params** → route to a backend by `-m <model>` (names from config or
  the built-in presets).
- **OpenAI-compatible by default** — `openai_image` speaks `/v1/images/generations`.
- **Built-in video** — `seedance` (Volcengine Ark) and `gemini_video` (Gemini
  Omni) create a provider task, poll it, and save the result; credentials come
  from `ARK_API_KEY` / `GEMINI_API_KEY`.
- **Spend boundary** — a task that carries a credential is listed and blocked
  until you pass `--authorize-spend` (or `IMAGINE_AUTHORIZE_SPEND=1`); imagine
  ships no price data, so it says that instead of guessing a cost.
- **Built-in Volcengine images** — `volcengine_image` drives Ark Seedream.
- **Dynamic models** — add/rename/remove models in config; discover with `imagine models`.
- **Concurrent scheduling** — multiple endpoints per model are load-balanced.
- **Agent-friendly** — `--json` machine output, `--dry-run`, meaningful exit codes.

Also supports Azure FLUX via `azure_flux` (width/height body). Starter config
ships example model entries you can edit freely.

Two optional local backends drive **self-hosted models** with the same unified
parameters — no credential, no weights, no model code in the binary:

- `qwen_image` — a local Qwen-Image-2.1 server (diffusers or vLLM-Omni):
  [`integrations/qwen-image`](integrations/qwen-image/README.md).
- `ltx2_video` — a local LTX-2 video service (text-to-video and image-to-video),
  with a documented wire contract and a dependency-free reference server:
  [`integrations/ltx2`](integrations/ltx2/README.md).


## Install

### Homebrew (macOS / Linux)

```bash
brew install talkincode/tap/imagine
```

This pulls prebuilt binaries from the [talkincode/homebrew-tap](https://github.com/talkincode/homebrew-tap) repository, updated automatically on every tagged release.

### One-liner (Linux / macOS)

One-liner for Linux / macOS (auto-detects OS/arch, downloads the prebuilt
binary and agent skill from the GitHub release, and verifies their SHA-256 —
no compilation):

```bash
curl -fsSL https://raw.githubusercontent.com/talkincode/imagine/main/install.sh | sh
```

This installs the `imagine` binary to `~/.local/bin` and the agent skill to
`~/.agents/skills/imagine`. Override with `IMAGINE_BIN_DIR`, `IMAGINE_AGENTS_DIR`,
or pin a release with `IMAGINE_VERSION=v0.2.0`.

**Windows:** download `imagine-windows-x86_64.exe` (or `-aarch64`) from the
[latest release](https://github.com/talkincode/imagine/releases/latest) and put
it on your `PATH`.

Prebuilt binaries are published for every tagged release across Linux, macOS,
and Windows on both `x86_64` and `arm64`.

From a source checkout (or any platform without a prebuilt binary):

```bash
make install        # build + install binary and skill
# or just the binary:
make build && cp zig-out/bin/imagine ~/.local/bin/
```

Building from source requires **Zig ≥ 0.16.0** (`brew install zig` or
<https://ziglang.org/download/>).

## Quick start

```bash
imagine config init                      # write ~/.imagine/config.toml (example models)
export AZURE_OPENAI_APIKEY="your-key"    # or edit api_key_env / api_key in config
imagine models                           # models + presets, with credential status (source=file|ephemeral|preset)

# Use a model name printed by `imagine models` (not a fixed name from docs):
imagine generate -m <model> -p "A photograph of a red fox in an autumn forest" -o fox.png
imagine generate -m <model> -p "a city at dusk" --width 1024 --height 1024 -o city.png
imagine generate -m <model> -p "logo concept" -n 4 -o logo.png -c 4 --authorize-spend

# No config file — ephemeral env (single model; -m optional):
IMAGINE_BASE_URL="https://host/.../images/generations" \
IMAGINE_MODEL="MAI-Image-2.6-Flash" AZURE_OPENAI_APIKEY="..." \
  IMAGINE_AUTHORIZE_SPEND=1 imagine generate -p "a fox" -o fox.png

# Video, no config file at all: built-in presets + one env key
export ARK_API_KEY="..."              # Volcengine Ark (Seedance / Seedream)
imagine generate -m doubao-seedance-2-5-260628 -p "a fox in snow" \
  --duration 5 --resolution 720p --ratio 16:9 -o fox.mp4

export GEMINI_API_KEY="..."           # Google Gemini Omni (video)
imagine generate -m gemini-omni-1.1-flash -p "a marble run" --image first.png -o run.mp4
```

Paid calls need `--authorize-spend` (or `IMAGINE_AUTHORIZE_SPEND=1`); see
[Spend authorization](#spend-authorization).

## Commands

```
imagine generate -m <model> -p <prompt> [options]     # image or video
imagine batch <manifest.json> [-c N] [--json]
imagine svg render --input <svg> -o <png> [--width W --height H]
imagine text render --text <text> -o <png> --width W [options]
imagine png compose --base <png> --layer <spec>... -o <png>
imagine compose --base <png> --svg <svg> -o <png> [options]
imagine models [--json]
imagine config path | init [--force] | convert | show
imagine version | help
```

### generate options

| Option | Description |
|--------|-------------|
| `-m, --model <name>` | Model to route to (**required**) |
| `-p, --prompt <text>` | Prompt (**required**; or positional) |
| `-o, --output <path>` | Output file (single) or stem (multiple) |
| `-n, --n <count>` | Number of images (default 1) |
| `-s, --size <WxH>` | Size for `openai_image` backends (provider-specific) |
| `--width / --height <px>` | Dimensions for `azure_flux` (also derives size for `openai_image`) |
| `--format <fmt>` | `png` / `jpeg` (`openai_image` `output_format`) |
| `--compression <0-100>` | Output compression (`openai_image`) |
| `--quality <q>` | `low` / `medium` / `high` / `auto` (`openai_image`) |
| `--seed <int>` | Seed (where supported) |
| `--steps <n>` | Denoising steps for `qwen_image` (`num_inference_steps`) |
| `--image <path\|url>` | First-frame / reference image (image-to-video, Seedream editing) |
| `--watermark` / `--no-watermark` | Force the provider watermark on/off (Ark) |
| `--duration <sec>` | Clip length in seconds (video) |
| `--resolution <r>` | `480p` / `720p` / `1080p` / `4k` (video) |
| `--ratio <r>` | Aspect ratio, e.g. `16:9` (video; `--size 16:9` works too) |
| `--poll-interval <sec>` | Seconds between provider task polls (default 5) |
| `--timeout <sec>` | Give up on one video task after N seconds (default 600) |
| `-c, --concurrency <n>` | Parallel requests (default: endpoint count) |
| `--config <path>` | Use a specific config file |
| `--json` | Emit a JSON result object |
| `--dry-run` | Print request body without calling the API |
| `--authorize-spend` | Allow tasks that call a credentialed (billable) endpoint |
| `-q, --quiet` | Suppress progress |

Exit codes: `0` success · `1` run failure (incl. partial) · `2` usage error.

### Video generation

Video models are routed exactly like image models — `-m <model>` plus the
unified flags — but the provider flow is asynchronous: `imagine` creates a task,
polls it until it is `succeeded`, then downloads the clip. Expect minutes, not
seconds; `--poll-interval` and `--timeout` (or `poll_interval` / `task_timeout`
in config) bound the wait, and one file is written per task (`-n 3` = three
provider tasks). Progress prints a `start …` line when a task is submitted.

| Backend | Provider / API | Credential env |
|---------|----------------|----------------|
| `seedance` | Volcengine Ark `contents/generations/tasks` (Seedance) | `ARK_API_KEY` |
| `gemini_video` | Google Gemini Interactions API (Omni) | `GEMINI_API_KEY` (`x-goog-api-key`) |
| `ltx2_video` | A self-hosted LTX-2 service ([contract](integrations/ltx2/README.md)) | none — local endpoint |

```bash
# Volcengine Ark Seedance — text to video
imagine generate -m doubao-seedance-2-5-260628 -p "a fox running through snow" \
  --duration 5 --resolution 720p --ratio 16:9 -o fox.mp4

# …or image to video (local file becomes a base64 data URL)
imagine generate -m doubao-seedance-2-5-260628 -p "the fox turns and looks at us" \
  --image fox.png --duration 5 -o fox-turn.mp4

# Google Gemini Omni (Interactions API)
imagine generate -m gemini-omni-1.1-flash -p "a marble run, smooth continuous shot" \
  --resolution 720p -o marble.mp4
```

Both models are **built-in presets**: with the credential env set you can call
them with no config file at all. `imagine models` lists them with
`source: "preset"`; defining a model of the same name in config overrides the
preset (URL, `api_model`, defaults, extra endpoints). Google's Veo models use a
different (non-Interactions) API and are not wired to this backend.

Ark's `--size` has no pixel meaning for video, so a `W:H` token is sent as the
aspect ratio; `--format mp4|mov` picks the container where the provider supports
it (Seedance 2.5 — Gemini Omni has no container parameter, so it always writes
`.mp4`). Gemini Omni always produces audio.

`--image` accepts a path or an `http(s)` URL. Local files are read and inlined
(the Ark request body is capped at 64 MB); a URL is passed through where the
provider accepts one, and fetched by `imagine` where it does not (Gemini only
takes bytes). The declared image type comes from the file's magic bytes, so an
extension-less URL works. Backends that take no image input (`openai_image`,
`azure_flux`, `qwen_image`) reject `--image` with a usage error rather than
ignoring it.

`ltx2_video` speaks the same async flow to a service on your own machine
(text-to-video and image-to-video); nothing leaves the box and no credential is
involved, so those runs are not gated by `--authorize-spend`. The wire contract,
a dependency-free reference server (adapting any local runtime through a command
template) and the config block live in
[`integrations/ltx2`](integrations/ltx2/README.md).

### Spend authorization

Every task that carries a credential is a request a provider may bill for, so
`imagine` stops before the first HTTP call and shows exactly what it would send:

```
$ imagine generate -m doubao-seedance-2-5-260628 -p "a fox" -n 3 -o fox.mp4
spend authorization: 3 of 3 task(s) call a credentialed provider endpoint
cost estimate: unavailable (imagine has no provider price data)
  [1] model=doubao-seedance-2-5-260628 backend=seedance size=n/a duration=provider-default resolution=provider-default ratio=provider-default
  [2] model=doubao-seedance-2-5-260628 backend=seedance size=n/a duration=provider-default resolution=provider-default ratio=provider-default
  [3] model=doubao-seedance-2-5-260628 backend=seedance size=n/a duration=provider-default resolution=provider-default ratio=provider-default
blocked before any HTTP request; rerun with --authorize-spend to allow these tasks
```

Add `--authorize-spend` (or set `IMAGINE_AUTHORIZE_SPEND=1` for a whole agent or
CI run) and the same plan is printed with `spend authorized: dispatching`.
The refusal is a usage error: exit code `2`, nothing dispatched, no file
written, and no provider request in the logs.

Rules, so the boundary stays predictable:

- **One coherent rule** — any task whose endpoint carries a credential (inline
  `api_key` or a resolved `api_key_env`) is gated, whether it is one task or a
  hundred, `generate` or `batch`.
- **Local endpoints are never gated** — `auth = "none"` (a local Qwen-Image or
  LTX-2 server) spends nothing.
- **Missing credentials are not gated** — such a task fails on its missing key
  before it could reach a provider, so you still get that clearer error.
- **No cost estimate** — imagine encodes no price data. It reports
  `cost estimate: unavailable` rather than implying a number.
- **The plan always goes to stderr**, so `--json` stdout stays parseable.
- **`--dry-run` dispatches nothing** and needs no authorization.
- **Authorization is per invocation**, never a config-file key: a shared config
  must not be able to authorize spending silently.

### image composition

Image composition is split into reusable steps. `svg render` turns an SVG into
a transparent PNG at a controlled size. `text render` generates a styled text
SVG layer and renders it to PNG. `png compose` overlays one or more PNG layers
over a base PNG in the order the layers are provided. PNG decoding and encoding
uses vendored `stb_image.h` / `stb_image_write.h`; SVG rendering uses the
`resvg` C API, which **every released binary enables by default**
(`imagine-windows-aarch64.exe` is the one exception — resvg has no
cross-buildable aarch64 Windows static library).

```bash
imagine svg render --input badge.svg -o badge.png --width 256
imagine text render --text "Summer Sale\nBuy 2 Save 50%" -o copy.png --width 900 \
  --font "PingFang SC" --size 72 --color "#ffffff" \
  --stroke "#111111" --stroke-width 3 --align center --line-height 1.18
imagine png compose --base photo.png \
  --layer badge.png,x=24,y=24,opacity=1,blend=normal \
  --layer copy.png,x=80,y=120,opacity=1,blend=normal \
  --layer shadow.png,x=20,y=28,opacity=0.45,blend=multiply \
  -o composed.png
```

`compose` remains as a shortcut for the common one-SVG-over-one-PNG case:

```bash
imagine compose --base photo.png --svg badge.svg -o composed.png --x 24 --y 24 --width 256 --blend=normal
```

| Option | Description |
|--------|-------------|
| `svg render --input <svg>` | SVG input path |
| `svg render -o, --output <png>` | Rendered PNG output path |
| `svg render --width/--height <px>` | Rendered dimensions; one side preserves aspect ratio |
| `text render --text <text>` | Text content; literal `\n` is treated as a line break |
| `text render --font/--size/--color` | Font family, font size, and fill color |
| `text render --stroke/--stroke-width` | Optional SVG text stroke |
| `text render --align/--line-height/--padding` | Text alignment, line-height multiplier, and canvas padding |
| `png compose --base <png>` | Base PNG image |
| `png compose --layer <spec>` | Layer spec: `path.png,x=0,y=0,opacity=1,blend=normal` |
| `png compose -o, --output <png>` | Output PNG path |

Blend modes: `normal`, `multiply`, `screen`, `overlay`, `darken`, `lighten`.
This is useful for product images: text layers usually use `normal`, shadow
layers use `multiply`, highlights use `screen`, and watermarks use `normal`
with reduced `opacity`.

This only matters when building from source — the release assets already have it.
The Makefile default build enables the feature through `-Dsvg-overlay=true` and
needs the resvg C API (0.47.0) on the machine. Build it from source with
`cargo build --release -p resvg-capi` in a checkout of
[`linebender/resvg`](https://github.com/linebender/resvg) (that is what CI does),
or install a packaged copy. Use `make build-core` for a portable core binary
without SVG/text rendering. For headers or libraries in another location, pass:

```bash
zig build -Dsvg-overlay=true -Dresvg-include=/path/to/include -Dresvg-lib=/path/to/lib
```

### Model sizes

Size limits are **provider- and deployment-specific**, not fixed in imagine.
Put preferred sizes in each model's `defaults`, discover models with
`imagine models`, and use `--dry-run` or `--json` `errors[]` when debugging.

`imagine models` reports two separate things per model, because "has a key" and
"can invoke this model" are not the same claim:

| Field | Values | Meaning |
|-------|--------|---------|
| `credential_status` | `missing` / `partial` / `configured` / `not_required` | whether the endpoints' credentials resolve right now |
| `availability` | `unknown` | whether the account may actually invoke the model — not knowable without a paid call, so it is never reported as `ready` |

A key that exists but is not activated for the model (`ModelNotOpen`,
`AccessDenied`) therefore shows up as an ordinary provider error at generation
time, not as a falsely optimistic model listing.

| Backend | Typical params |
|---------|----------------|
| `openai_image` | `--size` (e.g. `1024x1024`); optional `--format` / `--quality` |
| `azure_flux` | `--width` / `--height` (and optional `--seed`) |
| `qwen_image` | `--size` (`WxH` or a native ratio token such as `16:9`), `--steps`, `--seed`, `--format` |
| `volcengine_image` | `--size` (tier `1K`/`2K`/`4K` or `WxH`), `--format`, `--no-watermark` |
| `seedance` | `--duration`, `--resolution`, `--ratio`, `--image`, `--no-watermark` |
| `gemini_video` | `--duration`, `--resolution`, `--ratio`, `--image`, `--seed` |
| `ltx2_video` | `--duration`, `--resolution`, `--ratio`, `--image`, `--seed` |

### Local Qwen-Image-2.1 (optional)

`qwen_image` talks to a [Qwen-Image-2.1](https://huggingface.co/Qwen/Qwen-Image-2.1)
server on your own machine instead of a cloud API. Install one — the model code
lives in the integration, not in the binary:

```bash
integrations/qwen-image/install.sh --prefetch   # venv + deps + weights
qwen-image-server                               # http://127.0.0.1:8000/v1/images/generations
```

Or use vLLM-Omni, which speaks the same request contract:

```bash
vllm serve Qwen/Qwen-Image-2.1 --omni --port 8091
```

```toml
[models."qwen-image-2.1"]
backend = "qwen_image"
api_model = "Qwen/Qwen-Image-2.1"

[[models."qwen-image-2.1".endpoints]]
base_url = "http://127.0.0.1:8000/v1/images/generations"
auth = "none"                 # local servers take no key

[models."qwen-image-2.1".defaults]
size = "1024x1024"            # or a native 2K ratio token: 16:9 4:3 3:2 ...
steps = 20
```

```bash
imagine generate -m qwen-image-2.1 -p "a neon shop sign reading QWEN IMAGE 2.1" -o sign.png
imagine generate -m qwen-image-2.1 -p "a wide sticker sheet of dragons" --size 16:9 --steps 20 -o wide.png
```

`--size` also accepts the model's native ratio tokens (`1:1`, `4:3`, `3:4`,
`3:2`, `2:3`, `16:9`, `9:16`); imagine resolves them to the 2K shapes from the
model card before sending. Transparent (RGBA) output is prompt-driven: ask for
it in the prompt and keep `--format png`. Hardware notes, the editing endpoint,
and troubleshooting live in
[`integrations/qwen-image/README.md`](integrations/qwen-image/README.md).

### Local LTX-2 video (optional)

`ltx2_video` talks to a video service on your own machine (an MLX or PyTorch
LTX-2 build) with the same async flow as the hosted video backends. Weights and
inference stay in that service; the wire contract and a dependency-free
reference server — which adapts any local runtime, including a CLI, through a
command template — live in
[`integrations/ltx2/README.md`](integrations/ltx2/README.md):

```bash
python3 integrations/ltx2/server.py --port 8100 --mock   # wiring check, no weights
```

```toml
[models."ltx-2"]
backend = "ltx2_video"
api_model = "ltx-2"

[[models."ltx-2".endpoints]]
base_url = "http://127.0.0.1:8100/v1/videos/generations"
auth = "none"                 # local servers take no key

[models."ltx-2".defaults]
duration = 6
resolution = "720p"
ratio = "16:9"
```

```bash
imagine generate -m ltx-2 -p "a fox in snow" -o fox.mp4
imagine generate -m ltx-2 --image fox.png -p "the fox turns to camera" -o turn.mp4
```

### batch manifest

```json
{
  "jobs": [
    { "model": "<model-a>", "prompt": "a fox",  "output": "out/fox.png" },
    { "model": "<model-b>", "prompt": "a city", "output": "out/city.png", "width": 1024, "height": 1024, "n": 2 },
    { "model": "<model-c>", "prompt": "a tree", "output": "out/tree.png", "size": "512x512" },
    { "model": "doubao-seedance-2-5-260628", "prompt": "a fox in snow", "output": "out/fox.mp4",
      "duration": 5, "resolution": "720p", "ratio": "16:9" },
    { "model": "gemini-omni-1.1-flash", "prompt": "the fox turns", "output": "out/turn.mp4",
      "image": "fox.png", "resolution": "1080p" }
  ]
}
```

Per-job keys: `model, prompt, output, size, width, height, n, format, compression, quality,
seed, steps, duration, resolution, ratio, image, watermark`.
Use model names from `imagine models` (config models or built-in presets).
`--poll-interval` / `--timeout` apply to every video job in the manifest, and a
manifest whose jobs reach credentialed endpoints needs `--authorize-spend`
exactly like `generate` does.

## Configuration

Path resolution: `--config` > `$IMAGINE_CONFIG` > `~/.imagine/config.toml`.
If the default TOML file does not exist, imagine still tries the legacy
`~/.imagine/config.json` path for backwards compatibility.

A ready-to-edit sample lives at [`config.example.toml`](config.example.toml)
(it shows a model with **two endpoints** for concurrent scheduling). Copy it,
or run `imagine config init` to write the built-in starter:

```bash
cp config.example.toml ~/.imagine/config.toml   # then edit URLs/keys/model names
```

```toml
output_dir = "~/.imagine/outputs"
concurrency = 0     # 0 = auto (endpoint count)
poll_interval = 5   # video: seconds between provider task polls
task_timeout = 600  # video: give up on one task after N seconds

# Table key = logical name for -m; rename freely.
[models."my-image"]
backend = "openai_image" # openai_image | azure_flux  (azure_image = legacy alias)
api_model = "deployment-or-model-id"

[[models."my-image".endpoints]]
base_url = "https://<resource>.services.ai.azure.com/openai/v1/images/generations"
api_key_env = "AZURE_OPENAI_APIKEY" # or api_key = "literal"
auth = "bearer" # bearer | api-key | google_api_key | none  (none = local server)

[models."my-image".defaults]
size = "1024x1024"
output_format = "png"
output_compression = 100
quality = "high"
steps = 40 # qwen_image: num_inference_steps (optional)

# A video model: the create URL goes in base_url, the provider task is polled
# by imagine. `seedance` and `gemini_video` are async; `volcengine_image` is not.
[models."my-video"]
backend = "seedance"
api_model = "doubao-seedance-2-5-260628"

[[models."my-video".endpoints]]
base_url = "https://ark.cn-beijing.volces.com/api/v3/contents/generations/tasks"
api_key_env = "ARK_API_KEY"

[models."my-video".defaults]
duration = 5        # seconds
resolution = "720p" # 480p | 720p | 1080p | 4k
ratio = "16:9"
```

Backends: `openai_image`, `azure_flux`, `qwen_image`, `volcengine_image`,
`seedance`, `gemini_video`. The three provider backends also ship as built-in
presets (see `presets.zig` and `imagine models`) so a first-party model can be
called without a config file; a config entry with the same name wins.

Precedence — params: CLI > model `defaults` > built-in. Keys: endpoint
`api_key` > `api_key_env`. Video task bounds: `--poll-interval`/`--timeout` >
`poll_interval`/`task_timeout` > built-in defaults.

Ephemeral mode (no config file) reads the same knobs from the environment:
`IMAGINE_DURATION`, `IMAGINE_RESOLUTION`, `IMAGINE_RATIO`, `IMAGINE_WATERMARK`,
`IMAGINE_POLL_INTERVAL`, `IMAGINE_TASK_TIMEOUT`. The credential default follows
the backend: `IMAGINE_BACKEND=seedance` looks for `ARK_API_KEY`,
`IMAGINE_BACKEND=gemini_video` for `GEMINI_API_KEY`, everything else for
`AZURE_OPENAI_APIKEY` (override with `IMAGINE_API_KEY_ENV`).

Convert an existing JSON config to TOML:

```bash
imagine config convert --config ~/.imagine/config.json --to toml -o ~/.imagine/config.toml
```

### `--json` result

```json
{ "ok": true, "media": "image", "model": "my-image", "backend": "openai_image",
  "requested": 1, "succeeded": 1, "failed": 0,
  "images": [ { "path": "fox.png", "bytes": 12345 } ],
  "videos": [], "errors": [] }
```

`media` is `image` or `video`, and assets land in the matching array — the other
one is always present and empty, so the shape never changes. `batch` reports one
entry per task with the same `media` field. Providers report video failures
inside an HTTP 200 response body; those surface in `errors[]` with the task id,
e.g. `task cgt-… failed: …`.

## Development

```bash
make build      # zig build -Doptimize=ReleaseFast -Dsvg-overlay=true
make test       # zig build test -Dsvg-overlay=true
make e2e        # end-to-end against a local mock provider (needs python3)
make run ARGS="generate -m <model> -p 'a fox' --dry-run"
make build-core # build without optional svg/text render support
make test-svg
make build RESVG_LIB=/path/to/lib
make fmt        # zig fmt
make help       # list targets
scripts/release.sh 0.4.0   # bump + tag + push + trigger the release workflow
```

Releases are triggered with `scripts/release.sh` (or
`gh workflow run release -f tag=vX.Y.Z`): this repository is a fork, and GitHub
does not start push-triggered workflows for forks, so pushing a tag alone does
not publish anything.

The optional local backend ships its own installer and tests-free server:
`integrations/qwen-image/install.sh --mock` installs a light venv, and
`qwen-image-server --mock` answers `/v1/images/generations` with placeholder
images so the wiring can be checked without a GPU.

Architecture, module boundaries, the "add a backend" recipe, and the roadmap
live in [AGENT.md](AGENT.md). The agent skill lives in
[`skills/imagine`](skills/imagine/SKILL.md).

## License

See [LICENSE](LICENSE).
