const std = @import("std");
const r4os = @import("r4os");
const r4img = @import("r4img");

pub const resource_name = "LOADING.PNG";
pub const safety_margin: i32 = 16;
pub const max_resource_bytes: usize = 512 * 1024;

pub const Placement = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
};

pub const Frame = struct {
    placement: Placement,
    pixels: []const u32,
};

pub const Tile = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    pixels: []const u32,
};

/// Owns the decoded illustration for the lifetime of one Klickifax instance.
/// A failed resource lookup or decode deliberately leaves an empty asset: the
/// loading surface then stays blank and no broken-image placeholder appears.
pub const Asset = struct {
    allocator: std.mem.Allocator,
    image: ?*const r4img.Context = null,
    info: r4img.Info = .{ .format = .png, .width = 1, .height = 1, .channels = 4 },
    source_pixels: []u32 = &.{},
    frame_pixels: []u32 = &.{},
    tile_pixels: []u32 = &.{},
    frame_width: u32 = 0,
    frame_height: u32 = 0,
    frame_background: u32 = 0,

    pub fn load(
        sys: *const r4os.r4sys.Context,
        image: *const r4img.Context,
        allocator: std.mem.Allocator,
    ) Asset {
        return loadChecked(sys, image, allocator) catch .{ .allocator = allocator };
    }

    pub fn deinit(self: *Asset) void {
        if (self.tile_pixels.len > 0) self.allocator.free(self.tile_pixels);
        if (self.frame_pixels.len > 0) self.allocator.free(self.frame_pixels);
        if (self.source_pixels.len > 0) self.allocator.free(self.source_pixels);
        self.* = .{ .allocator = self.allocator };
    }

    pub fn available(self: *const Asset) bool {
        return self.source_pixels.len > 0 and self.frame_pixels.len >= self.source_pixels.len and
            self.tile_pixels.len >= r4os.abi.gui_raster_max_pixels;
    }

    /// Returns an opaque XRGB frame composited over the document background.
    /// The embedded PNG and the retained source pixels keep their alpha data;
    /// only the short-lived R4DRAW payload is flattened for the current page.
    pub fn frame(self: *Asset, viewport: r4os.gui.Rect, background: u32) ?Frame {
        if (!self.available()) return null;
        const placement = place(viewport, self.info.width, self.info.height) orelse return null;
        const count = std.math.mul(usize, placement.width, placement.height) catch return null;
        if (count > self.frame_pixels.len) return null;
        if (self.frame_width != placement.width or self.frame_height != placement.height or self.frame_background != background) {
            const image = self.image orelse return null;
            const source = r4img.Image{ .info = self.info, .pixels = self.source_pixels };
            _ = image.scaleComposite(
                source,
                self.frame_pixels[0..count],
                placement.width,
                placement.height,
                background,
            ) catch return null;
            self.frame_width = placement.width;
            self.frame_height = placement.height;
            self.frame_background = background;
        }
        return .{ .placement = placement, .pixels = self.frame_pixels[0..count] };
    }

    /// Packs one bounded R4DRAW command from the full cached frame. The
    /// caller may reuse this buffer immediately after Canvas.raster returns.
    pub fn tile(self: *Asset, frame_value: Frame, x: u32, y: u32) ?Tile {
        if (x >= frame_value.placement.width or y >= frame_value.placement.height) return null;
        const width = @min(r4os.abi.gui_raster_max_width, frame_value.placement.width - x);
        const height = @min(r4os.abi.gui_raster_max_height, frame_value.placement.height - y);
        const count = std.math.mul(usize, width, height) catch return null;
        if (count == 0 or count > self.tile_pixels.len) return null;
        const source_width: usize = @intCast(frame_value.placement.width);
        const tile_width: usize = @intCast(width);
        var row: usize = 0;
        while (row < height) : (row += 1) {
            const source_start = (@as(usize, y) + row) * source_width + x;
            const target_start = row * tile_width;
            @memcpy(
                self.tile_pixels[target_start .. target_start + tile_width],
                frame_value.pixels[source_start .. source_start + tile_width],
            );
        }
        return .{ .x = x, .y = y, .width = width, .height = height, .pixels = self.tile_pixels[0..count] };
    }
};

