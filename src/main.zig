const std = @import("std");
const r4os = @import("r4os");
const r4std = @import("r4std");
const r4img = @import("r4img");
const app_fonts = @import("app_fonts");
const r4font = app_fonts.r4font;
const model = @import("model.zig");
const storage_layout = @import("storage_layout.zig");
const inline_svg = @import("inline_svg.zig");
const font_cache_store = @import("font_cache_store.zig");
const font_source_match = @import("font_source_match.zig");
const document_fonts = @import("document_fonts.zig");
const font_run_mask = @import("font_run_mask.zig");
const loading_view = @import("loading_view.zig");
const native_paint = @import("native_paint.zig");

const AppApi = struct {
    sys: r4os.r4sys.Context,
    desk: r4os.r4desk.Context,
    draw: r4os.r4draw.Context,
    font: r4font.Context,
    image: r4img.Context,
    dev: r4os.r4dev.Context,
    files: r4os.Files,
    web: ?r4os.WebTransport,

    fn init(r4_app: *r4os.App) ?AppApi {
        return .{
            .sys = r4_app.system(),
            .desk = r4_app.desktop() orelse return null,
            .draw = r4_app.drawing() orelse return null,
            .font = r4font.Context.init(r4_app.startContext()) orelse return null,
            .image = r4img.Context.init(r4_app.startContext()) orelse return null,
            .dev = r4_app.devicesLowLevel() orelse return null,
            .files = r4_app.files() orelse return null,
            .web = r4_app.web(),
        };
    }
};

const FocusTarget = enum(u8) {
    back,
    forward,
    stop,
    reload,
    diagnostics,
    address,
    go,
    document,
};

const face = r4os.gui.default_palette.face;
const client = r4os.gui.default_palette.client_bg;
const text = r4os.gui.default_palette.text;
const error_text: u32 = 0xA00000;
const status_bg: u32 = 0xD8D8D8;
const ctrl_d: u8 = 0x04;
const ctrl_l: u8 = 0x0C;
const response_capacity: usize = 256 * 1024;
const font_response_capacity: usize = @intCast(r4os.web_font_cache.default_max_object_bytes);
const font_raw_response_capacity: usize = font_response_capacity + 256 * 1024;
comptime {
    if (font_response_capacity != r4os.web_runtime.max_font_response_body_bytes)
        @compileError("Klickifax and WebRuntime font response limits must stay identical");
}
const font_cache_busy_retry_limit: usize = 16;
const tls_scratch_capacity: usize = r4os.app_web.tls_scratch_bytes;
const scrollbar_size: i32 = 17;
const scroll_unit: i32 = 16;
const max_fonts: usize = 65; // 64 installed R4F faces plus builtin
const font_support_cache_entries: usize = 512;
const local_document_capacity: usize = 8192;
const form_body_capacity: usize = 8 * 1024;
const script_step_budget: usize = 2 * 1024 * 1024;
const script_stop_check_interval: usize = 64;
const script_yield_interval: usize = 32;
// Page work is cooperatively sliced. A site may own many resources, timers or
// promise jobs, but it must never monopolize the single-vCPU desktop between
// GUI events.
const page_loop_sleep_ms: u64 = 10;
const page_settled_loop_sleep_ms: u64 = 50;
const page_runtime_jobs_per_slice: usize = 2;
const page_settled_jobs_per_slice: usize = 1;
const page_event_jobs_per_slice: usize = 4;
const page_resource_requests_per_slice: usize = 2;
const page_subdocument_requests_per_slice: usize = 1;
// A document can schedule the full web resource budget as images and can
// additionally contain inline SVG roots.  Keep those two bounded pools
// explicit instead of silently dropping the second half of a 64-image page.
const max_inline_svg_images: usize = 32;
const max_page_images: usize = r4os.web_resources.max_resources + max_inline_svg_images;
const max_svg_links_per_image: usize = 32;
const web_font_composite_max_width: usize = 1600;
const web_font_composite_band_height: usize = r4os.abi.gui_alpha8_max_height;
const web_font_composite_capacity: usize = web_font_composite_max_width * web_font_composite_band_height;

const PendingMouseMove = struct {
    const Move = struct { x: i32, y: i32 };

    pending: bool = false,
    x: i32 = 0,
    y: i32 = 0,

    fn note(self: *PendingMouseMove, x: i32, y: i32) void {
        self.* = .{ .pending = true, .x = x, .y = y };
    }

    fn take(self: *PendingMouseMove) ?Move {
        if (!self.pending) return null;
        const move = Move{ .x = self.x, .y = self.y };
        self.pending = false;
        return move;
    }
};

const SvgLink = struct {
    node: u16 = r4os.html.none,
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
};

const PageImage = struct {
    used: bool = false,
    inline_svg: bool = false,
    generation: u32 = 0,
    resource_id: u32 = 0,
    node: u16 = r4os.html.none,
    role: r4os.web_layout.ImageRole = .content,
    state: r4os.web_layout.ImageState = .missing,
    info: r4img.Info = .{ .format = .png, .width = 1, .height = 1, .channels = 4 },
    svg_source: []u8 = &.{},
    pixels: []u32 = &.{},
    rendered: []u32 = &.{},
    rendered_target_width: u32 = 0,
    rendered_target_height: u32 = 0,
    rendered_width: u32 = 0,
    rendered_height: u32 = 0,
    rendered_scale: u32 = 1,
    rendered_background: u32 = 0,
    rendered_style_hash: u64 = 0,
    rendered_radii: r4os.web_background.Radii = .{},
    rendered_failure_key: u64 = 0,
    svg_links: [max_svg_links_per_image]SvgLink = .{SvgLink{}} ** max_svg_links_per_image,
    svg_link_count: usize = 0,
    svg_link_overflow: bool = false,
};

const SvgGlyphContext = struct {
    app: *const App,
    font_id: u32,
};

const FontSupportCacheEntry = struct {
    valid: bool = false,
    font_id: u32 = 0,
    codepoint: u32 = 0,
    supported: bool = false,
};

const RenderedPageImage = struct {
    pixels: []const u32,
    width: u32,
    height: u32,
    scale: u32,
    radii: r4os.web_background.Radii = .{},
};

const LoadedMedia = enum(u8) {
    none,
    html,
    plain_text,
    unsupported,
};

const WebCookieContext = struct {
    app: *App,
    same_site: bool,
    enabled: bool = true,
    credentials: ?r4os.web_security.CredentialsMode = null,
    request_origin: ?r4os.web_security.Origin = null,
};

const WebRequestAuthorizationContext = struct {
    runtime: *r4os.web_runtime.WebRuntime,
    generation: u32,
    kind: r4os.web_runtime.RequestKind,
    mode: r4os.web_security.RequestMode,
};

const ExternalStyle = struct {
    offset: u32 = 0,
    len: u32 = 0,
    final_url: r4os.web_navigation.Url = .{},
};

const WebFontRuleKey = struct {
    source_section: u16 = 0,
    rule_digest: [32]u8 = .{0} ** 32,
    base_digest: [32]u8 = .{0} ** 32,
};

const TemporaryRunBounds = struct {
    left: i64 = std.math.maxInt(i64),
    top: i64 = std.math.maxInt(i64),
    right: i64 = std.math.minInt(i64),
    bottom: i64 = std.math.minInt(i64),

    fn include(self: *TemporaryRunBounds, x: i64, y: i64, width: u32, height: u32) void {
        if (width == 0 or height == 0) return;
        self.left = @min(self.left, x);
        self.top = @min(self.top, y);
        self.right = @max(self.right, saturatingAddI64(x, width));
        self.bottom = @max(self.bottom, saturatingAddI64(y, height));
    }

    fn hasPixels(self: TemporaryRunBounds) bool {
        return self.right > self.left and self.bottom > self.top;
    }
};

const TransportBuffers = struct {
    raw: [response_capacity]u8,
    body: [response_capacity]u8,
    scratch: [tls_scratch_capacity]u8,
    document: r4os.html.Document,
    view: r4os.html.PlainView,
    stylesheet: r4os.css.Stylesheet,
    font_registry: r4os.web_fonts.Registry,
    external_styles: [r4os.css.max_source_bytes]u8,
    external_styles_len: usize = 0,
    external_style_records: [r4os.web_resources.max_resources]ExternalStyle = .{ExternalStyle{}} ** r4os.web_resources.max_resources,
    external_style_count: usize = 0,
    layout: r4os.web_layout.Layout,
    interaction: r4os.web_forms.Interaction,
    local_document: [local_document_capacity]u8,
    rollback_browser: model.Browser,
};

pub fn r4_app_main(r4_app: *r4os.App) i32 {
    if (!r4std.init(r4_app.startContext())) return r4os.abi.err_no_group;
    var ctx = AppApi.init(r4_app) orelse return r4os.abi.err_no_group;
    if (hasArg(ctx.sys.argsRaw(), "/SELFTEST")) return runSelfTest(&ctx);
    const allocator = ctx.sys.allocator();
    var font_store = app_fonts.FaceStore.init(ctx.font, allocator, .{}) catch return -1;
    defer font_store.deinit();
    var loading_illustration = loading_view.Asset.load(&ctx.sys, &ctx.image, allocator);
    defer loading_illustration.deinit();
    const transport = allocator.create(TransportBuffers) catch return -1;
    ctx.sys.taskYield();
    defer allocator.destroy(transport);
    const page_runtime = allocator.create(r4os.web_runtime.WebRuntime) catch return -1;
    ctx.sys.taskYield();
    defer allocator.destroy(page_runtime);
    const browser_storage = allocator.create(r4os.web_security.BrowserStorage) catch return -1;
    ctx.sys.taskYield();
    defer allocator.destroy(browser_storage);
    const persistence_buffer = allocator.alloc(u8, r4os.web_security.max_persistence_bytes) catch return -1;
    ctx.sys.taskYield();
    defer allocator.free(persistence_buffer);
    const web_font_composite = allocator.alloc(u8, web_font_composite_capacity) catch return -1;
    ctx.sys.taskYield();
    defer allocator.free(web_font_composite);
    var app = App{
        .ctx = &ctx,
        .browser = model.Browser.init(),
        .transport = transport,
        .page_runtime = page_runtime,
        .browser_storage = browser_storage,
        .persistence_buffer = persistence_buffer,
        .document_fonts = document_fonts.Set.init(&font_store),
        .web_font_composite = web_font_composite,
        .loading_illustration = &loading_illustration,
    };
    defer app.document_fonts.deinit();
    defer if (app.web_state_initialized) app.page_runtime.deinit();
    defer app.deinitSubdocuments();
    defer app.deinitImages();
    defer app.deinitFontCache();
    const result = app.run();
    if (app.web_state_initialized) saveBrowserStorage(&ctx.files, browser_storage, persistence_buffer);
    return result;
}

