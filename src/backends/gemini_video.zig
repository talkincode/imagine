//! Google Gemini video generation — the Interactions API (Gemini Omni).
//!
//!   POST https://generativelanguage.googleapis.com/v1beta/interactions
//!   GET  https://generativelanguage.googleapis.com/v1beta/files/{id}
//!   GET  https://generativelanguage.googleapis.com/v1beta/files/{id}:download?alt=media
//!   x-goog-api-key: $GEMINI_API_KEY
//!
//! A create call returns an interaction; the video is requested with
//! `response_format.delivery = "uri"` because inline delivery returns a large
//! base64 body from one long unary request. With `uri` delivery the interaction
//! carries a Files API reference (`files/<id>`, sometimes spelled as an absolute
//! `:download` URL), which is polled until its state is `ACTIVE` and then
//! downloaded — the create→poll→download loop in `backend.zig`. A response that
//! does contain inline `data` is accepted too, so an API that ignores
//! `delivery` still works.
//!
//! Notes baked into this backend:
//!   * `input` is always the content-part array form, which is what carries a
//!     first-frame image (`{"type":"image","data":…,"mime_type":…}`).
//!   * `--size`/`--ratio` map to `response_format.aspect_ratio`; resolution
//!     tokens (`720p`, `1080p`, …) go to `response_format.resolution`.
//!   * `--duration` is forwarded as a string. Google's reference lists the field
//!     but does not document its accepted values, so it is only sent when the
//!     caller asked for it.
//!   * Omni always generates audio and has no audio flag; there is no
//!     `numberOfVideos` (one video per interaction — `-n` fans out instead).
//!   * The download URL is built from the endpoint's API root (the create URL
//!     minus its last path segment), so a gateway or proxy prefix in `base_url`
//!     is preserved.

const std = @import("std");
const types = @import("../types.zig");
const util = @import("../util.zig");
const wire = @import("../wire.zig");

const InputPart = struct {
    type: []const u8,
    text: ?[]const u8 = null,
    data: ?[]const u8 = null,
    mime_type: ?[]const u8 = null,
};

const ResponseFormat = struct {
    type: []const u8 = "video",
    delivery: []const u8 = "uri",
    aspect_ratio: ?[]const u8 = null,
    resolution: ?[]const u8 = null,
    duration: ?[]const u8 = null,
};

const GenerationConfig = struct {
    seed: ?i64 = null,
};

const Body = struct {
    model: []const u8,
    input: []const InputPart,
    response_format: ResponseFormat,
    generation_config: ?GenerationConfig = null,
};

pub fn buildBody(allocator: std.mem.Allocator, req: types.GenRequest) ![]u8 {
    var parts = std.ArrayList(InputPart).empty;
    if (req.image) |img| {
        // The bytes are guaranteed by `backend.resolveInputImage`: this backend
        // declares `bytes_base64` and never sees a bare URL.
        const bytes = img.bytes orelse return error.InputImageNotFetched;
        try parts.append(allocator, .{
            .type = "image",
            .data = try util.base64EncodeAlloc(allocator, bytes),
            .mime_type = img.mime,
        });
    }
    try parts.append(allocator, .{ .type = "text", .text = req.prompt });

    var duration_buf: [16]u8 = undefined;
    const duration: ?[]const u8 = if (req.duration) |d|
        std.fmt.bufPrint(&duration_buf, "{d}", .{d}) catch null
    else
        null;

    const body = Body{
        .model = req.api_model,
        .input = try parts.toOwnedSlice(allocator),
        .response_format = .{
            // `--size` has no pixel meaning for video; a `W:H` token is an
            // aspect ratio, which is how `-s 16:9` reaches the API.
            .aspect_ratio = if (req.ratio) |r| r else if (req.size) |s| (if (util.isRatio(s)) s else null) else null,
            .resolution = req.resolution,
            .duration = duration,
        },
        .generation_config = if (req.seed) |s| GenerationConfig{ .seed = s } else null,
    };

    return std.json.Stringify.valueAlloc(allocator, body, .{ .emit_null_optional_fields = false });
}

