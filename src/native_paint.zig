const std = @import("std");
const r4os = @import("r4os");

pub const Stats = struct {
    commands: u64 = 0,
    shape_commands: u64 = 0,
    argb_commands: u64 = 0,
    resource_bytes: u64 = 0,
    failures: u64 = 0,
    last_error: i32 = 0,

    fn record(self: *Stats, result: i32, resource_len: usize, shape: bool) bool {
        if (result < 0) {
            self.failures +|= 1;
            self.last_error = result;
            return false;
        }
        self.commands +|= 1;
        if (shape) self.shape_commands +|= 1 else self.argb_commands +|= 1;
        self.resource_bytes +|= resource_len;
        return true;
    }
};

pub const PreparedShape = struct {
    command: r4os.abi.GuiFrameCommand,
    resource_len: usize,
};

pub fn buildRoundedShape(
    output: []u8,
    kind: u32,
    target: r4os.gui.Rect,
    clipped: r4os.gui.Rect,
    radii: r4os.web_layout.PixelRadii,
    borders: r4os.web_layout.PixelEdges,
    fill_argb: u32,
    border_argb: u32,
    shadow: ?r4os.web_layout.ShadowVisual,
) r4os.gui_shapes.Error!PreparedShape {
    if (target.w <= 0 or target.h <= 0 or clipped.w <= 0 or clipped.h <= 0) return error.InvalidValue;
    const resource = try r4os.gui_shapes.roundedRect(output, .{
        .x = @floatFromInt(target.x - clipped.x),
        .y = @floatFromInt(target.y - clipped.y),
        .w = @floatFromInt(target.w),
        .h = @floatFromInt(target.h),
        .radii = shapeRadii(radii),
        .borders = .{
            .top = @floatFromInt(@max(0, borders.top)),
            .right = @floatFromInt(@max(0, borders.right)),
            .bottom = @floatFromInt(@max(0, borders.bottom)),
            .left = @floatFromInt(@max(0, borders.left)),
        },
        .fill_argb = fill_argb,
        .border_argb = border_argb,
        .shadow = if (shadow) |value| .{
            .argb = (@as(u32, value.alpha) << 24) | (value.color & 0x00FF_FFFF),
            .offset_x = @floatFromInt(value.offset_x),
            .offset_y = @floatFromInt(value.offset_y),
            .spread = @floatFromInt(value.spread),
            .blur = @floatFromInt(@max(0, value.blur)),
            .inset = value.inset,
        } else .{},
    });
    return .{
        .command = try r4os.gui_shapes.command(
            kind,
            clipped.x,
            clipped.y,
            @intCast(clipped.w),
            @intCast(clipped.h),
            0,
            resource.len,
        ),
        .resource_len = resource.len,
    };
}

pub fn appendRoundedShape(
    draw: *const r4os.r4draw.Context,
    stats: *Stats,
    kind: u32,
    target: r4os.gui.Rect,
    clipped: r4os.gui.Rect,
    radii: r4os.web_layout.PixelRadii,
    borders: r4os.web_layout.PixelEdges,
    fill_argb: u32,
    border_argb: u32,
    shadow: ?r4os.web_layout.ShadowVisual,
) bool {
    var resource: [r4os.abi.gui_shape_resource_size]u8 = undefined;
    const prepared = buildRoundedShape(resource[0..], kind, target, clipped, radii, borders, fill_argb, border_argb, shadow) catch {
        stats.failures +|= 1;
        stats.last_error = r4os.abi.gui_frame_error_invalid;
        return false;
    };
    const commands = [_]r4os.abi.GuiFrameCommand{prepared.command};
    return stats.record(draw.guiFrameAppend(commands[0..], resource[0..prepared.resource_len]), prepared.resource_len, true);
}