const App = struct {
    ctx: *AppApi,
    browser: model.Browser,
    address: r4os.gui.TextField(model.url_capacity + 1) = .{},
    focus: FocusTarget = .address,
    pressed: ?FocusTarget = null,
    w: i32 = 720,
    h: i32 = 480,
    should_exit: bool = false,
    status: [160]u8 = .{0} ** 160,
    diagnostic: [1024]u8 = .{0} ** 1024,
    diagnostics_enabled: bool = false,
    title: [96]u8 = .{0} ** 96,
    transport: *TransportBuffers,
    page_runtime: *r4os.web_runtime.WebRuntime,
    browser_storage: *r4os.web_security.BrowserStorage,
    subdocuments: ?r4os.web_documents.Set = null,
    persistence_buffer: []u8,
    font_cache: ?font_cache_store.Store = null,
    font_cache_disabled: bool = false,
    font_cache_transaction: u64 = 1,
    font_cache_hits: usize = 0,
    font_cache_commits: usize = 0,
    font_cache_failures: usize = 0,
    document_fonts: document_fonts.Set,
    web_font_composite: []u8,
    loading_illustration: *loading_view.Asset,
    native_paint_stats: native_paint.Stats = .{},
    native_frame_active: bool = false,
    native_frame_app_failed: bool = false,
    native_frame_commits: u64 = 0,
    native_frame_failures: u64 = 0,
    native_shape_commands: u64 = 0,
    native_argb_commands: u64 = 0,
    native_resource_bytes: u64 = 0,
    native_resource_reuses: u64 = 0,
    native_resource_builds: u64 = 0,
    web_font_draw_error: i32 = 0,
    web_font_draw_commands: usize = 0,
    web_font_draw_failures: usize = 0,
    web_font_rule_keys: [r4os.web_fonts.max_source_sections]WebFontRuleKey = .{WebFontRuleKey{}} ** r4os.web_fonts.max_source_sections,
    web_font_rule_key_count: usize = 0,
    web_font_rule_generation: u32 = 0,
    web_font_rule_keys_valid: bool = false,
    web_font_viewport_dirty: bool = false,
    web_state_initialized: bool = false,
    document_generation: u32 = 0,
    runtime_active: bool = false,
    loaded_len: usize = 0,
    loaded_status: u16 = 0,
    loaded_secure: bool = false,
    loaded_html: bool = false,
    loaded_media: LoadedMedia = .none,
    layout_valid: bool = false,
    scroll_y: i32 = 0,
    hover_node: u16 = r4os.html.none,
    active_node: u16 = r4os.html.none,
    loading: bool = false,
    loading_view_active: bool = false,
    script_running: bool = false,
    script_checkpoints: usize = 0,
    resource_dirty: bool = false,
    stop_flag: r4os.abi.R4StopFlag = .{ .value = 0 },
    has_rollback: bool = false,
    font_infos: [max_fonts]r4os.abi.GuiFontInfo = .{r4os.abi.GuiFontInfo{}} ** max_fonts,
    font_count: usize = 0,
    font_support_cache: [font_support_cache_entries]FontSupportCacheEntry = .{FontSupportCacheEntry{}} ** font_support_cache_entries,
    font_support_cache_cursor: usize = 0,
    page_images: [max_page_images]PageImage = .{PageImage{}} ** max_page_images,
    image_loaded_count: usize = 0,
    image_fetch_failures: usize = 0,
    image_format_failures: usize = 0,
    image_decode_failures: usize = 0,
    image_memory_failures: usize = 0,
    image_limit_failures: usize = 0,
    image_other_failures: usize = 0,
    image_decode_last_bytes: usize = 0,
    image_draw_succeeded: bool = false,
    image_draw_error: i32 = 0,
    image_last_bytes: usize = 0,
    image_last_error: [32]u8 = .{0} ** 32,
    image_resource_event: r4os.web_runtime.ResourceEvent = .{
        .phase = .selected,
        .generation = 0,
        .resource_id = 0,
        .node = r4os.html.none,
        .kind = .image,
    },
    image_resource_event_valid: bool = false,
    image_resource_failure_event: r4os.web_runtime.ResourceEvent = .{
        .phase = .failed,
        .generation = 0,
        .resource_id = 0,
        .node = r4os.html.none,
        .kind = .image,
    },
    image_resource_failure_event_valid: bool = false,
    font_resource_event: r4os.web_runtime.ResourceEvent = .{
        .phase = .selected,
        .generation = 0,
        .resource_id = 0,
        .node = r4os.html.none,
        .kind = .font,
    },
    font_resource_event_valid: bool = false,
    font_resource_failure_event: r4os.web_runtime.ResourceEvent = .{
        .phase = .failed,
        .generation = 0,
        .resource_id = 0,
        .node = r4os.html.none,
        .kind = .font,
    },
    font_resource_failure_event_valid: bool = false,

    fn run(self: *App) i32 {
        if (self.ctx.desk.programWindowId() < 0) {
            self.ctx.sys.println("KLICKIFAX is a desktop GUI application.");
            self.ctx.sys.println("Please start it from Desktop or use /SELFTEST.");
            return 0;
        }
        _ = self.ctx.desk.guiSetMinSize(520, 320);
        self.address.set(self.browser.currentUrl().bytes());
        self.setStatus("Ready");
        self.updateTitle();
        self.address.selectAll();
        self.updateMetrics();
        self.loadFonts();
        self.render();
        self.initializeWebState();

        while (!self.ctx.sys.programShouldClose() and !self.should_exit) {
            var event: r4os.abi.GuiEvent = .{};
            var pending_mouse_move = PendingMouseMove{};
            while (self.ctx.desk.guiPollEvent(&event) > 0) {
                const kind: r4os.abi.GuiEventKind = @enumFromInt(event.kind);
                if (kind == .close) return 0;
                if (kind == .mouse_move) {
                    pending_mouse_move.note(event.x, event.y);
                    continue;
                }
                if (pending_mouse_move.take()) |move| self.handleMouseMove(move.x, move.y);
                switch (kind) {
                    .close, .mouse_move => unreachable,
                    .resize => {
                        const previous_w = self.w;
                        const previous_h = self.h;
                        self.updateMetrics();
                        if (!viewportSizeChanged(previous_w, previous_h, self.w, self.h)) continue;
                        self.updateWebViewport();
                        self.web_font_viewport_dirty = true;
                        self.refreshResponsiveWebFonts();
                        self.render();
                    },
                    .mouse_down => self.handleMouseDown(event.x, event.y),
                    .mouse_up => self.handleMouseUp(event.x, event.y),
                    .key_down => self.handleKey(r4os.gui.eventKey(event)),
                    .font_changed => {
                        self.loadFonts();
                        self.refreshInlineSvgImages();
                        self.web_font_rule_keys_valid = false;
                        self.web_font_viewport_dirty = true;
                        self.refreshResponsiveWebFonts();
                        self.render();
                    },
                    else => {},
                }
            }
            if (pending_mouse_move.take()) |move| self.handleMouseMove(move.x, move.y);
            if (self.web_font_viewport_dirty and !self.loading) {
                self.refreshResponsiveWebFonts();
                self.render();
            }
            self.pumpPageRuntime();
            const sleep_ms = pageLoopSleepMilliseconds(self.runtime_active, self.loading, self.page_runtime.resourcesSettled());
            self.ctx.sys.sleepTicks(self.ctx.sys.ticksFromMilliseconds(sleep_ms));
        }
        return 0;
    }

    fn initializeWebState(self: *App) void {
        const program_allocator = pageProgramAllocator(self);
        self.page_runtime.initialize(program_allocator);
        const environment = self.browserEnvironment();
        self.page_runtime.setEnvironment(environment);
        self.page_runtime.setExecutionPolicy(.{
            .context = self,
            .requested = scriptStopRequested,
            .check_interval = script_stop_check_interval,
        }, script_step_budget);
        self.page_runtime.setMonotonicClock(.{ .context = self, .now_milliseconds = pageMonotonicNow });
        self.page_runtime.setResourceHandler(.{ .context = self, .complete = completePageResource });
        self.page_runtime.setResourceObserver(.{ .context = self, .report = observePageResource });
        self.page_runtime.setFontSourceHandler(.{
            .context = self,
            .local_available = localWebFontAvailable,
            .cached_available = cachedWebFontAvailable,
        });
        self.page_runtime.setFrameLookup(.{ .context = self, .inspect = inspectFrame });
        self.subdocuments = r4os.web_documents.Set.init(self.ctx.sys.allocator(), program_allocator, self.browser_storage);
        if (self.subdocuments) |*documents| {
            documents.setEnvironment(environment);
            documents.setExecutionPolicy(.{
                .context = self,
                .requested = scriptStopRequested,
                .check_interval = script_stop_check_interval,
            }, script_step_budget);
            documents.setMonotonicClock(.{ .context = self, .now_milliseconds = pageMonotonicNow });
        }
        self.browser_storage.reset();
        self.ctx.sys.taskYield();
        ensureBrowserDataLayout(&self.ctx.files);
        self.initializeFontCache();
        loadBrowserStorage(&self.ctx.files, self.ctx.sys.allocator(), self.browser_storage, self.persistence_buffer);
        self.ctx.sys.taskYield();
        self.transport.document.reset();
        self.ctx.sys.taskYield();
        self.transport.view.reset();
        self.transport.stylesheet.reset();
        self.transport.font_registry.beginDocument(0);
        self.document_fonts.beginDocument(0);
        self.ctx.sys.taskYield();
        self.transport.layout.reset(.{ .width = 1, .height = 1 });
        self.transport.interaction.reset();
        self.ctx.sys.taskYield();
        self.web_state_initialized = true;
    }

    fn updateMetrics(self: *App) void {
        var info: r4os.abi.GuiWindowInfo = .{};
        _ = self.ctx.desk.guiWindowInfo(&info);
        const canvas = r4os.gui.Canvas.init(&self.ctx.draw, info);
        self.w = clampI32(canvas.w, 520, 1600);
        self.h = clampI32(canvas.h, 320, 1000);
    }

    fn browserEnvironment(self: *const App) r4os.web_runtime.Environment {
        const screen_width = self.ctx.draw.screenWidth();
        const screen_height = self.ctx.draw.screenHeight();
        return .{
            .viewport_width = @intCast(@max(self.w, 1)),
            .viewport_height = @intCast(@max(self.h, 1)),
            .screen_width = if (screen_width > 0) screen_width else @intCast(@max(self.w, 1)),
            .screen_height = if (screen_height > 0) screen_height else @intCast(@max(self.h, 1)),
            .online = self.ctx.web != null,
        };
    }

    fn updateWebViewport(self: *App) void {
        const width: u32 = @intCast(@max(self.w, 1));
        const height: u32 = @intCast(@max(self.h, 1));
        self.page_runtime.setViewport(width, height);
        if (self.subdocuments) |*documents| documents.setViewport(width, height);
    }

    fn render(self: *App) void {
        if (!self.ctx.draw.supportsGuiFrameContract()) {
            self.native_frame_failures +|= 1;
            self.setStatus("R4DRAW frame transactions are unavailable.");
            return;
        }
        const begin_result = self.ctx.draw.guiFrameBegin();
        if (begin_result < 0) {
            self.native_frame_failures +|= 1;
            self.setStatus("R4DRAW could not begin the document frame.");
            return;
        }
        var committed = false;
        self.native_frame_active = true;
        self.native_frame_app_failed = false;
        self.native_paint_stats = .{};
        defer {
            if (!committed) _ = self.ctx.draw.guiFrameCancel();
            self.native_frame_active = false;
        }
        const canvas = r4os.gui.Canvas.initSize(&self.ctx.draw, self.w, self.h);
        var scratch: [model.url_capacity + 1]u8 = .{0} ** (model.url_capacity + 1);
        self.address.focused = self.focus == .address;
        self.web_font_draw_error = 0;
        self.web_font_draw_commands = 0;

        _ = canvas.clear(face);
        _ = canvas.rect(.{ .x = 0, .y = 0, .w = self.w, .h = 72 }, face);
        self.drawButton(canvas, scratch[0..], .back, "Back", !self.browser.history.canBack());
        self.drawButton(canvas, scratch[0..], .forward, "Forward", !self.browser.history.canForward());
        self.drawButton(canvas, scratch[0..], .stop, "Stop", !self.isEnabled(.stop));
        self.drawButton(canvas, scratch[0..], .reload, "Reload", false);
        self.drawButton(canvas, scratch[0..], .diagnostics, "Trace", false);
        _ = canvas.label(.{
            .rect = .{ .x = 10, .y = 44, .w = 58, .h = 22 },
            .text = "Address:",
            .fg = text,
            .bg = face,
        }, scratch[0..]);
        _ = self.address.draw(canvas, self.addressRect(), scratch[0..]);
        self.drawButton(canvas, scratch[0..], .go, "Go", false);

        const document = self.documentRect();
        _ = canvas.rect(document, r4os.gui.default_palette.face_shadow);
        _ = canvas.rect(document.inset(1, 1), r4os.gui.default_palette.face_light);
        const page = document.inset(2, 2);
        _ = canvas.rect(page, client);
        const content_rect = self.documentContentRect(page);
        self.drawDocument(canvas, content_rect, scratch[0..]);
        _ = canvas.scrollbar(self.documentScrollbar(page), scratch[0..]);

        const status = self.statusRect();
        _ = canvas.rect(status, status_bg);
        _ = canvas.rect(.{ .x = status.x, .y = status.y, .w = status.w, .h = 1 }, r4os.gui.default_palette.face_shadow);
        _ = canvas.textClipped(status.x + 6, status.y + 5, status.w - 12, scratch[0..], self.visibleStatus(), text, status_bg);
        if (self.native_frame_app_failed or self.native_paint_stats.failures != 0) {
            self.native_frame_failures +|= 1;
            self.setStatus("Klickifax discarded an incomplete document frame.");
            return;
        }
        const commit_result = self.ctx.draw.guiFrameCommit();
        if (commit_result < 0) {
            self.native_frame_failures +|= 1;
            self.setStatus("R4DRAW kept the previous complete document frame.");
            return;
        }
        committed = true;
        self.native_frame_commits +|= 1;
        self.native_shape_commands +|= self.native_paint_stats.shape_commands;
        self.native_argb_commands +|= self.native_paint_stats.argb_commands;
        self.native_resource_bytes +|= self.native_paint_stats.resource_bytes;
    }

    fn drawDocument(self: *App, canvas: r4os.gui.Canvas, rect: r4os.gui.Rect, scratch: []u8) void {
        if (self.loading_view_active) {
            self.drawLoadingDocument(canvas, rect);
            return;
        }
        if (self.loaded_status != 0) {
            self.drawLoadedDocument(canvas, rect, scratch);
            return;
        }
        const page = self.browser.page;
        if (page.kind == .blank or page.kind == .remote_document) return;
        const heading_color = switch (page.kind) {
            .invalid_address, .explicit_error, .internal_not_found => error_text,
            else => text,
        };
        _ = canvas.textClipped(rect.x + 16, rect.y + 18, rect.w - 32, scratch, page.heading, heading_color, client);
        var y = rect.y + 48;
        for (page.lines) |line| {
            if (y + 16 >= rect.y + rect.h) break;
            _ = canvas.textClipped(rect.x + 16, y, rect.w - 32, scratch, line, text, client);
            y += 20;
        }
        if (y + 28 < rect.y + rect.h) {
            _ = canvas.textClipped(rect.x + 16, y + 12, rect.w - 32, scratch, self.browser.currentUrl().bytes(), r4os.gui.default_palette.disabled_text, client);
        }
    }

    fn drawLoadingDocument(self: *App, canvas: r4os.gui.Canvas, rect: r4os.gui.Rect) void {
        const frame = self.loading_illustration.frame(rect, client) orelse return;
        var y: u32 = 0;
        while (y < frame.placement.height) : (y += r4os.abi.gui_raster_max_height) {
            var x: u32 = 0;
            while (x < frame.placement.width) : (x += r4os.abi.gui_raster_max_width) {
                const tile = self.loading_illustration.tile(frame, x, y) orelse {
                    self.native_frame_app_failed = true;
                    return;
                };
                const result = canvas.raster(
                    frame.placement.x + @as(i32, @intCast(tile.x)),
                    frame.placement.y + @as(i32, @intCast(tile.y)),
                    tile.width,
                    tile.height,
                    1,
                    tile.pixels,
                );
                if (result <= 0) {
                    self.image_draw_error = result;
                    self.native_frame_app_failed = true;
                    return;
                }
            }
        }
    }

    fn drawLoadedDocument(self: *App, canvas: r4os.gui.Canvas, rect: r4os.gui.Rect, scratch: []u8) void {
        if (self.loaded_html) {
            self.drawHtmlDocument(canvas, rect, scratch);
            return;
        }
        if (self.loaded_media == .unsupported) {
            _ = canvas.textClipped(rect.x + 16, rect.y + 18, rect.w - 32, scratch, "Unsupported response type", error_text, client);
            _ = canvas.textClipped(rect.x + 16, rect.y + 46, rect.w - 32, scratch, "Klickifax did not interpret this payload as HTML.", text, client);
            return;
        }
        _ = canvas.textClipped(rect.x + 16, rect.y + 18, rect.w - 32, scratch, if (self.loaded_secure) "Secure HTTP response" else "HTTP response", text, client);
        var y = rect.y + 48;
        var offset: usize = 0;
        while (offset < self.loaded_len and y + 16 < rect.y + rect.h) {
            var out_len: usize = 0;
            while (offset < self.loaded_len and out_len < @min(scratch.len, 120)) : (offset += 1) {
                const ch = self.transport.body[offset];
                if (ch == '\n') {
                    offset += 1;
                    break;
                }
                if (ch == '\r') continue;
                scratch[out_len] = if (ch >= 0x20 and ch < 0x7F) ch else '.';
                out_len += 1;
            }
            if (out_len > 0) _ = canvas.textClipped(rect.x + 16, y, rect.w - 32, scratch[out_len..], scratch[0..out_len], text, client);
            y += 18;
        }
    }

    fn drawHtmlDocument(self: *App, canvas: r4os.gui.Canvas, rect: r4os.gui.Rect, scratch: []u8) void {
        if (!self.layout_valid) {
            _ = canvas.textClipped(rect.x + 12, rect.y + 12, rect.w - 24, scratch, "The document layout is unavailable.", error_text, client);
            return;
        }
        const paint_order = [_]r4os.web_layout.RenderKind{ .shadow, .background, .css_background, .border, .image, .text, .canvas };
        for (paint_order) |wanted| {
            var iteration: usize = 0;
            while (iteration < self.transport.layout.op_count) : (iteration += 1) {
                const index = if (wanted == .background or wanted == .css_background or wanted == .shadow)
                    self.transport.layout.op_count - 1 - iteration
                else
                    iteration;
                const op = self.transport.layout.ops[index];
                if (op.kind != wanted) continue;
                const scroll = if (op.fixed) 0 else self.scroll_y;
                const target = r4os.gui.Rect{
                    .x = rect.x + op.rect.x,
                    .y = rect.y + op.rect.y - scroll,
                    .w = op.rect.w,
                    .h = op.rect.h,
                };
                const paint_bounds = if (op.kind == .shadow) shadowBounds(target, op.shadow) else target;
                const clipped = clipRenderBounds(op, paint_bounds, rect, scroll);
                if (clipped.w <= 0 or clipped.h <= 0) continue;
                if (self.transport.interaction.controlForNodeConst(op.node) != null and op.kind != .shadow) continue;
                switch (op.kind) {
                    .shadow => _ = native_paint.appendRoundedShape(
                        &self.ctx.draw,
                        &self.native_paint_stats,
                        r4os.abi.gui_frame_command_kind_shadow,
                        target,
                        clipped,
                        op.radii,
                        .{},
                        0,
                        0,
                        op.shadow,
                    ),
                    .background => _ = native_paint.appendRoundedShape(
                        &self.ctx.draw,
                        &self.native_paint_stats,
                        r4os.abi.gui_frame_command_kind_rounded_rect,
                        target,
                        clipped,
                        op.radii,
                        .{},
                        0xFF000000 | (op.color & 0x00FFFFFF),
                        0,
                        null,
                    ),
                    .border => _ = native_paint.appendRoundedShape(
                        &self.ctx.draw,
                        &self.native_paint_stats,
                        r4os.abi.gui_frame_command_kind_rounded_rect,
                        target,
                        clipped,
                        op.radii,
                        op.border,
                        0,
                        0xFF000000 | (op.color & 0x00FFFFFF),
                        null,
                    ),
                    .css_background => {
                        _ = self.drawCssBackground(target, clipped, op, r4os.abi.gui_argb32_max_pixels);
                    },
                    .image => {
                        _ = self.drawPageImage(canvas, target, clipped, op, r4os.abi.gui_raster_max_pixels);
                    },
                    .text => {
                        if (target.x < clipped.x or target.y < clipped.y or target.y + target.h > clipped.y + clipped.h) continue;
                        const value = self.transport.layout.text(op);
                        if (value.len == 0) continue;
                        const viewport_width = clipped.x + clipped.w - target.x;
                        if (viewport_width <= 0) continue;
                        const measured_width = self.drawResolvedTextRun(canvas, clipped, target.x, target.y, viewport_width, scratch, value, .{
                            .id = op.font_id,
                            .height = op.font_height,
                            .line_height = op.font_line_height,
                            .baseline = op.font_baseline,
                            .max_advance = 1,
                        }, op.font_baseline, op.color, op.background);
                        if (op.underline) {
                            _ = canvas.rect(.{
                                .x = target.x,
                                .y = target.y + @min(target.h - 1, op.font_line_height),
                                .w = @min(viewport_width, measured_width),
                                .h = 1,
                            }, op.color);
                        }
                    },
                    .canvas => {
                        const surface = self.page_runtime.canvasView(op.node) orelse continue;
                        if (target.x < clipped.x or target.y < clipped.y or target.x + @as(i32, @intCast(surface.width)) > clipped.x + clipped.w or target.y + @as(i32, @intCast(surface.height)) > clipped.y + clipped.h) continue;
                        _ = canvas.raster(target.x, target.y, surface.width, surface.height, 1, surface.pixels);
                        for (surface.text_ops) |text_op| {
                            const text_x = target.x + text_op.x;
                            const text_y = target.y + text_op.y;
                            if (text_x < rect.x or text_y < rect.y or text_y >= rect.y + rect.h) continue;
                            _ = canvas.textClipped(text_x, text_y, target.x + target.w - text_x, scratch, text_op.text(), text_op.color, client);
                        }
                    },
                    .control => {},
                }
            }
        }
        self.drawFormControls(canvas, rect, scratch);
    }

    fn drawCssBackground(self: *App, target: r4os.gui.Rect, clipped: r4os.gui.Rect, op: r4os.web_layout.RenderOp, pixel_budget: usize) usize {
        const entry = self.pageImageForRole(op.node, .css_background) orelse return 0;
        if (entry.state != .ready or target.w <= 0 or target.h <= 0) return 0;
        const width: u32 = @intCast(target.w);
        const height: u32 = @intCast(target.h);
        const rendered = self.renderedCssBackground(entry, width, height, op, pixel_budget) orelse return 0;
        if (rendered.width == 0 or rendered.height == 0 or rendered.pixels.len == 0) return 0;

        const destination_width: u32 = @intCast(clipped.w);
        const destination_height: u32 = @intCast(clipped.h);
        const destination_count = std.math.mul(usize, destination_width, destination_height) catch {
            self.native_frame_app_failed = true;
            return 0;
        };
        if (destination_count == 0 or destination_count > r4os.abi.gui_argb32_max_pixels) {
            self.native_frame_app_failed = true;
            return 0;
        }

        const direct = rendered.scale == 1 and clipped.x == target.x and clipped.y == target.y and
            destination_width == rendered.width and destination_height == rendered.height;
        if (direct) {
            if (!native_paint.appendArgb32(&self.ctx.draw, &self.native_paint_stats, clipped.x, clipped.y, destination_width, destination_height, 1, rendered.pixels)) return 0;
            self.image_draw_succeeded = true;
            self.image_draw_error = 0;
            return destination_count;
        }

        const allocator = self.ctx.sys.allocator();
        const cropped = allocator.alloc(u32, destination_count) catch {
            self.noteImageFailure(.memory, "BackgroundFrameCrop", destination_count * @sizeOf(u32));
            self.native_frame_app_failed = true;
            return 0;
        };
        defer allocator.free(cropped);
        const scale: i64 = rendered.scale;
        var y: u32 = 0;
        while (y < destination_height) : (y += 1) {
            const document_y = @as(i64, clipped.y - target.y) + y;
            const source_y: usize = @intCast(@min(@as(i64, rendered.height - 1), @max(0, @divFloor(document_y, scale))));
            var x: u32 = 0;
            while (x < destination_width) : (x += 1) {
                const document_x = @as(i64, clipped.x - target.x) + x;
                const source_x: usize = @intCast(@min(@as(i64, rendered.width - 1), @max(0, @divFloor(document_x, scale))));
                cropped[@as(usize, y) * destination_width + x] = rendered.pixels[source_y * rendered.width + source_x];
            }
        }
        if (!native_paint.appendArgb32(&self.ctx.draw, &self.native_paint_stats, clipped.x, clipped.y, destination_width, destination_height, 1, cropped)) return 0;
        self.image_draw_succeeded = true;
        self.image_draw_error = 0;
        return destination_count;
    }

    fn renderedCssBackground(
        self: *App,
        entry: *PageImage,
        width: u32,
        height: u32,
        op: r4os.web_layout.RenderOp,
        pixel_budget: usize,
    ) ?RenderedPageImage {
        const style_hash = cssBackgroundStyleHash(op);
        const failure_key = cssBackgroundFailureKey(style_hash, width, height, 0, pixel_budget);
        const raster_plan = model.planRaster(width, height, pixel_budget) orelse {
            self.noteCssBackgroundFailure(entry, failure_key, .limit, "BackgroundRasterBudget", 0);
            return null;
        };
        if (entry.rendered.len > 0 and entry.rendered_target_width == width and entry.rendered_target_height == height and
            entry.rendered_width == raster_plan.width and entry.rendered_height == raster_plan.height and
            entry.rendered_scale == raster_plan.scale and entry.rendered_background == 0 and
            entry.rendered_style_hash == style_hash)
        {
            self.native_resource_reuses +|= 1;
            return .{
                .pixels = entry.rendered,
                .width = raster_plan.width,
                .height = raster_plan.height,
                .scale = raster_plan.scale,
                .radii = entry.rendered_radii,
            };
        }

        const allocator = self.ctx.sys.allocator();
        if (entry.rendered.len > 0) allocator.free(entry.rendered);
        entry.rendered = &.{};
        entry.rendered_target_width = 0;
        entry.rendered_target_height = 0;
        entry.rendered_width = 0;
        entry.rendered_height = 0;
        entry.rendered_scale = 1;
        entry.rendered_style_hash = 0;
        entry.rendered_radii = .{};

        const full_plan = r4os.web_background.buildPlan(.{
            .area = .{ .width = width, .height = height },
            .intrinsic = .{ .width = entry.info.width, .height = entry.info.height },
            .size = op.css_background.size,
            .position = op.css_background.position,
            .repeat = op.css_background.repeat,
            .radii = webBackgroundRadii(op.radii),
        }) catch |err| {
            self.noteWebBackgroundFailure(entry, failure_key, err);
            return null;
        };
        if (full_plan.tile.empty()) {
            entry.rendered_failure_key = 0;
            return .{ .pixels = &.{}, .width = 0, .height = 0, .scale = raster_plan.scale };
        }

        const scaled_tile = r4os.web_background.Size{
            .width = scaleExtent(full_plan.tile.width, raster_plan.scale),
            .height = scaleExtent(full_plan.tile.height, raster_plan.scale),
        };
        var compose_plan = r4os.web_background.Plan{
            .area = .{ .width = raster_plan.width, .height = raster_plan.height },
            .tile = scaled_tile,
            .origin_x = scalePosition(full_plan.origin_x, raster_plan.scale),
            .origin_y = scalePosition(full_plan.origin_y, raster_plan.scale),
            .repeat_x = full_plan.repeat_x,
            .repeat_y = full_plan.repeat_y,
            .radii = scaleBackgroundRadii(full_plan.radii, raster_plan.scale),
        };
        compose_plan.radii = r4os.web_background.normalizeRadii(compose_plan.area, compose_plan.radii);
        const output_count = std.math.mul(usize, raster_plan.width, raster_plan.height) catch {
            self.noteCssBackgroundFailure(entry, failure_key, .limit, "BackgroundPixelLimit", 0);
            return null;
        };
        const tile_count = std.math.mul(usize, scaled_tile.width, scaled_tile.height) catch {
            self.noteCssBackgroundFailure(entry, failure_key, .limit, "BackgroundTileLimit", 0);
            return null;
        };
        if (output_count == 0 or tile_count == 0 or output_count > r4img.max_pixels or tile_count > r4img.max_pixels) {
            self.noteCssBackgroundFailure(entry, failure_key, .limit, "BackgroundPixelLimit", 0);
            return null;
        }

        const rendered = allocator.alloc(u32, output_count) catch {
            self.noteCssBackgroundFailure(entry, failure_key, .memory, "BackgroundAllocation", output_count * @sizeOf(u32));
            return null;
        };
        var keep_rendered = false;
        defer if (!keep_rendered) allocator.free(rendered);
        @memset(rendered, 0);
        const tile_pixels = allocator.alloc(u32, tile_count) catch {
            self.noteCssBackgroundFailure(entry, failure_key, .memory, "BackgroundTileAllocation", tile_count * @sizeOf(u32));
            return null;
        };
        defer allocator.free(tile_pixels);

        if (entry.info.format == .svg) {
            if (entry.svg_source.len == 0) {
                self.noteCssBackgroundFailure(entry, failure_key, .other, "BackgroundSvgSource", 0);
                return null;
            }
            const target_info = r4img.Info{ .format = .svg, .width = scaled_tile.width, .height = scaled_tile.height, .channels = 4 };
            const scratch_size = self.ctx.image.scratchBytesFor(target_info, entry.svg_source.len) catch |err| {
                self.noteCssBackgroundR4ImgFailure(entry, failure_key, err, entry.svg_source.len);
                return null;
            };
            const scratch = allocator.alignedAlloc(u8, .fromByteUnits(16), scratch_size) catch {
                self.noteCssBackgroundFailure(entry, failure_key, .memory, "BackgroundScratchAllocation", scratch_size);
                return null;
            };
            defer allocator.free(scratch);
            var glyph_context = SvgGlyphContext{ .app = self, .font_id = r4os.abi.gui_font_builtin_id };
            _ = self.ctx.image.decodeSvgAt(
                entry.svg_source,
                "image/svg+xml",
                tile_pixels,
                scratch,
                scaled_tile.width,
                scaled_tile.height,
                .{ .glyphs = self.svgGlyphProvider(&glyph_context) },
            ) catch |err| {
                self.noteCssBackgroundR4ImgFailure(entry, failure_key, err, entry.svg_source.len);
                return null;
            };
        } else if (!scaleArgbTile(entry, tile_pixels, scaled_tile.width, scaled_tile.height)) {
            self.noteCssBackgroundFailure(entry, failure_key, .other, "BackgroundSourcePixels", entry.pixels.len * @sizeOf(u32));
            return null;
        }

        _ = r4os.web_background.composite(
            compose_plan,
            .{
                .pixels = tile_pixels,
                .width = scaled_tile.width,
                .height = scaled_tile.height,
                .stride = scaled_tile.width,
            },
            .{
                .pixels = rendered,
                .width = raster_plan.width,
                .height = raster_plan.height,
                .stride = raster_plan.width,
            },
        ) catch |err| {
            self.noteWebBackgroundFailure(entry, failure_key, err);
            return null;
        };

        entry.rendered = rendered;
        entry.rendered_target_width = width;
        entry.rendered_target_height = height;
        entry.rendered_width = raster_plan.width;
        entry.rendered_height = raster_plan.height;
        entry.rendered_scale = raster_plan.scale;
        entry.rendered_background = 0;
        entry.rendered_style_hash = style_hash;
        entry.rendered_radii = compose_plan.radii;
        entry.rendered_failure_key = 0;
        self.native_resource_builds +|= 1;
        keep_rendered = true;
        return .{
            .pixels = entry.rendered,
            .width = raster_plan.width,
            .height = raster_plan.height,
            .scale = raster_plan.scale,
            .radii = compose_plan.radii,
        };
    }

    fn noteWebBackgroundFailure(self: *App, entry: *PageImage, key: u64, err: r4os.web_background.Error) void {
        const class: ImageFailureClass = switch (err) {
            error.InvalidValue => .other,
            error.TooLarge, error.InvalidStride, error.BufferTooSmall, error.DimensionMismatch => .limit,
        };
        self.noteCssBackgroundFailure(entry, key, class, @errorName(err), 0);
    }

    fn noteCssBackgroundR4ImgFailure(self: *App, entry: *PageImage, key: u64, err: r4img.Error, bytes: usize) void {
        const class: ImageFailureClass = switch (err) {
            error.UnsupportedFormat, error.UnsupportedFeature => .format,
            error.DecodeFailed => .decode,
            error.TooLarge, error.InvalidDimensions, error.PixelBufferTooSmall, error.ScratchBufferTooSmall => .limit,
            error.Empty, error.InvalidImage, error.InvalidArgument => .other,
        };
        self.noteCssBackgroundFailure(entry, key, class, @errorName(err), bytes);
    }

    fn noteCssBackgroundFailure(self: *App, entry: *PageImage, key: u64, class: ImageFailureClass, name: []const u8, bytes: usize) void {
        if (entry.rendered_failure_key == key) return;
        entry.rendered_failure_key = key;
        self.noteImageFailure(class, name, bytes);
    }

    fn drawPageImage(self: *App, canvas: r4os.gui.Canvas, target: r4os.gui.Rect, clipped: r4os.gui.Rect, op: r4os.web_layout.RenderOp, pixel_budget: usize) usize {
        const entry = self.pageImageForRole(op.node, op.image_role) orelse {
            drawImagePlaceholder(canvas, target, clipped, op.background);
            return 0;
        };
        if (entry.state != .ready or target.w <= 0 or target.h <= 0) {
            drawImagePlaceholder(canvas, target, clipped, op.background);
            return 0;
        }
        const width: u32 = @intCast(target.w);
        const height: u32 = @intCast(target.h);
        const rendered = self.renderedPageImage(entry, width, height, op.background, pixel_budget) orelse {
            drawImagePlaceholder(canvas, target, clipped, op.background);
            return 0;
        };
        _ = canvas.rect(clipped, op.background);
        const output_width: i32 = @intCast(rendered.width * rendered.scale);
        const output_height: i32 = @intCast(rendered.height * rendered.scale);
        if (clipped.x != target.x or clipped.w < output_width) return 0;
        const clip_top = @max(0, clipped.y - target.y);
        const clip_bottom = @min(output_height, clipped.y + clipped.h - target.y);
        const scale_i32: i32 = @intCast(rendered.scale);
        const first_row: usize = @intCast(@divTrunc(clip_top + scale_i32 - 1, scale_i32));
        const end_row: usize = @intCast(@divTrunc(clip_bottom, scale_i32));
        if (end_row <= first_row) return 0;
        const source_width: usize = @intCast(rendered.width);
        const start = first_row * source_width;
        const count = (end_row - first_row) * source_width;
        const appended = native_paint.appendXrgb32(
            &self.ctx.draw,
            &self.native_paint_stats,
            target.x,
            target.y + @as(i32, @intCast(first_row)) * scale_i32,
            rendered.width,
            @intCast(end_row - first_row),
            rendered.scale,
            rendered.pixels[start .. start + count],
        );
        if (!appended) {
            self.image_draw_error = self.native_paint_stats.last_error;
            self.native_frame_app_failed = true;
            return 0;
        }
        self.image_draw_succeeded = true;
        self.image_draw_error = 0;
        return count;
    }

    fn renderedPageImage(self: *App, entry: *PageImage, width: u32, height: u32, background: u32, pixel_budget: usize) ?RenderedPageImage {
        const plan = model.planRaster(width, height, pixel_budget) orelse return null;
        if (entry.rendered.len > 0 and entry.rendered_target_width == width and entry.rendered_target_height == height and
            entry.rendered_width == plan.width and entry.rendered_height == plan.height and entry.rendered_scale == plan.scale and
            entry.rendered_background == background)
        {
            return .{ .pixels = entry.rendered, .width = plan.width, .height = plan.height, .scale = plan.scale };
        }
        const allocator = self.ctx.sys.allocator();
        if (entry.rendered.len > 0) allocator.free(entry.rendered);
        entry.rendered = &.{};
        entry.rendered_target_width = 0;
        entry.rendered_target_height = 0;
        entry.rendered_width = 0;
        entry.rendered_height = 0;
        entry.rendered_scale = 1;
        const count = std.math.mul(usize, plan.width, plan.height) catch return null;
        if (count == 0 or count > r4img.max_pixels) return null;
        const rendered = allocator.alloc(u32, count) catch return null;
        if (entry.info.format == .svg and entry.svg_source.len > 0) {
            const target_info = r4img.Info{ .format = .svg, .width = plan.width, .height = plan.height, .channels = 4 };
            const scratch_size = self.ctx.image.scratchBytesFor(target_info, entry.svg_source.len) catch |err| {
                allocator.free(rendered);
                entry.state = .failed;
                self.noteR4ImgFailure(err, entry.svg_source.len);
                return null;
            };
            const scratch = allocator.alignedAlloc(u8, .fromByteUnits(16), scratch_size) catch {
                allocator.free(rendered);
                entry.state = .failed;
                self.noteImageFailure(.memory, "RenderScratchAllocation", entry.svg_source.len);
                return null;
            };
            defer allocator.free(scratch);
            var glyph_context = SvgGlyphContext{ .app = self, .font_id = r4os.abi.gui_font_builtin_id };
            _ = self.ctx.image.decodeSvgAt(
                entry.svg_source,
                "image/svg+xml",
                rendered,
                scratch,
                plan.width,
                plan.height,
                .{
                    .glyphs = self.svgGlyphProvider(&glyph_context),
                    .background = background,
                },
            ) catch |err| {
                allocator.free(rendered);
                entry.state = .failed;
                self.noteR4ImgFailure(err, entry.svg_source.len);
                return null;
            };
        } else {
            const image = r4img.Image{ .info = entry.info, .pixels = entry.pixels };
            _ = self.ctx.image.scaleComposite(image, rendered, plan.width, plan.height, background) catch |err| {
                allocator.free(rendered);
                entry.state = .failed;
                self.noteR4ImgFailure(err, entry.pixels.len * @sizeOf(u32));
                return null;
            };
        }
        // The image has already been composited onto the CSS background.
        // Frame XRGB resources reserve their high byte and validate it as 0.
        for (rendered) |*pixel| pixel.* &= 0x00FF_FFFF;
        entry.rendered = rendered;
        entry.rendered_target_width = width;
        entry.rendered_target_height = height;
        entry.rendered_width = plan.width;
        entry.rendered_height = plan.height;
        entry.rendered_scale = plan.scale;
        entry.rendered_background = background;
        return .{ .pixels = entry.rendered, .width = plan.width, .height = plan.height, .scale = plan.scale };
    }

    fn drawFormControls(self: *App, canvas: r4os.gui.Canvas, rect: r4os.gui.Rect, scratch: []u8) void {
        var index: usize = 0;
        while (index < self.transport.interaction.control_count) : (index += 1) {
            const control = &self.transport.interaction.controls[index];
            if (control.kind == .hidden) continue;
            const control_rect = self.controlRect(control.node, rect) orelse continue;
            const visible_rect = self.controlVisibleRect(control.node, rect) orelse continue;
            if (visible_rect.w <= 0 or visible_rect.h <= 0) continue;
            const fully_visible = visible_rect.x == control_rect.x and visible_rect.y == control_rect.y and
                visible_rect.w == control_rect.w and visible_rect.h == control_rect.h;
            const focused = self.transport.interaction.focused_node == control.node;
            if (self.controlRenderOp(control.node)) |op| {
                switch (control.kind) {
                    .text, .search, .select, .submit, .button => {
                        const scroll = if (op.fixed) 0 else self.scroll_y;
                        self.drawCssControl(canvas, clipRenderViewport(op, rect, scroll), control_rect, scratch, control, op, focused);
                        continue;
                    },
                    else => {},
                }
            }
            if (!fully_visible) continue;
            switch (control.kind) {
                .text, .search => _ = r4os.gui.drawTextFieldEx(
                    canvas,
                    control_rect,
                    scratch,
                    control.value(),
                    control.cursor,
                    .{ .start = control.cursor, .end = control.cursor },
                    focused,
                    control.disabled,
                    r4os.gui.default_palette,
                ),
                .select, .submit, .button => _ = canvas.button(.{
                    .rect = control_rect,
                    .text = if (control.displayValue().len > 0) control.displayValue() else "Button",
                    .state = if (control.disabled) .disabled else if (self.active_node == control.node) .pressed else .normal,
                    .focused = focused,
                    .is_default = control.kind == .submit,
                }, scratch),
                .checkbox => _ = canvas.checkbox(.{
                    .rect = control_rect,
                    .text = control.value(),
                    .checked = control.checked,
                    .disabled = control.disabled,
                    .focused = focused,
                }, scratch),
                .radio => _ = canvas.radioButton(.{
                    .rect = control_rect,
                    .text = control.value(),
                    .selected = control.checked,
                    .disabled = control.disabled,
                    .focused = focused,
                }, scratch),
                .hidden => {},
            }
        }
    }

    fn drawCssControl(
        self: *App,
        canvas: r4os.gui.Canvas,
        viewport: r4os.gui.Rect,
        control_rect: r4os.gui.Rect,
        scratch: []u8,
        control: *const r4os.web_forms.Control,
        op: r4os.web_layout.RenderOp,
        focused: bool,
    ) void {
        const clipped = intersectRect(control_rect, viewport);
        if (clipped.w <= 0 or clipped.h <= 0) return;
        const has_border = op.border.top > 0 or op.border.right > 0 or op.border.bottom > 0 or op.border.left > 0;
        _ = native_paint.appendRoundedShape(
            &self.ctx.draw,
            &self.native_paint_stats,
            r4os.abi.gui_frame_command_kind_rounded_rect,
            control_rect,
            clipped,
            op.radii,
            op.border,
            0xFF000000 | (op.background & 0x00FFFFFF),
            if (has_border) 0xFF000000 | (op.border_color & 0x00FFFFFF) else 0,
            null,
        );

        const content = r4os.gui.Rect{
            .x = control_rect.x + op.border.left + op.padding.left,
            .y = control_rect.y + op.border.top + op.padding.top,
            .w = @max(1, control_rect.w - op.border.left - op.border.right - op.padding.left - op.padding.right),
            .h = @max(1, control_rect.h - op.border.top - op.border.bottom - op.padding.top - op.padding.bottom),
        };
        const raw_value = switch (control.kind) {
            .submit, .button, .select => control.displayValue(),
            else => control.value(),
        };
        const placeholder = raw_value.len == 0 and (control.kind == .text or control.kind == .search);
        const value = if (placeholder)
            self.transport.document.attribute(control.node, "placeholder") orelse ""
        else if (raw_value.len > 0)
            raw_value
        else
            "Button";
        if (value.len == 0) {
            if (focused and (control.kind == .text or control.kind == .search)) {
                const cursor_rect = intersectRect(.{ .x = content.x, .y = content.y, .w = 1, .h = content.h }, viewport);
                if (cursor_rect.w > 0 and cursor_rect.h > 0) _ = canvas.rect(cursor_rect, op.color);
            }
            return;
        }

        const measured = self.transport.layout.measureStyledText(&cssStyleForRenderOp(op), value);
        const measured_width = measured.width;
        const text_x = switch (op.text_align) {
            .left => content.x,
            .center => content.x + @max(0, @divTrunc(content.w - measured_width, 2)),
            .right => content.x + @max(0, content.w - measured_width),
        };
        const text_line_height = @max(1, measured.line_height);
        const text_y = content.y + @max(0, @divTrunc(content.h - text_line_height, 2));
        if (text_x < viewport.x or text_y < viewport.y or text_y + text_line_height > viewport.y + viewport.h) return;
        const normal_color = if (control.disabled) blendRgb(op.color, op.background, 112) else op.color;
        const text_color = if (placeholder) blendRgb(normal_color, op.background, 128) else normal_color;
        const text_width = @min(content.x + content.w, viewport.x + viewport.w) - text_x;
        if (text_width <= 0) return;
        self.drawResolvedTextRuns(canvas, viewport, text_x, text_y, text_width, scratch, value, op, text_color);

        if (focused and !control.disabled and !placeholder and (control.kind == .text or control.kind == .search)) {
            const cursor = @min(control.cursor, value.len);
            const prefix_width = self.transport.layout.measureStyledText(&cssStyleForRenderOp(op), value[0..cursor]).width;
            const cursor_x = @min(content.x + content.w - 1, text_x + prefix_width);
            const cursor_rect = intersectRect(.{ .x = cursor_x, .y = content.y, .w = 1, .h = content.h }, viewport);
            if (cursor_rect.w > 0 and cursor_rect.h > 0) _ = canvas.rect(cursor_rect, op.color);
        }
    }

    fn drawResolvedTextRuns(
        self: *App,
        canvas: r4os.gui.Canvas,
        viewport: r4os.gui.Rect,
        x: i32,
        y: i32,
        width: i32,
        scratch: []u8,
        value: []const u8,
        op: r4os.web_layout.RenderOp,
        color: u32,
    ) void {
        if (value.len == 0 or width <= 0) return;
        const style = cssStyleForRenderOp(op);
        const metrics = self.transport.layout.measureStyledText(&style, value);
        const catalog = self.fontCatalog();
        var cursor: usize = 0;
        var run_start: usize = 0;
        var draw_x = x;
        var current = self.document_fonts.resolve(&self.transport.font_registry, catalog, style.font_family, style.font_size, style.font_weight, style.italic, decodeUtf8Codepoint(value, 0));
        while (cursor < value.len) {
            const next_face = self.document_fonts.resolve(&self.transport.font_registry, catalog, style.font_family, style.font_size, style.font_weight, style.italic, decodeUtf8Codepoint(value, cursor));
            if (cursor > run_start and next_face.id != current.id) {
                draw_x += self.drawResolvedTextRun(canvas, viewport, draw_x, y, width - (draw_x - x), scratch, value[run_start..cursor], current, metrics.baseline, color, op.background);
                run_start = cursor;
                current = next_face;
            }
            cursor += utf8SequenceLength(value, cursor);
        }
        if (run_start < value.len and draw_x < x + width) {
            _ = self.drawResolvedTextRun(canvas, viewport, draw_x, y, width - (draw_x - x), scratch, value[run_start..], current, metrics.baseline, color, op.background);
        }
    }

    fn drawResolvedTextRun(
        self: *App,
        canvas: r4os.gui.Canvas,
        viewport: r4os.gui.Rect,
        x: i32,
        y: i32,
        width: i32,
        scratch: []u8,
        value: []const u8,
        face_info: r4os.web_layout.FontFace,
        line_baseline: i32,
        color: u32,
        background: u32,
    ) i32 {
        if (value.len == 0 or width <= 0 or scratch.len < 2) return 0;
        if (document_fonts.isTemporaryId(face_info.id)) {
            return self.drawTemporaryTextRun(canvas, viewport, x, y, width, value, face_info, line_baseline, color);
        }
        const font_canvas = canvas.withFontId(face_info.id);
        const run_y = y + @max(0, line_baseline - face_info.baseline);
        var total_width: i32 = 0;
        var cursor: usize = 0;
        while (cursor < value.len) {
            const end = utf8ChunkEnd(value, cursor, scratch.len - 1);
            if (end <= cursor) break;
            const chunk = value[cursor..end];
            setZ(scratch, chunk);
            const chunk_width = font_canvas.textWidthZ(@ptrCast(scratch.ptr));
            const chunk_x = x + total_width;
            const visible_width = @min(width - total_width, viewport.x + viewport.w - chunk_x);
            const vertically_visible = run_y >= viewport.y and run_y + face_info.line_height <= viewport.y + viewport.h;
            if (chunk_x >= viewport.x and visible_width > 0 and vertically_visible) {
                if (chunk_width <= visible_width) {
                    _ = font_canvas.text(chunk_x, run_y, @ptrCast(scratch.ptr), color, background);
                } else {
                    _ = font_canvas.textClipped(chunk_x, run_y, visible_width, scratch, chunk, color, background);
                }
            }
            total_width = std.math.add(i32, total_width, chunk_width) catch std.math.maxInt(i32);
            cursor = end;
        }
        return total_width;
    }

    fn drawTemporaryTextRun(
        self: *App,
        canvas: r4os.gui.Canvas,
        viewport: r4os.gui.Rect,
        x: i32,
        y: i32,
        width: i32,
        value: []const u8,
        face_info: r4os.web_layout.FontFace,
        line_baseline: i32,
        color: u32,
    ) i32 {
        if (value.len == 0 or width <= 0) return 0;
        const baseline_y = y + @max(0, line_baseline);
        var bounds = TemporaryRunBounds{};
        const advance_26_6 = self.walkTemporaryTextGlyphs(value, face_info.id, x, baseline_y, &bounds, null);
        const total_width = pixelsCeil26_6(advance_26_6);
        if (!bounds.hasPixels() or self.web_font_draw_error < 0) return total_width;

        const viewport_left: i64 = viewport.x;
        const viewport_top: i64 = viewport.y;
        const viewport_right = viewport_left + @as(i64, viewport.w);
        const viewport_bottom = viewport_top + @as(i64, viewport.h);
        const run_left: i64 = x;
        const run_right = run_left + @as(i64, width);
        const left = @max(@max(viewport_left, run_left), bounds.left);
        const top = @max(viewport_top, bounds.top);
        const right = @min(@min(viewport_right, run_right), bounds.right);
        const bottom = @min(viewport_bottom, bounds.bottom);
        if (right <= left or bottom <= top) return total_width;

        const mask_width: u32 = @intCast(right - left);
        if (mask_width == 0 or mask_width > web_font_composite_max_width) {
            self.noteWebFontDrawError(-2);
            return total_width;
        }
        var band_top = top;
        while (band_top < bottom and self.web_font_draw_error >= 0) {
            const band_height: u32 = @intCast(@min(
                @as(i64, r4os.abi.gui_alpha8_max_height),
                bottom - band_top,
            ));
            var mask = font_run_mask.Mask.init(
                self.web_font_composite,
                clampI64ToI32(left),
                clampI64ToI32(band_top),
                mask_width,
                band_height,
            ) catch {
                self.noteWebFontDrawError(-2);
                break;
            };
            _ = self.walkTemporaryTextGlyphs(value, face_info.id, x, baseline_y, null, &mask);

            var strips = mask.strips(r4os.abi.gui_alpha8_max_width);
            while (strips.next()) |strip| {
                const result = canvas.blendAlpha8(
                    strip.x,
                    strip.y,
                    strip.width,
                    strip.height,
                    strip.stride,
                    color,
                    strip.alpha,
                );
                if (result < 0) {
                    self.noteWebFontDrawError(result);
                    break;
                }
                self.web_font_draw_commands += 1;
            }
            band_top += band_height;
        }
        return total_width;
    }

    fn walkTemporaryTextGlyphs(
        self: *App,
        value: []const u8,
        render_id: u32,
        x: i32,
        baseline_y: i32,
        bounds: ?*TemporaryRunBounds,
        mask: ?*font_run_mask.Mask,
    ) i64 {
        const start_pen: i64 = @as(i64, x) * 64;
        var pen = start_pen;
        var previous: ?u32 = null;
        var cursor: usize = 0;
        while (cursor < value.len) {
            const codepoint = decodeUtf8Codepoint(value, cursor);
            cursor += utf8SequenceLength(value, cursor);
            const glyph_index = self.document_fonts.glyphIndex(render_id, codepoint) orelse {
                previous = null;
                continue;
            };
            if (previous) |left_glyph| {
                pen = saturatingAddI64(pen, self.document_fonts.kerning(render_id, left_glyph, glyph_index)[0]);
            }
            const raster = self.document_fonts.rasterizeCached(render_id, glyph_index) orelse {
                previous = glyph_index;
                continue;
            };
            const glyph_x = saturatingAddI64(@divFloor(pen, 64), raster.left);
            const glyph_y = saturatingAddI64(baseline_y, -@as(i64, raster.top));
            if (bounds) |target| target.include(glyph_x, glyph_y, raster.width, raster.height);
            if (mask) |target| _ = target.blend(glyph_x, glyph_y, raster.width, raster.height, raster.width, raster.alpha);
            pen = saturatingAddI64(pen, raster.advance_x_26_6);
            previous = glyph_index;
        }
        return saturatingAddI64(pen, -start_pen);
    }

    fn noteWebFontDrawError(self: *App, result: i32) void {
        self.web_font_draw_failures += 1;
        if (self.web_font_draw_error < 0) return;
        self.web_font_draw_error = result;
        self.setStatus(switch (result) {
            -4 => "Web font drawing reached the GUI command limit.",
            -5 => "Web font drawing reached the GUI raster limit.",
            else => "Web font drawing failed in the R4DRAW Alpha8 path.",
        });
    }

    fn drawButton(self: *const App, canvas: r4os.gui.Canvas, scratch: []u8, target: FocusTarget, label: []const u8, disabled: bool) void {
        _ = canvas.button(.{
            .rect = self.buttonRect(target),
            .text = label,
            .state = if (disabled) .disabled else if (self.pressed == target) .pressed else .normal,
            .focused = self.focus == target and !disabled,
            .is_default = target == .go,
        }, scratch);
    }

    fn handleMouseDown(self: *App, x: i32, y: i32) void {
        const page = self.documentRect().inset(2, 2);
        const scrollbar = self.documentScrollbar(page);
        const scrollbar_part = scrollbar.partAt(x, y);
        if (scrollbar_part != .none) {
            self.focus = .document;
            self.pressed = null;
            self.stepDocumentScrollbar(scrollbar_part);
            self.render();
            return;
        }
        if (self.documentContentRect(page).contains(x, y)) {
            self.focus = .document;
            self.pressed = null;
            const node = self.documentNodeAt(x, y);
            if (node != r4os.html.none) {
                self.transport.interaction.focus(node);
                self.active_node = node;
                self.transport.interaction.click(node);
                self.reflowDocument();
            } else {
                self.transport.interaction.focus(r4os.html.none);
                self.active_node = r4os.html.none;
            }
            self.render();
            return;
        }
        if (self.addressRect().contains(x, y)) {
            self.focus = .address;
            self.pressed = null;
            self.render();
            return;
        }
        for ([_]FocusTarget{ .back, .forward, .stop, .reload, .diagnostics, .go }) |target| {
            if (!self.isEnabled(target)) continue;
            if (self.buttonRect(target).contains(x, y)) {
                self.focus = target;
                self.pressed = target;
                self.render();
                return;
            }
        }
    }

    fn handleMouseUp(self: *App, x: i32, y: i32) void {
        if (self.active_node != r4os.html.none) {
            const node = self.active_node;
            self.active_node = r4os.html.none;
            if (self.documentNodeAt(x, y) == node) self.activateDocumentNode(node);
            self.reflowDocument();
            if (!self.should_exit) self.render();
            return;
        }
        const target = self.pressed orelse return;
        self.pressed = null;
        if (self.isEnabled(target) and self.buttonRect(target).contains(x, y)) self.activate(target);
        if (!self.should_exit) self.render();
    }

    fn handleMouseMove(self: *App, x: i32, y: i32) void {
        const node = self.documentNodeAt(x, y);
        if (node == self.hover_node) return;
        self.hover_node = node;
        self.reflowDocument();
        self.render();
    }

    fn handleKey(self: *App, key: u8) void {
        if (key == r4os.gui.Key.escape) {
            if (self.loading_view_active or self.loading or self.script_running) {
                self.requestStop();
                return;
            }
            self.should_exit = true;
            return;
        }
        if (key == ctrl_l) {
            self.focus = .address;
            self.address.selectAll();
            self.setStatus("Enter an address and press Enter.");
            self.render();
            return;
        }
        if (key == ctrl_d) {
            self.toggleDiagnostics();
            self.render();
            return;
        }
        if (key == r4os.gui.Key.tab or key == r4os.gui.Key.shift_tab) {
            if (self.focus == .document and self.loaded_html and
                self.transport.interaction.focusNext(key == r4os.gui.Key.shift_tab))
            {
                self.reflowDocument();
                self.render();
                return;
            }
            self.advanceFocus(key == r4os.gui.Key.shift_tab);
            self.render();
            return;
        }
        if (self.focus == .address) {
            if (key == r4os.gui.Key.enter) {
                self.navigate();
            } else {
                _ = self.address.handleClipboardKey(&self.ctx.desk, key);
            }
            self.render();
            return;
        }
        if (self.focus == .document) {
            if (self.handleFormKey(key)) {
                if (!self.should_exit) self.render();
                return;
            }
            if (self.handleDocumentKey(key)) self.render();
            return;
        }
        if ((key == r4os.gui.Key.enter or key == ' ') and self.isEnabled(self.focus)) {
            self.activate(self.focus);
            if (!self.should_exit) self.render();
        }
    }

    fn activate(self: *App, target: FocusTarget) void {
        switch (target) {
            .back => {
                self.saveRollback();
                if (self.browser.back()) self.loadCurrent("Back") else self.has_rollback = false;
            },
            .forward => {
                self.saveRollback();
                if (self.browser.forward()) self.loadCurrent("Forward") else self.has_rollback = false;
            },
            .stop => if (self.loading_view_active or self.loading or self.script_running) self.requestStop() else self.setStatus("No page load is active."),
            .reload => {
                self.saveRollback();
                self.browser.reload();
                self.loadCurrent("Reloaded");
            },
            .diagnostics => self.toggleDiagnostics(),
            .address, .go => self.navigate(),
            .document => {},
        }
    }

    fn navigate(self: *App) void {
        self.saveRollback();
        if (self.browser.navigate(self.address.value())) {
            self.loadCurrent("Done");
        } else {
            self.has_rollback = false;
            self.updateTitle();
            self.clearLoaded();
            self.setStatus("Invalid or unsupported address.");
        }
    }

    fn loadCurrent(self: *App, local_status: []const u8) void {
        self.address.set(self.browser.currentUrl().bytes());
        self.setStatus(local_status);
        self.updateTitle();
        switch (self.browser.page.kind) {
            .remote_document => self.fetchCurrent(),
            .search, .search_results => self.loadLocalDocument(),
            else => {
                self.clearLoaded();
                self.has_rollback = false;
                self.updateTitle();
            },
        }
    }

    fn fetchCurrent(self: *App) void {
        self.fetchCurrentRequest(.get, "", "", "");
    }

    fn fetchCurrentRequest(self: *App, method: r4os.http.Method, request_content_type: []const u8, body: []const u8, origin: []const u8) void {
        @atomicStore(u32, &self.stop_flag.value, 0, .release);
        self.loading_view_active = true;
        defer {
            self.loading_view_active = false;
            self.render();
        }
        self.loading = true;
        self.setStatus("Loading...");
        self.render();
        if (self.ctx.web) |*web| {
            var cookie_context = WebCookieContext{ .app = self, .same_site = true };
            const result = web.fetch(
                self.browser.currentUrl().bytes(),
                self.transport.raw[0..],
                self.transport.body[0..],
                self.transport.scratch[0..],
                .{
                    .stop = &self.stop_flag,
                    .progress = webProgress,
                    .progress_context = self,
                    .origin = origin,
                    .method = method,
                    .content_type = request_content_type,
                    .body = body,
                    .cookie_provider = webCookieProvider,
                    .cookie_sink = webCookieSink,
                    .cookie_context = &cookie_context,
                },
            );
            self.loading = false;
            switch (result) {
                .response => |response| {
                    self.clearLoaded();
                    self.loaded_len = response.body.len;
                    self.loaded_status = response.status;
                    self.loaded_secure = response.secure;
                    if (response.redirects > 0 and self.browser.replaceAfterRedirect(response.final_url.bytes())) {
                        self.address.set(self.browser.currentUrl().bytes());
                    }
                    const content_type = response.content_type orelse "";
                    self.loaded_media = switch (r4os.html.classifyMediaType(content_type)) {
                        .html => .html,
                        .plain_text => .plain_text,
                        .unsupported => .unsupported,
                    };
                    if (self.loaded_media == .html) {
                        // The transport buffers are reused while document resources load.
                        // Preserve the top-level response diagnostic before that happens.
                        self.captureResponseDiagnostic(response);
                        if (!self.parseHtmlDocument(
                            response.body,
                            content_type,
                            response.content_security_policy orelse "",
                            true,
                        )) {
                            self.captureStatusDiagnostic("Document", spanZ(self.status[0..]));
                            self.has_rollback = false;
                            return;
                        }
                    } else if (self.loaded_media == .unsupported) {
                        self.loaded_len = 0;
                        self.setStatus("This response MIME type has no Klickifax document handler.");
                        self.captureResponseDiagnostic(response);
                        self.has_rollback = false;
                        self.updateTitle();
                        return;
                    }
                    var len: usize = 0;
                    appendLocal(self.status[0..], &len, if (response.secure) "HTTPS " else "HTTP ");
                    appendDecimal(self.status[0..], &len, response.status);
                    if (self.loaded_media == .html) {
                        appendLocal(self.status[0..], &len, " - HTML ");
                        appendDecimal(self.status[0..], &len, self.transport.document.node_count);
                        appendLocal(self.status[0..], &len, " nodes - ");
                        appendLocal(self.status[0..], &len, documentModeText(self.transport.document.mode));
                    } else {
                        appendLocal(self.status[0..], &len, " - text/plain");
                    }
                    if (response.redirects > 0) {
                        appendLocal(self.status[0..], &len, " - redirects ");
                        appendDecimal(self.status[0..], &len, response.redirects);
                    }
                    if (self.loaded_media == .html) {
                        self.appendScriptDiagnostic();
                        self.appendImageDiagnostic();
                        self.appendFontDiagnostic();
                    } else self.captureResponseDiagnostic(response);
                    self.has_rollback = false;
                    self.updateTitle();
                },
                .failure => |err| {
                    if (err == .cancelled) {
                        self.restoreRollback();
                        self.setStatus("Loading stopped. The previous document remains active.");
                    } else {
                        self.restoreRollback();
                        self.setStatus(fetchErrorText(err));
                    }
                    self.captureStatusDiagnostic("Fetch", spanZ(self.status[0..]));
                },
            }
        } else {
            self.loading = false;
            self.has_rollback = false;
            self.setStatus("Web transport is unavailable.");
            self.captureStatusDiagnostic("Fetch", spanZ(self.status[0..]));
        }
    }

    fn parseHtmlDocument(self: *App, source: []const u8, content_type: []const u8, csp: []const u8, require_mime: bool) bool {
        const parse_result = self.transport.document.parse(source, .{
            .content_type = content_type,
            .require_html_mime = require_mime,
        });
        if (parse_result) |_| {
            self.transport.view.build(&self.transport.document) catch |err| {
                self.loaded_html = false;
                self.setStatus(htmlErrorText(err));
                return false;
            };
            self.transport.external_styles_len = 0;
            self.transport.external_style_count = 0;
            if (!self.rebuildStylesheet()) {
                self.loaded_html = false;
                return false;
            }
            self.transport.interaction.rebuild(&self.transport.document) catch |err| {
                self.loaded_html = false;
                self.setStatus(formErrorText(err));
                return false;
            };
            self.loaded_html = true;
            self.loaded_media = .html;
            self.document_generation +%= 1;
            if (self.document_generation == 0) self.document_generation = 1;
            self.document_fonts.beginDocument(self.document_generation);
            const effective_csp = if (csp.len > 0) csp else documentMetaCsp(&self.transport.document);
            self.configurePageClock();
            self.page_runtime.beginDocument(
                &self.transport.document,
                self.browser_storage,
                self.browser.currentUrl().bytes(),
                effective_csp,
                self.document_generation,
                self.nowMilliseconds(),
            ) catch |err| {
                self.runtime_active = false;
                self.loaded_html = false;
                self.setStatus(webRuntimeErrorText(err));
                return false;
            };
            self.page_runtime.setNavigationSnapshot(
                self.browser.history.entries[0..self.browser.history.count],
                self.browser.history.entry_ids[0..self.browser.history.count],
                self.browser.history.index,
            ) catch |err| {
                self.runtime_active = false;
                self.loaded_html = false;
                self.setStatus(webRuntimeErrorText(err));
                return false;
            };
            self.runtime_active = true;
            self.page_runtime.markResponseStart(self.nowMilliseconds());
            self.preparePageImageSlots();
            @atomicStore(u32, &self.stop_flag.value, 0, .release);
            self.script_checkpoints = 0;
            self.script_running = true;
            const script_result = self.page_runtime.executeDocumentScripts();
            self.script_running = false;
            _ = script_result catch |err| {
                self.setStatus(webRuntimeErrorText(err));
                return false;
            };
            var resource_rounds: usize = 0;
            while (!self.page_runtime.resourcesSettled() and resource_rounds < 4) : (resource_rounds += 1) {
                self.servicePageRequestsBurst();
                self.ctx.sys.taskYield();
            }
            if (!self.page_runtime.resourcesSettled()) {
                self.setStatus("The document resource queue did not settle.");
                return false;
            }
            if (!self.rebuildWebFontRegistry()) return false;
            self.refreshInlineSvgImages();
            self.reflowDocument();
            _ = self.syncLayoutWebFonts() orelse return false;
            if (!self.syncCssBackgroundImages()) return false;
            self.finalizePageImageSlots();
            self.reflowDocument();
            self.page_runtime.markDomContentLoadedStart(self.nowMilliseconds());
            _ = self.page_runtime.dispatchEvent(.document, "DOMContentLoaded", self.nowMilliseconds()) catch {};
            self.page_runtime.markDomContentLoadedEnd(self.nowMilliseconds());
            self.page_runtime.markLoadStart(self.nowMilliseconds());
            _ = self.page_runtime.dispatchEvent(.window, "load", self.nowMilliseconds()) catch {};
            _ = self.page_runtime.pump(self.nowMilliseconds(), page_event_jobs_per_slice) catch {};
            self.page_runtime.markLoadComplete(self.nowMilliseconds());
            self.updateTitle();
            return true;
        } else |err| {
            self.loaded_html = false;
            self.setStatus(htmlErrorText(err));
            return false;
        }
    }

    fn loadLocalDocument(self: *App) void {
        self.clearLoaded();
        const source = if (self.browser.page.kind == .search)
            localSearchFixture()
        else
            self.buildLocalResults();
        self.loaded_len = source.len;
        self.loaded_status = 200;
        self.loaded_secure = true;
        if (!self.parseHtmlDocument(source, "text/html;charset=utf-8", "", true)) {
            self.has_rollback = false;
            return;
        }
        self.has_rollback = false;
        self.setStatus(if (self.browser.page.kind == .search) "Local search form ready." else "Local result list ready.");
        self.updateTitle();
    }

    fn buildLocalResults(self: *App) []const u8 {
        return localResultsFixture(self.browser.currentUrl().bytes(), self.transport.local_document[0..]);
    }

    fn loadSubdocument(self: *App, completion: r4os.web_runtime.ResourceCompletion) bool {
        const documents = if (self.subdocuments) |*value| value else return false;
        const parent_runtime: *r4os.web_runtime.WebRuntime = if (completion.generation == self.document_generation)
            self.page_runtime
        else if (documents.findGeneration(completion.generation)) |context|
            &context.runtime
        else
            return false;
        const parent_document = parent_runtime.document orelse return false;
        if (completion.node >= parent_document.node_count) return false;
        const inherit_origin = parent_document.attribute(completion.node, "srcdoc") != null;
        const content_type = if (inherit_origin or completion.content_type.len == 0) "text/html" else completion.content_type;
        const context = documents.create(
            completion.generation,
            parent_runtime.security_context.document_origin,
            completion.node,
            completion.url,
            completion.body,
            content_type,
            completion.content_security_policy,
            inherit_origin,
            .{ .context = self, .complete = completePageResource },
            .{ .context = self, .inspect = inspectFrame },
        ) catch return false;
        var rounds: usize = 0;
        while (!context.runtime.resourcesSettled() and rounds < 4) : (rounds += 1) {
            self.serviceRuntimeRequests(&context.runtime, 16);
            self.ctx.sys.taskYield();
        }
        if (!context.runtime.resourcesSettled()) return false;
        _ = documents.finalizeSettled(self.nowMilliseconds()) catch return false;
        return true;
    }

    fn deinitImages(self: *App) void {
        self.clearPageImages();
    }

    fn clearPageImages(self: *App) void {
        const allocator = self.ctx.sys.allocator();
        for (&self.page_images) |*entry| {
            if (entry.svg_source.len > 0) allocator.free(entry.svg_source);
            if (entry.pixels.len > 0) allocator.free(entry.pixels);
            if (entry.rendered.len > 0) allocator.free(entry.rendered);
            entry.* = .{};
        }
    }

    fn preparePageImageSlots(self: *App) void {
        var index: usize = 0;
        while (index < self.transport.document.node_count) : (index += 1) {
            const node: u16 = @intCast(index);
            if (r4os.web_resources.resourceKind(&self.transport.document, node) != .image) continue;
            if (self.pageImage(node) != null) continue;
            const entry = self.pageImageSlot(self.document_generation, node) orelse {
                self.noteImageFailure(.limit, "ImageSlotLimit", 0);
                continue;
            };
            entry.* = .{
                .used = true,
                .generation = self.document_generation,
                .node = node,
                .state = .loading,
            };
        }
    }

    fn finalizePageImageSlots(self: *App) void {
        var unresolved = false;
        for (&self.page_images) |*entry| {
            if (!entry.used or entry.inline_svg or entry.generation != self.document_generation or entry.state != .loading) continue;
            entry.state = .failed;
            unresolved = true;
        }
        if (unresolved and self.image_fetch_failures == 0 and self.image_format_failures == 0 and
            self.image_decode_failures == 0 and self.image_memory_failures == 0 and
            self.image_limit_failures == 0 and self.image_other_failures == 0)
        {
            self.noteImageFailure(.other, "ResourceFailed", 0);
        }
    }

    fn pageImage(self: *App, node: u16) ?*PageImage {
        return self.pageImageForRole(node, .content);
    }

    fn pageImageForRole(self: *App, node: u16, role: r4os.web_layout.ImageRole) ?*PageImage {
        for (&self.page_images) |*entry| {
            if (entry.used and entry.generation == self.document_generation and entry.node == node and entry.role == role) return entry;
        }
        return null;
    }

    fn pageImageSlot(self: *App, generation: u32, node: u16) ?*PageImage {
        return self.pageImageSlotForRole(generation, node, .content);
    }

    fn pageImageSlotForRole(self: *App, generation: u32, node: u16, role: r4os.web_layout.ImageRole) ?*PageImage {
        var free: ?*PageImage = null;
        for (&self.page_images) |*entry| {
            if (entry.used and entry.generation == generation and entry.node == node and entry.role == role) return entry;
            if (!entry.used and free == null) free = entry;
        }
        return free;
    }

    fn releasePageImage(self: *App, entry: *PageImage) void {
        const allocator = self.ctx.sys.allocator();
        if (entry.used and entry.state == .ready) self.image_loaded_count -|= 1;
        if (entry.svg_source.len > 0) allocator.free(entry.svg_source);
        if (entry.pixels.len > 0) allocator.free(entry.pixels);
        if (entry.rendered.len > 0) allocator.free(entry.rendered);
        entry.* = .{};
    }

    fn completePageImage(self: *App, completion: r4os.web_runtime.ResourceCompletion) bool {
        const role = layoutImageRole(completion.role);
        const entry = self.pageImageSlotForRole(completion.generation, completion.node, role) orelse {
            self.noteImageFailure(.limit, "ImageSlotLimit", completion.body.len);
            return false;
        };
        self.releasePageImage(entry);
        entry.used = true;
        entry.generation = completion.generation;
        entry.resource_id = completion.resource_id;
        entry.node = completion.node;
        entry.role = role;
        entry.state = .loading;
        return self.decodePageImage(entry, completion.body, completion.content_type);
    }

    fn decodePageImage(self: *App, entry: *PageImage, source: []const u8, content_type: []const u8) bool {
        const info = self.ctx.image.probe(source, content_type) catch |err| {
            entry.state = .failed;
            self.noteR4ImgFailure(err, source.len);
            self.resource_dirty = true;
            return false;
        };
        const count = info.pixelCount() catch {
            entry.state = .failed;
            self.noteImageFailure(.limit, "PixelLimit", source.len);
            self.resource_dirty = true;
            return false;
        };
        const scratch_size = self.ctx.image.scratchBytesFor(info, source.len) catch {
            entry.state = .failed;
            self.noteImageFailure(.limit, "ScratchLimit", source.len);
            self.resource_dirty = true;
            return false;
        };
        const allocator = self.ctx.sys.allocator();
        const pixels = allocator.alloc(u32, count) catch {
            entry.state = .failed;
            self.noteImageFailure(.memory, "PixelAllocation", source.len);
            self.resource_dirty = true;
            return false;
        };
        const scratch = allocator.alignedAlloc(u8, .fromByteUnits(16), scratch_size) catch {
            allocator.free(pixels);
            entry.state = .failed;
            self.noteImageFailure(.memory, "ScratchAllocation", source.len);
            self.resource_dirty = true;
            return false;
        };
        defer allocator.free(scratch);
        var glyph_context = SvgGlyphContext{ .app = self, .font_id = r4os.abi.gui_font_builtin_id };
        const decoded = if (info.format == .svg)
            self.ctx.image.decodeSvg(
                source,
                content_type,
                pixels,
                scratch,
                .{
                    .glyphs = self.svgGlyphProvider(&glyph_context),
                    .links = .{ .context = entry, .record = svgLinkRegion },
                },
            )
        else
            self.ctx.image.decode(source, content_type, pixels, scratch);
        const image = decoded catch |err| {
            allocator.free(pixels);
            if (err == error.DecodeFailed) self.image_decode_last_bytes = source.len;
            entry.state = .failed;
            self.noteR4ImgFailure(err, source.len);
            self.resource_dirty = true;
            return false;
        };
        if (entry.svg_link_overflow) {
            allocator.free(pixels);
            entry.state = .failed;
            self.noteImageFailure(.limit, "SvgLinkLimit", source.len);
            self.resource_dirty = true;
            return false;
        }
        var svg_source: []u8 = &.{};
        if (info.format == .svg) {
            svg_source = allocator.dupe(u8, source) catch {
                allocator.free(pixels);
                entry.state = .failed;
                self.noteImageFailure(.memory, "SvgSourceAllocation", source.len);
                self.resource_dirty = true;
                return false;
            };
        }
        entry.info = image.info;
        entry.svg_source = svg_source;
        entry.pixels = pixels;
        entry.state = .ready;
        self.image_loaded_count += 1;
        self.resource_dirty = true;
        return true;
    }

    fn refreshInlineSvgImages(self: *App) void {
        if (!self.loaded_html) return;
        for (&self.page_images) |*entry| {
            if (!entry.used or !entry.inline_svg or entry.generation != self.document_generation) continue;
            if (entry.node >= self.transport.document.node_count or
                !inline_svg.isRoot(&self.transport.document, entry.node)) self.releasePageImage(entry);
        }
        const allocator = self.ctx.sys.allocator();
        const buffer = allocator.alloc(u8, r4img.max_svg_source_bytes) catch {
            self.noteImageFailure(.memory, "SvgSourceAllocation", 0);
            return;
        };
        defer allocator.free(buffer);
        var serializer = inline_svg.Serializer{ .buffer = buffer };
        var index: usize = 0;
        while (index < self.transport.document.node_count) : (index += 1) {
            const node: u16 = @intCast(index);
            if (!inline_svg.isRoot(&self.transport.document, node)) continue;
            const entry = self.pageImageSlot(self.document_generation, node) orelse {
                self.noteImageFailure(.limit, "ImageSlotLimit", 0);
                continue;
            };
            self.releasePageImage(entry);
            entry.used = true;
            entry.inline_svg = true;
            entry.generation = self.document_generation;
            entry.node = node;
            entry.state = .loading;
            const source = serializer.serialize(&self.transport.document, node) catch |err| {
                entry.state = .failed;
                const class: ImageFailureClass = if (err == error.InvalidNode) .other else .limit;
                self.noteImageFailure(class, @errorName(err), serializer.len);
                continue;
            };
            _ = self.decodePageImage(entry, source, "image/svg+xml");
        }
    }

    const ImageFailureClass = enum { fetch, format, decode, memory, limit, other };

    fn noteR4ImgFailure(self: *App, err: r4img.Error, bytes: usize) void {
        const class: ImageFailureClass = switch (err) {
            error.UnsupportedFormat, error.UnsupportedFeature => .format,
            error.DecodeFailed => .decode,
            error.TooLarge, error.InvalidDimensions, error.PixelBufferTooSmall, error.ScratchBufferTooSmall => .limit,
            error.Empty, error.InvalidImage, error.InvalidArgument => .other,
        };
        self.noteImageFailure(class, @errorName(err), bytes);
    }

    fn noteImageFailure(self: *App, class: ImageFailureClass, name: []const u8, bytes: usize) void {
        if (self.native_frame_active and class == .memory) self.native_frame_app_failed = true;
        switch (class) {
            .fetch => self.image_fetch_failures += 1,
            .format => self.image_format_failures += 1,
            .decode => self.image_decode_failures += 1,
            .memory => self.image_memory_failures += 1,
            .limit => self.image_limit_failures += 1,
            .other => self.image_other_failures += 1,
        }
        self.image_last_bytes = bytes;
        setZ(self.image_last_error[0..], name);
    }

    fn clearLoaded(self: *App) void {
        self.clearPageImages();
        if (self.subdocuments) |*documents| documents.retireParent(self.document_generation);
        if (self.runtime_active) {
            self.page_runtime.abortDocument();
            self.runtime_active = false;
        }
        self.loaded_len = 0;
        self.loaded_status = 0;
        self.loaded_secure = false;
        self.loaded_html = false;
        self.loaded_media = .none;
        self.layout_valid = false;
        self.scroll_y = 0;
        self.hover_node = r4os.html.none;
        self.active_node = r4os.html.none;
        self.resource_dirty = false;
        self.image_loaded_count = 0;
        self.image_fetch_failures = 0;
        self.image_format_failures = 0;
        self.image_decode_failures = 0;
        self.image_memory_failures = 0;
        self.image_limit_failures = 0;
        self.image_other_failures = 0;
        self.image_decode_last_bytes = 0;
        self.image_draw_succeeded = false;
        self.image_draw_error = 0;
        self.image_last_bytes = 0;
        self.image_last_error = .{0} ** 32;
        self.image_resource_event_valid = false;
        self.image_resource_failure_event_valid = false;
        self.font_resource_event_valid = false;
        self.font_resource_failure_event_valid = false;
        self.web_font_rule_key_count = 0;
        self.web_font_rule_generation = 0;
        self.web_font_rule_keys_valid = false;
        self.web_font_viewport_dirty = false;
        self.transport.document.reset();
        self.transport.view.reset();
        self.transport.stylesheet.reset();
        self.transport.font_registry.beginDocument(0);
        self.document_fonts.beginDocument(0);
        self.transport.external_styles_len = 0;
        self.transport.external_style_count = 0;
        self.transport.layout.reset(.{ .width = 1, .height = 1 });
        self.transport.interaction.reset();
    }

    fn initializeFontCache(self: *App) void {
        if (self.font_cache != null or self.font_cache_disabled) return;
        var attempt: usize = 0;
        while (attempt < font_cache_busy_retry_limit) : (attempt += 1) {
            var store = font_cache_store.Store.init(self.ctx.sys.allocator(), self.ctx.files, .{}) catch {
                self.font_cache_failures += 1;
                self.font_cache_disabled = true;
                return;
            };
            _ = store.load(self.cacheNowSeconds(), self.nextFontCacheTransaction()) catch |err| {
                store.deinit();
                if (err == error.CacheBusy) {
                    self.ctx.sys.taskYield();
                    continue;
                }
                self.font_cache_failures += 1;
                self.font_cache_disabled = true;
                return;
            };
            self.font_cache = store;
            return;
        }
        // Another instance may still be hashing or publishing. Keep this
        // instance retryable so the next lookup or response can join later.
    }

    fn waitForFontCacheLease(self: *App, generation: u32) bool {
        if (!self.fontGenerationActive(generation) or self.should_exit or
            @atomicLoad(u32, &self.stop_flag.value, .acquire) != 0) return false;
        if (!self.pumpLoading()) return false;
        self.ctx.sys.taskYield();
        return self.fontGenerationActive(generation) and !self.should_exit and
            @atomicLoad(u32, &self.stop_flag.value, .acquire) == 0;
    }

    fn fontGenerationActive(self: *App, generation: u32) bool {
        if (generation == self.document_generation) return true;
        const documents = if (self.subdocuments) |*value| value else return false;
        return documents.findGeneration(generation) != null;
    }

    fn deinitFontCache(self: *App) void {
        if (self.font_cache) |*store| store.deinit();
        self.font_cache = null;
    }

    fn nextFontCacheTransaction(self: *App) u64 {
        const result = if (self.font_cache_transaction == 0) 1 else self.font_cache_transaction;
        self.font_cache_transaction +%= 1;
        if (self.font_cache_transaction == 0) self.font_cache_transaction = 1;
        return result;
    }

    fn cacheNowSeconds(self: *const App) u64 {
        const state = self.ctx.sys.timeState();
        if (state.valid != 0) {
            if (r4std.date.fromTimeState(state)) |date_time| {
                if (r4std.date.utcFromDateTime(date_time, 0)) |utc| {
                    if (utc.seconds_since_unix_epoch > 0) return @intCast(utc.seconds_since_unix_epoch);
                }
            }
        }
        // Persistent cache timestamps use Unix seconds exclusively. Zero is
        // the explicit unknown-clock domain; boot-local monotonic ticks must
        // never be serialized beside Unix time across restarts.
        return 0;
    }

    fn deinitSubdocuments(self: *App) void {
        if (self.subdocuments) |*documents| documents.deinit();
        self.subdocuments = null;
    }

    fn updateTitle(self: *App) void {
        var len: usize = 0;
        appendLocal(self.title[0..], &len, "Klickifax");
        const document_title = if (self.loaded_html) self.transport.view.title() else "";
        if (document_title.len > 0) {
            appendLocal(self.title[0..], &len, " - ");
            appendLocal(self.title[0..], &len, document_title);
        } else if (self.browser.page.title.len > 0 and self.browser.page.kind != .home) {
            appendLocal(self.title[0..], &len, " - ");
            appendLocal(self.title[0..], &len, self.browser.page.title);
        }
        _ = self.ctx.desk.guiSetTitle(@ptrCast(&self.title));
    }

    fn advanceFocus(self: *App, reverse: bool) void {
        var current: u8 = @intFromEnum(self.focus);
        var count: usize = 0;
        while (count < 8) : (count += 1) {
            current = if (reverse) (current + 7) % 8 else (current + 1) % 8;
            const candidate: FocusTarget = @enumFromInt(current);
            if (self.isEnabled(candidate)) {
                self.focus = candidate;
                return;
            }
        }
    }

    fn isEnabled(self: *const App, target: FocusTarget) bool {
        return switch (target) {
            .back => self.browser.history.canBack(),
            .forward => self.browser.history.canForward(),
            .stop => self.loading_view_active or self.loading or self.script_running,
            .document => true,
            else => true,
        };
    }

    fn buttonRect(self: *const App, target: FocusTarget) r4os.gui.Rect {
        return switch (target) {
            .back => .{ .x = 8, .y = 8, .w = 64, .h = 27 },
            .forward => .{ .x = 78, .y = 8, .w = 76, .h = 27 },
            .stop => .{ .x = 160, .y = 8, .w = 56, .h = 27 },
            .reload => .{ .x = 222, .y = 8, .w = 70, .h = 27 },
            .diagnostics => .{ .x = 298, .y = 8, .w = 62, .h = 27 },
            .address => self.addressRect(),
            .go => .{ .x = self.w - 52, .y = 42, .w = 44, .h = 25 },
            .document => self.documentContentRect(self.documentRect().inset(2, 2)),
        };
    }

    fn addressRect(self: *const App) r4os.gui.Rect {
        return .{ .x = 68, .y = 42, .w = @max(120, self.w - 126), .h = 25 };
    }

    fn documentRect(self: *const App) r4os.gui.Rect {
        return .{ .x = 8, .y = 74, .w = self.w - 16, .h = self.h - 104 };
    }

    fn documentContentRect(self: *const App, page: r4os.gui.Rect) r4os.gui.Rect {
        _ = self;
        return .{ .x = page.x, .y = page.y, .w = @max(1, page.w - scrollbar_size), .h = page.h };
    }

    fn documentScrollbar(self: *const App, page: r4os.gui.Rect) r4os.gui.Scrollbar {
        const content = self.documentContentRect(page);
        const content_height = if (!self.loading_view_active and self.layout_valid) self.transport.layout.content_height else content.h;
        const total_units: usize = @intCast(@max(1, @divTrunc(content_height + scroll_unit - 1, scroll_unit)));
        const visible_units: usize = @intCast(@max(1, @divTrunc(content.h + scroll_unit - 1, scroll_unit)));
        const first_unit: usize = if (self.loading_view_active) 0 else @intCast(@max(0, @divTrunc(self.scroll_y, scroll_unit)));
        return .{
            .rect = .{ .x = page.x + page.w - scrollbar_size, .y = page.y, .w = scrollbar_size, .h = page.h },
            .orientation = .vertical,
            .total_items = total_units,
            .visible_items = visible_units,
            .first_index = first_unit,
            .disabled = total_units <= visible_units,
        };
    }

    fn reflowDocument(self: *App) void {
        self.layout_valid = false;
        if (!self.loaded_html) {
            self.scroll_y = 0;
            return;
        }
        const page = self.documentRect().inset(2, 2);
        const content = self.documentContentRect(page);
        _ = self.transport.layout.reflowInteractiveWithProviders(
            &self.transport.document,
            &self.transport.stylesheet,
            .{ .width = content.w, .height = content.h },
            .{
                .hovered_node = self.hover_node,
                .focused_node = self.transport.interaction.focused_node,
                .active_node = self.active_node,
            },
            .{ .context = self, .resolve = resolvePageImage, .resolve_role = resolvePageImageRole },
            .{ .context = self, .resolve = resolveLayoutFont, .measure = measureLayoutFont },
        ) catch |err| {
            self.setStatus(layoutErrorText(err));
            self.scroll_y = 0;
            return;
        };
        self.layout_valid = true;
        self.clampDocumentScroll();
    }

    fn syncCssBackgroundImages(self: *App) bool {
        if (!self.runtime_active or !self.layout_valid) return true;
        var sources: [r4os.web_resources.max_resources]r4os.web_runtime.CssImageSource = undefined;
        var source_count: usize = 0;
        for (self.transport.layout.ops[0..self.transport.layout.op_count]) |op| {
            if (op.kind != .css_background) continue;
            var duplicate = false;
            for (sources[0..source_count]) |source| {
                if (source.node == op.node) {
                    duplicate = true;
                    break;
                }
            }
            if (duplicate) continue;
            if (source_count >= sources.len) {
                self.setStatus("The CSS image resource catalogue is full.");
                return false;
            }
            sources[source_count] = .{
                .node = op.node,
                .raw_value = op.css_background.raw_value,
                .base_url = op.css_background.base_url,
            };
            source_count += 1;
        }
        _ = self.page_runtime.syncCssImages(sources[0..source_count]) catch |err| {
            self.setStatus(webRuntimeErrorText(err));
            return false;
        };
        return true;
    }

    fn rebuildStylesheet(self: *App) bool {
        self.transport.stylesheet.reset();
        self.transport.stylesheet.appendDocumentStyles(&self.transport.document) catch |err| {
            self.setStatus(cssErrorText(err));
            return false;
        };
        for (self.transport.external_style_records[0..self.transport.external_style_count]) |record| {
            const start: usize = record.offset;
            const length: usize = record.len;
            if (start > self.transport.external_styles_len or length > self.transport.external_styles_len - start) {
                self.setStatus("The stylesheet source catalogue was invalid.");
                return false;
            }
            self.transport.stylesheet.appendWithBase(
                self.transport.external_styles[start .. start + length],
                record.final_url.bytes(),
            ) catch |err| {
                self.setStatus(cssErrorText(err));
                return false;
            };
        }
        return true;
    }

    fn refreshResponsiveWebFonts(self: *App) void {
        if (!self.web_font_viewport_dirty or !self.loaded_html or self.loading) return;
        self.web_font_viewport_dirty = false;
        if (!self.rebuildWebFontRegistry()) return;
        self.reflowDocument();
        const activated = self.syncLayoutWebFonts() orelse return;
        if (activated) self.reflowDocument();
    }

    fn rebuildWebFontRegistry(self: *App) bool {
        const page = self.documentRect().inset(2, 2);
        const content = self.documentContentRect(page);
        var next_keys: [r4os.web_fonts.max_source_sections]WebFontRuleKey = .{WebFontRuleKey{}} ** r4os.web_fonts.max_source_sections;
        var next_key_count: usize = 0;
        var active_rules = self.transport.stylesheet.activeFontFaceRulesForViewportSize(content.w, content.h);
        while (active_rules.next()) |rule| {
            if (next_key_count >= next_keys.len or rule.source_section > std.math.maxInt(u16)) {
                self.setStatus("The active web font rule catalogue is full.");
                return false;
            }
            var key = WebFontRuleKey{ .source_section = @intCast(rule.source_section) };
            std.crypto.hash.sha2.Sha256.hash(rule.rule_text, &key.rule_digest, .{});
            std.crypto.hash.sha2.Sha256.hash(rule.final_base_url, &key.base_digest, .{});
            next_keys[next_key_count] = key;
            next_key_count += 1;
        }

        var unchanged = self.web_font_rule_keys_valid and
            self.web_font_rule_generation == self.document_generation and
            self.web_font_rule_key_count == next_key_count;
        if (unchanged) {
            for (next_keys[0..next_key_count], 0..) |key, index| {
                if (!std.meta.eql(key, self.web_font_rule_keys[index])) {
                    unchanged = false;
                    break;
                }
            }
        }
        if (unchanged) return true;

        self.page_runtime.resetFontFaces();
        self.document_fonts.resetRules();
        self.transport.font_registry.beginDocument(self.document_generation);
        active_rules = self.transport.stylesheet.activeFontFaceRulesForViewportSize(content.w, content.h);
        while (active_rules.next()) |rule| {
            _ = self.transport.font_registry.appendStylesheet(
                rule.rule_text,
                rule.final_base_url,
            ) catch |err| {
                self.setStatus(webFontErrorText(err));
                self.web_font_rule_keys_valid = false;
                return false;
            };
        }
        @memcpy(self.web_font_rule_keys[0..next_key_count], next_keys[0..next_key_count]);
        self.web_font_rule_key_count = next_key_count;
        self.web_font_rule_generation = self.document_generation;
        self.web_font_rule_keys_valid = true;
        self.web_font_viewport_dirty = false;
        return true;
    }

    fn syncLayoutWebFonts(self: *App) ?bool {
        if (!self.runtime_active or !self.layout_valid) return false;
        var demanded: [r4os.web_fonts.max_faces]bool = [_]bool{false} ** r4os.web_fonts.max_faces;
        var matches: [r4os.web_fonts.max_faces]u16 = undefined;

        for (self.transport.layout.ops[0..self.transport.layout.op_count]) |op| {
            const value = switch (op.kind) {
                .text => self.transport.layout.text(op),
                .control => self.webFontControlText(op.node),
                else => continue,
            };
            if (value.len == 0) continue;
            const count = self.transport.font_registry.collectNeededFaces(.{
                .family_list = op.font_family,
                .text = value,
                .weight = op.font_weight,
                .style = if (op.italic) .italic else .normal,
            }, matches[0..]) catch |err| {
                self.setStatus(webFontErrorText(err));
                return null;
            };
            for (matches[0..count]) |face_index| {
                if (face_index < demanded.len) demanded[face_index] = true;
            }
        }

        var faces: [r4os.web_fonts.max_faces]u16 = undefined;
        var face_count: usize = 0;
        for (demanded, 0..) |needed, face_index| {
            if (!needed) continue;
            faces[face_count] = @intCast(face_index);
            face_count += 1;
        }
        _ = self.document_fonts.syncDemands(
            &self.transport.font_registry,
            faces[0..face_count],
            self.fontNowMilliseconds(),
        ) catch |err| {
            self.setStatus(@errorName(err));
            return null;
        };
        _ = self.page_runtime.syncFontFaces(&self.transport.font_registry, faces[0..face_count]) catch |err| {
            if (err == error.ResourceLimit) {
                self.document_fonts.reconcile(self.page_runtime, self.fontNowMilliseconds());
                self.setStatus(webRuntimeErrorText(err));
                return self.document_fonts.publishRevision();
            }
            self.document_fonts.cancelDemandEpoch();
            self.setStatus(webRuntimeErrorText(err));
            return null;
        };
        self.document_fonts.reconcile(self.page_runtime, self.fontNowMilliseconds());
        return self.document_fonts.publishRevision();
    }

    fn webFontControlText(self: *App, node: u16) []const u8 {
        const control = self.transport.interaction.controlForNode(node) orelse return "";
        const raw = switch (control.kind) {
            .submit, .button, .select => control.displayValue(),
            else => control.value(),
        };
        if (raw.len > 0) return raw;
        if (control.kind == .text or control.kind == .search) {
            return self.transport.document.attribute(control.node, "placeholder") orelse "";
        }
        return if (control.kind == .submit or control.kind == .button or control.kind == .select) "Button" else "";
    }

    fn maxDocumentScroll(self: *const App) i32 {
        if (!self.layout_valid) return 0;
        const page = self.documentContentRect(self.documentRect().inset(2, 2));
        return @max(0, self.transport.layout.content_height - page.h);
    }

    fn clampDocumentScroll(self: *App) void {
        self.scroll_y = clampI32(self.scroll_y, 0, self.maxDocumentScroll());
    }

    fn scrollDocumentBy(self: *App, delta: i32) bool {
        const before = self.scroll_y;
        self.scroll_y = clampI32(self.scroll_y + delta, 0, self.maxDocumentScroll());
        return self.scroll_y != before;
    }

    fn stepDocumentScrollbar(self: *App, part: r4os.gui.ScrollbarPart) void {
        const page = self.documentRect().inset(2, 2);
        const scrollbar = self.documentScrollbar(page);
        if (scrollbar.disabled) return;
        const step = scrollbar.step(part);
        if (step.action == .changed) {
            self.scroll_y = @as(i32, @intCast(step.first_index)) * scroll_unit;
            self.clampDocumentScroll();
        }
    }

    fn handleDocumentKey(self: *App, key: u8) bool {
        const page = self.documentContentRect(self.documentRect().inset(2, 2));
        return switch (key) {
            r4os.gui.Key.up => self.scrollDocumentBy(-scroll_unit),
            r4os.gui.Key.down => self.scrollDocumentBy(scroll_unit),
            r4os.gui.Key.page_up => self.scrollDocumentBy(0 - @max(scroll_unit, page.h - scroll_unit)),
            r4os.gui.Key.page_down => self.scrollDocumentBy(@max(scroll_unit, page.h - scroll_unit)),
            r4os.gui.Key.home => blk: {
                const changed = self.scroll_y != 0;
                self.scroll_y = 0;
                break :blk changed;
            },
            r4os.gui.Key.end => blk: {
                const target = self.maxDocumentScroll();
                const changed = self.scroll_y != target;
                self.scroll_y = target;
                break :blk changed;
            },
            else => false,
        };
    }

    fn handleFormKey(self: *App, key: u8) bool {
        const focused_node = self.transport.interaction.focused_node;
        if (focused_node == r4os.html.none) return false;
        const control = self.transport.interaction.focusedControl() orelse {
            if (key == r4os.gui.Key.enter or key == ' ') {
                self.transport.interaction.click(focused_node);
                self.activateDocumentNode(focused_node);
                return true;
            }
            return false;
        };
        switch (key) {
            r4os.gui.Key.enter => {
                if (control.kind == .select) {
                    _ = self.transport.interaction.selectNext(&self.transport.document, control.node) catch |err| {
                        self.setStatus(formErrorText(err));
                        return true;
                    };
                    self.setStatus("Selection changed.");
                } else if (control.kind == .button) {
                    self.transport.interaction.click(control.node);
                    self.setStatus("Button click dispatched.");
                } else {
                    self.submitDocumentForm(control.node);
                }
                return true;
            },
            ' ' => {
                if (control.kind == .select) {
                    _ = self.transport.interaction.selectNext(&self.transport.document, control.node) catch |err| {
                        self.setStatus(formErrorText(err));
                        return true;
                    };
                    self.setStatus("Selection changed.");
                    return true;
                }
                if (control.kind == .submit or control.kind == .button) {
                    self.transport.interaction.click(control.node);
                    if (control.kind == .submit) self.submitDocumentForm(control.node);
                    return true;
                }
            },
            r4os.gui.Key.backspace => return self.transport.interaction.backspace(),
            r4os.gui.Key.delete => return self.transport.interaction.deleteForward(),
            r4os.gui.Key.left => return self.transport.interaction.moveCursor(.left),
            r4os.gui.Key.right => return self.transport.interaction.moveCursor(.right),
            r4os.gui.Key.home => return self.transport.interaction.moveCursor(.home),
            r4os.gui.Key.end => return self.transport.interaction.moveCursor(.end),
            else => {},
        }
        if (key >= 0x20 and key < 0x7F and (control.kind == .text or control.kind == .search)) {
            const input = [_]u8{key};
            return self.transport.interaction.insertText(input[0..]) catch |err| {
                self.setStatus(formErrorText(err));
                return true;
            };
        }
        return false;
    }

    fn activateDocumentNode(self: *App, node: u16) void {
        if (!self.dispatchPageEvent(node, "click")) return;
        if (self.transport.interaction.controlForNode(node)) |control| {
            if (control.disabled) return;
            switch (control.kind) {
                .submit => self.submitDocumentForm(node),
                .button => self.setStatus("Button click dispatched."),
                .checkbox, .radio => {
                    control.checked = !control.checked;
                    self.setStatus("Control state changed.");
                },
                .select => {
                    _ = self.transport.interaction.selectNext(&self.transport.document, node) catch |err| {
                        self.setStatus(formErrorText(err));
                        return;
                    };
                    self.setStatus("Selection changed.");
                },
                else => self.transport.interaction.focus(node),
            }
            return;
        }
        const target = r4os.web_forms.linkTarget(&self.transport.document, node) orelse return;
        self.navigateDocumentReference(target);
    }

    fn submitDocumentForm(self: *App, submitter: u16) void {
        if (!self.dispatchPageEvent(submitter, "submit")) return;
        var target_buffer: [model.url_capacity + 1]u8 = undefined;
        var body_buffer: [form_body_capacity]u8 = undefined;
        var origin_buffer: [r4os.web_security.max_origin_host_bytes + 24]u8 = undefined;
        const source_origin = r4os.web_security.Origin.parse(self.browser.currentUrl().bytes(), self.document_generation) catch r4os.web_security.Origin{};
        const origin = source_origin.serialize(origin_buffer[0..]) orelse "null";
        const submission = self.transport.interaction.submit(
            &self.transport.document,
            submitter,
            self.browser.currentUrl(),
            target_buffer[0..],
            body_buffer[0..],
        ) catch |err| {
            self.setStatus(formErrorText(err));
            return;
        };
        self.saveRollback();
        if (!self.browser.navigate(submission.target)) {
            self.has_rollback = false;
            self.setStatus("The form action is not a supported address.");
            return;
        }
        if (submission.method == .post) {
            self.address.set(self.browser.currentUrl().bytes());
            self.setStatus("Form submitted");
            self.updateTitle();
            self.fetchCurrentRequest(.post, submission.content_type, submission.body, origin);
        } else {
            self.loadCurrent("Form submitted");
        }
    }

    fn navigateDocumentReference(self: *App, reference: []const u8) void {
        const resolved = model.resolve(self.browser.currentUrl(), reference) catch {
            self.setStatus("The link target is not a supported address.");
            return;
        };
        self.saveRollback();
        if (!self.browser.navigate(resolved.bytes())) {
            self.has_rollback = false;
            self.setStatus("The link target is not a supported address.");
            return;
        }
        self.loadCurrent("Link opened");
    }

    fn documentNodeAt(self: *const App, x: i32, y: i32) u16 {
        if (!self.loaded_html or !self.layout_valid) return r4os.html.none;
        const viewport = self.documentContentRect(self.documentRect().inset(2, 2));
        var control_index: usize = 0;
        while (control_index < self.transport.interaction.control_count) : (control_index += 1) {
            const node = self.transport.interaction.controls[control_index].node;
            if (self.controlVisibleRect(node, viewport)) |rect| {
                if (rect.contains(x, y)) return node;
            }
        }
        var index = self.transport.layout.op_count;
        while (index > 0) {
            index -= 1;
            const op = self.transport.layout.ops[index];
            if (op.node == r4os.html.none) continue;
            const scroll = if (op.fixed) 0 else self.scroll_y;
            const target = r4os.gui.Rect{
                .x = viewport.x + op.rect.x,
                .y = viewport.y + op.rect.y - scroll,
                .w = op.rect.w,
                .h = op.rect.h,
            };
            if (!clipRenderBounds(op, target, viewport, scroll).contains(x, y)) continue;
            if (op.kind == .image) {
                if (self.svgLinkNodeAt(op.node, target, x, y)) |link_node| {
                    return r4os.web_forms.interactiveAncestor(&self.transport.document, link_node);
                }
            }
            return r4os.web_forms.interactiveAncestor(&self.transport.document, op.node);
        }
        return r4os.html.none;
    }

    fn svgLinkNodeAt(self: *const App, image_node: u16, target: r4os.gui.Rect, x: i32, y: i32) ?u16 {
        const entry = for (&self.page_images) |*candidate| {
            if (candidate.used and candidate.generation == self.document_generation and candidate.node == image_node) break candidate;
        } else return null;
        if (entry.state != .ready or entry.info.format != .svg or target.w <= 0 or target.h <= 0) return null;
        const local_x: i32 = @intCast(@divTrunc(
            @as(i64, x - target.x) * @as(i64, entry.info.width),
            target.w,
        ));
        const local_y: i32 = @intCast(@divTrunc(
            @as(i64, y - target.y) * @as(i64, entry.info.height),
            target.h,
        ));
        var index = entry.svg_link_count;
        while (index > 0) {
            index -= 1;
            const region = entry.svg_links[index];
            if (region.node >= self.transport.document.node_count) continue;
            if (local_x >= region.x and local_y >= region.y and
                local_x < region.x + region.w and local_y < region.y + region.h) return region.node;
        }
        return null;
    }

    fn controlRect(self: *const App, node: u16, viewport: r4os.gui.Rect) ?r4os.gui.Rect {
        if (self.controlRenderOp(node)) |op| {
            const scroll = if (op.fixed) 0 else self.scroll_y;
            return .{
                .x = viewport.x + op.rect.x,
                .y = viewport.y + op.rect.y - scroll,
                .w = op.rect.w,
                .h = op.rect.h,
            };
        }
        var found = false;
        var bounds = r4os.gui.Rect{};
        var index: usize = 0;
        while (index < self.transport.layout.op_count) : (index += 1) {
            const op = self.transport.layout.ops[index];
            if (op.node != node or op.kind != .text) continue;
            const scroll = if (op.fixed) 0 else self.scroll_y;
            const rect = r4os.gui.Rect{
                .x = viewport.x + op.rect.x - 5,
                .y = viewport.y + op.rect.y - 3 - scroll,
                .w = op.rect.w + 10,
                .h = @max(22, op.rect.h + 6),
            };
            if (!found) {
                bounds = rect;
                found = true;
            } else {
                const left = @min(bounds.x, rect.x);
                const top = @min(bounds.y, rect.y);
                const right = @max(bounds.x + bounds.w, rect.x + rect.w);
                const bottom = @max(bounds.y + bounds.h, rect.y + rect.h);
                bounds = .{ .x = left, .y = top, .w = right - left, .h = bottom - top };
            }
        }
        return if (found) bounds else null;
    }

    fn controlVisibleRect(self: *const App, node: u16, viewport: r4os.gui.Rect) ?r4os.gui.Rect {
        const target = self.controlRect(node, viewport) orelse return null;
        if (self.controlRenderOp(node)) |op| {
            const scroll = if (op.fixed) 0 else self.scroll_y;
            return clipRenderBounds(op, target, viewport, scroll);
        }
        return intersectRect(target, viewport);
    }

    fn controlRenderOp(self: *const App, node: u16) ?r4os.web_layout.RenderOp {
        var index: usize = 0;
        while (index < self.transport.layout.op_count) : (index += 1) {
            const op = self.transport.layout.ops[index];
            if (op.node == node and op.kind == .control) return op;
        }
        return null;
    }

    fn saveRollback(self: *App) void {
        self.transport.rollback_browser = self.browser;
        self.has_rollback = true;
    }

    fn restoreRollback(self: *App) void {
        if (!self.has_rollback) return;
        self.browser = self.transport.rollback_browser;
        self.has_rollback = false;
        self.address.set(self.browser.currentUrl().bytes());
        self.updateTitle();
    }

    fn requestStop(self: *App) void {
        @atomicStore(u32, &self.stop_flag.value, 1, .release);
        self.setStatus("Stopping...");
    }

    fn pumpLoading(self: *App) bool {
        var event: r4os.abi.GuiEvent = .{};
        var repaint = false;
        while (self.ctx.desk.guiPollEvent(&event) > 0) {
            const kind: r4os.abi.GuiEventKind = @enumFromInt(event.kind);
            switch (kind) {
                .close => {
                    self.should_exit = true;
                    self.requestStop();
                },
                .resize => {
                    const previous_w = self.w;
                    const previous_h = self.h;
                    self.updateMetrics();
                    if (!viewportSizeChanged(previous_w, previous_h, self.w, self.h)) continue;
                    self.updateWebViewport();
                    self.web_font_viewport_dirty = true;
                    repaint = true;
                },
                .mouse_down => {
                    if (self.buttonRect(.stop).contains(event.x, event.y)) {
                        self.focus = .stop;
                        self.pressed = .stop;
                        repaint = true;
                    }
                },
                .mouse_up => {
                    if (self.pressed == .stop) {
                        self.pressed = null;
                        if (self.buttonRect(.stop).contains(event.x, event.y)) self.requestStop();
                        repaint = true;
                    }
                },
                .key_down => if (r4os.gui.eventKey(event) == r4os.gui.Key.escape) self.requestStop(),
                else => {},
            }
        }
        if (repaint) self.render();
        return @atomicLoad(u32, &self.stop_flag.value, .acquire) == 0;
    }

    fn loadFonts(self: *App) void {
        self.font_count = 0;
        @memset(self.font_support_cache[0..], FontSupportCacheEntry{});
        self.font_support_cache_cursor = 0;
        const count = @min(@as(usize, @intCast(self.ctx.draw.fontCount())), self.font_infos.len);
        var index: usize = 0;
        while (index < count) : (index += 1) {
            var info: r4os.abi.GuiFontInfo = .{};
            if (self.ctx.draw.fontInfo(@intCast(index), &info) <= 0) continue;
            if ((info.flags & r4os.abi.gui_font_flag_renderable) == 0) continue;
            self.font_infos[self.font_count] = info;
            self.font_count += 1;
        }
    }

    fn resolveFont(self: *const App, family: []const u8, size: i32, weight: u16, codepoint: ?u32) u32 {
        return self.fontCatalog().resolve(family, size, weight, false, codepoint).id;
    }

    fn fontCatalog(self: *const App) r4os.web_font.Catalog {
        return .{
            .entries = self.font_infos[0..self.font_count],
            .support = .{ .context = @constCast(self), .callback = layoutFontSupports },
        };
    }

    fn fontSupports(self: *const App, info: *const r4os.abi.GuiFontInfo, codepoint: u32) bool {
        if (codepoint == ' ') return true;
        var row: u32 = 0;
        while (row < info.height) : (row += 1) {
            if (self.ctx.draw.fontGlyphRow(info.id, codepoint, row) != 0) return true;
        }
        return false;
    }

    fn cachedFontSupports(self: *App, font_id: u32, codepoint: u32) bool {
        for (self.font_support_cache[0..]) |entry| {
            if (entry.valid and entry.font_id == font_id and entry.codepoint == codepoint) return entry.supported;
        }
        var supported = false;
        for (self.font_infos[0..self.font_count]) |*info| {
            if (info.id != font_id) continue;
            supported = self.fontSupports(info, codepoint);
            break;
        }
        self.font_support_cache[self.font_support_cache_cursor] = .{
            .valid = true,
            .font_id = font_id,
            .codepoint = codepoint,
            .supported = supported,
        };
        self.font_support_cache_cursor = (self.font_support_cache_cursor + 1) % self.font_support_cache.len;
        return supported;
    }

    fn svgGlyphProvider(self: *const App, context: *SvgGlyphContext) r4img.SvgGlyphProvider {
        const font_id = self.resolveFont("sans-serif", 16, 400, null);
        context.* = .{ .app = self, .font_id = font_id };
        var info: r4os.abi.GuiFontInfo = .{};
        if (self.ctx.draw.fontInfo(font_id, &info) <= 0) {
            return .{ .context = context, .row = svgGlyphRow };
        }
        const height = @max(@as(u32, 1), @min(info.height, 64));
        return .{
            .context = context,
            .width = @intCast(@max(@as(u32, 1), @min(info.width, 64))),
            .height = @intCast(height),
            .advance = @intCast(@max(@as(u32, 1), @min(info.max_advance, 64))),
            .baseline = @intCast(std.math.clamp(info.baseline, 0, @as(i32, @intCast(height)))),
            .row = svgGlyphRow,
        };
    }

    fn statusRect(self: *const App) r4os.gui.Rect {
        return .{ .x = 0, .y = self.h - 26, .w = self.w, .h = 26 };
    }

    fn servicePageRequests(self: *App) void {
        self.servicePageRequestsLimited(page_resource_requests_per_slice, page_subdocument_requests_per_slice);
    }

    fn servicePageRequestsBurst(self: *App) void {
        self.servicePageRequestsLimited(16, 8);
    }

    fn servicePageRequestsLimited(self: *App, top_level_maximum: usize, subdocument_maximum: usize) void {
        if (!self.runtime_active) return;
        self.serviceRuntimeRequests(self.page_runtime, top_level_maximum);
        if (self.subdocuments) |*documents| {
            for (documents.entries) |entry| {
                const context = entry orelse continue;
                self.serviceRuntimeRequests(&context.runtime, subdocument_maximum);
            }
            _ = documents.finalizeSettled(self.nowMilliseconds()) catch {};
        }
    }

    fn serviceRuntimeRequests(self: *App, runtime: *r4os.web_runtime.WebRuntime, maximum: usize) void {
        var serviced: usize = 0;
        while (serviced < maximum) : (serviced += 1) {
            const request = runtime.takeRequest() orelse break;
            self.serviceRuntimeRequest(runtime, request);
            _ = runtime.pump(self.nowMilliseconds(), page_runtime_jobs_per_slice) catch {};
        }
    }

    fn serviceRuntimeRequest(self: *App, runtime: *r4os.web_runtime.WebRuntime, request: *r4os.web_runtime.PendingRequest) void {
        if (request.kind != .font) {
            self.fetchRuntimeRequest(runtime, request, self.transport.raw[0..], self.transport.body[0..]);
            return;
        }
        const allocator = self.ctx.sys.allocator();
        const raw = allocator.alloc(u8, font_raw_response_capacity) catch {
            self.font_cache_failures += 1;
            runtime.failRequest(request.id, request.generation, "Font response memory unavailable") catch {};
            return;
        };
        defer allocator.free(raw);
        const body = allocator.alloc(u8, font_response_capacity) catch {
            self.font_cache_failures += 1;
            runtime.failRequest(request.id, request.generation, "Font response memory unavailable") catch {};
            return;
        };
        defer allocator.free(body);
        self.fetchRuntimeRequest(runtime, request, raw, body);
    }

    fn fetchRuntimeRequest(
        self: *App,
        runtime: *r4os.web_runtime.WebRuntime,
        request: *r4os.web_runtime.PendingRequest,
        raw_buffer: []u8,
        body_buffer: []u8,
    ) void {
        const request_id = request.id;
        const generation = request.generation;
        const request_kind = request.kind;
        const request_url = request.url;
        var cookie_context = WebCookieContext{
            .app = self,
            .same_site = runtime.security_context.document_origin.same(&request.target_origin),
            .credentials = request.credentials,
            .request_origin = runtime.security_context.document_origin,
        };
        var authorization_context = WebRequestAuthorizationContext{
            .runtime = runtime,
            .generation = generation,
            .kind = request_kind,
            .mode = request.mode,
        };
        var origin_buffer: [r4os.web_security.max_origin_host_bytes + 24]u8 = undefined;
        const origin_header = runtime.security_context.document_origin.serialize(origin_buffer[0..]) orelse "null";
        if (self.ctx.web) |*web| {
            const result = web.fetch(
                request_url.bytes(),
                raw_buffer,
                body_buffer,
                self.transport.scratch[0..],
                .{
                    .stop = &self.stop_flag,
                    .progress = webProgress,
                    .progress_context = self,
                    .origin = origin_header,
                    .method = request.method,
                    .redirect = switch (request.redirect) {
                        .follow => .follow,
                        .error_mode => .error_mode,
                        .manual => .manual,
                    },
                    .headers = request.requestHeaders(),
                    .body = request.bodyBytes(),
                    .cors = request.mode == .cors,
                    .credentials_include = request.credentials == .include,
                    .cookie_provider = webCookieProvider,
                    .cookie_sink = webCookieSink,
                    .cookie_context = &cookie_context,
                    .target_authorizer = webRequestTargetAuthorizer,
                    .target_authorization_context = &authorization_context,
                },
            );
            switch (result) {
                .response => |response| {
                    runtime.completeRequest(
                        request_id,
                        generation,
                        .{
                            .status = response.status,
                            .secure = response.secure,
                            .content_type = response.content_type orelse "",
                            .content_security_policy = response.content_security_policy orelse "",
                            .headers = response.headers,
                            .redirected = response.redirects > 0,
                            .final_url = response.final_url.bytes(),
                            .access_control_allow_origin = response.access_control_allow_origin orelse "",
                            .access_control_allow_credentials = response.access_control_allow_credentials,
                            .set_cookies = response.set_cookies,
                            .set_cookie_count = response.set_cookie_count,
                            .manual_redirect = response.manual_redirect,
                            .cookies_processed = true,
                        },
                        response.body,
                    ) catch |err| {
                        if (runtime == self.page_runtime and request_kind == .image) self.noteImageFailure(.other, @errorName(err), response.body.len);
                        if (request_kind == .font) self.font_cache_failures += 1;
                        if (err != error.CorsBlocked and err != error.StaleGeneration) self.setStatus(webRuntimeErrorText(err));
                    };
                },
                .failure => |err| {
                    if (runtime == self.page_runtime and request_kind == .image) self.noteImageFailure(.fetch, fetchErrorText(err), 0);
                    if (request_kind == .font) self.font_cache_failures += 1;
                    if (err == .policy_rejected)
                        runtime.failRequestPolicy(request_id, generation, fetchErrorText(err)) catch {}
                    else
                        runtime.failRequest(request_id, generation, fetchErrorText(err)) catch {};
                },
            }
        } else {
            if (request_kind == .font) self.font_cache_failures += 1;
            runtime.failRequest(request_id, generation, "Web transport unavailable") catch {};
        }
    }

    fn pumpPageRuntime(self: *App) void {
        if (!self.runtime_active or self.loading) return;
        const jobs_per_slice = if (self.page_runtime.resourcesSettled()) page_settled_jobs_per_slice else page_runtime_jobs_per_slice;
        self.servicePageRequests();
        var jobs = self.page_runtime.pump(self.nowMilliseconds(), jobs_per_slice) catch 0;
        if (self.subdocuments) |*documents| jobs += documents.pumpFair(self.nowMilliseconds(), jobs_per_slice) catch 0;
        self.document_fonts.reconcile(self.page_runtime, self.fontNowMilliseconds());
        const font_changed = self.document_fonts.publishRevision();
        const resource_changed = self.resource_dirty;
        var action_changed = false;
        var inline_svg_dirty = false;
        self.resource_dirty = false;
        var handled: usize = 0;
        while (handled < 8) : (handled += 1) {
            const action = self.page_runtime.takeAction() orelse break;
            if (action.generation != self.document_generation) continue;
            switch (action.kind) {
                .dom_changed => {
                    action_changed = true;
                    inline_svg_dirty = true;
                },
                .form_submit => {
                    self.submitDocumentForm(action.node);
                    return;
                },
                .navigate, .replace => {
                    self.saveRollback();
                    const accepted = if (action.kind == .replace)
                        self.browser.replaceAfterRedirect(action.url.bytes())
                    else
                        self.browser.navigate(action.url.bytes());
                    if (accepted) self.loadCurrent("Script navigation") else self.has_rollback = false;
                    return;
                },
                .push_state, .replace_state => {
                    const accepted = if (action.kind == .replace_state)
                        self.browser.replaceAfterRedirect(action.url.bytes())
                    else
                        self.browser.pushState(action.url.bytes());
                    if (accepted) {
                        self.address.set(self.browser.currentUrl().bytes());
                        self.page_runtime.document_url = action.url;
                        self.updateTitle();
                        action_changed = true;
                    }
                },
                .reload => {
                    self.saveRollback();
                    self.browser.reload();
                    self.loadCurrent("Script reload");
                    return;
                },
                .back => {
                    self.saveRollback();
                    if (self.browser.back()) self.loadCurrent("Script history back") else self.has_rollback = false;
                    return;
                },
                .forward => {
                    self.saveRollback();
                    if (self.browser.forward()) self.loadCurrent("Script history forward") else self.has_rollback = false;
                    return;
                },
                .traverse => {
                    self.saveRollback();
                    if (self.browser.go(action.delta)) self.loadCurrent("Script history traversal") else self.has_rollback = false;
                    return;
                },
            }
        }
        const dom_changed = self.page_runtime.needsReflow();
        const changed = pageRuntimeNeedsRender(jobs, resource_changed, font_changed, action_changed, dom_changed);
        if (changed) {
            self.transport.view.build(&self.transport.document) catch {};
            if (!self.rebuildStylesheet()) return;
            self.transport.interaction.rebuild(&self.transport.document) catch {};
            if (inline_svg_dirty) self.refreshInlineSvgImages();
            if (!self.rebuildWebFontRegistry()) return;
            self.reflowDocument();
            const sync_activated = self.syncLayoutWebFonts() orelse return;
            if (!self.syncCssBackgroundImages()) return;
            if (sync_activated) self.reflowDocument();
            self.updateTitle();
            self.render();
        }
    }

    fn dispatchPageEvent(self: *App, node: u16, name: []const u8) bool {
        if (!self.runtime_active) return true;
        const dispatch = self.page_runtime.dispatchEvent(.{ .node = node }, name, self.nowMilliseconds()) catch return true;
        _ = self.page_runtime.pump(self.nowMilliseconds(), page_event_jobs_per_slice) catch {};
        return !self.page_runtime.eventCancelled(dispatch.serial);
    }

    fn nowMilliseconds(self: *const App) f64 {
        const frequency = self.ctx.sys.monotonicHz();
        if (frequency == 0) return @floatFromInt(self.ctx.sys.ticks());
        return @as(f64, @floatFromInt(self.ctx.sys.ticks())) * 1000.0 / @as(f64, @floatFromInt(frequency));
    }

    fn fontNowMilliseconds(self: *const App) u64 {
        const value = self.nowMilliseconds();
        if (!std.math.isFinite(value) or value <= 0) return 0;
        if (value >= @as(f64, @floatFromInt(std.math.maxInt(u64)))) return std.math.maxInt(u64);
        return @intFromFloat(value);
    }

    fn pageMonotonicNow(raw_context: ?*anyopaque) f64 {
        const self: *const App = @ptrCast(@alignCast(raw_context orelse return 0));
        return self.nowMilliseconds();
    }

    fn configurePageClock(self: *App) void {
        const state = self.ctx.sys.timeState();
        if (state.valid == 0) return;
        const date_time = r4std.date.fromTimeState(state) orelse return;
        const utc = r4std.date.utcFromDateTime(date_time, 0) orelse return;
        var time_config: r4std.time.Config = .{};
        var config_buffer: [768]u8 = undefined;
        const config_length = self.ctx.sys.fileRead(r4std.settings.paths.time, config_buffer[0..]);
        if (config_length > 0) _ = time_config.loadFromBytes(config_buffer[0..@intCast(config_length)]);
        self.page_runtime.setClockState(
            @as(f64, @floatFromInt(utc.seconds_since_unix_epoch)) * 1000.0,
            self.nowMilliseconds(),
            time_config.offsetMinutesForState(state),
        );
    }

    fn setStatus(self: *App, value: []const u8) void {
        setZ(self.status[0..], value);
    }

    fn visibleStatus(self: *const App) []const u8 {
        const diagnostic = spanZ(self.diagnostic[0..]);
        return if (self.diagnostics_enabled and diagnostic.len > 0) diagnostic else spanZ(self.status[0..]);
    }

    fn toggleDiagnostics(self: *App) void {
        self.diagnostics_enabled = !self.diagnostics_enabled;
        if (self.diagnostics_enabled and self.loaded_media == .html) {
            self.appendImageDiagnostic();
            self.appendFontDiagnostic();
            self.appendPaintDiagnostic();
        }
        self.setStatus(if (self.diagnostics_enabled)
            "Diagnostics shown. Ctrl+D or Trace hides the trace."
        else
            "Diagnostics hidden. Ctrl+D or Trace shows the latest trace.");
    }

    fn captureStatusDiagnostic(self: *App, category: []const u8, value: []const u8) void {
        var len: usize = 0;
        appendLocal(self.diagnostic[0..], &len, category);
        appendLocal(self.diagnostic[0..], &len, ": ");
        appendLocal(self.diagnostic[0..], &len, value);
    }

    fn captureResponseDiagnostic(self: *App, response: r4os.app_web.FetchResponse) void {
        var len: usize = 0;
        appendLocal(self.diagnostic[0..], &len, "HTTP ");
        appendDecimal(self.diagnostic[0..], &len, response.status);
        appendLocal(self.diagnostic[0..], &len, " bytes ");
        appendDecimal(self.diagnostic[0..], &len, response.body.len);
        if (response.redirects > 0) {
            appendLocal(self.diagnostic[0..], &len, " redirects ");
            appendDecimal(self.diagnostic[0..], &len, response.redirects);
        }
        if (response.content_type) |content_type| {
            appendLocal(self.diagnostic[0..], &len, " type ");
            appendLocal(self.diagnostic[0..], &len, content_type);
        }
    }

    fn appendScriptDiagnostic(self: *App) void {
        const script = self.page_runtime.scriptDiagnostics();
        if (script.error_count == 0) return;
        var len = spanZ(self.diagnostic[0..]).len;
        appendLocal(self.diagnostic[0..], &len, " script-errors ");
        appendDecimal(self.diagnostic[0..], &len, script.error_count);
        if (script.error_name.len > 0) {
            appendLocal(self.diagnostic[0..], &len, " ");
            appendLocal(self.diagnostic[0..], &len, diagnosticPhaseText(script.phase));
            appendLocal(self.diagnostic[0..], &len, "/");
            appendLocal(self.diagnostic[0..], &len, script.error_name);
            if (script.line > 0) {
                appendLocal(self.diagnostic[0..], &len, " line ");
                appendDecimal(self.diagnostic[0..], &len, script.line);
            }
        }
    }

    fn appendImageDiagnostic(self: *App) void {
        const failures = self.image_fetch_failures + self.image_format_failures + self.image_decode_failures +
            self.image_memory_failures + self.image_limit_failures + self.image_other_failures;
        if (self.image_loaded_count == 0 and failures == 0 and !self.image_resource_event_valid and !self.image_resource_failure_event_valid) return;
        var len: usize = 0;
        appendLocal(self.diagnostic[0..], &len, "IMG");
        if (self.image_resource_failure_event_valid or self.image_resource_event_valid) {
            const event = if (self.image_resource_failure_event_valid) self.image_resource_failure_event else self.image_resource_event;
            appendLocal(self.diagnostic[0..], &len, " id=");
            appendDecimal(self.diagnostic[0..], &len, event.resource_id);
            appendLocal(self.diagnostic[0..], &len, " role=");
            appendLocal(self.diagnostic[0..], &len, resourceRoleText(event.role));
            appendLocal(self.diagnostic[0..], &len, " node=");
            appendDecimal(self.diagnostic[0..], &len, event.node);
            appendLocal(self.diagnostic[0..], &len, " phase=");
            appendLocal(self.diagnostic[0..], &len, resourcePhaseText(event.phase));
            if (event.failure != .none) {
                appendLocal(self.diagnostic[0..], &len, "/");
                appendLocal(self.diagnostic[0..], &len, resourceFailureText(event.failure));
            }
            if (event.status != 0) {
                appendLocal(self.diagnostic[0..], &len, " http=");
                appendDecimal(self.diagnostic[0..], &len, event.status);
            }
            if (event.content_type.len > 0) {
                appendLocal(self.diagnostic[0..], &len, " mime=");
                appendLocal(self.diagnostic[0..], &len, event.content_type.bytes());
            }
            if (event.byte_count > 0) {
                appendLocal(self.diagnostic[0..], &len, " bytes=");
                appendDecimal(self.diagnostic[0..], &len, event.byte_count);
            }
            if (event.redirected) appendLocal(self.diagnostic[0..], &len, " redirected");
            const requested = event.requested_url.bytes();
            if (requested.len > 0) {
                appendLocal(self.diagnostic[0..], &len, " src=");
                appendLocal(self.diagnostic[0..], &len, requested);
            }
            const final_url = event.final_url.bytes();
            if (final_url.len > 0 and !std.mem.eql(u8, requested, final_url)) {
                appendLocal(self.diagnostic[0..], &len, " final=");
                appendLocal(self.diagnostic[0..], &len, final_url);
            }
        }
        appendLocal(self.diagnostic[0..], &len, " ok=");
        appendDecimal(self.diagnostic[0..], &len, self.image_loaded_count);
        appendLocal(self.diagnostic[0..], &len, " f=");
        appendDecimal(self.diagnostic[0..], &len, self.image_fetch_failures);
        appendLocal(self.diagnostic[0..], &len, " fmt=");
        appendDecimal(self.diagnostic[0..], &len, self.image_format_failures);
        appendLocal(self.diagnostic[0..], &len, " dec=");
        appendDecimal(self.diagnostic[0..], &len, self.image_decode_failures);
        if (self.image_decode_last_bytes > 0) {
            appendLocal(self.diagnostic[0..], &len, "/");
            appendDecimal(self.diagnostic[0..], &len, self.image_decode_last_bytes);
        }
        appendLocal(self.diagnostic[0..], &len, " mem=");
        appendDecimal(self.diagnostic[0..], &len, self.image_memory_failures);
        appendLocal(self.diagnostic[0..], &len, " lim=");
        appendDecimal(self.diagnostic[0..], &len, self.image_limit_failures);
        appendLocal(self.diagnostic[0..], &len, " oth=");
        appendDecimal(self.diagnostic[0..], &len, self.image_other_failures);
        appendLocal(self.diagnostic[0..], &len, " draw=");
        if (self.image_draw_succeeded) {
            appendLocal(self.diagnostic[0..], &len, "ok");
        } else {
            if (self.image_draw_error < 0) appendLocal(self.diagnostic[0..], &len, "-");
            const magnitude: usize = @intCast(if (self.image_draw_error < 0) -self.image_draw_error else self.image_draw_error);
            appendDecimal(self.diagnostic[0..], &len, magnitude);
        }
        const last = spanZ(self.image_last_error[0..]);
        if (last.len > 0) {
            appendLocal(self.diagnostic[0..], &len, " last=");
            appendLocal(self.diagnostic[0..], &len, last);
            appendLocal(self.diagnostic[0..], &len, "/");
            appendDecimal(self.diagnostic[0..], &len, self.image_last_bytes);
        }
    }

    fn appendFontDiagnostic(self: *App) void {
        if (!self.font_resource_event_valid and !self.font_resource_failure_event_valid and
            self.font_cache_hits == 0 and self.font_cache_commits == 0 and self.font_cache_failures == 0) return;
        var len = spanZ(self.diagnostic[0..]).len;
        if (len > 0) appendLocal(self.diagnostic[0..], &len, " ");
        appendLocal(self.diagnostic[0..], &len, "FONT");
        if (self.font_resource_failure_event_valid or self.font_resource_event_valid) {
            const event = if (self.font_resource_failure_event_valid) self.font_resource_failure_event else self.font_resource_event;
            appendLocal(self.diagnostic[0..], &len, " face=");
            appendDecimal(self.diagnostic[0..], &len, event.font_face_index);
            appendLocal(self.diagnostic[0..], &len, " src=");
            appendDecimal(self.diagnostic[0..], &len, event.font_source_index);
            appendLocal(self.diagnostic[0..], &len, " phase=");
            appendLocal(self.diagnostic[0..], &len, resourcePhaseText(event.phase));
            if (event.failure != .none) {
                appendLocal(self.diagnostic[0..], &len, "/");
                appendLocal(self.diagnostic[0..], &len, resourceFailureText(event.failure));
            }
            appendLocal(self.diagnostic[0..], &len, " origin=");
            appendLocal(self.diagnostic[0..], &len, fontSourceOriginText(event.font_source_origin));
            appendLocal(self.diagnostic[0..], &len, " fmt=");
            appendLocal(self.diagnostic[0..], &len, webFontFormatText(event.font_format));
        }
        appendLocal(self.diagnostic[0..], &len, " hit=");
        appendDecimal(self.diagnostic[0..], &len, self.font_cache_hits);
        appendLocal(self.diagnostic[0..], &len, " put=");
        appendDecimal(self.diagnostic[0..], &len, self.font_cache_commits);
        appendLocal(self.diagnostic[0..], &len, " fail=");
        appendDecimal(self.diagnostic[0..], &len, self.font_cache_failures);
    }

    fn appendPaintDiagnostic(self: *App) void {
        var len = spanZ(self.diagnostic[0..]).len;
        if (len > 0) appendLocal(self.diagnostic[0..], &len, " ");
        appendLocal(self.diagnostic[0..], &len, "DRAW frame=");
        appendDecimal(self.diagnostic[0..], &len, self.native_frame_commits);
        appendLocal(self.diagnostic[0..], &len, "/");
        appendDecimal(self.diagnostic[0..], &len, self.native_frame_failures);
        appendLocal(self.diagnostic[0..], &len, " shape=");
        appendDecimal(self.diagnostic[0..], &len, self.native_shape_commands);
        appendLocal(self.diagnostic[0..], &len, " argb=");
        appendDecimal(self.diagnostic[0..], &len, self.native_argb_commands);
        appendLocal(self.diagnostic[0..], &len, " bytes=");
        appendDecimal(self.diagnostic[0..], &len, self.native_resource_bytes);
        appendLocal(self.diagnostic[0..], &len, " reuse=");
        appendDecimal(self.diagnostic[0..], &len, self.native_resource_reuses);
        appendLocal(self.diagnostic[0..], &len, "/");
        appendDecimal(self.diagnostic[0..], &len, self.native_resource_builds);
        if (self.native_paint_stats.last_error < 0) {
            appendLocal(self.diagnostic[0..], &len, " err=-");
            appendDecimal(self.diagnostic[0..], &len, -self.native_paint_stats.last_error);
        }
    }
};

