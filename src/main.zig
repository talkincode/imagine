//! imagine — entry point and command execution.
//!
//! Parsing lives in `cli.zig`; this module loads config, builds the unified
//! request, fans work into scheduler tasks, and renders human or `--json`
//! output. It is the only module that performs process I/O (stdout/stderr,
//! exit codes, the shared HTTP client).

const std = @import("std");
const cli = @import("cli.zig");
const config = @import("config.zig");
const types = @import("types.zig");
const backend = @import("backend.zig");
const scheduler = @import("scheduler.zig");
const util = @import("util.zig");
const version = @import("version.zig");
const overlay = @import("overlay.zig");
const text = @import("text.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const argv = try collectArgs(arena, init.minimal.args);
    const env = makeEnv(init.environ_map);

    const parsed = try cli.parse(arena, argv);
    switch (parsed) {
        .help => |h| {
            try printOut(io, h);
            return 0;
        },
        .err => |e| {
            try printErr(io, e);
            try printErr(io, "\n");
            return 2;
        },
        .command => |cmd| return runCommand(.{
            .gpa = gpa,
            .arena = arena,
            .io = io,
            .env = env,
        }, cmd),
    }
}

const Ctx = struct {
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    env: config.Env,
};

fn runCommand(ctx: Ctx, cmd: cli.Command) !u8 {
    return switch (cmd) {
        .version => blk: {
            try outf(ctx, "{s} {s}\n", .{ version.name, version.string });
            break :blk 0;
        },
        .config_path => |c| cmdConfigPath(ctx, c),
        .config_init => |c| cmdConfigInit(ctx, c),
        .config_convert => |c| cmdConfigConvert(ctx, c),
        .config_show => |c| cmdConfigShow(ctx, c),
        .models => |c| cmdModels(ctx, c),
        .generate => |g| cmdGenerate(ctx, g),
        .batch => |b| cmdBatch(ctx, b),
        .svg_render => |r| cmdSvgRender(ctx, r),
        .png_compose => |p| cmdPngCompose(ctx, p),
        .text_render => |t| cmdTextRender(ctx, t),
        .compose => |c| cmdCompose(ctx, c),
    };
}

// ---------------------------------------------------------------------------
// config commands
// ---------------------------------------------------------------------------

fn cmdConfigPath(ctx: Ctx, c: cli.Common) !u8 {
    const path = try config.resolvePath(ctx.arena, ctx.env, c.config_path);
    try outf(ctx, "{s}\n", .{path});
    return 0;
}

fn cmdConfigInit(ctx: Ctx, c: cli.ConfigInit) !u8 {
    const raw = try config.resolvePath(ctx.arena, ctx.env, c.common.config_path);
    const path = try expandPath(ctx, raw);
    const fmt = selectInitFormat(ctx, c.format, path) catch return 2;
    const cwd = std.Io.Dir.cwd();

    const exists = blk: {
        cwd.access(ctx.io, path, .{}) catch break :blk false;
        break :blk true;
    };
    if (exists and !c.force) {
        try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "config already exists: {s} (use --force to overwrite)\n", .{path}));
        return 1;
    }

    if (util.dirName(path)) |_| {
        try util.ensureParentDir(ctx.io, cwd, path);
    }
    const data = switch (fmt) {
        .toml => config.template,
        .json => config.json_template,
    };
    try cwd.writeFile(ctx.io, .{ .sub_path = path, .data = data });
    try outf(ctx, "wrote starter {s} config to {s}\nedit model names/URLs, then set your API key (default env: AZURE_OPENAI_APIKEY)\nrun `imagine models` to list configured models\n", .{ fmt.toString(), path });
    return 0;
}

fn cmdConfigConvert(ctx: Ctx, c: cli.ConfigConvert) !u8 {
    var cfg = loadConfig(ctx, c.common.config_path) catch |e| return reportConfigError(ctx, e, c.common.config_path);
    defer cfg.deinit();

    const fmt = selectConvertFormat(ctx, c.to, c.output, cfg.source_format) catch return 2;
    const rendered = try config.renderAlloc(ctx.arena, cfg, fmt);

    if (c.output) |out_raw| {
        const path = try expandPath(ctx, out_raw);
        const cwd = std.Io.Dir.cwd();
        const exists = blk: {
            cwd.access(ctx.io, path, .{}) catch break :blk false;
            break :blk true;
        };
        if (exists and !c.force) {
            try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "output already exists: {s} (use --force to overwrite)\n", .{path}));
            return 1;
        }
        if (util.dirName(path)) |_| {
            try util.ensureParentDir(ctx.io, cwd, path);
        }
        try cwd.writeFile(ctx.io, .{ .sub_path = path, .data = rendered });
        try outf(ctx, "wrote {s} config to {s}\n", .{ fmt.toString(), path });
    } else {
        try printOut(ctx.io, rendered);
    }
    return 0;
}

