//! Configuration loading for imagine.
//!
//! Config is TOML at `~/.imagine/config.toml` by default (override with
//! `$IMAGINE_CONFIG` or `--config`). Legacy JSON configs are still accepted.
//! When no config file exists, a single-model **ephemeral** config can be
//! synthesized from environment variables (`IMAGINE_BASE_URL`, etc.).
//!
//! The file declares logical models, each mapping to a backend
//! and one-or-more endpoints (url + credential). Multiple endpoints on a model
//! are what allow the scheduler to fan a single model's work across keys.
//!
//! The loader is decoupled from the process environment via the small `Env`
//! interface so it can be unit-tested with a stub.

const std = @import("std");
const types = @import("types.zig");
const presets = @import("presets.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const default_rel_path = ".imagine/config.toml";
pub const legacy_json_rel_path = ".imagine/config.json";
pub const env_config_path = "IMAGINE_CONFIG";

/// Async (video) task defaults, overridable per config file and per CLI run.
pub const default_poll_interval: u32 = 5;
pub const default_task_timeout: u32 = 600;

/// Ephemeral (no-file) config env vars.
pub const env_base_url = "IMAGINE_BASE_URL";
pub const env_model = "IMAGINE_MODEL";
pub const env_api_model = "IMAGINE_API_MODEL";
pub const env_backend = "IMAGINE_BACKEND";
pub const env_auth = "IMAGINE_AUTH";
pub const env_api_key = "IMAGINE_API_KEY";
pub const env_api_key_env = "IMAGINE_API_KEY_ENV";
pub const env_default_api_key_env = "AZURE_OPENAI_APIKEY";
pub const env_output_dir = "IMAGINE_OUTPUT_DIR";
pub const env_concurrency = "IMAGINE_CONCURRENCY";
pub const env_size = "IMAGINE_SIZE";
pub const env_width = "IMAGINE_WIDTH";
pub const env_height = "IMAGINE_HEIGHT";
pub const env_format = "IMAGINE_FORMAT";
pub const env_compression = "IMAGINE_COMPRESSION";
pub const env_quality = "IMAGINE_QUALITY";
pub const env_steps = "IMAGINE_STEPS";
pub const env_duration = "IMAGINE_DURATION";
pub const env_resolution = "IMAGINE_RESOLUTION";
pub const env_ratio = "IMAGINE_RATIO";
pub const env_watermark = "IMAGINE_WATERMARK";
pub const env_poll_interval = "IMAGINE_POLL_INTERVAL";
pub const env_task_timeout = "IMAGINE_TASK_TIMEOUT";

pub const Format = enum {
    json,
    toml,

    pub fn fromString(s: []const u8) ?Format {
        if (std.ascii.eqlIgnoreCase(s, "json")) return .json;
        if (std.ascii.eqlIgnoreCase(s, "toml")) return .toml;
        return null;
    }

    pub fn toString(self: Format) []const u8 {
        return switch (self) {
            .json => "json",
            .toml => "toml",
        };
    }
};

pub const Source = enum {
    /// A config file (`--config` / `$IMAGINE_CONFIG` / `~/.imagine/config.toml`).
    file,
    /// Synthesized from `IMAGINE_*` environment variables (no config file).
    ephemeral,
    /// No config file and no ephemeral env: only the built-in presets, which is
    /// enough to run a first-party provider with just its API key set.
    preset,

    pub fn toString(self: Source) []const u8 {
        return switch (self) {
            .file => "file",
            .ephemeral => "ephemeral",
            .preset => "preset",
        };
    }
};

/// Minimal environment lookup so config parsing does not depend on a concrete
/// environment source (process env in production, a map in tests).
pub const Env = struct {
    context: *const anyopaque,
    func: *const fn (*const anyopaque, []const u8) ?[]const u8,

    pub fn get(self: Env, name: []const u8) ?[]const u8 {
        return self.func(self.context, name);
    }

    /// An Env that always returns null. Useful for tests and listing without
    /// resolving any credentials.
    pub fn empty() Env {
        const S = struct {
            fn f(_: *const anyopaque, _: []const u8) ?[]const u8 {
                return null;
            }
        };
        return .{ .context = undefined, .func = S.f };
    }
};

pub const Error = error{
    NotObject,
    MissingModels,
    EmptyModels,
    ModelNotObject,
    MissingBackend,
    UnknownBackend,
    MissingEndpoints,
    EmptyEndpoints,
    EndpointNotObject,
    MissingBaseUrl,
    UnknownAuth,
    BadFieldType,
    InvalidToml,
    UnsupportedToml,
    DuplicateTomlTable,
    EphemeralIncomplete,
    EphemeralNoCredential,
} || Allocator.Error || std.json.ParseError(std.json.Scanner);

pub const Config = struct {
    gpa: Allocator,
    arena: *std.heap.ArenaAllocator,
    output_dir: []const u8,
    /// 0 means "auto" (derive from endpoint count).
    concurrency: u32,
    /// Async (video) tasks: seconds between provider status polls.
    poll_interval: u32 = default_poll_interval,
    /// Async (video) tasks: give up on one task after this many seconds.
    task_timeout: u32 = default_task_timeout,
    models: []types.ModelConfig,
    /// Built-in convenience models (see `presets.zig`). Looked up by name only
    /// when the user's own models do not define that name, so a config entry
    /// always wins over a preset.
    presets: []types.ModelConfig = &.{},
    /// Path the config was loaded from, if any (informational).
    source_path: ?[]const u8 = null,
    source_format: ?Format = null,
    source: Source = .file,
    /// When `source == .ephemeral`, whether `IMAGINE_API_MODEL` set api_model.
    ephemeral_api_model_set: bool = false,

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
        self.gpa.destroy(self.arena);
    }

    pub fn findModel(self: *const Config, name: []const u8) ?*const types.ModelConfig {
        for (self.models) |*m| {
            if (std.mem.eql(u8, m.name, name)) return m;
        }
        return null;
    }

    /// A preset is only reachable when no configured model claims the name.
    pub fn findPreset(self: *const Config, name: []const u8) ?*const types.ModelConfig {
        if (self.findModel(name) != null) return null;
        for (self.presets) |*m| {
            if (std.mem.eql(u8, m.name, name)) return m;
        }
        return null;
    }
};

/// Materialize `presets.catalog` into models, resolving each credential from the
/// environment so `imagine models` can report readiness.
fn loadPresets(arena: Allocator, env: Env) ![]types.ModelConfig {
    const list = try arena.alloc(types.ModelConfig, presets.catalog.len);
    for (presets.catalog, 0..) |p, i| {
        const endpoints = try arena.alloc(types.Endpoint, 1);
        endpoints[0] = .{
            .base_url = try arena.dupe(u8, p.base_url),
            .api_key_env = try arena.dupe(u8, p.api_key_env),
            .auth = p.auth,
        };
        try resolveEndpointKeys(arena, env, &endpoints[0]);
        list[i] = .{
            .name = try arena.dupe(u8, p.name),
            .backend = p.backend,
            .api_model = try arena.dupe(u8, p.api_model),
            .endpoints = endpoints,
        };
    }
    return list;
}

/// Resolve the config file path. Precedence: explicit > $IMAGINE_CONFIG >
/// $HOME/.imagine/config.toml. Returned memory is owned by `arena`.
pub fn resolvePath(arena: Allocator, env: Env, explicit: ?[]const u8) ![]u8 {
    if (explicit) |p| return arena.dupe(u8, p);
    if (env.get(env_config_path)) |p| {
        if (p.len > 0) return arena.dupe(u8, p);
    }
    const home = env.get("HOME") orelse env.get("USERPROFILE") orelse ".";
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ home, default_rel_path });
}

/// Legacy default used only as a read fallback when the TOML default is absent.
pub fn resolveLegacyJsonPath(arena: Allocator, env: Env) ![]u8 {
    const home = env.get("HOME") orelse env.get("USERPROFILE") orelse ".";
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ home, legacy_json_rel_path });
}

fn envNonEmpty(env: Env, name: []const u8) ?[]const u8 {
    const v = env.get(name) orelse return null;
    const t = std.mem.trim(u8, v, " \t\r\n");
    if (t.len == 0) return null;
    return t;
}

/// True if the caller appears to be attempting ephemeral (no-file) mode.
pub fn ephemeralIntent(env: Env) bool {
    return envNonEmpty(env, env_base_url) != null or
        envNonEmpty(env, env_model) != null or
        envNonEmpty(env, env_api_key) != null or
        envNonEmpty(env, env_api_key_env) != null or
        envNonEmpty(env, env_backend) != null;
}

pub const EphemeralMissing = struct {
    base_url: bool = false,
    model: bool = false,
    credential: bool = false,
};

/// The ephemeral auth scheme, or null when `IMAGINE_AUTH` is unset (or names a
/// scheme no one knows yet, which `loadEphemeral` reports as `UnknownAuth`).
fn ephemeralAuth(env: Env) ?types.AuthScheme {
    const s = envNonEmpty(env, env_auth) orelse return null;
    return types.AuthScheme.fromString(s);
}