fn resourcePhaseText(phase: r4os.web_runtime.ResourcePhase) []const u8 {
    return switch (phase) {
        .selected => "selected",
        .queued => "queued",
        .fetching => "fetching",
        .response => "response",
        .ready => "ready",
        .failed => "failed",
        .aborted => "aborted",
        .replaced => "replaced",
    };
}

fn fontSourceOriginText(origin: r4os.web_runtime.FontSourceOrigin) []const u8 {
    return switch (origin) {
        .network => "net",
        .local => "local",
        .cache => "cache",
    };
}

fn webFontFormatText(format: r4os.web_fonts.FontFormat) []const u8 {
    return switch (format) {
        .unspecified => "auto",
        .woff2 => "woff2",
        .woff => "woff",
        .truetype => "ttf",
        .opentype => "otf",
        .embedded_opentype => "eot",
        .collection => "ttc",
        .svg => "svg",
        .unknown => "unknown",
    };
}

fn resourceFailureText(failure: r4os.web_runtime.ResourceFailure) []const u8 {
    return switch (failure) {
        .none => "none",
        .selection => "selection",
        .policy => "policy",
        .queue => "queue",
        .fetch => "fetch",
        .http_status => "http",
        .response_limit => "limit",
        .consumer => "consumer",
    };
}