fn cmdConfigShow(ctx: Ctx, c: cli.Common) !u8 {
    var cfg = loadConfig(ctx, c.config_path) catch |e| return reportConfigError(ctx, e, c.config_path);
    defer cfg.deinit();

    if (cfg.source == .preset) {
        try printErr(ctx.io, "no config file found; showing built-in defaults (run 'imagine config init' to write one)\n");
    }

    const Endpoint = struct {
        base_url: []const u8,
        auth: []const u8,
        api_key_env: ?[]const u8,
        key: []const u8,
    };
    const Model = struct {
        name: []const u8,
        backend: []const u8,
        api_model: []const u8,
        endpoints: []Endpoint,
        defaults: types.ModelDefaults,
    };
    const Show = struct {
        source: []const u8,
        config_path: ?[]const u8,
        output_dir: []const u8,
        concurrency: u32,
        poll_interval: u32,
        task_timeout: u32,
        models: []Model,
    };

    var models = try ctx.arena.alloc(Model, cfg.models.len);
    for (cfg.models, 0..) |m, mi| {
        var eps = try ctx.arena.alloc(Endpoint, m.endpoints.len);
        for (m.endpoints, 0..) |ep, ei| {
            const key_disp = if (ep.auth == .none)
                try ctx.arena.dupe(u8, "(not required)")
            else if (ep.resolved_key) |k|
                try util.redactKey(ctx.arena, k)
            else
                try ctx.arena.dupe(u8, "(unset)");
            eps[ei] = .{
                .base_url = ep.base_url,
                .auth = ep.auth.toString(),
                .api_key_env = ep.api_key_env,
                .key = key_disp,
            };
        }
        models[mi] = .{
            .name = m.name,
            .backend = m.backend.toString(),
            .api_model = m.api_model,
            .endpoints = eps,
            .defaults = m.defaults,
        };
    }
    const show = Show{
        .source = cfg.source.toString(),
        .config_path = cfg.source_path,
        .output_dir = cfg.output_dir,
        .concurrency = cfg.concurrency,
        .poll_interval = cfg.poll_interval,
        .task_timeout = cfg.task_timeout,
        .models = models,
    };
    // Omit nulls: an unset optional is the common case and 11 nulls per model
    // drown the values that are actually configured.
    const json = try std.json.Stringify.valueAlloc(ctx.arena, show, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = false,
    });
    try outf(ctx, "{s}\n", .{json});
    return 0;
}

fn cmdModels(ctx: Ctx, c: cli.Common) !u8 {
    var cfg = loadConfig(ctx, c.config_path) catch |e| return reportConfigError(ctx, e, c.config_path);
    defer cfg.deinit();

    // A preset whose name a configured model claims is unreachable, so it is
    // not listed at all — `findPreset` resolves the same way.
    var visible = std.ArrayList(types.ModelConfig).empty;
    for (cfg.presets) |m| {
        if (cfg.findModel(m.name) == null) try visible.append(ctx.arena, m);
    }
    const presets = visible.items;

    if (c.json) {
        const Item = struct {
            name: []const u8,
            backend: []const u8,
            media: []const u8,
            api_model: []const u8,
            endpoints: usize,
            ready: bool,
            source: []const u8,
        };
        var items = try ctx.arena.alloc(Item, cfg.models.len + presets.len);
        var i: usize = 0;
        for (cfg.models) |m| {
            items[i] = .{
                .name = m.name,
                .backend = m.backend.toString(),
                .media = m.backend.media().toString(),
                .api_model = m.api_model,
                .endpoints = m.endpoints.len,
                .ready = modelReady(m),
                .source = cfg.source.toString(),
            };
            i += 1;
        }
        // Presets are always listed so an agent can see what is callable with
        // nothing but an API key; `source` tells them apart from real config.
        for (presets) |m| {
            items[i] = .{
                .name = m.name,
                .backend = m.backend.toString(),
                .media = m.backend.media().toString(),
                .api_model = m.api_model,
                .endpoints = m.endpoints.len,
                .ready = modelReady(m),
                .source = "preset",
            };
            i += 1;
        }
        const json = try std.json.Stringify.valueAlloc(ctx.arena, items, .{ .whitespace = .indent_2 });
        try outf(ctx, "{s}\n", .{json});
        return 0;
    }

    try outf(ctx, "configured models ({d}, source={s}):\n", .{ cfg.models.len, cfg.source.toString() });
    for (cfg.models) |m| {
        const ready = if (modelReady(m)) "ready" else "no key";
        try outf(ctx, "  {s:<28} backend={s:<17} endpoints={d} [{s}]\n", .{ m.name, m.backend.toString(), m.endpoints.len, ready });
    }
    if (presets.len > 0) {
        try outf(ctx, "built-in presets ({d}, credential from env):\n", .{presets.len});
        for (presets) |m| {
            const ready = if (modelReady(m)) "ready" else "no key";
            try outf(ctx, "  {s:<28} backend={s:<17} env={s} [{s}]\n", .{
                m.name,
                m.backend.toString(),
                m.endpoints[0].api_key_env orelse "-",
                ready,
            });
        }
    }
    return 0;
}

