//! Shared wire-format helpers: the outcome types an async-task backend reports,
//! and the error-envelope shapes providers use.
//!
//! This module exists so `backends/*` can describe their responses without
//! importing `backend.zig` (the orchestrator that imports *them*). It knows
//! nothing about any specific provider: each backend maps its own status values
//! onto these outcomes and calls `apiError` for the rest.

const std = @import("std");
const types = @import("types.zig");

/// Outcome of the create call of an async-task backend.
pub const TaskOutcome = union(enum) {
    /// The provider accepted the work: poll `pending` (a task/file id) until it
    /// yields assets.
    pending: []const u8,
    /// The provider finished inside the create call.
    done: []types.Payload,
    api_error: []const u8,
};

/// Outcome of one status poll of an async-task backend.
pub const PollOutcome = union(enum) {
    pending,
    done: []types.Payload,
    api_error: []const u8,
};

/// The JSON object at the root of a response. Google's Interactions/Files
/// endpoints wrap payloads (and errors) in a one-element array, so both shapes
/// are accepted rather than reporting "unexpected response" and dropping the
/// provider's message.
pub fn rootObject(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |o| o,
        .array => |a| if (a.items.len > 0 and a.items[0] == .object) a.items[0].object else null,
        else => null,
    };
}

/// Message from an error object that may be a string or a `{message|code}`.
pub fn extractErrorMessage(ev: std.json.Value) ?[]const u8 {
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

/// `HTTP <status>: <message>` from an error envelope, falling back to a trimmed
/// body snippet — the shape every backend reports failures with, so `--json`
/// errors read the same everywhere.
pub fn apiError(allocator: std.mem.Allocator, status: u16, body: []const u8, root: std.json.ObjectMap) std.mem.Allocator.Error![]const u8 {
    if (root.get("error")) |ev| {
        const msg = extractErrorMessage(ev) orelse "unknown error";
        return std.fmt.allocPrint(allocator, "HTTP {d}: {s}", .{ status, msg });
    }
    if (root.get("message")) |mv| {
        if (mv == .string) return std.fmt.allocPrint(allocator, "HTTP {d}: {s}", .{ status, mv.string });
    }
    const snippet = body[0..@min(body.len, 280)];
    return std.fmt.allocPrint(allocator, "HTTP {d}: {s}", .{ status, snippet });
}

/// `HTTP <status>: <snippet>` for a body that is not JSON at all (an HTML error
/// page, a truncated response).
pub fn rawError(allocator: std.mem.Allocator, status: u16, body: []const u8) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "HTTP {d}: {s}", .{ status, body[0..@min(body.len, 280)] });
}

// ---- tests ----

test "rootObject accepts an object or a one-element array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const obj = try std.json.parseFromSlice(std.json.Value, a, "{\"error\":{\"message\":\"x\"}}", .{});
    try std.testing.expect(rootObject(obj.value) != null);

    // The shape Google's Interactions API returns on failure.
    const arr = try std.json.parseFromSlice(std.json.Value, a, "[{\"error\":{\"code\":400,\"message\":\"API key not valid\"}}]", .{});
    const root = rootObject(arr.value).?;
    try std.testing.expectEqualStrings("API key not valid", extractErrorMessage(root.get("error").?).?);
}

test "apiError reads the envelope, then the body snippet" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var parsed = try std.json.parseFromSlice(std.json.Value, a, "[{\"error\":{\"message\":\"bad key\"}}]", .{});
    defer parsed.deinit();
    const msg = try apiError(a, 400, "[]", rootObject(parsed.value).?);
    try std.testing.expectEqualStrings("HTTP 400: bad key", msg);

    var html = try std.json.parseFromSlice(std.json.Value, a, "{}", .{});
    defer html.deinit();
    const raw = try apiError(a, 502, "<html>Bad Gateway</html>", html.value.object);
    try std.testing.expect(std.mem.indexOf(u8, raw, "Bad Gateway") != null);
}
