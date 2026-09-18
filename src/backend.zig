//! Backend dispatch and generation orchestration.
//!
//! Per-provider code is intentionally tiny (just request-body construction in
//! `backends/*`). Everything provider-agnostic — credential resolution, auth
//! headers, transport, response parsing, base64 decode, URL fallback — lives
//! here so adding a backend stays a small, local change.

const std = @import("std");
const types = @import("types.zig");
const http = @import("http.zig");
const util = @import("util.zig");

const openai_image = @import("backends/openai_image.zig");
const azure_flux = @import("backends/azure_flux.zig");

const user_agent = "imagine/" ++ @import("version.zig").string;

/// Construct the provider request body for a model's backend.
pub fn buildBody(kind: types.BackendKind, allocator: std.mem.Allocator, req: types.ImageRequest) ![]u8 {
    return switch (kind) {
        .openai_image => openai_image.buildBody(allocator, req),
        .azure_flux => azure_flux.buildBody(allocator, req),
    };
}

/// Result of one generation attempt. API/HTTP/credential failures are reported
/// via `err` (a human-readable message) rather than as Zig errors, so callers
/// can aggregate per-task outcomes. Only allocation failure propagates.
pub const GenResult = struct {
    images: [][]u8 = &.{},
    err: ?[]const u8 = null,

    pub fn ok(self: GenResult) bool {
        return self.err == null;
    }
};

const Outcome = union(enum) {
    images: []types.ImagePayload,
    api_error: []const u8,
};

/// Generate images for a single (model, endpoint) pair. `allocator` should be a
/// per-task arena; all returned memory lives in it.
pub fn generate(
    client: *std.http.Client,
    allocator: std.mem.Allocator,
    model: *const types.ModelConfig,
    endpoint: *const types.Endpoint,
    req: types.ImageRequest,
) std.mem.Allocator.Error!GenResult {
    const key = endpoint.resolved_key orelse {
        const env_name = endpoint.api_key_env orelse "(none)";
        return .{ .err = try std.fmt.allocPrint(
            allocator,
            "missing credential: set ${s} or add api_key to endpoint for model '{s}'",
            .{ env_name, model.name },
        ) };
    };

    // Standard headers go through std.http's overridable `headers` field so
    // each is emitted exactly once. Putting User-Agent in `extra_headers`
    // instead produced a DUPLICATE User-Agent (std.http adds its own default),
    // which Azure's gateway rejects as "Bad Request - Invalid Header".
    var std_headers: http.StdHeaders = .{
        .user_agent = .{ .override = user_agent },
        .content_type = .{ .override = "application/json" },
    };
    var extra: []const http.Header = &.{};
    var api_key_hdr: [1]http.Header = undefined;
    switch (endpoint.auth) {
        .bearer => std_headers.authorization = .{
            .override = try std.fmt.allocPrint(allocator, "Bearer {s}", .{key}),
        },
        .api_key => {
            api_key_hdr[0] = .{ .name = endpoint.auth.headerName(), .value = key };
            extra = api_key_hdr[0..1];
        },
    }

    const body = try buildBody(model.backend, allocator, req);

    const res = http.post(client, allocator, endpoint.base_url, std_headers, extra, body) catch |e| {
        return .{ .err = try std.fmt.allocPrint(allocator, "request failed: {s}", .{@errorName(e)}) };
    };

    const outcome = try parseResponse(allocator, res.status, res.body);
    switch (outcome) {
        .api_error => |msg| return .{ .err = msg },
        .images => |payloads| {
            if (payloads.len == 0) {
                return .{ .err = try std.fmt.allocPrint(allocator, "no images in response (HTTP {d})", .{res.status}) };
            }
            var out = try allocator.alloc([]u8, payloads.len);
            for (payloads, 0..) |p, i| {
                switch (p) {
                    .bytes => |b| out[i] = b,
                    .url => |u| {
                        const dl = http.get(client, allocator, u, .{ .user_agent = .{ .override = user_agent } }, &.{}) catch |e| {
                            return .{ .err = try std.fmt.allocPrint(allocator, "failed to download image url: {s}", .{@errorName(e)}) };
                        };
                        out[i] = dl.body;
                    },
                }
            }
            return .{ .images = out };
        },
    }
}

