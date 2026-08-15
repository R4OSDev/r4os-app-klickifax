const std = @import("std");
const r4os = @import("r4os");
const app_fonts = @import("app_fonts");

pub const max_faces: usize = r4os.web_fonts.max_faces;

const temporary_id_flag: u32 = 0x80000000;
const face_bits: u5 = 6;
const size_bits: u5 = 9;
const size_shift: u5 = face_bits;
const epoch_shift: u5 = face_bits + size_bits;
const face_mask: u32 = (1 << face_bits) - 1;
const size_mask: u32 = (1 << size_bits) - 1;

const Reference = union(enum) {
    none,
    installed: u32,
    temporary: app_fonts.FaceHandle,
};

const Slot = struct {
    active: Reference = .none,
    staged: Reference = .none,
};

pub const Diagnostics = struct {
    active_temporary: usize = 0,
    active_installed: usize = 0,
    staged: usize = 0,
    published_revisions: u64 = 0,
};

/// Per-document ownership and activation boundary for CSS font faces.
/// R4FONT faces never leave the application and R4DRAW sees only rasterized
/// Alpha8 masks.  Installed faces remain ordinary R4DRAW font identifiers.
pub const Set = struct {
    store: *app_fonts.FaceStore,
    document_id: u64 = 0,
    render_epoch: u16 = 1,
    demand_epoch: u64 = 0,
    demand_mask: [max_faces]bool = [_]bool{false} ** max_faces,
    demand_display: [max_faces]r4os.web_fonts.FontDisplay = [_]r4os.web_fonts.FontDisplay{.auto} ** max_faces,
    slots: [max_faces]Slot = [_]Slot{.{}} ** max_faces,
    coordinator: r4os.web_font_activation.Coordinator = .{},
    published_revisions: u64 = 0,

    pub fn init(store: *app_fonts.FaceStore) Set {
        return .{ .store = store };
    }

    pub fn deinit(self: *Set) void {
        self.releaseAll();
        self.* = undefined;
    }

    pub fn beginDocument(self: *Set, document_id: u64) void {
        self.releaseAll();
        self.document_id = document_id;
        self.coordinator = .{};
        self.demand_mask = [_]bool{false} ** max_faces;
        self.demand_display = [_]r4os.web_fonts.FontDisplay{.auto} ** max_faces;
        self.advanceRenderEpoch();
    }

    /// Invalidates face indices after the active @font-face rule set changes.
    pub fn resetRules(self: *Set) void {
        self.releaseAll();
        self.coordinator = .{};
        self.demand_mask = [_]bool{false} ** max_faces;
        self.demand_display = [_]r4os.web_fonts.FontDisplay{.auto} ** max_faces;
        self.advanceRenderEpoch();
    }

    /// Begins a new demand epoch only when the exact used-face set changed.
    /// Already published faces are retained without creating a new revision;
    /// decoded but not yet published faces continue as new activations.
    pub fn syncDemands(
        self: *Set,
        registry: *const r4os.web_fonts.Registry,
        face_indices: []const u16,
        now_ms: u64,
    ) !bool {
        var next_mask = [_]bool{false} ** max_faces;
        var next_display = [_]r4os.web_fonts.FontDisplay{.auto} ** max_faces;
        var demands: [max_faces]r4os.web_font_activation.Demand = undefined;
        var demand_count: usize = 0;
        for (face_indices) |face_index| {
            if (face_index >= registry.face_count or face_index >= max_faces) return error.InvalidFace;
            if (next_mask[face_index]) continue;
            next_mask[face_index] = true;
            next_display[face_index] = registry.faces[face_index].display;
            demands[demand_count] = .{ .face_index = face_index, .display = registry.faces[face_index].display };
            demand_count += 1;
        }
        var unchanged = true;
        for (0..max_faces) |index| {
            if (self.demand_mask[index] != next_mask[index] or
                (next_mask[index] and self.demand_display[index] != next_display[index]))
            {
                unchanged = false;
                break;
            }
        }
        if (unchanged) return false;

        const epoch = self.nextDemandEpoch();
        try self.coordinator.begin(epoch, now_ms, demands[0..demand_count]);
        for (0..max_faces) |index| {
            if (!next_mask[index]) {
                self.releaseReference(&self.slots[index].staged);
                self.releaseReference(&self.slots[index].active);
                continue;
            }
            switch (self.slots[index].active) {
                .none => switch (self.slots[index].staged) {
                    .none => {},
                    else => _ = self.coordinator.complete(epoch, @intCast(index), .ready, now_ms),
                },
                else => _ = self.coordinator.complete(epoch, @intCast(index), .retained, now_ms),
            }
        }
        self.demand_mask = next_mask;
        self.demand_display = next_display;
        return true;
    }

    /// Records a concrete installed face selected by local().  The return
    /// value describes source validity, not whether font-display still allows
    /// a visual swap.
    pub fn completeLocal(self: *Set, face_index: u16, installed_id: u32, now_ms: u64) bool {
        if (face_index >= max_faces or !self.demand_mask[face_index] or isTemporaryId(installed_id)) return false;
        if (!self.coordinator.complete(self.demand_epoch, face_index, .ready, now_ms)) return true;
        if (self.coordinator.phase(self.demand_epoch, face_index) != .ready) return true;
        self.releaseReference(&self.slots[face_index].staged);
        self.slots[face_index].staged = .{ .installed = installed_id };
        return true;
    }

    /// Opens and validates caller bytes without making the face visible.  This
    /// split lets the network consumer finish bounded cache persistence before
    /// sampling the font-display clock and publishing a ready face.
    pub fn stageBytes(self: *Set, face_index: u16, bytes: []const u8) !bool {
        var handle = try self.store.openCopy(bytes, 0);
        var handle_owned = true;
        defer if (handle_owned) self.store.release(&handle) catch {};
        _ = try self.store.info(handle);
        if (face_index >= max_faces or !self.demand_mask[face_index]) return false;
        self.releaseReference(&self.slots[face_index].staged);
        self.slots[face_index].staged = .{ .temporary = handle };
        handle_owned = false;
        return true;
    }

    /// Completes a previously staged face against a fresh logical time sample.
    /// Expired or stale staging is released without a visual revision.
    pub fn completeStaged(self: *Set, face_index: u16, now_ms: u64) bool {
        if (face_index >= max_faces or !self.demand_mask[face_index]) return false;
        switch (self.slots[face_index].staged) {
            .none => return false,
            else => {},
        }
        if (!self.coordinator.complete(self.demand_epoch, face_index, .ready, now_ms) or
            self.coordinator.phase(self.demand_epoch, face_index) != .ready)
        {
            self.releaseReference(&self.slots[face_index].staged);
            return false;
        }
        return true;
    }

    pub fn discardStaged(self: *Set, face_index: u16) void {
        if (face_index >= max_faces) return;
        self.releaseReference(&self.slots[face_index].staged);
    }

    /// Convenience for cache/local paths that have no blocking work between
    /// decode and activation.
    pub fn completeBytes(self: *Set, face_index: u16, bytes: []const u8, now_ms: u64) !void {
        if (try self.stageBytes(face_index, bytes)) _ = self.completeStaged(face_index, now_ms);
    }

    /// Rolls back only unpublished work after a runtime synchronization error.
    /// Active faces remain usable; the next demand walk starts a fresh epoch.
    pub fn cancelDemandEpoch(self: *Set) void {
        for (&self.slots) |*slot| self.releaseReference(&slot.staged);
        self.coordinator = .{};
        self.demand_mask = [_]bool{false} ** max_faces;
        self.demand_display = [_]r4os.web_fonts.FontDisplay{.auto} ** max_faces;
    }

    /// Reconciles aggregate runtime state, never per-source failures, and
    /// advances bounded font-display windows using caller-supplied time.
    pub fn reconcile(self: *Set, runtime: *const r4os.web_runtime.WebRuntime, now_ms: u64) void {
        for (self.demand_mask, 0..) |demanded, index| {
            if (!demanded or self.coordinator.phase(self.demand_epoch, @intCast(index)) != .loading) continue;
            switch (runtime.fontFaceStatus(@intCast(index))) {
                .failed, .absent => _ = self.coordinator.complete(self.demand_epoch, @intCast(index), .failed, now_ms),
                .ready => switch (self.slots[index].active) {
                    .none => switch (self.slots[index].staged) {
                        .none => _ = self.coordinator.complete(self.demand_epoch, @intCast(index), .failed, now_ms),
                        else => _ = self.coordinator.complete(self.demand_epoch, @intCast(index), .ready, now_ms),
                    },
                    else => _ = self.coordinator.complete(self.demand_epoch, @intCast(index), .retained, now_ms),
                },
                .loading => {},
            }
        }
        _ = self.coordinator.advance(self.demand_epoch, now_ms);
    }

    /// Atomically publishes every staged face of the epoch after its single
    /// coalesced revision becomes available.
    pub fn publishRevision(self: *Set) bool {
        const revision = self.coordinator.takeRevision() orelse return false;
        if (revision.epoch != self.demand_epoch) return false;
        for (self.demand_mask, 0..) |demanded, index| {
            if (!demanded or self.coordinator.phase(self.demand_epoch, @intCast(index)) != .ready) continue;
            switch (self.slots[index].staged) {
                .none => {},
                else => {
                    self.releaseReference(&self.slots[index].active);
                    self.slots[index].active = self.slots[index].staged;
                    self.slots[index].staged = .none;
                },
            }
        }
        self.published_revisions += 1;
        return true;
    }

    pub fn resolve(
        self: *const Set,
        registry: *const r4os.web_fonts.Registry,
        catalog: r4os.web_font.Catalog,
        family_list: []const u8,
        pixel_size: i32,
        weight: u16,
        italic: bool,
        codepoint: ?u32,
    ) r4os.web_layout.FontFace {
        var cursor: usize = 0;
        var had_family = false;
        while (r4os.web_font.nextFamily(family_list, &cursor)) |family| {
            had_family = true;
            if (self.resolveDocumentFamily(registry, catalog, family, pixel_size, weight, italic, codepoint)) |face| return face;
            if (catalog.resolveFamily(family, pixel_size, weight, italic, codepoint)) |face| return layoutFace(face);
        }
        if (!had_family) {
            if (self.resolveDocumentFamily(registry, catalog, "sans-serif", pixel_size, weight, italic, codepoint)) |face| return face;
            if (catalog.resolveFamily("sans-serif", pixel_size, weight, italic, codepoint)) |face| return layoutFace(face);
        }
        return layoutFace(catalog.resolveAvailable(pixel_size, weight, italic, codepoint));
    }

    pub fn measure(self: *const Set, render_id: u32, value: []const u8) r4os.web_layout.TextMetrics {
        const decoded = self.decodeTemporaryId(render_id) orelse return .{};
        if (value.len == 0) return .{ .valid = true };
        const metrics = self.store.faceMetricsAt(decoded.handle, decoded.pixel_height) catch return .{};
        var width: i64 = 0;
        var cursor: usize = 0;
        var previous: ?u32 = null;
        while (cursor < value.len) {
            const scalar = decodeScalar(value, cursor);
            cursor += scalar.consumed;
            const glyph = self.store.glyphIndex(decoded.handle, scalar.codepoint) catch return .{};
            const glyph_index = glyph orelse return .{};
            if (previous) |left| {
                const kern = self.store.kerningAt(decoded.handle, left, glyph_index, decoded.pixel_height) catch return .{};
                width += kern[0];
            }
            const glyph_metrics = self.store.glyphMetricsAt(decoded.handle, glyph_index, decoded.pixel_height) catch return .{};
            width += glyph_metrics.advance_x;
            previous = glyph_index;
        }
        return .{
            .valid = true,
            .width = pixelsCeil(width),
            .height = @max(1, pixelsRound(metrics.height)),
            .line_height = @max(1, pixelsRound(metrics.line_height)),
            .baseline = @max(0, pixelsRound(metrics.baseline)),
            .visible_bytes = value.len,
        };
    }

    pub const DecodedTemporary = struct {
        handle: app_fonts.FaceHandle,
        face_index: u16,
        pixel_height: u32,
    };

    pub fn decodeTemporaryId(self: *const Set, render_id: u32) ?DecodedTemporary {
        if (!isTemporaryId(render_id)) return null;
        const encoded_epoch: u16 = @intCast((render_id >> epoch_shift) & 0xFFFF);
        if (encoded_epoch != self.render_epoch) return null;
        const face_index: u16 = @intCast(render_id & face_mask);
        if (face_index >= max_faces) return null;
        const pixel_height = (render_id >> size_shift) & size_mask;
        if (pixel_height == 0) return null;
        return switch (self.slots[face_index].active) {
            .temporary => |handle| .{ .handle = handle, .face_index = face_index, .pixel_height = pixel_height },
            else => null,
        };
    }

    pub fn glyphIndex(self: *const Set, render_id: u32, codepoint: u32) ?u32 {
        const decoded = self.decodeTemporaryId(render_id) orelse return null;
        return self.store.glyphIndex(decoded.handle, codepoint) catch null;
    }

    pub fn kerning(self: *const Set, render_id: u32, left: u32, right: u32) [2]i32 {
        const decoded = self.decodeTemporaryId(render_id) orelse return .{ 0, 0 };
        return self.store.kerningAt(decoded.handle, left, right, decoded.pixel_height) catch .{ 0, 0 };
    }

    pub fn rasterizeCached(self: *const Set, render_id: u32, glyph_index: u32) ?app_fonts.BorrowedRaster {
        const decoded = self.decodeTemporaryId(render_id) orelse return null;
        return self.store.rasterizeCached(decoded.handle, glyph_index, decoded.pixel_height) catch null;
    }

    pub fn diagnostics(self: *const Set) Diagnostics {
        var result = Diagnostics{ .published_revisions = self.published_revisions };
        for (self.slots) |slot| {
            switch (slot.active) {
                .temporary => result.active_temporary += 1,
                .installed => result.active_installed += 1,
                .none => {},
            }
            switch (slot.staged) {
                .none => {},
                else => result.staged += 1,
            }
        }
        return result;
    }

    fn resolveDocumentFamily(
        self: *const Set,
        registry: *const r4os.web_fonts.Registry,
        catalog: r4os.web_font.Catalog,
        family: []const u8,
        pixel_size: i32,
        weight: u16,
        italic: bool,
        codepoint: ?u32,
    ) ?r4os.web_layout.FontFace {
        const match = registry.matchFamilyCodepoint(family, .{
            .family_list = family,
            .text = "",
            .weight = weight,
            .style = if (italic) .italic else .normal,
        }, codepoint) orelse return null;
        if (match.document_id != self.document_id or match.face_index >= max_faces) return null;
        return switch (self.slots[match.face_index].active) {
            .none => null,
            .installed => |id| if (catalog.resolveId(id, codepoint)) |face| layoutFace(face) else null,
            .temporary => |handle| blk: {
                if (codepoint) |scalar| if (!(self.store.hasGlyph(handle, scalar) catch false)) break :blk null;
                const height: u32 = @intCast(@max(
                    @as(i32, app_fonts.min_pixel_height),
                    @min(pixel_size, @as(i32, app_fonts.max_pixel_height)),
                ));
                const metrics = self.store.faceMetricsAt(handle, height) catch break :blk null;
                break :blk .{
                    .id = self.temporaryId(match.face_index, height),
                    .height = @max(1, pixelsRound(metrics.height)),
                    .line_height = @max(1, pixelsRound(metrics.line_height)),
                    .baseline = @max(0, pixelsRound(metrics.baseline)),
                    .max_advance = @max(1, pixelsRound(metrics.max_advance)),
                };
            },
        };
    }

    fn temporaryId(self: *const Set, face_index: u16, pixel_height: u32) u32 {
        return temporary_id_flag |
            (@as(u32, self.render_epoch) << epoch_shift) |
            ((pixel_height & size_mask) << size_shift) |
            (@as(u32, face_index) & face_mask);
    }

    fn nextDemandEpoch(self: *Set) u64 {
        self.demand_epoch +%= 1;
        if (self.demand_epoch == 0) self.demand_epoch = 1;
        return self.demand_epoch;
    }

    fn advanceRenderEpoch(self: *Set) void {
        self.render_epoch +%= 1;
        if (self.render_epoch == 0) self.render_epoch = 1;
    }

    fn releaseAll(self: *Set) void {
        for (&self.slots) |*slot| {
            self.releaseReference(&slot.staged);
            self.releaseReference(&slot.active);
        }
    }

    fn releaseReference(self: *Set, reference: *Reference) void {
        switch (reference.*) {
            .temporary => |handle_value| {
                var handle = handle_value;
                self.store.release(&handle) catch {};
            },
            else => {},
        }
        reference.* = .none;
    }
};

