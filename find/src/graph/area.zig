const std = @import("std");
const s = @import("shared.zig");
const solve = @import("solve.zig");

pub const Coord = solve.Coord;

/// Concave-capable polygon over node coordinates, in raw lon/lat degrees.
/// Web-Mercator and lon/lat are monotone in lat and lon, so containment in
/// degrees is containment on the map; no projection is needed.
pub const Polygon = struct {
    points: []const Coord,
    min_lat: f32,
    max_lat: f32,
    min_lon: f32,
    max_lon: f32,

    pub const Bbox = struct {
        min_lat: f32,
        max_lat: f32,
        min_lon: f32,
        max_lon: f32,
    };

    pub fn init(points: []const Coord) Polygon {
        var lo_lat: f64 = 0;
        var hi_lat: f64 = 0;
        var lo_lon: f64 = 0;
        var hi_lon: f64 = 0;
        if (points.len > 0) {
            lo_lat = points[0].lat;
            hi_lat = lo_lat;
            lo_lon = points[0].lon;
            hi_lon = lo_lon;
            for (points[1..]) |p| {
                lo_lat = @min(lo_lat, p.lat);
                hi_lat = @max(hi_lat, p.lat);
                lo_lon = @min(lo_lon, p.lon);
                hi_lon = @max(hi_lon, p.lon);
            }
        }
        return .{
            .points = points,
            .min_lat = @floatCast(lo_lat),
            .max_lat = @floatCast(hi_lat),
            .min_lon = @floatCast(lo_lon),
            .max_lon = @floatCast(hi_lon),
        };
    }

    pub fn bbox(self: Polygon) Bbox {
        return .{
            .min_lat = self.min_lat,
            .max_lat = self.max_lat,
            .min_lon = self.min_lon,
            .max_lon = self.max_lon,
        };
    }

    pub fn contains(self: Polygon, c: Coord) bool {
        if (self.points.len < 3) return false;
        // Bbox check in f32: query and bbox round the same way, so a point
        // sitting exactly on a vertex is not rejected by rounding.
        const lat: f32 = @floatCast(c.lat);
        const lon: f32 = @floatCast(c.lon);
        if (lat < self.min_lat or lat > self.max_lat or
            lon < self.min_lon or lon > self.max_lon) return false;

        var inside = false;
        var j = self.points.len - 1;
        for (self.points, 0..) |a, i| {
            const b = self.points[j];
            if ((a.lat > c.lat) != (b.lat > c.lat)) {
                const t = (c.lat - a.lat) / (b.lat - a.lat);
                if (c.lon < a.lon + t * (b.lon - a.lon)) inside = !inside;
            }
            j = i;
        }
        return inside;
    }

    /// Shoelace area in m² via a local equirectangular frame centred on the bbox.
    pub fn areaM2(self: Polygon) f64 {
        if (self.points.len < 3) return 0;
        const lat0: f64 = (@as(f64, self.min_lat) + @as(f64, self.max_lat)) / 2;
        const k_lon = 111_320.0 * @cos(std.math.degreesToRadians(lat0));
        const k_lat = 110_540.0;
        var acc: f64 = 0;
        var j = self.points.len - 1;
        for (self.points, 0..) |a, i| {
            const b = self.points[j];
            acc += (a.lon * k_lon) * (b.lat * k_lat) - (b.lon * k_lon) * (a.lat * k_lat);
            j = i;
        }
        return @abs(acc) / 2;
    }

    pub fn perimeterM(self: Polygon) f64 {
        if (self.points.len < 2) return 0;
        var total: f64 = 0;
        var j = self.points.len - 1;
        for (self.points, 0..) |a, i| {
            total += solve.haversineMeters(a, self.points[j]);
            j = i;
        }
        return total;
    }
};

