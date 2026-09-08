const std = @import("std");
const r4os = @import("r4os");
const cache = r4os.web_response_cache;
const http = r4os.http;
const web = r4os.app_web;

pub const ClockSource = struct {
    context: ?*anyopaque,
    read: *const fn (?*anyopaque) cache.Clock,
    fn now(self: ClockSource) cache.Clock {
        return self.read(self.context);
    }
};
pub const Options = struct {
    transport: web.FetchOptions = .{},
    mode: cache.Mode = .normal,
    partition: []const u8 = "",
    clock: ClockSource,
};
pub const Result = struct {
    value: web.FetchResult,
    response_identity: u64 = 0,
    only_cache_miss: bool = false,
};

pub const Adapter = struct {
    storage: cache.Cache,
    transport_fetches: u64 = 0,
    revalidated: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) Adapter {
        return .{ .storage = cache.Cache.init(allocator, .{}) };
    }
    pub fn deinit(self: *Adapter) void {
        self.storage.deinit();
    }

    /// All cache operations are owner-only. The transaction pins an old entry
    /// while a worker transports the request; it owns generated header bytes.
    pub fn prepare(self: *Adapter, transaction: *Transaction, url: []const u8, raw: []u8, body: []u8, options: Options) ?Result {
        const opts = options.transport;
        transaction.* = .{ .adapter = self, .url = url, .options = options, .raw = raw, .body = body };
        if (stopped(opts)) return failure(.cancelled);
        if (opts.target_authorizer) |authorize| if (!authorize(opts.target_authorization_context, url)) return failure(.policy_rejected);
        const parsed = switch (http.parseUrl(url)) {
            .value => |value| value,
            else => return failure(.invalid_url),
        };

        const cookie = opts.initial_cookie orelse if (opts.cookie_provider) |provider| provider(opts.cookie_context, url, &transaction.cookie_buffer) else opts.cookie;

        const effective_headers = switch (http.buildRequest(&transaction.request_buffer, opts.method, parsed, .{ .headers = opts.headers, .cookie = cookie, .origin = opts.origin, .content_type = opts.content_type, .body = opts.body })) {
            .bytes => |bytes| bytes,
            else => return failure(.request_too_large),
        };

        const context = std.fmt.bufPrint(&transaction.context_buffer, "{s}\n{s}\ncors={d};credentials={d};redirect={s}", .{ options.partition, opts.origin, @intFromBool(opts.cors), @intFromBool(opts.credentials_include), @tagName(opts.redirect) }) catch return failure(.request_too_large);
        transaction.key = .{ .url = url, .context = context, .headers = effective_headers };
        const eligible = opts.method == .get and opts.body.len == 0 and
            cache.header(opts.headers, "Authorization") == null and cache.header(opts.headers, "Range") == null and
            cache.header(opts.headers, "If-None-Match") == null and cache.header(opts.headers, "If-Modified-Since") == null and
            cache.header(opts.headers, "If-Match") == null and cache.header(opts.headers, "If-Unmodified-Since") == null and cache.header(opts.headers, "If-Range") == null;
        const controls = cache.directives(opts.headers);
        if (options.mode == .only_if_cached and controls.no_store) return .{ .value = .{ .failure = .read_failed }, .only_cache_miss = true };
        var mode = options.mode;
        if (controls.no_store) mode = .no_store else if (mode == .normal and (controls.no_cache or controls.max_age == 0 or controls.invalid_age)) mode = .no_cache;
        const started = options.clock.now();
        const lookup = if (eligible) self.storage.lookup(transaction.key, mode, started) else cache.Lookup{ .action = if (mode == .only_if_cached) .only_miss else .miss };
        transaction.handle = lookup.handle;

        if (lookup.action == .only_miss) return .{ .value = .{ .failure = .read_failed }, .only_cache_miss = true };
        if (lookup.action == .hit) {
            const stored = self.storage.view(transaction.handle.?, started).?;
            const result = materialize(stored, url, parsed.scheme == .https, raw, body);
            transaction.deinit();
            return result;
        }

        transaction.network_options = opts;
        const request_options = &transaction.network_options;
        request_options.network_partition = options.partition;
        request_options.initial_cookie = cookie;

        var cache_header_len: usize = 0;
        const control_value: []const u8 = switch (mode) {
            .no_store, .reload => "no-cache",
            .no_cache => "max-age=0",
            else => "",
        };
        if (control_value.len != 0 and cache.header(opts.headers, "Cache-Control") == null) {
            const line = std.fmt.bufPrint(&transaction.cache_headers, "Cache-Control: {s}\n", .{control_value}) catch unreachable;
            cache_header_len = line.len;
        }
        if ((mode == .no_store or mode == .reload) and cache.header(opts.headers, "Pragma") == null) {
            const line = std.fmt.bufPrint(transaction.cache_headers[cache_header_len..], "Pragma: no-cache\n", .{}) catch unreachable;
            cache_header_len += line.len;
        }
        request_options.cache_headers = transaction.cache_headers[0..cache_header_len];
        if (lookup.action == .revalidate) {
            const stored = self.storage.view(transaction.handle.?, started).?;
            var used: usize = 0;
            for ([_][2][]const u8{ .{ "ETag", "If-None-Match" }, .{ "Last-Modified", "If-Modified-Since" } }) |pair| {
                if (cache.header(stored.headers, pair[0])) |value| {
                    const appended = std.fmt.bufPrint(transaction.conditional[used..], "{s}: {s}\n", .{ pair[1], value }) catch {
                        transaction.deinit();
                        return failure(.request_too_large);
                    };
                    used += appended.len;
                }
            }
            request_options.conditional_headers = transaction.conditional[0..used];
        }
        transaction.eligible = eligible;
        transaction.mode = mode;
        transaction.started = started;
        transaction.secure = parsed.scheme == .https;
        self.transport_fetches +|= 1;
        return null;
    }

    pub fn fetch(self: *Adapter, transport: anytype, url: []const u8, raw: []u8, body: []u8, scratch: []u8, options: Options) Result {
        var transaction: Transaction = undefined;
        if (self.prepare(&transaction, url, raw, body, options)) |result| return result;
        defer transaction.deinit();
        while (true) {
            const result = transport.fetch(url, raw, body, scratch, transaction.network_options);
            if (transaction.finish(result)) |finished| return finished;
        }
    }
};

