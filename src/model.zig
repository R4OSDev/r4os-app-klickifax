const std = @import("std");
const r4os = @import("r4os");
const abi = r4os.abi;
const navigation = r4os.web_navigation;

pub const url_capacity = navigation.url_capacity;
pub const history_capacity = navigation.history_capacity;
pub const UrlError = navigation.UrlError;
pub const Scheme = navigation.Scheme;
pub const Url = navigation.Url;
pub const History = navigation.History;

pub const RasterPlan = struct {
    width: u32,
    height: u32,
    scale: u32,
    pixels: usize,
};

/// Fits a displayed image into one bounded R4DRAW raster command. The command
/// scale restores most or all of the requested display size without copying a
/// full-resolution browser image into the per-frame GUI raster payload.
pub fn planRaster(target_width: u32, target_height: u32, pixel_budget: usize) ?RasterPlan {
    if (target_width == 0 or target_height == 0 or pixel_budget == 0) return null;
    var scale: u32 = 1;
    while (scale <= 16) : (scale += 1) {
        const width = @max(@as(u32, 1), target_width / scale);
        const height = @max(@as(u32, 1), target_height / scale);
        if (width > abi.gui_raster_max_width or height > abi.gui_raster_max_height) continue;
        const pixels = std.math.mul(usize, width, height) catch return null;
        if (pixels <= pixel_budget and pixels <= abi.gui_raster_max_pixels) {
            return .{ .width = width, .height = height, .scale = scale, .pixels = pixels };
        }
    }
    return null;
}

pub fn parse(raw: []const u8) UrlError!Url {
    return navigation.parse(raw);
}

pub fn resolve(base: *const Url, reference: []const u8) UrlError!Url {
    return navigation.resolve(base, reference);
}

pub const PageKind = enum {
    blank,
    home,
    fixture_one,
    fixture_two,
    search,
    search_results,
    explicit_error,
    internal_not_found,
    remote_document,
    invalid_address,
};

pub const Page = struct {
    kind: PageKind,
    title: []const u8,
    heading: []const u8,
    lines: []const []const u8,
};

const no_lines = [_][]const u8{};
const home_lines = [_][]const u8{
    "Welcome to the first Klickifax browser shell.",
    "Open about:search to use the local form and navigation fixture.",
    "HTTP and HTTPS use the shared R4OS web transport.",
};
const fixture_one_lines = [_][]const u8{
    "This is deterministic local page one.",
    "Navigate to about:fixture-two, then use Back and Forward.",
};
const fixture_two_lines = [_][]const u8{
    "This is deterministic local page two.",
    "Reload keeps the current history entry.",
};
const search_lines = [_][]const u8{
    "This local HTML page contains a keyboard-accessible GET search form.",
};
const results_lines = [_][]const u8{
    "This local HTML page displays deterministic result links.",
};
const explicit_error_lines = [_][]const u8{
    "This deterministic page verifies the browser error presentation.",
    "No network request was made.",
};
const missing_lines = [_][]const u8{
    "Klickifax does not know this internal page.",
    "Open about:klickifax to return home.",
};
const invalid_lines = [_][]const u8{
    "The entered address is empty, malformed or uses an unsupported scheme.",
    "Try about:klickifax or an HTTP/HTTPS address.",
};

pub fn pageFor(url: *const Url) Page {
    if (url.scheme == .http or url.scheme == .https) {
        return .{ .kind = .remote_document, .title = "Remote document", .heading = "", .lines = no_lines[0..] };
    }
    const name = internalName(url.bytes());
    if (std.mem.eql(u8, name, "about:blank")) return .{ .kind = .blank, .title = "Blank page", .heading = "", .lines = no_lines[0..] };
    if (std.mem.eql(u8, name, "about:klickifax")) return .{ .kind = .home, .title = "Klickifax", .heading = "Klickifax", .lines = home_lines[0..] };
    if (std.mem.eql(u8, name, "about:fixture-one")) return .{ .kind = .fixture_one, .title = "Fixture One", .heading = "Local page one", .lines = fixture_one_lines[0..] };
    if (std.mem.eql(u8, name, "about:fixture-two")) return .{ .kind = .fixture_two, .title = "Fixture Two", .heading = "Local page two", .lines = fixture_two_lines[0..] };
    if (std.mem.eql(u8, name, "about:search")) return .{ .kind = .search, .title = "Local Search", .heading = "Local search fixture", .lines = search_lines[0..] };
    if (std.mem.eql(u8, name, "about:search-results")) return .{ .kind = .search_results, .title = "Search Results", .heading = "Local search results", .lines = results_lines[0..] };
    if (std.mem.eql(u8, name, "about:error")) return .{ .kind = .explicit_error, .title = "Klickifax Error", .heading = "Something went wrong", .lines = explicit_error_lines[0..] };
    return .{ .kind = .internal_not_found, .title = "Page not found", .heading = "Internal page not found", .lines = missing_lines[0..] };
}

pub fn invalidPage() Page {
    return .{ .kind = .invalid_address, .title = "Invalid address", .heading = "Invalid address", .lines = invalid_lines[0..] };
}

