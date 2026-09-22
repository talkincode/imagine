//! Qwen-Image text-to-image (`QwenImage21Pipeline`, 2.1 default) served by a
//! local OpenAI-compatible endpoint.
//!
//! Image quality here is a function of denoising steps, not of a `quality`
//! label, so this backend sends `num_inference_steps` (the unified `--steps`)
//! and drops the OpenAI-only `quality` field. The wire contract is the one the
//! official Qwen serving stacks expose:
//!
//!   * bundled diffusers server — `integrations/qwen-image/`
//!   * vLLM-Omni — `vllm serve Qwen/Qwen-Image-2.1 --omni --port 8091`
//!
//! Both accept
//! `{model, prompt, n, size, num_inference_steps, seed, output_format,
//! output_compression}` and answer with the OpenAI `{ "data": [...] }` shape
//! that `backend.parseResponse` already decodes. Because the two servers speak
//! the same contract, the same command works against either one.

const std = @import("std");
const types = @import("../types.zig");

/// Native 2K shapes from the Qwen-Image-2.1 model card. Accepting the ratio
/// token (e.g. `--size 16:9`) here, in the client, keeps the wire format
/// `WIDTHxHEIGHT` — vLLM-Omni rejects anything without an `x`.
const AspectRatio = struct { ratio: []const u8, width: u32, height: u32 };
const aspect_ratios = [_]AspectRatio{
    .{ .ratio = "1:1", .width = 2048, .height = 2048 },
    .{ .ratio = "4:3", .width = 2400, .height = 1792 },
    .{ .ratio = "3:4", .width = 1792, .height = 2400 },
    .{ .ratio = "3:2", .width = 2528, .height = 1696 },
    .{ .ratio = "2:3", .width = 1696, .height = 2528 },
    .{ .ratio = "16:9", .width = 2752, .height = 1536 },
    .{ .ratio = "9:16", .width = 1536, .height = 2752 },
};

/// The `WIDTHxHEIGHT` string for a ratio token, if `s` is one.
fn aspectRatioSize(s: []const u8) ?AspectRatio {
    const t = std.mem.trim(u8, s, " \t");
    for (aspect_ratios) |ar| {
        if (std.mem.eql(u8, t, ar.ratio)) return ar;
    }
    return null;
}

/// Unified `--size` / `--width`+`--height` -> `WIDTHxHEIGHT`, or null to let
/// the server apply its own default (2048x2048). Derived strings live in the
/// caller's `buf`, so building a body needs no allocation of its own.
fn resolveSize(buf: []u8, req: types.GenRequest) ?[]const u8 {
    if (req.size) |s| {
        if (aspectRatioSize(s)) |ar| {
            return std.fmt.bufPrint(buf, "{d}x{d}", .{ ar.width, ar.height }) catch null;
        }
        return s;
    }
    if (req.width != null and req.height != null) {
        return std.fmt.bufPrint(buf, "{d}x{d}", .{ req.width.?, req.height.? }) catch null;
    }
    return null;
}

pub fn buildBody(allocator: std.mem.Allocator, req: types.GenRequest) ![]u8 {
    const Body = struct {
        model: []const u8,
        prompt: []const u8,
        n: u32,
        size: ?[]const u8,
        num_inference_steps: ?u32,
        seed: ?i64,
        output_format: ?[]const u8,
        output_compression: ?u32,
    };

    var size_buf: [32]u8 = undefined;

    const body = Body{
        .model = req.api_model,
        .prompt = req.prompt,
        .n = req.n,
        .size = resolveSize(&size_buf, req),
        .num_inference_steps = req.steps,
        .seed = req.seed,
        .output_format = req.output_format,
        .output_compression = req.output_compression,
    };

    return std.json.Stringify.valueAlloc(allocator, body, .{ .emit_null_optional_fields = false });
}

// ---- tests ----

test "qwen_image maps an aspect-ratio token to native 2K size" {
    const a = std.testing.allocator;
    const req = types.GenRequest{ .prompt = "a fox", .api_model = "Qwen/Qwen-Image-2.1", .size = "16:9" };
    const body = try buildBody(a, req);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"size\":\"2752x1536\"") != null);
}

test "qwen_image passes an explicit size through" {
    const a = std.testing.allocator;
    const req = types.GenRequest{ .prompt = "x", .api_model = "m", .size = "1024x768" };
    const body = try buildBody(a, req);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"size\":\"1024x768\"") != null);
}

test "qwen_image derives size from width/height" {
    const a = std.testing.allocator;
    const req = types.GenRequest{ .prompt = "x", .api_model = "m", .width = 512, .height = 768 };
    const body = try buildBody(a, req);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"size\":\"512x768\"") != null);
}

test "qwen_image sends steps/seed/format and omits nulls" {
    const a = std.testing.allocator;
    const req = types.GenRequest{
        .prompt = "x",
        .api_model = "m",
        .n = 1,
        .steps = 25,
        .seed = 42,
        .output_format = "png",
        .output_compression = 100,
        .quality = "high",
    };
    const body = try buildBody(a, req);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"num_inference_steps\":25") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"seed\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"output_format\":\"png\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"output_compression\":100") != null);
    // `quality` is an OpenAI-images knob; Qwen quality is controlled by steps.
    try std.testing.expect(std.mem.indexOf(u8, body, "quality") == null);
}

test "qwen_image omits size/steps/seed when unset" {
    const a = std.testing.allocator;
    const req = types.GenRequest{ .prompt = "x", .api_model = "m" };
    const body = try buildBody(a, req);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "size") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "num_inference_steps") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "seed") == null);
}