/// Initialize with Adapter.prepare; keep its address and borrowed request data
/// stable until finish/deinit. A null finish result requests one validator retry.
pub const Transaction = struct {
    adapter: *Adapter,
    url: []const u8,
    options: Options,
    raw: []u8,
    body: []u8,
    key: cache.Key = undefined,
    handle: ?cache.Handle = null,
    eligible: bool = false,
    mode: cache.Mode = .normal,
    started: cache.Clock = .{ .monotonic_ms = 0 },
    secure: bool = false,
    network_options: web.FetchOptions = .{},
    cookie_buffer: [1024]u8 = undefined,
    request_buffer: [cache.max_key_bytes]u8 = undefined,
    context_buffer: [2048]u8 = undefined,
    conditional: [cache.max_header_bytes]u8 = undefined,
    cache_headers: [128]u8 = undefined,

    pub fn deinit(self: *Transaction) void {
        if (self.handle) |held| self.adapter.storage.release(held);
        self.handle = null;
    }

    /// A null result means retry using network_options and the same buffers
    /// and absolute deadline. No cache or DOM state is touched by a worker.
    pub fn finish(self: *Transaction, result: web.FetchResult) ?Result {
        const storage = &self.adapter.storage;
        if (stopped(self.options.transport)) {
            self.deinit();
            return failure(.cancelled);
        }
        if (result == .response and result.response.status == 304 and self.handle != null and self.network_options.conditional_headers.len != 0) {
            const stored = storage.view(self.handle.?, self.options.clock.now()).?;
            const returned_tag = cache.header(result.response.headers, "ETag");
            const old_tag = cache.header(stored.headers, "ETag");
            const matching = returned_tag == null or (old_tag != null and std.mem.eql(u8, returned_tag.?, old_tag.?));
            var merged_buffer: [cache.max_header_bytes]u8 = undefined;
            const merged = if (matching) mergeHeaders(stored.headers, result.response.headers, stored.body.len, null, &merged_buffer) else null;
            if (merged) |headers| {
                const restored = materialize(.{ .headers = headers, .body = stored.body, .identity = stored.identity, .age_seconds = cache.initialAgeSeconds(headers, self.options.clock.now(), self.started.monotonic_ms) }, self.url, self.secure, self.raw, self.body);
                self.deinit();
                if (restored.value == .response) {
                    self.adapter.revalidated +|= 1;
                    if (self.mode != .no_store) _ = storage.store(self.key, headers, restored.value.response.body, self.options.clock.now(), self.started.monotonic_ms, stored.identity) catch null;
                }
                return restored;
            }
            self.network_options.conditional_headers = "";
            self.adapter.transport_fetches +|= 1;
            return null;
        }
        self.deinit();
        if (result == .response) {
            const response = result.response;
            const method = self.options.transport.method;
            if (method != .get and method != .head and response.status >= 200 and response.status < 400) {
                storage.invalidateUrl(self.url);
                storage.invalidateUrl(response.final_url.bytes());
            }
            const identity = storage.newIdentity();
            if (self.eligible and self.mode != .no_store) {
                if (response.status == 200 and response.redirects == 0 and !response.manual_redirect) {
                    var headers_buffer: [cache.max_header_bytes]u8 = undefined;
                    if (mergeHeaders(response.headers, "", response.body.len, null, &headers_buffer)) |headers| {
                        _ = storage.store(self.key, headers, response.body, self.options.clock.now(), self.started.monotonic_ms, identity) catch null;
                    } else storage.invalidate(self.key);
                } else storage.invalidate(self.key);
            }
            return .{ .value = result, .response_identity = identity };
        }
        return .{ .value = result };
    }
};