fn modelReady(m: types.ModelConfig) bool {
    for (m.endpoints) |ep| {
        // A keyless endpoint (`auth = "none"`, e.g. a local Qwen-Image server)
        // is ready as soon as it is configured; the rest need a credential.
        if (ep.auth == .none) return true;
        if (ep.resolved_key != null) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// generate
// ---------------------------------------------------------------------------

fn cmdGenerate(ctx: Ctx, g: cli.Generate) !u8 {
    var cfg = loadConfig(ctx, g.common.config_path) catch |e| return reportConfigError(ctx, e, g.common.config_path);
    defer cfg.deinit();

    const model = (try resolveModel(ctx, &cfg, g.model)) orelse return 2;

    var req = types.GenRequest{
        .prompt = g.prompt.?,
        .api_model = model.api_model,
        .size = g.size,
        .width = g.width,
        .height = g.height,
        .n = 1,
        .output_format = g.format,
        .output_compression = g.compression,
        .quality = g.quality,
        .seed = g.seed,
        .steps = g.steps,
        .duration = g.duration,
        .resolution = g.resolution,
        .ratio = g.ratio,
        .watermark = g.watermark,
    };
    req.applyDefaults(model.defaults);
    if (g.image != null and model.backend.inputImageStyle() == .unsupported) {
        return reportUnsupportedImage(ctx, model.backend);
    }
    req.image = readInputImage(ctx, g.image) catch |e| switch (e) {
        error.InputImageUnreadable => return 2,
        else => return e,
    };

    if (g.dry_run) {
        return dryRun(ctx, model, req, g.n, &cfg, g.poll_interval, g.timeout) catch |e| switch (e) {
            error.DryRunBodyUnavailable => 2,
            else => e,
        };
    }

    var client = std.http.Client{ .allocator = ctx.gpa, .io = ctx.io };
    defer client.deinit();

    // A first-frame URL is fetched here when the provider only takes bytes (a
    // local file was already read above). This must happen before the tasks are
    // built, because each task takes a copy of the request.
    if (req.image) |img| {
        req.image = backend.resolveInputImage(&client, ctx.arena, model.backend, img) catch {
            try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "cannot fetch --image '{s}' for backend {s}\n", .{ img.source, model.backend.toString() }));
            return 1;
        };
    }

    // Resolve the output base path and extension: a video model defaults to
    // .mp4 while every image backend keeps its provider format.
    const ext = backend.outputExt(model.backend, req.output_format);
    const base = try resolveOutputBase(ctx, &cfg, g.output, ext);

    // Build one task per requested asset, round-robining endpoints.
    var tasks = try ctx.arena.alloc(scheduler.Task, g.n);
    for (0..g.n) |i| {
        const path = if (g.n == 1) base else try util.numberedPath(ctx.arena, base, i + 1);
        tasks[i] = .{
            .model = model,
            .endpoint = &model.endpoints[i % model.endpoints.len],
            .req = req,
            .output_path = path,
            .arena = std.heap.ArenaAllocator.init(ctx.gpa),
        };
    }
    defer for (tasks) |*t| t.arena.deinit();

    const conc = chooseConcurrency(g.concurrency, cfg.concurrency, model.endpoints.len, g.n);
    if (!g.quiet and !g.common.json) {
        try outf(ctx, "generating {d} {s}(s) with '{s}' across {d} endpoint(s), concurrency {d}\n", .{ g.n, model.backend.media().toString(), model.name, model.endpoints.len, conc });
    }

    scheduler.run(tasks, .{
        .concurrency = conc,
        .io = ctx.io,
        .client = &client,
        .progress = !g.quiet and !g.common.json,
        .poll_interval_secs = g.poll_interval orelse cfg.poll_interval,
        .timeout_secs = g.timeout orelse cfg.task_timeout,
    });

    return try renderResults(ctx, model, tasks, g.common.json);
}

/// `--image` on a backend that takes no image input. Silently ignoring the file
/// would let an agent believe the reference was used, so it is a usage error.
fn reportUnsupportedImage(ctx: Ctx, kind: types.BackendKind) !u8 {
    try printErr(ctx.io, try std.fmt.allocPrint(
        ctx.arena,
        "backend {s} takes no --image input (supported by: seedance, gemini_video, volcengine_image)\n",
        .{kind.toString()},
    ));
    return 2;
}

/// The create body `--dry-run` prints. An inlined `--image` would put megabytes
/// of base64 into that output, so its payload is replaced by its byte count;
/// everything else is verbatim. A body that cannot be built without network
/// access (a URL image for a bytes-only backend) is reported as a message
/// instead of a Zig error trace.
fn dryRunBody(ctx: Ctx, model: *const types.ModelConfig, req: types.GenRequest) ![]const u8 {
    const body = backend.buildBody(model.backend, ctx.arena, req) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InputImageNotFetched => {
            try printErr(ctx.io, "this backend needs the --image bytes inline, but --dry-run makes no network call; pass a local file, or drop --dry-run to fetch the URL\n");
            return error.DryRunBodyUnavailable;
        },
    };
    const bytes = if (req.image) |img| (img.bytes orelse return body) else return body;
    const b64 = try util.base64EncodeAlloc(ctx.arena, bytes);
    const at = std.mem.indexOf(u8, body, b64) orelse return body;
    const note = try std.fmt.allocPrint(ctx.arena, "<{d} bytes of base64 elided>", .{b64.len});
    return std.fmt.allocPrint(ctx.arena, "{s}{s}{s}", .{ body[0..at], note, body[at + b64.len ..] });
}

