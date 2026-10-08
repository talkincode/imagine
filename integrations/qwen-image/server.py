#!/usr/bin/env python3
"""Qwen-Image-2.1 local image server (OpenAI-compatible images API).

Serves `Qwen/Qwen-Image-2.1` through the same request contract as Qwen's own
serving stacks, so the two are interchangeable behind one `imagine` backend:

    POST /v1/images/generations
    {
      "model": "Qwen/Qwen-Image-2.1",
      "prompt": "a ceramic teapot on a wooden table",
      "size": "2048x2048",          # WIDTHxHEIGHT, optional (default 2048x2048)
      "n": 1,                        # optional, 1..8
      "num_inference_steps": 40,     # optional (imagine: --steps)
      "seed": 42,                    # optional
      "output_format": "png",        # png (keeps RGBA) | jpeg | webp
      "output_compression": 100      # optional, 0..100
    }
    -> { "created": 1758..., "data": [ { "b64_json": "..." } ],
         "size": "2048x2048", "output_format": "png" }

    GET  /healthz      -> liveness + model/device currently in use
    GET  /v1/models    -> the single served model

Errors use the OpenAI body `{"error": {"message": ...}}`, which is what
`imagine` parses for its `--json` `errors[]` field.

An optional `image` field or `images` list accepts up to 10 base64 (or
`data:image/png;base64,...`) reference images for Qwen-Image-2.1 editing.
`imagine` maps repeated `--image` flags to the matching singular or plural field.

Usage:  python3 server.py [options]     (see --help, or run ./install.sh)
"""

from __future__ import annotations

import argparse
import base64
import io
import os
import threading
import time
from typing import Any

DEFAULT_MODEL = "Qwen/Qwen-Image-2.1"
# 1024 keeps one image near a minute on Apple Silicon; the model card's native
# 2K shapes stay available by asking for them (--size 16:9, --size 2048x2048).
DEFAULT_SIZE = (1024, 1024)
DEFAULT_STEPS = 40
MAX_IMAGES = 8
OUTPUT_FORMATS = ("png", "jpeg", "webp")


# ---------------------------------------------------------------------------
# request helpers
# ---------------------------------------------------------------------------


def parse_size(raw: str) -> tuple[int, int]:
    """`WIDTHxHEIGHT` -> (width, height). Raises ValueError on anything else."""
    text = str(raw).strip().lower().replace(" ", "")
    parts = text.split("x")
    if len(parts) != 2 or not all(p.isdigit() for p in parts):
        raise ValueError(f"size must be WIDTHxHEIGHT (e.g. 2048x2048), got: {raw!r}")
    width, height = (int(p) for p in parts)
    if width < 64 or height < 64:
        raise ValueError(f"size must be at least 64x64, got: {raw!r}")
    return width, height


def parse_int(value: Any, name: str, low: int, high: int) -> int:
    try:
        number = int(value)
    except (TypeError, ValueError):
        raise ValueError(f"{name} must be an integer, got: {value!r}") from None
    if not low <= number <= high:
        raise ValueError(f"{name} must be between {low} and {high}, got: {number}")
    return number


def decode_image(value: str):
    """Accept raw base64 or a `data:` URL and return a PIL image."""
    from PIL import Image  # imported lazily: only editing needs it

    payload = value.split(",", 1)[1] if value.startswith("data:") else value
    with Image.open(io.BytesIO(base64.b64decode(payload))) as image:
        return image.convert("RGBA")


def encode_image(image, output_format: str, compression: int) -> str:
    """Encode a PIL image to base64 in the requested output format."""
    buf = io.BytesIO()
    if output_format == "png":
        # PNG is the lossless option, and the one that keeps RGBA.
        # 100 = fastest encode (least compression); 1 = smallest file.
        level = 0 if compression >= 100 else max(0, min(9, round((100 - compression) * 9 / 99)))
        image.save(buf, "PNG", compress_level=level)
    elif output_format == "jpeg":
        # JPEG has no alpha channel: flatten transparency onto white first,
        # otherwise transparent pixels encode as black.
        from PIL import Image

        flat = Image.new("RGB", image.size, (255, 255, 255))
        flat.paste(image, mask=image.split()[-1] if image.mode == "RGBA" else None)
        flat.save(buf, "JPEG", quality=compression)
    else:
        image.save(buf, "WEBP", quality=compression)
    return base64.b64encode(buf.getvalue()).decode("ascii")


# ---------------------------------------------------------------------------
# model / mock pipeline
# ---------------------------------------------------------------------------


