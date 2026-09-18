# imagine

[![CI](https://github.com/talkincode/imagine/actions/workflows/ci.yml/badge.svg)](https://github.com/talkincode/imagine/actions/workflows/ci.yml)
[![Release](https://github.com/talkincode/imagine/actions/workflows/release.yml/badge.svg)](https://github.com/talkincode/imagine/actions/workflows/release.yml)

---

![](imagine.png)

---

A universal **image-generation CLI for AI agents**. Unified front-end
parameters, routed to different backends by **configured** model name. One
model can have multiple endpoints (URL + key) for concurrent scheduling.
Single static Zig binary — no `curl`/`jq`/`base64` dependencies.

- **Unified params** → route to a backend by `-m <model>` (names from config).
- **OpenAI-compatible by default** — `openai_image` speaks `/v1/images/generations`.
- **Dynamic models** — add/rename/remove models in config; discover with `imagine models`.
- **Concurrent scheduling** — multiple endpoints per model are load-balanced.
- **Agent-friendly** — `--json` machine output, `--dry-run`, meaningful exit codes.

Also supports Azure FLUX via `azure_flux` (width/height body). Starter config
ships example model entries you can edit freely.


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
imagine models                           # list configured models and readiness (source=file|ephemeral)

# Use a model name printed by `imagine models` (not a fixed name from docs):
imagine generate -m <model> -p "A photograph of a red fox in an autumn forest" -o fox.png
imagine generate -m <model> -p "a city at dusk" --width 1024 --height 1024 -o city.png
imagine generate -m <model> -p "logo concept" -n 4 -o logo.png -c 4

# No config file — ephemeral env (single model; -m optional):
IMAGINE_BASE_URL="https://host/.../images/generations" \
IMAGINE_MODEL="MAI-Image-2.6-Flash" AZURE_OPENAI_APIKEY="..." \
  imagine generate -p "a fox" -o fox.png
```

## Commands

```
imagine generate -m <model> -p <prompt> [options]
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
| `-c, --concurrency <n>` | Parallel requests (default: endpoint count) |
| `--config <path>` | Use a specific config file |
| `--json` | Emit a JSON result object |
| `--dry-run` | Print request body without calling the API |
| `-q, --quiet` | Suppress progress |

Exit codes: `0` success · `1` run failure (incl. partial) · `2` usage error.

### image composition

Image composition is split into reusable steps. `svg render` turns an SVG into
a transparent PNG at a controlled size. `text render` generates a styled text
SVG layer and renders it to PNG. `png compose` overlays one or more PNG layers
over a base PNG in the order the layers are provided. PNG decoding and encoding
uses vendored `stb_image.h` / `stb_image_write.h`; SVG rendering uses the
optional `resvg` C API build.

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

The Makefile default build enables this feature through `-Dsvg-overlay=true`;
install the `resvg` C API library first. Use `make build-core` for a portable
core binary without SVG/text rendering. If you need to use headers or libraries
from another location, pass:

```bash
zig build -Dsvg-overlay=true -Dresvg-include=/path/to/include -Dresvg-lib=/path/to/lib
```

### Model sizes

Size limits are **provider- and deployment-specific**, not fixed in imagine.
Put preferred sizes in each model's `defaults`, discover models with
`imagine models`, and use `--dry-run` or `--json` `errors[]` when debugging.

| Backend | Typical params |
|---------|----------------|
| `openai_image` | `--size` (e.g. `1024x1024`); optional `--format` / `--quality` |
| `azure_flux` | `--width` / `--height` (and optional `--seed`) |

### batch manifest

```json
{
  "jobs": [
    { "model": "<model-a>", "prompt": "a fox",  "output": "out/fox.png" },
    { "model": "<model-b>", "prompt": "a city", "output": "out/city.png", "width": 1024, "height": 1024, "n": 2 },
    { "model": "<model-c>", "prompt": "a tree", "output": "out/tree.png", "size": "512x512" }
  ]
}
```

Per-job keys: `model, prompt, output, size, width, height, n, format, compression, quality, seed`.
Use model names from `imagine models`.

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
concurrency = 0 # 0 = auto (endpoint count)

# Table key = logical name for -m; rename freely.
[models."my-image"]
backend = "openai_image" # openai_image | azure_flux  (azure_image = legacy alias)
api_model = "deployment-or-model-id"

[[models."my-image".endpoints]]
base_url = "https://<resource>.services.ai.azure.com/openai/v1/images/generations"
api_key_env = "AZURE_OPENAI_APIKEY" # or api_key = "literal"
auth = "bearer" # bearer | api-key

[models."my-image".defaults]
size = "1024x1024"
output_format = "png"
output_compression = 100
quality = "high"
```

Precedence — params: CLI > model `defaults` > built-in. Keys: endpoint
`api_key` > `api_key_env`.

Convert an existing JSON config to TOML:

```bash
imagine config convert --config ~/.imagine/config.json --to toml -o ~/.imagine/config.toml
```

### `--json` result

```json
{ "ok": true, "model": "my-image", "backend": "openai_image",
  "requested": 1, "succeeded": 1, "failed": 0,
  "images": [ { "path": "fox.png", "bytes": 12345 } ], "errors": [] }
```

## Development

```bash
make build      # zig build -Doptimize=ReleaseFast -Dsvg-overlay=true
make test       # zig build test -Dsvg-overlay=true
make run ARGS="generate -m <model> -p 'a fox' --dry-run"
make build-core # build without optional svg/text render support
make test-svg
make build RESVG_LIB=/path/to/lib
make fmt        # zig fmt
make help       # list targets
```

Architecture, module boundaries, the "add a backend" recipe, and the roadmap
live in [AGENT.md](AGENT.md). The agent skill lives in
[`skills/imagine`](skills/imagine/SKILL.md).

## License

See [LICENSE](LICENSE).