/// Uniform spatial grid (CSR over cells) so a polygon query only visits the
/// cells the polygon covers. Node positions are borrowed from the caller and
/// must outlive the grid.
pub const NodeGrid = struct {
    cell_offsets: []u32, // len = cols*rows + 1
    node_indices: []u32, // nodes of cell c are node_indices[cell_offsets[c]..cell_offsets[c+1]]

    // Positions: either an AoS byte view of the caller's node slice, or two
    // parallel SoA slices. Empty `lats` means the AoS view.
    nodes: []const u8,
    elem_size: usize,
    lat_off: usize,
    lon_off: usize,
    lats: []const f32,
    lons: []const f32,

    origin_lat: f32,
    origin_lon: f32,
    cell_deg_lat: f64,
    cell_deg_lon: f64,
    cols: u32,
    rows: u32,

    pub fn defaultCellMeters() f64 {
        return 512;
    }

    /// In-memory AoS constructor: `nodes` is any slice or array of structs
    /// carrying `.lat`/`.lon` (e.g. `shared.Node`); only those are read.
    pub fn build(allocator: std.mem.Allocator, nodes: anytype, cell_m: f64) !NodeGrid {
        const T = NodeType(@TypeOf(nodes));
        var grid = NodeGrid.empty();
        grid.nodes = std.mem.sliceAsBytes(nodes);
        grid.elem_size = @sizeOf(T);
        grid.lat_off = @offsetOf(T, "lat");
        grid.lon_off = @offsetOf(T, "lon");
        try grid.buildFrom(allocator, nodes.len, cell_m);
        return grid;
    }

    /// Zero-copy SoA constructor: positions come from two parallel slices.
    pub fn buildSoA(
        allocator: std.mem.Allocator,
        lats: []const f32,
        lons: []const f32,
        cell_m: f64,
    ) !NodeGrid {
        if (lats.len != lons.len) return error.LengthMismatch;
        var grid = NodeGrid.empty();
        grid.lats = lats;
        grid.lons = lons;
        try grid.buildFrom(allocator, lats.len, cell_m);
        return grid;
    }

    pub fn deinit(self: NodeGrid, allocator: std.mem.Allocator) void {
        if (self.cell_offsets.len > 0) allocator.free(self.cell_offsets);
        if (self.node_indices.len > 0) allocator.free(self.node_indices);
    }

    pub fn count(self: NodeGrid, poly: Polygon) usize {
        if (self.rows == 0 or poly.points.len < 3) return 0;
        const rect = self.cellRect(poly);
        var total: usize = 0;
        var r = rect.r0;
        while (r <= rect.r1) : (r += 1) {
            var c = rect.c0;
            while (c <= rect.c1) : (c += 1) {
                const cell = r * self.cols + c;
                const slice = self.node_indices[self.cell_offsets[cell]..self.cell_offsets[cell + 1]];
                for (slice) |i| {
                    if (poly.contains(self.nodeCoord(i))) total += 1;
                }
            }
        }
        return total;
    }

    /// Node indices inside `poly`; caller frees. Order is deterministic
    /// (cell row-major, node order within a cell).
    pub fn query(self: NodeGrid, allocator: std.mem.Allocator, poly: Polygon) ![]u32 {
        var out = std.ArrayList(u32).empty;
        errdefer out.deinit(allocator);
        if (self.rows == 0 or poly.points.len < 3) return try out.toOwnedSlice(allocator);
        const rect = self.cellRect(poly);
        var r = rect.r0;
        while (r <= rect.r1) : (r += 1) {
            var c = rect.c0;
            while (c <= rect.c1) : (c += 1) {
                const cell = r * self.cols + c;
                const slice = self.node_indices[self.cell_offsets[cell]..self.cell_offsets[cell + 1]];
                for (slice) |i| {
                    if (poly.contains(self.nodeCoord(i))) try out.append(allocator, i);
                }
            }
        }
        return try out.toOwnedSlice(allocator);
    }

    fn empty() NodeGrid {
        return .{
            .cell_offsets = &.{},
            .node_indices = &.{},
            .nodes = &.{},
            .elem_size = 0,
            .lat_off = 0,
            .lon_off = 0,
            .lats = &.{},
            .lons = &.{},
            .origin_lat = 0,
            .origin_lon = 0,
            .cell_deg_lat = 1,
            .cell_deg_lon = 1,
            .cols = 0,
            .rows = 0,
        };
    }

    /// Count, prefix sum and fill, shared by both constructors. `n` is the
    /// number of nodes already reachable through the position accessors.
    fn buildFrom(self: *NodeGrid, allocator: std.mem.Allocator, n: usize, cell_m: f64) !void {
        if (n == 0) return;

        var min_lat: f32 = self.latOf(0);
        var max_lat: f32 = min_lat;
        var min_lon: f32 = self.lonOf(0);
        var max_lon: f32 = min_lon;
        for (0..n) |i| {
            const lat = self.latOf(i);
            const lon = self.lonOf(i);
            min_lat = @min(min_lat, lat);
            max_lat = @max(max_lat, lat);
            min_lon = @min(min_lon, lon);
            max_lon = @max(max_lon, lon);
        }

        const lat0: f64 = (@as(f64, min_lat) + @as(f64, max_lat)) / 2;
        const cell_deg_lat = cell_m / 110_540.0;
        const cell_deg_lon = cell_m / (111_320.0 * @cos(std.math.degreesToRadians(lat0)));
        const cols = cellsFor(@as(f64, max_lon) - @as(f64, min_lon), cell_deg_lon);
        const rows = cellsFor(@as(f64, max_lat) - @as(f64, min_lat), cell_deg_lat);
        const cells: usize = @as(usize, cols) * rows;

        self.origin_lat = min_lat;
        self.origin_lon = min_lon;
        self.cell_deg_lat = cell_deg_lat;
        self.cell_deg_lon = cell_deg_lon;
        self.cols = cols;
        self.rows = rows;

        self.cell_offsets = try allocator.alloc(u32, cells + 1);
        errdefer allocator.free(self.cell_offsets);
        self.node_indices = try allocator.alloc(u32, n);
        errdefer allocator.free(self.node_indices);

        @memset(self.cell_offsets, 0);
        for (0..n) |i| self.cell_offsets[self.cellIndex(self.latOf(i), self.lonOf(i)) + 1] += 1;
        // Exclusive prefix sum: cell c owns cell_offsets[c]..cell_offsets[c+1].
        for (1..cells + 1) |i| self.cell_offsets[i] += self.cell_offsets[i - 1];
        const cursor = try allocator.dupe(u32, self.cell_offsets[0..cells]);
        defer allocator.free(cursor);
        for (0..n) |i| {
            const c = self.cellIndex(self.latOf(i), self.lonOf(i));
            self.node_indices[cursor[c]] = @intCast(i);
            cursor[c] += 1;
        }
    }

    fn latOf(self: NodeGrid, i: usize) f32 {
        if (self.lats.len > 0) return self.lats[i];
        return loadF32(self.nodes[i * self.elem_size ..], self.lat_off);
    }

    fn lonOf(self: NodeGrid, i: usize) f32 {
        if (self.lats.len > 0) return self.lons[i];
        return loadF32(self.nodes[i * self.elem_size ..], self.lon_off);
    }

    fn nodeCoord(self: NodeGrid, i: u32) Coord {
        return .{ .lat = self.latOf(i), .lon = self.lonOf(i) };
    }

    const Rect = struct { r0: u32, c0: u32, r1: u32, c1: u32 };

    // shortcut: a polygon bbox entirely off the grid clamps to every cell, i.e. the
    // whole grid is scanned; add an overlap guard if the UI can drag off the map.
    fn cellRect(self: NodeGrid, poly: Polygon) Rect {
        const b = poly.bbox();
        return .{
            .r0 = clampIndex((@as(f64, b.min_lat) - self.origin_lat) / self.cell_deg_lat, self.rows),
            .r1 = clampIndex((@as(f64, b.max_lat) - self.origin_lat) / self.cell_deg_lat, self.rows),
            .c0 = clampIndex((@as(f64, b.min_lon) - self.origin_lon) / self.cell_deg_lon, self.cols),
            .c1 = clampIndex((@as(f64, b.max_lon) - self.origin_lon) / self.cell_deg_lon, self.cols),
        };
    }

    /// Clamped so nodes on the bbox edge land in the last cell instead of one past it.
    fn cellIndex(self: NodeGrid, lat: f32, lon: f32) u32 {
        const r = clampIndex((@as(f64, lat) - self.origin_lat) / self.cell_deg_lat, self.rows);
        const c = clampIndex((@as(f64, lon) - self.origin_lon) / self.cell_deg_lon, self.cols);
        return r * self.cols + c;
    }
};