class ImagePipeline:
    """Diffusers `QwenImage21Pipeline` behind a load-once, run-one-at-a-time gate.

    Denoising saturates a device, so requests are serialized: ask for `n > 1`
    (or `imagine -n`) instead of firing parallel requests at one GPU.
    """

    def __init__(self, model: str, device: str, dtype: str, offload: bool, mock: bool):
        self.model = model
        self.device = device
        self.dtype = dtype
        self.offload = offload
        self.mock = mock
        self._pipe = None
        self._lock = threading.Lock()

    @property
    def loaded(self) -> bool:
        return self._pipe is not None

    def _load(self):
        if self._pipe is not None:
            return self._pipe

        import torch
        from diffusers import QwenImage21Pipeline

        torch_dtype = {"bfloat16": torch.bfloat16, "float16": torch.float16}.get(
            self.dtype, torch.float32
        )
        print(f"loading {self.model} (device={self.device}, dtype={self.dtype}) ...", flush=True)
        pipe = QwenImage21Pipeline.from_pretrained(self.model, torch_dtype=torch_dtype)
        if self.offload:
            # Streams weights per module: slower, but fits small GPUs.
            pipe.enable_model_cpu_offload()
        else:
            pipe.to(self.device)
        self._pipe = pipe
        print("model ready", flush=True)
        return pipe

    def generate(
        self,
        prompt: str,
        width: int,
        height: int,
        steps: int,
        seed: int | None,
        reference_images: list[Any] | None = None,
    ):
        with self._lock:
            if self.mock:
                return mock_image(prompt, width, height, seed)

            import torch

            pipe = self._load()
            generator = None
            if seed is not None:
                generator = torch.Generator("cpu").manual_seed(int(seed))
            kwargs: dict[str, Any] = {
                "prompt": prompt,
                "width": width,
                "height": height,
                "num_inference_steps": steps,
                "generator": generator,
            }
            if reference_images:
                # A single reference keeps the plain `image=` path; several use
                # the up-to-10 reference list the model supports.
                kwargs["image"] = (
                    reference_images[0] if len(reference_images) == 1 else reference_images
                )
            return pipe(**kwargs).images[0]


