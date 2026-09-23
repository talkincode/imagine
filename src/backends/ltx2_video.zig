//! Self-hosted LTX-2 video service adapter.
//!
//! The service contract is documented in `integrations/ltx2/README.md`: create
//! returns a task id, status polling returns a video URL, and the generic async
//! backend loop downloads the finished MP4.

const std = @import("std");
const types = @import("../types.zig");
const util = @import("../util.zig");
const wire = @import("../wire.zig");

const ImageInput = struct {
    mime_type: []const u8,
    data: []const u8,
};

const Body = struct {
    model: []const u8,
    prompt: []const u8,
    duration: ?u32,
    resolution: ?[]const u8,
    ratio: ?[]const u8,
    seed: ?i64,
    image: ?ImageInput,
};

pub fn buildBody(allocator: std.mem.Allocator, req: types.GenRequest) ![]u8 {
    const image = if (req.image) |img| blk: {
        const bytes = img.bytes orelse return error.InputImageNotFetched;
        break :blk ImageInput{
            .mime_type = img.mime,
            .data = try util.base64EncodeAlloc(allocator, bytes),
        };
    } else null;

    return std.json.Stringify.valueAlloc(allocator, Body{
        .model = req.api_model,
        .prompt = req.prompt,
        .duration = req.duration,
        .resolution = req.resolution,
        .ratio = if (req.ratio) |r| r else if (req.size) |s| (if (util.isRatio(s)) s else null) else null,
        .seed = req.seed,
        .image = image,
    }, .{ .emit_null_optional_fields = false });
}

/// Create accepts `{ "id": "..." }`; all provider-specific execution stays
/// behind the optional local service.
pub fn parseCreate(allocator: std.mem.Allocator, status: u16, body: []const u8) std.mem.Allocator.Error!wire.TaskOutcome {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return .{ .api_error = try wire.rawError(allocator, status, body) };
    };
    defer parsed.deinit();

    const root = wire.rootObject(parsed.value) orelse
        return .{ .api_error = try std.fmt.allocPrint(allocator, "HTTP {d}: unexpected response", .{status}) };
    if (root.get("id")) |id_v| {
        if (id_v == .string and id_v.string.len > 0) {
            return .{ .pending = try allocator.dupe(u8, id_v.string) };
        }
    }
    return .{ .api_error = try wire.apiError(allocator, status, body, root) };
}

pub fn pollUrl(allocator: std.mem.Allocator, base_url: []const u8, task_id: []const u8) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ std.mem.trimEnd(u8, base_url, "/"), task_id });
}

pub fn parsePoll(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    task_id: []const u8,
    status: u16,
    body: []const u8,
) std.mem.Allocator.Error!wire.PollOutcome {
    _ = base_url;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return .{ .api_error = try wire.rawError(allocator, status, body) };
    };
    defer parsed.deinit();

    const root = wire.rootObject(parsed.value) orelse
        return .{ .api_error = try std.fmt.allocPrint(allocator, "HTTP {d}: unexpected response", .{status}) };
    const state_v = root.get("status") orelse
        return .{ .api_error = try wire.apiError(allocator, status, body, root) };
    if (state_v != .string) {
        return .{ .api_error = try wire.apiError(allocator, status, body, root) };
    }

    if (std.mem.eql(u8, state_v.string, "succeeded")) {
        const url_v = root.get("video_url") orelse return .{ .api_error = try std.fmt.allocPrint(
            allocator,
            "task {s} succeeded but returned no video_url",
            .{task_id},
        ) };
        if (url_v != .string or url_v.string.len == 0) return .{ .api_error = try std.fmt.allocPrint(
            allocator,
            "task {s} succeeded but returned no video_url",
            .{task_id},
        ) };
        const payloads = try allocator.alloc(types.Payload, 1);
        payloads[0] = .{ .url = try allocator.dupe(u8, url_v.string) };
        return .{ .done = payloads };
    }

    if (std.mem.eql(u8, state_v.string, "failed") or std.mem.eql(u8, state_v.string, "cancelled")) {
        if (root.get("error")) |error_value| {
            if (wire.extractErrorMessage(error_value)) |message| {
                return .{ .api_error = try std.fmt.allocPrint(allocator, "task {s} {s}: {s}", .{ task_id, state_v.string, message }) };
            }
        }
        return .{ .api_error = try std.fmt.allocPrint(allocator, "task {s} {s}", .{ task_id, state_v.string }) };
    }

    return .pending;
}

// ---- tests ----

test "ltx2_video body supports text-to-video and first-frame video" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const t2v = try buildBody(a, .{
        .prompt = "a fox runs through snow",
        .api_model = "ltx-2",
        .duration = 6,
        .resolution = "720p",
        .size = "16:9",
        .seed = 17,
    });
    try std.testing.expect(std.mem.indexOf(u8, t2v, "\"model\":\"ltx-2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, t2v, "\"duration\":6") != null);
    try std.testing.expect(std.mem.indexOf(u8, t2v, "\"resolution\":\"720p\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, t2v, "\"ratio\":\"16:9\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, t2v, "\"seed\":17") != null);
    try std.testing.expect(std.mem.indexOf(u8, t2v, "\"image\"") == null);

    const i2v = try buildBody(a, .{
        .prompt = "the fox looks at the camera",
        .api_model = "ltx-2",
        .image = .{ .source = "first.png", .bytes = "PNG", .mime = "image/png" },
    });
    try std.testing.expect(std.mem.indexOf(u8, i2v, "\"image\":{\"mime_type\":\"image/png\",\"data\":\"UE5H\"}") != null);
}

test "ltx2_video create, poll, and errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const created = try parseCreate(a, 202, "{\"id\":\"task-123\"}");
    try std.testing.expectEqualStrings("task-123", created.pending);
    try std.testing.expectEqualStrings("http://127.0.0.1:8000/v1/videos/generations/task-123", try pollUrl(a, "http://127.0.0.1:8000/v1/videos/generations/", "task-123"));

    const running = try parsePoll(a, "", "task-123", 200, "{\"status\":\"running\"}");
    try std.testing.expect(running == .pending);
    const finished = try parsePoll(a, "", "task-123", 200, "{\"status\":\"succeeded\",\"video_url\":\"http://127.0.0.1:8000/v1/videos/task-123/content\"}");
    try std.testing.expectEqualStrings("http://127.0.0.1:8000/v1/videos/task-123/content", finished.done[0].url);
    const failed = try parsePoll(a, "", "task-123", 200, "{\"status\":\"failed\",\"error\":{\"message\":\"out of memory\"}}");
    try std.testing.expect(std.mem.indexOf(u8, failed.api_error, "task task-123 failed: out of memory") != null);
    const bad_create = try parseCreate(a, 503, "{\"error\":{\"message\":\"service unavailable\"}}");
    try std.testing.expect(std.mem.indexOf(u8, bad_create.api_error, "service unavailable") != null);
}
