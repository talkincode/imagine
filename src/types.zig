//! Shared core types for the imagine CLI.
//!
//! These types form the decoupling seam between the frontend (CLI parsing and
//! unified parameters) and the backends (per-provider request construction).
//! Nothing here imports a backend or the HTTP layer, so the types can be reused
//! and unit-tested in isolation.

const std = @import("std");

/// How an endpoint authenticates. Azure AI Foundry accepts both a bearer token
/// and an `api-key` header; Google's APIs take their key in `x-goog-api-key`;
/// `none` covers self-hosted endpoints (a local model server) that take no
/// credential at all.
pub const AuthScheme = enum {
    bearer,
    api_key,
    /// `x-goog-api-key: <key>` (Google AI Studio / Gemini API keys).
    google_api_key,
    none,

    pub fn fromString(s: []const u8) ?AuthScheme {
        if (std.mem.eql(u8, s, "bearer")) return .bearer;
        if (std.mem.eql(u8, s, "api-key") or std.mem.eql(u8, s, "api_key")) return .api_key;
        if (std.mem.eql(u8, s, "google_api_key") or std.mem.eql(u8, s, "google-api-key") or
            std.mem.eql(u8, s, "google") or std.mem.eql(u8, s, "gemini") or
            std.mem.eql(u8, s, "x-goog-api-key")) return .google_api_key;
        if (std.mem.eql(u8, s, "none")) return .none;
        return null;
    }

    /// Name of the header carrying the credential. Never called for `.none`,
    /// which sends no credential header at all.
    pub fn headerName(self: AuthScheme) []const u8 {
        return switch (self) {
            .bearer => "Authorization",
            .api_key => "api-key",
            .google_api_key => "x-goog-api-key",
            .none => "",
        };
    }

    pub fn toString(self: AuthScheme) []const u8 {
        return switch (self) {
            .bearer => "bearer",
            .api_key => "api-key",
            .google_api_key => "google_api_key",
            .none => "none",
        };
    }
};

/// What a backend produces. The unified request covers both; only the output
/// naming (extension, `--json` key) and the progress wording differ.
pub const Media = enum {
    image,
    video,

    pub fn toString(self: Media) []const u8 {
        return switch (self) {
            .image => "image",
            .video => "video",
        };
    }

    /// Output format used when the caller passed neither `--format` nor a model
    /// default. Providers always return these container formats, so the choice
    /// is only about the file name we write them to.
    pub fn defaultFormat(self: Media) []const u8 {
        return switch (self) {
            .image => "png",
            .video => "mp4",
        };
    }
};

/// How a backend's wire protocol is driven. `sync` finishes inside one request;
/// `async_task` needs a create call plus status polling (video generation).
pub const Flow = enum {
    sync,
    async_task,
};

/// How the unified `--image` (first-frame / reference) input reaches a provider.
pub const InputImageStyle = enum {
    /// Accepts a URL as-is, and a base64 `data:` URL for local files.
    url_or_data_url,
    /// Accepts raw base64 bytes plus a MIME type (never a URL).
    bytes_base64,
    /// Takes no image at all: sending one would be silently dropped, so the CLI
    /// rejects `--image` for these backends instead.
    unsupported,
};

