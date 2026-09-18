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

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const default_rel_path = ".imagine/config.toml";
pub const legacy_json_rel_path = ".imagine/config.json";
pub const env_config_path = "IMAGINE_CONFIG";

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
    file,
    ephemeral,

    pub fn toString(self: Source) []const u8 {
        return switch (self) {
            .file => "file",
            .ephemeral => "ephemeral",
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
    models: []types.ModelConfig,
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
};

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

pub fn ephemeralMissing(env: Env) EphemeralMissing {
    var m: EphemeralMissing = .{};
    if (envNonEmpty(env, env_base_url) == null) m.base_url = true;
    if (envNonEmpty(env, env_model) == null) m.model = true;

    const has_literal = envNonEmpty(env, env_api_key) != null;
    const key_env_name = envNonEmpty(env, env_api_key_env) orelse env_default_api_key_env;
    const has_from_env = envNonEmpty(env, key_env_name) != null;
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
        if (m.credential) try list.appendSlice(arena, " AZURE_OPENAI_APIKEY|IMAGINE_API_KEY|IMAGINE_API_KEY_ENV");
        try list.appendSlice(arena, "\nor run 'imagine config init' for a multi-model config file\n");
        return list.toOwnedSlice(arena);
    }
    return arena.dupe(u8,
        \\no config file found and ephemeral env incomplete
        \\  file: run 'imagine config init'  (or set IMAGINE_CONFIG / --config)
        \\  ephemeral: set IMAGINE_BASE_URL + IMAGINE_MODEL + AZURE_OPENAI_APIKEY
        \\             (or IMAGINE_API_KEY / IMAGINE_API_KEY_ENV)
        \\
    );
}

fn parseEnvU32(raw: []const u8) ?u32 {
    return std.fmt.parseInt(u32, raw, 10) catch null;
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
    } else {
        const key_env = envNonEmpty(env, env_api_key_env) orelse env_default_api_key_env;
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

    return .{
        .gpa = gpa,
        .arena = arena_ptr,
        .output_dir = output_dir,
        .concurrency = concurrency,
        .models = models,
        .source = .ephemeral,
        .ephemeral_api_model_set = api_model_set,
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
    d.width = try getU32(obj, "width");
    d.height = try getU32(obj, "height");
    d.output_compression = try getU32(obj, "output_compression");
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

fn applyTomlRootPair(arena: Allocator, key: []const u8, value: TomlScalar, output_dir: *?[]const u8, concurrency: *u32) Error!void {
    if (std.mem.eql(u8, key, "output_dir")) {
        output_dir.* = try arena.dupe(u8, try scalarString(value));
    } else if (std.mem.eql(u8, key, "concurrency")) {
        concurrency.* = try scalarU32(value);
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

    var output_dir: ?[]const u8 = null;
    var concurrency: u32 = 0;
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
            .root => try applyTomlRootPair(arena, key, value, &output_dir, &concurrency),
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
        .output_dir = output_dir orelse try arena.dupe(u8, "~/.imagine/outputs"),
        .concurrency = concurrency,
        .models = out_models,
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
        .models = models,
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
        d.output_format != null or d.output_compression != null or d.quality != null;
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

fn appendJsonDefaults(out: *std.ArrayList(u8), arena: Allocator, d: types.ModelDefaults, indent: []const u8) !void {
    try out.appendSlice(arena, "{\n");
    var first = true;
    if (d.size) |v| try appendJsonFieldString(out, arena, "size", v, &first, indent);
    if (d.width) |v| try appendJsonFieldU32(out, arena, "width", v, &first, indent);
    if (d.height) |v| try appendJsonFieldU32(out, arena, "height", v, &first, indent);
    if (d.output_format) |v| try appendJsonFieldString(out, arena, "output_format", v, &first, indent);
    if (d.output_compression) |v| try appendJsonFieldU32(out, arena, "output_compression", v, &first, indent);
    if (d.quality) |v| try appendJsonFieldString(out, arena, "quality", v, &first, indent);
    try out.appendSlice(arena, "\n      }");
}

pub fn toJsonAlloc(arena: Allocator, cfg: Config) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(arena, "{\n");
    try appendFmt(&out, arena, "  \"output_dir\": {s},\n", .{try jsonStringAlloc(arena, cfg.output_dir)});
    try appendFmt(&out, arena, "  \"concurrency\": {d},\n", .{cfg.concurrency});
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
