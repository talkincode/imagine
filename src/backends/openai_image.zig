//! OpenAI-compatible image generation (`/v1/images/generations`).
//!
//! Works with Azure OpenAI, OpenAI, and any provider that speaks the same
//! request shape. The logical model name and `api_model` come from config —
//! this module does not hardcode provider model ids.
//!
//! Body uses a `size` string ("WxH") plus optional output controls. Only the
//! request-body construction lives here; auth, transport and response parsing
//! are handled generically in `backend.zig`.

const std = @import("std");
const types = @import("../types.zig");

pub fn buildBody(allocator: std.mem.Allocator, req: types.ImageRequest) ![]u8 {
    // Prefer an explicit size; otherwise synthesize one from width/height.
    var size_buf: [32]u8 = undefined;
    const size: ?[]const u8 = req.size orelse blk: {
        if (req.width != null and req.height != null) {
            break :blk std.fmt.bufPrint(&size_buf, "{d}x{d}", .{ req.width.?, req.height.? }) catch null;
        }
        break :blk null;
    };

    const Body = struct {
        prompt: []const u8,
        model: []const u8,
        n: u32,
        size: ?[]const u8,
        output_format: ?[]const u8,
        output_compression: ?u32,
        quality: ?[]const u8,
    };

    const body = Body{
        .prompt = req.prompt,
        .model = req.api_model,
        .n = req.n,
        .size = size,
        .output_format = req.output_format,
        .output_compression = req.output_compression,
        .quality = req.quality,
    };

    return std.json.Stringify.valueAlloc(allocator, body, .{ .emit_null_optional_fields = false });
}

test "openai_image body omits nulls" {
    const a = std.testing.allocator;
    const req = types.ImageRequest{
        .prompt = "a fox",
        .api_model = "my-deployment",
        .n = 1,
        .size = "1024x1024",
        .output_format = "png",
        .output_compression = 100,
    };
    const body = try buildBody(a, req);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"prompt\":\"a fox\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"my-deployment\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"size\":\"1024x1024\"") != null);
    // quality was null -> must be omitted
    try std.testing.expect(std.mem.indexOf(u8, body, "quality") == null);
}

test "openai_image derives size from width/height" {
    const a = std.testing.allocator;
    const req = types.ImageRequest{ .prompt = "x", .api_model = "img", .n = 1, .width = 512, .height = 768 };
    const body = try buildBody(a, req);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"size\":\"512x768\"") != null);
}
