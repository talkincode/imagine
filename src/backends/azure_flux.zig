//! Black Forest Labs FLUX models on Azure.
//!
//! Endpoint shape is provider-specific (not OpenAI images/generations).
//! Body uses integer `width`/`height` (not a size string) plus an optional
//! `seed`. Logical model name / `api_model` come from config.

const std = @import("std");
const types = @import("../types.zig");

pub fn buildBody(allocator: std.mem.Allocator, req: types.GenRequest) ![]u8 {
    // FLUX wants width/height. Derive them from a "WxH" size when needed.
    var width = req.width;
    var height = req.height;
    if ((width == null or height == null)) {
        if (req.size) |s| {
            if (types.parseSize(s)) |wh| {
                if (width == null) width = wh.w;
                if (height == null) height = wh.h;
            }
        }
    }

    const Body = struct {
        prompt: []const u8,
        model: []const u8,
        n: u32,
        width: ?u32,
        height: ?u32,
        seed: ?i64,
    };

    const body = Body{
        .prompt = req.prompt,
        .model = req.api_model,
        .n = req.n,
        .width = width,
        .height = height,
        .seed = req.seed,
    };

    return std.json.Stringify.valueAlloc(allocator, body, .{ .emit_null_optional_fields = false });
}

test "azure_flux body uses width/height and omits null seed" {
    const a = std.testing.allocator;
    const req = types.GenRequest{ .prompt = "a fox", .api_model = "FLUX.2-pro", .n = 1, .width = 1024, .height = 1024 };
    const body = try buildBody(a, req);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"width\":1024") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"height\":1024") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "seed") == null);
}

test "azure_flux derives width/height from size" {
    const a = std.testing.allocator;
    const req = types.GenRequest{ .prompt = "x", .api_model = "FLUX.2-pro", .n = 1, .size = "768x512", .seed = 7 };
    const body = try buildBody(a, req);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"width\":768") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"height\":512") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"seed\":7") != null);
}