/// `IMAGINE_AUTH=none` targets a local model server, which takes no credential,
/// so an ephemeral config pointing at one is complete without a key.
pub fn ephemeralNeedsCredential(env: Env) bool {
    if (ephemeralAuth(env)) |a| {
        if (a == types.AuthScheme.none) return false;
    }
    return true;
}

/// Credential env var used when `IMAGINE_API_KEY_ENV` names none: the selected
/// backend's canonical one (`ARK_API_KEY` for the Ark backends, `GEMINI_API_KEY`
/// for Gemini, `AZURE_OPENAI_APIKEY` otherwise). Without this, an ephemeral run
/// against a video backend would ask for an Azure key.
pub fn ephemeralKeyEnv(env: Env) []const u8 {
    if (envNonEmpty(env, env_api_key_env)) |name| return name;
    const backend_str = envNonEmpty(env, env_backend) orelse return env_default_api_key_env;
    const backend = types.BackendKind.fromString(backend_str) orelse return env_default_api_key_env;
    return backend.defaultKeyEnv();
}

pub fn ephemeralMissing(env: Env) EphemeralMissing {
    var m: EphemeralMissing = .{};
    if (envNonEmpty(env, env_base_url) == null) m.base_url = true;
    if (envNonEmpty(env, env_model) == null) m.model = true;

    if (!ephemeralNeedsCredential(env)) return m;

    const has_literal = envNonEmpty(env, env_api_key) != null;
    const has_from_env = envNonEmpty(env, ephemeralKeyEnv(env)) != null;
    if (!has_literal and !has_from_env) m.credential = true;
    return m;
}

pub fn ephemeralReady(env: Env) bool {
    const m = ephemeralMissing(env);
    return !m.base_url and !m.model and !m.credential;
}

/// Human-readable hint for agents when neither file nor ephemeral config works.
pub fn noConfigHint(arena: Allocator, env: Env) ![]const u8 {
    if (ephemeralIntent(env)) {
        const m = ephemeralMissing(env);
        var list = std.ArrayList(u8).empty;
        try list.appendSlice(arena, "ephemeral config incomplete; set:");
        if (m.base_url) try list.appendSlice(arena, " IMAGINE_BASE_URL");
        if (m.model) try list.appendSlice(arena, " IMAGINE_MODEL");
        if (m.credential) {
            try list.appendSlice(arena, " ");
            try list.appendSlice(arena, ephemeralKeyEnv(env));
            try list.appendSlice(arena, "|IMAGINE_API_KEY|IMAGINE_API_KEY_ENV");
        }
        try list.appendSlice(arena, "\nor run 'imagine config init' for a multi-model config file\n");
        return list.toOwnedSlice(arena);
    }
    return arena.dupe(u8,
        \\no config file found and ephemeral env incomplete
        \\  file: run 'imagine config init'  (or set IMAGINE_CONFIG / --config)
        \\  ephemeral: set IMAGINE_BASE_URL + IMAGINE_MODEL + a credential env:
        \\             AZURE_OPENAI_APIKEY (default), ARK_API_KEY, GEMINI_API_KEY,
        \\             or IMAGINE_API_KEY / IMAGINE_API_KEY_ENV
        \\
    );
}

fn parseEnvU32(raw: []const u8) ?u32 {
    return std.fmt.parseInt(u32, raw, 10) catch null;
}

fn parseEnvBool(raw: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(raw, "true") or std.mem.eql(u8, raw, "1")) return true;
    if (std.ascii.eqlIgnoreCase(raw, "false") or std.mem.eql(u8, raw, "0")) return false;
    return null;
}

/// Synthesize a single-model config from environment variables.
pub fn loadEphemeral(gpa: Allocator, env: Env) Error!Config {
    const base_url = envNonEmpty(env, env_base_url) orelse return Error.EphemeralIncomplete;
    const model_name = envNonEmpty(env, env_model) orelse return Error.EphemeralIncomplete;

    const arena_ptr = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena_ptr);
    arena_ptr.* = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_ptr.deinit();
    const arena = arena_ptr.allocator();

    const backend_str = envNonEmpty(env, env_backend) orelse "openai_image";
    const backend = types.BackendKind.fromString(backend_str) orelse return Error.UnknownBackend;

    const auth_str = envNonEmpty(env, env_auth) orelse "bearer";
    const auth = types.AuthScheme.fromString(auth_str) orelse return Error.UnknownAuth;

    var ep: types.Endpoint = .{
        .base_url = try arena.dupe(u8, base_url),
        .auth = auth,
    };

    const api_model_set = envNonEmpty(env, env_api_model) != null;
    const api_model = if (envNonEmpty(env, env_api_model)) |am|
        try arena.dupe(u8, am)
    else
        try arena.dupe(u8, model_name);

    if (envNonEmpty(env, env_api_key)) |k| {
        ep.api_key = try arena.dupe(u8, k);
        ep.resolved_key = ep.api_key;
    } else if (auth == .none) {
        // Local server: nothing to resolve, and no auth header is sent.
    } else {
        const key_env = ephemeralKeyEnv(env);
        ep.api_key_env = try arena.dupe(u8, key_env);
        if (envNonEmpty(env, key_env)) |val| {
            ep.resolved_key = try arena.dupe(u8, val);
        } else {
            return Error.EphemeralNoCredential;
        }
    }

    var defaults: types.ModelDefaults = .{};
    if (envNonEmpty(env, env_size)) |s| defaults.size = try arena.dupe(u8, s);
    if (envNonEmpty(env, env_format)) |s| defaults.output_format = try arena.dupe(u8, s);
    if (envNonEmpty(env, env_quality)) |s| defaults.quality = try arena.dupe(u8, s);
    if (envNonEmpty(env, env_width)) |s| defaults.width = parseEnvU32(s) orelse return Error.BadFieldType;
    if (envNonEmpty(env, env_height)) |s| defaults.height = parseEnvU32(s) orelse return Error.BadFieldType;
    if (envNonEmpty(env, env_compression)) |s| defaults.output_compression = parseEnvU32(s) orelse return Error.BadFieldType;
    if (envNonEmpty(env, env_steps)) |s| defaults.steps = parseEnvU32(s) orelse return Error.BadFieldType;
    if (envNonEmpty(env, env_duration)) |s| defaults.duration = parseEnvU32(s) orelse return Error.BadFieldType;
    if (envNonEmpty(env, env_resolution)) |s| defaults.resolution = try arena.dupe(u8, s);
    if (envNonEmpty(env, env_ratio)) |s| defaults.ratio = try arena.dupe(u8, s);
    if (envNonEmpty(env, env_watermark)) |s| defaults.watermark = parseEnvBool(s) orelse return Error.BadFieldType;

    const endpoints = try arena.alloc(types.Endpoint, 1);
    endpoints[0] = ep;

    const models = try arena.alloc(types.ModelConfig, 1);
    models[0] = .{
        .name = try arena.dupe(u8, model_name),
        .backend = backend,
        .api_model = api_model,
        .endpoints = endpoints,
        .defaults = defaults,
    };

    const output_dir = if (envNonEmpty(env, env_output_dir)) |d|
        try arena.dupe(u8, d)
    else
        try arena.dupe(u8, "~/.imagine/outputs");

    var concurrency: u32 = 0;
    if (envNonEmpty(env, env_concurrency)) |s| {
        concurrency = parseEnvU32(s) orelse return Error.BadFieldType;
    }
    var poll_interval: u32 = default_poll_interval;
    if (envNonEmpty(env, env_poll_interval)) |s| {
        poll_interval = parseEnvU32(s) orelse return Error.BadFieldType;
    }
    var task_timeout: u32 = default_task_timeout;
    if (envNonEmpty(env, env_task_timeout)) |s| {
        task_timeout = parseEnvU32(s) orelse return Error.BadFieldType;
    }

    return .{
        .gpa = gpa,
        .arena = arena_ptr,
        .output_dir = output_dir,
        .concurrency = concurrency,
        .poll_interval = poll_interval,
        .task_timeout = task_timeout,
        .models = models,
        .presets = try loadPresets(arena, env),
        .source = .ephemeral,
        .ephemeral_api_model_set = api_model_set,
    };
}

/// A config with no user models at all: the built-in presets and nothing else.
/// Reached when no config file and no ephemeral env exist, which is what makes
/// `ARK_API_KEY=… imagine generate -m <preset>` work out of the box.
pub fn loadPresetsOnly(gpa: Allocator, env: Env) Error!Config {
    const arena_ptr = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena_ptr);
    arena_ptr.* = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_ptr.deinit();
    const arena = arena_ptr.allocator();

    return .{
        .gpa = gpa,
        .arena = arena_ptr,
        .output_dir = try arena.dupe(u8, "~/.imagine/outputs"),
        .concurrency = 0,
        .models = &.{},
        .presets = try loadPresets(arena, env),
        .source = .preset,
    };
}

pub fn inferFormatFromPath(path: []const u8) ?Format {
    if (std.mem.endsWith(u8, path, ".json")) return .json;
    if (std.mem.endsWith(u8, path, ".toml")) return .toml;
    return null;
}