fn resourceRoleText(role: r4os.web_runtime.ImageRole) []const u8 {
    return switch (role) {
        .content => "content",
        .css_background => "css-bg",
    };
}

fn diagnosticPhaseText(phase: r4os.javascript.DiagnosticPhase) []const u8 {
    return switch (phase) {
        .none => "none",
        .parser => "parser",
        .compiler => "compiler",
        .vm => "vm",
        .host => "host",
    };
}

fn webProgress(context: ?*anyopaque) callconv(.c) bool {
    const raw = context orelse return false;
    const app: *App = @ptrCast(@alignCast(raw));
    return app.pumpLoading();
}

fn scriptStopRequested(context: ?*anyopaque) bool {
    const raw = context orelse return false;
    const app: *App = @ptrCast(@alignCast(raw));
    if (@atomicLoad(u32, &app.stop_flag.value, .acquire) != 0 or app.should_exit) return true;
    app.script_checkpoints +%= 1;
    if (app.script_checkpoints % script_yield_interval == 0) {
        _ = app.pumpLoading();
        app.ctx.sys.taskYield();
    }
    return @atomicLoad(u32, &app.stop_flag.value, .acquire) != 0 or app.should_exit;
}

fn localWebFontAvailable(context: ?*anyopaque, probe: r4os.web_runtime.FontSourceProbe) bool {
    const app: *App = @ptrCast(@alignCast(context orelse return false));
    if (probe.source_value.len == 0) return false;
    for (app.font_infos[0..app.font_count]) |*info| {
        if ((info.flags & r4os.abi.gui_font_flag_renderable) == 0) continue;
        if (font_source_match.installedFace(spanZ(info.face[0..]), probe.source_value)) {
            return app.document_fonts.completeLocal(probe.face_index, info.id, app.fontNowMilliseconds());
        }
    }
    return false;
}