def mock_image(prompt: str, width: int, height: int, seed: int | None = None):
    """Deterministic placeholder, so the HTTP wiring is testable without a GPU.

    Transparent canvas plus a semi-transparent band, so a generated file shows
    the real width/height and proves the alpha channel survived the round trip.
    """
    from PIL import Image, ImageDraw, ImageFont

    digest = sum(prompt.encode("utf-8")) + (seed or 0)
    color = (digest * 7 % 256, digest * 13 % 256, digest * 29 % 256, 255)

    image = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    unit = max(4, min(width, height) // 24)
    inset = unit * 3
    draw.rounded_rectangle((inset, inset, width - inset, height - inset), radius=unit * 2, fill=color)
    draw.rectangle(
        (inset, height - inset - unit * 2, width - inset, height - inset - unit),
        fill=color[:3] + (110,),  # 43% alpha: visible only if alpha survived
    )

    font_size = max(14, min(width, height) // 24)
    try:  # Pillow >= 10 can size the built-in bitmap font; older ones cannot.
        font = ImageFont.load_default(size=font_size)
    except TypeError:
        font = ImageFont.load_default()

    import textwrap

    wraps_at = max(20, int((width - inset * 4) / (font_size * 0.55)))
    lines = textwrap.wrap(prompt, width=wraps_at)[:3] or [""]
    if len(lines) == 3 and len("".join(lines)) < len(prompt):
        lines[2] = lines[2][: max(1, wraps_at - 3)] + "..."
    label = "mock - not model output\n{d}x{d}  seed={s}\nprompt: {p}".format(
        width, height, seed, "\n        ".join(lines)
    )
    text_xy = (inset + unit * 2, inset + unit * 2)
    box = draw.multiline_textbbox(text_xy, label, font=font, spacing=unit)
    pad = unit
    draw.rectangle((box[0] - pad, box[1] - pad, box[2] + pad, box[3] + pad), fill=(255, 255, 255, 230))
    draw.multiline_text(text_xy, label, fill=(20, 20, 20, 255), font=font, spacing=unit)
    return image


# ---------------------------------------------------------------------------
# HTTP API
# ---------------------------------------------------------------------------


def create_app(config: argparse.Namespace):
    from fastapi import Body, FastAPI, HTTPException
    from fastapi.responses import JSONResponse

    pipeline = ImagePipeline(
        model=config.model,
        device=config.device,
        dtype=config.dtype,
        offload=config.offload,
        mock=config.mock,
    )
    started = time.time()
    app = FastAPI(title="qwen-image", version="2.1", docs_url="/docs", redoc_url=None)

    @app.exception_handler(HTTPException)
    async def openai_error(_request, exc: HTTPException):
        # imagine reads `error.message`; keep every failure in that shape.
        return JSONResponse(
            status_code=exc.status_code,
            content={"error": {"message": exc.detail, "type": "invalid_request_error"}},
        )

    @app.get("/healthz")
    def healthz():
        return {
            "ok": True,
            "model": pipeline.model,
            "device": pipeline.device,
            "dtype": pipeline.dtype,
            "mock": pipeline.mock,
            "loaded": pipeline.loaded,
            "uptime_seconds": round(time.time() - started, 1),
        }

    @app.get("/v1/models")
    def list_models():
        return {
            "object": "list",
            "data": [{"id": pipeline.model, "object": "model", "owned_by": "local"}],
        }

    @app.post("/v1/images/generations")
    def generate(payload: dict = Body(...)):
        if payload.get("response_format", "b64_json") != "b64_json":
            raise HTTPException(400, "only response_format=b64_json is supported")

        prompt = payload.get("prompt")
        if not isinstance(prompt, str) or not prompt.strip():
            raise HTTPException(400, "prompt is required")

        try:
            width, height = parse_size(payload["size"]) if payload.get("size") else DEFAULT_SIZE
            n = parse_int(payload.get("n", 1), "n", 1, MAX_IMAGES)
            steps = parse_int(
                payload.get("num_inference_steps", config.steps), "num_inference_steps", 1, 200
            )
            compression = parse_int(
                payload.get("output_compression", 100), "output_compression", 0, 100
            )
            seed = payload.get("seed")
            if seed is not None:
                seed = parse_int(seed, "seed", -(2**63), 2**63 - 1)
            output_format = str(payload.get("output_format", "png")).lower()
            if output_format not in OUTPUT_FORMATS:
                raise ValueError(f"output_format must be one of {OUTPUT_FORMATS}")

            references = payload.get("images") or payload.get("image")
            if references is not None and not isinstance(references, list):
                references = [references]
            if references is not None and len(references) > 10:
                raise ValueError("at most 10 reference images are supported")
        except ValueError as err:
            raise HTTPException(400, str(err)) from None

        images = []
        for index in range(n):
            # Offset the seed per image so `n > 1` never returns duplicates.
            image_seed = None if seed is None else seed + index
            try:
                reference_images = [decode_image(r) for r in references] if references else None
                image = pipeline.generate(
                    prompt=prompt,
                    width=width,
                    height=height,
                    steps=steps,
                    seed=image_seed,
                    reference_images=reference_images,
                )
            except HTTPException:
                raise
            except Exception as err:  # noqa: BLE001 - surfaced to the caller as a 500
                raise HTTPException(500, f"generation failed: {err}") from err
            images.append({"b64_json": encode_image(image, output_format, compression)})

        return {
            "created": int(time.time()),
            "data": images,
            "size": f"{width}x{height}",
            "output_format": output_format,
        }

    return app


# ---------------------------------------------------------------------------
# entry point
# ---------------------------------------------------------------------------


def pick_device(requested: str) -> str:
    if requested != "auto":
        return requested
    try:
        import torch
    except ImportError:
        return "cpu"
    if torch.cuda.is_available():
        return "cuda"
    if torch.backends.mps.is_available():
        return "mps"
    return "cpu"


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Qwen-Image-2.1 local image server")
    env = os.environ.get
    parser.add_argument("--model", default=env("QWEN_IMAGE_MODEL", DEFAULT_MODEL))
    parser.add_argument(
        "--device", default=env("QWEN_IMAGE_DEVICE", "auto"), help="auto|cuda|mps|cpu"
    )
    parser.add_argument(
        "--dtype",
        default=env("QWEN_IMAGE_DTYPE", ""),
        help="bfloat16|float16|float32 (default: bfloat16 on CUDA, float16 on MPS, float32 on CPU)",
    )
    parser.add_argument(
        "--offload",
        action="store_true",
        default=env("QWEN_IMAGE_OFFLOAD", "") not in ("", "0"),
        help="stream weights per module (fits small GPUs, slower)",
    )
    parser.add_argument("--steps", type=int, default=int(env("QWEN_IMAGE_STEPS", DEFAULT_STEPS)))
    parser.add_argument("--size", default=env("QWEN_IMAGE_SIZE", ""), help="default WIDTHxHEIGHT")
    parser.add_argument("--host", default=env("QWEN_IMAGE_HOST", "127.0.0.1"))
    parser.add_argument("--port", type=int, default=int(env("QWEN_IMAGE_PORT", "8000")))
    parser.add_argument(
        "--mock",
        action="store_true",
        default=env("QWEN_IMAGE_MOCK", "") not in ("", "0"),
        help="return placeholder images: checks wiring without torch/weights",
    )
    parser.add_argument("--log-level", default=env("QWEN_IMAGE_LOG_LEVEL", "info"))
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    args.device = "cpu" if args.mock else pick_device(args.device)
    # Half precision matters: float32 would double a ~33 GB checkpoint. CUDA
    # prefers bf16, Metal has native fp16, and CPU only realistically runs fp32.
    half = {"cuda": "bfloat16", "mps": "float16"}
    args.dtype = args.dtype or half.get(args.device, "float32")
    if args.size:
        try:
            parse_size(args.size)  # fail fast on a bad default
        except ValueError as err:
            print(f"error: {err}", flush=True)
            return 2

    import uvicorn

    print(
        f"qwen-image server: model={args.model} device={args.device} dtype={args.dtype} "
        f"offload={args.offload} mock={args.mock}",
        flush=True,
    )
    if args.size:
        print(f"default size: {args.size}", flush=True)
    print(f"listening on http://{args.host}:{args.port}/v1/images/generations", flush=True)
    uvicorn.run(create_app(args), host=args.host, port=args.port, log_level=args.log_level, workers=1)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