fn failure(err: web.Error) Result {
    return .{ .value = .{ .failure = err } };
}
fn stopped(options: web.FetchOptions) bool {
    if (options.stop) |flag| if (@atomicLoad(u32, &flag.value, .acquire) != 0) return true;
    if (options.progress) |progress| return !progress(options.progress_context);
    return false;
}
fn excludedHeader(name: []const u8) bool {
    for ([_][]const u8{ "Set-Cookie", "Connection", "Keep-Alive", "Proxy-Authenticate", "Proxy-Authorization", "TE", "Trailer", "Transfer-Encoding", "Upgrade", "Content-Length", "Warning" }) |excluded|
        if (std.ascii.eqlIgnoreCase(name, excluded)) return true;
    return false;
}
fn connectionHeader(headers: []const u8, name: []const u8) bool {
    var iterator = cache.HeaderIterator.init(headers);
    while (iterator.next()) |item| {
        if (!std.ascii.eqlIgnoreCase(item.name, "Connection")) continue;
        var tokens = std.mem.splitScalar(u8, item.value, ',');
        while (tokens.next()) |token| if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, token, " \t"), name)) return true;
    }
    return false;
}
fn mergeHeaders(previous: []const u8, update: []const u8, body_len: usize, age: ?u64, out: []u8) ?[]const u8 {
    var used: usize = 0;
    for ([_][]const u8{ previous, update }, 0..) |headers, pass| {
        var iterator = cache.HeaderIterator.init(headers);
        while (iterator.next()) |item| {
            if (excludedHeader(item.name) or connectionHeader(previous, item.name) or connectionHeader(update, item.name) or (age != null and std.ascii.eqlIgnoreCase(item.name, "Age")) or
                (pass == 0 and cache.header(update, item.name) != null)) continue;
            const line = std.fmt.bufPrint(out[used..], "{s}: {s}\r\n", .{ item.name, item.value }) catch return null;
            used += line.len;
        }
    }
    const length = std.fmt.bufPrint(out[used..], "Content-Length: {d}\r\n", .{body_len}) catch return null;
    used += length.len;
    if (age) |seconds| {
        const line = std.fmt.bufPrint(out[used..], "Age: {d}\r\n", .{seconds}) catch return null;
        used += line.len;
    }
    return out[0..used];
}
fn materialize(stored: cache.View, url: []const u8, secure: bool, raw: []u8, body: []u8) Result {
    if (stored.body.len > body.len) return failure(.response_too_large);
    const headers = mergeHeaders(stored.headers, "", stored.body.len, stored.age_seconds, raw) orelse return failure(.response_too_large);
    var final_url: web.FinalUrl = .{};
    if (url.len > final_url.storage.len) return failure(.invalid_url);
    @memcpy(final_url.storage[0..url.len], url);
    final_url.len = url.len;
    @memcpy(body[0..stored.body.len], stored.body);
    return .{ .response_identity = stored.identity, .value = .{ .response = .{
        .status = 200,
        .body = body[0..stored.body.len],
        .headers = headers,
        .content_type = cache.header(headers, "Content-Type"),
        .content_security_policy = cache.header(headers, "Content-Security-Policy"),
        .access_control_allow_origin = cache.header(headers, "Access-Control-Allow-Origin"),
        .access_control_allow_credentials = if (cache.header(headers, "Access-Control-Allow-Credentials")) |value| std.mem.eql(u8, value, "true") else false,
        .set_cookie = null,
        .set_cookies = .{null} ** http.max_set_cookie_headers,
        .set_cookie_count = 0,
        .redirects = 0,
        .manual_redirect = false,
        .secure = secure,
        .final_url = final_url,
    } } };
}