/// The API root that file polling and downloads hang off: the create URL
/// without its last path segment (`…/v1beta/interactions` -> `…/v1beta`).
fn apiRoot(base_url: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, base_url, "/");
    const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return trimmed;
    return trimmed[0..slash];
}

/// `files/abc` and `https://host/v1beta/files/abc:download?alt=media` both mean
/// file id `abc`.
fn normalizeFileId(allocator: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error![]const u8 {
    var s = raw;
    if (std.mem.indexOf(u8, s, "/files/")) |i| {
        s = s[i + "/files/".len ..];
    } else if (std.mem.startsWith(u8, s, "files/")) {
        s = s["files/".len..];
    }
    if (std.mem.indexOfAny(u8, s, ":?")) |i| s = s[0..i];
    return allocator.dupe(u8, s);
}

const VideoRef = struct { uri: ?[]const u8 = null, data: ?[]const u8 = null };

/// First `type == "video"` content part, looking through the interaction's
/// `steps[]` and (tolerantly) at a top-level `output_video` object.
fn findVideo(root: std.json.ObjectMap) ?VideoRef {
    if (root.get("steps")) |steps_v| {
        if (steps_v == .array) {
            for (steps_v.array.items) |step| {
                if (step != .object) continue;
                const content_v = step.object.get("content") orelse continue;
                if (content_v != .array) continue;
                for (content_v.array.items) |part| {
                    if (part != .object) continue;
                    const o = part.object;
                    const t = o.get("type") orelse continue;
                    if (t != .string or !std.mem.eql(u8, t.string, "video")) continue;
                    if (videoRefOf(o)) |ref| return ref;
                }
            }
        }
    }
    if (root.get("output_video")) |ov| {
        if (ov == .object) return videoRefOf(ov.object);
    }
    return null;
}

fn videoRefOf(o: std.json.ObjectMap) ?VideoRef {
    var ref: VideoRef = .{};
    if (o.get("uri")) |uv| {
        if (uv == .string) ref.uri = uv.string;
    }
    if (o.get("data")) |dv| {
        if (dv == .string) ref.data = dv.string;
    }
    if (ref.uri == null and ref.data == null) return null;
    return ref;
}

/// Human-readable reason from an interaction's `errors[]` / `error` / `status`.
fn failureReason(root: std.json.ObjectMap) ?[]const u8 {
    if (root.get("errors")) |ev| {
        if (ev == .array) {
            for (ev.array.items) |item| {
                if (wire.extractErrorMessage(item)) |msg| return msg;
            }
        }
    }
    if (root.get("error")) |ev| {
        if (wire.extractErrorMessage(ev)) |msg| return msg;
    }
    return null;
}

pub fn parseCreate(allocator: std.mem.Allocator, status: u16, body: []const u8) std.mem.Allocator.Error!wire.TaskOutcome {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return .{ .api_error = try std.fmt.allocPrint(allocator, "HTTP {d}: {s}", .{ status, body[0..@min(body.len, 280)] }) };
    };
    defer parsed.deinit();

    const root = wire.rootObject(parsed.value) orelse
        return .{ .api_error = try std.fmt.allocPrint(allocator, "HTTP {d}: unexpected response", .{status}) };

    if (findVideo(root)) |ref| {
        if (ref.data) |b64| {
            const bytes = util.base64DecodeAlloc(allocator, b64) catch
                return .{ .api_error = try std.fmt.allocPrint(allocator, "HTTP {d}: malformed inline video data", .{status}) };
            const list = try allocator.alloc(types.Payload, 1);
            list[0] = .{ .bytes = bytes };
            return .{ .done = list };
        }
        if (ref.uri) |uri| {
            const id = try normalizeFileId(allocator, uri);
            if (id.len == 0) {
                return .{ .api_error = try std.fmt.allocPrint(allocator, "HTTP {d}: empty video uri", .{status}) };
            }
            return .{ .pending = id };
        }
    }

    if (failureReason(root)) |msg| {
        return .{ .api_error = try std.fmt.allocPrint(allocator, "HTTP {d}: {s}", .{ status, msg }) };
    }
    const state = blk: {
        if (root.get("status")) |sv| {
            if (sv == .string) break :blk sv.string;
        }
        break :blk "unknown";
    };
    return .{ .api_error = try std.fmt.allocPrint(
        allocator,
        "HTTP {d}: interaction returned no video (status: {s})",
        .{ status, state },
    ) };
}

