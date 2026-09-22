//! Backend dispatch and generation orchestration.
//!
//! Per-provider code is intentionally tiny: request-body construction plus, for
//! async-task providers, the three small parsers that carry a task from create
//! to download (`parseCreate` / `pollUrl` / `parsePoll`). Everything
//! provider-agnostic — credential resolution, auth headers, transport, the
//! create→poll→download loop, sync response parsing, base64 decode, URL
//! fallback — lives here so adding a backend stays a small, local change.

const std = @import("std");
const types = @import("types.zig");
const wire = @import("wire.zig");
const http = @import("http.zig");
const util = @import("util.zig");

const openai_image = @import("backends/openai_image.zig");
const azure_flux = @import("backends/azure_flux.zig");
const qwen_image = @import("backends/qwen_image.zig");
const seedance = @import("backends/seedance.zig");
const volcengine_image = @import("backends/volcengine_image.zig");
const gemini_video = @import("backends/gemini_video.zig");

const user_agent = "imagine/" ++ @import("version.zig").string;

/// Execution context for one generation task. Async-task backends (video) need
/// a clock to wait between polls and a deadline to give up on.
pub const GenOptions = struct {
    io: std.Io,
    /// Async-task backends: seconds to wait between status polls.
    poll_interval_secs: u32 = 5,
    /// Async-task backends: overall deadline for one task, in seconds.
    timeout_secs: u32 = 600,
};

/// File extension for the asset a backend will write. Image backends follow
/// `--format` (the provider returns what it was asked for, or its own default);
/// `gemini_video` is pinned to mp4 because its API has no container parameter,
/// and naming the file anything else would be a lie.
pub fn outputExt(kind: types.BackendKind, format: ?[]const u8) []const u8 {
    return switch (kind) {
        .gemini_video => "mp4",
        else => util.extForFormat(format orelse kind.media().defaultFormat()),
    };
}

/// Construct the provider request body for a model's backend. For async-task
/// backends this is the *create* request body (what `--dry-run` prints).
pub fn buildBody(kind: types.BackendKind, allocator: std.mem.Allocator, req: types.GenRequest) ![]u8 {
    return switch (kind) {
        .openai_image => openai_image.buildBody(allocator, req),
        .azure_flux => azure_flux.buildBody(allocator, req),
        .qwen_image => qwen_image.buildBody(allocator, req),
        .seedance => seedance.buildBody(allocator, req),
        .volcengine_image => volcengine_image.buildBody(allocator, req),
        .gemini_video => gemini_video.buildBody(allocator, req),
    };
}

/// Result of one generation attempt. API/HTTP/credential failures are reported
/// via `err` (a human-readable message) rather than as Zig errors, so callers
/// can aggregate per-task outcomes. Only allocation failure propagates.
pub const GenResult = struct {
    /// One entry per produced asset (image or video), ready to write to disk.
    assets: [][]u8 = &.{},
    err: ?[]const u8 = null,

    pub fn ok(self: GenResult) bool {
        return self.err == null;
    }
};

const Outcome = union(enum) {
    assets: []types.Payload,
    api_error: []const u8,
};

/// The provider-specific half of the async-task flow. A backend is only listed
/// here when `BackendKind.flow()` reports `.async_task`.
const Async = struct {
    parse_create: *const fn (std.mem.Allocator, u16, []const u8) std.mem.Allocator.Error!wire.TaskOutcome,
    poll_url: *const fn (std.mem.Allocator, []const u8, []const u8) std.mem.Allocator.Error![]u8,
    parse_poll: *const fn (std.mem.Allocator, []const u8, []const u8, u16, []const u8) std.mem.Allocator.Error!wire.PollOutcome,
};

/// Exhaustive on purpose: a new backend must decide whether it polls or not.
fn asyncImpl(kind: types.BackendKind) ?Async {
    return switch (kind) {
        .seedance => .{
            .parse_create = seedance.parseCreate,
            .poll_url = seedance.pollUrl,
            .parse_poll = seedance.parsePoll,
        },
        .gemini_video => .{
            .parse_create = gemini_video.parseCreate,
            .poll_url = gemini_video.pollUrl,
            .parse_poll = gemini_video.parsePoll,
        },
        .openai_image, .azure_flux, .qwen_image, .volcengine_image => null,
    };
}

/// Credential headers for one endpoint, reused by every call of one task. Owns
/// the storage behind `extra`, so the slice it hands out stays valid as long as
/// the value is not copied after `extra()` is taken.
const Auth = struct {
    std: http.StdHeaders = .{
        .user_agent = .{ .override = user_agent },
        .content_type = .{ .override = "application/json" },
    },
    extra_buf: [1]http.Header = undefined,
    extra_len: usize = 0,

    fn extra(self: *const Auth) []const http.Header {
        return self.extra_buf[0..self.extra_len];
    }

    /// The same credential for a GET: no body, so no content type.
    fn getHeaders(self: *const Auth) http.StdHeaders {
        var h = self.std;
        h.content_type = .omit;
        return h;
    }
};