// Resource completion may synchronously load a subdocument and reuse the
// transport buffers. Shared consumers therefore hold one bounded snapshot.
pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    memory: []u8,
    response: web.FetchResponse,

    pub fn init(allocator: std.mem.Allocator, response: web.FetchResponse) !Snapshot {
        const size = try std.math.add(usize, response.headers.len, response.body.len);
        const memory = try allocator.alloc(u8, size);
        @memcpy(memory[0..response.headers.len], response.headers);
        @memcpy(memory[response.headers.len..], response.body);
        var copy = response;
        copy.headers = memory[0..response.headers.len];
        copy.body = memory[response.headers.len..];
        copy.content_type = cache.header(copy.headers, "Content-Type");
        copy.content_security_policy = cache.header(copy.headers, "Content-Security-Policy");
        copy.access_control_allow_origin = cache.header(copy.headers, "Access-Control-Allow-Origin");
        copy.set_cookie = null;
        copy.set_cookies = .{null} ** http.max_set_cookie_headers;
        copy.set_cookie_count = 0;
        return .{ .allocator = allocator, .memory = memory, .response = copy };
    }
    pub fn deinit(self: *Snapshot) void {
        self.allocator.free(self.memory);
    }
};

const Fixture = struct {
    time: cache.Clock = .{ .monotonic_ms = 1000 },
    calls: usize = 0,
    body_text: []const u8 = "one",
    tag: []const u8 = "\"v1\"",
    control: []const u8 = "max-age=60",
    vary: []const u8 = "Accept",
    cookie: []const u8 = "",
    validators: usize = 0,
    stopped_on_fetch: ?*r4os.abi.R4StopFlag = null,

    fn clock(raw: ?*anyopaque) cache.Clock {
        const self: *Fixture = @ptrCast(@alignCast(raw.?));
        return self.time;
    }
    fn cookies(raw: ?*anyopaque, _: []const u8, _: []u8) []const u8 {
        const self: *Fixture = @ptrCast(@alignCast(raw.?));
        return self.cookie;
    }
    fn options(self: *Fixture, mode: cache.Mode) Options {
        return .{ .mode = mode, .partition = "document", .clock = .{ .context = self, .read = clock }, .transport = .{ .cookie_provider = cookies, .cookie_context = self } };
    }
    pub fn fetch(self: *Fixture, url: []const u8, raw: []u8, body: []u8, _: []u8, options_: web.FetchOptions) web.FetchResult {
        self.calls += 1;
        self.time.monotonic_ms += 10;
        std.debug.assert(std.mem.eql(u8, options_.initial_cookie.?, self.cookie));
        const validator = cache.header(options_.conditional_headers, "If-None-Match");
        if (validator != null) {
            self.validators += 1;
            std.debug.assert(cache.header(options_.headers, "If-None-Match") == null);
        }
        const unchanged = if (validator) |value| std.mem.eql(u8, value, self.tag) else false;
        const headers = std.fmt.bufPrint(raw, "Content-Type: text/plain\r\nCache-Control: {s}\r\nETag: {s}\r\nVary: {s}\r\nSet-Cookie: fixture=once\r\n", .{ self.control, self.tag, self.vary }) catch unreachable;
        var final: web.FinalUrl = .{};
        @memcpy(final.storage[0..url.len], url);
        final.len = url.len;
        if (!unchanged) @memcpy(body[0..self.body_text.len], self.body_text);
        if (self.stopped_on_fetch) |flag| @atomicStore(u32, &flag.value, 1, .release);
        return .{ .response = .{ .status = if (unchanged) 304 else 200, .body = body[0..if (unchanged) 0 else self.body_text.len], .headers = headers, .content_type = cache.header(headers, "Content-Type"), .content_security_policy = null, .access_control_allow_origin = null, .access_control_allow_credentials = false, .set_cookie = cache.header(headers, "Set-Cookie"), .set_cookies = .{null} ** http.max_set_cookie_headers, .set_cookie_count = 0, .redirects = 0, .manual_redirect = false, .secure = false, .final_url = final } };
    }
};

