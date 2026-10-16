const std = @import("std");
const s = @import("shared.zig");
const dyn = @import("dynamic.zig");
const area = @import("area.zig");

/// Read-only graph over an already-decompressed `.zl` file. Sections are read
/// in place — no per-node parsing, no copy — so the browser holds one buffer
/// plus the adjacency index. The CLI uses it too, which is why loading a
/// 145 MB graph costs a map of the file rather than a few hundred MB of lists.
pub const PackedGraph = struct {
    /// Marks the half edge that traverses its segment backwards.
    pub const REVERSE: u32 = 1 << 31;
    /// Roughly the work a single `indexStep` call performs.
    pub const STEP_BUDGET: u32 = 1 << 18;

    pub const Phase = enum { count, prefix, fill, done };

    allocator: std.mem.Allocator,
    bytes: []const u8,
    node_count: u32,
    edge_count: u32,

    ids: []const i64,
    lats: []const f32,
    lons: []const f32,
    elevs: []const u16,
    edges_u: []const u32,
    edges_v: []const u32,
    edges_gain: []const u16,
    edges_loss: []const u16,
    edges_dist: []const u32,

    offsets: []u32 = &.{},
    half: []u32 = &.{},
    fill_cursor: []u32 = &.{},

    phase: Phase = .count,
    cursor: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, bytes: []const u8) !PackedGraph {
        if (bytes.len < @sizeOf(s.FileHeader)) return error.InvalidFileFormat;
        // Sections are read as typed slices, so the buffer must be aligned.
        if (@intFromPtr(bytes.ptr) % @alignOf(i64) != 0) return error.UnalignedBuffer;

        const header: *const s.FileHeader = @alignCast(@ptrCast(bytes.ptr));
        if (!std.mem.eql(u8, &header.magic, &s.FileHeader.MAGIC)) return error.InvalidFileFormat;
        if (!s.validVersion(header.version)) return error.UnsupportedVersion;
        if (header.node_count > std.math.maxInt(u32) or header.edge_count > std.math.maxInt(u32)) return error.InvalidFileFormat;

        const n: u32 = @intCast(header.node_count);
        const e: u32 = @intCast(header.edge_count);
        const layout = s.Sections.init(n, e);
        if (bytes.len != layout.total) return error.SizeMismatch;

        return .{
            .allocator = allocator,
            .bytes = bytes,
            .node_count = n,
            .edge_count = e,
            .ids = section(i64, bytes, layout.ids, n),
            .lats = section(f32, bytes, layout.lats, n),
            .lons = section(f32, bytes, layout.lons, n),
            .elevs = section(u16, bytes, layout.elevs, n),
            .edges_u = section(u32, bytes, layout.edges_u, e),
            .edges_v = section(u32, bytes, layout.edges_v, e),
            .edges_gain = section(u16, bytes, layout.edges_gain, e),
            .edges_loss = section(u16, bytes, layout.edges_loss, e),
            .edges_dist = section(u32, bytes, layout.edges_dist, e),
        };
    }

    fn section(comptime T: type, bytes: []const u8, offset: u64, count: u64) []const T {
        if (count == 0) return &.{};
        const base = @as(usize, @intCast(offset));
        const len = @as(usize, @intCast(count));
        const ptr: [*]const T = @alignCast(@ptrCast(bytes.ptr + base));
        return ptr[0..len];
    }

    pub fn deinit(self: *PackedGraph) void {
        if (self.offsets.len != 0) self.allocator.free(self.offsets);
        if (self.half.len != 0) self.allocator.free(self.half);
        if (self.fill_cursor.len != 0) self.allocator.free(self.fill_cursor);
        self.* = undefined;
    }

    /// Builds the adjacency index in `budget`-sized chunks. Returns true while
    /// there is work left, so a browser can keep the frame alive between steps.
    pub fn indexStep(self: *PackedGraph, budget: u32) !bool {
        switch (self.phase) {
            .count => {
                if (self.offsets.len == 0) {
                    self.offsets = try self.allocator.alloc(u32, self.node_count + 1);
                    @memset(self.offsets, 0);
                }
                const end = @min(self.edge_count, self.cursor + budget);
                while (self.cursor < end) : (self.cursor += 1) {
                    self.offsets[self.edges_u[self.cursor] + 1] += 1;
                    self.offsets[self.edges_v[self.cursor] + 1] += 1;
                }
                if (self.cursor == self.edge_count) {
                    self.phase = .prefix;
                    self.cursor = 0;
                }
            },
            .prefix => {
                const end = @min(self.node_count, self.cursor + budget);
                while (self.cursor < end) : (self.cursor += 1) {
                    self.offsets[self.cursor + 1] += self.offsets[self.cursor];
                }
                if (self.cursor == self.node_count) {
                    self.phase = .fill;
                    self.cursor = 0;
                    self.half = try self.allocator.alloc(u32, self.offsets[self.node_count]);
                    self.fill_cursor = try self.allocator.alloc(u32, self.node_count + 1);
                    @memcpy(self.fill_cursor, self.offsets);
                }
            },
            .fill => {
                const end = @min(self.edge_count, self.cursor + budget);
                while (self.cursor < end) : (self.cursor += 1) {
                    const i = self.cursor;
                    self.half[self.fill_cursor[self.edges_u[i]]] = i;
                    self.fill_cursor[self.edges_u[i]] += 1;
                    self.half[self.fill_cursor[self.edges_v[i]]] = i | REVERSE;
                    self.fill_cursor[self.edges_v[i]] += 1;
                }
                if (self.cursor == self.edge_count) {
                    self.phase = .done;
                    self.allocator.free(self.fill_cursor);
                    self.fill_cursor = &.{};
                }
            },
            .done => return false,
        }
        return self.phase != .done;
    }

    /// Convenience for callers that do not need to interleave work.
    pub fn index(self: *PackedGraph) !void {
        while (try self.indexStep(STEP_BUDGET)) {}
    }

    /// Fraction of the index build that is finished, 0..1, for progress display.
    pub fn indexProgress(self: *const PackedGraph) f64 {
        const total = @as(f64, @floatFromInt(self.edge_count * 2 + self.node_count + 1));
        const done: f64 = switch (self.phase) {
            .count => @floatFromInt(self.cursor),
            .prefix => @floatFromInt(self.edge_count + self.cursor),
            .fill => @floatFromInt(self.edge_count + self.node_count + 1 + self.cursor),
            .done => total,
        };
        return if (total == 0) 1 else done / total;
    }

    pub inline fn nodeCount(self: *const PackedGraph) u32 {
        return self.node_count;
    }

    pub inline fn edgeCount(self: *const PackedGraph) u32 {
        return self.edge_count;
    }

    pub inline fn nodeId(self: *const PackedGraph, idx: u32) i64 {
        return self.ids[idx];
    }

    pub inline fn nodeLat(self: *const PackedGraph, idx: u32) f32 {
        return self.lats[idx];
    }

    pub inline fn nodeLon(self: *const PackedGraph, idx: u32) f32 {
        return self.lons[idx];
    }

    pub inline fn nodeElev(self: *const PackedGraph, idx: u32) ?u16 {
        const e = self.elevs[idx];
        return if (e == s.INVALID_ELEV) null else e;
    }

    pub inline fn outDegree(self: *const PackedGraph, idx: u32) u32 {
        return self.offsets[idx + 1] - self.offsets[idx];
    }

    pub inline fn halfEdge(self: *const PackedGraph, idx: u32, k: u32) s.HalfEdge {
        const raw = self.half[self.offsets[idx] + k];
        if (raw & REVERSE != 0) {
            const i = raw & ~REVERSE;
            return .{
                .to = self.edges_u[i],
                .gain = self.edges_loss[i],
                .loss = self.edges_gain[i],
                .distance = self.edges_dist[i],
            };
        }
        return .{
            .to = self.edges_v[raw],
            .gain = self.edges_gain[raw],
            .loss = self.edges_loss[raw],
            .distance = self.edges_dist[raw],
        };
    }

    /// Spatial index over the node positions, for area queries.
    pub fn buildGrid(self: *const PackedGraph, allocator: std.mem.Allocator, cell_m: f64) !area.NodeGrid {
        return area.NodeGrid.buildSoA(allocator, self.lats, self.lons, cell_m);
    }

    /// Writes the path's node coordinates as lat, lon, elev triples. Returns
    /// the number of triples written, or the length needed if it does not fit.
    pub fn writePathPoints(self: *const PackedGraph, path: []const u32, out: []f32) u32 {
        const needed = path.len * 3;
        if (out.len < needed) return @intCast(needed);
        for (path, 0..) |node_idx, i| {
            out[i * 3] = self.lats[node_idx];
            out[i * 3 + 1] = self.lons[node_idx];
            out[i * 3 + 2] = @floatFromInt(self.nodeElev(node_idx) orelse 0);
        }
        return @intCast(needed);
    }
};