fn inferFormat(path: ?[]const u8, bytes: []const u8) Format {
    if (path) |p| {
        if (inferFormatFromPath(p)) |f| return f;
    }
    const trimmed = std.mem.trimStart(u8, bytes, " \t\r\n");
    if (trimmed.len > 0 and trimmed[0] == '{') return .json;
    return .toml;
}

fn getStr(obj: *const std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn getU32(obj: *const std.json.ObjectMap, key: []const u8) Error!?u32 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| if (i < 0) Error.BadFieldType else @intCast(i),
        .null => null,
        else => Error.BadFieldType,
    };
}

fn parseDefaults(arena: Allocator, obj: *const std.json.ObjectMap) !types.ModelDefaults {
    var d: types.ModelDefaults = .{};
    if (getStr(obj, "size")) |s| d.size = try arena.dupe(u8, s);
    if (getStr(obj, "output_format")) |s| d.output_format = try arena.dupe(u8, s);
    if (getStr(obj, "quality")) |s| d.quality = try arena.dupe(u8, s);
    if (getStr(obj, "resolution")) |s| d.resolution = try arena.dupe(u8, s);
    if (getStr(obj, "ratio")) |s| d.ratio = try arena.dupe(u8, s);
    d.width = try getU32(obj, "width");
    d.height = try getU32(obj, "height");
    d.output_compression = try getU32(obj, "output_compression");
    d.steps = try getU32(obj, "steps");
    d.duration = try getU32(obj, "duration");
    if (obj.get("watermark")) |wv| {
        if (wv == .bool) d.watermark = wv.bool;
    }
    return d;
}

fn parseEndpoint(arena: Allocator, env: Env, v: Value) !types.Endpoint {
    if (v != .object) return Error.EndpointNotObject;
    const obj = &v.object;
    const base_url = getStr(obj, "base_url") orelse return Error.MissingBaseUrl;

    var ep: types.Endpoint = .{ .base_url = try arena.dupe(u8, base_url) };

    if (getStr(obj, "api_key")) |k| ep.api_key = try arena.dupe(u8, k);
    if (getStr(obj, "api_key_env")) |k| ep.api_key_env = try arena.dupe(u8, k);
    if (getStr(obj, "auth")) |a| {
        ep.auth = types.AuthScheme.fromString(a) orelse return Error.UnknownAuth;
    }

    // Resolve credential now when possible, but never fail here: listing and
    // `config show` must work without keys present. Generation validates later.
    // Trim surrounding whitespace/newlines: a trailing '\n' (common with
    // `export KEY=$(cat file)`) would otherwise produce an invalid auth header.
    if (ep.api_key) |k| {
        const t = std.mem.trim(u8, k, " \t\r\n");
        if (t.len > 0) ep.resolved_key = t;
    } else if (ep.api_key_env) |name| {
        if (env.get(name)) |val| {
            const t = std.mem.trim(u8, val, " \t\r\n");
            if (t.len > 0) ep.resolved_key = try arena.dupe(u8, t);
        }
    }
    return ep;
}

fn parseModel(arena: Allocator, env: Env, name: []const u8, v: Value) !types.ModelConfig {
    if (v != .object) return Error.ModelNotObject;
    const obj = &v.object;

    const backend_str = getStr(obj, "backend") orelse return Error.MissingBackend;
    const backend = types.BackendKind.fromString(backend_str) orelse return Error.UnknownBackend;

    const endpoints_v = obj.get("endpoints") orelse return Error.MissingEndpoints;
    if (endpoints_v != .array) return Error.MissingEndpoints;
    const arr = endpoints_v.array;
    if (arr.items.len == 0) return Error.EmptyEndpoints;

    const endpoints = try arena.alloc(types.Endpoint, arr.items.len);
    for (arr.items, 0..) |item, i| {
        endpoints[i] = try parseEndpoint(arena, env, item);
    }

    const api_model = if (getStr(obj, "api_model")) |am|
        try arena.dupe(u8, am)
    else
        try arena.dupe(u8, name);

    var defaults: types.ModelDefaults = .{};
    if (obj.get("defaults")) |dv| {
        if (dv == .object) defaults = try parseDefaults(arena, &dv.object);
    }

    return .{
        .name = try arena.dupe(u8, name),
        .backend = backend,
        .api_model = api_model,
        .endpoints = endpoints,
        .defaults = defaults,
    };
}

const ModelBuilder = struct {
    name: []const u8,
    backend: ?types.BackendKind = null,
    api_model: ?[]const u8 = null,
    endpoints: std.ArrayList(types.Endpoint) = .empty,
    defaults: types.ModelDefaults = .{},
};

const TomlScalar = union(enum) {
    string: []const u8,
    integer: i64,
    boolean: bool,
};

const TomlSection = union(enum) {
    root,
    model: *ModelBuilder,
    defaults: *ModelBuilder,
    endpoint: *types.Endpoint,
};

fn stripTomlComment(line: []const u8) []const u8 {
    var quote: u8 = 0;
    var escaped = false;
    for (line, 0..) |c, i| {
        if (quote != 0) {
            if (quote == '"' and escaped) {
                escaped = false;
            } else if (quote == '"' and c == '\\') {
                escaped = true;
            } else if (c == quote) {
                quote = 0;
            }
            continue;
        }
        if (c == '"' or c == '\'') {
            quote = c;
        } else if (c == '#') {
            return std.mem.trim(u8, line[0..i], " \t\r\n");
        }
    }
    return std.mem.trim(u8, line, " \t\r\n");
}

fn findTomlEquals(line: []const u8) ?usize {
    var quote: u8 = 0;
    var escaped = false;
    for (line, 0..) |c, i| {
        if (quote != 0) {
            if (quote == '"' and escaped) {
                escaped = false;
            } else if (quote == '"' and c == '\\') {
                escaped = true;
            } else if (c == quote) {
                quote = 0;
            }
            continue;
        }
        if (c == '"' or c == '\'') {
            quote = c;
        } else if (c == '=') {
            return i;
        }
    }
    return null;
}

fn parseTomlQuotedString(arena: Allocator, raw: []const u8) Error![]const u8 {
    if (raw.len < 2) return Error.InvalidToml;
    const q = raw[0];
    if ((q != '"' and q != '\'') or raw[raw.len - 1] != q) return Error.InvalidToml;
    const inner = raw[1 .. raw.len - 1];
    if (q == '\'') return arena.dupe(u8, inner);

    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        const c = inner[i];
        if (c != '\\') {
            try out.append(arena, c);
            continue;
        }
        i += 1;
        if (i >= inner.len) return Error.InvalidToml;
        switch (inner[i]) {
            '"' => try out.append(arena, '"'),
            '\\' => try out.append(arena, '\\'),
            'n' => try out.append(arena, '\n'),
            'r' => try out.append(arena, '\r'),
            't' => try out.append(arena, '\t'),
            else => return Error.UnsupportedToml,
        }
    }
    return out.toOwnedSlice(arena);
}

fn parseTomlKeySegment(arena: Allocator, raw: []const u8) Error![]const u8 {
    const s = std.mem.trim(u8, raw, " \t\r\n");
    if (s.len == 0) return Error.InvalidToml;
    if (s[0] == '"' or s[0] == '\'') return parseTomlQuotedString(arena, s);
    for (s) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return Error.InvalidToml;
    }
    return arena.dupe(u8, s);
}

fn parseTomlPath(arena: Allocator, raw: []const u8) Error![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    var i: usize = 0;
    while (i < raw.len) {
        while (i < raw.len and std.ascii.isWhitespace(raw[i])) i += 1;
        if (i >= raw.len) return Error.InvalidToml;

        const start = i;
        if (raw[i] == '"' or raw[i] == '\'') {
            const q = raw[i];
            i += 1;
            var escaped = false;
            while (i < raw.len) : (i += 1) {
                const c = raw[i];
                if (q == '"' and escaped) {
                    escaped = false;
                } else if (q == '"' and c == '\\') {
                    escaped = true;
                } else if (c == q) {
                    i += 1;
                    break;
                }
            }
            if (i > raw.len or raw[i - 1] != q) return Error.InvalidToml;
        } else {
            while (i < raw.len and raw[i] != '.' and !std.ascii.isWhitespace(raw[i])) i += 1;
        }
        try out.append(arena, try parseTomlKeySegment(arena, raw[start..i]));

        while (i < raw.len and std.ascii.isWhitespace(raw[i])) i += 1;
        if (i >= raw.len) break;
        if (raw[i] != '.') return Error.InvalidToml;
        i += 1;
    }
    return out.toOwnedSlice(arena);
}

fn parseTomlScalar(arena: Allocator, raw: []const u8) Error!TomlScalar {
    const s = std.mem.trim(u8, raw, " \t\r\n");
    if (s.len == 0) return Error.InvalidToml;
    if (s[0] == '"' or s[0] == '\'') return .{ .string = try parseTomlQuotedString(arena, s) };
    if (std.mem.eql(u8, s, "true")) return .{ .boolean = true };
    if (std.mem.eql(u8, s, "false")) return .{ .boolean = false };
    return .{ .integer = std.fmt.parseInt(i64, s, 10) catch return Error.InvalidToml };
}