pub fn pollUrl(allocator: std.mem.Allocator, base_url: []const u8, file_id: []const u8) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/files/{s}", .{ apiRoot(base_url), file_id });
}

fn downloadUrl(allocator: std.mem.Allocator, base_url: []const u8, file_id: []const u8) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/files/{s}:download?alt=media", .{ apiRoot(base_url), file_id });
}

pub fn parsePoll(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    file_id: []const u8,
    status: u16,
    body: []const u8,
) std.mem.Allocator.Error!wire.PollOutcome {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return .{ .api_error = try std.fmt.allocPrint(allocator, "HTTP {d}: {s}", .{ status, body[0..@min(body.len, 280)] }) };
    };
    defer parsed.deinit();

    const root = wire.rootObject(parsed.value) orelse
        return .{ .api_error = try std.fmt.allocPrint(allocator, "HTTP {d}: unexpected response", .{status}) };

    // The file resource reports `state`; the upload/response wrapper nests it
    // under `file`, so accept either spelling.
    const state = blk: {
        if (root.get("state")) |sv| {
            if (sv == .string) break :blk sv.string;
        }
        if (root.get("file")) |fv| {
            if (fv == .object) {
                if (fv.object.get("state")) |sv| {
                    if (sv == .string) break :blk sv.string;
                }
            }
        }
        break :blk null;
    } orelse {
        if (failureReason(root)) |msg| {
            return .{ .api_error = try std.fmt.allocPrint(allocator, "HTTP {d}: {s}", .{ status, msg }) };
        }
        return .{ .api_error = try wire.apiError(allocator, status, body, root) };
    };

    if (std.mem.eql(u8, state, "ACTIVE")) {
        const list = try allocator.alloc(types.Payload, 1);
        list[0] = .{ .url = try downloadUrl(allocator, base_url, file_id) };
        return .{ .done = list };
    }
    if (std.mem.eql(u8, state, "FAILED")) {
        const msg = failureReason(root) orelse "file processing failed";
        return .{ .api_error = try std.fmt.allocPrint(allocator, "video file {s}: {s}", .{ file_id, msg }) };
    }
    // STATE_UNSPECIFIED / PROCESSING, or anything new the API adds.
    return .pending;
}

// ---- tests ----

test "gemini_video body uses content parts and uri delivery" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const req = types.GenRequest{
        .prompt = "a marble on a chain reaction track",
        .api_model = "gemini-omni-1.1-flash",
        .resolution = "720p",
        .ratio = "16:9",
        .duration = 5,
        .seed = 7,
    };
    const body = try buildBody(a, req);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"gemini-omni-1.1-flash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"input\":[{\"type\":\"text\",\"text\":\"a marble on a chain reaction track\"}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"response_format\":{\"type\":\"video\",\"delivery\":\"uri\",\"aspect_ratio\":\"16:9\",\"resolution\":\"720p\",\"duration\":\"5\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"generation_config\":{\"seed\":7}") != null);
}

test "gemini_video omits duration/seed when unset and maps --size ratios" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const req = types.GenRequest{ .prompt = "x", .api_model = "m", .size = "9:16" };
    const body = try buildBody(a, req);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"aspect_ratio\":\"9:16\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "duration") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "generation_config") == null);
}