/// Element type of a slice, array, or pointer-to-array of nodes.
fn NodeType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |p| NodeType(p.child),
        .array => |a| NodeType(a.child),
        else => T,
    };
}

fn cellsFor(span: f64, cell_deg: f64) u32 {
    if (!(span > 0) or !(cell_deg > 0)) return 1;
    const n = @floor(span / cell_deg) + 1;
    if (!(n > 1)) return 1;
    return @intFromFloat(@min(n, 1e9));
}

fn clampIndex(v: f64, n: u32) u32 {
    if (!(v > 0)) return 0; // also rejects NaN
    if (v >= @as(f64, @floatFromInt(n))) return n - 1;
    return @intFromFloat(v);
}

fn loadF32(bytes: []const u8, off: usize) f32 {
    return @as(*align(1) const f32, @ptrCast(bytes[off..][0..4])).*;
}

// ============================= tests =============================

/// L-shaped concave polygon: a tall bar on the west, a short bar on the south-east.
const l_shape = [_]Coord{
    .{ .lat = 45.99, .lon = 6.99 },
    .{ .lat = 46.01, .lon = 6.99 },
    .{ .lat = 46.01, .lon = 7.00 },
    .{ .lat = 46.00, .lon = 7.00 },
    .{ .lat = 46.00, .lon = 7.01 },
    .{ .lat = 45.99, .lon = 7.01 },
};