fn scalarString(v: TomlScalar) Error![]const u8 {
    return switch (v) {
        .string => |s| s,
        else => Error.BadFieldType,
    };
}

fn scalarU32(v: TomlScalar) Error!u32 {
    return switch (v) {
        .integer => |i| if (i < 0) Error.BadFieldType else @intCast(i),
        else => Error.BadFieldType,
    };
}

fn scalarBool(v: TomlScalar) Error!bool {
    return switch (v) {
        .boolean => |b| b,
        else => Error.BadFieldType,
    };
}

fn getOrPutModel(models: *std.array_hash_map.String(ModelBuilder), gpa: Allocator, name: []const u8) !*ModelBuilder {
    const gop = try models.getOrPut(gpa, name);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{ .name = name };
    }
    return gop.value_ptr;
}

fn parseTomlHeader(
    arena: Allocator,
    gpa: Allocator,
    models: *std.array_hash_map.String(ModelBuilder),
    line: []const u8,
) Error!TomlSection {
    const is_array = std.mem.startsWith(u8, line, "[[");
    const inner = if (is_array) blk: {
        if (!std.mem.endsWith(u8, line, "]]")) return Error.InvalidToml;
        break :blk std.mem.trim(u8, line[2 .. line.len - 2], " \t\r\n");
    } else blk: {
        if (!std.mem.startsWith(u8, line, "[") or !std.mem.endsWith(u8, line, "]")) return Error.InvalidToml;
        break :blk std.mem.trim(u8, line[1 .. line.len - 1], " \t\r\n");
    };

    const parts = try parseTomlPath(arena, inner);
    if (parts.len == 0) return Error.InvalidToml;
    if (!std.mem.eql(u8, parts[0], "models")) return Error.UnsupportedToml;
    if (parts.len < 2) return Error.InvalidToml;

    const model = try getOrPutModel(models, gpa, parts[1]);
    if (is_array) {
        if (parts.len != 3 or !std.mem.eql(u8, parts[2], "endpoints")) return Error.UnsupportedToml;
        try model.endpoints.append(arena, .{ .base_url = "" });
        return .{ .endpoint = &model.endpoints.items[model.endpoints.items.len - 1] };
    }
    if (parts.len == 2) return .{ .model = model };
    if (parts.len == 3 and std.mem.eql(u8, parts[2], "defaults")) return .{ .defaults = model };
    return Error.UnsupportedToml;
}

fn applyTomlPair(arena: Allocator, section: TomlSection, key: []const u8, value: TomlScalar) Error!void {
    switch (section) {
        .root => {
            return Error.UnsupportedToml;
        },
        .model => |m| {
            if (std.mem.eql(u8, key, "backend")) {
                const s = try scalarString(value);
                m.backend = types.BackendKind.fromString(s) orelse return Error.UnknownBackend;
            } else if (std.mem.eql(u8, key, "api_model")) {
                m.api_model = try arena.dupe(u8, try scalarString(value));
            } else {
                return Error.UnsupportedToml;
            }
        },
        .defaults => |m| {
            if (std.mem.eql(u8, key, "size")) {
                m.defaults.size = try arena.dupe(u8, try scalarString(value));
            } else if (std.mem.eql(u8, key, "output_format")) {
                m.defaults.output_format = try arena.dupe(u8, try scalarString(value));
            } else if (std.mem.eql(u8, key, "quality")) {
                m.defaults.quality = try arena.dupe(u8, try scalarString(value));
            } else if (std.mem.eql(u8, key, "width")) {
                m.defaults.width = try scalarU32(value);
            } else if (std.mem.eql(u8, key, "height")) {
                m.defaults.height = try scalarU32(value);
            } else if (std.mem.eql(u8, key, "output_compression")) {
                m.defaults.output_compression = try scalarU32(value);
            } else if (std.mem.eql(u8, key, "steps")) {
                m.defaults.steps = try scalarU32(value);
            } else if (std.mem.eql(u8, key, "duration")) {
                m.defaults.duration = try scalarU32(value);
            } else if (std.mem.eql(u8, key, "resolution")) {
                m.defaults.resolution = try arena.dupe(u8, try scalarString(value));
            } else if (std.mem.eql(u8, key, "ratio")) {
                m.defaults.ratio = try arena.dupe(u8, try scalarString(value));
            } else if (std.mem.eql(u8, key, "watermark")) {
                m.defaults.watermark = try scalarBool(value);
            } else {
                return Error.UnsupportedToml;
            }
        },
        .endpoint => |ep| {
            if (std.mem.eql(u8, key, "base_url")) {
                ep.base_url = try arena.dupe(u8, try scalarString(value));
            } else if (std.mem.eql(u8, key, "api_key")) {
                ep.api_key = try arena.dupe(u8, try scalarString(value));
            } else if (std.mem.eql(u8, key, "api_key_env")) {
                ep.api_key_env = try arena.dupe(u8, try scalarString(value));
            } else if (std.mem.eql(u8, key, "auth")) {
                const s = try scalarString(value);
                ep.auth = types.AuthScheme.fromString(s) orelse return Error.UnknownAuth;
            } else {
                return Error.UnsupportedToml;
            }
        },
    }
}

/// Root-level (`[models...]`-less) TOML keys.
const RootBuilder = struct {
    output_dir: ?[]const u8 = null,
    concurrency: u32 = 0,
    poll_interval: u32 = default_poll_interval,
    task_timeout: u32 = default_task_timeout,
};

fn applyTomlRootPair(arena: Allocator, key: []const u8, value: TomlScalar, root: *RootBuilder) Error!void {
    if (std.mem.eql(u8, key, "output_dir")) {
        root.output_dir = try arena.dupe(u8, try scalarString(value));
    } else if (std.mem.eql(u8, key, "concurrency")) {
        root.concurrency = try scalarU32(value);
    } else if (std.mem.eql(u8, key, "poll_interval")) {
        root.poll_interval = try scalarU32(value);
    } else if (std.mem.eql(u8, key, "task_timeout")) {
        root.task_timeout = try scalarU32(value);
    } else {
        return Error.UnsupportedToml;
    }
}

fn resolveEndpointKeys(arena: Allocator, env: Env, ep: *types.Endpoint) !void {
    if (ep.api_key) |k| {
        const t = std.mem.trim(u8, k, " \t\r\n");
        if (t.len > 0) ep.resolved_key = t;
    } else if (ep.api_key_env) |name| {
        if (env.get(name)) |val| {
            const t = std.mem.trim(u8, val, " \t\r\n");
            if (t.len > 0) ep.resolved_key = try arena.dupe(u8, t);
        }
    }
}

/// Parse config from raw TOML bytes.
pub fn loadTomlFromBytes(gpa: Allocator, toml_bytes: []const u8, env: Env) Error!Config {
    const arena_ptr = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena_ptr);
    arena_ptr.* = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_ptr.deinit();
    const arena = arena_ptr.allocator();

    var root: RootBuilder = .{};
    var models = std.array_hash_map.String(ModelBuilder).empty;
    defer models.deinit(gpa);

    var section: TomlSection = .root;
    var lines = std.mem.splitScalar(u8, toml_bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = stripTomlComment(raw_line);
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "[")) {
            section = try parseTomlHeader(arena, gpa, &models, line);
            continue;
        }

        const eq = findTomlEquals(line) orelse return Error.InvalidToml;
        const key = try parseTomlKeySegment(arena, line[0..eq]);
        const value = try parseTomlScalar(arena, line[eq + 1 ..]);
        switch (section) {
            .root => try applyTomlRootPair(arena, key, value, &root),
            else => try applyTomlPair(arena, section, key, value),
        }
    }

    if (models.count() == 0) return Error.MissingModels;

    const out_models = try arena.alloc(types.ModelConfig, models.count());
    for (models.values(), 0..) |*m, i| {
        if (m.backend == null) return Error.MissingBackend;
        if (m.endpoints.items.len == 0) return Error.MissingEndpoints;

        const endpoints = try arena.alloc(types.Endpoint, m.endpoints.items.len);
        for (m.endpoints.items, 0..) |ep_in, ei| {
            if (ep_in.base_url.len == 0) return Error.MissingBaseUrl;
            endpoints[ei] = ep_in;
            try resolveEndpointKeys(arena, env, &endpoints[ei]);
        }

        out_models[i] = .{
            .name = m.name,
            .backend = m.backend.?,
            .api_model = if (m.api_model) |am| am else m.name,
            .endpoints = endpoints,
            .defaults = m.defaults,
        };
    }

    return .{
        .gpa = gpa,
        .arena = arena_ptr,
        .output_dir = root.output_dir orelse try arena.dupe(u8, "~/.imagine/outputs"),
        .concurrency = root.concurrency,
        .poll_interval = root.poll_interval,
        .task_timeout = root.task_timeout,
        .models = out_models,
        .presets = try loadPresets(arena, env),
        .source_format = .toml,
    };
}

