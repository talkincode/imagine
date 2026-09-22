//! Volcengine Ark image generation (Seedream).
//!
//!   POST https://ark.cn-beijing.volces.com/api/v3/images/generations
//!   Authorization: Bearer $ARK_API_KEY
//!
//! Synchronous, and OpenAI-shaped on the response side (`data[].url` or
//! `data[].b64_json`), so the shared `backend.parseResponse` decodes it. The
//! request side is not OpenAI-shaped though:
//!
//!   * `size` takes a tier (`1K` / `2K` / `4K`) or explicit `WxH` pixels;
//!   * there is no `n` (a batch is one *sequential* request) and no `seed`;
//!   * `watermark` defaults to **true** on Ark, so `--no-watermark` is the only
//!     way to get a clean image;
//!   * `output_format` defaults to `jpeg` on Ark while `imagine`'s default
//!     output name is `.png`, so an unset format is pinned to `png` to keep the
//!     bytes and the file extension in agreement;
//!   * `image` carries a reference image (URL or `data:` URL) for editing.
//!
//! Because the scheduler fans `-n` into independent requests, this backend
//! never sends Ark's `sequential_image_generation` — `-n 4` means four calls,
//! the same rule as every other image backend.

const std = @import("std");
const types = @import("../types.zig");
const util = @import("../util.zig");

pub fn buildBody(allocator: std.mem.Allocator, req: types.GenRequest) ![]u8 {
    const Body = struct {
        model: []const u8,
        prompt: []const u8,
        size: ?[]const u8,
        output_format: []const u8,
        response_format: []const u8,
        watermark: ?bool,
        image: ?[]const u8,
    };

    var size_buf: [32]u8 = undefined;
    const size: ?[]const u8 = req.size orelse blk: {
        if (req.width != null and req.height != null) {
            break :blk std.fmt.bufPrint(&size_buf, "{d}x{d}", .{ req.width.?, req.height.? }) catch null;
        }
        break :blk null;
    };

    const body = Body{
        .model = req.api_model,
        .prompt = req.prompt,
        .size = size,
        .output_format = req.output_format orelse "png",
        // Always download through the URL form: Ark's URLs live 24 hours, and
        // the generic downloader keeps every backend's payload path identical.
        .response_format = "url",
        .watermark = req.watermark,
        .image = if (req.image) |img| try imageRef(allocator, img) else null,
    };

    return std.json.Stringify.valueAlloc(allocator, body, .{ .emit_null_optional_fields = false });
}

/// Ark takes a reference image as an HTTPS URL or a base64 `data:` URL.
fn imageRef(allocator: std.mem.Allocator, img: types.InputImage) ![]const u8 {
    const bytes = img.bytes orelse return img.source;
    return util.dataUrlAlloc(allocator, bytes, img.mime);
}

// ---- tests ----

test "volcengine_image body: tier size, pinned png, no n or seed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const req = types.GenRequest{
        .prompt = "a neon city",
        .api_model = "doubao-seedream-5-0-260128",
        .size = "2K",
        .watermark = false,
    };
    const body = try buildBody(a, req);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"size\":\"2K\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"output_format\":\"png\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"response_format\":\"url\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"watermark\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"n\"") == null);
    // No `seed` field: Ark image generation does not take one.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"seed\"") == null);
}

test "volcengine_image derives size from width/height and honours --format" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const req = types.GenRequest{
        .prompt = "x",
        .api_model = "m",
        .width = 2048,
        .height = 2048,
        .output_format = "jpeg",
    };
    const body = try buildBody(a, req);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"size\":\"2048x2048\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"output_format\":\"jpeg\"") != null);
    // `seed` is not an Ark image parameter; a caller-supplied seed is dropped.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"seed\"") == null);
}

test "volcengine_image sends a reference image as a data URL" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const req = types.GenRequest{
        .prompt = "x",
        .api_model = "m",
        .image = .{ .source = "ref.png", .bytes = "hi", .mime = "image/png" },
    };
    const body = try buildBody(a, req);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"image\":\"data:image/png;base64,aGk=\"") != null);
}