fn testNodes(allocator: std.mem.Allocator, n: usize, seed: u64) ![]s.Node {
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    const nodes = try allocator.alloc(s.Node, n);
    for (nodes, 0..) |*node, i| {
        node.* = .{
            .id = @intCast(i),
            .lat = 45.99 + rand.float(f32) * 0.03,
            .lon = 6.99 + rand.float(f32) * 0.03,
            .elev = null,
        };
    }
    return nodes;
}

test "area concave contains" {
    const poly = Polygon.init(&l_shape);
    try std.testing.expect(poly.contains(.{ .lat = 46.005, .lon = 6.995 })); // west bar
    try std.testing.expect(poly.contains(.{ .lat = 45.995, .lon = 7.005 })); // south bar
    try std.testing.expect(!poly.contains(.{ .lat = 46.005, .lon = 7.005 })); // notch
    try std.testing.expect(!poly.contains(.{ .lat = 46.02, .lon = 7.00 })); // north of bbox
    try std.testing.expect(!poly.contains(.{ .lat = 45.98, .lon = 7.00 })); // south of bbox
    try std.testing.expect(!poly.contains(.{ .lat = 46.00, .lon = 7.02 })); // east of bbox
    try std.testing.expect(!poly.contains(.{ .lat = 46.00, .lon = 6.98 })); // west of bbox
}

test "area degenerate and bbox" {
    try std.testing.expect(!Polygon.init(&.{}).contains(.{ .lat = 0, .lon = 0 }));
    const two = [_]Coord{ .{ .lat = 0, .lon = 0 }, .{ .lat = 1, .lon = 1 } };
    try std.testing.expect(!Polygon.init(&two).contains(.{ .lat = 0.5, .lon = 0.5 }));
    const b = Polygon.init(&l_shape).bbox();
    try std.testing.expectEqual(@as(f32, 45.99), b.min_lat);
    try std.testing.expectEqual(@as(f32, 46.01), b.max_lat);
    try std.testing.expectEqual(@as(f32, 6.99), b.min_lon);
    try std.testing.expectEqual(@as(f32, 7.01), b.max_lon);
}