/// Parse config from raw JSON bytes. `gpa` backs both the returned Config's
/// arena and the temporary JSON parse; all retained data is copied into the
/// arena so the parse scratch can be freed.
pub fn loadJsonFromBytes(gpa: Allocator, json_bytes: []const u8, env: Env) Error!Config {
    const arena_ptr = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena_ptr);
    arena_ptr.* = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_ptr.deinit();
    const arena = arena_ptr.allocator();

    var parsed = try std.json.parseFromSlice(Value, gpa, json_bytes, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return Error.NotObject;
    const root = &parsed.value.object;

    const output_dir = if (getStr(root, "output_dir")) |d|
        try arena.dupe(u8, d)
    else
        try arena.dupe(u8, "~/.imagine/outputs");

    const concurrency: u32 = (try getU32(root, "concurrency")) orelse 0;
    const poll_interval: u32 = (try getU32(root, "poll_interval")) orelse default_poll_interval;
    const task_timeout: u32 = (try getU32(root, "task_timeout")) orelse default_task_timeout;

    const models_v = root.get("models") orelse return Error.MissingModels;
    if (models_v != .object) return Error.MissingModels;
    const models_obj = &models_v.object;
    if (models_obj.count() == 0) return Error.EmptyModels;

    const models = try arena.alloc(types.ModelConfig, models_obj.count());
    var it = models_obj.iterator();
    var i: usize = 0;
    while (it.next()) |entry| : (i += 1) {
        models[i] = try parseModel(arena, env, entry.key_ptr.*, entry.value_ptr.*);
    }

    return .{
        .gpa = gpa,
        .arena = arena_ptr,
        .output_dir = output_dir,
        .concurrency = concurrency,
        .poll_interval = poll_interval,
        .task_timeout = task_timeout,
        .models = models,
        .presets = try loadPresets(arena, env),
        .source_format = .json,
    };
}

/// Parse config from raw bytes, auto-detecting TOML/JSON by extension when a
/// path is available or by the first non-whitespace byte otherwise.
pub fn loadFromBytesAs(gpa: Allocator, bytes: []const u8, env: Env, format: Format) Error!Config {
    return switch (format) {
        .json => loadJsonFromBytes(gpa, bytes, env),
        .toml => loadTomlFromBytes(gpa, bytes, env),
    };
}

pub fn loadFromBytes(gpa: Allocator, bytes: []const u8, env: Env) Error!Config {
    return loadFromBytesAs(gpa, bytes, env, inferFormat(null, bytes));
}

/// Read and parse the config file at `path`.
pub fn loadFromFile(gpa: Allocator, io: std.Io, path: []const u8, env: Env) !Config {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(8 * 1024 * 1024)) catch |err| {
        return err;
    };
    defer gpa.free(bytes);
    const fmt = inferFormat(path, bytes);
    var cfg = try loadFromBytesAs(gpa, bytes, env, fmt);
    cfg.source_path = try cfg.arena.allocator().dupe(u8, path);
    cfg.source_format = fmt;
    return cfg;
}

fn appendFmt(list: *std.ArrayList(u8), arena: Allocator, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(arena, fmt, args);
    try list.appendSlice(arena, s);
}

fn jsonStringAlloc(arena: Allocator, s: []const u8) ![]const u8 {
    return std.json.Stringify.valueAlloc(arena, s, .{});
}

fn tomlStringAlloc(arena: Allocator, s: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.append(arena, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(arena, "\\\""),
            '\\' => try out.appendSlice(arena, "\\\\"),
            '\n' => try out.appendSlice(arena, "\\n"),
            '\r' => try out.appendSlice(arena, "\\r"),
            '\t' => try out.appendSlice(arena, "\\t"),
            else => try out.append(arena, c),
        }
    }
    try out.append(arena, '"');
    return out.toOwnedSlice(arena);
}

fn defaultsAny(d: types.ModelDefaults) bool {
    return d.size != null or d.width != null or d.height != null or
        d.output_format != null or d.output_compression != null or d.quality != null or
        d.steps != null or d.duration != null or d.resolution != null or d.ratio != null or
        d.watermark != null;
}

fn appendJsonFieldString(out: *std.ArrayList(u8), arena: Allocator, name: []const u8, value: []const u8, first: *bool, indent: []const u8) !void {
    if (!first.*) try out.appendSlice(arena, ",\n");
    first.* = false;
    try appendFmt(out, arena, "{s}{s}: {s}", .{ indent, try jsonStringAlloc(arena, name), try jsonStringAlloc(arena, value) });
}

fn appendJsonFieldU32(out: *std.ArrayList(u8), arena: Allocator, name: []const u8, value: u32, first: *bool, indent: []const u8) !void {
    if (!first.*) try out.appendSlice(arena, ",\n");
    first.* = false;
    try appendFmt(out, arena, "{s}{s}: {d}", .{ indent, try jsonStringAlloc(arena, name), value });
}

fn appendJsonFieldBool(out: *std.ArrayList(u8), arena: Allocator, name: []const u8, value: bool, first: *bool, indent: []const u8) !void {
    if (!first.*) try out.appendSlice(arena, ",\n");
    first.* = false;
    try appendFmt(out, arena, "{s}{s}: {s}", .{ indent, try jsonStringAlloc(arena, name), if (value) "true" else "false" });
}

fn appendJsonDefaults(out: *std.ArrayList(u8), arena: Allocator, d: types.ModelDefaults, indent: []const u8) !void {
    try out.appendSlice(arena, "{\n");
    var first = true;
    if (d.size) |v| try appendJsonFieldString(out, arena, "size", v, &first, indent);
    if (d.width) |v| try appendJsonFieldU32(out, arena, "width", v, &first, indent);
    if (d.height) |v| try appendJsonFieldU32(out, arena, "height", v, &first, indent);
    if (d.output_format) |v| try appendJsonFieldString(out, arena, "output_format", v, &first, indent);
    if (d.output_compression) |v| try appendJsonFieldU32(out, arena, "output_compression", v, &first, indent);
    if (d.quality) |v| try appendJsonFieldString(out, arena, "quality", v, &first, indent);
    if (d.steps) |v| try appendJsonFieldU32(out, arena, "steps", v, &first, indent);
    if (d.duration) |v| try appendJsonFieldU32(out, arena, "duration", v, &first, indent);
    if (d.resolution) |v| try appendJsonFieldString(out, arena, "resolution", v, &first, indent);
    if (d.ratio) |v| try appendJsonFieldString(out, arena, "ratio", v, &first, indent);
    if (d.watermark) |v| try appendJsonFieldBool(out, arena, "watermark", v, &first, indent);
    try out.appendSlice(arena, "\n      }");
}

pub fn toJsonAlloc(arena: Allocator, cfg: Config) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(arena, "{\n");
    try appendFmt(&out, arena, "  \"output_dir\": {s},\n", .{try jsonStringAlloc(arena, cfg.output_dir)});
    try appendFmt(&out, arena, "  \"concurrency\": {d},\n", .{cfg.concurrency});
    try appendFmt(&out, arena, "  \"poll_interval\": {d},\n", .{cfg.poll_interval});
    try appendFmt(&out, arena, "  \"task_timeout\": {d},\n", .{cfg.task_timeout});
    try out.appendSlice(arena, "  \"models\": {\n");
    for (cfg.models, 0..) |m, mi| {
        if (mi > 0) try out.appendSlice(arena, ",\n");
        try appendFmt(&out, arena, "    {s}: {{\n", .{try jsonStringAlloc(arena, m.name)});
        try appendFmt(&out, arena, "      \"backend\": {s},\n", .{try jsonStringAlloc(arena, m.backend.toString())});
        try appendFmt(&out, arena, "      \"api_model\": {s},\n", .{try jsonStringAlloc(arena, m.api_model)});
        try out.appendSlice(arena, "      \"endpoints\": [\n");
        for (m.endpoints, 0..) |ep, ei| {
            if (ei > 0) try out.appendSlice(arena, ",\n");
            try out.appendSlice(arena, "        {\n");
            var first = true;
            try appendJsonFieldString(&out, arena, "base_url", ep.base_url, &first, "          ");
            if (ep.api_key) |v| try appendJsonFieldString(&out, arena, "api_key", v, &first, "          ");
            if (ep.api_key_env) |v| try appendJsonFieldString(&out, arena, "api_key_env", v, &first, "          ");
            try appendJsonFieldString(&out, arena, "auth", ep.auth.toString(), &first, "          ");
            try out.appendSlice(arena, "\n        }");
        }
        try out.appendSlice(arena, "\n      ]");
        if (defaultsAny(m.defaults)) {
            try out.appendSlice(arena, ",\n      \"defaults\": ");
            try appendJsonDefaults(&out, arena, m.defaults, "        ");
        }
        try out.appendSlice(arena, "\n    }");
    }
    try out.appendSlice(arena, "\n  }\n}\n");
    return out.toOwnedSlice(arena);
}