fn cachedWebFontAvailable(
    context: ?*anyopaque,
    probe: r4os.web_runtime.FontSourceProbe,
    final_url: *r4os.web_navigation.Url,
) bool {
    const app: *App = @ptrCast(@alignCast(context orelse return false));
    const hit = lookupCachedWebFont(app, probe.request_origin, probe.resolved_url.bytes(), probe.format) orelse return false;
    final_url.* = r4os.web_navigation.parse(hit.final_url.bytes()) catch {
        app.font_cache_failures += 1;
        return false;
    };
    return true;
}

fn lookupCachedWebFont(
    app: *App,
    request_origin_value: r4os.web_security.Origin,
    source_url: []const u8,
    format: r4os.web_fonts.FontFormat,
) ?font_cache_store.LookupResult {
    app.initializeFontCache();
    const store = if (app.font_cache) |*value| value else return null;
    if (source_url.len == 0) return null;
    var origin_buffer: [r4os.web_security.max_origin_host_bytes + 24]u8 = undefined;
    const request_origin = request_origin_value.serialize(origin_buffer[0..]) orelse return null;
    const now = app.cacheNowSeconds();
    var attempt: usize = 0;
    while (attempt < font_cache_busy_retry_limit) : (attempt += 1) {
        const transaction = app.nextFontCacheTransaction();
        const lookup = if (cacheFormatForWebFont(format)) |cache_format|
            store.lookup(request_origin, source_url, cache_format, now, transaction) catch |err| {
                if (err == error.CacheBusy) {
                    app.ctx.sys.taskYield();
                    continue;
                }
                app.font_cache_failures += 1;
                return null;
            }
        else if (format == .unspecified)
            store.lookupAny(request_origin, source_url, now, transaction) catch |err| {
                if (err == error.CacheBusy) {
                    app.ctx.sys.taskYield();
                    continue;
                }
                app.font_cache_failures += 1;
                return null;
            }
        else
            null;
        return lookup;
    }
    app.font_cache_failures += 1;
    return null;
}