pub fn isTemporaryId(render_id: u32) bool {
    return (render_id & temporary_id_flag) != 0;
}

fn layoutFace(face: r4os.web_font.Face) r4os.web_layout.FontFace {
    return .{
        .id = face.id,
        .height = face.height,
        .line_height = face.line_height,
        .baseline = face.baseline,
        .max_advance = face.max_advance,
    };
}

fn pixelsRound(value: anytype) i32 {
    const wide: i64 = @intCast(value);
    if (wide >= 0) return @intCast(@min(@as(i64, std.math.maxInt(i32)), @divTrunc(wide + 32, 64)));
    return @intCast(@max(@as(i64, std.math.minInt(i32)), -@divTrunc(-wide + 32, 64)));
}

fn pixelsCeil(value: i64) i32 {
    if (value <= 0) return @intCast(@max(@as(i64, std.math.minInt(i32)), @divTrunc(value, 64)));
    return @intCast(@min(@as(i64, std.math.maxInt(i32)), @divTrunc(value + 63, 64)));
}

const Scalar = struct {
    codepoint: u32,
    consumed: usize,
};

fn decodeScalar(value: []const u8, cursor: usize) Scalar {
    if (cursor >= value.len) return .{ .codepoint = 0xFFFD, .consumed = 1 };
    const first = value[cursor];
    if (first < 0x80) return .{ .codepoint = first, .consumed = 1 };
    const length: usize = if ((first & 0xE0) == 0xC0)
        2
    else if ((first & 0xF0) == 0xE0)
        3
    else if ((first & 0xF8) == 0xF0)
        4
    else
        return .{ .codepoint = 0xFFFD, .consumed = 1 };
    if (cursor + length > value.len) return .{ .codepoint = 0xFFFD, .consumed = 1 };
    var codepoint: u32 = first & (@as(u8, 0x7F) >> @intCast(length));
    for (value[cursor + 1 .. cursor + length]) |continuation| {
        if ((continuation & 0xC0) != 0x80) return .{ .codepoint = 0xFFFD, .consumed = 1 };
        codepoint = (codepoint << 6) | (continuation & 0x3F);
    }
    const minimum: u32 = switch (length) {
        2 => 0x80,
        3 => 0x800,
        else => 0x10000,
    };
    if (codepoint < minimum or codepoint > 0x10FFFF or (codepoint >= 0xD800 and codepoint <= 0xDFFF))
        return .{ .codepoint = 0xFFFD, .consumed = 1 };
    return .{ .codepoint = codepoint, .consumed = length };
}

