//! Shared core types for the imagine CLI.
//!
//! These types form the decoupling seam between the frontend (CLI parsing and
//! unified parameters) and the backends (per-provider request construction).
//! Nothing here imports a backend or the HTTP layer, so the types can be reused
//! and unit-tested in isolation.

const std = @import("std");

/// How an endpoint authenticates. Azure AI Foundry accepts both a bearer token
/// and an `api-key` header; other providers can be added later.
pub const AuthScheme = enum {
    bearer,
    api_key,

    pub fn fromString(s: []const u8) ?AuthScheme {
        if (std.mem.eql(u8, s, "bearer")) return .bearer;
        if (std.mem.eql(u8, s, "api-key") or std.mem.eql(u8, s, "api_key")) return .api_key;
        return null;
    }

    pub fn headerName(self: AuthScheme) []const u8 {
        return switch (self) {
            .bearer => "Authorization",
            .api_key => "api-key",
        };
    }

    pub fn toString(self: AuthScheme) []const u8 {
        return switch (self) {
            .bearer => "bearer",
            .api_key => "api-key",
        };
    }
};

/// Identifies which backend module builds a request body for a model. Adding a
/// new provider means adding a variant here and a module under `backends/`.
/// Logical model names are never hardcoded — they come from config.
pub const BackendKind = enum {
    /// OpenAI-compatible `images/generations` (Azure OpenAI, OpenAI, etc.).
    openai_image,
    /// Azure-hosted Black Forest Labs FLUX (width/height body).
    azure_flux,

    pub fn fromString(s: []const u8) ?BackendKind {
        // openai_image is canonical; azure_image is kept as a legacy alias.
        if (std.mem.eql(u8, s, "openai_image") or std.mem.eql(u8, s, "openai-image") or
            std.mem.eql(u8, s, "azure_image") or std.mem.eql(u8, s, "azure-image"))
            return .openai_image;
        if (std.mem.eql(u8, s, "azure_flux") or std.mem.eql(u8, s, "azure-flux")) return .azure_flux;
        return null;
    }

    pub fn toString(self: BackendKind) []const u8 {
        return switch (self) {
            .openai_image => "openai_image",
            .azure_flux => "azure_flux",
        };
    }
};

/// A single concrete API target for a model: one URL plus one credential. A
/// model owns a slice of these, which is what enables concurrent scheduling of
/// the same logical model across several keys/regions.
pub const Endpoint = struct {
    base_url: []const u8,
    /// Inline key (discouraged but supported). Takes precedence when present.
    api_key: ?[]const u8 = null,
    /// Environment variable to read the key from.
    api_key_env: ?[]const u8 = null,
    auth: AuthScheme = .bearer,
    /// Resolved credential, filled in by config loading. Never serialized.
    resolved_key: ?[]const u8 = null,
};

/// Per-model defaults that fill in any frontend parameter the caller omitted.
pub const ModelDefaults = struct {
    size: ?[]const u8 = null,
    width: ?u32 = null,
    height: ?u32 = null,
    output_format: ?[]const u8 = null,
    output_compression: ?u32 = null,
    quality: ?[]const u8 = null,
};

/// A logical model the user can route to by name. Maps to exactly one backend
/// and one or more endpoints.
pub const ModelConfig = struct {
    name: []const u8,
    backend: BackendKind,
    /// The `model` value sent in the request body. Defaults to `name`.
    api_model: []const u8,
    endpoints: []Endpoint,
    defaults: ModelDefaults = .{},
};

/// Unified frontend request. Backends translate this into provider-specific
/// JSON. Width/height and `size` are both accepted; backends use whichever the
/// provider understands and derive one from the other when needed.
pub const ImageRequest = struct {
    prompt: []const u8,
    /// Model value sent to the provider API (already resolved from api_model).
    api_model: []const u8,
    size: ?[]const u8 = null,
    width: ?u32 = null,
    height: ?u32 = null,
    /// Images requested for this single API call. The scheduler expands the
    /// user's -n into separate tasks, so this is normally 1.
    n: u32 = 1,
    output_format: ?[]const u8 = null,
    output_compression: ?u32 = null,
    quality: ?[]const u8 = null,
    seed: ?i64 = null,

    /// Apply model defaults for any field the caller left null.
    pub fn applyDefaults(self: *ImageRequest, d: ModelDefaults) void {
        if (self.size == null) self.size = d.size;
        if (self.width == null) self.width = d.width;
        if (self.height == null) self.height = d.height;
        if (self.output_format == null) self.output_format = d.output_format;
        if (self.output_compression == null) self.output_compression = d.output_compression;
        if (self.quality == null) self.quality = d.quality;
    }
};

/// Decoded result of a single image from a provider response. Either raw bytes
/// (decoded from base64) or a URL the caller must still download.
pub const ImagePayload = union(enum) {
    bytes: []u8,
    url: []const u8,
};

/// Parse a "WxH" string (e.g. "1024x1024") into width/height.
pub fn parseSize(s: []const u8) ?struct { w: u32, h: u32 } {
    const idx = std.mem.indexOfScalar(u8, s, 'x') orelse
        std.mem.indexOfScalar(u8, s, 'X') orelse return null;
    const w = std.fmt.parseInt(u32, s[0..idx], 10) catch return null;
    const h = std.fmt.parseInt(u32, s[idx + 1 ..], 10) catch return null;
    return .{ .w = w, .h = h };
}

test "parseSize" {
    const r = parseSize("1024x768").?;
    try std.testing.expectEqual(@as(u32, 1024), r.w);
    try std.testing.expectEqual(@as(u32, 768), r.h);
    try std.testing.expect(parseSize("nope") == null);
}

test "AuthScheme/BackendKind round trips" {
    try std.testing.expectEqual(AuthScheme.bearer, AuthScheme.fromString("bearer").?);
    try std.testing.expectEqual(AuthScheme.api_key, AuthScheme.fromString("api-key").?);
    try std.testing.expectEqual(BackendKind.openai_image, BackendKind.fromString("openai_image").?);
    try std.testing.expectEqual(BackendKind.openai_image, BackendKind.fromString("azure_image").?);
    try std.testing.expectEqual(BackendKind.azure_flux, BackendKind.fromString("azure-flux").?);
}