test "overlapping cache transactions retain independent bytes and release cancelled pins" {
    var adapter = Adapter.init(std.testing.allocator);
    defer adapter.deinit();
    var fixture: Fixture = .{};
    var raw_a: [4096]u8 = undefined;
    var raw_b: [4096]u8 = undefined;
    var body_a: [128]u8 = undefined;
    var body_b: [128]u8 = undefined;
    var a: Transaction = undefined;
    var b: Transaction = undefined;
    const url_a = "http://cache.example/a";
    const url_b = "http://cache.example/b";
    try std.testing.expect(adapter.prepare(&a, url_a, &raw_a, &body_a, fixture.options(.normal)) == null);
    defer a.deinit();
    try std.testing.expect(adapter.prepare(&b, url_b, &raw_b, &body_b, fixture.options(.normal)) == null);
    defer b.deinit();
    const result_a = fixture.fetch(url_a, &raw_a, &body_a, &.{}, a.network_options);
    fixture.body_text = "two";
    const result_b = fixture.fetch(url_b, &raw_b, &body_b, &.{}, b.network_options);
    const finished_b = b.finish(result_b).?;
    const finished_a = a.finish(result_a).?;
    try std.testing.expectEqualStrings("one", finished_a.value.response.body);
    try std.testing.expectEqualStrings("two", finished_b.value.response.body);
    try std.testing.expect(finished_a.response_identity != finished_b.response_identity);
    try std.testing.expectEqualStrings("document", a.network_options.network_partition);

    var stop: r4os.abi.R4StopFlag = .{};
    var options = fixture.options(.no_cache);
    options.transport.stop = &stop;
    options.transport.absolute_deadline = .{ .deadline_tick = 42 };
    try std.testing.expect(adapter.prepare(&a, url_a, &raw_a, &body_a, options) == null);
    try std.testing.expect(a.handle != null);
    const before = adapter.storage.bytes;
    adapter.storage.invalidateUrl(url_a);
    try std.testing.expectEqual(before, adapter.storage.bytes);
    @atomicStore(u32, &stop.value, 1, .release);
    try std.testing.expectEqual(web.Error.cancelled, a.finish(result_a).?.value.failure);
    try std.testing.expect(a.handle == null and adapter.storage.bytes < before);
    try std.testing.expectEqual(@as(u64, 42), a.network_options.absolute_deadline.?.deadline_tick);
}