/// Resolve `--image` into a form the backend can send. Local files are read by
/// the caller; a URL is downloaded here when the provider only accepts bytes.
/// Returns the input unchanged when it already has bytes, or when the backend
/// accepts URLs directly. `error.InputImageUnsupported` means the backend takes
/// no image at all — the caller reports that as a usage error before this point.
pub fn resolveInputImage(
    client: *std.http.Client,
    allocator: std.mem.Allocator,
    kind: types.BackendKind,
    image: types.InputImage,
) !types.InputImage {
    if (kind.inputImageStyle() == .unsupported) return error.InputImageUnsupported;
    if (image.bytes != null) return image;
    if (kind.inputImageStyle() == .url_or_data_url) return image;
    if (!util.isHttpUrl(image.source)) return error.InputImageUnreadable;

    const res = try http.get(client, allocator, image.source, .{ .user_agent = .{ .override = user_agent } }, &.{});
    if (res.status >= 400) return error.InputImageDownloadFailed;
    return .{
        .source = image.source,
        .bytes = res.body,
        // A URL often has no extension to trust; the bytes do not lie.
        .mime = util.sniffImageMime(res.body) orelse image.mime,
    };
}

/// Generate assets for a single (model, endpoint) pair. `allocator` should be a
/// per-task arena; all returned memory lives in it.
pub fn generate(
    client: *std.http.Client,
    allocator: std.mem.Allocator,
    model: *const types.ModelConfig,
    endpoint: *const types.Endpoint,
    req: types.GenRequest,
    opts: GenOptions,
) std.mem.Allocator.Error!GenResult {
    // `auth = "none"` endpoints (a local model server) carry no credential;
    // every other scheme must resolve one before a request is attempted.
    const key: ?[]const u8 = switch (endpoint.auth) {
        .none => null,
        else => endpoint.resolved_key orelse {
            const env_name = endpoint.api_key_env orelse "(none)";
            return .{ .err = try std.fmt.allocPrint(
                allocator,
                "missing credential: set ${s} or add api_key to endpoint for model '{s}'",
                .{ env_name, model.name },
            ) };
        },
    };

    // Standard headers go through std.http's overridable `headers` field so
    // each is emitted exactly once. Putting User-Agent in `extra_headers`
    // instead produced a DUPLICATE User-Agent (std.http adds its own default),
    // which Azure's gateway rejects as "Bad Request - Invalid Header".
    var auth: Auth = .{};
    switch (endpoint.auth) {
        .none => {},
        .bearer => auth.std.authorization = .{
            .override = try std.fmt.allocPrint(allocator, "Bearer {s}", .{key.?}),
        },
        .api_key, .google_api_key => {
            auth.extra_buf[0] = .{ .name = endpoint.auth.headerName(), .value = key.? };
            auth.extra_len = 1;
        },
    }

    // Body construction is allocation-only except for one semantic case: a
    // backend that must inline image bytes was handed an image with none.
    const body = buildBody(model.backend, allocator, req) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InputImageNotFetched => return .{ .err = try std.fmt.allocPrint(
            allocator,
            "backend {s} needs the first-frame image as bytes; re-run with a local file or a fetchable URL",
            .{model.backend.toString()},
        ) },
    };

    return switch (model.backend.flow()) {
        .sync => generateSync(client, allocator, model.backend, endpoint, &auth, body),
        .async_task => generateAsync(client, allocator, model.backend, endpoint, &auth, body, opts),
    };
}

fn generateSync(
    client: *std.http.Client,
    allocator: std.mem.Allocator,
    kind: types.BackendKind,
    endpoint: *const types.Endpoint,
    auth: *const Auth,
    body: []const u8,
) std.mem.Allocator.Error!GenResult {
    const res = http.post(client, allocator, endpoint.base_url, auth.std, auth.extra(), body) catch |e| {
        return .{ .err = try std.fmt.allocPrint(allocator, "request failed: {s}", .{@errorName(e)}) };
    };

    const outcome = try parseResponse(allocator, res.status, res.body);
    switch (outcome) {
        .api_error => |msg| return .{ .err = msg },
        .assets => |payloads| return fetchPayloads(client, allocator, kind, auth, payloads, res.status),
    }
}