pub fn argb32Command(x: i32, y: i32, width: u32, height: u32, scale: u32, pixel_count: usize) ?r4os.abi.GuiFrameCommand {
    if (width == 0 or height == 0 or width > r4os.abi.gui_argb32_max_width or height > r4os.abi.gui_argb32_max_height or scale < 1 or scale > 16) return null;
    const expected = std.math.mul(usize, @as(usize, width), @as(usize, height)) catch return null;
    if (expected != pixel_count or expected > r4os.abi.gui_argb32_max_pixels) return null;
    const resource_bytes = std.math.mul(usize, expected, @sizeOf(u32)) catch return null;
    return .{
        .kind = r4os.abi.gui_frame_command_kind_argb32,
        .x = x,
        .y = y,
        .w = width,
        .h = height,
        .resource_bytes = resource_bytes,
        .parameter0 = scale,
    };
}

pub fn appendArgb32(
    draw: *const r4os.r4draw.Context,
    stats: *Stats,
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    scale: u32,
    pixels: []const u32,
) bool {
    const command = argb32Command(x, y, width, height, scale, pixels.len) orelse {
        stats.failures +|= 1;
        stats.last_error = r4os.abi.gui_frame_error_invalid;
        return false;
    };
    const commands = [_]r4os.abi.GuiFrameCommand{command};
    const resources = std.mem.sliceAsBytes(pixels);
    return stats.record(draw.guiFrameAppend(commands[0..], resources), resources.len, false);
}

pub fn xrgb32Command(x: i32, y: i32, width: u32, height: u32, scale: u32, pixel_count: usize) ?r4os.abi.GuiFrameCommand {
    if (width == 0 or height == 0 or width > r4os.abi.gui_raster_max_width or height > r4os.abi.gui_raster_max_height or scale < 1 or scale > 16) return null;
    const expected = std.math.mul(usize, @as(usize, width), @as(usize, height)) catch return null;
    if (expected != pixel_count or expected > r4os.abi.gui_raster_max_pixels) return null;
    const resource_bytes = std.math.mul(usize, expected, @sizeOf(u32)) catch return null;
    return .{
        .kind = r4os.abi.gui_frame_command_kind_raster,
        .x = x,
        .y = y,
        .w = width,
        .h = height,
        .resource_bytes = resource_bytes,
        .parameter0 = scale,
    };
}

/// Appends already-composited XRGB pixels directly to the active frame. This
/// avoids routing browser images through the legacy GUI raster/COW bridge.
pub fn appendXrgb32(
    draw: *const r4os.r4draw.Context,
    stats: *Stats,
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    scale: u32,
    pixels: []const u32,
) bool {
    const command = xrgb32Command(x, y, width, height, scale, pixels.len) orelse {
        stats.failures +|= 1;
        stats.last_error = r4os.abi.gui_frame_error_invalid;
        return false;
    };
    const commands = [_]r4os.abi.GuiFrameCommand{command};
    const resources = std.mem.sliceAsBytes(pixels);
    return stats.record(draw.guiFrameAppend(commands[0..], resources), resources.len, false);
}

fn shapeRadii(value: r4os.web_layout.PixelRadii) r4os.gui_shapes.Radii {
    return .{
        .top_left_x = @floatFromInt(@max(0, value.top_left.x)),
        .top_left_y = @floatFromInt(@max(0, value.top_left.y)),
        .top_right_x = @floatFromInt(@max(0, value.top_right.x)),
        .top_right_y = @floatFromInt(@max(0, value.top_right.y)),
        .bottom_right_x = @floatFromInt(@max(0, value.bottom_right.x)),
        .bottom_right_y = @floatFromInt(@max(0, value.bottom_right.y)),
        .bottom_left_x = @floatFromInt(@max(0, value.bottom_left.x)),
        .bottom_left_y = @floatFromInt(@max(0, value.bottom_left.y)),
    };
}

fn readU32(bytes: []const u8, offset: usize) u32 {
    return @as(u32, bytes[offset]) |
        (@as(u32, bytes[offset + 1]) << 8) |
        (@as(u32, bytes[offset + 2]) << 16) |
        (@as(u32, bytes[offset + 3]) << 24);
}