test "cached transport separates modes and merges validators without repeating cookie effects" {
    var adapter = Adapter.init(std.testing.allocator);
    defer adapter.deinit();
    var fixture: Fixture = .{};
    var raw: [4096]u8 = undefined;
    var body: [128]u8 = undefined;
    const url = "http://cache.example/a";
    const miss = adapter.fetch(&fixture, url, &raw, &body, &.{}, fixture.options(.only_if_cached));
    try std.testing.expect(miss.only_cache_miss);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    const first = adapter.fetch(&fixture, url, &raw, &body, &.{}, fixture.options(.normal));
    try std.testing.expectEqualStrings("one", first.value.response.body);
    const identity = first.response_identity;
    body[0] = 'X';
    const hit = adapter.fetch(&fixture, url, &raw, &body, &.{}, fixture.options(.normal));
    try std.testing.expectEqualStrings("one", hit.value.response.body);
    try std.testing.expectEqual(identity, hit.response_identity);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expect(hit.value.response.set_cookie == null and cache.header(hit.value.response.headers, "Set-Cookie") == null);
    const validated = adapter.fetch(&fixture, url, &raw, &body, &.{}, fixture.options(.no_cache));
    try std.testing.expectEqual(@as(u16, 200), validated.value.response.status);
    try std.testing.expectEqualStrings("one", validated.value.response.body);
    try std.testing.expectEqual(identity, validated.response_identity);
    try std.testing.expectEqual(@as(usize, 1), fixture.validators);
    fixture.body_text = "two";
    fixture.tag = "\"v2\"";
    try std.testing.expectEqualStrings("two", adapter.fetch(&fixture, url, &raw, &body, &.{}, fixture.options(.no_store)).value.response.body);
    try std.testing.expectEqualStrings("one", adapter.fetch(&fixture, url, &raw, &body, &.{}, fixture.options(.force_cache)).value.response.body);
    const reload = adapter.fetch(&fixture, url, &raw, &body, &.{}, fixture.options(.reload));
    try std.testing.expectEqualStrings("two", reload.value.response.body);
    try std.testing.expect(reload.response_identity != identity);
    try std.testing.expectEqualStrings("two", adapter.fetch(&fixture, url, &raw, &body, &.{}, fixture.options(.only_if_cached)).value.response.body);
    try std.testing.expectEqual(@as(usize, 4), fixture.calls);
    fixture.time.monotonic_ms += 61_000;
    const expired = adapter.fetch(&fixture, url, &raw, &body, &.{}, fixture.options(.normal));
    try std.testing.expectEqual(@as(u16, 200), expired.value.response.status);
    try std.testing.expectEqual(@as(usize, 5), fixture.calls);
    try std.testing.expectEqual(@as(usize, 2), fixture.validators);
}

