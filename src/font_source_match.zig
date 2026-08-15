const std = @import("std");

/// CSS local() identifies a concrete full or PostScript face name, not a
/// family. Family matching would incorrectly suppress the following URL
/// fallback when only another size, weight, or style is installed.
pub fn installedFace(concrete_face: []const u8, local_name: []const u8) bool {
    return concrete_face.len > 0 and local_name.len > 0 and std.ascii.eqlIgnoreCase(concrete_face, local_name);
}

test "CSS local source matches only a concrete installed face" {
    try std.testing.expect(installedFace("R4 Sans 16 Bold", "r4 sans 16 bold"));
    try std.testing.expect(!installedFace("R4 Sans 16 Regular", "R4 Sans"));
    try std.testing.expect(!installedFace("R4 Sans 16 Regular", "R4 Sans 16 Bold"));
    try std.testing.expect(!installedFace("", "R4 Sans"));
}
