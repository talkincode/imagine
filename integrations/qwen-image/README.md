# Qwen-Image-2.1 — the optional local backend

[Qwen-Image-2.1](https://huggingface.co/Qwen/Qwen-Image-2.1) is an open-weights
7B text-to-image / image-editing model. `imagine` reaches it through the
`qwen_image` backend, which sends the OpenAI-style request that Qwen's own
serving stacks accept, so one `imagine` command works against either server:

| Server | How to get it | Why |
|--------|---------------|-----|
| `server.py` (this directory) | `integrations/qwen-image/install.sh` | diffusers `QwenImage21Pipeline`, exactly as the model card uses it; runs wherever Python does |
| [vLLM-Omni](https://github.com/vllm-project/vllm-omni) | `vllm serve Qwen/Qwen-Image-2.1 --omni --port 8091` | higher throughput (prefix KV cache, CUDA graphs, FP8, tensor parallelism) |

This piece is **optional**: with no local server running, every cloud backend
behaves exactly as before. No image code, weights, or Python dependency lives in
the `imagine` binary — it only speaks HTTP.

## 1. Install and start the bundled server

```bash
integrations/qwen-image/install.sh              # venv + dependencies
integrations/qwen-image/install.sh --prefetch   # also download the weights now
qwen-image-server                               # launcher written by the installer
```

`install.sh` creates `~/.imagine/qwen-image/` containing `server.py` and a
self-contained venv, and writes a `qwen-image-server` launcher to
`~/.local/bin`. Nothing is installed system-wide, and your imagine config is
untouched unless you pass `--write-config`.

The checkpoint is ~33 GB, so on a small internal disk put the cache on an
external one — `--hf-home` is recorded in the launcher, so restarts keep using
the same cache:

```bash
integrations/qwen-image/install.sh --hf-home /Volumes/PSSD/qwen-image/hf --prefetch
```

```bash
# Piped install (no checkout needed):
curl -fsSL https://raw.githubusercontent.com/talkincode/imagine/main/integrations/qwen-image/install.sh | sh
curl -fsSL https://raw.githubusercontent.com/talkincode/imagine/main/integrations/qwen-image/install.sh | sh -s -- --prefetch
```

| Option | Effect |
|--------|--------|
| `--home DIR` | install dir (default `~/.imagine/qwen-image`) |
| `--bin-dir DIR` | launcher dir (default `~/.local/bin`) |
| `--python CMD` | interpreter used to create the venv (default `python3`) |
| `--model ID` | checkpoint to serve (default `Qwen/Qwen-Image-2.1`) |
| `--hf-home DIR` | weight cache location (default `$HF_HOME`; point it at an external disk — the checkpoint is ~33 GB) |
| `--prefetch` | download weights into the Hugging Face cache now |
| `--mock` | install only `fastapi`/`uvicorn`/`pillow` — wiring tests, no torch |
| `--write-config` | append the model block below to the imagine config |
| `--no-launcher` | skip the `qwen-image-server` launcher |

Server flags (or the matching `QWEN_IMAGE_*` environment variables):

```bash
qwen-image-server --help
qwen-image-server --port 8000 --steps 40 --size 1024x1024   # defaults
qwen-image-server --offload                                  # small-VRAM GPUs
qwen-image-server --mock                                     # placeholder images
```

The server reports what it is doing on `/healthz` (model, device, dtype,
whether the pipeline is loaded) and lists itself on `/v1/models`.

Hardware: the visual generation component is 7B parameters (~14 GB in bf16),
and the checkpoint ships its text encoder and VAE on top of that — about 33 GB
total, so it needs a CUDA GPU or an Apple Silicon machine with plenty of unified
memory (an M2 Ultra / 64 GB loads it in fp16 on MPS). `--offload` streams
weights per module when memory is tight (the model card's
`enable_model_cpu_offload()`); CPU-only runs are possible but far slower.
Downloads are cached by `huggingface_hub` (`HF_HOME` moves that cache — see
`--hf-home` above).

## 2. Point imagine at it

With a config file (`imagine config init` writes one; `install.sh
--write-config` appends this block):

```toml
[models."qwen-image-2.1"]
backend = "qwen_image"
api_model = "Qwen/Qwen-Image-2.1"

[[models."qwen-image-2.1".endpoints]]
base_url = "http://127.0.0.1:8000/v1/images/generations"
auth = "none"            # a local server takes no credential — no key needed

[models."qwen-image-2.1".defaults]
size = "1024x1024"
steps = 20
```

```bash
imagine models                      # qwen-image-2.1 ... [ready]
imagine generate -m qwen-image-2.1 -p "a neon shop sign reading QWEN IMAGE 2.1" -o sign.png
```

Or with no config file at all (single model, `-m` optional):

```bash
IMAGINE_BASE_URL=http://127.0.0.1:8000/v1/images/generations \
IMAGINE_MODEL=qwen-image-2.1 \
IMAGINE_BACKEND=qwen_image \
IMAGINE_AUTH=none \
  imagine generate -p "a neon Qwen sign" --size 16:9 --steps 40 -o sign.png
```

## 3. Unified parameters

The `qwen_image` backend translates imagine's unified frontend parameters into
the Qwen serving contract — the same flags you use for cloud backends, with no
Qwen-specific syntax:

| imagine | Request field | Notes |
|---------|---------------|-------|
| `-p, --prompt` | `prompt` | required |
| `-m, --model` | `model` | logical name from config; `api_model` is sent |
| `-s, --size` | `size` | `WIDTHxHEIGHT` or an aspect-ratio token (below); server default 1024x1024 |
| `--width/--height` | `size` | combined into `WIDTHxHEIGHT` |
| `-n, --n` | `n` (per call: 1) | imagine fans `-n` into parallel calls, `-c` sets the fan-out |
| repeated `--image` | `image` (one) / `images` (multiple) | up to 10 edit references; local files and fetched URLs are inlined |
| `--steps` | `num_inference_steps` | denoising steps; server default 40 |
| `--seed` | `seed` | reproducible output |
| `--format` | `output_format` | `png` (keeps RGBA) / `webp` (keeps RGBA) / `jpeg` (flattens onto white) |
| `--compression` | `output_compression` | `0-100`; PNG encode level, JPEG/WebP quality |
| `--quality` | *(not sent)* | Qwen-Image quality is a function of `--steps` |

`imagine --dry-run` prints the request body with inline image bytes elided, and
`--json` reports per-image results and errors, for both servers.

### Native aspect ratios

Qwen-Image-2.1 is trained on 2K shapes; `--size` also accepts the model card's
ratio tokens and resolves them to pixels before the request is sent (opt-in —
they cost roughly 6x the time of the 1024 default on Apple Silicon):

| `--size` | pixels |
|----------|--------|
| `1:1` | 2048x2048 |
| `4:3` / `3:4` | 2400x1792 / 1792x2400 |
| `3:2` / `2:3` | 2528x1696 / 1696x2528 |
| `16:9` / `9:16` | 2752x1536 / 1536x2752 |

Anything else (for example `--size 1536x1024`) is passed through unchanged; with
no size at all, the server's default (**1024x1024** — the 2K shapes above are
opt-in) applies. The token lookup happens in `imagine`, because vLLM-Omni
rejects a `size` without an `x`.

### Transparent (RGBA) images

Transparency is prompt-driven, not a flag. Use the model card's phrasing and
save to PNG:

```bash
imagine generate -m qwen-image-2.1 -o sticker.png --steps 40 \
  -p "This is an RGBA image with transparency. A cute cartoon dragon sticker. The image has alpha channel and the background is transparent."
```

## 4. Image editing

Qwen-Image-2.1 is a unified generate/edit model. Repeat `--image` for up to 10
reference images; local files are inlined and URL inputs are fetched before the
request reaches the server:

```bash
# One reference
imagine generate -m qwen-image-2.1 --image input.png \
  -p "Change the background to a sunset beach" -o edited.png

# Multiple references
imagine generate -m qwen-image-2.1 --image subject.png --image style.png \
  -p "Combine the subject with the style of the second image" -o composite.png
```

For one reference, imagine sends the server's `image` string field; for multiple
references it sends an `images` array of data URLs. The bundled server accepts
up to 10 references per request.

Editing is where the model's prefix KV cache pays off; vLLM-Omni is the faster
server for it.

## Smoke test without a GPU

The installer's light mode and the server's `--mock` flag exist so the whole
path — install, HTTP contract, imagine's decode and write-to-disk — can be
checked before downloading 20 GB of weights:

```bash
# 1. light install (fastapi/uvicorn/pillow only, no torch)
integrations/qwen-image/install.sh --mock --write-config

# 2. serve placeholder images on the port the config block above points at
qwen-image-server --mock

# 3. drive it through imagine
imagine generate -m qwen-image-2.1 -p "wiring check" --size 16:9 --steps 8 \
  -o check.png --json
# -> ok=true and check.png is a 2752x1536 RGBA PNG
```

`--dry-run` prints the exact request body, and a bad parameter round-trips the
server's error text, e.g. `--steps 500` ->
`errors: ["HTTP 400: num_inference_steps must be between 1 and 200, got: 500"]`.

## 5. Run it as a macOS LaunchDaemon

`install.sh` leaves the server as a foreground process. To have a Mac serve the
model unattended (starts at boot, restarts after a crash), wrap it in a
LaunchDaemon.

> **macOS gotcha #1 — external volumes.** TCC blocks launchd-spawned processes
> from removable volumes, including as root: a daemon whose venv or weights sit
> under `/Volumes/...` dies with `Operation not permitted` / exit code
> `78: EX_CONFIG`, and even a probe like
> `sudo launchctl submit -l probe -- /bin/ls /Volumes/ExtDISK` is denied. Keep
> the venv **and** the weights on the internal disk
> (`install.sh --home ~/.imagine/qwen-image --hf-home ~/.imagine/qwen-image/hf-home --prefetch`),
> or grant Full Disk Access to the venv's `python` binary in
> System Settings → Privacy & Security → Full Disk Access.

> **macOS gotcha #2 — log directory ownership.** `StandardOutPath` /
> `StandardErrorPath` must be writable by the user the job runs as. A log
> directory created with `sudo mkdir` (owned by `root:wheel`) makes launchd fail
> the job with the same `78: EX_CONFIG` before the program even runs:
> `sudo mkdir -p ~/Library/Logs/qwen-image && sudo chown -R "$(id -un):$(id -gn)" ~/Library/Logs/qwen-image`.

`~/.imagine/qwen-image/server/run-daemon.sh` (waits for the weights, then hands
over — `KeepAlive` restarts it if the process dies):

```sh
#!/bin/sh
ROOT="$HOME/.imagine/qwen-image"
WEIGHTS="$ROOT/weights/Qwen-Image-2.1"
for _ in $(seq 1 120); do
  [ -f "$WEIGHTS/model_index.json" ] && break
  echo "$(date '+%F %T') waiting for $WEIGHTS"
  sleep 5
done
[ -f "$WEIGHTS/model_index.json" ] || exit 1
exec "$ROOT/server/venv/bin/python" "$ROOT/server/server.py" \
  --model "$WEIGHTS" --host 127.0.0.1 --port 8000
```

`/Library/LaunchDaemons/com.imagine.qwen-image.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.imagine.qwen-image</string>
    <key>ProgramArguments</key>
    <array><string>/Users/&lt;you&gt;/.imagine/qwen-image/server/run-daemon.sh</string></array>
    <key>UserName</key><string>&lt;you&gt;</string>
    <key>GroupName</key><string>staff</string>
    <key>EnvironmentVariables</key>
    <dict><key>HF_HOME</key><string>/Users/&lt;you&gt;/.imagine/qwen-image/hf-home</string></dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>ThrottleInterval</key><integer>30</integer>
    <key>WorkingDirectory</key><string>/Users/&lt;you&gt;/.imagine/qwen-image</string>
    <key>StandardOutPath</key><string>/Users/&lt;you&gt;/Library/Logs/qwen-image/daemon.out.log</string>
    <key>StandardErrorPath</key><string>/Users/&lt;you&gt;/Library/Logs/qwen-image/daemon.err.log</string>
</dict>
</plist>
```

```bash
sudo cp com.imagine.qwen-image.plist /Library/LaunchDaemons/
sudo chown root:wheel /Library/LaunchDaemons/com.imagine.qwen-image.plist
sudo chmod 644 /Library/LaunchDaemons/com.imagine.qwen-image.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/com.imagine.qwen-image.plist
sudo launchctl print system/com.imagine.qwen-image | grep -E "state|pid"   # state = running
curl -s http://127.0.0.1:8000/healthz
```

`KeepAlive` is verifiable: `sudo pkill -f server.py` and the job comes back with
`runs = 2` after the throttle interval.

## Troubleshooting

- **`imagine models` shows no key / not ready** — with `auth = "none"` it is
  ready without a credential; check the model name in the config block.
- **Connection refused** — the server is not running, or is on another host:
  the `base_url` must include `/v1/images/generations`.
- **HTTP 400 `size must be WIDTHxHEIGHT`** — the bundled server (like
  vLLM-Omni) takes pixels only; use a token from the table above or `WxH`.
- **First request is slow** — weights load lazily on the first call; watch
  `/healthz` (`"loaded": true`) or start with `--prefetch`.
- **Out of memory** — restart with `--offload`, or lower `--size`/`--steps`.
- **Wiring only** — `qwen-image-server --mock` returns placeholder images so you
  can prove the HTTP path (`imagine ... --json`) before downloading weights.
