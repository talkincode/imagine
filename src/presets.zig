//! Built-in model presets for the providers `imagine` ships backends for:
//! Volcengine Ark (Seedream images, Seedance video) and Google Gemini (Omni
//! video).
//!
//! These exist so `imagine models` and `-m <id>` work with nothing but an API
//! key in the environment — no config file, no URL to look up. They are
//! convenience defaults, not policy:
//!
//!   * a model with the same name in your config always wins;
//!   * credentials still come from the environment (`ARK_API_KEY`,
//!     `GEMINI_API_KEY`), never from here;
//!   * provider model ids churn, so treat a preset as a starting point —
//!     override `api_model` / `base_url` in config when a provider renames one.
//!
//! Adding a preset is a data change: one entry, no new code path. Only model
//! ids that are current at the time of writing are listed; retired ids are
//! removed rather than kept for nostalgia.

const std = @import("std");
const types = @import("types.zig");

pub const ark_base = "https://ark.cn-beijing.volces.com/api/v3";
pub const gemini_base = "https://generativelanguage.googleapis.com/v1beta";

pub const Preset = struct {
    /// Logical name, i.e. what `-m` takes. Kept equal to the provider's model
    /// id so a name copied from provider documentation works unchanged.
    name: []const u8,
    backend: types.BackendKind,
    /// Wire model id; normally the same as `name`.
    api_model: []const u8,
    base_url: []const u8,
    api_key_env: []const u8,
    auth: types.AuthScheme = .bearer,
};

pub const catalog = [_]Preset{
    // ---- Volcengine Ark: video (Seedance) ----
    .{
        .name = "doubao-seedance-2-5-260628",
        .backend = .seedance,
        .api_model = "doubao-seedance-2-5-260628",
        .base_url = ark_base ++ "/contents/generations/tasks",
        .api_key_env = "ARK_API_KEY",
    },
    .{
        .name = "doubao-seedance-2-0-fast-260128",
        .backend = .seedance,
        .api_model = "doubao-seedance-2-0-fast-260128",
        .base_url = ark_base ++ "/contents/generations/tasks",
        .api_key_env = "ARK_API_KEY",
    },
    .{
        .name = "doubao-seedance-1-0-pro-250528",
        .backend = .seedance,
        .api_model = "doubao-seedance-1-0-pro-250528",
        .base_url = ark_base ++ "/contents/generations/tasks",
        .api_key_env = "ARK_API_KEY",
    },
    // ---- Volcengine Ark: image (Seedream) ----
    .{
        .name = "doubao-seedream-5-0-260128",
        .backend = .volcengine_image,
        .api_model = "doubao-seedream-5-0-260128",
        .base_url = ark_base ++ "/images/generations",
        .api_key_env = "ARK_API_KEY",
    },
    .{
        .name = "doubao-seedream-4-0-250828",
        .backend = .volcengine_image,
        .api_model = "doubao-seedream-4-0-250828",
        .base_url = ark_base ++ "/images/generations",
        .api_key_env = "ARK_API_KEY",
    },
    // ---- Google Gemini: video (Omni, Interactions API) ----
    .{
        .name = "gemini-omni-1.1-flash",
        .backend = .gemini_video,
        .api_model = "gemini-omni-1.1-flash",
        .base_url = gemini_base ++ "/interactions",
        .api_key_env = "GEMINI_API_KEY",
        .auth = .google_api_key,
    },
};

test "catalog entries are self-consistent" {
    for (catalog) |p| {
        try std.testing.expectEqualStrings(p.name, p.api_model);
        try std.testing.expect(std.mem.startsWith(u8, p.base_url, "https://"));
        try std.testing.expect(p.api_key_env.len > 0);
        try std.testing.expect(p.auth != .none);
    }
}