/// Largest `--image` file read into memory. Ark caps a request body at 64 MB and
/// a single image at 30 MB; 32 MB leaves room for the prompt and encoding.
const max_input_image_bytes: usize = 32 * 1024 * 1024;

/// `--image` accepts a path or an http(s) URL. Local files are read here so a
/// typo fails before any provider request; URLs are left to the backend layer,
/// which knows whether the provider takes URLs or raw bytes.
fn readInputImage(ctx: Ctx, source: ?[]const u8) !?types.InputImage {
    const raw = source orelse return null;
    if (util.isHttpUrl(raw)) {
        return types.InputImage{
            .source = try ctx.arena.dupe(u8, raw),
            .mime = util.mimeForPath(raw),
        };
    }
    const path = try expandPath(ctx, raw);
    const bytes = std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .limited(max_input_image_bytes)) catch |e| {
        try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "cannot read --image '{s}': {s}\n", .{ path, @errorName(e) }));
        return error.InputImageUnreadable;
    };
    return types.InputImage{
        .source = path,
        .bytes = bytes,
        // Magic bytes beat the extension: a misnamed file would otherwise be
        // rejected by the provider for declaring the wrong type.
        .mime = util.sniffImageMime(bytes) orelse util.mimeForPath(path),
    };
}

fn dryRun(
    ctx: Ctx,
    model: *const types.ModelConfig,
    req: types.GenRequest,
    n: u32,
    cfg: *const config.Config,
    poll_interval: ?u32,
    timeout: ?u32,
) !u8 {
    const body = try dryRunBody(ctx, model, req);
    const ep = &model.endpoints[0];
    const media = model.backend.media();
    try outf(ctx,
        \\dry run (no API call)
        \\  model:    {s}
        \\  backend:  {s}
        \\  media:    {s}
        \\  endpoint: {s}
        \\  assets:   {d}
        \\  request body (n=1 per call):
        \\{s}
        \\
    , .{ model.name, model.backend.toString(), media.toString(), ep.base_url, n, body });
    if (model.backend.flow() == .async_task) {
        try outf(ctx,
            \\  async: this backend creates a provider task and polls it
            \\  poll:  every {d}s, giving up after {d}s (--poll-interval/--timeout)
            \\
        , .{ poll_interval orelse cfg.poll_interval, timeout orelse cfg.task_timeout });
    }
    return 0;
}

// ---------------------------------------------------------------------------
// batch
// ---------------------------------------------------------------------------