test "rejects mismatched files" {
    const bytes = try std.testing.allocator.alloc(u8, s.fileSize(4, 2));
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 0);

    try std.testing.expectError(error.InvalidFileFormat, PackedGraph.init(std.testing.allocator, bytes));

    const header: *s.FileHeader = @alignCast(@ptrCast(bytes.ptr));
    header.* = .{ .node_count = 4, .edge_count = 2 };
    var graph = try PackedGraph.init(std.testing.allocator, bytes);
    defer graph.deinit();
    try graph.index();
    try std.testing.expectEqual(@as(u32, 4), graph.nodeCount());
    try std.testing.expectEqual(@as(u32, 2), graph.edgeCount());

    // One byte short of the header's promise is a corrupt file, not a graph.
    try std.testing.expectError(error.SizeMismatch, PackedGraph.init(std.testing.allocator, bytes[0 .. bytes.len - 1]));
}

test "rejects an unsupported version" {
    const bytes = try std.testing.allocator.alloc(u8, s.fileSize(1, 1));
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 0);
    const header: *s.FileHeader = @alignCast(@ptrCast(bytes.ptr));
    header.* = .{ .node_count = 1, .edge_count = 1 };
    header.version = .{ 0, 0, 1, 0 };

    try std.testing.expectError(error.UnsupportedVersion, PackedGraph.init(std.testing.allocator, bytes));
}