/// Identifies which backend module builds a request body for a model. Adding a
/// new provider means adding a variant here and a module under `backends/`.
/// Logical model names are never hardcoded — they come from config (the one
/// exception is the convenience preset catalog in `presets.zig`).
///
/// Routing metadata (media kind, flow, credential env, download auth) lives on
/// this enum because every module already depends on `types.zig`; the wire
/// formats themselves live in `backends/*`.
pub const BackendKind = enum {
    /// OpenAI-compatible `images/generations` (Azure OpenAI, OpenAI, etc.).
    openai_image,
    /// Azure-hosted Black Forest Labs FLUX (width/height body).
    azure_flux,
    /// Qwen-Image text-to-image (`QwenImage21Pipeline`) served locally over an
    /// OpenAI-compatible `images/generations` endpoint. See `integrations/qwen-image`.
    qwen_image,
    /// Volcengine Ark video generation (Seedance): create task, poll, download.
    seedance,
    /// Volcengine Ark image generation (Seedream), OpenAI-style sync response.
    volcengine_image,
    /// Google Gemini video generation through the Interactions API (Gemini
    /// Omni): an interaction yields a Files reference that is polled and then
    /// downloaded. Veo is a different protocol (`generateContent` +
    /// `:predictLongRunning`) and deliberately has no alias here.
    gemini_video,
    /// Self-hosted LTX-2 service using imagine's documented async video contract.
    ltx2_video,

    pub fn fromString(s: []const u8) ?BackendKind {
        // openai_image is canonical; azure_image is kept as a legacy alias.
        if (std.mem.eql(u8, s, "openai_image") or std.mem.eql(u8, s, "openai-image") or
            std.mem.eql(u8, s, "azure_image") or std.mem.eql(u8, s, "azure-image"))
            return .openai_image;
        if (std.mem.eql(u8, s, "azure_flux") or std.mem.eql(u8, s, "azure-flux")) return .azure_flux;
        // Version-agnostic aliases: `-m`/api_model pick the concrete checkpoint.
        if (std.mem.eql(u8, s, "qwen_image") or std.mem.eql(u8, s, "qwen-image") or
            std.mem.eql(u8, s, "qwen")) return .qwen_image;
        if (std.mem.eql(u8, s, "seedance") or std.mem.eql(u8, s, "ark_video") or
            std.mem.eql(u8, s, "ark-video") or std.mem.eql(u8, s, "volcengine_video"))
            return .seedance;
        if (std.mem.eql(u8, s, "volcengine_image") or std.mem.eql(u8, s, "volcengine-image") or
            std.mem.eql(u8, s, "seedream") or std.mem.eql(u8, s, "ark_image"))
            return .volcengine_image;
        if (std.mem.eql(u8, s, "gemini_video") or std.mem.eql(u8, s, "gemini-video") or
            std.mem.eql(u8, s, "gemini_omni") or std.mem.eql(u8, s, "gemini-omni"))
            return .gemini_video;
        if (std.mem.eql(u8, s, "ltx2_video") or std.mem.eql(u8, s, "ltx2-video") or
            std.mem.eql(u8, s, "ltx_video") or std.mem.eql(u8, s, "ltx-2") or
            std.mem.eql(u8, s, "ltx2")) return .ltx2_video;
        return null;
    }

    pub fn toString(self: BackendKind) []const u8 {
        return switch (self) {
            .openai_image => "openai_image",
            .azure_flux => "azure_flux",
            .qwen_image => "qwen_image",
            .seedance => "seedance",
            .volcengine_image => "volcengine_image",
            .gemini_video => "gemini_video",
            .ltx2_video => "ltx2_video",
        };
    }

    pub fn media(self: BackendKind) Media {
        return switch (self) {
            .seedance, .gemini_video, .ltx2_video => .video,
            else => .image,
        };
    }

    pub fn flow(self: BackendKind) Flow {
        return switch (self) {
            .seedance, .gemini_video, .ltx2_video => .async_task,
            else => .sync,
        };
    }

    /// Canonical environment variable holding this provider's API key. Used by
    /// ephemeral mode when `IMAGINE_API_KEY_ENV` does not name one.
    pub fn defaultKeyEnv(self: BackendKind) []const u8 {
        return switch (self) {
            .seedance, .volcengine_image => "ARK_API_KEY",
            .gemini_video => "GEMINI_API_KEY",
            .ltx2_video => "LTX2_API_KEY",
            else => "AZURE_OPENAI_APIKEY",
        };
    }

    /// True when the produced asset URL must be fetched with the same credential
    /// as the create call (Gemini Files API). Provider CDN URLs (Ark, Azure) are
    /// pre-signed and reject a request that also carries an auth header.
    pub fn assetNeedsAuth(self: BackendKind) bool {
        return switch (self) {
            .gemini_video => true,
            else => false,
        };
    }

    pub fn inputImageStyle(self: BackendKind) InputImageStyle {
        return switch (self) {
            .gemini_video, .ltx2_video => .bytes_base64,
            .seedance, .volcengine_image => .url_or_data_url,
            .openai_image, .azure_flux, .qwen_image => .unsupported,
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
    /// Denoising steps for diffusion backends (`qwen_image`).
    steps: ?u32 = null,
    // ---- video ----
    /// Clip length in seconds (video backends).
    duration: ?u32 = null,
    /// Resolution token such as `720p` / `1080p` (video backends).
    resolution: ?[]const u8 = null,
    /// Aspect-ratio token such as `16:9` (video backends).
    ratio: ?[]const u8 = null,
    /// Provider watermark (`volcengine_image` / `seedance`).
    watermark: ?bool = null,
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

/// A first-frame / reference image for image-to-video. `source` is what the
/// caller typed (URL or path); `bytes` is filled in when the file had to be
/// read, either because the source is a local path or because the backend only
/// accepts raw bytes.
pub const InputImage = struct {
    source: []const u8,
    bytes: ?[]const u8 = null,
    mime: []const u8 = "image/png",
};

/// Unified frontend request. Backends translate this into provider-specific
/// JSON. Width/height and `size` are both accepted; backends use whichever the
/// provider understands and derive one from the other when needed.
pub const GenRequest = struct {
    prompt: []const u8,
    /// Model value sent to the provider API (already resolved from api_model).
    api_model: []const u8,
    size: ?[]const u8 = null,
    width: ?u32 = null,
    height: ?u32 = null,
    /// Assets requested for this single API call. The scheduler expands the
    /// user's -n into separate tasks, so this is normally 1.
    n: u32 = 1,
    output_format: ?[]const u8 = null,
    output_compression: ?u32 = null,
    quality: ?[]const u8 = null,
    seed: ?i64 = null,
    /// Denoising steps; only diffusion backends (`qwen_image`) send this.
    steps: ?u32 = null,
    // ---- video ----
    /// Clip length in seconds.
    duration: ?u32 = null,
    /// Resolution token such as `720p` / `1080p`.
    resolution: ?[]const u8 = null,
    /// Aspect-ratio token such as `16:9`.
    ratio: ?[]const u8 = null,
    /// First-frame / reference image (image-to-video).
    image: ?InputImage = null,
    /// Provider watermark. Ark defaults it to *on* for images and *off* for
    /// video, so this is only sent when the caller decides.
    watermark: ?bool = null,

    /// Apply model defaults for any field the caller left null.
    pub fn applyDefaults(self: *GenRequest, d: ModelDefaults) void {
        if (self.size == null) self.size = d.size;
        if (self.width == null) self.width = d.width;
        if (self.height == null) self.height = d.height;
        if (self.output_format == null) self.output_format = d.output_format;
        if (self.output_compression == null) self.output_compression = d.output_compression;
        if (self.quality == null) self.quality = d.quality;
        if (self.steps == null) self.steps = d.steps;
        if (self.duration == null) self.duration = d.duration;
        if (self.resolution == null) self.resolution = d.resolution;
        if (self.ratio == null) self.ratio = d.ratio;
        if (self.watermark == null) self.watermark = d.watermark;
    }
};

/// Decoded result of a single asset from a provider response. Either raw bytes
/// (decoded from base64) or a URL the caller must still download.
pub const Payload = union(enum) {
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
    try std.testing.expectEqual(AuthScheme.google_api_key, AuthScheme.fromString("google").?);
    try std.testing.expectEqualStrings("x-goog-api-key", AuthScheme.google_api_key.headerName());
    try std.testing.expectEqual(AuthScheme.none, AuthScheme.fromString("none").?);
    try std.testing.expectEqual(BackendKind.openai_image, BackendKind.fromString("openai_image").?);
    try std.testing.expectEqual(BackendKind.openai_image, BackendKind.fromString("azure_image").?);
    try std.testing.expectEqual(BackendKind.azure_flux, BackendKind.fromString("azure-flux").?);
    try std.testing.expectEqual(BackendKind.qwen_image, BackendKind.fromString("qwen_image").?);
    try std.testing.expectEqual(BackendKind.qwen_image, BackendKind.fromString("qwen-image").?);
    try std.testing.expectEqual(BackendKind.seedance, BackendKind.fromString("seedance").?);
    try std.testing.expectEqual(BackendKind.volcengine_image, BackendKind.fromString("seedream").?);
    try std.testing.expectEqual(BackendKind.gemini_video, BackendKind.fromString("gemini_omni").?);
    try std.testing.expectEqual(BackendKind.ltx2_video, BackendKind.fromString("ltx-2").?);
    // Veo speaks a different protocol, so it must not resolve to this backend.
    try std.testing.expect(BackendKind.fromString("veo") == null);
}

test "backend routing metadata" {
    try std.testing.expectEqual(Media.video, BackendKind.seedance.media());
    try std.testing.expectEqual(Media.video, BackendKind.gemini_video.media());
    try std.testing.expectEqual(Media.video, BackendKind.ltx2_video.media());
    try std.testing.expectEqual(Media.image, BackendKind.volcengine_image.media());
    try std.testing.expectEqual(Flow.async_task, BackendKind.seedance.flow());
    try std.testing.expectEqual(Flow.async_task, BackendKind.gemini_video.flow());
    try std.testing.expectEqual(Flow.async_task, BackendKind.ltx2_video.flow());
    try std.testing.expectEqual(Flow.sync, BackendKind.volcengine_image.flow());
    try std.testing.expectEqualStrings("mp4", Media.video.defaultFormat());
    try std.testing.expectEqualStrings("png", Media.image.defaultFormat());
    try std.testing.expectEqualStrings("ARK_API_KEY", BackendKind.seedance.defaultKeyEnv());
    try std.testing.expectEqualStrings("GEMINI_API_KEY", BackendKind.gemini_video.defaultKeyEnv());
    try std.testing.expectEqualStrings("LTX2_API_KEY", BackendKind.ltx2_video.defaultKeyEnv());
    try std.testing.expectEqualStrings("AZURE_OPENAI_APIKEY", BackendKind.openai_image.defaultKeyEnv());
    try std.testing.expect(BackendKind.gemini_video.assetNeedsAuth());
    try std.testing.expect(!BackendKind.seedance.assetNeedsAuth());
    try std.testing.expectEqual(InputImageStyle.bytes_base64, BackendKind.gemini_video.inputImageStyle());
    try std.testing.expectEqual(InputImageStyle.bytes_base64, BackendKind.ltx2_video.inputImageStyle());
    try std.testing.expectEqual(InputImageStyle.url_or_data_url, BackendKind.seedance.inputImageStyle());
    try std.testing.expectEqual(InputImageStyle.unsupported, BackendKind.openai_image.inputImageStyle());
}