test "temporary render identifiers keep face size and epoch isolated" {
    try std.testing.expect(!isTemporaryId(17));
    try std.testing.expect(isTemporaryId(temporary_id_flag));
    try std.testing.expectEqual(@as(i32, 2), pixelsRound(127));
    try std.testing.expectEqual(@as(i32, -2), pixelsRound(-127));
    try std.testing.expectEqual(@as(i32, 2), pixelsCeil(65));
}

fn testingFontIdentity() app_fonts.FontContext {
    const provider = @import("r4font_provider");
    return app_fonts.FontContext.initHeader(&provider.r4font_api_v1.header).?;
}

fn testingReadFont(path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        std.testing.allocator,
        .limited(8 * 1024 * 1024),
    );
}

fn testingRegistry(document_id: u64) !r4os.web_fonts.Registry {
    var registry: r4os.web_fonts.Registry = undefined;
    registry.beginDocument(document_id);
    const stats = try registry.appendStylesheet(
        "@font-face{font-family:'R4OS Web Fixture';src:url(regular.woff) format('woff');font-weight:400;font-style:normal;font-display:swap;unicode-range:U+0041-005A;}" ++
            "@font-face{font-family:'R4OS Web Fixture';src:url(bold.woff) format('woff');font-weight:700;font-style:normal;font-display:swap;unicode-range:U+0041-005A;}" ++
            "@font-face{font-family:'R4OS Web Fixture';src:url(italic.woff) format('woff');font-weight:400;font-style:italic;font-display:swap;unicode-range:U+0041-005A;}" ++
            "@font-face{font-family:'R4OS Web Symbols';src:url(symbol.woff) format('woff');font-weight:400;font-style:normal;font-display:swap;unicode-range:U+2605;}",
        "https://fixture.invalid/fonts/",
    );
    try std.testing.expectEqual(@as(usize, 4), stats.faces_added);
    return registry;
}