fn loadCachedWebFont(
    app: *App,
    completion: r4os.web_runtime.ResourceCompletion,
) ?font_cache_store.OwnedLookupResult {
    const source_url = completion.requested_url.bytes();
    const token = lookupCachedWebFont(app, completion.request_origin, source_url, completion.font_format) orelse return null;
    if (!std.mem.eql(u8, token.final_url.bytes(), completion.final_url.bytes())) {
        app.font_cache_failures += 1;
        return null;
    }
    const store = if (app.font_cache) |*value| value else return null;
    var origin_buffer: [r4os.web_security.max_origin_host_bytes + 24]u8 = undefined;
    const request_origin = completion.request_origin.serialize(origin_buffer[0..]) orelse return null;
    var attempt: usize = 0;
    while (attempt < font_cache_busy_retry_limit) : (attempt += 1) {
        const loaded = store.loadAuthorized(
            app.ctx.sys.allocator(),
            request_origin,
            source_url,
            token,
            app.cacheNowSeconds(),
            app.nextFontCacheTransaction(),
        ) catch |err| {
            if (err == error.CacheBusy) {
                app.ctx.sys.taskYield();
                continue;
            }
            app.font_cache_failures += 1;
            return null;
        };
        if (loaded != null) app.font_cache_hits += 1;
        return loaded;
    }
    app.font_cache_failures += 1;
    return null;
}

fn cacheFormatForWebFont(format: r4os.web_fonts.FontFormat) ?r4os.web_font_cache.FontFormat {
    return switch (format) {
        .woff => .woff,
        .woff2 => .woff2,
        .truetype => .truetype,
        .opentype => .opentype,
        else => null,
    };
}

fn completeWebFont(app: *App, completion: r4os.web_runtime.ResourceCompletion) bool {
    if (completion.font_source_origin == .cache) {
        var loaded = loadCachedWebFont(app, completion) orelse return false;
        defer loaded.deinit(app.ctx.sys.allocator());
        const staged = app.document_fonts.stageBytes(completion.font_face_index, loaded.bytes) catch {
            app.font_cache_failures += 1;
            return false;
        };
        if (staged) _ = app.document_fonts.completeStaged(completion.font_face_index, app.fontNowMilliseconds());
        return true;
    }
    if (completion.body.len == 0 or completion.body.len > font_response_capacity) {
        app.font_cache_failures += 1;
        return false;
    }
    const source_url = completion.requested_url.bytes();
    if (source_url.len == 0) {
        app.font_cache_failures += 1;
        return false;
    }
    const mime = normalizedFontMime(completion.content_type);
    const concrete = font_cache_store.detectFormat(
        completion.font_format,
        mime,
        completion.final_url.bytes(),
        completion.body,
    ) catch {
        app.font_cache_failures += 1;
        return false;
    };
    var staged = app.document_fonts.stageBytes(completion.font_face_index, completion.body) catch {
        app.font_cache_failures += 1;
        return false;
    };
    defer if (staged) app.document_fonts.discardStaged(completion.font_face_index);

    while (app.font_cache == null and !app.font_cache_disabled) {
        app.initializeFontCache();
        if (app.font_cache != null) break;
        if (!app.waitForFontCacheLease(completion.generation)) return false;
    }
    const store = if (app.font_cache) |*value| value else {
        app.font_cache_failures += 1;
        activateStagedWebFont(app, completion.font_face_index, &staged);
        return true;
    };
    const now = app.cacheNowSeconds();
    var origin_buffer: [r4os.web_security.max_origin_host_bytes + 24]u8 = undefined;
    const request_origin = completion.request_origin.serialize(origin_buffer[0..]) orelse {
        app.font_cache_failures += 1;
        activateStagedWebFont(app, completion.font_face_index, &staged);
        return true;
    };
    while (true) {
        _ = store.commit(
            completion.body,
            request_origin,
            source_url,
            completion.final_url.bytes(),
            mime,
            concrete,
            now,
            app.nextFontCacheTransaction(),
        ) catch |err| {
            if (err == error.CacheBusy) {
                if (!app.waitForFontCacheLease(completion.generation)) return false;
                continue;
            }
            app.font_cache_failures += 1;
            activateStagedWebFont(app, completion.font_face_index, &staged);
            return true;
        };
        app.font_cache_commits += 1;
        activateStagedWebFont(app, completion.font_face_index, &staged);
        return true;
    }
}

fn activateStagedWebFont(app: *App, face_index: u16, staged: *bool) void {
    if (!staged.*) return;
    _ = app.document_fonts.completeStaged(face_index, app.fontNowMilliseconds());
    staged.* = false;
}

fn normalizedFontMime(raw: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, raw, ';') orelse raw.len;
    const media_type = std.mem.trim(u8, raw[0..end], " \t\r\n");
    return if (media_type.len > 0) media_type else "application/octet-stream";
}

fn completePageResource(context: ?*anyopaque, completion: r4os.web_runtime.ResourceCompletion) bool {
    const app: *App = @ptrCast(@alignCast(context orelse return false));
    const top_level = completion.generation == app.document_generation;
    if (!top_level) {
        const documents = if (app.subdocuments) |*value| value else return false;
        if (documents.findGeneration(completion.generation) == null) return false;
    }
    switch (completion.kind) {
        .stylesheet => {
            if (completion.body.len == 0) return false;
            if (!top_level) return true;
            if (app.transport.external_style_count >= app.transport.external_style_records.len) return false;
            if (completion.body.len > app.transport.external_styles.len -| app.transport.external_styles_len) return false;
            app.transport.stylesheet.appendWithBase(completion.body, completion.final_url.bytes()) catch return false;
            const start = app.transport.external_styles_len;
            @memcpy(app.transport.external_styles[start .. start + completion.body.len], completion.body);
            app.transport.external_styles_len += completion.body.len;
            app.transport.external_style_records[app.transport.external_style_count] = .{
                .offset = @intCast(start),
                .len = @intCast(completion.body.len),
                .final_url = completion.final_url,
            };
            app.transport.external_style_count += 1;
            app.resource_dirty = true;
            return true;
        },
        .image => {
            if (!top_level) {
                _ = app.ctx.image.probe(completion.body, completion.content_type) catch return false;
                return true;
            }
            return app.completePageImage(completion);
        },
        // Child documents do not own a visual layout yet and therefore have
        // no used-font demand set.  Never let a future child completion mutate
        // the top-level document owner; its runtime will continue SRC fallback.
        .font => return if (top_level) completeWebFont(app, completion) else false,
        .subdocument => return app.loadSubdocument(completion),
        .script => return false,
    }
}

fn observePageResource(context: ?*anyopaque, event: r4os.web_runtime.ResourceEvent) void {
    const app: *App = @ptrCast(@alignCast(context orelse return));
    if (event.kind == .font and event.generation == app.document_generation) {
        app.font_resource_event = event;
        app.font_resource_event_valid = true;
        if (event.phase == .failed) {
            app.font_resource_failure_event = event;
            app.font_resource_failure_event_valid = true;
        }
        return;
    }
    if (event.kind != .image or event.generation != app.document_generation) return;
    const role = layoutImageRole(event.role);
    app.image_resource_event = event;
    app.image_resource_event_valid = true;
    if (event.phase == .failed) {
        app.image_resource_failure_event = event;
        app.image_resource_failure_event_valid = true;
    }

    switch (event.phase) {
        .selected, .queued, .fetching, .response => {
            if (app.pageImageForRole(event.node, role) == null) {
                const entry = app.pageImageSlotForRole(event.generation, event.node, role) orelse return;
                entry.* = .{ .used = true, .generation = event.generation, .resource_id = event.resource_id, .node = event.node, .role = role, .state = .loading };
            }
        },
        .replaced => {
            if (app.pageImageForRole(event.node, role)) |entry| app.releasePageImage(entry);
            const replacement = app.pageImageSlotForRole(event.generation, event.node, role) orelse return;
            replacement.* = .{ .used = true, .generation = event.generation, .resource_id = event.resource_id, .node = event.node, .role = role, .state = .loading };
        },
        .aborted => {
            if (app.pageImageForRole(event.node, role)) |entry| app.releasePageImage(entry);
            app.resource_dirty = true;
        },
        .failed => {
            const entry = app.pageImageForRole(event.node, role) orelse app.pageImageSlotForRole(event.generation, event.node, role) orelse return;
            if (!entry.used) entry.* = .{ .used = true, .generation = event.generation, .resource_id = event.resource_id, .node = event.node, .role = role };
            entry.state = .failed;
            app.resource_dirty = true;
        },
        .ready => {},
    }
}

fn layoutImageRole(role: r4os.web_runtime.ImageRole) r4os.web_layout.ImageRole {
    return switch (role) {
        .content => .content,
        .css_background => .css_background,
    };
}

fn viewportSizeChanged(previous_w: i32, previous_h: i32, next_w: i32, next_h: i32) bool {
    return previous_w != next_w or previous_h != next_h;
}

test "duplicate resize events do not invalidate the document viewport" {
    try std.testing.expect(!viewportSizeChanged(800, 600, 800, 600));
    try std.testing.expect(viewportSizeChanged(800, 600, 801, 600));
    try std.testing.expect(viewportSizeChanged(800, 600, 800, 601));
}

test "consecutive mouse moves coalesce to the latest position" {
    var pending = PendingMouseMove{};
    try std.testing.expect(pending.take() == null);
    pending.note(10, 20);
    pending.note(30, 40);
    const move = pending.take().?;
    try std.testing.expectEqual(@as(i32, 30), move.x);
    try std.testing.expectEqual(@as(i32, 40), move.y);
    try std.testing.expect(pending.take() == null);
}

fn pageRuntimeNeedsRender(
    completed_jobs: usize,
    resource_changed: bool,
    font_changed: bool,
    action_changed: bool,
    dom_changed: bool,
) bool {
    // Executing a timer, promise or other JavaScript job does not by itself
    // alter visible state.  The runtime reports DOM mutations separately.
    _ = completed_jobs;
    return resource_changed or font_changed or action_changed or dom_changed;
}

fn pageLoopSleepMilliseconds(runtime_active: bool, loading: bool, resources_settled: bool) u64 {
    // Loading remains responsive to transport/resource progress. Once the
    // initial document is complete, untrusted recurring timers receive a
    // bounded foreground cadence so they cannot starve the desktop.
    return if (runtime_active and !loading and resources_settled) page_settled_loop_sleep_ms else page_loop_sleep_ms;
}

test "JavaScript jobs alone do not trigger a page reflow and repaint" {
    try std.testing.expect(page_loop_sleep_ms > 0);
    try std.testing.expect(page_runtime_jobs_per_slice < 32);
    try std.testing.expect(page_resource_requests_per_slice < 16);
    try std.testing.expect(!pageRuntimeNeedsRender(32, false, false, false, false));
    try std.testing.expect(pageRuntimeNeedsRender(0, true, false, false, false));
    try std.testing.expect(pageRuntimeNeedsRender(0, false, true, false, false));
    try std.testing.expect(pageRuntimeNeedsRender(0, false, false, true, false));
    try std.testing.expect(pageRuntimeNeedsRender(0, false, false, false, true));
}

test "settled documents throttle recurring script work without slowing loading" {
    try std.testing.expect(page_settled_loop_sleep_ms > page_loop_sleep_ms);
    try std.testing.expect(page_settled_jobs_per_slice < page_runtime_jobs_per_slice);
    try std.testing.expectEqual(page_loop_sleep_ms, pageLoopSleepMilliseconds(false, false, true));
    try std.testing.expectEqual(page_loop_sleep_ms, pageLoopSleepMilliseconds(true, true, true));
    try std.testing.expectEqual(page_loop_sleep_ms, pageLoopSleepMilliseconds(true, false, false));
    try std.testing.expectEqual(page_settled_loop_sleep_ms, pageLoopSleepMilliseconds(true, false, true));
}

fn cssStyleForRenderOp(op: r4os.web_layout.RenderOp) r4os.css.ComputedStyle {
    return .{
        .font_family = op.font_family,
        .font_size = op.font_size,
        .font_weight = op.font_weight,
        .italic = op.italic,
        .line_height = @max(1, op.font_line_height),
    };
}

fn resolveLayoutFont(
    context: ?*anyopaque,
    family: []const u8,
    size: i32,
    weight: u16,
    italic: bool,
    codepoint: ?u32,
) r4os.web_layout.FontFace {
    const app: *App = @ptrCast(@alignCast(context orelse return .{}));
    return app.document_fonts.resolve(
        &app.transport.font_registry,
        app.fontCatalog(),
        family,
        size,
        weight,
        italic,
        codepoint,
    );
}

fn layoutFontSupports(context: ?*anyopaque, font_id: u32, codepoint: u32) bool {
    const app: *App = @ptrCast(@alignCast(context orelse return false));
    if (document_fonts.isTemporaryId(font_id)) return app.document_fonts.glyphIndex(font_id, codepoint) != null;
    return app.cachedFontSupports(font_id, codepoint);
}

fn measureLayoutFont(context: ?*anyopaque, font_id: u32, value: []const u8) r4os.web_layout.TextMetrics {
    const app: *App = @ptrCast(@alignCast(context orelse return .{}));
    if (document_fonts.isTemporaryId(font_id)) return app.document_fonts.measure(font_id, value);
    if (value.len == 0) return .{ .valid = true };
    var result = r4os.web_layout.TextMetrics{ .valid = true };
    var buffer: [1025]u8 = undefined;
    var cursor: usize = 0;
    while (cursor < value.len) {
        var end = @min(value.len, cursor + buffer.len - 1);
        if (end < value.len) {
            while (end > cursor and (value[end] & 0xC0) == 0x80) end -= 1;
            if (end == cursor) end = @min(value.len, cursor + utf8SequenceLength(value, cursor));
        }
        setZ(buffer[0..], value[cursor..end]);
        var metrics: r4os.abi.GuiTextMetrics = .{};
        if (app.ctx.draw.fontMeasure(font_id, @ptrCast(buffer[0..].ptr), &metrics) < 0) return .{};
        const width: i32 = @intCast(@min(metrics.width, @as(u32, std.math.maxInt(i32))));
        result.width = std.math.add(i32, result.width, width) catch std.math.maxInt(i32);
        result.height = @max(result.height, @as(i32, @intCast(@min(metrics.height, @as(u32, std.math.maxInt(i32))))));
        result.line_height = @max(result.line_height, @as(i32, @intCast(@min(metrics.line_height, @as(u32, std.math.maxInt(i32))))));
        result.baseline = @max(result.baseline, metrics.baseline);
        result.visible_bytes += @min(end - cursor, @as(usize, metrics.visible_bytes));
        cursor = end;
    }
    return result;
}

fn resolvePageImage(context: ?*anyopaque, node: u16) r4os.web_layout.ImageIntrinsic {
    const app: *App = @ptrCast(@alignCast(context orelse return .{}));
    const entry = app.pageImage(node) orelse return .{};
    return .{
        .state = entry.state,
        .width = if (entry.state == .ready) entry.info.width else 0,
        .height = if (entry.state == .ready) entry.info.height else 0,
    };
}

fn resolvePageImageRole(context: ?*anyopaque, node: u16, role: r4os.web_layout.ImageRole) r4os.web_layout.ImageIntrinsic {
    const app: *App = @ptrCast(@alignCast(context orelse return .{}));
    const entry = app.pageImageForRole(node, role) orelse return .{};
    return .{
        .state = entry.state,
        .width = entry.info.width,
        .height = entry.info.height,
    };
}

fn svgGlyphRow(context: ?*anyopaque, codepoint: u32, row: u32) callconv(.c) u64 {
    const glyph_context: *const SvgGlyphContext = @ptrCast(@alignCast(context orelse return 0));
    return glyph_context.app.ctx.draw.fontGlyphRow(glyph_context.font_id, codepoint, row);
}

fn svgLinkRegion(context: ?*anyopaque, node: u16, x: i32, y: i32, width: i32, height: i32) callconv(.c) void {
    const entry: *PageImage = @ptrCast(@alignCast(context orelse return));
    if (node == r4os.html.none or width <= 0 or height <= 0) return;
    var index: usize = 0;
    while (index < entry.svg_link_count) : (index += 1) {
        const region = &entry.svg_links[index];
        if (region.node != node) continue;
        const right = @max(region.x + region.w, x + width);
        const bottom = @max(region.y + region.h, y + height);
        region.x = @min(region.x, x);
        region.y = @min(region.y, y);
        region.w = right - region.x;
        region.h = bottom - region.y;
        return;
    }
    if (entry.svg_link_count >= entry.svg_links.len) {
        entry.svg_link_overflow = true;
        return;
    }
    entry.svg_links[entry.svg_link_count] = .{ .node = node, .x = x, .y = y, .w = width, .h = height };
    entry.svg_link_count += 1;
}

fn drawImagePlaceholder(canvas: r4os.gui.Canvas, target: r4os.gui.Rect, clipped: r4os.gui.Rect, background: u32) void {
    _ = canvas.rect(clipped, background);
    if (target.w <= 1 or target.h <= 1) return;
    const border = r4os.gui.default_palette.face_shadow;
    _ = canvas.rect(intersectRect(.{ .x = target.x, .y = target.y, .w = target.w, .h = 1 }, clipped), border);
    _ = canvas.rect(intersectRect(.{ .x = target.x, .y = target.y + target.h - 1, .w = target.w, .h = 1 }, clipped), border);
    _ = canvas.rect(intersectRect(.{ .x = target.x, .y = target.y, .w = 1, .h = target.h }, clipped), border);
    _ = canvas.rect(intersectRect(.{ .x = target.x + target.w - 1, .y = target.y, .w = 1, .h = target.h }, clipped), border);
}

fn webBackgroundRadii(source: r4os.web_layout.PixelRadii) r4os.web_background.Radii {
    return .{
        .top_left = .{ .x = @intCast(@max(0, source.top_left.x)), .y = @intCast(@max(0, source.top_left.y)) },
        .top_right = .{ .x = @intCast(@max(0, source.top_right.x)), .y = @intCast(@max(0, source.top_right.y)) },
        .bottom_right = .{ .x = @intCast(@max(0, source.bottom_right.x)), .y = @intCast(@max(0, source.bottom_right.y)) },
        .bottom_left = .{ .x = @intCast(@max(0, source.bottom_left.x)), .y = @intCast(@max(0, source.bottom_left.y)) },
    };
}

fn scaleExtent(value: u32, scale: u32) u32 {
    if (value == 0 or scale == 0) return 0;
    return @intCast((@as(u64, value) + scale - 1) / scale);
}

fn scalePosition(value: i32, scale: u32) i32 {
    if (scale == 0) return value;
    return @intCast(@divFloor(@as(i64, value), @as(i64, scale)));
}

fn scaleBackgroundRadii(source: r4os.web_background.Radii, scale: u32) r4os.web_background.Radii {
    return .{
        .top_left = .{ .x = scaleExtent(source.top_left.x, scale), .y = scaleExtent(source.top_left.y, scale) },
        .top_right = .{ .x = scaleExtent(source.top_right.x, scale), .y = scaleExtent(source.top_right.y, scale) },
        .bottom_right = .{ .x = scaleExtent(source.bottom_right.x, scale), .y = scaleExtent(source.bottom_right.y, scale) },
        .bottom_left = .{ .x = scaleExtent(source.bottom_left.x, scale), .y = scaleExtent(source.bottom_left.y, scale) },
    };
}

/// Raster CSS tiles must retain straight alpha until web_background composites
/// them over the element background.  The ordinary image scaler intentionally
/// flattens alpha for the RGB-only R4DRAW path and therefore cannot be reused.
fn scaleArgbTile(entry: *const PageImage, destination: []u32, width: u32, height: u32) bool {
    if (width == 0 or height == 0 or entry.info.width == 0 or entry.info.height == 0) return false;
    const source_count = entry.info.pixelCount() catch return false;
    const destination_count = std.math.mul(usize, width, height) catch return false;
    if (entry.pixels.len < source_count or destination.len < destination_count) return false;

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const source_y: u32 = @intCast(@min(
            @as(u64, entry.info.height - 1),
            ((@as(u64, y) * 2 + 1) * entry.info.height) / (@as(u64, height) * 2),
        ));
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const source_x: u32 = @intCast(@min(
                @as(u64, entry.info.width - 1),
                ((@as(u64, x) * 2 + 1) * entry.info.width) / (@as(u64, width) * 2),
            ));
            destination[@as(usize, y) * width + x] = entry.pixels[@as(usize, source_y) * entry.info.width + source_x];
        }
    }
    return true;
}

fn cssBackgroundStyleHash(op: r4os.web_layout.RenderOp) u64 {
    var hash: u64 = 14695981039346656037;
    cssBackgroundHashSlice(&hash, op.css_background.raw_value);
    cssBackgroundHashSlice(&hash, op.css_background.base_url);
    cssBackgroundHashWord(&hash, @intFromEnum(op.css_background.repeat));
    cssBackgroundHashLength(&hash, op.css_background.position.x);
    cssBackgroundHashLength(&hash, op.css_background.position.y);
    cssBackgroundHashWord(&hash, @intFromEnum(op.css_background.size.kind));
    cssBackgroundHashLength(&hash, op.css_background.size.width);
    cssBackgroundHashLength(&hash, op.css_background.size.height);
    cssBackgroundHashWord(&hash, @as(u32, @bitCast(op.radii.top_left.x)));
    cssBackgroundHashWord(&hash, @as(u32, @bitCast(op.radii.top_left.y)));
    cssBackgroundHashWord(&hash, @as(u32, @bitCast(op.radii.top_right.x)));
    cssBackgroundHashWord(&hash, @as(u32, @bitCast(op.radii.top_right.y)));
    cssBackgroundHashWord(&hash, @as(u32, @bitCast(op.radii.bottom_right.x)));
    cssBackgroundHashWord(&hash, @as(u32, @bitCast(op.radii.bottom_right.y)));
    cssBackgroundHashWord(&hash, @as(u32, @bitCast(op.radii.bottom_left.x)));
    cssBackgroundHashWord(&hash, @as(u32, @bitCast(op.radii.bottom_left.y)));
    return hash;
}

fn cssBackgroundFailureKey(style_hash: u64, width: u32, height: u32, background: u32, pixel_budget: usize) u64 {
    var hash = style_hash;
    cssBackgroundHashWord(&hash, width);
    cssBackgroundHashWord(&hash, height);
    cssBackgroundHashWord(&hash, background);
    cssBackgroundHashWord(&hash, @intCast(pixel_budget));
    return hash;
}

fn cssBackgroundHashLength(hash: *u64, value: r4os.css.Length) void {
    cssBackgroundHashWord(hash, @intFromEnum(value.kind));
    cssBackgroundHashWord(hash, @as(u32, @bitCast(value.value)));
    cssBackgroundHashWord(hash, @as(u32, @bitCast(value.calc_px)));
    cssBackgroundHashWord(hash, @as(u32, @bitCast(value.calc_percent)));
    cssBackgroundHashWord(hash, @as(u32, @bitCast(value.calc_em)));
    cssBackgroundHashWord(hash, @as(u32, @bitCast(value.calc_rem)));
    cssBackgroundHashWord(hash, @as(u32, @bitCast(value.calc_vw)));
    cssBackgroundHashWord(hash, @as(u32, @bitCast(value.calc_vh)));
}