fn cmdBatch(ctx: Ctx, b: cli.Batch) !u8 {
    var cfg = loadConfig(ctx, b.common.config_path) catch |e| return reportConfigError(ctx, e, b.common.config_path);
    defer cfg.deinit();

    const manifest_path = try expandPath(ctx, b.manifest.?);
    const bytes = std.Io.Dir.cwd().readFileAlloc(ctx.io, manifest_path, ctx.arena, .limited(8 * 1024 * 1024)) catch |e| {
        try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "cannot read manifest '{s}': {s}\n", .{ manifest_path, @errorName(e) }));
        return 1;
    };

    var parsed = std.json.parseFromSlice(std.json.Value, ctx.arena, bytes, .{}) catch |e| {
        try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "invalid manifest JSON: {s}\n", .{@errorName(e)}));
        return 1;
    };
    defer parsed.deinit();

    const jobs_v = switch (parsed.value) {
        .object => |o| o.get("jobs") orelse {
            try printErr(ctx.io, "manifest must have a 'jobs' array\n");
            return 1;
        },
        .array => parsed.value,
        else => {
            try printErr(ctx.io, "manifest must be an object with 'jobs' or a top-level array\n");
            return 1;
        },
    };
    if (jobs_v != .array or jobs_v.array.items.len == 0) {
        try printErr(ctx.io, "manifest has no jobs\n");
        return 1;
    }

    // Expand jobs into tasks.
    var tasks = std.ArrayList(scheduler.Task).empty;

    for (jobs_v.array.items) |job_v| {
        if (job_v != .object) continue;
        const job = job_v.object;
        const model_name = jsonStr(job, "model") orelse {
            try printErr(ctx.io, "each job needs a 'model'\n");
            return 1;
        };
        const model = cfg.findModel(model_name) orelse cfg.findPreset(model_name) orelse {
            _ = try reportUnknownModel(ctx, &cfg, model_name);
            return 2;
        };
        const prompt = jsonStr(job, "prompt") orelse {
            try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "job for model '{s}' needs a 'prompt'\n", .{model_name}));
            return 1;
        };

        var req = types.GenRequest{
            .prompt = try ctx.arena.dupe(u8, prompt),
            .api_model = model.api_model,
            .size = if (jsonStr(job, "size")) |s| try ctx.arena.dupe(u8, s) else null,
            .width = jsonU32(job, "width"),
            .height = jsonU32(job, "height"),
            .n = 1,
            .output_format = if (jsonStr(job, "format")) |s| try ctx.arena.dupe(u8, s) else null,
            .output_compression = jsonU32(job, "compression"),
            .quality = if (jsonStr(job, "quality")) |s| try ctx.arena.dupe(u8, s) else null,
            .seed = jsonI64(job, "seed"),
            .steps = jsonU32(job, "steps"),
            .duration = jsonU32(job, "duration"),
            .resolution = if (jsonStr(job, "resolution")) |s| try ctx.arena.dupe(u8, s) else null,
            .ratio = if (jsonStr(job, "ratio")) |s| try ctx.arena.dupe(u8, s) else null,
            .watermark = jsonBool(job, "watermark"),
        };
        req.applyDefaults(model.defaults);
        if (jsonStr(job, "image") != null and model.backend.inputImageStyle() == .unsupported) {
            return reportUnsupportedImage(ctx, model.backend);
        }
        req.image = readInputImage(ctx, jsonStr(job, "image")) catch |e| switch (e) {
            error.InputImageUnreadable => return 2,
            else => return e,
        };

        const n = jsonU32(job, "n") orelse 1;
        const ext = backend.outputExt(model.backend, req.output_format);
        const base = if (jsonStr(job, "output")) |o|
            try expandPath(ctx, o)
        else
            try defaultOutputPath(ctx, &cfg, ext);

        for (0..n) |i| {
            const path = if (n == 1) base else try util.numberedPath(ctx.arena, base, i + 1);
            try tasks.append(ctx.arena, .{
                .model = model,
                .endpoint = &model.endpoints[i % model.endpoints.len],
                .req = req,
                .output_path = path,
                .arena = std.heap.ArenaAllocator.init(ctx.gpa),
            });
        }
    }

    const task_slice = try tasks.toOwnedSlice(ctx.arena);
    if (task_slice.len == 0) {
        try printErr(ctx.io, "no valid jobs in manifest\n");
        return 1;
    }
    defer for (task_slice) |*t| t.arena.deinit();

    if (b.dry_run) {
        try outf(ctx, "dry run: {d} task(s) from manifest\n", .{task_slice.len});
        for (task_slice) |*t| {
            const body = dryRunBody(ctx, t.model, t.req) catch |e| switch (e) {
                error.DryRunBodyUnavailable => return 2,
                else => return e,
            };
            try outf(ctx, "  {s} -> {s}\n    {s}\n", .{ t.model.name, t.output_path, body });
        }
        return 0;
    }

    var client = std.http.Client{ .allocator = ctx.gpa, .io = ctx.io };
    defer client.deinit();

    // Same rule as `generate`: a first-frame URL is fetched only when the
    // backend cannot take a URL directly.
    for (task_slice) |*t| {
        if (t.req.image) |img| {
            t.req.image = backend.resolveInputImage(&client, ctx.arena, t.model.backend, img) catch {
                try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "cannot fetch --image '{s}' for backend {s}\n", .{ img.source, t.model.backend.toString() }));
                return 1;
            };
        }
    }

    const conc = chooseConcurrency(b.concurrency, cfg.concurrency, distinctEndpoints(task_slice), task_slice.len);
    if (!b.quiet and !b.common.json) {
        try outf(ctx, "running {d} task(s), concurrency {d}\n", .{ task_slice.len, conc });
    }

    scheduler.run(task_slice, .{
        .concurrency = conc,
        .io = ctx.io,
        .client = &client,
        .progress = !b.quiet and !b.common.json,
        .poll_interval_secs = b.poll_interval orelse cfg.poll_interval,
        .timeout_secs = b.timeout orelse cfg.task_timeout,
    });

    return try renderBatchResults(ctx, task_slice, b.common.json);
}

// ---------------------------------------------------------------------------
// result rendering
// ---------------------------------------------------------------------------

fn cmdCompose(ctx: Ctx, c: cli.Compose) !u8 {
    const base = try expandPath(ctx, c.base.?);
    const svg = try expandPath(ctx, c.svg.?);
    const output = try expandPath(ctx, c.output.?);
    const blend = if (c.blend) |b| overlay.BlendMode.fromString(b) orelse {
        try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "unknown blend mode: {s}\n", .{b}));
        return 2;
    } else overlay.BlendMode.normal;

    if (util.dirName(output)) |_| {
        try util.ensureParentDir(ctx.io, std.Io.Dir.cwd(), output);
    }

    overlay.compose(ctx.arena, .{
        .base_path = base,
        .svg_path = svg,
        .output_path = output,
        .x = c.x,
        .y = c.y,
        .width = c.width,
        .height = c.height,
        .opacity = c.opacity,
        .blend = blend,
    }) catch |e| {
        return reportOverlayError(ctx, "compose", e);
    };

    try outf(ctx, "wrote composed PNG to {s}\n", .{output});
    return 0;
}

fn cmdSvgRender(ctx: Ctx, r: cli.SvgRender) !u8 {
    const input = try expandPath(ctx, r.input.?);
    const output = try expandPath(ctx, r.output.?);
    if (util.dirName(output)) |_| {
        try util.ensureParentDir(ctx.io, std.Io.Dir.cwd(), output);
    }
    overlay.renderSvgToPng(ctx.arena, .{
        .input_path = input,
        .output_path = output,
        .width = r.width,
        .height = r.height,
    }) catch |e| return reportOverlayError(ctx, "svg render", e);
    try outf(ctx, "wrote rendered PNG to {s}\n", .{output});
    return 0;
}