test "gemini_video sends a first-frame image as inline base64" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const req = types.GenRequest{
        .prompt = "x",
        .api_model = "m",
        .image = .{ .source = "first.png", .bytes = "hi", .mime = "image/png" },
    };
    const body = try buildBody(a, req);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "{\"type\":\"image\",\"data\":\"aGk=\",\"mime_type\":\"image/png\"}") != null);
    // The image part precedes the prompt part.
    const img_at = std.mem.indexOf(u8, body, "\"type\":\"image\"").?;
    const txt_at = std.mem.indexOf(u8, body, "\"type\":\"text\"").?;
    try std.testing.expect(img_at < txt_at);
}

test "gemini_video derives poll and download URLs from the API root" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();
    const base = "https://generativelanguage.googleapis.com/v1beta/interactions";

    try std.testing.expectEqualStrings(
        "https://generativelanguage.googleapis.com/v1beta/files/abc",
        try pollUrl(al, base, "abc"),
    );
    try std.testing.expectEqualStrings(
        "https://generativelanguage.googleapis.com/v1beta/files/abc:download?alt=media",
        try downloadUrl(al, base, "abc"),
    );
}

test "gemini_video normalizes every uri spelling to a file id" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();
    try std.testing.expectEqualStrings("abc-123", try normalizeFileId(al, "files/abc-123"));
    try std.testing.expectEqualStrings("abc-123", try normalizeFileId(al, "https://generativelanguage.googleapis.com/v1beta/files/abc-123:download?alt=media"));
    try std.testing.expectEqualStrings("abc-123", try normalizeFileId(al, "abc-123"));
}

test "gemini_video create: uri, inline data, and failure" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    const uri_body =
        \\{"id":"v1_x","status":"completed","object":"interaction","steps":[
        \\  {"type":"model_output","content":[{"type":"video","mime_type":"video/mp4","uri":"files/abc"}]}]}
    ;
    const pending = try parseCreate(al, 200, uri_body);
    try std.testing.expect(pending == .pending);
    try std.testing.expectEqualStrings("abc", pending.pending);

    // A server that ignores `delivery: "uri"` and returns base64 still works.
    const inline_body =
        \\{"status":"completed","steps":[{"type":"model_output","content":[
        \\  {"type":"video","mime_type":"video/mp4","data":"aGk="}]}]}
    ;
    const done = try parseCreate(al, 200, inline_body);
    try std.testing.expect(done == .done);
    try std.testing.expectEqualStrings("hi", done.done[0].bytes);

    const failed_body =
        \\{"status":"failed","errors":[{"code":"safety","message":"blocked by policy"}]}
    ;
    const failed = try parseCreate(al, 200, failed_body);
    try std.testing.expect(failed == .api_error);
    try std.testing.expect(std.mem.indexOf(u8, failed.api_error, "blocked by policy") != null);

    const err_body = "{\"error\":{\"code\":\"authentication\",\"message\":\"bad key\"}}";
    const err = try parseCreate(al, 401, err_body);
    try std.testing.expect(err == .api_error);
    try std.testing.expect(std.mem.indexOf(u8, err.api_error, "401") != null);
}

test "gemini_video poll: processing, active, failed" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();
    const base = "https://generativelanguage.googleapis.com/v1beta/interactions";

    const processing = try parsePoll(al, base, "abc", 200, "{\"name\":\"files/abc\",\"state\":\"PROCESSING\"}");
    try std.testing.expect(processing == .pending);

    const active = try parsePoll(al, base, "abc", 200, "{\"name\":\"files/abc\",\"state\":\"ACTIVE\"}");
    try std.testing.expect(active == .done);
    try std.testing.expect(std.mem.indexOf(u8, active.done[0].url, "/files/abc:download?alt=media") != null);

    const nested = try parsePoll(al, base, "abc", 200, "{\"file\":{\"state\":\"ACTIVE\"}}");
    try std.testing.expect(nested == .done);

    const failed = try parsePoll(al, base, "abc", 200, "{\"state\":\"FAILED\"}");
    try std.testing.expect(failed == .api_error);
    try std.testing.expect(std.mem.indexOf(u8, failed.api_error, "abc") != null);
    try std.testing.expect(std.mem.indexOf(u8, failed.api_error, "processing failed") != null);
}