test "cached transport keeps request variants cancellation and no-store responses separate" {
    var adapter = Adapter.init(std.testing.allocator);
    defer adapter.deinit();
    var fixture: Fixture = .{};
    var raw: [4096]u8 = undefined;
    var body: [128]u8 = undefined;
    const url = "http://cache.example/vary";
    _ = adapter.fetch(&fixture, url, &raw, &body, &.{}, fixture.options(.normal));
    fixture.cookie = "user=a";
    _ = adapter.fetch(&fixture, url, &raw, &body, &.{}, fixture.options(.normal));
    var variant = fixture.options(.normal);
    variant.transport.headers = "Accept: application/json\n";
    _ = adapter.fetch(&fixture, url, &raw, &body, &.{}, variant);
    variant.partition = "another document context";
    _ = adapter.fetch(&fixture, url, &raw, &body, &.{}, variant);
    try std.testing.expectEqual(@as(usize, 4), fixture.calls);
    var only = fixture.options(.only_if_cached);
    only.transport.headers = "Cache-Control: no-store\n";
    try std.testing.expect(adapter.fetch(&fixture, url, &raw, &body, &.{}, only).only_cache_miss);
    try std.testing.expectEqual(@as(usize, 4), fixture.calls);
    var stop: r4os.abi.R4StopFlag = .{};
    variant.transport.stop = &stop;
    @atomicStore(u32, &stop.value, 1, .release);
    try std.testing.expectEqual(web.Error.cancelled, adapter.fetch(&fixture, url, &raw, &body, &.{}, variant).value.failure);
    try std.testing.expectEqual(@as(usize, 4), fixture.calls);
    @atomicStore(u32, &stop.value, 0, .release);
    fixture.stopped_on_fetch = &stop;
    try std.testing.expectEqual(web.Error.cancelled, adapter.fetch(&fixture, "http://cache.example/aborted", &raw, &body, &.{}, variant).value.failure);
    fixture.stopped_on_fetch = null;
    @atomicStore(u32, &stop.value, 0, .release);
    variant.mode = .only_if_cached;
    try std.testing.expect(adapter.fetch(&fixture, "http://cache.example/aborted", &raw, &body, &.{}, variant).only_cache_miss);
    fixture.control = "no-store";
    const before = fixture.calls;
    for (0..2) |_| _ = adapter.fetch(&fixture, "http://cache.example/no-store", &raw, &body, &.{}, fixture.options(.normal));
    try std.testing.expectEqual(before + 2, fixture.calls);
    fixture.control = "max-age=60";
    fixture.vary = "*";
    for (0..2) |_| _ = adapter.fetch(&fixture, "http://cache.example/star", &raw, &body, &.{}, fixture.options(.normal));
    try std.testing.expectEqual(before + 4, fixture.calls);
}

test "shared response snapshot survives reuse of transport headers and body" {
    var fixture: Fixture = .{};
    var raw: [1024]u8 = undefined;
    var body: [32]u8 = undefined;
    var options = fixture.options(.normal).transport;
    options.initial_cookie = "";
    const response = fixture.fetch("http://cache.example/a", &raw, &body, &.{}, options).response;
    var snapshot = try Snapshot.init(std.testing.allocator, response);
    defer snapshot.deinit();
    @memset(&raw, 0);
    @memset(&body, 0);
    try std.testing.expectEqualStrings("one", snapshot.response.body);
    try std.testing.expectEqualStrings("text/plain", snapshot.response.content_type.?);
    try std.testing.expectEqualStrings("http://cache.example/a", snapshot.response.final_url.bytes());
}

test "cached transport still delivers when optional cache allocation fails" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var adapter = Adapter.init(failing.allocator());
    defer adapter.deinit();
    var fixture: Fixture = .{};
    var raw: [4096]u8 = undefined;
    var body: [128]u8 = undefined;
    for (0..2) |_| {
        const result = adapter.fetch(&fixture, "http://cache.example/a", &raw, &body, &.{}, fixture.options(.normal));
        try std.testing.expectEqualStrings("one", result.value.response.body);
    }
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    try std.testing.expectEqual(@as(usize, 0), adapter.storage.bytes);

    // A successful replacement with uncacheable metadata must retire the old
    // representation even though the new network response remains deliverable.
    const url = "http://cache.example/a";
    var stored = Adapter.init(std.testing.allocator);
    defer stored.deinit();
    var large_raw: [12 * 1024]u8 = undefined;
    var metadata: [cache.max_header_bytes]u8 = undefined;
    @memset(&metadata, 'x');
    fixture.control = "max-age=60";
    _ = stored.fetch(&fixture, url, &large_raw, &body, &.{}, fixture.options(.normal));
    fixture.control = &metadata;
    try std.testing.expect(stored.fetch(&fixture, url, &large_raw, &body, &.{}, fixture.options(.reload)).value == .response);
    try std.testing.expect(stored.fetch(&fixture, url, &large_raw, &body, &.{}, fixture.options(.only_if_cached)).only_cache_miss);
}
