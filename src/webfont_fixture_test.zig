const std = @import("std");
const r4font = @import("r4font");
const provider = @import("r4font_provider");

const Fixture = struct {
    path: []const u8,
    family: []const u8,
    style: []const u8,
    bold: bool,
    italic: bool,
    codepoint: u32,
    missing_codepoint: u32,
    glyph_index: u32,
    advance: i32,
    raster_width: u32 = 11,
    raster_height: u32 = 13,
    raster_sha256: []const u8 = "afd31ea366bcf62249ba0b5f4f161a31398eebfbdaf3997d13eaa68a8407e95b",
};

const fixtures = [_]Fixture{
    .{
        .path = "../../../../Tests/Fixture/Browser/Fonts06241/regular.woff",
        .family = "R4OS Web Fixture",
        .style = "Regular",
        .bold = false,
        .italic = false,
        .codepoint = 'A',
        .missing_codepoint = 0x2605,
        .glyph_index = 1,
        .advance = 620,
    },
    .{
        .path = "../../../../Tests/Fixture/Browser/Fonts06241/bold.woff",
        .family = "R4OS Web Fixture",
        .style = "Bold",
        .bold = true,
        .italic = false,
        .codepoint = 'A',
        .missing_codepoint = 0x2605,
        .glyph_index = 1,
        .advance = 720,
    },
    .{
        .path = "../../../../Tests/Fixture/Browser/Fonts06241/italic.woff",
        .family = "R4OS Web Fixture",
        .style = "Italic",
        .bold = false,
        .italic = true,
        .codepoint = 'A',
        .missing_codepoint = 0x2605,
        .glyph_index = 1,
        .advance = 670,
    },
    .{
        .path = "../../../../Tests/Fixture/Browser/Fonts06241/symbol.woff",
        .family = "R4OS Web Symbols",
        .style = "Regular",
        .bold = false,
        .italic = false,
        .codepoint = 0x2605,
        .missing_codepoint = 'A',
        .glyph_index = 1,
        .advance = 640,
    },
};

test "0.62.41 browser fixtures decode with distinct styles metrics and Unicode coverage" {
    var fonts = r4font.Context.initHeader(&provider.r4font_api_v1.header).?;
    var decoder = try fonts.createDecoder(std.testing.allocator, 16 * 1024 * 1024);
    defer decoder.deinit();
    const baseline = decoder.diagnostics().current_bytes;
    const raster_buffer = try std.testing.allocator.alloc(u8, r4font.max_raster_dimension * r4font.max_raster_dimension);
    defer std.testing.allocator.free(raster_buffer);

    for (fixtures) |fixture| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(
            std.testing.io,
            fixture.path,
            std.testing.allocator,
            .limited(r4font.max_source_bytes),
        );
        defer std.testing.allocator.free(bytes);
        try std.testing.expect(bytes.len > 0);
        try std.testing.expectEqual(r4font.Format.woff, fonts.sniff(bytes).?);
        var face = try decoder.openFace(bytes, 0);
        defer face.deinit();
        const info = try face.info();
        try std.testing.expectEqualStrings(fixture.family, info.family);
        try std.testing.expectEqualStrings(fixture.style, info.style);
        try std.testing.expectEqual(fixture.bold, info.bold);
        try std.testing.expectEqual(fixture.italic, info.italic);
        try std.testing.expectEqual(fixture.glyph_index, face.glyphIndex(fixture.codepoint));
        try std.testing.expectEqual(@as(u32, 0), face.glyphIndex(fixture.missing_codepoint));
        const metrics = try face.glyphMetrics(fixture.glyph_index);
        try std.testing.expectEqual(fixture.advance, metrics.advance_x);
        const raster = try face.rasterize(fixture.glyph_index, 18, raster_buffer);
        try std.testing.expectEqual(fixture.raster_width, raster.width);
        try std.testing.expectEqual(fixture.raster_height, raster.height);
        try std.testing.expectEqual(@as(usize, raster.width * raster.height), raster.alpha.len);
        try std.testing.expect(raster.advance_x_26_6 > 0);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(raster.alpha, &digest, .{});
        const digest_hex = std.fmt.bytesToHex(digest, .lower);
        try std.testing.expectEqualStrings(fixture.raster_sha256, &digest_hex);
    }
    try std.testing.expectEqual(baseline, decoder.diagnostics().current_bytes);
}