test "document fonts activate variants Unicode fallback and one coalesced revision" {
    var store = try app_fonts.FaceStore.init(testingFontIdentity(), std.testing.allocator, .{});
    defer store.deinit();
    var set = Set.init(&store);
    defer set.deinit();
    var registry = try testingRegistry(71);
    set.beginDocument(71);

    const paths = [_][]const u8{
        "../../../../Tests/Fixture/Browser/Fonts06241/regular.woff",
        "../../../../Tests/Fixture/Browser/Fonts06241/bold.woff",
        "../../../../Tests/Fixture/Browser/Fonts06241/italic.woff",
        "../../../../Tests/Fixture/Browser/Fonts06241/symbol.woff",
    };
    try std.testing.expect(try set.syncDemands(&registry, &.{ 0, 1, 2, 3 }, 1_000));
    for (paths, 0..) |path, index| {
        const bytes = try testingReadFont(path);
        defer std.testing.allocator.free(bytes);
        try std.testing.expect(try set.stageBytes(@intCast(index), bytes));
        try std.testing.expect(set.completeStaged(@intCast(index), 1_001 + index));
        if (index + 1 < paths.len) try std.testing.expect(!set.publishRevision());
    }
    try std.testing.expectEqual(@as(usize, 4), set.diagnostics().staged);
    try std.testing.expect(set.publishRevision());
    try std.testing.expect(!set.publishRevision());
    try std.testing.expectEqual(@as(u64, 1), set.diagnostics().published_revisions);
    try std.testing.expectEqual(@as(usize, 4), set.diagnostics().active_temporary);

    const catalog = r4os.web_font.Catalog{ .entries = &.{} };
    const regular = set.resolve(&registry, catalog, "'R4OS Web Fixture', sans-serif", 18, 400, false, 'A');
    const bold = set.resolve(&registry, catalog, "'R4OS Web Fixture', sans-serif", 18, 700, false, 'A');
    const italic = set.resolve(&registry, catalog, "'R4OS Web Fixture', sans-serif", 18, 400, true, 'A');
    const symbol = set.resolve(&registry, catalog, "'R4OS Web Fixture', 'R4OS Web Symbols', sans-serif", 18, 400, false, 0x2605);
    try std.testing.expect(isTemporaryId(regular.id));
    try std.testing.expect(isTemporaryId(bold.id));
    try std.testing.expect(isTemporaryId(italic.id));
    try std.testing.expect(isTemporaryId(symbol.id));
    try std.testing.expect(regular.id != bold.id and regular.id != italic.id and regular.id != symbol.id);

    const measured = set.measure(regular.id, "AA");
    try std.testing.expect(measured.valid);
    try std.testing.expect(measured.width > 0 and measured.height > 0 and measured.visible_bytes == 2);
    const glyph = set.glyphIndex(regular.id, 'A') orelse return error.MissingGlyph;
    const raster = set.rasterizeCached(regular.id, glyph) orelse return error.MissingRaster;
    try std.testing.expectEqual(@as(u32, 11), raster.width);
    try std.testing.expectEqual(@as(u32, 13), raster.height);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(raster.alpha, &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expectEqualStrings("afd31ea366bcf62249ba0b5f4f161a31398eebfbdaf3997d13eaa68a8407e95b", &digest_hex);

    const stale_id = regular.id;
    set.beginDocument(72);
    try std.testing.expect(set.decodeTemporaryId(stale_id) == null);
    const diagnostics = store.diagnostics();
    try std.testing.expectEqual(@as(usize, 0), diagnostics.active_faces);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.source_objects);
}