test "half edges carry both directions of a segment" {
    var g = dyn.DynamicGraph.init(std.testing.allocator);
    defer g.deinit();
    const a = try g.addNode(11, 46.0, 7.0, 900.0);
    const b = try g.addNode(22, 46.01, 7.01, 1000.0);
    try g.addEdge(a, b, 100, 20, 1400);

    const bytes = try std.testing.allocator.alloc(u8, s.fileSize(2, 1));
    defer std.testing.allocator.free(bytes);
    var writer = std.Io.Writer.fixed(bytes);
    try g.exportToWriter(&writer);

    var loaded = try PackedGraph.init(std.testing.allocator, bytes);
    defer loaded.deinit();
    try loaded.index();

    const up = loaded.halfEdge(a, 0);
    try std.testing.expectEqual(b, up.to);
    try std.testing.expectEqual(@as(u16, 100), up.gain);
    try std.testing.expectEqual(@as(u16, 20), up.loss);
    try std.testing.expectEqual(@as(u32, 1400), up.distance);

    const down = loaded.halfEdge(b, 0);
    try std.testing.expectEqual(a, down.to);
    try std.testing.expectEqual(@as(u16, 20), down.gain);
    try std.testing.expectEqual(@as(u16, 100), down.loss);
    try std.testing.expectEqual(@as(u32, 1400), down.distance);

    try std.testing.expectEqual(@as(u32, 1), loaded.outDegree(a));
    try std.testing.expectEqual(@as(u32, 1), loaded.outDegree(b));
}

test "incremental index matches the one-shot index" {
    var g = dyn.DynamicGraph.init(std.testing.allocator);
    defer g.deinit();
    const a = try g.addNode(1, 46.0, 7.0, 100.0);
    const b = try g.addNode(2, 46.1, 7.1, 200.0);
    const c = try g.addNode(3, 46.2, 7.2, 300.0);
    try g.addEdge(a, b, 100, 0, 1000);
    try g.addEdge(b, c, 100, 0, 1000);
    try g.addEdge(a, c, 200, 0, 2100);

    const bytes = try std.testing.allocator.alloc(u8, s.fileSize(3, 3));
    defer std.testing.allocator.free(bytes);
    var writer = std.Io.Writer.fixed(bytes);
    try g.exportToWriter(&writer);

    var stepped = try PackedGraph.init(std.testing.allocator, bytes);
    defer stepped.deinit();
    var steps: usize = 0;
    while (try stepped.indexStep(1)) steps += 1;
    try std.testing.expect(steps >= 3);

    var oneshot = try PackedGraph.init(std.testing.allocator, bytes);
    defer oneshot.deinit();
    try oneshot.index();

    for (0..3) |i| {
        const idx: u32 = @intCast(i);
        try std.testing.expectEqual(oneshot.outDegree(idx), stepped.outDegree(idx));
        for (0..oneshot.outDegree(idx)) |k| {
            const kk: u32 = @intCast(k);
            try std.testing.expectEqual(oneshot.halfEdge(idx, kk).to, stepped.halfEdge(idx, kk).to);
            try std.testing.expectEqual(oneshot.halfEdge(idx, kk).distance, stepped.halfEdge(idx, kk).distance);
        }
    }
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), oneshot.indexProgress(), 1e-12);
}
