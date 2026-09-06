---
name: imagine
description: Use the imagine CLI to call multiple image-generation model APIs, including Azure gpt-image-1.5, gpt-image-2, and FLUX.2-pro. Use for text-to-image generation, batch generation, routing by model name, distributing one model across multiple endpoints, and parsing machine-readable --json results. Check whether the imagine binary is installed first, and guide installation when it is missing.
---

# imagine - Universal Image Generation CLI Skill

`imagine` is a universal image-generation CLI for AI agents. It provides one
frontend parameter set, routes requests to backends by model name, and can
distribute one logical model across multiple endpoints (URL + key) for
concurrent scheduling. It is a single static Zig binary and does not require
`curl`, `jq`, or `base64`.

## When To Use This Skill

- Generate one or more images from a text prompt and save them to disk.
- Run batch generation from a JSON manifest with multiple jobs.
- Overlay an SVG on a PNG with `compose` when the binary was built with optional
  `resvg` support.
- Use `--json` when an agent needs structured output.
- Inspect or initialize config, or troubleshoot missing models and credentials.

Configured models come from `~/.imagine/config.toml`. The legacy
`~/.imagine/config.json` path is still supported for compatibility. The starter
template includes `gpt-image-1.5`, `gpt-image-2`, and `FLUX.2-pro`.

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
curl -fsSL https://raw.githubusercontent.com/talkincode/imagine/main/install.sh | sh

# Option B: source install for development or unsupported prebuilt platforms.
# Requires Zig >= 0.16.0.
make install
```

After installation, make sure `~/.local/bin` is on PATH if needed, then verify
again with `imagine version`.

Linux and macOS can use the one-line installer. Windows users should download
`imagine-windows-x86_64.exe` or `imagine-windows-aarch64.exe` from the latest
release and put it on PATH. The one-line installer only downloads prebuilt
artifacts; use `IMAGINE_VERSION=v0.1.2` to pin a release. If no prebuilt binary
exists for the platform, build from source with Zig >= 0.16.0.

## Step 1: Configure

The default config path is `~/.imagine/config.toml`. Override it with
`$IMAGINE_CONFIG` or `--config <path>`.

```bash
imagine config path          # print the resolved config path
imagine config init          # write the starter config; use --force to overwrite
imagine config convert --config ~/.imagine/config.json --to toml -o ~/.imagine/config.toml
imagine config show          # print effective config with keys redacted
imagine models               # list configured models and readiness
imagine models --json        # machine-readable model list
```

Credential precedence is endpoint `api_key` literal value first, then the
environment variable named by endpoint `api_key_env`. The starter template reads
from `AZURE_API_KEY`:

```bash
export AZURE_API_KEY="your-azure-key"
```

To distribute requests across multiple endpoints, add multiple `endpoints`
tables under the same model. When generating multiple images, imagine fans
requests across those endpoints.

## Step 2: Generate

```bash
# Single image with gpt-image-1.5
imagine generate -m gpt-image-1.5 -p "A photograph of a red fox in an autumn forest" -o fox.png

# FLUX uses width/height
imagine generate -m FLUX.2-pro -p "a city at dusk" --width 1024 --height 1024 -o city.png

# Multiple images with concurrency; filenames get numbered automatically
imagine generate -m gpt-image-2 -p "logo concept" -n 4 -o logo.png -c 4

# Inspect the request body without calling the API
imagine generate -m gpt-image-1.5 -p "test" --dry-run

# Structured output for agents
imagine generate -m gpt-image-1.5 -p "a red fox" -o fox.png --json
```

Common options:

| Option | Description |
|--------|-------------|
| `-m, --model` | Model name to route to. Required. |
| `-p, --prompt` | Prompt text. Required, or pass it as a positional argument. |
| `-o, --output` | Output file for one image, or output stem for multiple images. |
| `-n, --n` | Number of images. Default: 1. |
| `-s, --size` | Size for gpt-image models. See model size notes below. |
| `--width / --height` | Dimensions for FLUX models; use instead of `--size`. |
| `--format` | `png` or `jpeg` for gpt-image output. WebP is not supported. |
| `--compression` | Output compression from `0` to `100` for gpt-image output. |
| `--quality` | `low`, `medium`, `high`, or `auto` for gpt-image output. |
| `--seed` | Seed where supported. |
| `-c, --concurrency` | Parallel requests. Default: endpoint count. |
| `--config` | Use a specific config file. |
| `--json` | Emit a JSON result object. |
| `--dry-run` | Print the request body without calling the API. |
| `-q, --quiet` | Suppress progress output. |

### Model Sizes

| Model | Size constraints |
|-------|------------------|
| `gpt-image-1.5` | `--size` must be `1024x1024`, `1536x1024`, `1024x1536`, or `auto`. |
| `gpt-image-2` | `--size` can be any `WxH` where both sides are multiples of 16 and the longest edge is <= 3840, subject to the provider's minimum pixel budget. |
| `FLUX.2-pro` | Use `--width/--height`; each side must be >= 64 and `width * height <= 4 MP` (up to `2048x2048`). No 16-pixel divisibility requirement. |

Unsupported sizes return provider errors. Use `--dry-run` to inspect request
bodies, or parse `errors[]` from `--json` output when a run fails.

## Step 3: Batch Generation

```bash
imagine batch jobs.json -c 4
```

`jobs.json` format:

```json
{
  "jobs": [
    { "model": "gpt-image-1.5", "prompt": "a fox",  "output": "out/fox.png" },
    { "model": "FLUX.2-pro",    "prompt": "a city", "output": "out/city.png", "width": 1024, "height": 1024, "n": 2 },
    { "model": "gpt-image-2",   "prompt": "a tree", "output": "out/tree.png", "size": "512x512" }
  ]
}
```

Each job supports: `model`, `prompt`, `output`, `size`, `width`, `height`, `n`,
`format`, `compression`, `quality`, and `seed`.

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
  { "ok": true, "model": "...", "backend": "azure_image",
    "requested": 1, "succeeded": 1, "failed": 0,
    "images": [ { "path": "fox.png", "bytes": 12345 } ], "errors": [] }
  ```
- Parse `images[].path` to find generated files. When `ok=false`, read
  `errors[]`.
- Run `imagine models --json` first when you need to confirm that a model has
  `ready=true` before generation.
- Use `--dry-run` when parameters are uncertain.

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `IMAGINE_CONFIG` | Override the config path. Default: `~/.imagine/config.toml`. |
| `AZURE_API_KEY` | Default Azure credential source used by the starter config. You can change `api_key_env` in config. |

## Troubleshooting

- `model 'X' not found`: run `imagine models` to inspect configured models, or
  run `imagine config init` to create a starter config.
- `missing credential`: set the configured environment variable, defaulting to
  `AZURE_API_KEY`, or set endpoint `api_key`.
- `HTTP 4xx/5xx`: the error comes from the provider API, such as policy,
  quota, or authentication failures.
- Slow generation or rate limits: configure multiple `endpoints` for the model
  and increase `-c`.