test "area count query brute force" {
    const allocator = std.testing.allocator;
    const nodes = try testNodes(allocator, 3000, 0x5eed);
    defer allocator.free(nodes);
    // One node exactly on the north-east corner of the node bbox, to exercise clamping.
    nodes[0] = .{ .id = 0, .lat = 46.02, .lon = 7.02, .elev = null };

    const poly = Polygon.init(&l_shape);
    var brute: usize = 0;
    for (nodes) |n| {
        if (poly.contains(.{ .lat = n.lat, .lon = n.lon })) brute += 1;
    }
    try std.testing.expect(brute > 100); // the fixture actually overlaps the polygon

    const grid = try NodeGrid.build(allocator, nodes, 100);
    defer grid.deinit(allocator);
    try std.testing.expectEqual(brute, grid.count(poly));

    const hits = try grid.query(allocator, poly);
    defer allocator.free(hits);
    try std.testing.expectEqual(brute, hits.len);
    for (hits, 0..) |idx, k| {
        const n = nodes[idx];
        try std.testing.expect(poly.contains(.{ .lat = n.lat, .lon = n.lon }));
        for (hits[0..k]) |prev| try std.testing.expect(prev != idx); // no duplicates
    }

    // Same positions in a different element layout: the byte view must read them identically.
    const OtherNode = packed struct { id: i64, lat: f32, lon: f32, elev: u16 };
    const other = try allocator.alloc(OtherNode, nodes.len);
    defer allocator.free(other);
    for (nodes, 0..) |n, i| {
        other[i] = .{ .id = n.id, .lat = n.lat, .lon = n.lon, .elev = s.INVALID_ELEV };
    }
    const other_grid = try NodeGrid.build(allocator, other, 100);
    defer other_grid.deinit(allocator);
    try std.testing.expectEqual(brute, other_grid.count(poly));

    // Empty input and non-overlapping polygon are harmless.
    const empty = try NodeGrid.build(allocator, nodes[0..0], 100);
    defer empty.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), empty.count(poly));

    const far = [_]Coord{
        .{ .lat = 40.0, .lon = 3.0 },
        .{ .lat = 40.1, .lon = 3.0 },
        .{ .lat = 40.0, .lon = 3.1 },
    };
    try std.testing.expectEqual(@as(usize, 0), grid.count(Polygon.init(&far)));
    const none = try grid.query(allocator, Polygon.init(&far));
    defer allocator.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);

    try std.testing.expectEqual(@as(f64, 512), NodeGrid.defaultCellMeters());
}

test "area soa grid matches aos" {
    const allocator = std.testing.allocator;
    const nodes = try testNodes(allocator, 3000, 0xabc);
    defer allocator.free(nodes);
    const lats = try allocator.alloc(f32, nodes.len);
    defer allocator.free(lats);
    const lons = try allocator.alloc(f32, nodes.len);
    defer allocator.free(lons);
    for (nodes, 0..) |n, i| {
        lats[i] = n.lat;
        lons[i] = n.lon;
    }

    const poly = Polygon.init(&l_shape);
    const aos = try NodeGrid.build(allocator, nodes, 100);
    defer aos.deinit(allocator);
    const soa = try NodeGrid.buildSoA(allocator, lats, lons, 100);
    defer soa.deinit(allocator);

    try std.testing.expect(aos.count(poly) > 100);
    try std.testing.expectEqual(aos.count(poly), soa.count(poly));
    const a = try aos.query(allocator, poly);
    defer allocator.free(a);
    const b = try soa.query(allocator, poly);
    defer allocator.free(b);
    try std.testing.expectEqualSlices(u32, a, b);

    const empty = try NodeGrid.buildSoA(allocator, &.{}, &.{}, 100);
    defer empty.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), empty.count(poly));

    // Mismatched slices are rejected instead of read out of bounds.
    try std.testing.expectError(
        error.LengthMismatch,
        NodeGrid.buildSoA(allocator, lats, lons[0 .. lons.len - 1], 100),
    );
}

test "area triangle area and perimeter" {
    const a = Coord{ .lat = 46.0, .lon = 7.0 };
    const b = Coord{ .lat = 46.0 + 1000.0 / 110_540.0, .lon = 7.0 };
    const c = Coord{ .lat = 46.0, .lon = 7.0 + 1000.0 / (111_320.0 * @cos(std.math.degreesToRadians(46.0))) };
    const poly = Polygon.init(&[_]Coord{ a, b, c });

    try std.testing.expectApproxEqRel(500_000.0, poly.areaM2(), 0.15);
    try std.testing.expectApproxEqRel(1000.0 * 2 + std.math.sqrt2 * 1000.0, poly.perimeterM(), 0.05);

    const empty = Polygon.init(&.{}).areaM2();
    try std.testing.expectEqual(@as(f64, 0), empty);
}