test "two document owners share source bytes but retire independently" {
    var store = try app_fonts.FaceStore.init(testingFontIdentity(), std.testing.allocator, .{});
    defer store.deinit();
    var first = Set.init(&store);
    defer first.deinit();
    var second = Set.init(&store);
    defer second.deinit();
    var first_registry = try testingRegistry(81);
    var second_registry = try testingRegistry(82);
    first.beginDocument(81);
    second.beginDocument(82);
    try std.testing.expect(try first.syncDemands(&first_registry, &.{0}, 100));
    try std.testing.expect(try second.syncDemands(&second_registry, &.{0}, 100));
    const bytes = try testingReadFont("../../../../Tests/Fixture/Browser/Fonts06241/regular.woff");
    defer std.testing.allocator.free(bytes);
    try first.completeBytes(0, bytes, 101);
    try second.completeBytes(0, bytes, 101);
    try std.testing.expect(first.publishRevision());
    try std.testing.expect(second.publishRevision());
    var diagnostics = store.diagnostics();
    try std.testing.expectEqual(@as(usize, 2), diagnostics.active_faces);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.source_objects);
    try std.testing.expectEqual(bytes.len, diagnostics.source_bytes);

    const catalog = r4os.web_font.Catalog{ .entries = &.{} };
    const second_face = second.resolve(&second_registry, catalog, "R4OS Web Fixture", 18, 400, false, 'A');
    try std.testing.expect(isTemporaryId(second_face.id));
    first.beginDocument(83);
    diagnostics = store.diagnostics();
    try std.testing.expectEqual(@as(usize, 1), diagnostics.active_faces);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.source_objects);
    try std.testing.expect(second.measure(second_face.id, "A").valid);
    second.beginDocument(84);
    diagnostics = store.diagnostics();
    try std.testing.expectEqual(@as(usize, 0), diagnostics.active_faces);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.source_objects);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.source_bytes);
}
