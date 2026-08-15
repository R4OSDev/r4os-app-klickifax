const std = @import("std");
const r4os = @import("r4os");

pub const settings_path = "C:\\R4OS\\CONFIG\\APPS\\KLICKIFAX.R4S";
pub const app_data_root = "C:\\R4OS\\APPDATA";
pub const browser_data_root = "C:\\R4OS\\APPDATA\\KLICKIFAX";
pub const profile_dir = "C:\\R4OS\\APPDATA\\KLICKIFAX\\PROFILE";
pub const profile_storage_path = "C:\\R4OS\\APPDATA\\KLICKIFAX\\PROFILE\\WEBSTORAGE.DAT";
pub const temp_root = "C:\\R4OS\\Temp";
pub const temp_dir = "C:\\R4OS\\Temp\\Klickifax";
pub const cache_dir = "C:\\R4OS\\Temp\\Klickifax\\Cache";
pub const work_dir = "C:\\R4OS\\Temp\\Klickifax\\Work";
pub const font_cache_dir = r4os.web_font_cache.root_path[0 .. r4os.web_font_cache.root_path.len - 1];
pub const font_objects_dir = r4os.web_font_cache.objects_path[0 .. r4os.web_font_cache.objects_path.len - 1];
pub const font_staging_dir = r4os.web_font_cache.staging_path[0 .. r4os.web_font_cache.staging_path.len - 1];
pub const font_catalog_path = r4os.web_font_cache.catalog_path;
pub const legacy_storage_path = "C:\\R4OS\\CONFIG\\KLICKIFAX.DAT";

pub const LoadSource = enum(u8) {
    none,
    profile,
    legacy,
};

pub fn chooseLoadSource(profile_valid: bool, legacy_valid: bool) LoadSource {
    if (profile_valid) return .profile;
    if (legacy_valid) return .legacy;
    return .none;
}

pub fn migrationVerified(source: []const u8, written: ?usize, verified: ?[]const u8) bool {
    const write_count = written orelse return false;
    const destination = verified orelse return false;
    return write_count == source.len and std.mem.eql(u8, source, destination);
}

test "Klickifax data layout separates settings profile cache and temporary data" {
    try std.testing.expect(std.mem.startsWith(u8, settings_path, "C:\\R4OS\\CONFIG\\APPS\\"));
    try std.testing.expect(std.mem.startsWith(u8, profile_storage_path, profile_dir));
    try std.testing.expect(std.mem.startsWith(u8, cache_dir, temp_dir));
    try std.testing.expect(std.mem.startsWith(u8, work_dir, temp_dir));
    try std.testing.expect(!std.mem.eql(u8, cache_dir, work_dir));
    try std.testing.expect(std.mem.startsWith(u8, font_cache_dir, cache_dir));
    try std.testing.expect(std.mem.startsWith(u8, font_objects_dir, font_cache_dir));
    try std.testing.expect(std.mem.startsWith(u8, font_staging_dir, font_cache_dir));
    try std.testing.expect(std.mem.startsWith(u8, font_catalog_path, font_cache_dir));
    try std.testing.expect(std.mem.startsWith(u8, temp_dir, temp_root));
    try std.testing.expect(!std.mem.startsWith(u8, profile_storage_path, cache_dir));
    try std.testing.expect(!std.mem.startsWith(u8, profile_storage_path, temp_dir));
    try std.testing.expect(!std.mem.eql(u8, profile_storage_path, legacy_storage_path));
}

test "legacy migration retires its source only after exact verification" {
    const bytes = "R4WB fixture";
    try std.testing.expect(migrationVerified(bytes, bytes.len, bytes));
    try std.testing.expect(!migrationVerified(bytes, bytes.len - 1, bytes));
    try std.testing.expect(!migrationVerified(bytes, bytes.len, "R4WB fixturE"));
    try std.testing.expect(!migrationVerified(bytes, null, bytes));
    try std.testing.expect(!migrationVerified(bytes, bytes.len, null));
    try std.testing.expectEqual(LoadSource.profile, chooseLoadSource(true, true));
    try std.testing.expectEqual(LoadSource.legacy, chooseLoadSource(false, true));
    try std.testing.expectEqual(LoadSource.none, chooseLoadSource(false, false));
}