pub fn toTomlAlloc(arena: Allocator, cfg: Config) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try appendFmt(&out, arena, "output_dir = {s}\n", .{try tomlStringAlloc(arena, cfg.output_dir)});
    try appendFmt(&out, arena, "concurrency = {d}\n", .{cfg.concurrency});
    try appendFmt(&out, arena, "poll_interval = {d}\n", .{cfg.poll_interval});
    try appendFmt(&out, arena, "task_timeout = {d}\n", .{cfg.task_timeout});

    for (cfg.models) |m| {
        const model_key = try tomlStringAlloc(arena, m.name);
        try appendFmt(&out, arena, "\n[models.{s}]\n", .{model_key});
        try appendFmt(&out, arena, "backend = {s}\n", .{try tomlStringAlloc(arena, m.backend.toString())});
        try appendFmt(&out, arena, "api_model = {s}\n", .{try tomlStringAlloc(arena, m.api_model)});

        for (m.endpoints) |ep| {
            try appendFmt(&out, arena, "\n[[models.{s}.endpoints]]\n", .{model_key});
            try appendFmt(&out, arena, "base_url = {s}\n", .{try tomlStringAlloc(arena, ep.base_url)});
            if (ep.api_key) |v| try appendFmt(&out, arena, "api_key = {s}\n", .{try tomlStringAlloc(arena, v)});
            if (ep.api_key_env) |v| try appendFmt(&out, arena, "api_key_env = {s}\n", .{try tomlStringAlloc(arena, v)});
            try appendFmt(&out, arena, "auth = {s}\n", .{try tomlStringAlloc(arena, ep.auth.toString())});
        }

        if (defaultsAny(m.defaults)) {
            try appendFmt(&out, arena, "\n[models.{s}.defaults]\n", .{model_key});
            if (m.defaults.size) |v| try appendFmt(&out, arena, "size = {s}\n", .{try tomlStringAlloc(arena, v)});
            if (m.defaults.width) |v| try appendFmt(&out, arena, "width = {d}\n", .{v});
            if (m.defaults.height) |v| try appendFmt(&out, arena, "height = {d}\n", .{v});
            if (m.defaults.output_format) |v| try appendFmt(&out, arena, "output_format = {s}\n", .{try tomlStringAlloc(arena, v)});
            if (m.defaults.output_compression) |v| try appendFmt(&out, arena, "output_compression = {d}\n", .{v});
            if (m.defaults.quality) |v| try appendFmt(&out, arena, "quality = {s}\n", .{try tomlStringAlloc(arena, v)});
            if (m.defaults.steps) |v| try appendFmt(&out, arena, "steps = {d}\n", .{v});
            if (m.defaults.duration) |v| try appendFmt(&out, arena, "duration = {d}\n", .{v});
            if (m.defaults.resolution) |v| try appendFmt(&out, arena, "resolution = {s}\n", .{try tomlStringAlloc(arena, v)});
            if (m.defaults.ratio) |v| try appendFmt(&out, arena, "ratio = {s}\n", .{try tomlStringAlloc(arena, v)});
            if (m.defaults.watermark) |v| try appendFmt(&out, arena, "watermark = {s}\n", .{if (v) "true" else "false"});
        }
    }
    return out.toOwnedSlice(arena);
}

pub fn renderAlloc(arena: Allocator, cfg: Config, format: Format) ![]const u8 {
    return switch (format) {
        .json => toJsonAlloc(arena, cfg),
        .toml => toTomlAlloc(arena, cfg),
    };
}

/// Built-in starter config written by `imagine config init`.
/// Example models are illustrative — rename/add/remove freely.
/// Default credential env: `$AZURE_OPENAI_APIKEY`.
pub const template =
    \\# Starter config. Edit model names, api_model, and endpoint URLs to match
    \\# your OpenAI-compatible deployments. Run `imagine models` to list them.
    \\output_dir = "~/.imagine/outputs"
    \\concurrency = 0
    \\# Async (video) tasks: ask the provider for the task status every
    \\# poll_interval seconds, and give up on one task after task_timeout.
    \\poll_interval = 5
    \\task_timeout = 600
    \\
    \\[models."MAI-Image-2.6"]
    \\backend = "openai_image"
    \\api_model = "MAI-Image-2.6"
    \\
    \\[[models."MAI-Image-2.6".endpoints]]
    \\base_url = "https://jettai2.services.ai.azure.com/mai/v1/images/generations"
    \\api_key_env = "AZURE_OPENAI_APIKEY"
    \\auth = "bearer"
    \\
    \\[models."MAI-Image-2.6".defaults]
    \\size = "1024x1024"
    \\output_format = "png"
    \\output_compression = 100
    \\quality = "high"
    \\
    \\[models."MAI-Image-2.5"]
    \\backend = "openai_image"
    \\api_model = "MAI-Image-2.5"
    \\
    \\[[models."MAI-Image-2.5".endpoints]]
    \\base_url = "https://jettai2.services.ai.azure.com/mai/v1/images/generations"
    \\api_key_env = "AZURE_OPENAI_APIKEY"
    \\auth = "bearer"
    \\
    \\[models."MAI-Image-2.5".defaults]
    \\size = "1024x1024"
    \\output_format = "png"
    \\output_compression = 100
    \\quality = "high"
    \\
    \\[models."MAI-Image-2.6-Flash"]
    \\backend = "openai_image"
    \\api_model = "MAI-Image-2.6-Flash"
    \\
    \\[[models."MAI-Image-2.6-Flash".endpoints]]
    \\base_url = "https://jettai2.services.ai.azure.com/mai/v1/images/generations"
    \\api_key_env = "AZURE_OPENAI_APIKEY"
    \\auth = "bearer"
    \\
    \\[models."MAI-Image-2.6-Flash".defaults]
    \\size = "1024x1024"
    \\output_format = "png"
    \\output_compression = 100
    \\quality = "high"
    \\
    \\# --- Volcengine Ark (Seedream images / Seedance video) -----------------------
    \\# Credential env: ARK_API_KEY. Both models are also built-in presets (see
    \\# `imagine models`), so this block only matters when you want to override a
    \\# URL, pin defaults, or add another endpoint.
    \\# [models."doubao-seedance-2-5-260628"]
    \\# backend = "seedance"
    \\# api_model = "doubao-seedance-2-5-260628"
    \\
    \\# [[models."doubao-seedance-2-5-260628".endpoints]]
    \\# base_url = "https://ark.cn-beijing.volces.com/api/v3/contents/generations/tasks"
    \\# api_key_env = "ARK_API_KEY"
    \\
    \\# [models."doubao-seedance-2-5-260628".defaults]
    \\# duration = 5                # seconds
    \\# resolution = "720p"         # 480p | 720p | 1080p | 4k
    \\# ratio = "16:9"
    \\
    \\# [models."doubao-seedream-5-0-260128"]
    \\# backend = "volcengine_image"
    \\# api_model = "doubao-seedream-5-0-260128"
    \\
    \\# [[models."doubao-seedream-5-0-260128".endpoints]]
    \\# base_url = "https://ark.cn-beijing.volces.com/api/v3/images/generations"
    \\# api_key_env = "ARK_API_KEY"
    \\
    \\# [models."doubao-seedream-5-0-260128".defaults]
    \\# size = "2K"                 # tier (1K/2K/4K) or explicit WxH
    \\# watermark = false           # Ark defaults to true
    \\
    \\# --- Google Gemini video (Omni, Interactions API) ---------------------------
    \\# Credential env: GEMINI_API_KEY; the key travels in `x-goog-api-key`.
    \\# [models."gemini-omni-1.1-flash"]
    \\# backend = "gemini_video"
    \\# api_model = "gemini-omni-1.1-flash"
    \\
    \\# [[models."gemini-omni-1.1-flash".endpoints]]
    \\# base_url = "https://generativelanguage.googleapis.com/v1beta/interactions"
    \\# api_key_env = "GEMINI_API_KEY"
    \\# auth = "google_api_key"
    \\
    \\# [models."gemini-omni-1.1-flash".defaults]
    \\# resolution = "720p"
    \\# ratio = "16:9"
    \\
    \\# --- Local Qwen-Image-2.1 (optional) ---------------------------------------
    \\# Install the local server first (see integrations/qwen-image/README.md):
    \\#   integrations/qwen-image/install.sh   ... then run: qwen-image-server
    \\# Local servers take no credential, so auth = "none" needs no key. Uncomment:
    \\# [models."qwen-image-2.1"]
    \\# backend = "qwen_image"
    \\# api_model = "Qwen/Qwen-Image-2.1"
    \\
    \\# [[models."qwen-image-2.1".endpoints]]
    \\# base_url = "http://127.0.0.1:8000/v1/images/generations"
    \\# auth = "none"
    \\
    \\# [models."qwen-image-2.1".defaults]
    \\# size = "1024x1024"      # or a 2K ratio token: 16:9 4:3 3:2 ...
    \\# steps = 20               # = num_inference_steps
    \\
;