pub fn place(viewport: r4os.gui.Rect, source_width: u32, source_height: u32) ?Placement {
    if (viewport.w <= safety_margin * 2 or viewport.h <= safety_margin * 2 or source_width == 0 or source_height == 0) return null;
    const available_width: u32 = @intCast(viewport.w - safety_margin * 2);
    const available_height: u32 = @intCast(viewport.h - safety_margin * 2);

    var width = source_width;
    var height = source_height;
    if (width > available_width or height > available_height) {
        if (@as(u64, available_width) * source_height <= @as(u64, available_height) * source_width) {
            width = available_width;
            height = @max(@as(u32, 1), @as(u32, @intCast((@as(u64, source_height) * width) / source_width)));
        } else {
            height = available_height;
            width = @max(@as(u32, 1), @as(u32, @intCast((@as(u64, source_width) * height) / source_height)));
        }
    }
    if (width > available_width or height > available_height) return null;
    return .{
        .x = viewport.x + @divTrunc(viewport.w - @as(i32, @intCast(width)), 2),
        .y = viewport.y + @divTrunc(viewport.h - @as(i32, @intCast(height)), 2),
        .width = width,
        .height = height,
    };
}

const LoadError = error{
    ModulePath,
    MissingResource,
    ResourceTooLarge,
    ResourceRead,
    WrongFormat,
    MissingTransparency,
} || std.mem.Allocator.Error || r4img.Error;

fn loadChecked(
    sys: *const r4os.r4sys.Context,
    image: *const r4img.Context,
    allocator: std.mem.Allocator,
) LoadError!Asset {
    var module_path: [260]u8 = .{0} ** 260;
    const path_len_raw = sys.programModulePath(module_path[0 .. module_path.len - 1]);
    if (path_len_raw <= 0) return error.ModulePath;
    const path_len: usize = @intCast(path_len_raw);
    if (path_len >= module_path.len) return error.ModulePath;
    module_path[path_len] = 0;
    const module_path_z: [*:0]const u8 = @ptrCast(module_path[0..].ptr);

    const size_raw = sys.moduleResourceStat(
        module_path_z,
        r4os.r4sys.module_resource_type_file,
        0,
        resource_name,
    );
    if (size_raw <= 0) return error.MissingResource;
    const encoded_len: usize = @intCast(size_raw);
    if (encoded_len > max_resource_bytes) return error.ResourceTooLarge;

    const encoded = try allocator.alloc(u8, encoded_len);
    defer allocator.free(encoded);
    const read = sys.moduleResourceRead(
        module_path_z,
        r4os.r4sys.module_resource_type_file,
        0,
        resource_name,
        encoded,
    );
    if (read != size_raw) return error.ResourceRead;

    const info = try image.probe(encoded, "image/png");
    if (info.format != .png or info.channels != 4) return error.WrongFormat;
    const pixel_count = try info.pixelCount();
    const source_pixels = try allocator.alloc(u32, pixel_count);
    errdefer allocator.free(source_pixels);
    const scratch_len = try image.scratchBytesFor(info, encoded.len);
    const scratch = try allocator.alignedAlloc(u8, .fromByteUnits(16), scratch_len);
    defer allocator.free(scratch);
    const decoded = try image.decode(encoded, "image/png", source_pixels, scratch);

    var has_visible = false;
    var has_transparency = false;
    for (decoded.pixels) |pixel| {
        const alpha: u8 = @truncate(pixel >> 24);
        has_visible = has_visible or alpha != 0;
        has_transparency = has_transparency or alpha != 0xFF;
    }
    if (!has_visible or !has_transparency) return error.MissingTransparency;

    const frame_pixels = try allocator.alloc(u32, pixel_count);
    errdefer allocator.free(frame_pixels);
    const tile_pixels = try allocator.alloc(u32, r4os.abi.gui_raster_max_pixels);
    errdefer allocator.free(tile_pixels);
    return .{
        .allocator = allocator,
        .image = image,
        .info = info,
        .source_pixels = source_pixels,
        .frame_pixels = frame_pixels,
        .tile_pixels = tile_pixels,
    };
}