/// Parse a provider JSON response into decoded payloads or an error message.
/// Shared across all current backends, which return the OpenAI-style
/// `{ "data": [ { "b64_json" | "url" } ] }` shape and
/// `{ "error": { "message" } }` for failures.
pub fn parseResponse(allocator: std.mem.Allocator, status: u16, body: []const u8) std.mem.Allocator.Error!Outcome {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        // Non-JSON body (e.g. an HTML error page). Surface a trimmed snippet.
        const snippet = body[0..@min(body.len, 280)];
        return .{ .api_error = try std.fmt.allocPrint(allocator, "HTTP {d}: {s}", .{ status, snippet }) };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return .{ .api_error = try std.fmt.allocPrint(allocator, "HTTP {d}: unexpected response", .{status}) };
    }
    const root = parsed.value.object;

    if (root.get("error")) |ev| {
        const msg = extractErrorMessage(ev) orelse "unknown error";
        return .{ .api_error = try std.fmt.allocPrint(allocator, "HTTP {d}: {s}", .{ status, msg }) };
    }

    const data_v = root.get("data") orelse {
        // Some error responses put the message at the top level.
        if (root.get("message")) |mv| {
            if (mv == .string) return .{ .api_error = try std.fmt.allocPrint(allocator, "HTTP {d}: {s}", .{ status, mv.string }) };
        }
        if (status >= 400) {
            const snippet = body[0..@min(body.len, 280)];
            return .{ .api_error = try std.fmt.allocPrint(allocator, "HTTP {d}: {s}", .{ status, snippet }) };
        }
        return .{ .images = &.{} };
    };
    if (data_v != .array) return .{ .images = &.{} };

    var list = std.ArrayList(types.ImagePayload).empty;
    for (data_v.array.items) |item| {
        if (item != .object) continue;
        const o = item.object;
        if (o.get("b64_json")) |bv| {
            if (bv == .string) {
                const bytes = util.base64DecodeAlloc(allocator, bv.string) catch continue;
                try list.append(allocator, .{ .bytes = bytes });
                continue;
            }
        }
        if (o.get("url")) |uv| {
            if (uv == .string) {
                try list.append(allocator, .{ .url = try allocator.dupe(u8, uv.string) });
            }
        }
    }
    return .{ .images = try list.toOwnedSlice(allocator) };
}

fn extractErrorMessage(ev: std.json.Value) ?[]const u8 {
    switch (ev) {
        .string => |s| return s,
        .object => |o| {
            if (o.get("message")) |mv| {
                if (mv == .string) return mv.string;
            }
            if (o.get("code")) |cv| {
                if (cv == .string) return cv.string;
            }
            return null;
        },
        else => return null,
    }
}

// ---- tests ----

test "parseResponse decodes b64_json" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    // "aGk=" -> "hi"
    const body = "{\"data\":[{\"b64_json\":\"aGk=\"}]}";
    const outcome = try parseResponse(arena.allocator(), 200, body);
    try std.testing.expect(outcome == .images);
    try std.testing.expectEqual(@as(usize, 1), outcome.images.len);
    try std.testing.expectEqualStrings("hi", outcome.images[0].bytes);
}

test "parseResponse surfaces error.message" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const body = "{\"error\":{\"message\":\"bad prompt\",\"code\":\"content_policy\"}}";
    const outcome = try parseResponse(arena.allocator(), 400, body);
    try std.testing.expect(outcome == .api_error);
    try std.testing.expect(std.mem.indexOf(u8, outcome.api_error, "bad prompt") != null);
}

test "parseResponse handles non-json" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const outcome = try parseResponse(arena.allocator(), 502, "<html>Bad Gateway</html>");
    try std.testing.expect(outcome == .api_error);
    try std.testing.expect(std.mem.indexOf(u8, outcome.api_error, "502") != null);
}

test "parseResponse captures url payloads" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const body = "{\"data\":[{\"url\":\"https://example.com/x.png\"}]}";
    const outcome = try parseResponse(arena.allocator(), 200, body);
    try std.testing.expect(outcome == .images);
    try std.testing.expect(outcome.images[0] == .url);
}