fn cmdPngCompose(ctx: Ctx, p: cli.PngCompose) !u8 {
    const base = try expandPath(ctx, p.base.?);
    const output = try expandPath(ctx, p.output.?);
    if (util.dirName(output)) |_| {
        try util.ensureParentDir(ctx.io, std.Io.Dir.cwd(), output);
    }

    var layers = try ctx.arena.alloc(overlay.Layer, p.layers.len);
    for (p.layers, 0..) |spec, i| {
        layers[i] = parseLayerSpec(ctx, spec) catch |e| {
            try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "invalid layer spec '{s}': {s}\n", .{ spec, @errorName(e) }));
            return 2;
        };
    }

    overlay.composePng(ctx.arena, .{
        .base_path = base,
        .output_path = output,
        .layers = layers,
    }) catch |e| return reportOverlayError(ctx, "png compose", e);
    try outf(ctx, "wrote composed PNG to {s}\n", .{output});
    return 0;
}

fn cmdTextRender(ctx: Ctx, t: cli.TextRender) !u8 {
    const output = try expandPath(ctx, t.output.?);
    if (util.dirName(output)) |_| {
        try util.ensureParentDir(ctx.io, std.Io.Dir.cwd(), output);
    }
    const text_align = text.Align.fromString(t.text_align) orelse {
        try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "unknown text align: {s} (expected left, center, or right)\n", .{t.text_align}));
        return 2;
    };
    const rendered = text.renderSvgAlloc(ctx.arena, .{
        .text = t.text.?,
        .width = t.width.?,
        .height = t.height,
        .font = t.font orelse "Arial",
        .size = t.size,
        .color = t.color,
        .stroke = t.stroke,
        .stroke_width = t.stroke_width,
        .text_align = text_align,
        .line_height = t.line_height,
        .padding = t.padding,
    }) catch |e| {
        try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "text render failed: {s}\n", .{@errorName(e)}));
        return 1;
    };

    overlay.renderSvgDataToPng(ctx.arena, .{
        .svg = rendered.svg,
        .output_path = output,
        .width = rendered.width,
        .height = rendered.height,
    }) catch |e| return reportOverlayError(ctx, "text render", e);

    try outf(ctx, "wrote rendered text PNG to {s}\n", .{output});
    return 0;
}

fn reportOverlayError(ctx: Ctx, command: []const u8, e: anyerror) !u8 {
    switch (e) {
        error.SvgOverlayDisabled => {
            try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "{s} requires SVG rendering support; rebuild with 'zig build -Dsvg-overlay=true' and ensure libresvg is installed\n", .{command}));
        },
        else => {
            try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "{s} failed: {s}\n", .{ command, @errorName(e) }));
        },
    }
    return 1;
}

fn renderResults(ctx: Ctx, model: *const types.ModelConfig, tasks: []scheduler.Task, json: bool) !u8 {
    var ok_count: usize = 0;
    for (tasks) |*t| {
        if (t.ok()) ok_count += 1;
    }
    const failed = tasks.len - ok_count;

    if (json) {
        const AssetOut = struct { path: []const u8, bytes: usize };
        var images = std.ArrayList(AssetOut).empty;
        var videos = std.ArrayList(AssetOut).empty;
        var errors = std.ArrayList([]const u8).empty;
        // Assets land under the key matching the model's media kind; the other
        // array stays present (and empty) so the shape never changes.
        const bucket = if (model.backend.media() == .video) &videos else &images;
        for (tasks) |*t| {
            if (t.ok()) {
                for (t.written_paths) |p| try bucket.append(ctx.arena, .{ .path = p, .bytes = t.bytes_total });
            } else {
                try errors.append(ctx.arena, t.err.?);
            }
        }
        const Result = struct {
            ok: bool,
            media: []const u8,
            model: []const u8,
            backend: []const u8,
            requested: usize,
            succeeded: usize,
            failed: usize,
            images: []AssetOut,
            videos: []AssetOut,
            errors: [][]const u8,
        };
        const result = Result{
            .ok = failed == 0,
            .media = model.backend.media().toString(),
            .model = model.name,
            .backend = model.backend.toString(),
            .requested = tasks.len,
            .succeeded = ok_count,
            .failed = failed,
            .images = try images.toOwnedSlice(ctx.arena),
            .videos = try videos.toOwnedSlice(ctx.arena),
            .errors = try errors.toOwnedSlice(ctx.arena),
        };
        const out = try std.json.Stringify.valueAlloc(ctx.arena, result, .{ .whitespace = .indent_2 });
        try outf(ctx, "{s}\n", .{out});
    } else {
        try outf(ctx, "done: {d} succeeded, {d} failed\n", .{ ok_count, failed });
    }
    return if (failed == 0) 0 else 1;
}

