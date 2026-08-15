const std = @import("std");
const r4os = @import("r4os");
const storage_layout = @import("storage_layout.zig");

const cache = r4os.web_font_cache;

pub const max_aliases: usize = 256;
pub const io_chunk_bytes: usize = 16 * 1024;
pub const max_object_cleanup_entries: usize = cache.max_entries * (cache.object_directory_depth + 1) * 4;
pub const max_object_cleanup_depth: usize = cache.object_directory_depth + 1;
pub const lock_path = cache.root_path ++ "FCACHE.LCK";
pub const max_partition_origin_bytes: usize = r4os.web_security.max_origin_host_bytes + 24;
pub const OriginKey = cache.Fixed(max_partition_origin_bytes);
const max_u64_decimal_bytes: usize = 20;
const max_format_label_bytes: usize = "embedded-opentype".len;
const max_entry_line_bytes: usize = "ENTRY|".len + cache.digest_hex_bytes + 1 + cache.digest_hex_bytes + 1 +
    max_format_label_bytes + 1 + max_u64_decimal_bytes + 1 + max_u64_decimal_bytes + 1 +
    max_u64_decimal_bytes + 1 + cache.max_mime_bytes * 2 + 1 + cache.max_source_url_bytes * 2 + 2;
const max_alias_line_bytes: usize = "ALIAS|".len + cache.digest_hex_bytes + 1 + max_format_label_bytes + 1 +
    max_u64_decimal_bytes + 1 + max_partition_origin_bytes * 2 + 1 + cache.max_source_url_bytes * 2 + 1 +
    cache.max_source_url_bytes * 2 + 2;
pub const max_catalog_bytes: usize = 4096 + cache.max_entries * max_entry_line_bytes + max_aliases * max_alias_line_bytes;

pub const Error = cache.Error || std.mem.Allocator.Error || error{
    NotLoaded,
    CacheBusy,
    BadPath,
    Io,
    AtomicUnsupported,
    AtomicConflict,
    CatalogTooLarge,
    CatalogCorrupt,
    BufferTooSmall,
    ObjectMissing,
    ObjectCorrupt,
    AmbiguousAlias,
    InvalidOrigin,
    InvalidMediaType,
    DirectoryTraversalLimit,
    SelfTestProbeFormat,
    SelfTestInitialLoad,
    SelfTestLeaseAcquire,
    SelfTestLeaseBusy,
    SelfTestLeaseRelease,
    SelfTestWarmLoad,
    SelfTestImmediateLookup,
    SelfTestWarmLookup,
    SelfTestRecoveredLookup,
    SelfTestCleanup,
    ObjectDirectoryIo,
    ObjectModelStageWrite,
    ObjectModelStageVerify,
    ObjectOwnedStageWrite,
    ObjectOwnedStageVerify,
    ObjectPublishIo,
    CatalogModelStageWrite,
    CatalogModelStageVerify,
    CatalogAtomicStageWrite,
    CatalogAtomicStageVerify,
    CatalogPublishIo,
    CommitLeaseReleaseIo,
};

pub const Alias = struct {
    occupied: bool = false,
    request_origin: OriginKey = .{},
    source_url: cache.SourceUrl = .{},
    final_url: cache.SourceUrl = .{},
    format: cache.FontFormat = .unknown,
    id: cache.Digest = [_]u8{0} ** cache.digest_bytes,
    last_access: u64 = 0,

    fn valid(self: *const Alias, catalog: *const cache.Catalog) bool {
        if (!self.occupied or self.request_origin.len == 0 or self.source_url.len == 0 or self.final_url.len == 0 or self.format == .unknown) return false;
        const metadata = catalog.find(self.id) orelse return false;
        return self.last_access <= metadata.last_access;
    }
};

pub const State = struct {
    catalog: cache.Catalog = .{},
    aliases: [max_aliases]Alias = [_]Alias{.{}} ** max_aliases,
    alias_count: usize = 0,

    pub fn findUrl(self: *const State, request_origin: []const u8, source_url: []const u8, format: cache.FontFormat) ?cache.Digest {
        for (&self.aliases) |*alias| {
            if (alias.occupied and alias.format == format and
                std.mem.eql(u8, alias.request_origin.bytes(), request_origin) and
                std.mem.eql(u8, alias.source_url.bytes(), source_url)) return alias.id;
        }
        return null;
    }

    pub fn findUrlHint(self: *const State, request_origin: []const u8, source_url: []const u8, declared_format: cache.FontFormat) Error!?cache.Digest {
        var selected: ?cache.Digest = null;
        var selected_format: cache.FontFormat = .unknown;
        for (&self.aliases) |*alias| {
            if (!alias.occupied or !formatHintCompatible(declared_format, alias.format) or
                !std.mem.eql(u8, alias.request_origin.bytes(), request_origin) or
                !std.mem.eql(u8, alias.source_url.bytes(), source_url)) continue;
            if (selected) |id| {
                if (selected_format != alias.format or !std.mem.eql(u8, &id, &alias.id)) return error.AmbiguousAlias;
            } else {
                selected = alias.id;
                selected_format = alias.format;
            }
        }
        return selected;
    }

    pub fn putAlias(
        self: *State,
        request_origin: []const u8,
        source_url: []const u8,
        final_url: []const u8,
        format: cache.FontFormat,
        id: cache.Digest,
        now: u64,
    ) Error!void {
        if (format == .unknown) return error.InvalidMetadata;
        const metadata = self.catalog.find(id) orelse return error.InvalidMetadata;
        var replacement = Alias{ .occupied = true, .format = format, .id = id, .last_access = now };
        try replacement.request_origin.set(request_origin);
        try replacement.source_url.set(source_url);
        try replacement.final_url.set(final_url);

        // A request partition and requested URL identify the current network
        // representation.  If that representation changes its concrete font
        // format, retaining the old format alias would make lookupAny
        // ambiguous.  Remove only catalog objects whose displaced aliases
        // have no surviving reference from another origin or URL.
        var catalog_index: usize = 0;
        while (catalog_index < self.catalog.entries.len) : (catalog_index += 1) {
            const entry = self.catalog.entries[catalog_index];
            if (!entry.occupied or std.mem.eql(u8, &entry.id, &id)) continue;
            var displaced = false;
            var surviving = false;
            for (&self.aliases) |*alias| {
                if (!alias.occupied or !std.mem.eql(u8, &alias.id, &entry.id)) continue;
                const same_request = std.mem.eql(u8, alias.request_origin.bytes(), request_origin) and
                    std.mem.eql(u8, alias.source_url.bytes(), source_url);
                if (same_request and (alias.format != format or !std.mem.eql(u8, &alias.id, &id))) {
                    displaced = true;
                } else {
                    surviving = true;
                }
            }
            if (displaced and !surviving) _ = self.catalog.remove(entry.id);
        }

        for (&self.aliases) |*alias| {
            if (!alias.occupied or alias.format == format or
                !std.mem.eql(u8, alias.request_origin.bytes(), request_origin) or
                !std.mem.eql(u8, alias.source_url.bytes(), source_url)) continue;
            alias.* = .{};
            self.alias_count -|= 1;
        }

        for (&self.aliases) |*alias| {
            if (!alias.occupied or alias.format != format or
                !std.mem.eql(u8, alias.request_origin.bytes(), request_origin) or
                !std.mem.eql(u8, alias.source_url.bytes(), source_url)) continue;
            const same_object = std.mem.eql(u8, &alias.id, &id);
            replacement.last_access = if (same_object)
                @max(alias.last_access, metadata.last_access)
            else
                metadata.last_access;
            alias.* = replacement;
            return;
        }

        var slot: ?usize = null;
        for (&self.aliases, 0..) |*alias, index| {
            if (!alias.occupied) {
                slot = index;
                break;
            }
        }
        if (slot == null) slot = self.oldestAlias();
        const selected = slot orelse return error.CatalogFull;
        const evicted_id = if (self.aliases[selected].occupied) self.aliases[selected].id else null;
        if (!self.aliases[selected].occupied) self.alias_count += 1;
        self.aliases[selected] = replacement;
        if (evicted_id) |old_id| self.removeCatalogIfUnreferenced(old_id);
    }

    pub fn recordPrepared(self: *State, request_origin: []const u8, final_url: []const u8, prepared: *const cache.Prepared) Error!cache.Disposition {
        const disposition = try self.catalog.recordCommitted(prepared);
        try self.putAlias(
            request_origin,
            prepared.metadata.source_url.bytes(),
            final_url,
            prepared.metadata.format,
            prepared.metadata.id,
            prepared.metadata.last_access,
        );
        return disposition;
    }

    pub fn removeAliasesFor(self: *State, id: cache.Digest) void {
        for (&self.aliases) |*alias| {
            if (!alias.occupied or !std.mem.eql(u8, &alias.id, &id)) continue;
            alias.* = .{};
            self.alias_count -|= 1;
        }
    }

    pub fn validate(self: *const State) bool {
        if (!self.catalog.validate()) return false;
        var count: usize = 0;
        for (&self.aliases, 0..) |*alias, index| {
            if (!alias.occupied) continue;
            if (!alias.valid(&self.catalog)) return false;
            for (self.aliases[index + 1 ..]) |later| {
                if (later.occupied and
                    std.mem.eql(u8, later.request_origin.bytes(), alias.request_origin.bytes()) and
                    std.mem.eql(u8, later.source_url.bytes(), alias.source_url.bytes())) return false;
            }
            count += 1;
        }
        return count == self.alias_count;
    }

    fn oldestAlias(self: *const State) ?usize {
        var best: ?usize = null;
        for (&self.aliases, 0..) |*alias, index| {
            if (!alias.occupied) continue;
            if (best == null or alias.last_access < self.aliases[best.?].last_access or
                (alias.last_access == self.aliases[best.?].last_access and
                    aliasOrder(alias, &self.aliases[best.?]) == .lt)) best = index;
        }
        return best;
    }

    fn removeCatalogIfUnreferenced(self: *State, id: cache.Digest) void {
        for (&self.aliases) |*alias| {
            if (alias.occupied and std.mem.eql(u8, &alias.id, &id)) return;
        }
        _ = self.catalog.remove(id);
    }
};

fn selectAlias(state: *State, request_origin: []const u8, source_url: []const u8, requested_format: ?cache.FontFormat) Error!?*Alias {
    var selected: ?*Alias = null;
    for (&state.aliases) |*alias| {
        if (!alias.occupied or
            !std.mem.eql(u8, alias.request_origin.bytes(), request_origin) or
            !std.mem.eql(u8, alias.source_url.bytes(), source_url)) continue;
        if (requested_format) |format| if (!formatHintCompatible(format, alias.format)) continue;
        if (selected) |prior| {
            if (prior.format != alias.format or !std.mem.eql(u8, &prior.id, &alias.id)) return error.AmbiguousAlias;
        } else selected = alias;
    }
    return selected;
}

fn authorizedAlias(state: *State, request_origin: []const u8, source_url: []const u8, token: LookupResult) ?*Alias {
    if (token.format == .unknown) return null;
    for (&state.aliases) |*alias| {
        if (!alias.occupied or alias.format != token.format or
            !std.mem.eql(u8, alias.request_origin.bytes(), request_origin) or
            !std.mem.eql(u8, alias.source_url.bytes(), source_url) or
            !std.mem.eql(u8, alias.final_url.bytes(), token.final_url.bytes()) or
            !std.mem.eql(u8, &alias.id, &token.id)) continue;
        return alias;
    }
    return null;
}

const ExpiryPlan = struct {
    object_ids: [cache.max_entries]cache.Digest = undefined,
    object_count: usize = 0,
    removed_aliases: usize = 0,
    changed: bool = false,
};

fn expireAliases(state: *State, now: u64, max_age_seconds: u64) Error!ExpiryPlan {
    var plan = ExpiryPlan{};
    if (max_age_seconds == 0) return plan;
    for (&state.aliases) |*alias| {
        if (!alias.occupied or !cacheEntryExpired(alias.last_access, now, max_age_seconds)) continue;
        alias.* = .{};
        state.alias_count -|= 1;
        plan.removed_aliases += 1;
        plan.changed = true;
    }

    var entry_index: usize = 0;
    while (entry_index < state.catalog.entries.len) : (entry_index += 1) {
        const entry = state.catalog.entries[entry_index];
        if (!entry.occupied) continue;
        var referenced = false;
        var newest_access: u64 = 0;
        for (&state.aliases) |*alias| {
            if (!alias.occupied or !std.mem.eql(u8, &alias.id, &entry.id)) continue;
            referenced = true;
            newest_access = @max(newest_access, alias.last_access);
        }
        if (!referenced) {
            if (plan.object_count >= plan.object_ids.len) return error.CatalogFull;
            plan.object_ids[plan.object_count] = entry.id;
            plan.object_count += 1;
            _ = state.catalog.remove(entry.id);
            plan.changed = true;
        } else if (state.catalog.entries[entry_index].last_access != newest_access) {
            state.catalog.entries[entry_index].last_access = newest_access;
            plan.changed = true;
        }
    }
    if (!state.validate()) return error.CatalogCorrupt;
    return plan;
}

fn cacheEntryExpired(last_access: u64, now: u64, max_age_seconds: u64) bool {
    return max_age_seconds > 0 and now > 0 and last_access > 0 and now >= last_access and now - last_access >= max_age_seconds;
}

fn touchLookupAccess(
    state: *State,
    id: cache.Digest,
    request_origin: []const u8,
    source_url: []const u8,
    concrete_format: cache.FontFormat,
    now: u64,
) bool {
    if (now == 0) return false;
    var changed = false;
    if (state.catalog.find(id)) |metadata| {
        if (now > metadata.last_access) changed = true;
    }
    _ = state.catalog.touch(id, now);
    for (&state.aliases) |*alias| {
        if (!alias.occupied or alias.format != concrete_format or
            !std.mem.eql(u8, alias.request_origin.bytes(), request_origin) or
            !std.mem.eql(u8, alias.source_url.bytes(), source_url)) continue;
        if (now > alias.last_access) {
            alias.last_access = now;
            changed = true;
        }
        break;
    }
    return changed;
}

pub const LoadReport = struct {
    catalog_found: bool = false,
    catalog_discarded: bool = false,
    invalid_objects: usize = 0,
    expired_objects: usize = 0,
    orphan_objects: usize = 0,
    staging_files: usize = 0,
};