fn cssBackgroundHashSlice(hash: *u64, value: []const u8) void {
    cssBackgroundHashWord(hash, @intCast(value.len));
    for (value) |byte| cssBackgroundHashByte(hash, byte);
}

fn cssBackgroundHashWord(hash: *u64, value: u64) void {
    var remaining = value;
    var index: usize = 0;
    while (index < @sizeOf(u64)) : (index += 1) {
        cssBackgroundHashByte(hash, @truncate(remaining));
        remaining >>= 8;
    }
}

fn cssBackgroundHashByte(hash: *u64, value: u8) void {
    hash.* = (hash.* ^ value) *% 1099511628211;
}

fn shadowBounds(target: r4os.gui.Rect, shadow: r4os.web_layout.ShadowVisual) r4os.gui.Rect {
    if (!shadow.enabled or shadow.inset) return target;
    const expansion = @max(0, shadow.spread + shadow.blur);
    return .{
        .x = target.x + shadow.offset_x - expansion,
        .y = target.y + shadow.offset_y - expansion,
        .w = target.w + expansion * 2,
        .h = target.h + expansion * 2,
    };
}

fn blendRgb(foreground: u32, background: u32, alpha: u8) u32 {
    const inverse: u32 = 255 - alpha;
    const red = (((foreground >> 16) & 0xFF) * alpha + ((background >> 16) & 0xFF) * inverse + 127) / 255;
    const green = (((foreground >> 8) & 0xFF) * alpha + ((background >> 8) & 0xFF) * inverse + 127) / 255;
    const blue = ((foreground & 0xFF) * alpha + (background & 0xFF) * inverse + 127) / 255;
    return (red << 16) | (green << 8) | blue;
}

fn inspectFrame(context: ?*anyopaque, parent_origin: r4os.web_security.Origin, parent_generation: u32, node: u16) ?r4os.web_runtime.FrameInfo {
    const app: *App = @ptrCast(@alignCast(context orelse return null));
    const documents = if (app.subdocuments) |*value| value else return null;
    const child = documents.find(parent_generation, node) orelse return null;
    const same_origin = parent_origin.same(&child.runtime.security_context.document_origin);
    return .{
        .url = child.url,
        .same_origin = same_origin,
        .complete = child.finalized,
        .document = if (same_origin) &child.document else null,
        .runtime = if (same_origin) &child.runtime else null,
    };
}

fn pageProgramAllocator(app: *App) r4os.web_runtime.ProgramAllocator {
    return .{
        .context = @ptrCast(app),
        .create = createPageProgram,
        .destroy = destroyPageProgram,
        .allocate = allocatePageRuntimeMemory,
        .free = freePageRuntimeMemory,
    };
}

fn createPageProgram(context: *anyopaque) ?*r4os.javascript.Program {
    const app: *App = @ptrCast(@alignCast(context));
    return app.ctx.sys.allocator().create(r4os.javascript.Program) catch null;
}

fn destroyPageProgram(context: *anyopaque, program: *r4os.javascript.Program) void {
    const app: *App = @ptrCast(@alignCast(context));
    app.ctx.sys.allocator().destroy(program);
}

fn allocatePageRuntimeMemory(context: *anyopaque, length: usize, alignment: usize) ?[*]u8 {
    const app: *App = @ptrCast(@alignCast(context));
    return app.ctx.sys.allocator().rawAlloc(length, .fromByteUnits(alignment), @returnAddress());
}

fn freePageRuntimeMemory(context: *anyopaque, memory: [*]u8, length: usize, alignment: usize) void {
    const app: *App = @ptrCast(@alignCast(context));
    app.ctx.sys.allocator().rawFree(memory[0..length], .fromByteUnits(alignment), @returnAddress());
}

fn ensureBrowserDirectory(files: *const r4os.Files, path_text: []const u8) void {
    const path = r4os.AbsoluteFilePath.parse(path_text) catch return;
    _ = files.createDirectory(path.asZ());
}

fn ensureBrowserDataLayout(files: *const r4os.Files) void {
    ensureBrowserDirectory(files, r4std.settings.paths.sys_dir);
    ensureBrowserDirectory(files, r4std.settings.paths.config_dir);
    ensureBrowserDirectory(files, r4std.settings.paths.apps_dir);
    ensureBrowserDirectory(files, storage_layout.app_data_root);
    ensureBrowserDirectory(files, storage_layout.browser_data_root);
    ensureBrowserDirectory(files, storage_layout.profile_dir);
    ensureBrowserDirectory(files, storage_layout.temp_root);
    ensureBrowserDirectory(files, storage_layout.temp_dir);
    ensureBrowserDirectory(files, storage_layout.cache_dir);
    ensureBrowserDirectory(files, storage_layout.work_dir);
    ensureBrowserDirectory(files, storage_layout.font_cache_dir);
    ensureBrowserDirectory(files, storage_layout.font_objects_dir);
    ensureBrowserDirectory(files, storage_layout.font_staging_dir);

    const settings_path = r4os.AbsoluteFilePath.parse(storage_layout.settings_path) catch return;
    if (files.info(settings_path.asZ()) != .missing) return;
    var bytes: [128]u8 = .{0} ** 128;
    var writer = r4std.settings.Writer.init(bytes[0..]);
    writer.writeHeader("KLICKIFAX");
    if (!writer.ok()) return;
    _ = files.write(settings_path.asZ(), writer.bytes());
}

fn loadStorageFile(files: *const r4os.Files, path_text: []const u8, storage: *r4os.web_security.BrowserStorage, buffer: []u8) bool {
    const path = r4os.AbsoluteFilePath.parse(path_text) catch return false;
    switch (files.read(path.asZ(), buffer)) {
        .bytes => |count| {
            storage.decode(buffer[0..count]) catch {
                storage.reset();
                return false;
            };
            return true;
        },
        .end, .failure => return false,
    }
}

fn transferByteCount(transfer: r4os.app_storage.Transfer) ?usize {
    return switch (transfer) {
        .bytes => |count| count,
        .end, .failure => null,
    };
}

fn migrateLegacyBrowserStorage(files: *const r4os.Files, allocator: std.mem.Allocator, source: []const u8) void {
    const profile_path = r4os.AbsoluteFilePath.parse(storage_layout.profile_storage_path) catch return;
    const legacy_path = r4os.AbsoluteFilePath.parse(storage_layout.legacy_storage_path) catch return;
    const written = transferByteCount(files.write(profile_path.asZ(), source));
    const verify_buffer = allocator.alloc(u8, source.len) catch return;
    defer allocator.free(verify_buffer);
    const verified = switch (files.read(profile_path.asZ(), verify_buffer)) {
        .bytes => |count| verify_buffer[0..count],
        .end, .failure => null,
    };
    if (storage_layout.migrationVerified(source, written, verified)) _ = files.delete(legacy_path.asZ());
}

fn loadBrowserStorage(files: *const r4os.Files, allocator: std.mem.Allocator, storage: *r4os.web_security.BrowserStorage, buffer: []u8) void {
    const profile_valid = loadStorageFile(files, storage_layout.profile_storage_path, storage, buffer);
    if (storage_layout.chooseLoadSource(profile_valid, false) == .profile) return;
    storage.reset();
    const legacy_valid = loadStorageFile(files, storage_layout.legacy_storage_path, storage, buffer);
    if (storage_layout.chooseLoadSource(false, legacy_valid) != .legacy) return;
    const legacy_path = r4os.AbsoluteFilePath.parse(storage_layout.legacy_storage_path) catch return;
    const count = switch (files.read(legacy_path.asZ(), buffer)) {
        .bytes => |value| value,
        .end, .failure => return,
    };
    migrateLegacyBrowserStorage(files, allocator, buffer[0..count]);
}

fn saveBrowserStorage(files: *const r4os.Files, storage: *const r4os.web_security.BrowserStorage, buffer: []u8) void {
    const path = r4os.AbsoluteFilePath.parse(storage_layout.profile_storage_path) catch return;
    const bytes = storage.encode(buffer) catch return;
    _ = files.write(path.asZ(), bytes);
}

fn localSearchFixture() []const u8 {
    return "<!doctype html><html><head><title>Local Search</title>" ++
        "<style>body{font-family:sans-serif;color:#202020}h1{color:#000080}" ++
        "form{margin:12px 0;padding:10px;border-width:1px;border-color:#808080;background:#eeeeee}" ++
        "input{width:260px}input:focus{color:#000080}button{margin-left:8px}" ++
        "a{color:#0000cc}</style></head><body><h1>Local Search</h1>" ++
        "<p>Enter a term and submit the real HTML GET form.</p>" ++
        "<form action='about:search-results' method=get>" ++
        "<label>Search: <input type=search name=q placeholder='Search terms'></label>" ++
        "<button type=submit name=submit value=Search>Search</button></form>" ++
        "<p id=runtime-state>JavaScript pending</p>" ++
        "<p><a href='about:fixture-one'>Open navigation fixture one</a></p>" ++
        "<script>document.getElementById('runtime-state').textContent='JavaScript web runtime active';" ++
        "sessionStorage.setItem('klickifax-fixture','active');</script>" ++
        "</body></html>";
}

fn localResultsFixture(url: []const u8, out: []u8) []const u8 {
    var query: [r4os.web_forms.max_value_bytes + 1]u8 = .{0} ** (r4os.web_forms.max_value_bytes + 1);
    const query_len = decodeQueryParameter(url, "q", query[0..]);
    var len: usize = 0;
    appendBuffer(out, &len, "<!doctype html><html><head><title>Local Search Results</title>" ++
        "<style>body{font-family:sans-serif;color:#202020}h1{color:#000080}" ++
        "a{color:#0000cc}li{margin:10px 0}.excerpt{color:#505050}</style></head><body>" ++
        "<h1>Local Search Results</h1><p>Results for <strong>");
    appendHtmlEscaped(out, &len, if (query_len > 0) query[0..query_len] else "(empty query)");
    appendBuffer(out, &len, "</strong></p><ol>" ++
        "<li><a href='about:fixture-one'>R4OS local fixture one</a>" ++
        "<p class=excerpt>Deterministic first result for navigation and history tests.</p></li>" ++
        "<li><a href='about:fixture-two'>R4OS local fixture two</a>" ++
        "<p class=excerpt>Second result used to verify Back, Forward and Reload.</p></li>" ++
        "<li><a href='about:search'>Search again</a>" ++
        "<p class=excerpt>Returns to the keyboard-accessible GET form.</p></li>" ++
        "</ol></body></html>");
    return out[0..len];
}

fn webUrlPath(url: []const u8) []const u8 {
    const scheme = std.mem.indexOf(u8, url, "://") orelse return "/";
    const authority_start = scheme + 3;
    const start = std.mem.indexOfScalarPos(u8, url, authority_start, '/') orelse return "/";
    const end = std.mem.indexOfAnyPos(u8, url, start, "?#") orelse url.len;
    return url[start..end];
}

fn webCookieProvider(raw_context: ?*anyopaque, url: []const u8, out: []u8) []const u8 {
    const context: *WebCookieContext = @ptrCast(@alignCast(raw_context orelse return ""));
    if (!context.enabled) return "";
    const origin = r4os.web_security.Origin.parse(url, context.app.document_generation) catch return "";
    if (context.credentials) |credentials| {
        const request_origin = context.request_origin orelse context.app.page_runtime.security_context.document_origin;
        if (credentials == .omit or (credentials == .same_origin and !request_origin.same(&origin))) return "";
    }
    const same_site = if (context.credentials != null) (context.request_origin orelse context.app.page_runtime.security_context.document_origin).same(&origin) else context.same_site;
    return context.app.browser_storage.cookies.writeRequestHeader(
        &origin,
        webUrlPath(url),
        same_site,
        out,
    );
}

fn webCookieSink(raw_context: ?*anyopaque, url: []const u8, header: []const u8) void {
    const context: *WebCookieContext = @ptrCast(@alignCast(raw_context orelse return));
    if (!context.enabled) return;
    const origin = r4os.web_security.Origin.parse(url, context.app.document_generation) catch return;
    if (context.credentials) |credentials| {
        const request_origin = context.request_origin orelse context.app.page_runtime.security_context.document_origin;
        if (credentials == .omit or (credentials == .same_origin and !request_origin.same(&origin))) return;
    }
    context.app.browser_storage.cookies.setFromHeader(&origin, webUrlPath(url), header) catch {};
}

fn webRequestTargetAuthorizer(raw_context: ?*anyopaque, url: []const u8) bool {
    const context: *WebRequestAuthorizationContext = @ptrCast(@alignCast(raw_context orelse return false));
    return context.runtime.authorizeRequestTarget(
        context.generation,
        context.kind,
        context.mode,
        url,
    );
}

fn documentMetaCsp(document: *const r4os.html.Document) []const u8 {
    var index: usize = 0;
    while (index < document.node_count) : (index += 1) {
        const node: u16 = @intCast(index);
        if (document.nodes[node].kind != .element or !equalsIgnoreCase(document.nodeName(node), "meta")) continue;
        const equiv = document.attribute(node, "http-equiv") orelse continue;
        if (!equalsIgnoreCase(equiv, "content-security-policy")) continue;
        return document.attribute(node, "content") orelse "";
    }
    return "";
}

fn decodeQueryParameter(url: []const u8, wanted: []const u8, out: []u8) usize {
    const query_start = stdIndexOfScalar(url, '?') orelse return 0;
    var rest = url[query_start + 1 ..];
    while (rest.len > 0) {
        const separator = stdIndexOfScalar(rest, '&') orelse rest.len;
        const pair = rest[0..separator];
        const equals_index = stdIndexOfScalar(pair, '=') orelse pair.len;
        if (equals(pair[0..equals_index], wanted)) {
            const encoded = if (equals_index < pair.len) pair[equals_index + 1 ..] else "";
            var len: usize = 0;
            var cursor: usize = 0;
            while (cursor < encoded.len and len < out.len) {
                if (encoded[cursor] == '+') {
                    out[len] = ' ';
                    len += 1;
                    cursor += 1;
                } else if (encoded[cursor] == '%' and cursor + 2 < encoded.len) {
                    const high = hexValue(encoded[cursor + 1]);
                    const low = hexValue(encoded[cursor + 2]);
                    if (high != null and low != null) {
                        out[len] = high.? * 16 + low.?;
                        len += 1;
                        cursor += 3;
                    } else {
                        out[len] = encoded[cursor];
                        len += 1;
                        cursor += 1;
                    }
                } else {
                    out[len] = encoded[cursor];
                    len += 1;
                    cursor += 1;
                }
            }
            return len;
        }
        if (separator == rest.len) break;
        rest = rest[separator + 1 ..];
    }
    return 0;
}

fn appendHtmlEscaped(out: []u8, len: *usize, value: []const u8) void {
    for (value) |byte| {
        switch (byte) {
            '&' => appendBuffer(out, len, "&amp;"),
            '<' => appendBuffer(out, len, "&lt;"),
            '>' => appendBuffer(out, len, "&gt;"),
            '"' => appendBuffer(out, len, "&quot;"),
            '\'' => appendBuffer(out, len, "&#39;"),
            else => {
                if (len.* < out.len) {
                    out[len.*] = byte;
                    len.* += 1;
                }
            },
        }
    }
}

fn appendBuffer(out: []u8, len: *usize, value: []const u8) void {
    const count = @min(value.len, out.len -| len.*);
    if (count > 0) @memcpy(out[len.* .. len.* + count], value[0..count]);
    len.* += count;
}

fn stdIndexOfScalar(value: []const u8, needle: u8) ?usize {
    var index: usize = 0;
    while (index < value.len) : (index += 1) if (value[index] == needle) return index;
    return null;
}

fn hexValue(byte: u8) ?u8 {
    if (byte >= '0' and byte <= '9') return byte - '0';
    if (byte >= 'a' and byte <= 'f') return byte - 'a' + 10;
    if (byte >= 'A' and byte <= 'F') return byte - 'A' + 10;
    return null;
}

fn documentModeText(mode: r4os.html.DocumentMode) []const u8 {
    return switch (mode) {
        .no_quirks => "standards mode",
        .limited_quirks => "limited quirks mode",
        .quirks => "quirks mode",
    };
}

fn runSelfTest(ctx: *const AppApi) i32 {
    if (!fontCatalogSelfTest(ctx)) return selfTestFail(&ctx.sys, "font-catalog");
    if (!imageResourceSelfTest(ctx)) return selfTestFail(&ctx.sys, "image-resources");
    if (!loadingViewSelfTest(ctx)) return selfTestFail(&ctx.sys, "loading-view");
    if (!fontCacheSelfTest(ctx)) return selfTestFail(&ctx.sys, "webfont-cache");
    if (!webFontRuntimeSelfTest(ctx)) return selfTestFail(&ctx.sys, "webfont-runtime");
    var browser = model.Browser.init();
    if (!equals(browser.currentUrl().bytes(), "about:klickifax")) return selfTestFail(&ctx.sys, "home");
    if (!browser.navigate("about:fixture-one")) return selfTestFail(&ctx.sys, "fixture-one");
    if (!browser.navigate("about:fixture-two")) return selfTestFail(&ctx.sys, "fixture-two");
    if (!browser.back() or browser.page.kind != .fixture_one) return selfTestFail(&ctx.sys, "back");
    if (!browser.forward() or browser.page.kind != .fixture_two) return selfTestFail(&ctx.sys, "forward");
    if (!browser.navigate("Example.COM/a/../search?q=r4os")) return selfTestFail(&ctx.sys, "http-address");
    if (!equals(browser.currentUrl().bytes(), "https://example.com/search?q=r4os")) return selfTestFail(&ctx.sys, "normalize");
    if (browser.page.kind != .remote_document) return selfTestFail(&ctx.sys, "transport-page");
    if (browser.navigate("ftp://example.com")) return selfTestFail(&ctx.sys, "unsupported-scheme");
    if (browser.page.kind != .invalid_address) return selfTestFail(&ctx.sys, "error-page");
    const allocator = ctx.sys.allocator();
    const form_harness = allocator.create(struct {
        document: r4os.html.Document,
        interaction: r4os.web_forms.Interaction,
    }) catch return selfTestFail(&ctx.sys, "form-memory");
    defer allocator.destroy(form_harness);
    const fixture = localSearchFixture();
    const stats = form_harness.document.parse(fixture, .{
        .content_type = "text/html;charset=utf-8",
        .require_html_mime = true,
    }) catch return selfTestFail(&ctx.sys, "form-document");
    if (stats.mode != .no_quirks) return selfTestFail(&ctx.sys, "standards-mode");
    form_harness.interaction.rebuild(&form_harness.document) catch return selfTestFail(&ctx.sys, "form-controls");
    if (form_harness.interaction.control_count != 2) return selfTestFail(&ctx.sys, "form-control-count");
    form_harness.interaction.controls[0].setValue("R4 OS") catch return selfTestFail(&ctx.sys, "form-value");
    var submit_url: [model.url_capacity + 1]u8 = undefined;
    var submit_body: [form_body_capacity]u8 = undefined;
    const base = model.parse("about:search") catch return selfTestFail(&ctx.sys, "form-base");
    const submitted = form_harness.interaction.submit(
        &form_harness.document,
        form_harness.interaction.controls[1].node,
        &base,
        submit_url[0..],
        submit_body[0..],
    ) catch return selfTestFail(&ctx.sys, "form-submit");
    if (submitted.method != .get or !equals(submitted.target, "about:search-results?q=R4+OS&submit=Search")) return selfTestFail(&ctx.sys, "form-encoding");
    var result_source: [local_document_capacity]u8 = undefined;
    const results = localResultsFixture(submitted.target, result_source[0..]);
    _ = form_harness.document.parse(results, .{
        .content_type = "text/html;charset=utf-8",
        .require_html_mime = true,
    }) catch return selfTestFail(&ctx.sys, "result-document");
    var result_links: usize = 0;
    var result_excerpts: usize = 0;
    var first_result: u16 = r4os.html.none;
    var node_index: usize = 0;
    while (node_index < form_harness.document.node_count) : (node_index += 1) {
        const node: u16 = @intCast(node_index);
        if (form_harness.document.nodes[node].kind != .element) continue;
        const name = form_harness.document.nodeName(node);
        if (equalsIgnoreCase(name, "a")) {
            result_links += 1;
            if (first_result == r4os.html.none) first_result = node;
        } else if (equalsIgnoreCase(name, "p")) {
            const class_name = form_harness.document.attribute(node, "class") orelse "";
            if (equals(class_name, "excerpt")) result_excerpts += 1;
        }
    }
    if (result_links != 3 or result_excerpts != 3 or first_result == r4os.html.none) return selfTestFail(&ctx.sys, "result-content");
    const first_target = r4os.web_forms.linkTarget(&form_harness.document, first_result) orelse return selfTestFail(&ctx.sys, "result-link");
    if (!equals(first_target, "about:fixture-one")) return selfTestFail(&ctx.sys, "result-target");
    var result_browser = model.Browser.init();
    if (!result_browser.navigate(submitted.target) or !result_browser.navigate(first_target) or result_browser.page.kind != .fixture_one) return selfTestFail(&ctx.sys, "result-navigation");

    _ = form_harness.document.parse(
        "<!doctype html><form action='https://consent.example/save' method=post>" ++
            "<input type=hidden name=continue value='/search?q=R4 OS'>" ++
            "<button name=choice value=reject>Reject all</button></form>",
        .{ .content_type = "text/html;charset=utf-8", .require_html_mime = true },
    ) catch return selfTestFail(&ctx.sys, "post-document");
    form_harness.interaction.rebuild(&form_harness.document) catch return selfTestFail(&ctx.sys, "post-controls");
    const post_base = model.parse("https://www.example.com/search?q=R4OS") catch return selfTestFail(&ctx.sys, "post-base");
    const posted = form_harness.interaction.submit(
        &form_harness.document,
        form_harness.interaction.controls[1].node,
        &post_base,
        submit_url[0..],
        submit_body[0..],
    ) catch return selfTestFail(&ctx.sys, "post-submit");
    if (posted.method != .post or !equals(posted.target, "https://consent.example/save") or
        !equals(posted.body, "continue=%2Fsearch%3Fq%3DR4+OS&choice=reject")) return selfTestFail(&ctx.sys, "post-encoding");
    if (r4os.html.classifyMediaType("image/png") != .unsupported) return selfTestFail(&ctx.sys, "mime");
    if (!protocolSelfTest(&ctx.sys, &ctx.dev, "application.http", 5, "R4HTTP selftest: OK")) return selfTestFail(&ctx.sys, "http-protocol");
    if (!protocolSelfTest(&ctx.sys, &ctx.dev, "security.tls", 32, "tls12-client-harness;")) return selfTestFail(&ctx.sys, "tls-client");
    if (!protocolSelfTest(&ctx.sys, &ctx.dev, "application.html", 4, "R4HTML selftest: OK")) return selfTestFail(&ctx.sys, "html-protocol");
    if (!protocolSelfTest(&ctx.sys, &ctx.dev, "text.css", 4, "R4CSS selftest: OK")) return selfTestFail(&ctx.sys, "css-protocol");
    if (!protocolSelfTest(&ctx.sys, &ctx.dev, "application.javascript", 4, "R4JS selftest: OK")) return selfTestFail(&ctx.sys, "javascript-protocol");
    if (!protocolSelfTest(&ctx.sys, &ctx.dev, "application.javascript", 5, "R4JS web-runtime selftest: OK")) return selfTestFail(&ctx.sys, "web-runtime-protocol");
    ctx.sys.println("KLICKIFAX selftest: OK web=HTTP/1.1+TLS1.2 html=DOM css=layout+images forms=GET+POST navigation=history js=runtime+bindings origin=SOP+CORS+CSP storage=cookies+local+session");
    return 0;
}

fn fontCacheSelfTest(ctx: *const AppApi) bool {
    const report = font_cache_store.selfTest(ctx.sys.allocator(), ctx.files, 1) catch |err| {
        ctx.sys.write("KLICKIFAX font-cache selftest error: ");
        ctx.sys.println(@errorName(err));
        return false;
    };
    if (!report.ok()) {
        ctx.sys.write("KLICKIFAX font-cache selftest flags commit/immediate/warm/cleanup/busy/recovered=");
        ctx.sys.printI32(@intFromBool(report.staged_and_committed));
        ctx.sys.putc('/');
        ctx.sys.printI32(@intFromBool(report.immediate_lookup));
        ctx.sys.putc('/');
        ctx.sys.printI32(@intFromBool(report.warm_lookup));
        ctx.sys.putc('/');
        ctx.sys.printI32(@intFromBool(report.cleanup));
        ctx.sys.putc('/');
        ctx.sys.printI32(@intFromBool(report.lease_busy));
        ctx.sys.putc('/');
        ctx.sys.printI32(@intFromBool(report.lease_recovered));
        ctx.sys.putc('\n');
        return false;
    }
    ctx.sys.println("KLICKIFAX font-cache selftest: OK demand=used-only storage=content-addressed warm=verified");
    return true;
}

