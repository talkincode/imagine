//! Volcengine Ark video generation (Seedance) — asynchronous task API.
//!
//! Ark's video models are not a synchronous `images/generations` call: the
//! create request returns a task id, and the result is fetched by polling that
//! task until it reaches `succeeded`.
//!
//!   POST https://ark.cn-beijing.volces.com/api/v3/contents/generations/tasks
//!   GET  https://ark.cn-beijing.volces.com/api/v3/contents/generations/tasks/{id}
//!   Authorization: Bearer $ARK_API_KEY
//!
//! Create body (`content` carries the prompt, and optionally a first-frame
//! image as a URL or `data:` URL), create response `{ "id": "cgt-…" }`, status
//! response `{ "status": …, "content": { "video_url": … } }`. Only `succeeded`
//! is a success; `failed` / `cancelled` / `expired` are terminal and arrive as
//! HTTP 200 with an `error` object, which is why `parsePoll` checks `status`
//! rather than the HTTP code. The returned URL expires after 24 hours, so the
//! generic loop downloads it immediately.
//!
//! The generic create→poll→download loop lives in `backend.zig`; this module
//! owns the Ark-specific body and the three parsers it feeds.

const std = @import("std");
const types = @import("../types.zig");
const util = @import("../util.zig");
const wire = @import("../wire.zig");

const ImageUrl = struct { url: []const u8 };

const Content = struct {
    type: []const u8,
    text: ?[]const u8 = null,
    image_url: ?ImageUrl = null,
    role: ?[]const u8 = null,
};

/// Ark takes an image as an HTTPS URL or a base64 `data:` URL. Local files were
/// already read by the caller, so they become a data URL here.
fn imageRef(allocator: std.mem.Allocator, img: types.InputImage) ![]const u8 {
    const bytes = img.bytes orelse return img.source;
    return util.dataUrlAlloc(allocator, bytes, img.mime);
}

pub fn buildBody(allocator: std.mem.Allocator, req: types.GenRequest) ![]u8 {
    const Body = struct {
        model: []const u8,
        content: []const Content,
        resolution: ?[]const u8,
        ratio: ?[]const u8,
        duration: ?u32,
        seed: ?i64,
        watermark: ?bool,
        output_format: ?[]const u8,
    };

    var content = std.ArrayList(Content).empty;
    try content.append(allocator, .{ .type = "text", .text = req.prompt });
    if (req.image) |img| {
        try content.append(allocator, .{
            .type = "image_url",
            .image_url = .{ .url = try imageRef(allocator, img) },
            .role = "first_frame",
        });
    }

    const body = Body{
        .model = req.api_model,
        .content = try content.toOwnedSlice(allocator),
        .resolution = req.resolution,
        // `--size` has no pixel meaning for video; treat a `W:H` token as the
        // aspect ratio so `-s 16:9` does the obvious thing.
        .ratio = if (req.ratio) |r| r else if (req.size) |s| (if (util.isRatio(s)) s else null) else null,
        .duration = req.duration,
        .seed = req.seed,
        .watermark = req.watermark,
        .output_format = req.output_format,
    };

    return std.json.Stringify.valueAlloc(allocator, body, .{ .emit_null_optional_fields = false });
}

/// `{"id": "cgt-…"}` — the only field the create call returns.
pub fn parseCreate(allocator: std.mem.Allocator, status: u16, body: []const u8) std.mem.Allocator.Error!wire.TaskOutcome {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return .{ .api_error = try std.fmt.allocPrint(allocator, "HTTP {d}: {s}", .{ status, body[0..@min(body.len, 280)] }) };
    };
    defer parsed.deinit();

    const root = wire.rootObject(parsed.value) orelse
        return .{ .api_error = try std.fmt.allocPrint(allocator, "HTTP {d}: unexpected response", .{status}) };
    if (root.get("id")) |id_v| {
        if (id_v == .string) return .{ .pending = try allocator.dupe(u8, id_v.string) };
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
        return .{ .api_error = try std.fmt.allocPrint(allocator, "HTTP {d}: {s}", .{ status, body[0..@min(body.len, 280)] }) };
    };
    defer parsed.deinit();

    const root = wire.rootObject(parsed.value) orelse
        return .{ .api_error = try std.fmt.allocPrint(allocator, "HTTP {d}: unexpected response", .{status}) };
    const state_v = root.get("status") orelse
        return .{ .api_error = try wire.apiError(allocator, status, body, root) };
    if (state_v != .string) {
        return .{ .api_error = try wire.apiError(allocator, status, body, root) };
    }
    const state = state_v.string;

    if (std.mem.eql(u8, state, "succeeded")) {
        const url = videoUrl(root) orelse return .{ .api_error = try std.fmt.allocPrint(
            allocator,
            "task {s} succeeded but returned no content.video_url",
            .{task_id},
        ) };
        const list = try allocator.alloc(types.Payload, 1);
        list[0] = .{ .url = try allocator.dupe(u8, url) };
        return .{ .done = list };
    }

    // Terminal failures arrive with HTTP 200 and an `error` object.
    if (std.mem.eql(u8, state, "failed") or std.mem.eql(u8, state, "cancelled") or
        std.mem.eql(u8, state, "expired"))
    {
        if (root.get("error")) |ev| {
            if (wire.extractErrorMessage(ev)) |msg| {
                return .{ .api_error = try std.fmt.allocPrint(allocator, "task {s} {s}: {s}", .{ task_id, state, msg }) };
            }
        }
        return .{ .api_error = try std.fmt.allocPrint(allocator, "task {s} {s}", .{ task_id, state }) };
    }

    // queued / running (and anything new the provider adds).
    return .pending;
}