fn renderBatchResults(ctx: Ctx, tasks: []scheduler.Task, json: bool) !u8 {
    var ok_count: usize = 0;
    for (tasks) |*t| {
        if (t.ok()) ok_count += 1;
    }
    const failed = tasks.len - ok_count;

    if (json) {
        const TaskOut = struct {
            model: []const u8,
            media: []const u8,
            path: []const u8,
            bytes: usize,
            ok: bool,
            err: ?[]const u8,
        };
        var items = try ctx.arena.alloc(TaskOut, tasks.len);
        for (tasks, 0..) |*t, i| {
            const p = if (t.written_paths.len > 0) t.written_paths[0] else t.output_path;
            items[i] = .{
                .model = t.model.name,
                .media = t.model.backend.media().toString(),
                .path = p,
                .bytes = t.bytes_total,
                .ok = t.ok(),
                .err = t.err,
            };
        }
        const Result = struct {
            ok: bool,
            total: usize,
            succeeded: usize,
            failed: usize,
            tasks: []TaskOut,
        };
        const result = Result{ .ok = failed == 0, .total = tasks.len, .succeeded = ok_count, .failed = failed, .tasks = items };
        const out = try std.json.Stringify.valueAlloc(ctx.arena, result, .{ .whitespace = .indent_2 });
        try outf(ctx, "{s}\n", .{out});
    } else {
        try outf(ctx, "batch done: {d} succeeded, {d} failed\n", .{ ok_count, failed });
    }
    return if (failed == 0) 0 else 1;
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

fn chooseConcurrency(cli_val: ?usize, cfg_val: u32, endpoints: usize, tasks: usize) usize {
    const want: usize = if (cli_val) |v| v else if (cfg_val > 0) cfg_val else @max(@as(usize, 1), endpoints);
    return @max(@as(usize, 1), @min(want, tasks));
}

fn distinctEndpoints(tasks: []scheduler.Task) usize {
    // Upper bound on useful parallelism: count distinct endpoint pointers.
    var count: usize = 0;
    for (tasks, 0..) |*t, i| {
        var seen = false;
        for (tasks[0..i]) |*p| {
            if (p.endpoint == t.endpoint) {
                seen = true;
                break;
            }
        }
        if (!seen) count += 1;
    }
    return @max(@as(usize, 1), count);
}

fn resolveOutputBase(ctx: Ctx, cfg: *const config.Config, output: ?[]const u8, ext: []const u8) ![]const u8 {
    if (output) |o| return expandPath(ctx, o);
    return defaultOutputPath(ctx, cfg, ext);
}

fn defaultOutputPath(ctx: Ctx, cfg: *const config.Config, ext: []const u8) ![]const u8 {
    const dir = try expandPath(ctx, cfg.output_dir);
    const stamp = try util.timestampName(ctx.arena, ctx.io);
    return std.fmt.allocPrint(ctx.arena, "{s}/imagine-{s}.{s}", .{ dir, stamp, ext });
}

fn expandPath(ctx: Ctx, path: []const u8) ![]u8 {
    const home = ctx.env.get("HOME") orelse ctx.env.get("USERPROFILE");
    return util.expandTilde(ctx.arena, home, path);
}

fn loadConfig(ctx: Ctx, explicit: ?[]const u8) !config.Config {
    // 1) Explicit --config: file only.
    if (explicit) |p| {
        const path = try expandPath(ctx, p);
        return config.loadFromFile(ctx.gpa, ctx.io, path, ctx.env);
    }

    // 2) $IMAGINE_CONFIG: file only.
    if (ctx.env.get(config.env_config_path)) |p| {
        if (p.len > 0) {
            const path = try expandPath(ctx, p);
            return config.loadFromFile(ctx.gpa, ctx.io, path, ctx.env);
        }
    }

    // 3) Default toml, then legacy json.
    const raw = try config.resolvePath(ctx.arena, ctx.env, null);
    const path = try expandPath(ctx, raw);
    return config.loadFromFile(ctx.gpa, ctx.io, path, ctx.env) catch |e| {
        if (e != error.FileNotFound) return e;

        const legacy_raw = try config.resolveLegacyJsonPath(ctx.arena, ctx.env);
        const legacy_path = try expandPath(ctx, legacy_raw);
        return config.loadFromFile(ctx.gpa, ctx.io, legacy_path, ctx.env) catch |e2| {
            if (e2 != error.FileNotFound) return e2;

            // 4) Ephemeral env synthesis when no config file exists.
            if (config.ephemeralReady(ctx.env)) {
                return config.loadEphemeral(ctx.gpa, ctx.env);
            }
            if (config.ephemeralIntent(ctx.env)) {
                return error.EphemeralIncomplete;
            }
            // 5) Nothing configured at all: built-in presets are still callable
            //    with just their API key in the environment.
            return config.loadPresetsOnly(ctx.gpa, ctx.env);
        };
    };
}

/// Pick a model by name, or the sole configured model when `--model` is omitted.
/// For ephemeral configs, `--model` may retarget the single model's name/api_model.
fn resolveModel(ctx: Ctx, cfg: *config.Config, requested: ?[]const u8) !?*const types.ModelConfig {
    if (requested) |name| {
        if (cfg.findModel(name)) |m| return m;
        if (cfg.source == .ephemeral and cfg.models.len == 1) {
            const m = &cfg.models[0];
            m.name = try cfg.arena.allocator().dupe(u8, name);
            if (!cfg.ephemeral_api_model_set) {
                m.api_model = m.name;
            }
            return m;
        }
        // Built-in presets are the last resort, so a config model always wins.
        if (cfg.findPreset(name)) |m| return m;
        _ = try reportUnknownModel(ctx, cfg, name);
        return null;
    }
    if (cfg.models.len == 1) return &cfg.models[0];
    if (cfg.models.len == 0 and cfg.presets.len > 0) {
        try printErr(ctx.io, "missing required option: --model (nothing configured; pass a built-in preset name from `imagine models`)\n");
        return null;
    }
    try printErr(ctx.io, "missing required option: --model (multiple models configured; run `imagine models`)\n");
    return null;
}

fn selectInitFormat(ctx: Ctx, requested: ?[]const u8, path: []const u8) !config.Format {
    if (requested) |f| {
        return config.Format.fromString(f) orelse {
            try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "unknown config format: {s} (expected toml or json)\n", .{f}));
            return error.InvalidConfigFormat;
        };
    }
    return config.inferFormatFromPath(path) orelse .toml;
}