test "one native command preserves elliptical radii unequal borders and each shadow layer" {
    var resource: [r4os.abi.gui_shape_resource_size]u8 = undefined;
    const target = r4os.gui.Rect{ .x = 10, .y = 20, .w = 120, .h = 60 };
    const clipped = r4os.gui.Rect{ .x = 16, .y = 23, .w = 90, .h = 31 };
    const radii = r4os.web_layout.PixelRadii{
        .top_left = .{ .x = 17, .y = 9 },
        .top_right = .{ .x = 11, .y = 7 },
        .bottom_right = .{ .x = 5, .y = 13 },
        .bottom_left = .{ .x = 3, .y = 2 },
    };
    const prepared = try buildRoundedShape(
        resource[0..],
        r4os.abi.gui_frame_command_kind_rounded_rect,
        target,
        clipped,
        radii,
        .{ .top = 1, .right = 2, .bottom = 3, .left = 4 },
        0xFF102030,
        0xFF405060,
        null,
    );
    try std.testing.expectEqual(@as(i32, clipped.x), prepared.command.x);
    try std.testing.expectEqual(@as(u32, @intCast(clipped.w)), prepared.command.w);
    try std.testing.expectEqual(@as(u32, @bitCast(@as(f32, 17))), readU32(resource[0..], @offsetOf(r4os.abi.GuiShapeResource, "radius_top_left_x_bits")));
    try std.testing.expectEqual(@as(u32, @bitCast(@as(f32, 9))), readU32(resource[0..], @offsetOf(r4os.abi.GuiShapeResource, "radius_top_left_y_bits")));
    try std.testing.expectEqual(@as(u32, @bitCast(@as(f32, 4))), readU32(resource[0..], @offsetOf(r4os.abi.GuiShapeResource, "border_left_bits")));

    const first_shadow = try buildRoundedShape(resource[0..], r4os.abi.gui_frame_command_kind_shadow, target, clipped, radii, .{}, 0, 0, .{
        .enabled = true,
        .color = 0x112233,
        .alpha = 128,
        .offset_x = 2,
        .offset_y = 3,
        .blur = 4,
        .spread = 1,
    });
    try std.testing.expectEqual(@as(u32, 0x80112233), readU32(resource[0..], @offsetOf(r4os.abi.GuiShapeResource, "shadow_argb")));
    const second_shadow = try buildRoundedShape(resource[0..], r4os.abi.gui_frame_command_kind_shadow, target, clipped, radii, .{}, 0, 0, .{
        .enabled = true,
        .color = 0xABCDEF,
        .alpha = 64,
        .inset = true,
    });
    try std.testing.expectEqual(r4os.abi.gui_frame_command_kind_shadow, first_shadow.command.kind);
    try std.testing.expectEqual(r4os.abi.gui_frame_command_kind_shadow, second_shadow.command.kind);
    try std.testing.expectEqual(@as(u32, 0x40ABCDEF), readU32(resource[0..], @offsetOf(r4os.abi.GuiShapeResource, "shadow_argb")));
}

test "ARGB32 planning is exact and has no aggregate command cap" {
    var hash: u64 = 14695981039346656037;
    var index: usize = 0;
    while (index < 4096) : (index += 1) {
        const command = argb32Command(@intCast(index), 1, 2, 2, 1, 4) orelse return error.ExpectedCommand;
        hash = (hash ^ @as(u64, @bitCast(@as(i64, command.x)))) *% 1099511628211;
    }
    try std.testing.expect(hash != 0);
    try std.testing.expect(argb32Command(0, 0, 2, 2, 1, 3) == null);
    try std.testing.expect(argb32Command(0, 0, r4os.abi.gui_argb32_max_width + 1, 1, 1, r4os.abi.gui_argb32_max_width + 1) == null);
}

test "XRGB32 browser image planning uses the native frame raster contract" {
    const command = xrgb32Command(4, 5, 90, 30, 3, 2700) orelse return error.ExpectedCommand;
    try std.testing.expectEqual(r4os.abi.gui_frame_command_kind_raster, command.kind);
    try std.testing.expectEqual(@as(u64, 3), command.parameter0);
    try std.testing.expectEqual(@as(u64, 2700 * @sizeOf(u32)), command.resource_bytes);
    try std.testing.expect(xrgb32Command(0, 0, r4os.abi.gui_raster_max_width + 1, 1, 1, r4os.abi.gui_raster_max_width + 1) == null);
}