fn videoUrl(root: std.json.ObjectMap) ?[]const u8 {
    const content_v = root.get("content") orelse return null;
    if (content_v != .object) return null;
    const url_v = content_v.object.get("video_url") orelse return null;
    if (url_v != .string) return null;
    return url_v.string;
}

// ---- tests ----

test "seedance body carries prompt, video params and omits unset ones" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const req = types.GenRequest{
        .prompt = "a cat yawning",
        .api_model = "doubao-seedance-2-5-260628",
        .duration = 5,
        .resolution = "720p",
        .ratio = "16:9",
        .seed = 11,
        .watermark = false,
    };
    const body = try buildBody(a, req);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"doubao-seedance-2-5-260628\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\":[{\"type\":\"text\",\"text\":\"a cat yawning\"}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"resolution\":\"720p\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"duration\":5") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"seed\":11") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"watermark\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "image_url") == null);
}

test "seedance maps --size ratio tokens and first-frame images" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const req = types.GenRequest{
        .prompt = "x",
        .api_model = "m",
        .size = "9:16",
        .image = .{ .source = "https://example.com/first.png" },
    };
    const body = try buildBody(a, req);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"ratio\":\"9:16\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"image_url\":{\"url\":\"https://example.com/first.png\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"first_frame\"") != null);
}

test "seedance encodes a local first-frame image as a data URL" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const req = types.GenRequest{
        .prompt = "x",
        .api_model = "m",
        .image = .{ .source = "first.jpg", .bytes = "hi", .mime = "image/jpeg" },
    };
    const body = try buildBody(a, req);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "data:image/jpeg;base64,aGk=") != null);
}

test "seedance ignores a pixel size and parses the create response" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    const body = try buildBody(al, .{ .prompt = "x", .api_model = "m", .size = "1024x1024" });
    try std.testing.expect(std.mem.indexOf(u8, body, "ratio") == null);

    const created = try parseCreate(al, 200, "{\"id\":\"cgt-123\"}");
    try std.testing.expect(created == .pending);
    try std.testing.expectEqualStrings("cgt-123", created.pending);

    const url = try pollUrl(al, "https://ark.example.com/api/v3/contents/generations/tasks", "cgt-123");
    try std.testing.expectEqualStrings("https://ark.example.com/api/v3/contents/generations/tasks/cgt-123", url);
}

test "seedance poll: running, succeeded, failed" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();
    const base = "https://ark.example.com/api/v3/contents/generations/tasks";

    const running = try parsePoll(al, base, "t1", 200, "{\"id\":\"t1\",\"status\":\"running\"}");
    try std.testing.expect(running == .pending);

    const ok = try parsePoll(al, base, "t1", 200, "{\"id\":\"t1\",\"status\":\"succeeded\",\"content\":{\"video_url\":\"https://cdn/v.mp4\"}}");
    try std.testing.expect(ok == .done);
    try std.testing.expectEqualStrings("https://cdn/v.mp4", ok.done[0].url);

    const failed = try parsePoll(al, base, "t1", 200, "{\"id\":\"t1\",\"status\":\"failed\",\"error\":{\"code\":\"OutputVideoSensitiveContentDetected\",\"message\":\"blocked\"}}");
    try std.testing.expect(failed == .api_error);
    try std.testing.expect(std.mem.indexOf(u8, failed.api_error, "blocked") != null);
}

test "seedance surfaces an error envelope on the create call" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const out = try parseCreate(arena.allocator(), 401, "{\"error\":{\"code\":\"AuthenticationError\",\"message\":\"bad key\"}}");
    try std.testing.expect(out == .api_error);
    try std.testing.expect(std.mem.indexOf(u8, out.api_error, "bad key") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.api_error, "401") != null);
}