fn selectConvertFormat(ctx: Ctx, requested: ?[]const u8, output: ?[]const u8, input: ?config.Format) !config.Format {
    if (requested) |f| {
        return config.Format.fromString(f) orelse {
            try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "unknown config format: {s} (expected toml or json)\n", .{f}));
            return error.InvalidConfigFormat;
        };
    }
    if (output) |p| {
        if (config.inferFormatFromPath(p)) |f| return f;
    }
    return switch (input orelse .json) {
        .json => .toml,
        .toml => .json,
    };
}

fn reportConfigError(ctx: Ctx, e: anyerror, explicit: ?[]const u8) !u8 {
    const raw = config.resolvePath(ctx.arena, ctx.env, explicit) catch "(unknown)";
    switch (e) {
        error.FileNotFound => {
            const hint = try config.noConfigHint(ctx.arena, ctx.env);
            try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "no config found at {s}\n{s}", .{ raw, hint }));
        },
        error.EphemeralIncomplete, error.EphemeralNoCredential => {
            const hint = try config.noConfigHint(ctx.arena, ctx.env);
            try printErr(ctx.io, hint);
        },
        else => {
            try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "failed to load config {s}: {s}\n", .{ raw, @errorName(e) }));
        },
    }
    return 1;
}

fn reportUnknownModel(ctx: Ctx, cfg: *const config.Config, name: []const u8) !u8 {
    try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "unknown model: '{s}'\navailable models:\n", .{name}));
    for (cfg.models) |m| {
        try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "  {s}\n", .{m.name}));
    }
    if (cfg.presets.len > 0) {
        try printErr(ctx.io, "built-in presets (key from env):\n");
        for (cfg.presets) |m| {
            try printErr(ctx.io, try std.fmt.allocPrint(ctx.arena, "  {s}\n", .{m.name}));
        }
    }
    return 1;
}

fn parseLayerSpec(ctx: Ctx, spec: []const u8) !overlay.Layer {
    var parts = std.mem.splitScalar(u8, spec, ',');
    const raw_path = parts.next() orelse return error.MissingLayerPath;
    if (raw_path.len == 0) return error.MissingLayerPath;

    var layer = overlay.Layer{ .path = try expandPath(ctx, raw_path) };
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse return error.BadLayerOption;
        const key = part[0..eq];
        const value = part[eq + 1 ..];
        if (std.mem.eql(u8, key, "x")) {
            layer.x = std.fmt.parseInt(i32, value, 10) catch return error.BadLayerX;
        } else if (std.mem.eql(u8, key, "y")) {
            layer.y = std.fmt.parseInt(i32, value, 10) catch return error.BadLayerY;
        } else if (std.mem.eql(u8, key, "opacity")) {
            layer.opacity = std.fmt.parseFloat(f32, value) catch return error.BadLayerOpacity;
            if (layer.opacity < 0 or layer.opacity > 1 or !std.math.isFinite(layer.opacity)) return error.BadLayerOpacity;
        } else if (std.mem.eql(u8, key, "blend")) {
            layer.blend = overlay.BlendMode.fromString(value) orelse return error.BadLayerBlend;
        } else {
            return error.BadLayerOption;
        }
    }
    return layer;
}

fn jsonStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn jsonU32(obj: std.json.ObjectMap, key: []const u8) ?u32 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| if (i < 0) null else @intCast(i),
        else => null,
    };
}

fn jsonI64(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        else => null,
    };
}

fn jsonBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .bool => |b| b,
        else => null,
    };
}

fn collectArgs(arena: Allocator, args: std.process.Args) ![]const []const u8 {
    var it = try args.iterateAllocator(arena);
    defer it.deinit();
    _ = it.next(); // skip program name
    var list = std.ArrayList([]const u8).empty;
    while (it.next()) |a| try list.append(arena, try arena.dupe(u8, a));
    return list.toOwnedSlice(arena);
}

fn makeEnv(map: *std.process.Environ.Map) config.Env {
    const S = struct {
        fn get(ctx: *const anyopaque, name: []const u8) ?[]const u8 {
            const m: *const std.process.Environ.Map = @ptrCast(@alignCast(ctx));
            return m.get(name);
        }
    };
    return .{ .context = map, .func = S.get };
}

fn printOut(io: Io, bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}

fn printErr(io: Io, bytes: []const u8) !void {
    try std.Io.File.stderr().writeStreamingAll(io, bytes);
}

fn outf(ctx: Ctx, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(ctx.arena, fmt, args);
    try printOut(ctx.io, s);
}

test {
    std.testing.refAllDecls(@This());
}