/// Create a task, then poll it until it produces assets. Poll failures are not
/// retried (the same policy as sync backends): whatever the provider reports is
/// what surfaces. `--poll-interval` and `--timeout` bound the wait.
fn generateAsync(
    client: *std.http.Client,
    allocator: std.mem.Allocator,
    kind: types.BackendKind,
    endpoint: *const types.Endpoint,
    auth: *const Auth,
    body: []const u8,
    opts: GenOptions,
) std.mem.Allocator.Error!GenResult {
    const impl = asyncImpl(kind) orelse return .{ .err = try std.fmt.allocPrint(
        allocator,
        "backend '{s}' has no async-task implementation",
        .{kind.toString()},
    ) };

    const created = http.post(client, allocator, endpoint.base_url, auth.std, auth.extra(), body) catch |e| {
        return .{ .err = try std.fmt.allocPrint(allocator, "request failed: {s}", .{@errorName(e)}) };
    };

    var task_id: []const u8 = undefined;
    switch (try impl.parse_create(allocator, created.status, created.body)) {
        .api_error => |msg| return .{ .err = msg },
        .done => |payloads| return fetchPayloads(client, allocator, kind, auth, payloads, created.status),
        .pending => |id| task_id = id,
    }

    const deadline = std.Io.Clock.awake.now(opts.io)
        .addDuration(std.Io.Duration.fromSeconds(opts.timeout_secs));
    const interval = std.Io.Duration.fromSeconds(@max(@as(u32, 1), opts.poll_interval_secs));

    while (true) {
        if (std.Io.Clock.awake.now(opts.io).nanoseconds >= deadline.nanoseconds) {
            return .{ .err = try std.fmt.allocPrint(
                allocator,
                "task {s} did not finish within {d}s (raise --timeout to wait longer)",
                .{ task_id, opts.timeout_secs },
            ) };
        }
        std.Io.sleep(opts.io, interval, .awake) catch |e| {
            return .{ .err = try std.fmt.allocPrint(
                allocator,
                "waiting for task {s} failed: {s}",
                .{ task_id, @errorName(e) },
            ) };
        };

        const url = try impl.poll_url(allocator, endpoint.base_url, task_id);
        const res = http.get(client, allocator, url, auth.getHeaders(), auth.extra()) catch |e| {
            return .{ .err = try std.fmt.allocPrint(allocator, "status request failed: {s}", .{@errorName(e)}) };
        };
        switch (try impl.parse_poll(allocator, endpoint.base_url, task_id, res.status, res.body)) {
            .api_error => |msg| return .{ .err = msg },
            .pending => {},
            .done => |payloads| return fetchPayloads(client, allocator, kind, auth, payloads, res.status),
        }
    }
}

/// Materialize payloads into bytes: base64 payloads pass through, URLs are
/// downloaded. Providers that gate their asset URLs behind the API credential
/// (Gemini Files) get the same headers as the create call; pre-signed CDN URLs
/// (Ark, Azure) must *not* carry them — Azure Storage rejects a request that has
/// both a SAS token and an Authorization header.
fn fetchPayloads(
    client: *std.http.Client,
    allocator: std.mem.Allocator,
    kind: types.BackendKind,
    auth: *const Auth,
    payloads: []types.Payload,
    status: u16,
) std.mem.Allocator.Error!GenResult {
    if (payloads.len == 0) {
        return .{ .err = try std.fmt.allocPrint(allocator, "no assets in response (HTTP {d})", .{status}) };
    }

    var out = try allocator.alloc([]u8, payloads.len);
    for (payloads, 0..) |p, i| {
        switch (p) {
            .bytes => |b| out[i] = b,
            .url => |u| {
                const with_auth = kind.assetNeedsAuth();
                const headers: http.StdHeaders = if (with_auth) auth.getHeaders() else .{
                    .user_agent = .{ .override = user_agent },
                };
                const extra: []const http.Header = if (with_auth) auth.extra() else &.{};
                const dl = http.get(client, allocator, u, headers, extra) catch |e| {
                    return .{ .err = try std.fmt.allocPrint(allocator, "failed to download asset url: {s}", .{@errorName(e)}) };
                };
                if (dl.status >= 400) {
                    return .{ .err = try std.fmt.allocPrint(allocator, "failed to download asset url (HTTP {d})", .{dl.status}) };
                }
                out[i] = dl.body;
            },
        }
    }
    return .{ .assets = out };
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

    const root = wire.rootObject(parsed.value) orelse
        return .{ .api_error = try std.fmt.allocPrint(allocator, "HTTP {d}: unexpected response", .{status}) };

    if (root.get("error")) |ev| {
        const msg = wire.extractErrorMessage(ev) orelse "unknown error";
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
        return .{ .assets = &.{} };
    };
    if (data_v != .array) return .{ .assets = &.{} };

    var list = std.ArrayList(types.Payload).empty;
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
    return .{ .assets = try list.toOwnedSlice(allocator) };
}

// ---- tests ----

test "parseResponse decodes b64_json" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    // "aGk=" -> "hi"
    const body = "{\"data\":[{\"b64_json\":\"aGk=\"}]}";
    const outcome = try parseResponse(arena.allocator(), 200, body);
    try std.testing.expect(outcome == .assets);
    try std.testing.expectEqual(@as(usize, 1), outcome.assets.len);
    try std.testing.expectEqualStrings("hi", outcome.assets[0].bytes);
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
    try std.testing.expect(outcome == .assets);
    try std.testing.expect(outcome.assets[0] == .url);
}

test "async-task backends and their implementations agree" {
    // `generate` picks the loop from `flow()`; keep the two switches honest.
    inline for (std.meta.tags(types.BackendKind)) |kind| {
        try std.testing.expectEqual(kind.flow() == .async_task, asyncImpl(kind) != null);
    }
}