pub const CommitResult = struct {
    id: cache.Digest,
    object_path: cache.Path,
    disposition: cache.Disposition,
    object_reused: bool,
    evicted: usize,
};

pub const LookupResult = struct {
    id: cache.Digest,
    path: cache.Path,
    format: cache.FontFormat,
    final_url: cache.SourceUrl,
};

/// Caller-owned, checksum- and container-validated bytes for one previously
/// authorized warm-cache token.  R4FONT borrows this memory for the complete
/// lifetime of every face opened from it, so the consumer explicitly releases
/// the result only after those faces have been closed.
pub const OwnedLookupResult = struct {
    id: cache.Digest,
    format: cache.FontFormat,
    final_url: cache.SourceUrl,
    bytes: []u8,

    pub fn deinit(self: *OwnedLookupResult, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const SelfTestReport = struct {
    staged_and_committed: bool = false,
    immediate_lookup: bool = false,
    warm_lookup: bool = false,
    cleanup: bool = false,
    lease_busy: bool = false,
    lease_recovered: bool = false,

    pub fn ok(self: SelfTestReport) bool {
        return self.staged_and_committed and self.immediate_lookup and self.warm_lookup and self.cleanup and
            self.lease_busy and self.lease_recovered;
    }
};

const ObjectCleanupMode = enum { atomic_temps, orphans };

const ObjectTreeCleanup = struct {
    removed_files: usize = 0,
    removed_directories: usize = 0,
    retained_entries: bool = false,
};

const ObjectTreeBudget = struct {
    visited_entries: usize = 0,

    fn visit(self: *ObjectTreeBudget) Error!void {
        if (self.visited_entries >= max_object_cleanup_entries) return error.DirectoryTraversalLimit;
        self.visited_entries += 1;
    }
};

const ObjectFileDisposition = enum { referenced, orphan };

fn objectFileDisposition(state: *const State, path: []const u8) ObjectFileDisposition {
    const id = cache.digestFromObjectPath(path) orelse return .orphan;
    return if (state.catalog.find(id) != null) .referenced else .orphan;
}

pub const Store = struct {
    allocator: std.mem.Allocator,
    files: r4os.Files,
    policy: cache.Policy,
    state: *State,
    loaded: bool = false,

    pub fn init(allocator: std.mem.Allocator, files: r4os.Files, policy: cache.Policy) Error!Store {
        if (!policy.valid()) return error.ReservationTooLarge;
        const state = try allocator.create(State);
        state.* = .{};
        return .{ .allocator = allocator, .files = files, .policy = policy, .state = state };
    }

    pub fn deinit(self: *Store) void {
        self.allocator.destroy(self.state);
        self.* = undefined;
    }

    pub fn ensureLayout(self: *Store) Error!void {
        const paths = [_][]const u8{
            storage_layout.temp_root,
            storage_layout.temp_dir,
            storage_layout.cache_dir,
            storage_layout.work_dir,
            storage_layout.font_cache_dir,
            storage_layout.font_objects_dir,
            storage_layout.font_staging_dir,
        };
        for (paths) |text| {
            const path = absolute(text) catch return error.BadPath;
            switch (self.files.createDirectory(path.asZ())) {
                .ok, .missing => {},
                .failure => return error.Io,
            }
        }
    }

    fn ensureObjectParentDirectories(self: *Store, id: cache.Digest) Error!void {
        const parent = try cache.objectParentPath(id);
        var cursor: usize = cache.objects_path.len;
        var depth: usize = 0;
        while (depth < cache.object_directory_depth) : (depth += 1) {
            cursor += cache.object_digest_component_hex_bytes;
            const directory = absolute(parent.bytes()[0..cursor]) catch return error.BadPath;
            switch (self.files.createDirectory(directory.asZ())) {
                .ok, .missing => {},
                .failure => return error.Io,
            }
            if (depth + 1 < cache.object_directory_depth) cursor += 1;
        }
    }

    /// Loads only a checksum-complete catalog, verifies every referenced
    /// immutable object, then applies age/LRU policy while holding the cache
    /// lease.  Missing or incomplete objects are removed before any lookup
    /// can observe the state.
    pub fn load(self: *Store, now: u64, transaction_id: u64) Error!LoadReport {
        if (transaction_id == 0) return error.InvalidTransaction;
        try self.ensureLayout();
        var lock = try self.acquireLock();
        var lock_open = true;
        defer if (lock_open) releaseLock(&lock);

        var report = LoadReport{};
        const working = try self.allocator.create(State);
        defer self.allocator.destroy(working);
        working.* = .{};

        const loaded = self.readPersistentState(working) catch |err| switch (err) {
            error.ObjectMissing => false,
            error.CatalogCorrupt, error.CatalogTooLarge => blk: {
                report.catalog_found = true;
                report.catalog_discarded = true;
                const catalog_path = absolute(cache.catalog_path) catch return error.BadPath;
                try requireCatalogDiscard(self.files.delete(catalog_path.asZ()));
                break :blk false;
            },
            else => return err,
        };
        report.catalog_found = loaded or report.catalog_found;

        const io_buffer = try self.allocator.alloc(u8, io_chunk_bytes);
        defer self.allocator.free(io_buffer);
        var changed = report.catalog_discarded;
        if (loaded) {
            var index: usize = 0;
            while (index < working.catalog.entries.len) : (index += 1) {
                const entry = working.catalog.entries[index];
                if (!entry.occupied) continue;
                if (!(try self.objectMatches(&entry, io_buffer))) {
                    _ = working.catalog.remove(entry.id);
                    working.removeAliasesFor(entry.id);
                    report.invalid_objects += 1;
                    changed = true;
                }
            }
        }

        const cleanup = try cache.planCleanup(&working.catalog, self.policy, now, .{}, null);
        if (cleanup.count > 0) {
            for (cleanup.actions[0..cleanup.count]) |action| working.removeAliasesFor(action.id);
            try cache.applyCleanup(&working.catalog, &cleanup);
            report.expired_objects = cleanup.count;
            changed = true;
        }
        if (!working.validate()) return error.CatalogCorrupt;

        if (changed and (loaded or working.catalog.count != 0)) try self.publishState(working, transaction_id);
        for (cleanup.actions[0..cleanup.count]) |action| self.deleteObject(action.id);

        report.staging_files = try self.removeDirectoryFiles(storage_layout.font_staging_dir);
        report.staging_files += try self.removeAtomicTemps(storage_layout.font_cache_dir, "KC");
        const object_temps = try self.cleanupObjectTree(null, .atomic_temps);
        report.staging_files += object_temps.removed_files;
        report.orphan_objects = try self.removeOrphanObjects(working);
        self.state.* = working.*;
        self.loaded = true;
        try releaseLockChecked(&lock);
        lock_open = false;
        return report;
    }

    pub fn commit(
        self: *Store,
        bytes: []const u8,
        request_origin: []const u8,
        source_url: []const u8,
        final_url: []const u8,
        mime: []const u8,
        format: cache.FontFormat,
        now: u64,
        transaction_id: u64,
    ) Error!CommitResult {
        if (!self.loaded) return error.NotLoaded;
        if (transaction_id == 0) return error.InvalidTransaction;
        var origin = OriginKey{};
        try normalizeOrigin(request_origin, &origin);
        if (!validSourceUrl(final_url)) return error.InvalidSourceUrl;
        var mime_storage: [cache.max_mime_bytes]u8 = undefined;
        const normalized_mime = try normalizeMediaType(mime, mime_storage[0..]);
        const detected = try detectFormat(.unspecified, normalized_mime, source_url, bytes);
        if (detected != format) return error.UnsupportedFormat;
        const prepared = try cache.prepare(bytes, source_url, normalized_mime, format, now, self.policy);
        var lock = try self.acquireLock();
        var lock_open = true;
        defer if (lock_open) releaseLock(&lock);

        const working = try self.allocator.create(State);
        defer self.allocator.destroy(working);
        if (!(try self.readPersistentState(working))) working.* = self.state.*;

        const admission = try cache.planAdmission(&working.catalog, &prepared, self.policy, now, transaction_id);
        for (admission.cleanup.actions[0..admission.cleanup.count]) |action| working.removeAliasesFor(action.id);
        try cache.applyCleanup(&working.catalog, &admission.cleanup);
        var pre_alias_update_ids: [cache.max_entries]cache.Digest = undefined;
        var pre_alias_update_count: usize = 0;
        for (&working.catalog.entries) |*entry| {
            if (!entry.occupied) continue;
            pre_alias_update_ids[pre_alias_update_count] = entry.id;
            pre_alias_update_count += 1;
        }
        const disposition = try working.recordPrepared(origin.bytes(), final_url, &prepared);
        if (!working.validate()) return error.CatalogCorrupt;

        const object_reused = try self.publishObject(bytes, &prepared, transaction_id);
        try self.publishState(working, transaction_id);
        for (admission.cleanup.actions[0..admission.cleanup.count]) |action| self.deleteObject(action.id);
        for (pre_alias_update_ids[0..pre_alias_update_count]) |prior_id| {
            if (working.catalog.find(prior_id) != null) continue;
            self.deleteObject(prior_id);
        }

        self.state.* = working.*;
        const result = CommitResult{
            .id = prepared.metadata.id,
            .object_path = try cache.objectPath(prepared.metadata.id),
            .disposition = disposition,
            .object_reused = object_reused,
            .evicted = admission.cleanup.count,
        };
        releaseLockChecked(&lock) catch return error.CommitLeaseReleaseIo;
        lock_open = false;
        return result;
    }

    /// Resolves the persistent URL+format alias, verifies the immutable bytes
    /// before returning the path, and durably records LRU access.  A stale
    /// catalog entry is removed atomically and can never become a cache hit.
    pub fn lookup(self: *Store, request_origin: []const u8, source_url: []const u8, format: cache.FontFormat, now: u64, transaction_id: u64) Error!?LookupResult {
        return self.lookupInternal(request_origin, source_url, format, now, transaction_id);
    }

    pub fn lookupAny(self: *Store, request_origin: []const u8, source_url: []const u8, now: u64, transaction_id: u64) Error!?LookupResult {
        return self.lookupInternal(request_origin, source_url, null, now, transaction_id);
    }

    fn lookupInternal(self: *Store, request_origin: []const u8, source_url: []const u8, requested_format: ?cache.FontFormat, now: u64, transaction_id: u64) Error!?LookupResult {
        if (!self.loaded) return error.NotLoaded;
        if (transaction_id == 0) return error.InvalidTransaction;
        var origin = OriginKey{};
        try normalizeOrigin(request_origin, &origin);
        var lock = try self.acquireLock();
        var lock_open = true;
        defer if (lock_open) releaseLock(&lock);

        const working = try self.allocator.create(State);
        defer self.allocator.destroy(working);
        if (!(try self.readPersistentState(working))) {
            try releaseLockChecked(&lock);
            lock_open = false;
            return null;
        }
        const expiry = try expireAliases(working, now, self.policy.max_age_seconds);
        const selected = selectAlias(working, origin.bytes(), source_url, requested_format) catch |err| {
            try self.finishExpiry(working, &expiry, transaction_id);
            return err;
        };
        const alias = selected orelse {
            try self.finishExpiry(working, &expiry, transaction_id);
            try releaseLockChecked(&lock);
            lock_open = false;
            return null;
        };
        const id = alias.id;
        const format = alias.format;
        const final_url = alias.final_url;
        const metadata = working.catalog.find(id) orelse {
            try releaseLockChecked(&lock);
            lock_open = false;
            return null;
        };
        const io_buffer = try self.allocator.alloc(u8, io_chunk_bytes);
        defer self.allocator.free(io_buffer);
        if (!(try self.objectMatches(metadata, io_buffer))) {
            _ = working.catalog.remove(id);
            working.removeAliasesFor(id);
            try self.publishState(working, transaction_id);
            self.deleteExpiryObjects(&expiry);
            self.deleteObject(id);
            self.state.* = working.*;
            try releaseLockChecked(&lock);
            lock_open = false;
            return null;
        }

        const touched = touchLookupAccess(working, id, origin.bytes(), source_url, format, now);
        if (expiry.changed or touched) {
            try self.publishState(working, transaction_id);
            self.deleteExpiryObjects(&expiry);
        }
        self.state.* = working.*;
        const result = LookupResult{ .id = id, .path = try cache.objectPath(id), .format = format, .final_url = final_url };
        try releaseLockChecked(&lock);
        lock_open = false;
        return result;
    }

    /// Re-resolves an already policy-authorized lookup token while holding
    /// the cache lease and returns an exact caller-owned byte image.  A token
    /// whose alias was replaced between authorization and loading is a miss,
    /// never permission to consume the replacement.  Missing, corrupt,
    /// oversized or structurally invalid objects are retired atomically and
    /// also become misses. CacheBusy, I/O and allocator failures remain
    /// distinct errors so the caller can retry or report them deliberately.
    pub fn loadAuthorized(
        self: *Store,
        allocator: std.mem.Allocator,
        request_origin: []const u8,
        source_url: []const u8,
        token: LookupResult,
        now: u64,
        transaction_id: u64,
    ) Error!?OwnedLookupResult {
        if (!self.loaded) return error.NotLoaded;
        if (transaction_id == 0) return error.InvalidTransaction;
        var origin = OriginKey{};
        try normalizeOrigin(request_origin, &origin);
        var lock = try self.acquireLock();
        var lock_open = true;
        defer if (lock_open) releaseLock(&lock);

        const working = try self.allocator.create(State);
        defer self.allocator.destroy(working);
        if (!(try self.readPersistentState(working))) {
            try releaseLockChecked(&lock);
            lock_open = false;
            return null;
        }
        const expiry = try expireAliases(working, now, self.policy.max_age_seconds);
        const alias = authorizedAlias(working, origin.bytes(), source_url, token) orelse {
            try self.finishExpiry(working, &expiry, transaction_id);
            try releaseLockChecked(&lock);
            lock_open = false;
            return null;
        };
        const id = alias.id;
        const metadata = working.catalog.find(id) orelse {
            try releaseLockChecked(&lock);
            lock_open = false;
            return null;
        };
        const valid_size = self.policy.acceptsObjectSize(metadata.size) and
            metadata.size <= cache.default_max_object_bytes and metadata.size <= std.math.maxInt(usize);
        if (!valid_size) {
            try self.retireInvalidObject(working, &expiry, id, transaction_id);
            try releaseLockChecked(&lock);
            lock_open = false;
            return null;
        }

        const bytes = try allocator.alloc(u8, @intCast(metadata.size));
        var bytes_owned = true;
        defer if (bytes_owned) allocator.free(bytes);
        const object_path = try cache.objectPath(id);
        const path = absolute(object_path.bytes()) catch return error.BadPath;
        self.readExact(path, bytes) catch |err| switch (err) {
            error.ObjectMissing, error.ObjectCorrupt => {
                try self.retireInvalidObject(working, &expiry, id, transaction_id);
                try releaseLockChecked(&lock);
                lock_open = false;
                return null;
            },
            else => return err,
        };
        if (!loadedObjectValid(metadata, token.final_url.bytes(), bytes)) {
            try self.retireInvalidObject(working, &expiry, id, transaction_id);
            try releaseLockChecked(&lock);
            lock_open = false;
            return null;
        }

        const touched = touchLookupAccess(working, id, origin.bytes(), source_url, token.format, now);
        if (expiry.changed or touched) {
            try self.publishState(working, transaction_id);
            self.deleteExpiryObjects(&expiry);
        }
        self.state.* = working.*;
        try releaseLockChecked(&lock);
        lock_open = false;
        bytes_owned = false;
        return .{
            .id = id,
            .format = token.format,
            .final_url = token.final_url,
            .bytes = bytes,
        };
    }

    /// Removes exactly the alias represented by an authorized token.  A
    /// newer replacement for the same origin and requested URL is preserved.
    /// The immutable object is deleted only after its final alias disappears.
    pub fn removeAuthorized(
        self: *Store,
        request_origin: []const u8,
        source_url: []const u8,
        token: LookupResult,
        transaction_id: u64,
    ) Error!bool {
        if (!self.loaded) return error.NotLoaded;
        if (transaction_id == 0) return error.InvalidTransaction;
        var origin = OriginKey{};
        try normalizeOrigin(request_origin, &origin);
        var lock = try self.acquireLock();
        var lock_open = true;
        defer if (lock_open) releaseLock(&lock);

        const working = try self.allocator.create(State);
        defer self.allocator.destroy(working);
        if (!(try self.readPersistentState(working))) working.* = self.state.*;
        const alias = authorizedAlias(working, origin.bytes(), source_url, token) orelse {
            try releaseLockChecked(&lock);
            lock_open = false;
            return false;
        };
        const id = alias.id;
        alias.* = .{};
        working.alias_count -|= 1;
        working.removeCatalogIfUnreferenced(id);
        const retained = working.catalog.find(id) != null;
        if (!working.validate()) return error.CatalogCorrupt;
        try self.publishState(working, transaction_id);
        if (!retained) self.deleteObject(id);
        self.state.* = working.*;
        try releaseLockChecked(&lock);
        lock_open = false;
        return true;
    }

    fn retireInvalidObject(self: *Store, working: *State, expiry: *const ExpiryPlan, id: cache.Digest, transaction_id: u64) Error!void {
        working.removeAliasesFor(id);
        _ = working.catalog.remove(id);
        if (!working.validate()) return error.CatalogCorrupt;
        try self.publishState(working, transaction_id);
        self.deleteExpiryObjects(expiry);
        self.deleteObject(id);
        self.state.* = working.*;
    }

    fn finishExpiry(self: *Store, working: *State, expiry: *const ExpiryPlan, transaction_id: u64) Error!void {
        if (!expiry.changed) return;
        try self.publishState(working, transaction_id);
        self.deleteExpiryObjects(expiry);
        self.state.* = working.*;
    }

    fn deleteExpiryObjects(self: *Store, expiry: *const ExpiryPlan) void {
        for (expiry.object_ids[0..expiry.object_count]) |id| self.deleteObject(id);
    }

    pub fn removeUrl(self: *Store, request_origin: []const u8, source_url: []const u8, format: cache.FontFormat, transaction_id: u64) Error!bool {
        if (!self.loaded) return error.NotLoaded;
        if (transaction_id == 0) return error.InvalidTransaction;
        var origin = OriginKey{};
        try normalizeOrigin(request_origin, &origin);
        var lock = try self.acquireLock();
        var lock_open = true;
        defer if (lock_open) releaseLock(&lock);

        const working = try self.allocator.create(State);
        defer self.allocator.destroy(working);
        if (!(try self.readPersistentState(working))) working.* = self.state.*;
        var removed_id: ?cache.Digest = null;
        for (&working.aliases) |*alias| {
            if (!alias.occupied or alias.format != format or
                !std.mem.eql(u8, alias.request_origin.bytes(), origin.bytes()) or
                !std.mem.eql(u8, alias.source_url.bytes(), source_url)) continue;
            removed_id = alias.id;
            alias.* = .{};
            working.alias_count -|= 1;
            break;
        }
        const id = removed_id orelse {
            try releaseLockChecked(&lock);
            lock_open = false;
            return false;
        };
        var still_referenced = false;
        for (&working.aliases) |*alias| {
            if (alias.occupied and std.mem.eql(u8, &alias.id, &id)) {
                still_referenced = true;
                break;
            }
        }
        if (!still_referenced) _ = working.catalog.remove(id);
        if (!working.validate()) return error.CatalogCorrupt;
        try self.publishState(working, transaction_id);
        if (!still_referenced) self.deleteObject(id);
        self.state.* = working.*;
        try releaseLockChecked(&lock);
        lock_open = false;
        return true;
    }

    fn acquireLock(self: *Store) Error!r4os.app_storage.OwnedStageWriter {
        const path = absolute(lock_path) catch return error.BadPath;
        return switch (self.files.ownedCreateWriter(path.asZ())) {
            .writer => |writer| writer,
            .failure => |code| leaseOpenError(code),
        };
    }

    fn readPersistentState(self: *Store, output: *State) Error!bool {
        const path = absolute(cache.catalog_path) catch return error.BadPath;
        const info = switch (self.files.info(path.asZ())) {
            .value => |value| value,
            .missing => return false,
            .failure => return error.Io,
        };
        if (info.is_dir != 0) return error.CatalogCorrupt;
        if (info.size > max_catalog_bytes) return error.CatalogTooLarge;
        const bytes = try self.allocator.alloc(u8, @intCast(info.size));
        defer self.allocator.free(bytes);
        try self.readExact(path, bytes);
        output.* = try decodeState(bytes, self.policy);
        return true;
    }

    fn publishObject(self: *Store, bytes: []const u8, prepared: *const cache.Prepared, transaction_id: u64) Error!bool {
        self.ensureObjectParentDirectories(prepared.metadata.id) catch |err| switch (err) {
            error.Io => return error.ObjectDirectoryIo,
            else => return err,
        };
        const model_stage = try cache.objectStagePath(prepared.metadata.id, transaction_id);
        self.writeOrdinary(model_stage.bytes(), bytes) catch return error.ObjectModelStageWrite;
        const io_buffer = try self.allocator.alloc(u8, io_chunk_bytes);
        defer self.allocator.free(io_buffer);
        self.verifyPath(model_stage.bytes(), prepared.metadata.size, prepared.metadata.checksum, io_buffer) catch
            return error.ObjectModelStageVerify;

        const object_parent = try cache.objectParentPath(prepared.metadata.id);
        const paths = try atomicSiblingPaths(object_parent.bytes(), "KF", transaction_id);
        self.deletePath(paths.stage.bytes());
        self.deletePath(paths.backup.bytes());
        var owned = self.writeOwned(paths.stage.bytes(), bytes) catch return error.ObjectOwnedStageWrite;
        var consumed = false;
        defer if (!consumed) releaseLock(&owned);
        self.verifyPath(paths.stage.bytes(), prepared.metadata.size, prepared.metadata.checksum, io_buffer) catch
            return error.ObjectOwnedStageVerify;

        const target = try cache.objectPath(prepared.metadata.id);
        const target_path = absolute(target.bytes()) catch return error.BadPath;
        const stage_path = absolute(paths.stage.bytes()) catch return error.BadPath;
        const backup_path = absolute(paths.backup.bytes()) catch return error.BadPath;
        const result = self.files.replaceAtomic(target_path.asZ(), stage_path.asZ(), backup_path.asZ(), .{
            .consume_stage = true,
            .require_target_absent = true,
            .require_owned_stage = true,
        });
        switch (result) {
            .ok => consumed = true,
            .conflict => {
                const matches = try self.objectMatches(&prepared.metadata, io_buffer);
                if (!matches) return error.DigestCollision;
                self.deletePath(model_stage.bytes());
                return true;
            },
            .unsupported => return error.AtomicUnsupported,
            .missing, .bad_path => return error.BadPath,
            .failure => return error.ObjectPublishIo,
        }
        self.deletePath(model_stage.bytes());
        return false;
    }

    fn publishState(self: *Store, state: *const State, transaction_id: u64) Error!void {
        if (!state.validate()) return error.CatalogCorrupt;
        const bytes = try self.allocator.alloc(u8, max_catalog_bytes);
        defer self.allocator.free(bytes);
        const encoded = try encodeState(state, bytes);
        const model_stage = try cache.catalogStagePath(transaction_id);
        self.writeOrdinary(model_stage.bytes(), encoded) catch return error.CatalogModelStageWrite;
        self.verifyBytes(model_stage.bytes(), encoded) catch return error.CatalogModelStageVerify;

        const paths = try atomicSiblingPaths(cache.root_path, "KC", transaction_id);
        self.deletePath(paths.stage.bytes());
        self.deletePath(paths.backup.bytes());
        self.writeOrdinary(paths.stage.bytes(), encoded) catch return error.CatalogAtomicStageWrite;
        self.verifyBytes(paths.stage.bytes(), encoded) catch return error.CatalogAtomicStageVerify;

        const target = absolute(cache.catalog_path) catch return error.BadPath;
        const stage = absolute(paths.stage.bytes()) catch return error.BadPath;
        const backup = absolute(paths.backup.bytes()) catch return error.BadPath;
        switch (self.files.replaceAtomic(target.asZ(), stage.asZ(), backup.asZ(), .{})) {
            .ok => {},
            .unsupported => return error.AtomicUnsupported,
            .conflict => return error.AtomicConflict,
            .missing, .bad_path => return error.BadPath,
            .failure => return error.CatalogPublishIo,
        }
        self.deletePath(paths.backup.bytes());
        self.deletePath(model_stage.bytes());
    }

    fn writeOwned(self: *Store, path_text: []const u8, bytes: []const u8) Error!r4os.app_storage.OwnedStageWriter {
        const path = absolute(path_text) catch return error.BadPath;
        var writer = switch (self.files.ownedCreateWriter(path.asZ())) {
            .writer => |value| value,
            .failure => return error.Io,
        };
        var offset: usize = 0;
        while (offset < bytes.len) {
            const end = @min(offset + io_chunk_bytes, bytes.len);
            switch (writer.write(bytes[offset..end])) {
                .ok => {},
                else => {
                    releaseLock(&writer);
                    return error.Io;
                },
            }
            offset = end;
        }
        switch (writer.finishKeepOwnership()) {
            .ok => return writer,
            else => {
                releaseLock(&writer);
                return error.Io;
            },
        }
    }

    fn writeOrdinary(self: *Store, path_text: []const u8, bytes: []const u8) Error!void {
        const path = absolute(path_text) catch return error.BadPath;
        var writer = switch (self.files.streamWriter(path.asZ(), r4os.abi.file_stream_open_replace)) {
            .writer => |value| value,
            .failure => return error.Io,
        };
        var offset: usize = 0;
        while (offset < bytes.len) {
            const end = @min(offset + io_chunk_bytes, bytes.len);
            switch (writer.write(bytes[offset..end])) {
                .ok => {},
                else => {
                    _ = writer.abort();
                    return error.Io;
                },
            }
            offset = end;
        }
        switch (writer.finish()) {
            .ok => {},
            else => {
                _ = writer.abort();
                return error.Io;
            },
        }
    }

    fn verifyBytes(self: *Store, path_text: []const u8, expected: []const u8) Error!void {
        const path = absolute(path_text) catch return error.BadPath;
        const actual = try self.allocator.alloc(u8, expected.len);
        defer self.allocator.free(actual);
        try self.readExact(path, actual);
        if (!std.mem.eql(u8, actual, expected)) return error.ObjectCorrupt;
    }

    fn verifyPath(self: *Store, path_text: []const u8, size: u64, digest: cache.Digest, scratch: []u8) Error!void {
        const path = absolute(path_text) catch return error.BadPath;
        const observation = try self.observe(path, scratch);
        if (observation.size != size) return error.StageSizeMismatch;
        if (!std.mem.eql(u8, &observation.digest, &digest)) return error.StageDigestMismatch;
    }

    fn objectMatches(self: *Store, metadata: *const cache.Metadata, scratch: []u8) Error!bool {
        const object_path = try cache.objectPath(metadata.id);
        const path = absolute(object_path.bytes()) catch return error.BadPath;
        const observation = self.observe(path, scratch) catch |err| switch (err) {
            error.ObjectMissing => return false,
            else => return err,
        };
        return observation.size == metadata.size and std.mem.eql(u8, &observation.digest, &metadata.checksum);
    }

    const Observation = struct { size: u64, digest: cache.Digest };

    fn observe(self: *Store, path: r4os.AbsoluteFilePath, scratch: []u8) Error!Observation {
        if (scratch.len == 0) return error.BufferTooSmall;
        const info = switch (self.files.info(path.asZ())) {
            .value => |value| value,
            .missing => return error.ObjectMissing,
            .failure => return error.Io,
        };
        if (info.is_dir != 0 or info.size > 0xFFFF_FFFF) return error.ObjectCorrupt;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var offset: u64 = 0;
        while (offset < info.size) {
            const want: usize = @intCast(@min(@as(u64, scratch.len), info.size - offset));
            const got = switch (self.files.readAt(path.asZ(), @intCast(offset), scratch[0..want])) {
                .bytes => |count| @as(usize, count),
                .end => return error.ObjectCorrupt,
                .failure => return error.Io,
            };
            if (got == 0 or got > want) return error.ObjectCorrupt;
            hasher.update(scratch[0..got]);
            offset += got;
        }
        var digest: cache.Digest = undefined;
        hasher.final(&digest);
        return .{ .size = info.size, .digest = digest };
    }

    fn readExact(self: *Store, path: r4os.AbsoluteFilePath, output: []u8) Error!void {
        const info = switch (self.files.info(path.asZ())) {
            .value => |value| value,
            .missing => return error.ObjectMissing,
            .failure => return error.Io,
        };
        if (info.is_dir != 0 or info.size != output.len or info.size > 0xFFFF_FFFF) return error.ObjectCorrupt;
        var offset: usize = 0;
        while (offset < output.len) {
            const end = @min(offset + io_chunk_bytes, output.len);
            const got = switch (self.files.readAt(path.asZ(), @intCast(offset), output[offset..end])) {
                .bytes => |count| @as(usize, count),
                .end => return error.ObjectCorrupt,
                .failure => return error.Io,
            };
            if (got == 0 or offset + got > end) return error.ObjectCorrupt;
            offset += got;
        }
    }

    fn removeOrphanObjects(self: *Store, state: *const State) Error!usize {
        return (try self.cleanupObjectTree(state, .orphans)).removed_files;
    }

    fn cleanupObjectTree(self: *Store, state: ?*const State, mode: ObjectCleanupMode) Error!ObjectTreeCleanup {
        var budget = ObjectTreeBudget{};
        return self.cleanupObjectDirectory(storage_layout.font_objects_dir, state, mode, 0, &budget);
    }

    fn cleanupObjectDirectory(
        self: *Store,
        directory_text: []const u8,
        state: ?*const State,
        mode: ObjectCleanupMode,
        depth: usize,
        budget: *ObjectTreeBudget,
    ) Error!ObjectTreeCleanup {
        if (depth > max_object_cleanup_depth) return error.DirectoryTraversalLimit;
        const directory = absolute(directory_text) catch return error.BadPath;
        var iterator = self.files.iterate(directory.asZ());
        var path_buffer: [512]u8 = undefined;
        var result = ObjectTreeCleanup{};
        while (true) {
            const entry = switch (iterator.next(path_buffer[0..])) {
                .entry => |value| value,
                .end => break,
                .failure => return error.Io,
            };
            try budget.visit();
            if (entry.kind == .directory) {
                if (depth >= max_object_cleanup_depth) return error.DirectoryTraversalLimit;
                const child = try self.cleanupObjectDirectory(entry.path, state, mode, depth + 1, budget);
                result.removed_files += child.removed_files;
                result.removed_directories += child.removed_directories;
                if (child.retained_entries) {
                    result.retained_entries = true;
                    continue;
                }
                const child_path = absolute(entry.path) catch return error.BadPath;
                switch (self.files.deleteDirectory(child_path.asZ())) {
                    .ok => {
                        result.removed_directories += 1;
                        iterator.revisitAfterRemoval();
                    },
                    .missing => iterator.revisitAfterRemoval(),
                    .failure => return error.Io,
                }
                continue;
            }

            const remove = switch (mode) {
                .atomic_temps => isAtomicTempName(baseName(entry.path), "KF"),
                .orphans => objectFileDisposition(state orelse return error.CatalogCorrupt, entry.path) == .orphan,
            };
            if (!remove) {
                result.retained_entries = true;
                continue;
            }
            const path = absolute(entry.path) catch return error.BadPath;
            switch (self.files.delete(path.asZ())) {
                .ok => {
                    result.removed_files += 1;
                    iterator.revisitAfterRemoval();
                },
                .missing => iterator.revisitAfterRemoval(),
                .failure => return error.Io,
            }
        }
        return result;
    }

    fn removeAtomicTemps(self: *Store, directory_text: []const u8, prefix: []const u8) Error!usize {
        const directory = absolute(directory_text) catch return error.BadPath;
        var iterator = self.files.iterate(directory.asZ());
        var path_buffer: [512]u8 = undefined;
        var removed: usize = 0;
        while (true) {
            const entry = switch (iterator.next(path_buffer[0..])) {
                .entry => |value| value,
                .end => break,
                .failure => return error.Io,
            };
            if (entry.kind != .file or !isAtomicTempName(baseName(entry.path), prefix)) continue;
            const path = absolute(entry.path) catch continue;
            switch (self.files.delete(path.asZ())) {
                .ok => {
                    removed += 1;
                    iterator.revisitAfterRemoval();
                },
                .missing => iterator.revisitAfterRemoval(),
                .failure => return error.Io,
            }
        }
        return removed;
    }

    fn removeDirectoryFiles(self: *Store, directory_text: []const u8) Error!usize {
        const directory = absolute(directory_text) catch return error.BadPath;
        var iterator = self.files.iterate(directory.asZ());
        var path_buffer: [512]u8 = undefined;
        var removed: usize = 0;
        while (true) {
            const entry = switch (iterator.next(path_buffer[0..])) {
                .entry => |value| value,
                .end => break,
                .failure => return error.Io,
            };
            if (entry.kind != .file) continue;
            const path = absolute(entry.path) catch continue;
            switch (self.files.delete(path.asZ())) {
                .ok => {
                    removed += 1;
                    iterator.revisitAfterRemoval();
                },
                .missing => iterator.revisitAfterRemoval(),
                .failure => return error.Io,
            }
        }
        return removed;
    }

    fn deleteObject(self: *Store, id: cache.Digest) void {
        const object = cache.objectPath(id) catch return;
        const path = absolute(object.bytes()) catch return;
        switch (self.files.delete(path.asZ())) {
            .ok, .missing => self.pruneObjectParentDirectories(id),
            .failure => {},
        }
    }

    fn pruneObjectParentDirectories(self: *Store, id: cache.Digest) void {
        const parent = cache.objectParentPath(id) catch return;
        var depth = cache.object_directory_depth;
        while (depth > 0) : (depth -= 1) {
            const len = cache.objects_path.len +
                depth * cache.object_digest_component_hex_bytes +
                (depth - 1);
            const directory = absolute(parent.bytes()[0..len]) catch return;
            switch (self.files.deleteDirectory(directory.asZ())) {
                .ok, .missing => {},
                .failure => return,
            }
        }
    }

    fn deletePath(self: *Store, text: []const u8) void {
        const path = absolute(text) catch return;
        _ = self.files.delete(path.asZ());
    }
};

fn loadedObjectValid(metadata: *const cache.Metadata, final_url: []const u8, bytes: []const u8) bool {
    if (!metadata.valid() or bytes.len != metadata.size or bytes.len > cache.default_max_object_bytes) return false;
    const digest = cache.contentId(bytes);
    if (!std.mem.eql(u8, &digest, &metadata.id) or !std.mem.eql(u8, &digest, &metadata.checksum)) return false;
    const concrete = detectFormat(.unspecified, metadata.mime.bytes(), final_url, bytes) catch return false;
    return concrete == metadata.format;
}

/// Resolves a downloaded font to the cache's concrete original-byte format.
/// Magic bytes are authoritative; a concrete CSS `format()` or recognized
/// MIME that contradicts them is rejected.  URL suffixes are deliberately
/// only hints, so redirects and content-disposition filenames cannot turn an
/// HTML/error body into a font.
pub fn detectFormat(
    declared: r4os.web_fonts.FontFormat,
    mime: []const u8,
    source_url: []const u8,
    bytes: []const u8,
) Error!cache.FontFormat {
    const signature = signatureFormat(bytes) orelse return error.UnsupportedFormat;
    const declared_format = declaredCacheFormat(declared) orelse switch (declared) {
        .unspecified => null,
        else => return error.UnsupportedFormat,
    };
    if (declared_format) |hint| if (!formatHintCompatible(hint, signature)) return error.UnsupportedFormat;
    if (mimeFormat(mime)) |hint| if (!formatHintCompatible(hint, signature)) return error.UnsupportedFormat;
    _ = urlFormat(source_url); // suffix is diagnostic-only; signature wins
    return signature;
}

/// Canonicalizes an HTTP(S) request origin to scheme, lower-case host and
/// explicit non-default port.  Opaque origins are intentionally ineligible
/// for persistent cache aliases because their identity is document-local.
pub fn normalizeOrigin(raw: []const u8, output: *OriginKey) Error!void {
    const parsed = r4os.web_security.Origin.parse(raw, 0) catch return error.InvalidOrigin;
    if (parsed.scheme == .opaque_origin) return error.InvalidOrigin;
    var buffer: [max_partition_origin_bytes]u8 = undefined;
    const serialized = parsed.serialize(buffer[0..]) orelse return error.InvalidOrigin;
    output.set(serialized) catch return error.InvalidOrigin;
}

/// Stores only the lower-case media type, never response parameters.  Raw
/// `Content-Type` values such as `font/woff2; charset=binary` therefore map
/// to the same persistent metadata as `font/woff2` without weakening the
/// signature check.
pub fn normalizeMediaType(raw: []const u8, output: []u8) Error![]const u8 {
    for (raw) |byte| if (byte == '\r' or byte == '\n' or byte == 0 or byte == 0x7f) return error.InvalidMediaType;
    const end = std.mem.indexOfScalar(u8, raw, ';') orelse raw.len;
    const value = std.mem.trim(u8, raw[0..end], " \t");
    if (value.len == 0 or value.len > cache.max_mime_bytes or value.len > output.len) return error.InvalidMediaType;
    const slash = std.mem.indexOfScalar(u8, value, '/') orelse return error.InvalidMediaType;
    if (slash == 0 or slash + 1 == value.len or std.mem.indexOfScalarPos(u8, value, slash + 1, '/') != null) return error.InvalidMediaType;
    for (value, 0..) |byte, index| {
        if (!mediaTokenByte(byte) and byte != '/') return error.InvalidMediaType;
        output[index] = std.ascii.toLower(byte);
    }
    return output[0..value.len];
}

fn mediaTokenByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or switch (byte) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

fn signatureFormat(bytes: []const u8) ?cache.FontFormat {
    if (bytes.len < 4) return null;
    if (std.mem.eql(u8, bytes[0..4], "wOFF")) return if (validWoff(bytes)) .woff else null;
    if (std.mem.eql(u8, bytes[0..4], "wOF2")) return if (validWoff2(bytes)) .woff2 else null;
    if (std.mem.eql(u8, bytes[0..4], "true") or std.mem.eql(u8, bytes[0..4], &[_]u8{ 0, 1, 0, 0 })) {
        return if (validSfnt(bytes)) .truetype else null;
    }
    if (std.mem.eql(u8, bytes[0..4], "OTTO")) return if (validSfnt(bytes)) .opentype else null;
    return null;
}

fn validWoff(bytes: []const u8) bool {
    const header_size: usize = 44;
    const entry_size: usize = 20;
    if (bytes.len < header_size or bytes.len > std.math.maxInt(u32)) return false;
    const declared_length = readBe32(bytes, 8) orelse return false;
    if (declared_length != @as(u32, @intCast(bytes.len))) return false;

    const table_count = readBe16(bytes, 12) orelse return false;
    if (table_count == 0 or (readBe16(bytes, 14) orelse return false) != 0) return false;
    const directory_end = directoryEnd(header_size, table_count, entry_size, bytes.len) orelse return false;
    const minimum_sfnt_size = directoryEnd(12, table_count, 16, std.math.maxInt(usize)) orelse return false;
    if (@as(usize, readBe32(bytes, 16) orelse return false) < minimum_sfnt_size) return false;

    var index: usize = 0;
    while (index < table_count) : (index += 1) {
        const entry = header_size + index * entry_size;
        const offset = readBe32(bytes, entry + 4) orelse return false;
        const compressed_length = readBe32(bytes, entry + 8) orelse return false;
        const original_length = readBe32(bytes, entry + 12) orelse return false;
        if (compressed_length == 0 or original_length == 0 or compressed_length > original_length) return false;
        if (@as(usize, offset) < directory_end or offset % 4 != 0 or !rangeWithin(bytes.len, offset, compressed_length)) return false;
    }

    const metadata_offset = readBe32(bytes, 24) orelse return false;
    const metadata_length = readBe32(bytes, 28) orelse return false;
    const metadata_original_length = readBe32(bytes, 32) orelse return false;
    if (metadata_offset == 0) {
        if (metadata_length != 0 or metadata_original_length != 0) return false;
    } else if (metadata_length == 0 or metadata_original_length == 0 or
        @as(usize, metadata_offset) < directory_end or !rangeWithin(bytes.len, metadata_offset, metadata_length))
    {
        return false;
    }

    const private_offset = readBe32(bytes, 36) orelse return false;
    const private_length = readBe32(bytes, 40) orelse return false;
    if (private_offset == 0) {
        if (private_length != 0) return false;
    } else if (private_length == 0 or @as(usize, private_offset) < directory_end or !rangeWithin(bytes.len, private_offset, private_length)) {
        return false;
    }
    return true;
}

fn validWoff2(bytes: []const u8) bool {
    const header_size: usize = 48;
    if (bytes.len < header_size or bytes.len > std.math.maxInt(u32)) return false;
    const declared_length = readBe32(bytes, 8) orelse return false;
    if (declared_length != @as(u32, @intCast(bytes.len))) return false;

    const table_count = readBe16(bytes, 12) orelse return false;
    if (table_count == 0 or (readBe16(bytes, 14) orelse return false) != 0) return false;
    const minimum_sfnt_size = directoryEnd(12, table_count, 16, std.math.maxInt(usize)) orelse return false;
    if (@as(usize, readBe32(bytes, 16) orelse return false) < minimum_sfnt_size) return false;

    var cursor: usize = header_size;
    var table_index: usize = 0;
    while (table_index < table_count) : (table_index += 1) {
        if (cursor >= bytes.len) return false;
        const flags = bytes[cursor];
        cursor += 1;
        const tag_index = flags & 0x3f;
        var glyf_or_loca = tag_index == 10 or tag_index == 11;
        if (tag_index == 0x3f) {
            if (bytes.len - cursor < 4) return false;
            glyf_or_loca = std.mem.eql(u8, bytes[cursor .. cursor + 4], "glyf") or
                std.mem.eql(u8, bytes[cursor .. cursor + 4], "loca");
            cursor += 4;
        }
        const original_length = readUIntBase128(bytes, &cursor) orelse return false;
        if (original_length == 0) return false;
        const transform_version = flags >> 6;
        const transformed = if (glyf_or_loca) transform_version == 0 else transform_version != 0;
        if (glyf_or_loca and transform_version != 0 and transform_version != 3) return false;
        if (transformed) _ = readUIntBase128(bytes, &cursor) orelse return false;
    }

    const compressed_length = readBe32(bytes, 20) orelse return false;
    if (compressed_length == 0 or !rangeWithin(bytes.len, cursor, compressed_length)) return false;
    const compressed_end = cursor + @as(usize, compressed_length);

    const metadata_offset = readBe32(bytes, 28) orelse return false;
    const metadata_length = readBe32(bytes, 32) orelse return false;
    const metadata_original_length = readBe32(bytes, 36) orelse return false;
    if (metadata_offset == 0) {
        if (metadata_length != 0 or metadata_original_length != 0) return false;
    } else if (metadata_length == 0 or metadata_original_length == 0 or
        @as(usize, metadata_offset) < compressed_end or !rangeWithin(bytes.len, metadata_offset, metadata_length))
    {
        return false;
    }

    const private_offset = readBe32(bytes, 40) orelse return false;
    const private_length = readBe32(bytes, 44) orelse return false;
    if (private_offset == 0) {
        if (private_length != 0) return false;
    } else if (private_length == 0 or @as(usize, private_offset) < compressed_end or !rangeWithin(bytes.len, private_offset, private_length)) {
        return false;
    }
    return true;
}

fn validSfnt(bytes: []const u8) bool {
    const header_size: usize = 12;
    const entry_size: usize = 16;
    if (bytes.len < header_size) return false;
    const table_count = readBe16(bytes, 4) orelse return false;
    if (table_count == 0) return false;
    const directory_end = directoryEnd(header_size, table_count, entry_size, bytes.len) orelse return false;

    var has_table_data = false;
    var index: usize = 0;
    while (index < table_count) : (index += 1) {
        const entry = header_size + index * entry_size;
        const offset = readBe32(bytes, entry + 8) orelse return false;
        const length = readBe32(bytes, entry + 12) orelse return false;
        if (length == 0) {
            if (@as(usize, offset) > bytes.len) return false;
            continue;
        }
        has_table_data = true;
        if (@as(usize, offset) < directory_end or offset % 4 != 0 or !rangeWithin(bytes.len, offset, length)) return false;
    }
    return has_table_data;
}

fn readBe16(bytes: []const u8, offset: usize) ?u16 {
    if (offset > bytes.len or bytes.len - offset < 2) return null;
    return (@as(u16, bytes[offset]) << 8) | @as(u16, bytes[offset + 1]);
}

fn readBe32(bytes: []const u8, offset: usize) ?u32 {
    if (offset > bytes.len or bytes.len - offset < 4) return null;
    return (@as(u32, bytes[offset]) << 24) |
        (@as(u32, bytes[offset + 1]) << 16) |
        (@as(u32, bytes[offset + 2]) << 8) |
        @as(u32, bytes[offset + 3]);
}

fn readUIntBase128(bytes: []const u8, cursor: *usize) ?u32 {
    var value: u64 = 0;
    var count: usize = 0;
    while (count < 5) : (count += 1) {
        if (cursor.* >= bytes.len) return null;
        const byte = bytes[cursor.*];
        cursor.* += 1;
        if (count == 0 and byte == 0x80) return null;
        value = (value << 7) | (byte & 0x7f);
        if (value > std.math.maxInt(u32)) return null;
        if (byte & 0x80 == 0) return @intCast(value);
    }
    return null;
}

fn directoryEnd(header_size: usize, table_count: u16, entry_size: usize, limit: usize) ?usize {
    const count: usize = table_count;
    if (count > (limit -| header_size) / entry_size) return null;
    return header_size + count * entry_size;
}

fn rangeWithin(total: usize, offset: usize, length: usize) bool {
    return offset <= total and length <= total - offset;
}

fn declaredCacheFormat(value: r4os.web_fonts.FontFormat) ?cache.FontFormat {
    return switch (value) {
        .woff => .woff,
        .woff2 => .woff2,
        .truetype => .truetype,
        .opentype => .opentype,
        else => null,
    };
}

fn formatHintCompatible(hint: cache.FontFormat, concrete: cache.FontFormat) bool {
    if (hint == concrete) return true;
    const hint_sfnt = hint == .truetype or hint == .opentype;
    const concrete_sfnt = concrete == .truetype or concrete == .opentype;
    return hint_sfnt and concrete_sfnt;
}

fn mimeFormat(raw: []const u8) ?cache.FontFormat {
    const end = std.mem.indexOfScalar(u8, raw, ';') orelse raw.len;
    const value = std.mem.trim(u8, raw[0..end], " \t");
    if (std.ascii.eqlIgnoreCase(value, "font/woff")) return .woff;
    if (std.ascii.eqlIgnoreCase(value, "font/woff2")) return .woff2;
    if (std.ascii.eqlIgnoreCase(value, "font/ttf") or std.ascii.eqlIgnoreCase(value, "application/x-font-ttf")) return .truetype;
    if (std.ascii.eqlIgnoreCase(value, "font/otf") or std.ascii.eqlIgnoreCase(value, "application/x-font-opentype")) return .opentype;
    return null;
}

fn urlFormat(raw: []const u8) ?cache.FontFormat {
    var end = raw.len;
    if (std.mem.indexOfAny(u8, raw, "?#")) |marker| end = marker;
    const value = raw[0..end];
    if (endsWithIgnoreCase(value, ".woff2")) return .woff2;
    if (endsWithIgnoreCase(value, ".woff")) return .woff;
    if (endsWithIgnoreCase(value, ".ttf")) return .truetype;
    if (endsWithIgnoreCase(value, ".otf")) return .opentype;
    return null;
}

fn endsWithIgnoreCase(value: []const u8, suffix: []const u8) bool {
    return value.len >= suffix.len and std.ascii.eqlIgnoreCase(value[value.len - suffix.len ..], suffix);
}

/// Guest-safe cache contract probe used by Klickifax `/SELFTEST`.  It only
/// touches the browser's temporary font cache, reopens the persistent state
/// to prove a warm hit, and removes its own URL alias and unshared object.
pub fn selfTest(allocator: std.mem.Allocator, files: r4os.Files, now: u64) Error!SelfTestReport {
    const request_origin = "https://selftest.r4os.invalid";
    const source_url = "https://selftest.r4os.invalid/cache-probe.ttf";
    const final_url = "https://cdn.selftest.r4os.invalid/cache-probe-v2.ttf";
    const probe_bytes = selfTestProbeBytes();
    const probe_format = detectFormat(.truetype, "font/ttf", source_url, probe_bytes[0..]) catch
        return error.SelfTestProbeFormat;
    if (probe_format != .truetype) return error.SelfTestProbeFormat;
    const base_tx = if (now == 0) @as(u64, 0x4b465801) else now ^ 0x4b465800;
    var report = SelfTestReport{};

    var first = try Store.init(allocator, files, .{});
    defer first.deinit();
    _ = first.load(now, nonzeroTransaction(base_tx)) catch return error.SelfTestInitialLoad;

    var warm = try Store.init(allocator, files, .{});
    defer warm.deinit();
    var held = first.acquireLock() catch return error.SelfTestLeaseAcquire;
    var held_open = true;
    defer if (held_open) releaseLock(&held);
    report.lease_busy = busy: {
        _ = warm.load(now, nonzeroTransaction(base_tx +% 1)) catch |err| switch (err) {
            error.CacheBusy => break :busy true,
            else => return error.SelfTestLeaseBusy,
        };
        break :busy false;
    };
    releaseLockChecked(&held) catch return error.SelfTestLeaseRelease;
    held_open = false;
    _ = warm.load(now, nonzeroTransaction(base_tx +% 2)) catch return error.SelfTestWarmLoad;

    var cleanup_needed = false;
    defer {
        if (cleanup_needed) _ = first.removeUrl(request_origin, source_url, .truetype, nonzeroTransaction(base_tx +% 11)) catch false;
    }
    const committed = try first.commit(
        probe_bytes[0..],
        request_origin,
        source_url,
        final_url,
        "Font/TTF; charset=binary",
        .truetype,
        now,
        nonzeroTransaction(base_tx +% 3),
    );
    cleanup_needed = true;
    const expected_id = cache.contentId(probe_bytes[0..]);
    report.staged_and_committed = std.mem.eql(u8, &committed.id, &expected_id);
    const immediate = first.lookup(request_origin, source_url, .truetype, now +| 1, nonzeroTransaction(base_tx +% 4)) catch
        return error.SelfTestImmediateLookup;
    var immediate_bytes = if (immediate) |token|
        first.loadAuthorized(allocator, request_origin, source_url, token, now +| 1, nonzeroTransaction(base_tx +% 5)) catch
            return error.SelfTestImmediateLookup
    else
        null;
    defer if (immediate_bytes) |*loaded| loaded.deinit(allocator);
    report.immediate_lookup = immediate != null and immediate_bytes != null and
        std.mem.eql(u8, immediate.?.final_url.bytes(), final_url) and
        std.mem.eql(u8, immediate_bytes.?.bytes, probe_bytes[0..]);

    const warm_hit = warm.lookup(request_origin, source_url, .truetype, now +| 2, nonzeroTransaction(base_tx +% 6)) catch
        return error.SelfTestWarmLookup;
    var warm_bytes = if (warm_hit) |token|
        warm.loadAuthorized(allocator, request_origin, source_url, token, now +| 2, nonzeroTransaction(base_tx +% 7)) catch
            return error.SelfTestWarmLookup
    else
        null;
    defer if (warm_bytes) |*loaded| loaded.deinit(allocator);
    report.warm_lookup = warm_hit != null and warm_bytes != null and
        std.mem.eql(u8, warm_hit.?.final_url.bytes(), final_url) and
        std.mem.eql(u8, warm_bytes.?.bytes, probe_bytes[0..]);
    const warm_commit = try warm.commit(
        probe_bytes[0..],
        request_origin,
        source_url,
        final_url,
        "font/ttf; charset=binary",
        .truetype,
        now +| 3,
        nonzeroTransaction(base_tx +% 8),
    );
    const recovered_hit = try warm.lookup(request_origin, source_url, .opentype, now +| 4, nonzeroTransaction(base_tx +% 9));
    report.lease_recovered = recovered_hit != null and
        std.mem.eql(u8, &warm_commit.id, &expected_id) and
        std.mem.eql(u8, recovered_hit.?.final_url.bytes(), final_url);
    report.cleanup = if (recovered_hit) |token|
        warm.removeAuthorized(request_origin, source_url, token, nonzeroTransaction(base_tx +% 10)) catch
            return error.SelfTestCleanup
    else
        false;
    cleanup_needed = !report.cleanup;
    return report;
}

fn selfTestProbeBytes() [32]u8 {
    return minimalSfntFixture(&[_]u8{ 0, 1, 0, 0 });
}

fn nonzeroTransaction(value: u64) u64 {
    return if (value == 0) 1 else value;
}

fn releaseLock(writer: *r4os.app_storage.OwnedStageWriter) void {
    _ = writer.abort();
}

fn releaseLockChecked(writer: *r4os.app_storage.OwnedStageWriter) Error!void {
    switch (writer.abort()) {
        .ok => {},
        .missing, .failure => return error.Io,
    }
}

fn leaseOpenError(code: i32) Error {
    return if (code == r4os.abi.file_stream_error_exists) error.CacheBusy else error.Io;
}

fn requireCatalogDiscard(result: r4os.app_storage.Operation) Error!void {
    switch (result) {
        .ok, .missing => {},
        .failure => return error.Io,
    }
}

const AtomicSiblingPaths = struct { stage: cache.Path, backup: cache.Path };

fn atomicSiblingPaths(directory: []const u8, prefix: []const u8, transaction_id: u64) Error!AtomicSiblingPaths {
    if (transaction_id == 0 or prefix.len != 2) return error.InvalidTransaction;
    const suffix: u32 = @truncate(transaction_id);
    var stage_buffer: [cache.max_path_bytes]u8 = undefined;
    var backup_buffer: [cache.max_path_bytes]u8 = undefined;
    // Atomic stage/backup names are deliberately portable FAT/NTFS 8.3
    // names.  Lower-case hexadecimal is not accepted by that shared
    // ownership-transfer contract; transactions whose low suffix first
    // reached A-F otherwise failed only after several successful publishes.
    const stage_text = std.fmt.bufPrint(stage_buffer[0..], "{s}{s}{X:0>6}.TMP", .{ directory, prefix, suffix & 0x00ff_ffff }) catch return error.PathTooLong;
    const backup_text = std.fmt.bufPrint(backup_buffer[0..], "{s}{s}{X:0>6}.BAK", .{ directory, prefix, suffix & 0x00ff_ffff }) catch return error.PathTooLong;
    var stage = cache.Path{};
    var backup = cache.Path{};
    try stage.set(stage_text);
    try backup.set(backup_text);
    return .{ .stage = stage, .backup = backup };
}

fn absolute(text: []const u8) !r4os.AbsoluteFilePath {
    return r4os.AbsoluteFilePath.parse(text);
}

fn baseName(path: []const u8) []const u8 {
    var start: usize = 0;
    for (path, 0..) |byte, index| {
        if (byte == '\\' or byte == '/') start = index + 1;
    }
    return path[start..];
}

fn isAtomicTempName(name: []const u8, prefix: []const u8) bool {
    if (prefix.len != 2 or name.len != 12 or !std.ascii.eqlIgnoreCase(name[0..2], prefix)) return false;
    for (name[2..8]) |byte| if (hexNibble(byte) == null) return false;
    return std.ascii.eqlIgnoreCase(name[8..], ".TMP") or std.ascii.eqlIgnoreCase(name[8..], ".BAK");
}

fn aliasOrder(a: *const Alias, b: *const Alias) std.math.Order {
    const origin_order = std.mem.order(u8, a.request_origin.bytes(), b.request_origin.bytes());
    if (origin_order != .eq) return origin_order;
    const url_order = std.mem.order(u8, a.source_url.bytes(), b.source_url.bytes());
    if (url_order != .eq) return url_order;
    return std.math.order(@intFromEnum(a.format), @intFromEnum(b.format));
}

const catalog_bom = [_]u8{ 0xef, 0xbb, 0xbf };
const catalog_header = "R4FONT-CACHE|2\r\n";

pub fn encodeState(state: *const State, output: []u8) Error![]const u8 {
    if (!state.validate()) return error.CatalogCorrupt;
    var len: usize = 0;
    try append(output, &len, &catalog_bom);
    try append(output, &len, catalog_header);
    try appendNumberLine(output, &len, "ENTRIES|", state.catalog.count);
    for (&state.catalog.entries) |*entry| {
        if (!entry.occupied) continue;
        try append(output, &len, "ENTRY|");
        try appendHex(output, &len, &entry.id);
        try append(output, &len, "|");
        try appendHex(output, &len, &entry.checksum);
        try append(output, &len, "|");
        try append(output, &len, entry.format.label());
        try append(output, &len, "|");
        try appendNumber(output, &len, entry.size);
        try append(output, &len, "|");
        try appendNumber(output, &len, entry.created_at);
        try append(output, &len, "|");
        try appendNumber(output, &len, entry.last_access);
        try append(output, &len, "|");
        try appendHex(output, &len, entry.mime.bytes());
        try append(output, &len, "|");
        try appendHex(output, &len, entry.source_url.bytes());
        try append(output, &len, "\r\n");
    }
    try appendNumberLine(output, &len, "ALIASES|", state.alias_count);
    for (&state.aliases) |*alias| {
        if (!alias.occupied) continue;
        try append(output, &len, "ALIAS|");
        try appendHex(output, &len, &alias.id);
        try append(output, &len, "|");
        try append(output, &len, alias.format.label());
        try append(output, &len, "|");
        try appendNumber(output, &len, alias.last_access);
        try append(output, &len, "|");
        try appendHex(output, &len, alias.request_origin.bytes());
        try append(output, &len, "|");
        try appendHex(output, &len, alias.source_url.bytes());
        try append(output, &len, "|");
        try appendHex(output, &len, alias.final_url.bytes());
        try append(output, &len, "\r\n");
    }

    var checksum: cache.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(output[0..len], &checksum, .{});
    try append(output, &len, "END|");
    try appendHex(output, &len, &checksum);
    try append(output, &len, "\r\n");
    return output[0..len];
}

pub fn decodeState(input: []const u8, policy: cache.Policy) Error!State {
    if (!policy.valid()) return error.ReservationTooLarge;
    if (input.len < catalog_bom.len + catalog_header.len + 4 or
        !std.mem.eql(u8, input[0..catalog_bom.len], &catalog_bom)) return error.CatalogCorrupt;
    if (!std.mem.endsWith(u8, input, "\r\n")) return error.CatalogCorrupt;
    const marker = std.mem.lastIndexOf(u8, input, "\nEND|") orelse return error.CatalogCorrupt;
    const end_start = marker + 1;
    const footer = input[end_start .. input.len - 2];
    if (footer.len != "END|".len + cache.digest_hex_bytes or !std.mem.startsWith(u8, footer, "END|")) return error.CatalogCorrupt;
    var expected: cache.Digest = undefined;
    try decodeHexExact(footer["END|".len..], &expected);
    var actual: cache.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(input[0..end_start], &actual, .{});
    if (!std.mem.eql(u8, &actual, &expected)) return error.CatalogCorrupt;

    var lines = std.mem.splitScalar(u8, input[0..end_start], '\n');
    const first_raw = lines.next() orelse return error.CatalogCorrupt;
    if (first_raw.len < catalog_bom.len or !std.mem.eql(u8, first_raw[0..catalog_bom.len], &catalog_bom) or
        !std.mem.eql(u8, trimLine(first_raw[catalog_bom.len..]), trimLine(catalog_header))) return error.CatalogCorrupt;
    const entry_count = try parseCountLine(lines.next() orelse return error.CatalogCorrupt, "ENTRIES|", cache.max_entries);
    var state = State{};
    var entry_index: usize = 0;
    while (entry_index < entry_count) : (entry_index += 1) {
        try parseEntryLine(trimLine(lines.next() orelse return error.CatalogCorrupt), &state, policy);
    }
    const alias_count = try parseCountLine(lines.next() orelse return error.CatalogCorrupt, "ALIASES|", max_aliases);
    var alias_index: usize = 0;
    while (alias_index < alias_count) : (alias_index += 1) {
        try parseAliasLine(trimLine(lines.next() orelse return error.CatalogCorrupt), &state);
    }
    while (lines.next()) |line| if (trimLine(line).len != 0) return error.CatalogCorrupt;
    if (state.catalog.count != entry_count or state.alias_count != alias_count or !state.validate()) return error.CatalogCorrupt;
    if (state.catalog.total_bytes > policy.max_total_bytes or state.catalog.count > policy.max_entry_count) return error.CatalogCorrupt;
    return state;
}

fn parseEntryLine(line: []const u8, state: *State, policy: cache.Policy) Error!void {
    var fields = std.mem.splitScalar(u8, line, '|');
    if (!std.mem.eql(u8, fields.next() orelse return error.CatalogCorrupt, "ENTRY")) return error.CatalogCorrupt;
    var metadata = cache.Metadata{ .occupied = true };
    try decodeHexExact(fields.next() orelse return error.CatalogCorrupt, &metadata.id);
    try decodeHexExact(fields.next() orelse return error.CatalogCorrupt, &metadata.checksum);
    metadata.format = parseFormat(fields.next() orelse return error.CatalogCorrupt) orelse return error.CatalogCorrupt;
    metadata.size = parseU64(fields.next() orelse return error.CatalogCorrupt) orelse return error.CatalogCorrupt;
    metadata.created_at = parseU64(fields.next() orelse return error.CatalogCorrupt) orelse return error.CatalogCorrupt;
    metadata.last_access = parseU64(fields.next() orelse return error.CatalogCorrupt) orelse return error.CatalogCorrupt;
    var mime: [cache.max_mime_bytes]u8 = undefined;
    const mime_len = try decodeHex(fields.next() orelse return error.CatalogCorrupt, mime[0..]);
    var url: [cache.max_source_url_bytes]u8 = undefined;
    const url_len = try decodeHex(fields.next() orelse return error.CatalogCorrupt, url[0..]);
    var normalized_mime: [cache.max_mime_bytes]u8 = undefined;
    const canonical_mime = normalizeMediaType(mime[0..mime_len], normalized_mime[0..]) catch return error.CatalogCorrupt;
    if (fields.next() != null or metadata.size > policy.max_object_bytes or
        !std.mem.eql(u8, canonical_mime, mime[0..mime_len]) or !validSourceUrl(url[0..url_len])) return error.CatalogCorrupt;
    try metadata.mime.set(mime[0..mime_len]);
    try metadata.source_url.set(url[0..url_len]);
    if (!metadata.valid()) return error.CatalogCorrupt;
    _ = state.catalog.recordCommitted(&.{ .metadata = metadata }) catch return error.CatalogCorrupt;
}

fn parseAliasLine(line: []const u8, state: *State) Error!void {
    var fields = std.mem.splitScalar(u8, line, '|');
    if (!std.mem.eql(u8, fields.next() orelse return error.CatalogCorrupt, "ALIAS")) return error.CatalogCorrupt;
    var id: cache.Digest = undefined;
    try decodeHexExact(fields.next() orelse return error.CatalogCorrupt, &id);
    const format = parseFormat(fields.next() orelse return error.CatalogCorrupt) orelse return error.CatalogCorrupt;
    const last_access = parseU64(fields.next() orelse return error.CatalogCorrupt) orelse return error.CatalogCorrupt;
    var origin: [max_partition_origin_bytes]u8 = undefined;
    const origin_len = try decodeHex(fields.next() orelse return error.CatalogCorrupt, origin[0..]);
    var url: [cache.max_source_url_bytes]u8 = undefined;
    const url_len = try decodeHex(fields.next() orelse return error.CatalogCorrupt, url[0..]);
    var final_url: [cache.max_source_url_bytes]u8 = undefined;
    const final_url_len = try decodeHex(fields.next() orelse return error.CatalogCorrupt, final_url[0..]);
    if (fields.next() != null or !validCanonicalOrigin(origin[0..origin_len]) or
        !validSourceUrl(url[0..url_len]) or !validSourceUrl(final_url[0..final_url_len])) return error.CatalogCorrupt;
    try state.putAlias(origin[0..origin_len], url[0..url_len], final_url[0..final_url_len], format, id, last_access);
}

fn append(output: []u8, len: *usize, value: []const u8) Error!void {
    if (value.len > output.len -| len.*) return error.BufferTooSmall;
    if (value.len > 0) @memcpy(output[len.* .. len.* + value.len], value);
    len.* += value.len;
}

fn appendHex(output: []u8, len: *usize, value: []const u8) Error!void {
    const alphabet = "0123456789abcdef";
    if (value.len > (output.len -| len.*) / 2) return error.BufferTooSmall;
    for (value) |byte| {
        output[len.*] = alphabet[byte >> 4];
        output[len.* + 1] = alphabet[byte & 0x0f];
        len.* += 2;
    }
}

fn appendNumber(output: []u8, len: *usize, value: anytype) Error!void {
    var buffer: [32]u8 = undefined;
    const text = std.fmt.bufPrint(buffer[0..], "{d}", .{value}) catch return error.BufferTooSmall;
    try append(output, len, text);
}

fn appendNumberLine(output: []u8, len: *usize, prefix: []const u8, value: anytype) Error!void {
    try append(output, len, prefix);
    try appendNumber(output, len, value);
    try append(output, len, "\r\n");
}

fn decodeHex(input: []const u8, output: []u8) Error!usize {
    if ((input.len & 1) != 0 or input.len / 2 > output.len) return error.CatalogCorrupt;
    var index: usize = 0;
    while (index < input.len / 2) : (index += 1) {
        const high = hexNibble(input[index * 2]) orelse return error.CatalogCorrupt;
        const low = hexNibble(input[index * 2 + 1]) orelse return error.CatalogCorrupt;
        output[index] = (high << 4) | low;
    }
    return input.len / 2;
}

fn decodeHexExact(input: []const u8, output: anytype) Error!void {
    const slice = output[0..];
    const count = try decodeHex(input, slice);
    if (count != slice.len) return error.CatalogCorrupt;
}

fn hexNibble(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

fn parseCountLine(raw: []const u8, prefix: []const u8, limit: usize) Error!usize {
    const line = trimLine(raw);
    if (!std.mem.startsWith(u8, line, prefix)) return error.CatalogCorrupt;
    const value = std.fmt.parseInt(usize, line[prefix.len..], 10) catch return error.CatalogCorrupt;
    if (value > limit) return error.CatalogCorrupt;
    return value;
}

fn parseU64(value: []const u8) ?u64 {
    if (value.len == 0) return null;
    return std.fmt.parseInt(u64, value, 10) catch null;
}

fn parseFormat(value: []const u8) ?cache.FontFormat {
    inline for (std.meta.fields(cache.FontFormat)) |field| {
        const format: cache.FontFormat = @enumFromInt(field.value);
        if (std.mem.eql(u8, value, format.label())) return format;
    }
    return null;
}

fn trimLine(line: []const u8) []const u8 {
    return std.mem.trimEnd(u8, line, "\r\n");
}

fn validSourceUrl(value: []const u8) bool {
    if (value.len == 0 or value.len > cache.max_source_url_bytes) return false;
    if (!startsWithIgnoreCase(value, "http://") and !startsWithIgnoreCase(value, "https://")) return false;
    for (value) |byte| if (byte < 0x21 or byte == 0x7f) return false;
    return true;
}

fn validCanonicalOrigin(value: []const u8) bool {
    var normalized = OriginKey{};
    normalizeOrigin(value, &normalized) catch return false;
    return std.mem.eql(u8, value, normalized.bytes());
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

test "font cache catalog roundtrip keeps BOM aliases and integrity footer" {
    var state = State{};
    var origin_a = OriginKey{};
    var origin_b = OriginKey{};
    try normalizeOrigin("https://A.example/path", &origin_a);
    try normalizeOrigin("https://b.example/", &origin_b);
    const shared_url = "https://cdn.example/font.woff2";
    const first = try cache.prepare("same font bytes", shared_url, "font/woff2", .woff2, 10, .{});
    const second = try cache.prepare("same font bytes", "https://b.example/renamed.woff2", "font/woff2", .woff2, 20, .{});
    const third = try cache.prepare("different origin bytes", shared_url, "font/woff2", .woff2, 30, .{});
    try std.testing.expectEqual(cache.Disposition.new_object, try state.recordPrepared(origin_a.bytes(), "https://assets.example/final-a.woff2", &first));
    try std.testing.expectEqual(cache.Disposition.duplicate, try state.recordPrepared(origin_a.bytes(), "https://assets.example/final-b.woff2", &second));
    try std.testing.expectEqual(cache.Disposition.new_object, try state.recordPrepared(origin_b.bytes(), "https://assets.example/final-c.woff2", &third));
    try std.testing.expectEqual(@as(usize, 2), state.catalog.count);
    try std.testing.expectEqual(@as(usize, 3), state.alias_count);
    try std.testing.expect(std.mem.eql(u8, &(state.findUrl(origin_a.bytes(), first.metadata.source_url.bytes(), .woff2).?), &first.metadata.id));
    try std.testing.expect(std.mem.eql(u8, &(state.findUrl(origin_a.bytes(), second.metadata.source_url.bytes(), .woff2).?), &first.metadata.id));
    try std.testing.expect(std.mem.eql(u8, &(state.findUrl(origin_b.bytes(), shared_url, .woff2).?), &third.metadata.id));
    try std.testing.expect(!std.mem.eql(u8, &(state.findUrl(origin_a.bytes(), shared_url, .woff2).?), &(state.findUrl(origin_b.bytes(), shared_url, .woff2).?)));

    const buffer = try std.testing.allocator.alloc(u8, max_catalog_bytes);
    defer std.testing.allocator.free(buffer);
    const encoded = try encodeState(&state, buffer);
    try std.testing.expect(std.mem.startsWith(u8, encoded, &catalog_bom));
    const decoded = try decodeState(encoded, .{});
    try std.testing.expect(decoded.validate());
    try std.testing.expectEqual(@as(usize, 3), decoded.alias_count);
    try std.testing.expect(std.mem.eql(u8, &(decoded.findUrl(origin_a.bytes(), first.metadata.source_url.bytes(), .woff2).?), &first.metadata.id));
    try std.testing.expect(std.mem.eql(u8, &(decoded.findUrl(origin_a.bytes(), second.metadata.source_url.bytes(), .woff2).?), &first.metadata.id));
    try std.testing.expect(std.mem.eql(u8, &(decoded.findUrl(origin_b.bytes(), shared_url, .woff2).?), &third.metadata.id));
    var saw_redirect = false;
    for (&decoded.aliases) |*alias| {
        if (alias.occupied and std.mem.eql(u8, alias.request_origin.bytes(), origin_a.bytes()) and
            std.mem.eql(u8, alias.source_url.bytes(), shared_url))
        {
            saw_redirect = std.mem.eql(u8, alias.final_url.bytes(), "https://assets.example/final-a.woff2");
        }
    }
    try std.testing.expect(saw_redirect);

    try std.testing.expectError(error.CatalogCorrupt, decodeState(encoded[0 .. encoded.len - 1], .{}));
    buffer[8] ^= 1;
    try std.testing.expectError(error.CatalogCorrupt, decodeState(encoded, .{}));
}

fn testWoffFixture() [68]u8 {
    var bytes = [_]u8{0} ** 68;
    @memcpy(bytes[0..4], "wOFF");
    bytes[5] = 1;
    writeBe32(bytes[0..], 8, @intCast(bytes.len));
    writeBe16(bytes[0..], 12, 1);
    writeBe32(bytes[0..], 16, 32);
    @memcpy(bytes[44..48], "cmap");
    writeBe32(bytes[0..], 48, 64);
    writeBe32(bytes[0..], 52, 4);
    writeBe32(bytes[0..], 56, 4);
    @memcpy(bytes[64..68], "font");
    return bytes;
}

fn testWoff2Fixture() [54]u8 {
    var bytes = [_]u8{0} ** 54;
    @memcpy(bytes[0..4], "wOF2");
    bytes[5] = 1;
    writeBe32(bytes[0..], 8, @intCast(bytes.len));
    writeBe16(bytes[0..], 12, 1);
    writeBe32(bytes[0..], 16, 32);
    writeBe32(bytes[0..], 20, 4);
    bytes[48] = 0;
    bytes[49] = 4;
    @memcpy(bytes[50..54], "font");
    return bytes;
}

fn minimalSfntFixture(magic: []const u8) [32]u8 {
    std.debug.assert(magic.len == 4);
    var bytes = [_]u8{0} ** 32;
    @memcpy(bytes[0..4], magic);
    writeBe16(bytes[0..], 4, 1);
    @memcpy(bytes[12..16], "cmap");
    writeBe32(bytes[0..], 20, 28);
    writeBe32(bytes[0..], 24, 4);
    @memcpy(bytes[28..32], "font");
    return bytes;
}

fn writeBe16(bytes: []u8, offset: usize, value: u16) void {
    std.debug.assert(offset <= bytes.len and bytes.len - offset >= 2);
    bytes[offset] = @truncate(value >> 8);
    bytes[offset + 1] = @truncate(value);
}

fn writeBe32(bytes: []u8, offset: usize, value: u32) void {
    std.debug.assert(offset <= bytes.len and bytes.len - offset >= 4);
    bytes[offset] = @truncate(value >> 24);
    bytes[offset + 1] = @truncate(value >> 16);
    bytes[offset + 2] = @truncate(value >> 8);
    bytes[offset + 3] = @truncate(value);
}

test "atomic font cache siblings are same-directory short names" {
    const parent = try cache.objectParentPath(cache.contentId("font object"));
    const object = try atomicSiblingPaths(parent.bytes(), "KF", 0x12abcdef);
    var expected: [cache.max_path_bytes]u8 = undefined;
    const expected_stage = try std.fmt.bufPrint(expected[0..], "{s}KFABCDEF.TMP", .{parent.bytes()});
    try std.testing.expectEqualStrings(expected_stage, object.stage.bytes());
    try std.testing.expect(std.mem.startsWith(u8, object.backup.bytes(), parent.bytes()));
    try std.testing.expectEqualStrings("KFABCDEF.BAK", baseName(object.backup.bytes()));
    const catalog = try atomicSiblingPaths(cache.root_path, "KC", 0xface);
    try std.testing.expectEqualStrings(cache.root_path ++ "KC00FACE.TMP", catalog.stage.bytes());
    try std.testing.expectEqualStrings(cache.root_path ++ "KC00FACE.BAK", catalog.backup.bytes());
}

test "hierarchical object orphan classification uses the complete SHA-256 path" {
    const prepared = try cache.prepare("font", "https://example.test/font.ttf", "font/ttf", .truetype, 1, .{});
    const orphan = try cache.prepare("orphan", "https://example.test/orphan.ttf", "font/ttf", .truetype, 1, .{});
    var state = State{};
    _ = try state.catalog.recordCommitted(&prepared);
    const path = try cache.objectPath(prepared.metadata.id);
    const parsed = cache.digestFromObjectPath(path.bytes()).?;
    try std.testing.expect(std.mem.eql(u8, &parsed, &prepared.metadata.id));
    try std.testing.expectEqual(ObjectFileDisposition.referenced, objectFileDisposition(&state, path.bytes()));
    try std.testing.expectEqual(ObjectFileDisposition.orphan, objectFileDisposition(&state, (try cache.objectPath(orphan.metadata.id)).bytes()));
    try std.testing.expectEqual(ObjectFileDisposition.orphan, objectFileDisposition(&state, cache.objects_path ++ "01234567.FNT"));
}

test "hierarchical object cleanup has a hard entry budget" {
    var budget = ObjectTreeBudget{ .visited_entries = max_object_cleanup_entries - 1 };
    try budget.visit();
    try std.testing.expectEqual(max_object_cleanup_entries, budget.visited_entries);
    try std.testing.expectError(error.DirectoryTraversalLimit, budget.visit());
}

test "font format detection requires complete bounded containers and rejects mislabeled payloads" {
    const woff = testWoffFixture();
    const woff2 = testWoff2Fixture();
    const truetype = minimalSfntFixture(&[_]u8{ 0, 1, 0, 0 });
    const opentype = minimalSfntFixture("OTTO");

    try std.testing.expectEqual(cache.FontFormat.woff, try detectFormat(.unspecified, "application/octet-stream", "https://cdn.test/font", woff[0..]));
    try std.testing.expectEqual(cache.FontFormat.woff2, try detectFormat(.woff2, "font/woff2", "https://cdn.test/font.bin", woff2[0..]));
    try std.testing.expectEqual(cache.FontFormat.truetype, try detectFormat(.unspecified, "font/ttf", "https://cdn.test/font.ttf", truetype[0..]));
    try std.testing.expectEqual(cache.FontFormat.opentype, try detectFormat(.opentype, "font/otf", "https://cdn.test/font.otf", opentype[0..]));
    try std.testing.expectEqual(cache.FontFormat.truetype, try detectFormat(.opentype, "application/octet-stream", "https://cdn.test/font", truetype[0..]));
    try std.testing.expectEqual(cache.FontFormat.opentype, try detectFormat(.truetype, "application/octet-stream", "https://cdn.test/font", opentype[0..]));
    try std.testing.expectError(error.UnsupportedFormat, detectFormat(.woff2, "font/woff2", "https://cdn.test/font.woff2", truetype[0..]));
    try std.testing.expectError(error.UnsupportedFormat, detectFormat(.unspecified, "font/woff2", "https://cdn.test/font.woff2", "<!doctype html>"));
    try std.testing.expectError(error.UnsupportedFormat, detectFormat(.unspecified, "font/woff2", "https://cdn.test/font.woff2", woff[0..]));
    try std.testing.expectError(error.UnsupportedFormat, detectFormat(.unspecified, "font/woff", "https://cdn.test/font.woff", "wOFFpayload"));
    try std.testing.expectError(error.UnsupportedFormat, detectFormat(.unspecified, "font/woff2", "https://cdn.test/font.woff2", "wOF2payload"));
    try std.testing.expectError(error.UnsupportedFormat, detectFormat(.unspecified, "font/ttf", "https://cdn.test/font.ttf", &[_]u8{ 0, 1, 0, 0 }));
}

test "guest font cache selftest probe is a complete validated SFNT" {
    const probe = selfTestProbeBytes();
    try std.testing.expectEqual(
        cache.FontFormat.truetype,
        try detectFormat(.truetype, "font/ttf", "https://selftest.r4os.invalid/cache-probe.ttf", probe[0..]),
    );
}

test "owned warm bytes require matching digest metadata and complete container" {
    var probe = selfTestProbeBytes();
    const prepared = try cache.prepare(
        probe[0..],
        "https://fonts.example/runtime.ttf",
        "font/ttf",
        .truetype,
        1,
        .{},
    );
    try std.testing.expect(loadedObjectValid(&prepared.metadata, "https://cdn.example/runtime.ttf", probe[0..]));

    probe[probe.len - 1] ^= 0x01;
    try std.testing.expect(!loadedObjectValid(&prepared.metadata, "https://cdn.example/runtime.ttf", probe[0..]));
    probe[probe.len - 1] ^= 0x01;

    var wrong_format = prepared.metadata;
    wrong_format.format = .opentype;
    try std.testing.expect(!loadedObjectValid(&wrong_format, "https://cdn.example/runtime.otf", probe[0..]));
    try std.testing.expect(!loadedObjectValid(&prepared.metadata, "https://cdn.example/runtime.ttf", probe[0 .. probe.len - 1]));
}

test "authorized warm token cannot consume a replaced alias" {
    var origin = OriginKey{};
    try normalizeOrigin("https://page.example/", &origin);
    const source_url = "https://fonts.example/runtime.ttf";
    const first_bytes = selfTestProbeBytes();
    var second_bytes = selfTestProbeBytes();
    second_bytes[second_bytes.len - 1] ^= 0x01;
    const first = try cache.prepare(first_bytes[0..], source_url, "font/ttf", .truetype, 1, .{});
    const second = try cache.prepare(second_bytes[0..], source_url, "font/ttf", .truetype, 2, .{});
    var state = State{};
    _ = try state.recordPrepared(origin.bytes(), "https://cdn.example/first.ttf", &first);
    const first_alias = (try selectAlias(&state, origin.bytes(), source_url, .truetype)).?;
    const first_token = LookupResult{
        .id = first_alias.id,
        .path = try cache.objectPath(first_alias.id),
        .format = first_alias.format,
        .final_url = first_alias.final_url,
    };
    try std.testing.expect(authorizedAlias(&state, origin.bytes(), source_url, first_token) != null);

    _ = try state.recordPrepared(origin.bytes(), "https://cdn.example/second.ttf", &second);
    try std.testing.expect(authorizedAlias(&state, origin.bytes(), source_url, first_token) == null);
    const second_alias = (try selectAlias(&state, origin.bytes(), source_url, .truetype)).?;
    const second_token = LookupResult{
        .id = second_alias.id,
        .path = try cache.objectPath(second_alias.id),
        .format = second_alias.format,
        .final_url = second_alias.final_url,
    };
    try std.testing.expect(authorizedAlias(&state, origin.bytes(), source_url, second_token) != null);
}

test "WOFF completeness rejects truncation length mismatch and bounded-directory failures" {
    var bytes = testWoffFixture();
    try std.testing.expectError(error.UnsupportedFormat, detectFormat(.woff, "font/woff", "https://cdn.test/font.woff", bytes[0 .. bytes.len - 1]));

    writeBe32(bytes[0..], 8, @intCast(bytes.len - 4));
    try std.testing.expectError(error.UnsupportedFormat, detectFormat(.woff, "font/woff", "https://cdn.test/font.woff", bytes[0..]));

    bytes = testWoffFixture();
    writeBe16(bytes[0..], 12, 0xffff);
    try std.testing.expectError(error.UnsupportedFormat, detectFormat(.woff, "font/woff", "https://cdn.test/font.woff", bytes[0..]));

    bytes = testWoffFixture();
    writeBe32(bytes[0..], 48, @intCast(bytes.len - 2));
    writeBe32(bytes[0..], 52, 8);
    try std.testing.expectError(error.UnsupportedFormat, detectFormat(.woff, "font/woff", "https://cdn.test/font.woff", bytes[0..]));
}

test "WOFF2 completeness rejects truncation length mismatch and bounded-stream failures" {
    var bytes = testWoff2Fixture();
    try std.testing.expectError(error.UnsupportedFormat, detectFormat(.woff2, "font/woff2", "https://cdn.test/font.woff2", bytes[0 .. bytes.len - 1]));

    writeBe32(bytes[0..], 8, @intCast(bytes.len - 1));
    try std.testing.expectError(error.UnsupportedFormat, detectFormat(.woff2, "font/woff2", "https://cdn.test/font.woff2", bytes[0..]));

    bytes = testWoff2Fixture();
    writeBe16(bytes[0..], 12, 0xffff);
    try std.testing.expectError(error.UnsupportedFormat, detectFormat(.woff2, "font/woff2", "https://cdn.test/font.woff2", bytes[0..]));

    bytes = testWoff2Fixture();
    writeBe32(bytes[0..], 20, @intCast(bytes.len));
    try std.testing.expectError(error.UnsupportedFormat, detectFormat(.woff2, "font/woff2", "https://cdn.test/font.woff2", bytes[0..]));
}

test "SFNT completeness rejects truncation directory overflow and table length mismatch" {
    var bytes = minimalSfntFixture(&[_]u8{ 0, 1, 0, 0 });
    try std.testing.expectError(error.UnsupportedFormat, detectFormat(.truetype, "font/ttf", "https://cdn.test/font.ttf", bytes[0 .. bytes.len - 1]));

    writeBe16(bytes[0..], 4, 0xffff);
    try std.testing.expectError(error.UnsupportedFormat, detectFormat(.truetype, "font/ttf", "https://cdn.test/font.ttf", bytes[0..]));

    bytes = minimalSfntFixture(&[_]u8{ 0, 1, 0, 0 });
    writeBe32(bytes[0..], 20, @intCast(bytes.len - 2));
    writeBe32(bytes[0..], 24, 8);
    try std.testing.expectError(error.UnsupportedFormat, detectFormat(.truetype, "font/ttf", "https://cdn.test/font.ttf", bytes[0..]));
}

test "origin and media type normalization are canonical and bounded" {
    var origin = OriginKey{};
    try normalizeOrigin("https://Example.COM:8443/path?q=1", &origin);
    try std.testing.expectEqualStrings("https://example.com:8443", origin.bytes());
    try std.testing.expectError(error.InvalidOrigin, normalizeOrigin("about:blank", &origin));
    var mime: [cache.max_mime_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("font/woff2", try normalizeMediaType(" Font/WOFF2; charset=binary ", mime[0..]));
    try std.testing.expectError(error.InvalidMediaType, normalizeMediaType("font/woff2\r\nX: bad", mime[0..]));
}

test "broken catalog discard propagates filesystem failures" {
    try requireCatalogDiscard(.ok);
    try requireCatalogDiscard(.missing);
    try std.testing.expectError(error.Io, requireCatalogDiscard(.{ .failure = -77 }));
}

test "font cache lease contention has a distinct retryable error" {
    try std.testing.expectEqual(error.CacheBusy, leaseOpenError(r4os.abi.file_stream_error_exists));
    try std.testing.expectEqual(error.Io, leaseOpenError(r4os.abi.file_stream_error_invalid));
}

test "lookup expiry is inclusive at policy boundary and preserves shared live objects" {
    const age = cache.default_max_age_seconds;
    const start: u64 = 100;
    var origin = OriginKey{};
    try normalizeOrigin("https://page.example/", &origin);

    var exact = State{};
    const exact_font = try cache.prepare("exact", "https://cdn.example/exact.woff2", "font/woff2", .woff2, start, .{});
    _ = try exact.recordPrepared(origin.bytes(), "https://cdn.example/exact-final.woff2", &exact_font);
    const exact_plan = try expireAliases(&exact, start + age, age);
    try std.testing.expectEqual(@as(usize, 1), exact_plan.removed_aliases);
    try std.testing.expectEqual(@as(usize, 1), exact_plan.object_count);
    try std.testing.expectEqual(@as(usize, 0), exact.catalog.count);

    var before = State{};
    _ = try before.recordPrepared(origin.bytes(), "https://cdn.example/exact-final.woff2", &exact_font);
    const before_plan = try expireAliases(&before, start + age - 1, age);
    try std.testing.expect(!before_plan.changed);
    try std.testing.expectEqual(@as(usize, 1), before.alias_count);
    try std.testing.expectEqual(@as(usize, 1), before.catalog.count);

    var shared = State{};
    const old_alias = try cache.prepare("shared", "https://cdn.example/old.woff2", "font/woff2", .woff2, start, .{});
    const live_alias = try cache.prepare("shared", "https://cdn.example/live.woff2", "font/woff2", .woff2, start + age - 1, .{});
    _ = try shared.recordPrepared(origin.bytes(), "https://cdn.example/shared.woff2", &old_alias);
    _ = try shared.recordPrepared(origin.bytes(), "https://cdn.example/shared.woff2", &live_alias);
    const shared_plan = try expireAliases(&shared, start + age, age);
    try std.testing.expectEqual(@as(usize, 1), shared_plan.removed_aliases);
    try std.testing.expectEqual(@as(usize, 0), shared_plan.object_count);
    try std.testing.expectEqual(@as(usize, 1), shared.alias_count);
    try std.testing.expectEqual(@as(usize, 1), shared.catalog.count);
    try std.testing.expect(shared.findUrl(origin.bytes(), live_alias.metadata.source_url.bytes(), .woff2) != null);
}

test "unknown wall clock neither expires nor touches and starts ageing on first valid hit" {
    const age = cache.default_max_age_seconds;
    var origin = OriginKey{};
    try normalizeOrigin("https://page.example/", &origin);

    var valid_then_invalid = State{};
    const valid = try cache.prepare("valid", "https://cdn.example/valid.woff2", "font/woff2", .woff2, 500, .{});
    _ = try valid_then_invalid.recordPrepared(origin.bytes(), "https://cdn.example/valid-final.woff2", &valid);
    const invalid_rtc = try expireAliases(&valid_then_invalid, 0, age);
    try std.testing.expect(!invalid_rtc.changed);
    try std.testing.expect(!touchLookupAccess(&valid_then_invalid, valid.metadata.id, origin.bytes(), valid.metadata.source_url.bytes(), .woff2, 0));
    try std.testing.expectEqual(@as(u64, 500), valid_then_invalid.catalog.find(valid.metadata.id).?.last_access);
    const restored_now = 500 + age - 1;
    const restored = try expireAliases(&valid_then_invalid, restored_now, age);
    try std.testing.expect(!restored.changed);
    try std.testing.expect(touchLookupAccess(&valid_then_invalid, valid.metadata.id, origin.bytes(), valid.metadata.source_url.bytes(), .woff2, restored_now));
    try std.testing.expectEqual(restored_now, valid_then_invalid.catalog.find(valid.metadata.id).?.last_access);

    var unknown_created = State{};
    const unknown = try cache.prepare("unknown", "https://cdn.example/unknown.woff2", "font/woff2", .woff2, 0, .{});
    _ = try unknown_created.recordPrepared(origin.bytes(), "https://cdn.example/unknown-final.woff2", &unknown);
    const first_valid_now = age * 4;
    const first_valid = try expireAliases(&unknown_created, first_valid_now, age);
    try std.testing.expect(!first_valid.changed);
    try std.testing.expect(touchLookupAccess(&unknown_created, unknown.metadata.id, origin.bytes(), unknown.metadata.source_url.bytes(), .woff2, first_valid_now));
    try std.testing.expectEqual(first_valid_now, unknown_created.catalog.find(unknown.metadata.id).?.last_access);
    const after_full_age = try expireAliases(&unknown_created, first_valid_now + age, age);
    try std.testing.expectEqual(@as(usize, 1), after_full_age.removed_aliases);
    try std.testing.expectEqual(@as(usize, 1), after_full_age.object_count);
}

test "replacing an alias follows the new object clock domain" {
    var origin = OriginKey{};
    try normalizeOrigin("https://page.example/", &origin);
    const source_url = "https://cdn.example/replaced.woff2";
    for ([_]u64{ 0, 400 }) |replacement_time| {
        var state = State{};
        const old = try cache.prepare("old bytes", source_url, "font/woff2", .woff2, 500, .{});
        _ = try state.recordPrepared(origin.bytes(), "https://cdn.example/old-final.woff2", &old);
        const replacement_bytes = if (replacement_time == 0) "new unknown-clock bytes" else "new corrected-clock bytes";
        const replacement = try cache.prepare(replacement_bytes, source_url, "font/woff2", .woff2, replacement_time, .{});
        _ = try state.recordPrepared(origin.bytes(), "https://cdn.example/new-final.woff2", &replacement);

        try std.testing.expect(state.validate());
        try std.testing.expectEqual(@as(usize, 1), state.catalog.count);
        try std.testing.expect(std.mem.eql(u8, &(state.findUrl(origin.bytes(), source_url, .woff2).?), &replacement.metadata.id));
        var matched = false;
        for (state.aliases[0..]) |alias| {
            if (!alias.occupied or !std.mem.eql(u8, alias.source_url.bytes(), source_url)) continue;
            try std.testing.expectEqual(replacement.metadata.last_access, alias.last_access);
            matched = true;
        }
        try std.testing.expect(matched);
    }
}

test "new concrete format replaces lookupAny representation without disturbing other keys" {
    const source_url = "https://cdn.example/switching-font";
    var origin_a = OriginKey{};
    var origin_b = OriginKey{};
    try normalizeOrigin("https://page-a.example/", &origin_a);
    try normalizeOrigin("https://page-b.example/", &origin_b);
    const old = try cache.prepare("old woff bytes", source_url, "font/woff", .woff, 10, .{});
    const replacement = try cache.prepare("new woff2 bytes", source_url, "font/woff2", .woff2, 20, .{});

    var solitary = State{};
    _ = try solitary.recordPrepared(origin_a.bytes(), "https://cdn.example/old.woff", &old);
    _ = try solitary.recordPrepared(origin_a.bytes(), "https://cdn.example/new.woff2", &replacement);
    try std.testing.expect(solitary.validate());
    try std.testing.expectEqual(@as(usize, 1), solitary.alias_count);
    try std.testing.expectEqual(@as(usize, 1), solitary.catalog.count);
    try std.testing.expect(solitary.findUrl(origin_a.bytes(), source_url, .woff) == null);
    const current = (try selectAlias(&solitary, origin_a.bytes(), source_url, null)).?;
    try std.testing.expectEqual(cache.FontFormat.woff2, current.format);
    try std.testing.expect(std.mem.eql(u8, &current.id, &replacement.metadata.id));

    var shared = State{};
    const other_url_font = try cache.prepare("unrelated bytes", "https://cdn.example/other-font", "font/woff", .woff, 11, .{});
    _ = try shared.recordPrepared(origin_a.bytes(), "https://cdn.example/old.woff", &old);
    _ = try shared.recordPrepared(origin_b.bytes(), "https://cdn.example/old.woff", &old);
    _ = try shared.recordPrepared(origin_a.bytes(), "https://cdn.example/other.woff", &other_url_font);
    _ = try shared.recordPrepared(origin_a.bytes(), "https://cdn.example/new.woff2", &replacement);
    try std.testing.expect(shared.validate());
    try std.testing.expectEqual(@as(usize, 3), shared.alias_count);
    try std.testing.expectEqual(@as(usize, 3), shared.catalog.count);
    try std.testing.expect(shared.findUrl(origin_a.bytes(), source_url, .woff) == null);
    try std.testing.expect(std.mem.eql(u8, &(shared.findUrl(origin_a.bytes(), source_url, .woff2).?), &replacement.metadata.id));
    try std.testing.expect(std.mem.eql(u8, &(shared.findUrl(origin_b.bytes(), source_url, .woff).?), &old.metadata.id));
    try std.testing.expect(std.mem.eql(u8, &(shared.findUrl(origin_a.bytes(), other_url_font.metadata.source_url.bytes(), .woff).?), &other_url_font.metadata.id));
}

test "persisted SFNT aliases accept reciprocal truetype and opentype hints" {
    var origin = OriginKey{};
    try normalizeOrigin("https://page.example/", &origin);
    var state = State{};
    const ttf = try cache.prepare("\x00\x01\x00\x00ttf", "https://cdn.example/font-a", "font/ttf", .truetype, 1, .{});
    const otf = try cache.prepare("OTTOotf", "https://cdn.example/font-b", "font/otf", .opentype, 2, .{});
    _ = try state.recordPrepared(origin.bytes(), "https://cdn.example/final-a", &ttf);
    _ = try state.recordPrepared(origin.bytes(), "https://cdn.example/final-b", &otf);
    const buffer = try std.testing.allocator.alloc(u8, max_catalog_bytes);
    defer std.testing.allocator.free(buffer);
    const decoded = try decodeState(try encodeState(&state, buffer), .{});
    const ttf_from_opentype = (try decoded.findUrlHint(origin.bytes(), ttf.metadata.source_url.bytes(), .opentype)).?;
    const otf_from_truetype = (try decoded.findUrlHint(origin.bytes(), otf.metadata.source_url.bytes(), .truetype)).?;
    try std.testing.expect(std.mem.eql(u8, &ttf_from_opentype, &ttf.metadata.id));
    try std.testing.expect(std.mem.eql(u8, &otf_from_truetype, &otf.metadata.id));
}

test "maximum valid catalog state fits mechanically derived bound" {
    const state = try std.testing.allocator.create(State);
    defer std.testing.allocator.destroy(state);
    state.* = .{};

    var origin_text: [8 + r4os.web_security.max_origin_host_bytes + 6]u8 = undefined;
    var origin_len: usize = 0;
    @memcpy(origin_text[origin_len .. origin_len + 8], "https://");
    origin_len += 8;
    var host_index: usize = 0;
    while (host_index < r4os.web_security.max_origin_host_bytes) : (host_index += 1) {
        origin_text[origin_len] = if (host_index == 63 or host_index == 127 or host_index == 191) '.' else 'a';
        origin_len += 1;
    }
    @memcpy(origin_text[origin_len .. origin_len + 6], ":65535");
    origin_len += 6;
    var origin = OriginKey{};
    try normalizeOrigin(origin_text[0..origin_len], &origin);

    var mime: [cache.max_mime_bytes]u8 = undefined;
    @memcpy(mime[0..5], "font/");
    @memset(mime[5..], 'a');
    var entry_index: usize = 0;
    while (entry_index < cache.max_entries) : (entry_index += 1) {
        var source_a: [cache.max_source_url_bytes]u8 = undefined;
        var source_b: [cache.max_source_url_bytes]u8 = undefined;
        var final_a: [cache.max_source_url_bytes]u8 = undefined;
        var final_b: [cache.max_source_url_bytes]u8 = undefined;
        fillMaxTestUrl(&source_a, 'a', @intCast(entry_index * 2));
        fillMaxTestUrl(&source_b, 'b', @intCast(entry_index * 2 + 1));
        fillMaxTestUrl(&final_a, 'c', @intCast(entry_index * 2));
        fillMaxTestUrl(&final_b, 'd', @intCast(entry_index * 2 + 1));
        const payload = [_]u8{ @intCast(entry_index), @intCast(entry_index ^ 0xa5) };
        const prepared = try cache.prepare(
            &payload,
            &source_a,
            &mime,
            .embedded_opentype,
            @intCast(entry_index + 1),
            .{},
        );
        _ = try state.catalog.recordCommitted(&prepared);
        try state.putAlias(origin.bytes(), &source_a, &final_a, .embedded_opentype, prepared.metadata.id, @intCast(entry_index + 1));
        try state.putAlias(origin.bytes(), &source_b, &final_b, .embedded_opentype, prepared.metadata.id, @intCast(entry_index + 1));
    }
    try std.testing.expectEqual(cache.max_entries, state.catalog.count);
    try std.testing.expectEqual(max_aliases, state.alias_count);
    try std.testing.expect(state.validate());
    const output = try std.testing.allocator.alloc(u8, max_catalog_bytes);
    defer std.testing.allocator.free(output);
    const encoded = try encodeState(state, output);
    try std.testing.expect(encoded.len <= max_catalog_bytes);
    const decoded = try decodeState(encoded, .{});
    try std.testing.expect(decoded.validate());
    try std.testing.expectEqual(cache.max_entries, decoded.catalog.count);
    try std.testing.expectEqual(max_aliases, decoded.alias_count);
}

fn fillMaxTestUrl(output: *[cache.max_source_url_bytes]u8, fill: u8, suffix: u32) void {
    const prefix = "https://fonts.example/";
    @memcpy(output[0..prefix.len], prefix);
    @memset(output[prefix.len..], fill);
    _ = std.fmt.bufPrint(output[output.len - 8 ..], "{x:0>8}", .{suffix}) catch unreachable;
}

test "persistent store and guest selftest paths typecheck without host IO" {
    var execute = false;
    const runtime_flag: *volatile bool = &execute;
    if (runtime_flag.*) {
        const files: r4os.Files = undefined;
        const result = try selfTest(std.testing.allocator, files, 1);
        try std.testing.expect(result.ok());
    }
}