fn webFontRuntimeSelfTest(ctx: *const AppApi) bool {
    const allocator = ctx.sys.allocator();
    const fixture_path = r4os.AbsoluteFilePath.parse("C:\\TEMP\\KFXWEB.WOF") catch return false;
    const fixture_info = switch (ctx.files.info(fixture_path.asZ())) {
        .value => |value| value,
        else => return false,
    };
    if (fixture_info.is_dir != 0 or fixture_info.size == 0 or fixture_info.size > font_response_capacity or
        fixture_info.size > std.math.maxInt(usize)) return false;
    const fixture = allocator.alloc(u8, @intCast(fixture_info.size)) catch return false;
    defer allocator.free(fixture);
    switch (ctx.files.read(fixture_path.asZ(), fixture)) {
        .bytes => |count| if (count != fixture.len) return false,
        else => return false,
    }

    const installed_before = countDirectoryFiles(&ctx.files, "C:\\R4OS\\FONTS") orelse return false;
    const system_font_count_before = ctx.draw.fontCount();
    var face_store = app_fonts.FaceStore.init(ctx.font, allocator, .{}) catch return false;
    defer face_store.deinit();

    const cold_registry = allocator.create(r4os.web_fonts.Registry) catch return false;
    defer allocator.destroy(cold_registry);
    if (!initializeWebFontSelfTestRegistry(cold_registry, 0x6241_0001)) return false;
    var cold = document_fonts.Set.init(&face_store);
    defer cold.deinit();
    cold.beginDocument(0x6241_0001);
    _ = cold.syncDemands(cold_registry, &.{0}, 10) catch return false;
    cold.completeBytes(0, fixture, 11) catch return false;
    if (!cold.publishRevision() or cold.publishRevision()) return false;
    const empty_catalog = r4os.web_font.Catalog{ .entries = &.{} };
    const cold_face = cold.resolve(cold_registry, empty_catalog, "R4OS Web Fixture, sans-serif", 18, 400, false, 'A');
    if (!document_fonts.isTemporaryId(cold_face.id)) return false;
    const cold_metrics = cold.measure(cold_face.id, "AA");
    if (!cold_metrics.valid or cold_metrics.width <= 0 or cold_metrics.height <= 0) return false;
    const cold_glyph = cold.glyphIndex(cold_face.id, 'A') orelse return false;
    const cold_raster = cold.rasterizeCached(cold_face.id, cold_glyph) orelse return false;
    if (!webFontRasterMatches(cold_raster)) return false;
    const alpha8_canvas = r4os.gui.Canvas.initSize(&ctx.draw, @intCast(cold_raster.width), @intCast(cold_raster.height));
    if (alpha8_canvas.clear(0xFFFFFF) <= 0 or alpha8_canvas.blendAlpha8(
        0,
        0,
        cold_raster.width,
        cold_raster.height,
        cold_raster.width,
        0x204080,
        cold_raster.alpha,
    ) <= 0) return false;
    const stale_render_id = cold_face.id;
    cold.beginDocument(0x6241_0002);
    if (cold.decodeTemporaryId(stale_render_id) != null) return false;

    var cache_store = font_cache_store.Store.init(allocator, ctx.files, .{}) catch return false;
    defer cache_store.deinit();
    cache_store.ensureLayout() catch return false;
    _ = cache_store.load(0, 0x6241_1001) catch return false;
    const request_origin = "https://fixture.invalid";
    const source_url = "https://fixture.invalid/fonts/runtime-06241.woff";
    _ = cache_store.commit(
        fixture,
        request_origin,
        source_url,
        source_url,
        "font/woff",
        .woff,
        0,
        0x6241_1002,
    ) catch return false;
    const token = (cache_store.lookup(request_origin, source_url, .woff, 0, 0x6241_1003) catch return false) orelse return false;
    var warm = (cache_store.loadAuthorized(allocator, request_origin, source_url, token, 0, 0x6241_1004) catch return false) orelse return false;
    defer warm.deinit(allocator);
    if (!std.mem.eql(u8, fixture, warm.bytes)) return false;

    const first_registry = allocator.create(r4os.web_fonts.Registry) catch return false;
    defer allocator.destroy(first_registry);
    const second_registry = allocator.create(r4os.web_fonts.Registry) catch return false;
    defer allocator.destroy(second_registry);
    if (!initializeWebFontSelfTestRegistry(first_registry, 0x6241_0011) or
        !initializeWebFontSelfTestRegistry(second_registry, 0x6241_0012)) return false;
    var first = document_fonts.Set.init(&face_store);
    defer first.deinit();
    var second = document_fonts.Set.init(&face_store);
    defer second.deinit();
    first.beginDocument(0x6241_0011);
    second.beginDocument(0x6241_0012);
    _ = first.syncDemands(first_registry, &.{0}, 20) catch return false;
    _ = second.syncDemands(second_registry, &.{0}, 20) catch return false;
    first.completeBytes(0, warm.bytes, 21) catch return false;
    second.completeBytes(0, warm.bytes, 21) catch return false;
    if (!first.publishRevision() or first.publishRevision() or
        !second.publishRevision() or second.publishRevision()) return false;
    var diagnostics = face_store.diagnostics();
    if (diagnostics.active_faces != 2 or diagnostics.source_objects != 1 or diagnostics.source_bytes != fixture.len) return false;
    const warm_face = second.resolve(second_registry, empty_catalog, "R4OS Web Fixture, sans-serif", 18, 400, false, 'A');
    const warm_metrics = second.measure(warm_face.id, "AA");
    const warm_glyph = second.glyphIndex(warm_face.id, 'A') orelse return false;
    const warm_raster = second.rasterizeCached(warm_face.id, warm_glyph) orelse return false;
    if (!warm_metrics.valid or warm_metrics.width != cold_metrics.width or warm_metrics.height != cold_metrics.height or
        !webFontRasterMatches(warm_raster)) return false;
    first.beginDocument(0x6241_0021);
    diagnostics = face_store.diagnostics();
    if (diagnostics.active_faces != 1 or diagnostics.source_objects != 1 or !second.measure(warm_face.id, "A").valid) return false;
    second.beginDocument(0x6241_0022);
    diagnostics = face_store.diagnostics();
    if (diagnostics.active_faces != 0 or diagnostics.source_objects != 0 or diagnostics.source_bytes != 0 or
        diagnostics.raster_entries != 0 or diagnostics.raster_bytes != 0) return false;

    if (!(cache_store.removeAuthorized(request_origin, source_url, token, 0x6241_1005) catch return false)) return false;
    if ((cache_store.lookup(request_origin, source_url, .woff, 0, 0x6241_1006) catch return false) != null) return false;
    const installed_after = countDirectoryFiles(&ctx.files, "C:\\R4OS\\FONTS") orelse return false;
    if (ctx.draw.fontCount() != system_font_count_before or installed_after != installed_before) return false;
    ctx.sys.println("KLICKIFAX webfont-runtime selftest: OK cold=decoded warm=cache network=0 transport=alpha8 variants=host-verified unicode=host-verified display=logical reflow-per-owner=1 owners=2 shared-source=1 navigation=stale-rejected system-font-delta=0 installed-files-delta=0 active-after-retire=0 render=afd31ea366bcf62249ba0b5f4f161a31398eebfbdaf3997d13eaa68a8407e95b");
    return true;
}

fn initializeWebFontSelfTestRegistry(registry: *r4os.web_fonts.Registry, document_id: u64) bool {
    registry.beginDocument(document_id);
    const stats = registry.appendStylesheet(
        "@font-face{font-family:'R4OS Web Fixture';src:url(runtime-06241.woff) format('woff');font-weight:400;font-style:normal;font-display:swap;unicode-range:U+0041-005A;}",
        "https://fixture.invalid/fonts/",
    ) catch return false;
    return stats.faces_added == 1 and stats.invalid_faces == 0;
}

fn webFontRasterMatches(raster: app_fonts.BorrowedRaster) bool {
    if (raster.width != 11 or raster.height != 13 or raster.alpha.len != 143) return false;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(raster.alpha, &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    return std.mem.eql(u8, &digest_hex, "afd31ea366bcf62249ba0b5f4f161a31398eebfbdaf3997d13eaa68a8407e95b");
}

fn countDirectoryFiles(files: *const r4os.Files, path_text: []const u8) ?usize {
    const directory = r4os.AbsoluteFilePath.parse(path_text) catch return null;
    var iterator = files.*.iterate(directory.asZ());
    var path_buffer: [r4os.abi.file_path_max_bytes + 1]u8 = undefined;
    var count: usize = 0;
    while (true) switch (iterator.next(path_buffer[0..])) {
        .entry => |entry| if (entry.kind == .file) {
            count += 1;
        },
        .end => return count,
        .failure => return null,
    };
}

fn imageResourceSelfTest(ctx: *const AppApi) bool {
    const source = "<svg width='8' height='8' viewBox='0 0 8 8'>" ++
        "<path fill='#00ff00' d='M0 0H8V8H0Z'/>" ++
        "<image href='https://fixture.invalid/unavailable.png' x='2' y='2' width='4' height='4'/>" ++
        "</svg>";
    const target_info = r4img.Info{ .format = .svg, .width = 8, .height = 8, .channels = 4 };
    const scratch_size = ctx.image.scratchBytesFor(target_info, source.len) catch return false;
    const allocator = ctx.sys.allocator();
    const scratch = allocator.alignedAlloc(u8, .fromByteUnits(16), scratch_size) catch return false;
    defer allocator.free(scratch);
    var pixels: [64]u32 = .{0} ** 64;
    const image = ctx.image.decodeSvgAt(source, "image/svg+xml", pixels[0..], scratch, 8, 8, .{
        .background = 0xFFFFFF,
    }) catch return false;
    if (image.info.width != 8 or image.info.height != 8 or image.pixels.len != pixels.len) return false;
    var vector_visible = false;
    for (image.pixels) |pixel| {
        if ((pixel & 0x00FF_FFFF) == 0x0000_FF00) {
            vector_visible = true;
            break;
        }
    }
    if (!vector_visible) return false;
    ctx.sys.println("KLICKIFAX image selftest: OK responsive=data+srcset css-background=resource SVG=nested-image-optional");
    return true;
}

fn loadingViewSelfTest(ctx: *const AppApi) bool {
    const allocator = ctx.sys.allocator();
    var asset = loading_view.Asset.load(&ctx.sys, &ctx.image, allocator);
    defer asset.deinit();
    if (!asset.available() or asset.info.width != 256 or asset.info.height != 384 or asset.info.channels != 4) return false;

    var transparent: usize = 0;
    var partial: usize = 0;
    var opaque_pixels: usize = 0;
    for (asset.source_pixels) |pixel| {
        const alpha: u8 = @truncate(pixel >> 24);
        if (alpha == 0) transparent += 1 else if (alpha == 0xFF) opaque_pixels += 1 else partial += 1;
    }
    if (transparent == 0 or partial == 0 or opaque_pixels == 0) return false;

    const viewport = r4os.gui.Rect{ .x = 9, .y = 13, .w = 600, .h = 500 };
    const first = asset.frame(viewport, client) orelse return false;
    if (first.placement.width != 256 or first.placement.height != 384 or first.pixels.len != 256 * 384) return false;
    const second = asset.frame(viewport, client) orelse return false;
    if (second.pixels.ptr != first.pixels.ptr or second.placement.x != first.placement.x or second.placement.y != first.placement.y) return false;

    var tiles: usize = 0;
    var y: u32 = 0;
    while (y < first.placement.height) : (y += r4os.abi.gui_raster_max_height) {
        var x: u32 = 0;
        while (x < first.placement.width) : (x += r4os.abi.gui_raster_max_width) {
            const tile = asset.tile(first, x, y) orelse return false;
            if (tile.width > r4os.abi.gui_raster_max_width or tile.height > r4os.abi.gui_raster_max_height or
                tile.pixels.len > r4os.abi.gui_raster_max_pixels) return false;
            tiles += 1;
        }
    }
    if (tiles != 6) return false;

    var module_path: [260]u8 = .{0} ** 260;
    const path_len_raw = ctx.sys.programModulePath(module_path[0 .. module_path.len - 1]);
    if (path_len_raw <= 0) return false;
    const path_len: usize = @intCast(path_len_raw);
    if (path_len >= module_path.len) return false;
    module_path[path_len] = 0;
    const module_path_z: [*:0]const u8 = @ptrCast(module_path[0..].ptr);
    if (ctx.sys.moduleResourceStat(module_path_z, r4os.r4sys.module_resource_type_file, 0, "MISSING.PNG") !=
        r4os.r4sys.module_resource_error_no_entry) return false;
    const corrupt = ctx.image.probe("\x89PNG\r\n\x1a\n", "image/png") catch null;
    if (corrupt != null) return false;

    ctx.sys.println("KLICKIFAX loading selftest: OK resource=container png=256x384 alpha=yes reuse=1 geometry=native+bounded tiles=6 missing=blank corrupt=blank");
    return true;
}

fn fontCatalogSelfTest(ctx: *const AppApi) bool {
    const expected_sizes = [_]u32{ 8, 12, 16, 24, 32, 40 };
    var regular_mask: u8 = 0;
    var bold_mask: u8 = 0;
    var regular_16_id: ?u32 = null;
    const count = ctx.draw.fontCount();
    var font_id: u32 = 0;
    while (font_id < count) : (font_id += 1) {
        var info = r4os.abi.GuiFontInfo{};
        if (ctx.draw.fontInfo(font_id, &info) <= 0) continue;
        if ((info.flags & r4os.abi.gui_font_flag_renderable) == 0 or !equals(spanZ(info.family[0..]), "R4 Sans")) continue;
        var size_index: usize = 0;
        while (size_index < expected_sizes.len and info.height != expected_sizes[size_index]) : (size_index += 1) {}
        if (size_index == expected_sizes.len) return false;
        const bit: u8 = @as(u8, 1) << @intCast(size_index);
        if (info.weight >= 600 or (info.style_flags & app_fonts.font_format.STYLE_BOLD) != 0) {
            if ((bold_mask & bit) != 0) return false;
            bold_mask |= bit;
        } else {
            if ((regular_mask & bit) != 0) return false;
            regular_mask |= bit;
            if (info.height == 16) regular_16_id = info.id;
        }
    }
    const all_sizes: u8 = (@as(u8, 1) << expected_sizes.len) - 1;
    if (regular_mask != all_sizes or bold_mask != all_sizes) return false;
    const proportional_id = regular_16_id orelse return false;
    var narrow = r4os.abi.GuiTextMetrics{};
    var wide = r4os.abi.GuiTextMetrics{};
    if (ctx.draw.fontMeasure(proportional_id, "iiii", &narrow) < 0 or
        ctx.draw.fontMeasure(proportional_id, "WWWW", &wide) < 0) return false;
    if (narrow.width >= wide.width or narrow.height != wide.height or narrow.line_height == 0 or narrow.baseline <= 0) return false;
    ctx.sys.println("KLICKIFAX font selftest: OK family=R4 Sans faces=12 sizes=8,12,16,24,32,40 weights=regular+bold metrics=proportional");
    return true;
}

fn protocolSelfTest(sys: *const r4os.r4sys.Context, dev: *const r4os.r4dev.Context, role: []const u8, op: u32, expected: []const u8) bool {
    var input: [1]u8 = .{0};
    var output: [256]u8 = .{0} ** 256;
    var in_buffer = r4os.abi.ProtocolBuffer{ .data = &input, .len = 0, .capacity = input.len };
    var out_buffer = r4os.abi.ProtocolBuffer{ .data = &output, .len = 0, .capacity = output.len };
    const rc = dev.protocolDispatch(role, op, &in_buffer, &out_buffer);
    if (rc != 0 or out_buffer.len > out_buffer.capacity) {
        sys.write("KLICKIFAX protocol selftest rc=");
        sys.printI32(rc);
        sys.putc('\n');
        return false;
    }
    return startsWith(output[0..out_buffer.len], expected);
}

fn selfTestFail(ctx: *const r4os.r4sys.Context, label: []const u8) i32 {
    ctx.write("KLICKIFAX selftest FAILED: ");
    ctx.println(label);
    return 1;
}

fn appendLocal(out: []u8, len: *usize, value: []const u8) void {
    if (out.len == 0 or len.* >= out.len - 1) return;
    const count = @min(value.len, out.len - 1 - len.*);
    if (count > 0) @memcpy(out[len.* .. len.* + count], value[0..count]);
    len.* += count;
    out[len.*] = 0;
}

fn appendDecimal(out: []u8, len: *usize, value: anytype) void {
    var digits: [20]u8 = undefined;
    var count: usize = 0;
    var remaining: u64 = @intCast(value);
    if (remaining == 0) {
        appendLocal(out, len, "0");
        return;
    }
    while (remaining > 0) : (remaining /= 10) {
        digits[count] = @intCast('0' + remaining % 10);
        count += 1;
    }
    while (count > 0) {
        count -= 1;
        appendLocal(out, len, digits[count .. count + 1]);
    }
}

fn fetchErrorText(err: r4os.app_web.Error) []const u8 {
    return switch (err) {
        .invalid_url, .unsupported_scheme => "Invalid or unsupported address.",
        .cancelled => "Loading was cancelled.",
        .dns_timeout => "DNS lookup timed out.",
        .dns_not_found => "Host name was not found.",
        .dns_failed => "DNS lookup failed.",
        .connect_timeout => "Connection timed out.",
        .connect_failed => "Connection failed.",
        .write_failed => "Could not send the HTTP request.",
        .read_failed => "Could not read the HTTP response.",
        .read_timeout => "Reading the HTTP response timed out.",
        .read_reset => "The server reset the connection while reading.",
        .read_peer_closed => "The server closed the connection before the response was complete.",
        .response_too_large => "The response exceeds the current 256 KB limit.",
        .malformed_response => "The server returned a malformed HTTP response.",
        .cors_preflight_failed => "The server rejected the CORS preflight.",
        .cors_rejected => "The server rejected the cross-origin response.",
        .policy_rejected => "The request target was blocked by the document security policy.",
        .redirect_disallowed => "The request does not allow redirects.",
        .redirect_without_location => "The redirect has no destination.",
        .redirect_limit => "Too many redirects.",
        .tls_unavailable => "TLS protocol is unavailable.",
        .tls_entropy_required => "Secure hardware entropy is unavailable.",
        .tls_handshake_failed => "TLS handshake failed.",
        .tls_alert_handshake_failure => "TLS alert: handshake failure.",
        .tls_alert_illegal_parameter => "TLS alert: illegal parameter.",
        .tls_alert_decode_error => "TLS alert: decode error.",
        .tls_alert_protocol_version => "TLS alert: protocol version rejected.",
        .tls_alert_insufficient_security => "TLS alert: insufficient security.",
        .tls_alert_unexpected_message => "TLS alert: unexpected message.",
        .tls_server_flight_malformed => "TLS server flight was malformed.",
        .tls_server_record_header_invalid => "TLS server record header was invalid.",
        .tls_server_message_framing_invalid => "TLS server message framing was invalid.",
        .tls_server_hello_invalid => "TLS ServerHello was invalid.",
        .tls_server_certificate_list_invalid => "TLS server certificate list was invalid.",
        .tls_server_key_exchange_invalid => "TLS ServerKeyExchange was invalid.",
        .tls_server_hello_done_invalid => "TLS ServerHelloDone was invalid.",
        .tls_server_message_unsupported => "TLS server sent an unsupported handshake message.",
        .tls_server_flight_incomplete => "TLS server flight was incomplete.",
        .tls_client_flight_buffer_invalid => "TLS client flight buffer was invalid.",
        .tls_client_flight_header_invalid => "TLS client flight header was invalid.",
        .tls_client_flight_lengths_invalid => "TLS client flight lengths were invalid.",
        .tls_client_state_length_mismatch => "TLS serialized client-state length changed in the sender.",
        .tls_server_flight_length_mismatch => "TLS serialized server-flight length changed in the sender.",
        .tls_client_flight_total_length_mismatch => "TLS serialized total flight length changed in the sender.",
        .tls_client_state_length_zero => "TLS client state length was zero.",
        .tls_server_flight_length_zero => "TLS server flight length was zero.",
        .tls_client_flight_declared_too_large => "TLS declared flight lengths exceed the input.",
        .tls_client_flight_has_trailing_input => "TLS flight input exceeds its declared lengths.",
        .tls_client_state_invalid => "TLS serialized client state was invalid.",
        .tls_certificate_rejected => "The server certificate was rejected.",
        .tls_certificate_material_unavailable => "TLS certificate trust material is unavailable.",
        .tls_certificate_clock_invalid => "The system clock cannot validate the TLS certificate.",
        .tls_certificate_parse_failed => "The server certificate could not be parsed.",
        .tls_certificate_hostname_rejected => "The TLS certificate does not match the server name.",
        .tls_certificate_validity_rejected => "The TLS certificate is outside its validity period.",
        .tls_certificate_chain_rejected => "The TLS certificate chain was rejected.",
        .tls_certificate_root_rejected => "The TLS certificate root was rejected.",
        .tls_server_signature_rejected => "TLS server signature was rejected.",
        .tls_server_flight_unsupported => "TLS server flight uses an unsupported standard.",
        .tls_server_final_flight_invalid => "TLS server final flight was invalid.",
        .tls_server_finished_rejected => "TLS server Finished verification failed.",
        .tls_finished_state_invalid => "TLS finished state was invalid.",
        .tls_record_failed => "TLS record verification failed.",
        .tls_close_notify => "The server ended TLS before the response was complete.",
        .tls_alert_received => "The server rejected the TLS request with an alert.",
        .scratch_too_small => "Web transport scratch space is too small.",
        .request_too_large => "The HTTP request exceeds the current request limit.",
        .header_buffer_too_small => "The streaming header buffer is too small.",
        .io_buffer_too_small => "The streaming I/O buffer is too small.",
        .sink_failed => "The download destination rejected data.",
        .content_length_required => "The download response has no fixed content length.",
        .content_range_required => "The resumed download has no content range.",
        .content_range_mismatch => "The resumed download range does not match the local file.",
        .range_header_conflict => "The request already contains a Range header.",
        .unsupported_method => "The streaming download only supports GET and HEAD.",
    };
}

fn htmlErrorText(err: r4os.html.Error) []const u8 {
    return switch (err) {
        error.SourceTooLarge => "The HTML document exceeds the current 256 KB limit.",
        error.UnsupportedEncoding => "The HTML document uses an unsupported character encoding.",
        error.StringLimit => "The HTML document contains too much text.",
        error.NodeLimit => "The HTML document contains too many nodes.",
        error.AttributeLimit => "The HTML document contains too many attributes.",
        error.DepthLimit => "The HTML document is nested too deeply.",
        error.ViewLimit => "The readable HTML view exceeds its current limit.",
        error.InvalidNode => "The HTML document contains an invalid DOM relation.",
        error.UnsupportedMediaType => "The response is not an HTML document.",
    };
}

fn formErrorText(err: r4os.web_forms.Error) []const u8 {
    return switch (err) {
        error.ControlLimit => "The page contains too many form controls.",
        error.FocusLimit => "The page contains too many keyboard-focusable elements.",
        error.NameTooLong => "A form control name is too long.",
        error.ValueTooLong => "The form value is too long.",
        error.InvalidUtf8 => "The form value is not valid UTF-8.",
        error.NotAControl => "The selected element is not a form control.",
        error.NoForm => "The control is not connected to a form.",
        error.UnsupportedMethod => "The form method or encoding is not supported.",
        error.UrlTooLong => "The encoded form target is too long.",
        error.InvalidAction => "The form action is not a supported address.",
    };
}

fn cssErrorText(err: r4os.css.Error) []const u8 {
    return switch (err) {
        error.SourceTooLarge => "The page styles exceed the current 128 KB limit.",
        error.RuleLimit => "The page contains too many CSS rules.",
        error.DeclarationLimit => "The page contains too many CSS declarations.",
        error.LayerLimit => "The page contains too many CSS cascade layers.",
        error.SourceSectionLimit => "The page references too many CSS source sections.",
        error.FontFaceRuleLimit => "The page contains too many CSS web font rules.",
        error.BaseUrlLimit => "The page stylesheet address catalogue is too large.",
        error.SelectorLimit => "A CSS selector is too complex.",
        error.Malformed => "The page contains malformed CSS.",
    };
}

fn webFontErrorText(err: r4os.web_fonts.Error) []const u8 {
    return switch (err) {
        error.StylesheetTooLarge => "The web font stylesheet exceeds its current limit.",
        error.SourceSectionLimit => "The page references too many web font source sections.",
        error.FaceLimit => "The page declares too many web font faces.",
        error.SourceLimit => "The page declares too many web font sources.",
        error.UnicodeRangeLimit => "The page declares too many web font Unicode ranges.",
        error.DescriptorLimit, error.CssDepthLimit => "A web font rule is too complex.",
        error.StringLimit, error.FamilyListTooLong, error.TextRunTooLong, error.OutputLimit => "The web font catalogue exceeds its current memory limit.",
    };
}

fn layoutErrorText(err: r4os.web_layout.Error) []const u8 {
    return switch (err) {
        error.RenderLimit => "The page creates too many drawing operations.",
        error.TextLimit => "The laid out page contains too much visible text.",
        error.DepthLimit => "The page layout is nested too deeply.",
    };
}

fn webRuntimeErrorText(err: r4os.web_runtime.Error) []const u8 {
    return switch (err) {
        error.SecurityBlocked => "Page script request blocked by the origin policy.",
        error.CorsBlocked => "Page script request blocked by CORS.",
        error.StaleGeneration => "A response from an old document was discarded.",
        error.ScriptLimit => "The page contains too many executable scripts.",
        error.ScriptAllocation => "The page script workspace could not be allocated.",
        error.ListenerLimit => "The page registered too many event listeners.",
        error.TimerLimit => "The page registered too many timers.",
        error.RequestLimit => "The page started too many web requests.",
        error.ResponseTooLarge => "A script response exceeds the current size limit.",
        error.Cancelled => "Page script execution was cancelled.",
        error.StepLimit => "A page script exceeded its execution budget.",
        else => "The page JavaScript runtime reported an error.",
    };
}

fn intersectRect(left: r4os.gui.Rect, right: r4os.gui.Rect) r4os.gui.Rect {
    const x = @max(left.x, right.x);
    const y = @max(left.y, right.y);
    const edge_x = @min(left.x + left.w, right.x + right.w);
    const edge_y = @min(left.y + left.h, right.y + right.h);
    return .{ .x = x, .y = y, .w = @max(0, edge_x - x), .h = @max(0, edge_y - y) };
}

fn clipRenderViewport(op: r4os.web_layout.RenderOp, viewport: r4os.gui.Rect, scroll: i32) r4os.gui.Rect {
    var result = viewport;
    if (op.clip.x) {
        const clip_left = viewport.x + op.clip.rect.x;
        const clip_right = clip_left + op.clip.rect.w;
        const left = @max(result.x, clip_left);
        const right = @min(result.x + result.w, clip_right);
        result.x = left;
        result.w = @max(0, right - left);
    }
    if (op.clip.y) {
        const clip_top = viewport.y + op.clip.rect.y - scroll;
        const clip_bottom = clip_top + op.clip.rect.h;
        const top = @max(result.y, clip_top);
        const bottom = @min(result.y + result.h, clip_bottom);
        result.y = top;
        result.h = @max(0, bottom - top);
    }
    return result;
}

fn clipRenderBounds(
    op: r4os.web_layout.RenderOp,
    bounds: r4os.gui.Rect,
    viewport: r4os.gui.Rect,
    scroll: i32,
) r4os.gui.Rect {
    return intersectRect(bounds, clipRenderViewport(op, viewport, scroll));
}

fn decodeUtf8Codepoint(value: []const u8, start: usize) u32 {
    if (start >= value.len) return 0xFFFD;
    const count = utf8SequenceLength(value, start);
    const first = value[start];
    if (count == 1) return if (first < 0x80) first else 0xFFFD;
    var scalar: u32 = first & (@as(u8, 0x7F) >> @intCast(count));
    var index: usize = 1;
    while (index < count) : (index += 1) {
        if ((value[start + index] & 0xC0) != 0x80) return 0xFFFD;
        scalar = (scalar << 6) | (value[start + index] & 0x3F);
    }
    return scalar;
}

const WrappedRange = struct {
    end: usize,
    next: usize,
};

fn nextWrappedRange(value: []const u8, start: usize, max_scalars: usize) WrappedRange {
    var cursor = start;
    var count: usize = 0;
    var last_space: ?usize = null;
    while (cursor < value.len and count < max_scalars) : (count += 1) {
        if (value[cursor] == ' ') last_space = cursor;
        cursor += utf8SequenceLength(value, cursor);
    }
    var end = cursor;
    var next = cursor;
    if (cursor < value.len) {
        if (last_space) |space| {
            if (space > start) {
                end = space;
                next = space + 1;
            }
        }
    }
    while (next < value.len and value[next] == ' ') next += 1;
    return .{ .end = end, .next = next };
}

fn utf8SequenceLength(value: []const u8, start: usize) usize {
    const byte = value[start];
    const wanted: usize = if (byte < 0x80) 1 else if ((byte & 0xE0) == 0xC0) 2 else if ((byte & 0xF0) == 0xE0) 3 else if ((byte & 0xF8) == 0xF0) 4 else 1;
    return @min(wanted, value.len - start);
}

fn utf8ChunkEnd(value: []const u8, start: usize, capacity: usize) usize {
    if (start >= value.len or capacity == 0) return start;
    var end = @min(value.len, start + capacity);
    if (end < value.len) {
        while (end > start and (value[end] & 0xC0) == 0x80) end -= 1;
        if (end == start) end = @min(value.len, start + utf8SequenceLength(value, start));
    }
    return end;
}

fn setZ(out: []u8, value: []const u8) void {
    @memset(out, 0);
    if (out.len == 0) return;
    const count = @min(value.len, out.len - 1);
    if (count > 0) @memcpy(out[0..count], value[0..count]);
}

fn spanZ(buffer: []const u8) []const u8 {
    var len: usize = 0;
    while (len < buffer.len and buffer[len] != 0) : (len += 1) {}
    return buffer[0..len];
}

fn clampI32(value: i32, min: i32, max: i32) i32 {
    if (value < min) return min;
    if (value > max) return max;
    return value;
}

fn clampI64ToI32(value: i64) i32 {
    return @intCast(@max(@as(i64, std.math.minInt(i32)), @min(@as(i64, std.math.maxInt(i32)), value)));
}

fn saturatingAddI64(left: i64, right: anytype) i64 {
    const value: i64 = @intCast(right);
    return std.math.add(i64, left, value) catch if (value >= 0) std.math.maxInt(i64) else std.math.minInt(i64);
}

fn pixelsCeil26_6(value: i64) i32 {
    if (value <= 0) return clampI64ToI32(@divTrunc(value, 64));
    return clampI64ToI32(@divTrunc(saturatingAddI64(value, 63), 64));
}

fn equals(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (left != right) return false;
    }
    return true;
}

fn startsWith(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and equals(value[0..prefix.len], prefix);
}

fn hasArg(args: [*:0]const u8, wanted: []const u8) bool {
    const bytes = spanPtrZ(args);
    var rest = bytes;
    while (rest.len > 0) {
        while (rest.len > 0 and (rest[0] == ' ' or rest[0] == '\t')) rest = rest[1..];
        if (rest.len == 0) break;
        var end: usize = 0;
        while (end < rest.len and rest[end] != ' ' and rest[end] != '\t') : (end += 1) {}
        if (equalsIgnoreCase(rest[0..end], wanted)) return true;
        rest = rest[end..];
    }
    return false;
}

fn spanPtrZ(value: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (value[len] != 0) : (len += 1) {}
    return value[0..len];
}

fn equalsIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (asciiLower(left) != asciiLower(right)) return false;
    }
    return true;
}

fn asciiLower(ch: u8) u8 {
    return if (ch >= 'A' and ch <= 'Z') ch + ('a' - 'A') else ch;
}