pub const json_template =
    \\{
    \\  "output_dir": "~/.imagine/outputs",
    \\  "concurrency": 0,
    \\  "models": {
    \\    "MAI-Image-2.6": {
    \\      "backend": "openai_image",
    \\      "api_model": "MAI-Image-2.6",
    \\      "endpoints": [
    \\        {
    \\          "base_url": "https://jettai2.services.ai.azure.com/mai/v1/images/generations",
    \\          "api_key_env": "AZURE_OPENAI_APIKEY",
    \\          "auth": "bearer"
    \\        }
    \\      ],
    \\      "defaults": {
    \\        "size": "1024x1024",
    \\        "output_format": "png",
    \\        "output_compression": 100,
    \\        "quality": "high"
    \\      }
    \\    },
    \\    "MAI-Image-2.5": {
    \\      "backend": "openai_image",
    \\      "api_model": "MAI-Image-2.5",
    \\      "endpoints": [
    \\        {
    \\          "base_url": "https://jettai2.services.ai.azure.com/mai/v1/images/generations",
    \\          "api_key_env": "AZURE_OPENAI_APIKEY",
    \\          "auth": "bearer"
    \\        }
    \\      ],
    \\      "defaults": {
    \\        "size": "1024x1024",
    \\        "output_format": "png",
    \\        "output_compression": 100,
    \\        "quality": "high"
    \\      }
    \\    },
    \\    "MAI-Image-2.6-Flash": {
    \\      "backend": "openai_image",
    \\      "api_model": "MAI-Image-2.6-Flash",
    \\      "endpoints": [
    \\        {
    \\          "base_url": "https://jettai2.services.ai.azure.com/mai/v1/images/generations",
    \\          "api_key_env": "AZURE_OPENAI_APIKEY",
    \\          "auth": "bearer"
    \\        }
    \\      ],
    \\      "defaults": {
    \\        "size": "1024x1024",
    \\        "output_format": "png",
    \\        "output_compression": 100,
    \\        "quality": "high"
    \\      }
    \\    }
    \\  }
    \\}
    \\
;

// ---- tests ----

const TestEnv = struct {
    map: std.StringHashMap([]const u8),
    fn get(ctx: *const anyopaque, name: []const u8) ?[]const u8 {
        const self: *const TestEnv = @ptrCast(@alignCast(ctx));
        return self.map.get(name);
    }
    fn env(self: *const TestEnv) Env {
        return .{ .context = self, .func = TestEnv.get };
    }
};

test "loadFromBytes parses models, endpoints and defaults" {
    const a = std.testing.allocator;
    var te = TestEnv{ .map = std.StringHashMap([]const u8).init(a) };
    defer te.map.deinit();
    try te.map.put("AZURE_OPENAI_APIKEY", "secret-123");

    var cfg = try loadFromBytes(a, template, te.env());
    defer cfg.deinit();

    try std.testing.expectEqual(@as(usize, 3), cfg.models.len);
    const m = cfg.findModel("MAI-Image-2.6").?;
    try std.testing.expectEqual(types.BackendKind.openai_image, m.backend);
    try std.testing.expectEqualStrings("MAI-Image-2.6", m.api_model);
    try std.testing.expectEqual(@as(usize, 1), m.endpoints.len);
    try std.testing.expectEqualStrings("secret-123", m.endpoints[0].resolved_key.?);
    try std.testing.expectEqualStrings("1024x1024", m.defaults.size.?);

    const flash = cfg.findModel("MAI-Image-2.6-Flash").?;
    try std.testing.expectEqual(types.BackendKind.openai_image, flash.backend);
    try std.testing.expectEqualStrings("MAI-Image-2.6-Flash", flash.api_model);
}

test "auth=none endpoint is keyless and defaults.steps parses" {
    const a = std.testing.allocator;
    const toml =
        \\[models."qwen-image-2.1"]
        \\backend = "qwen_image"
        \\api_model = "Qwen/Qwen-Image-2.1"
        \\
        \\[[models."qwen-image-2.1".endpoints]]
        \\base_url = "http://127.0.0.1:8000/v1/images/generations"
        \\auth = "none"
        \\
        \\[models."qwen-image-2.1".defaults]
        \\size = "2048x2048"
        \\steps = 40
        \\
    ;
    var cfg = try loadFromBytes(a, toml, Env.empty());
    defer cfg.deinit();

    const m = cfg.findModel("qwen-image-2.1").?;
    try std.testing.expectEqual(types.BackendKind.qwen_image, m.backend);
    try std.testing.expectEqual(types.AuthScheme.none, m.endpoints[0].auth);
    try std.testing.expect(m.endpoints[0].resolved_key == null);
    try std.testing.expectEqual(@as(u32, 40), m.defaults.steps.?);
}

test "loadEphemeral auth=none needs no credential" {
    const a = std.testing.allocator;
    var te = TestEnv{ .map = std.StringHashMap([]const u8).init(a) };
    defer te.map.deinit();
    try te.map.put(env_base_url, "http://127.0.0.1:8000/v1/images/generations");
    try te.map.put(env_model, "qwen-image-2.1");
    try te.map.put(env_backend, "qwen_image");
    try te.map.put(env_auth, "none");
    try te.map.put(env_steps, "40");

    try std.testing.expect(ephemeralReady(te.env()));
    var cfg = try loadEphemeral(a, te.env());
    defer cfg.deinit();

    try std.testing.expectEqual(types.BackendKind.qwen_image, cfg.models[0].backend);
    try std.testing.expectEqual(types.AuthScheme.none, cfg.models[0].endpoints[0].auth);
    try std.testing.expect(cfg.models[0].endpoints[0].resolved_key == null);
    try std.testing.expectEqual(@as(u32, 40), cfg.models[0].defaults.steps.?);
}

test "loadJsonFromBytes keeps legacy config support" {
    const a = std.testing.allocator;
    var cfg = try loadJsonFromBytes(a, json_template, Env.empty());
    defer cfg.deinit();

    try std.testing.expectEqual(@as(usize, 3), cfg.models.len);
    try std.testing.expectEqualStrings("MAI-Image-2.5", cfg.findModel("MAI-Image-2.5").?.api_model);
}

test "render TOML can be parsed again" {
    const a = std.testing.allocator;
    var cfg = try loadFromBytes(a, json_template, Env.empty());
    defer cfg.deinit();

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const toml = try toTomlAlloc(arena.allocator(), cfg);

    var cfg2 = try loadFromBytes(a, toml, Env.empty());
    defer cfg2.deinit();
    try std.testing.expectEqual(@as(usize, 3), cfg2.models.len);
    try std.testing.expectEqualStrings("1024x1024", cfg2.findModel("MAI-Image-2.6").?.defaults.size.?);
}

test "resolvePath precedence" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    var te = TestEnv{ .map = std.StringHashMap([]const u8).init(a) };
    defer te.map.deinit();
    try te.map.put("HOME", "/home/u");

    const p = try resolvePath(arena.allocator(), te.env(), null);
    try std.testing.expectEqualStrings("/home/u/.imagine/config.toml", p);

    const p2 = try resolvePath(arena.allocator(), te.env(), "/x/y.json");
    try std.testing.expectEqualStrings("/x/y.json", p2);
}

test "missing models errors" {
    const a = std.testing.allocator;
    try std.testing.expectError(Error.MissingModels, loadFromBytes(a, "{}", Env.empty()));
}

test "loadEphemeral synthesizes single openai_image model" {
    const a = std.testing.allocator;
    var te = TestEnv{ .map = std.StringHashMap([]const u8).init(a) };
    defer te.map.deinit();
    try te.map.put(env_base_url, "https://example.com/v1/images/generations");
    try te.map.put(env_model, "MAI-Image-2.6-Flash");
    try te.map.put(env_default_api_key_env, "secret-key");
    try te.map.put(env_size, "1024x1024");

    var cfg = try loadEphemeral(a, te.env());
    defer cfg.deinit();

    try std.testing.expectEqual(Source.ephemeral, cfg.source);
    try std.testing.expectEqual(@as(usize, 1), cfg.models.len);
    try std.testing.expectEqualStrings("MAI-Image-2.6-Flash", cfg.models[0].name);
    try std.testing.expectEqualStrings("MAI-Image-2.6-Flash", cfg.models[0].api_model);
    try std.testing.expectEqual(types.BackendKind.openai_image, cfg.models[0].backend);
    try std.testing.expectEqualStrings("https://example.com/v1/images/generations", cfg.models[0].endpoints[0].base_url);
    try std.testing.expectEqualStrings("secret-key", cfg.models[0].endpoints[0].resolved_key.?);
    try std.testing.expectEqualStrings(env_default_api_key_env, cfg.models[0].endpoints[0].api_key_env.?);
    try std.testing.expectEqualStrings("1024x1024", cfg.models[0].defaults.size.?);
    try std.testing.expect(ephemeralReady(te.env()));
}

test "loadEphemeral respects IMAGINE_API_KEY and IMAGINE_API_MODEL" {
    const a = std.testing.allocator;
    var te = TestEnv{ .map = std.StringHashMap([]const u8).init(a) };
    defer te.map.deinit();
    try te.map.put(env_base_url, "https://x/v1");
    try te.map.put(env_model, "logical");
    try te.map.put(env_api_model, "deployment-id");
    try te.map.put(env_api_key, "inline-secret");
    try te.map.put(env_backend, "azure_image"); // legacy alias
    try te.map.put(env_auth, "api-key");

    var cfg = try loadEphemeral(a, te.env());
    defer cfg.deinit();

    try std.testing.expect(cfg.ephemeral_api_model_set);
    try std.testing.expectEqualStrings("deployment-id", cfg.models[0].api_model);
    try std.testing.expectEqualStrings("inline-secret", cfg.models[0].endpoints[0].resolved_key.?);
    try std.testing.expectEqual(types.AuthScheme.api_key, cfg.models[0].endpoints[0].auth);
    try std.testing.expectEqual(types.BackendKind.openai_image, cfg.models[0].backend);
}

