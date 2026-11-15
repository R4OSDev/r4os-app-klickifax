const std = @import("std");
const r4os = @import("r4os");

pub const resource_progress_ms: u64 = 10;
pub const settled_script_slice_ms: u64 = 50;
pub const Scope = enum { top_level, subdocument };

/// One wait after a bounded page-work slice. Input, close and font events
/// remain EventLoop wake sources regardless of this optional page deadline.
pub const Plan = struct {
    now_ms: f64,
    script_slice_ms: u64,
    delay_ms: ?u64 = null,

    pub fn init(now_ms: f64, settled: bool) Plan {
        return .{ .now_ms = now_ms, .script_slice_ms = if (settled) settled_script_slice_ms else resource_progress_ms };
    }

    pub fn progress(self: *Plan) void {
        self.include(resource_progress_ms);
    }

    pub fn deadline(self: *Plan, due_ms: f64) void {
        self.include(remaining(self.now_ms, due_ms));
    }

    pub fn runtime(self: *Plan, web: *const r4os.web_runtime.WebRuntime, scope: Scope) void {
        if (!web.resourcesSettled()) self.progress();
        // Fetch/XHR requests need progress even after document load completes.
        for (&web.requests) |*request| {
            if (request.generation != web.generation) continue;
            if (request.state == .queued or request.state == .in_flight) {
                self.progress();
                break;
            }
        }
        // The application consumes only its top-level action/reflow queue.
        // A child queue without a consumer is not a runnable wake source.
        if (scope == .top_level and (web.action_count != 0 or web.dom_dirty)) self.include(self.script_slice_ms);
        if (!web.javascriptRealmActive()) return;
        if (web.runtime.task_count != 0 or web.runtime.microtask_count != 0) self.include(self.script_slice_ms);
        for (&web.timers) |*timer| {
            if (timer.occupied and timer.generation == web.generation)
                self.include(@max(self.script_slice_ms, remaining(self.now_ms, timer.due_ms)));
        }
        for (&web.abort_deadlines) |*abort| {
            if (abort.occupied and abort.generation == web.generation)
                self.include(@max(self.script_slice_ms, remaining(self.now_ms, abort.due_ms)));
        }
    }

    pub fn timeout(self: Plan) r4os.time_contract.Timeout {
        return if (self.delay_ms) |delay|
            r4os.time_contract.timeoutFinite(.{ .nanoseconds = delay *| std.time.ns_per_ms })
        else
            r4os.time_contract.timeoutForever();
    }

    fn include(self: *Plan, delay: u64) void {
        self.delay_ms = if (self.delay_ms) |current| @min(current, delay) else delay;
    }
};

fn remaining(now_ms: f64, due_ms: f64) u64 {
    if (!std.math.isFinite(now_ms) or !std.math.isFinite(due_ms)) return resource_progress_ms;
    const delta = due_ms - now_ms;
    if (delta <= 0) return 0;
    if (delta >= @as(f64, @floatFromInt(std.math.maxInt(u64)))) return std.math.maxInt(u64);
    return @intFromFloat(@ceil(delta));
}

test "settled documents throttle recurring script work without slowing loading" {
    const allocator = std.testing.allocator;
    const web = try allocator.create(r4os.web_runtime.WebRuntime);
    defer allocator.destroy(web);
    const js = try allocator.create(r4os.javascript.Runtime);
    defer allocator.destroy(js);
    // Only the public scheduling state is observed; no script is evaluated.
    web.resources.count = 0;
    web.action_count = 0;
    web.dom_dirty = false;
    web.generation = 7;
    web.runtime_memory = null;
    web.runtime = js;
    js.task_count = 0;
    js.microtask_count = 0;
    for (&web.requests) |*request| {
        request.state = .free;
        request.generation = 0;
    }
    for (&web.timers) |*timer| timer.occupied = false;
    for (&web.abort_deadlines) |*abort| abort.occupied = false;
    var idle = Plan.init(1000, true);
    idle.runtime(web, .top_level);
    try std.testing.expectEqual(r4os.abi.timeout_kind_forever, idle.timeout().kind);

    web.runtime_memory = @ptrCast(js);
    web.timers[0] = .{ .occupied = true, .generation = 7, .due_ms = 1001, .interval_ms = 1 };
    var settled = Plan.init(1000, true);
    settled.runtime(web, .top_level);
    try std.testing.expectEqual(@as(?u64, 50), settled.delay_ms);
    var loading = Plan.init(1000, false);
    loading.runtime(web, .top_level);
    try std.testing.expectEqual(@as(?u64, 10), loading.delay_ms);
    // A long timer keeps its actual deadline instead of producing 20 wakes/s.
    web.timers[0].due_ms = 60000;
    var long_timer = Plan.init(1000, true);
    long_timer.runtime(web, .top_level);
    try std.testing.expectEqual(@as(?u64, 59000), long_timer.delay_ms);
    // Navigation invalidates timer generations; cancelled work stays asleep.
    web.timers[0].generation = 6;
    var stale = Plan.init(1000, true);
    stale.runtime(web, .top_level);
    try std.testing.expectEqual(@as(?u64, null), stale.delay_ms);
    web.timers[0].occupied = false;
    web.abort_deadlines[0] = .{ .occupied = true, .generation = 7, .due_ms = 1100 };
    var abort = Plan.init(1000, true);
    abort.runtime(web, .top_level);
    try std.testing.expectEqual(@as(?u64, 100), abort.delay_ms);
    web.abort_deadlines[0].occupied = false;
    js.microtask_count = 1;
    var promise = Plan.init(1000, true);
    promise.runtime(web, .top_level);
    try std.testing.expectEqual(@as(?u64, 50), promise.delay_ms);
    js.microtask_count = 0;
    // A post-load fetch cannot be hidden by resourcesSettled().
    web.requests[0].state = .in_flight;
    web.requests[0].generation = 7;
    var fetch = Plan.init(1000, true);
    fetch.runtime(web, .top_level);
    try std.testing.expectEqual(@as(?u64, 10), fetch.delay_ms);
    web.requests[0].generation = 6;
    var retired_fetch = Plan.init(1000, true);
    retired_fetch.runtime(web, .top_level);
    try std.testing.expectEqual(@as(?u64, null), retired_fetch.delay_ms);
    web.dom_dirty = true;
    var mutation = Plan.init(1000, true);
    mutation.runtime(web, .top_level);
    try std.testing.expectEqual(@as(?u64, 50), mutation.delay_ms);
    var child = Plan.init(1000, true);
    child.runtime(web, .subdocument);
    try std.testing.expectEqual(@as(?u64, null), child.delay_ms);
}

test "page deadlines use the earliest source and round up without overflow" {
    var plan = Plan.init(1000, true);
    plan.deadline(2000);
    plan.deadline(1000.25);
    try std.testing.expectEqual(@as(?u64, 1), plan.delay_ms);
    plan.progress();
    try std.testing.expectEqual(@as(?u64, 1), plan.delay_ms);
    plan.deadline(999);
    try std.testing.expectEqual(@as(?u64, 0), plan.delay_ms);
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), remaining(0, 1e30));
    try std.testing.expectEqual(@as(u64, 10), remaining(0, std.math.nan(f64)));
}
