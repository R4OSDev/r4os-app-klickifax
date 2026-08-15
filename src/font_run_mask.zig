const std = @import("std");

pub const Error = error{
    InvalidGeometry,
    StorageTooSmall,
};

/// Caller-owned Alpha8 composition surface. Coordinates are absolute so a
/// glyph can be clipped directly into a visible text-run band.
pub const Mask = struct {
    storage: []u8,
    origin_x: i32,
    origin_y: i32,
    width: u32,
    height: u32,
    stride: u32,

    pub fn init(storage: []u8, origin_x: i32, origin_y: i32, width: u32, height: u32) Error!Mask {
        if (width == 0 or height == 0) return error.InvalidGeometry;
        const required = std.math.mul(usize, @as(usize, width), @as(usize, height)) catch return error.InvalidGeometry;
        if (required > storage.len) return error.StorageTooSmall;
        @memset(storage[0..required], 0);
        return .{
            .storage = storage[0..required],
            .origin_x = origin_x,
            .origin_y = origin_y,
            .width = width,
            .height = height,
            .stride = width,
        };
    }

    /// Composes one potentially padded glyph mask using source-over coverage.
    /// The RGB color is common to the complete run and is applied only when
    /// the finished strips cross R4DRAW.
    pub fn blend(self: *Mask, x: i64, y: i64, width: u32, height: u32, stride: u32, alpha: []const u8) bool {
        if (width == 0 or height == 0 or stride < width) return false;
        const source_required = std.math.mul(usize, @as(usize, height - 1), @as(usize, stride)) catch return false;
        const required = std.math.add(usize, source_required, @as(usize, width)) catch return false;
        if (required > alpha.len) return false;

        const mask_left: i64 = self.origin_x;
        const mask_top: i64 = self.origin_y;
        const mask_right = mask_left + @as(i64, self.width);
        const mask_bottom = mask_top + @as(i64, self.height);
        const source_right = std.math.add(i64, x, @as(i64, width)) catch std.math.maxInt(i64);
        const source_bottom = std.math.add(i64, y, @as(i64, height)) catch std.math.maxInt(i64);
        const left = @max(mask_left, x);
        const top = @max(mask_top, y);
        const right = @min(mask_right, source_right);
        const bottom = @min(mask_bottom, source_bottom);
        if (right <= left or bottom <= top) return false;

        const source_x: usize = @intCast(left - x);
        const source_y: usize = @intCast(top - y);
        const destination_x: usize = @intCast(left - mask_left);
        const destination_y: usize = @intCast(top - mask_top);
        const copy_width: usize = @intCast(right - left);
        const copy_height: usize = @intCast(bottom - top);
        var changed = false;
        var row: usize = 0;
        while (row < copy_height) : (row += 1) {
            const source_offset = (source_y + row) * @as(usize, stride) + source_x;
            const destination_offset = (destination_y + row) * @as(usize, self.stride) + destination_x;
            var column: usize = 0;
            while (column < copy_width) : (column += 1) {
                const coverage = alpha[source_offset + column];
                if (coverage == 0) continue;
                const destination = &self.storage[destination_offset + column];
                destination.* = coverageOver(destination.*, coverage);
                changed = true;
            }
        }
        return changed;
    }

    pub fn strips(self: *const Mask, max_width: u32) StripIterator {
        return .{ .mask = self, .max_width = max_width };
    }

    fn rangeHasCoverage(self: *const Mask, x: usize, width: usize) bool {
        var row: usize = 0;
        while (row < self.height) : (row += 1) {
            const start = row * @as(usize, self.stride) + x;
            for (self.storage[start .. start + width]) |coverage| if (coverage != 0) return true;
        }
        return false;
    }
};

pub const Strip = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    stride: u32,
    alpha: []const u8,
};

pub const StripIterator = struct {
    mask: *const Mask,
    max_width: u32,
    offset: usize = 0,

    pub fn next(self: *StripIterator) ?Strip {
        if (self.max_width == 0) return null;
        const mask_width: usize = self.mask.width;
        while (self.offset < mask_width) {
            const start = self.offset;
            const width = @min(@as(usize, self.max_width), mask_width - start);
            self.offset += width;
            if (!self.mask.rangeHasCoverage(start, width)) continue;
            const byte_count = (@as(usize, self.mask.height) - 1) * @as(usize, self.mask.stride) + width;
            return .{
                .x = self.mask.origin_x + @as(i32, @intCast(start)),
                .y = self.mask.origin_y,
                .width = @intCast(width),
                .height = self.mask.height,
                .stride = self.mask.stride,
                .alpha = self.mask.storage[start .. start + byte_count],
            };
        }
        return null;
    }
};

fn coverageOver(destination: u8, source: u8) u8 {
    if (source == 0) return destination;
    if (source == 255 or destination == 0) return source;
    const inverse: u32 = 255 - @as(u32, source);
    const retained = (@as(u32, destination) * inverse + 127) / 255;
    return @intCast(@min(@as(u32, 255), @as(u32, source) + retained));
}

test "glyph masks clip and compose source-over coverage" {
    var storage: [12]u8 = undefined;
    var mask = try Mask.init(storage[0..], 10, 20, 4, 3);
    const first = [_]u8{
        0, 64,  128, 0, 99,
        0, 128, 255, 0, 99,
        0, 0,   0,   0, 99,
    };
    try std.testing.expect(mask.blend(9, 19, 4, 3, 5, first[0..]));
    try std.testing.expectEqual(@as(u8, 128), mask.storage[0]);
    try std.testing.expectEqual(@as(u8, 255), mask.storage[1]);
    try std.testing.expectEqual(@as(u8, 0), mask.storage[2]);

    const second = [_]u8{128};
    try std.testing.expect(mask.blend(10, 20, 1, 1, 1, second[0..]));
    try std.testing.expectEqual(@as(u8, 192), mask.storage[0]);
    try std.testing.expect(!mask.blend(100, 100, 1, 1, 1, second[0..]));
}

test "hundreds of glyph contributions collapse into bounded run strips" {
    var storage: [1600 * 2]u8 = undefined;
    var mask = try Mask.init(storage[0..], 7, 11, 1600, 2);
    const glyph = [_]u8{255};
    var glyph_index: usize = 0;
    while (glyph_index < 400) : (glyph_index += 1) {
        try std.testing.expect(mask.blend(7 + @as(i64, @intCast(glyph_index * 4)), 11, 1, 1, 1, glyph[0..]));
    }

    var iterator = mask.strips(512);
    var strip_count: usize = 0;
    var covered_pixels: usize = 0;
    while (iterator.next()) |strip| {
        strip_count += 1;
        var row: usize = 0;
        while (row < strip.height) : (row += 1) {
            const start = row * @as(usize, strip.stride);
            for (strip.alpha[start .. start + @as(usize, strip.width)]) |coverage| {
                if (coverage != 0) covered_pixels += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 4), strip_count);
    try std.testing.expectEqual(@as(usize, 400), covered_pixels);
}