test "video defaults and async task knobs parse from TOML" {
    const a = std.testing.allocator;
    const toml =
        \\poll_interval = 2
        \\task_timeout = 90
        \\
        \\[models."v"]
        \\backend = "seedance"
        \\api_model = "doubao-seedance-2-5-260628"
        \\
        \\[[models."v".endpoints]]
        \\base_url = "https://ark.example.com/api/v3/contents/generations/tasks"
        \\api_key_env = "ARK_API_KEY"
        \\
        \\[models."v".defaults]
        \\duration = 5
        \\resolution = "720p"
        \\ratio = "16:9"
        \\watermark = false
        \\
    ;
    var cfg = try loadFromBytes(a, toml, Env.empty());
    defer cfg.deinit();

    try std.testing.expectEqual(@as(u32, 2), cfg.poll_interval);
    try std.testing.expectEqual(@as(u32, 90), cfg.task_timeout);

    const m = cfg.findModel("v").?;
    try std.testing.expectEqual(types.BackendKind.seedance, m.backend);
    try std.testing.expectEqual(types.Media.video, m.backend.media());
    try std.testing.expectEqual(types.Flow.async_task, m.backend.flow());
    try std.testing.expectEqual(@as(u32, 5), m.defaults.duration.?);
    try std.testing.expectEqualStrings("720p", m.defaults.resolution.?);
    try std.testing.expectEqualStrings("16:9", m.defaults.ratio.?);
    try std.testing.expectEqual(false, m.defaults.watermark.?);
}

test "video defaults survive a TOML render and re-parse" {
    const a = std.testing.allocator;
    const toml =
        \\[models."v"]
        \\backend = "volcengine_image"
        \\api_model = "doubao-seedream-5-0-260128"
        \\
        \\[[models."v".endpoints]]
        \\base_url = "https://ark.example.com/api/v3/images/generations"
        \\api_key_env = "ARK_API_KEY"
        \\
        \\[models."v".defaults]
        \\size = "2K"
        \\duration = 4
        \\resolution = "1080p"
        \\ratio = "9:16"
        \\watermark = true
        \\
    ;
    var cfg = try loadFromBytes(a, toml, Env.empty());
    defer cfg.deinit();

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const rendered = try toTomlAlloc(arena.allocator(), cfg);

    var cfg2 = try loadFromBytes(a, rendered, Env.empty());
    defer cfg2.deinit();
    const d = cfg2.findModel("v").?.defaults;
    try std.testing.expectEqual(@as(u32, 4), d.duration.?);
    try std.testing.expectEqualStrings("1080p", d.resolution.?);
    try std.testing.expectEqualStrings("9:16", d.ratio.?);
    try std.testing.expectEqual(true, d.watermark.?);

    // The JSON renderer carries the same fields.
    const as_json = try toJsonAlloc(arena.allocator(), cfg);
    var cfg3 = try loadFromBytes(a, as_json, Env.empty());
    defer cfg3.deinit();
    try std.testing.expectEqual(true, cfg3.findModel("v").?.defaults.watermark.?);
    try std.testing.expectEqualStrings("1080p", cfg3.findModel("v").?.defaults.resolution.?);
}

test "presets load, carry their credential env, and yield to config models" {
    const a = std.testing.allocator;
    var te = TestEnv{ .map = std.StringHashMap([]const u8).init(a) };
    defer te.map.deinit();
    try te.map.put("ARK_API_KEY", "ark-secret");

    const toml =
        \\[models."doubao-seedance-2-5-260628"]
        \\backend = "seedance"
        \\api_model = "my-endpoint-id"
        \\
        \\[[models."doubao-seedance-2-5-260628".endpoints]]
        \\base_url = "https://example.com/tasks"
        \\api_key = "k"
        \\
    ;
    var cfg = try loadFromBytes(a, toml, te.env());
    defer cfg.deinit();

    try std.testing.expectEqual(presets.catalog.len, cfg.presets.len);

    // Credentials are resolved for presets too, so `imagine models` can report
    // readiness without a config file.
    const seedream = cfg.findPreset("doubao-seedream-5-0-260128").?;
    try std.testing.expectEqualStrings("ARK_API_KEY", seedream.endpoints[0].api_key_env.?);
    try std.testing.expectEqualStrings("ark-secret", seedream.endpoints[0].resolved_key.?);
    // No GEMINI_API_KEY in the test env, so that preset is not ready.
    try std.testing.expect(cfg.findPreset("gemini-omni-1.1-flash").?.endpoints[0].resolved_key == null);

    // A configured model of the same name shadows the preset.
    try std.testing.expect(cfg.findPreset("doubao-seedance-2-5-260628") == null);
    try std.testing.expectEqualStrings("my-endpoint-id", cfg.findModel("doubao-seedance-2-5-260628").?.api_model);
}

test "preset-only config needs no file and no ephemeral env" {
    const a = std.testing.allocator;
    var te = TestEnv{ .map = std.StringHashMap([]const u8).init(a) };
    defer te.map.deinit();

    var cfg = try loadPresetsOnly(a, te.env());
    defer cfg.deinit();

    try std.testing.expectEqual(Source.preset, cfg.source);
    try std.testing.expectEqualStrings("preset", cfg.source.toString());
    try std.testing.expectEqual(@as(usize, 0), cfg.models.len);
    try std.testing.expectEqual(presets.catalog.len, cfg.presets.len);
    try std.testing.expectEqual(default_poll_interval, cfg.poll_interval);
    try std.testing.expectEqual(default_task_timeout, cfg.task_timeout);
    // `-m <preset>` is the only way to pick one, so every preset is reachable.
    try std.testing.expect(cfg.findPreset("doubao-seedance-2-5-260628") != null);
}

test "ephemeralKeyEnv follows IMAGINE_BACKEND" {
    const a = std.testing.allocator;
    var te = TestEnv{ .map = std.StringHashMap([]const u8).init(a) };
    defer te.map.deinit();

    try std.testing.expectEqualStrings("AZURE_OPENAI_APIKEY", ephemeralKeyEnv(te.env()));

    try te.map.put(env_backend, "seedance");
    try std.testing.expectEqualStrings("ARK_API_KEY", ephemeralKeyEnv(te.env()));

    try te.map.put(env_backend, "volcengine_image");
    try std.testing.expectEqualStrings("ARK_API_KEY", ephemeralKeyEnv(te.env()));

    try te.map.put(env_backend, "gemini_video");
    try std.testing.expectEqualStrings("GEMINI_API_KEY", ephemeralKeyEnv(te.env()));

    // An explicit IMAGINE_API_KEY_ENV always wins.
    try te.map.put(env_api_key_env, "MY_KEY");
    try std.testing.expectEqualStrings("MY_KEY", ephemeralKeyEnv(te.env()));
}

test "loadEphemeral reads the video knobs and the backend's credential env" {
    const a = std.testing.allocator;
    var te = TestEnv{ .map = std.StringHashMap([]const u8).init(a) };
    defer te.map.deinit();
    try te.map.put(env_base_url, "https://ark.example.com/api/v3/contents/generations/tasks");
    try te.map.put(env_model, "doubao-seedance-2-5-260628");
    try te.map.put(env_backend, "seedance");
    try te.map.put("ARK_API_KEY", "ark-secret");
    try te.map.put(env_duration, "6");
    try te.map.put(env_resolution, "1080p");
    try te.map.put(env_ratio, "9:16");
    try te.map.put(env_watermark, "false");
    try te.map.put(env_poll_interval, "2");
    try te.map.put(env_task_timeout, "120");

    try std.testing.expect(ephemeralReady(te.env()));
    var cfg = try loadEphemeral(a, te.env());
    defer cfg.deinit();

    const m = cfg.models[0];
    try std.testing.expectEqual(types.BackendKind.seedance, m.backend);
    try std.testing.expectEqualStrings("ARK_API_KEY", m.endpoints[0].api_key_env.?);
    try std.testing.expectEqualStrings("ark-secret", m.endpoints[0].resolved_key.?);
    try std.testing.expectEqual(@as(u32, 6), m.defaults.duration.?);
    try std.testing.expectEqualStrings("1080p", m.defaults.resolution.?);
    try std.testing.expectEqualStrings("9:16", m.defaults.ratio.?);
    try std.testing.expectEqual(false, m.defaults.watermark.?);
    try std.testing.expectEqual(@as(u32, 2), cfg.poll_interval);
    try std.testing.expectEqual(@as(u32, 120), cfg.task_timeout);
}

test "ephemeralIncomplete when base url missing" {
    const a = std.testing.allocator;
    var te = TestEnv{ .map = std.StringHashMap([]const u8).init(a) };
    defer te.map.deinit();
    try te.map.put(env_model, "m");
    try te.map.put(env_default_api_key_env, "k");
    try std.testing.expect(ephemeralIntent(te.env()));
    try std.testing.expect(!ephemeralReady(te.env()));
    try std.testing.expectError(Error.EphemeralIncomplete, loadEphemeral(a, te.env()));
}