pub const Browser = struct {
    history: History,
    page: Page,
    last_error: ?UrlError = null,

    pub fn init() Browser {
        const home = parse("about:klickifax") catch unreachable;
        return .{ .history = History.init(home), .page = pageFor(&home) };
    }

    pub fn currentUrl(self: *const Browser) *const Url {
        return self.history.current();
    }

    pub fn canBack(self: *const Browser) bool {
        return self.history.canBack();
    }

    pub fn canForward(self: *const Browser) bool {
        return self.history.canForward();
    }

    pub fn navigate(self: *Browser, input: []const u8) bool {
        const next = if (navigation.isRelativeReference(input))
            resolve(self.currentUrl(), input)
        else
            parse(input);
        const url = next catch |err| {
            self.last_error = err;
            self.page = invalidPage();
            return false;
        };
        self.last_error = null;
        self.history.navigate(url);
        self.page = pageFor(self.currentUrl());
        return true;
    }

    pub fn replaceAfterRedirect(self: *Browser, input: []const u8) bool {
        const url = parse(input) catch |err| {
            self.last_error = err;
            return false;
        };
        self.last_error = null;
        self.history.replaceCurrent(url);
        self.page = pageFor(self.currentUrl());
        return true;
    }

    pub fn pushState(self: *Browser, input: []const u8) bool {
        const url = parse(input) catch |err| {
            self.last_error = err;
            return false;
        };
        self.last_error = null;
        self.history.push(url);
        self.page = pageFor(self.currentUrl());
        return true;
    }

    pub fn back(self: *Browser) bool {
        if (!self.history.back()) return false;
        self.last_error = null;
        self.page = pageFor(self.currentUrl());
        return true;
    }

    pub fn forward(self: *Browser) bool {
        if (!self.history.forward()) return false;
        self.last_error = null;
        self.page = pageFor(self.currentUrl());
        return true;
    }

    pub fn go(self: *Browser, delta: i32) bool {
        if (!self.history.go(delta)) return false;
        self.last_error = null;
        self.page = pageFor(self.currentUrl());
        return true;
    }

    pub fn reload(self: *Browser) void {
        self.last_error = null;
        self.page = pageFor(self.currentUrl());
    }
};

fn internalName(value: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, value, '?') orelse value.len;
    return value[0..end];
}

test "browser raster plan uses R4DRAW scale without exceeding its payload" {
    const eiffel = planRaster(136, 200, abi.gui_raster_max_pixels).?;
    try std.testing.expectEqual(@as(u32, 68), eiffel.width);
    try std.testing.expectEqual(@as(u32, 100), eiffel.height);
    try std.testing.expectEqual(@as(u32, 2), eiffel.scale);
    try std.testing.expectEqual(@as(usize, 6800), eiffel.pixels);

    const shared = planRaster(300, 201, abi.gui_raster_max_pixels / 2).?;
    try std.testing.expectEqual(@as(u32, 100), shared.width);
    try std.testing.expectEqual(@as(u32, 67), shared.height);
    try std.testing.expectEqual(@as(u32, 3), shared.scale);
    try std.testing.expect(shared.pixels <= abi.gui_raster_max_pixels / 2);
    try std.testing.expect(planRaster(4096, 4096, abi.gui_raster_max_pixels) == null);
}

test "URL parsing uses reusable normalization and rejects unsupported schemes" {
    const url = try parse(" Example.COM/a/./b/../c ");
    try std.testing.expectEqual(Scheme.https, url.scheme);
    try std.testing.expectEqualStrings("https://example.com/a/c", url.bytes());
    const internal = try parse("ABOUT:Search-Results?q=R4OS+Browser");
    try std.testing.expectEqualStrings("about:search-results?q=R4OS+Browser", internal.bytes());
    try std.testing.expectError(error.UnsupportedScheme, parse("ftp://example.com/file"));
}

test "relative URL resolution handles path query fragment and scheme-relative forms" {
    const base = try parse("https://Example.com/a/b/index.html?old=1#top");
    try std.testing.expectEqualStrings("https://example.com/a/next?q=2", (try resolve(&base, "../next?q=2")).bytes());
    try std.testing.expectEqualStrings("https://example.com/a/b/index.html?q=3", (try resolve(&base, "?q=3")).bytes());
    try std.testing.expectEqualStrings("https://example.com/a/b/index.html?old=1#section", (try resolve(&base, "#section")).bytes());
    try std.testing.expectEqualStrings("https://other.example/x", (try resolve(&base, "//Other.example/x")).bytes());
}

test "bounded history supports branch replacement eviction and redirects" {
    var history = History.init(try parse("about:klickifax"));
    history.navigate(try parse("about:fixture-one"));
    history.navigate(try parse("about:fixture-two"));
    try std.testing.expect(history.back());
    history.navigate(try parse("about:error"));
    try std.testing.expect(!history.canForward());
    history.replaceCurrent(try parse("about:fixture-one"));
    try std.testing.expectEqualStrings("about:fixture-one", history.current().bytes());

    var number: usize = 0;
    while (number < history_capacity + 4) : (number += 1) {
        var text: [64]u8 = undefined;
        history.navigate(try parse(try std.fmt.bufPrint(text[0..], "https://example.com/{d}", .{number})));
    }
    try std.testing.expectEqual(history_capacity, history.count);
    try std.testing.expectEqual(history_capacity - 1, history.index);
}

test "browser presents local search remote and error documents" {
    var browser = Browser.init();
    try std.testing.expect(browser.navigate("about:search"));
    try std.testing.expectEqual(PageKind.search, browser.page.kind);
    try std.testing.expect(browser.navigate("about:search-results?q=R4OS"));
    try std.testing.expectEqual(PageKind.search_results, browser.page.kind);
    try std.testing.expect(browser.navigate("google.com"));
    try std.testing.expectEqual(PageKind.remote_document, browser.page.kind);
    try std.testing.expect(browser.replaceAfterRedirect("https://www.google.com/"));
    try std.testing.expectEqualStrings("https://www.google.com/", browser.currentUrl().bytes());
    try std.testing.expect(!browser.navigate("ftp://example.com"));
    try std.testing.expectEqual(PageKind.invalid_address, browser.page.kind);
}