test "loading illustration remains native and centered when it fits" {
    const placement = place(.{ .x = 20, .y = 40, .w = 600, .h = 500 }, 256, 384) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 256), placement.width);
    try std.testing.expectEqual(@as(u32, 384), placement.height);
    try std.testing.expectEqual(@as(i32, 192), placement.x);
    try std.testing.expectEqual(@as(i32, 98), placement.y);
}

test "loading illustration shrinks proportionally with a safety margin" {
    const height_limited = place(.{ .x = 7, .y = 11, .w = 500, .h = 212 }, 256, 384) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 120), height_limited.width);
    try std.testing.expectEqual(@as(u32, 180), height_limited.height);
    try std.testing.expectEqual(@as(i32, 197), height_limited.x);
    try std.testing.expectEqual(@as(i32, 27), height_limited.y);

    const width_limited = place(.{ .x = 3, .y = 5, .w = 160, .h = 500 }, 256, 384) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 128), width_limited.width);
    try std.testing.expectEqual(@as(u32, 192), width_limited.height);
    try std.testing.expectEqual(@as(i32, 19), width_limited.x);
    try std.testing.expectEqual(@as(i32, 159), width_limited.y);
}

test "loading illustration never creates a tiny artificial surface" {
    try std.testing.expect(place(.{ .x = 0, .y = 0, .w = 32, .h = 100 }, 256, 384) == null);
    try std.testing.expect(place(.{ .x = 0, .y = 0, .w = 100, .h = 32 }, 256, 384) == null);
    try std.testing.expect(place(.{ .x = 0, .y = 0, .w = 100, .h = 100 }, 0, 384) == null);
}

test "unavailable or corrupt loading resource stays a blank surface" {
    var asset = Asset{ .allocator = std.testing.allocator };
    defer asset.deinit();
    try std.testing.expect(!asset.available());
    try std.testing.expect(asset.frame(.{ .x = 0, .y = 0, .w = 640, .h = 400 }, 0xFFFFFF) == null);
}

test "full loading frame is packed into bounded reusable raster tiles" {
    const allocator = std.testing.allocator;
    const count: usize = 256 * 384;
    var asset = Asset{
        .allocator = allocator,
        .info = .{ .format = .png, .width = 256, .height = 384, .channels = 4 },
        .source_pixels = try allocator.alloc(u32, count),
        .frame_pixels = try allocator.alloc(u32, count),
        .tile_pixels = try allocator.alloc(u32, r4os.abi.gui_raster_max_pixels),
    };
    defer asset.deinit();
    for (asset.frame_pixels, 0..) |*pixel, index| pixel.* = @intCast(index);
    const frame_value = Frame{
        .placement = .{ .x = 0, .y = 0, .width = 256, .height = 384 },
        .pixels = asset.frame_pixels,
    };
    var tiles: usize = 0;
    var y: u32 = 0;
    while (y < frame_value.placement.height) : (y += r4os.abi.gui_raster_max_height) {
        var x: u32 = 0;
        while (x < frame_value.placement.width) : (x += r4os.abi.gui_raster_max_width) {
            const tile_value = asset.tile(frame_value, x, y) orelse return error.TestUnexpectedResult;
            try std.testing.expect(tile_value.width <= r4os.abi.gui_raster_max_width);
            try std.testing.expect(tile_value.height <= r4os.abi.gui_raster_max_height);
            try std.testing.expect(tile_value.pixels.len <= r4os.abi.gui_raster_max_pixels);
            try std.testing.expectEqual(asset.frame_pixels[@as(usize, y) * 256 + x], tile_value.pixels[0]);
            tiles += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 6), tiles);
}
