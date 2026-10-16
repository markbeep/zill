//! WebAssembly entry points for the browser dashboard. The host downloads the
//! `.zl` file, decompresses it into memory reserved here, then drives the index
//! build and the search in bounded steps so the page keeps painting.

const std = @import("std");
const zill = @import("zill");
const zl = zill.packed_graph;
const area = zill.area;
const search = zill.search;
const solve = zill.solve;

const allocator = std.heap.wasm_allocator;
const Engine = search.Engine(zl.PackedGraph);

pub const ZI_OK: i32 = 0;
pub const ZI_ERR_STATE: i32 = -1;
pub const ZI_ERR_FORMAT: i32 = -2;
pub const ZI_ERR_VERSION: i32 = -3;
pub const ZI_ERR_SIZE: i32 = -4;
pub const ZI_ERR_ARGS: i32 = -5;
pub const ZI_ERR_ALLOC: i32 = -6;

/// Start nodes handled per `zi_search_step` call. Small enough to keep a frame
/// budget, large enough to make progress visible within a second.
pub const SEARCH_STEP: u32 = 256;

const Session = struct {
    /// Raw allocation backing `graph_bytes`; kept for `zi_reset`.
    raw: []u8 = &.{},
    /// The decompressed `.zl` file, aligned so the graph can read it in place.
    graph_bytes: []u8 = &.{},
    graph: ?zl.PackedGraph = null,
    grid: ?area.NodeGrid = null,
    starts: []u32 = &.{},
    /// Last `zi_area_begin` result, paged out by `zi_area_page`. Kept apart
    /// from `starts` so a search cannot evict the list being drawn.
    area_starts: []u32 = &.{},
    engine: ?Engine = null,

    fn clear(self: *Session) void {
        if (self.engine) |*engine| engine.deinit();
        self.engine = null;
        if (self.starts.len != 0) allocator.free(self.starts);
        self.starts = &.{};
        if (self.area_starts.len != 0) allocator.free(self.area_starts);
        self.area_starts = &.{};
        if (self.grid) |grid| grid.deinit(allocator);
        self.grid = null;
        if (self.graph) |*graph| graph.deinit();
        self.graph = null;
        if (self.raw.len != 0) allocator.free(self.raw);
        self.raw = &.{};
        self.graph_bytes = &.{};
    }
};

var session: Session = .{};

/// One host-visible buffer, allocated once. It carries polygon coordinates in
/// and search results out, so a dragging pointer never allocates. The dashboard
/// splits it into named regions (see `dashboard/src/worker.ts`).
const SCRATCH_BYTES: u32 = 1024 * 1024;
var scratch_raw: []u8 = &.{};
var scratch_ptr: [*]u8 = undefined;
var scratch_len: u32 = 0;

/// Reserves room for the decompressed graph file and returns its address for
/// the host to stream into, or 0 when the allocation fails.
export fn zi_reserve(len: u32) u32 {
    session.clear();
    const raw = allocator.alloc(u8, len + 8) catch return 0;
    session.raw = raw;
    const base = @intFromPtr(raw.ptr);
    const aligned = std.mem.alignForward(usize, base, 8);
    session.graph_bytes = raw[aligned - base ..][0..len];
    return @intCast(aligned);
}

/// Frees everything. The host calls this when it starts over or unloads.
export fn zi_reset() void {
    if (scratch_raw.len != 0) allocator.free(scratch_raw);
    scratch_raw = &.{};
    scratch_len = 0;
    session.clear();
}

/// Validates the reserved bytes as a `.zl` file and prepares the graph view.
export fn zi_load_graph() i32 {
    if (session.graph_bytes.len == 0) return ZI_ERR_STATE;
    const graph = zl.PackedGraph.init(allocator, session.graph_bytes) catch |err| return switch (err) {
        error.InvalidFileFormat => ZI_ERR_FORMAT,
        error.UnsupportedVersion => ZI_ERR_VERSION,
        error.SizeMismatch => ZI_ERR_SIZE,
        error.UnalignedBuffer => ZI_ERR_ARGS,
    };
    session.graph = graph;
    return ZI_OK;
}

/// Builds the adjacency index and then the spatial index in bounded slices.
/// Returns 1 while there is work left, 0 when the graph is searchable, <0 on error.
export fn zi_index_step(budget: u32) i32 {
    const graph = &(session.graph orelse return ZI_ERR_STATE);
    const more = graph.indexStep(budget) catch return ZI_ERR_ALLOC;
    if (!more) {
        if (session.grid == null) {
            session.grid = graph.buildGrid(allocator, area.NodeGrid.defaultCellMeters()) catch return ZI_ERR_ALLOC;
        }
        return 0;
    }
    return 1;
}

/// [node_count, edge_count, ready, index_progress_permille, bytes, cell_meters]
export fn zi_graph_info(out: [*]u32) void {
    const graph = session.graph orelse {
        @memset(out[0..6], 0);
        return;
    };
    out[0] = graph.nodeCount();
    out[1] = graph.edgeCount();
    out[2] = @intFromBool(session.grid != null);
    out[3] = @intFromFloat(graph.indexProgress() * 1000.0);
    out[4] = @intCast(session.graph_bytes.len);
    out[5] = @intFromFloat(area.NodeGrid.defaultCellMeters());
}

/// Address of the host scratch buffer: polygon coordinates go in, search stats,
/// route metadata and route points come out, so dragging never allocates.
export fn zi_scratch() u32 {
    if (scratch_len == 0) {
        const raw = allocator.alloc(u8, SCRATCH_BYTES + 8) catch return 0;
        scratch_raw = raw;
        const base = @intFromPtr(raw.ptr);
        const aligned = std.mem.alignForward(usize, base, 8);
        scratch_ptr = raw[aligned - base ..].ptr;
        scratch_len = SCRATCH_BYTES;
    }
    return @intCast(@intFromPtr(scratch_ptr));
}

/// Size of the buffer `zi_scratch` returns: the host writes polygon
/// coordinates, search stats, route metadata and route points through it.
export fn zi_scratch_len() u32 {
    return scratch_len;
}

fn polygon(pts: [*]const f64, n: u32) ?area.Polygon {
    if (n < 3 or n > 1 << 16) return null;
    if (@intFromPtr(pts) % @alignOf(f64) != 0) return null;
    const coords: []const solve.Coord = @as([*]const solve.Coord, @ptrCast(@alignCast(pts)))[0..n];
    for (coords) |c| {
        if (!std.math.isFinite(c.lat) or !std.math.isFinite(c.lon)) return null;
        if (c.lat < -90 or c.lat > 90 or c.lon < -180 or c.lon > 180) return null;
    }
    return area.Polygon.init(coords);
}

/// Number of graph nodes inside the polygon — the "search cost" the visitor
/// watches while dragging a vertex.
export fn zi_area_count(pts: [*]const f64, n: u32) u32 {
    const grid = &(session.grid orelse return 0);
    const poly = polygon(pts, n) orelse return 0;
    return @intCast(grid.count(poly));
}

/// Runs the grid query once and stores the node indices in the session so the
/// dashboard can page them out later; returns how many are inside. Each call
/// replaces the stored list, so the polygon is freed as soon as it is drawn.
export fn zi_area_begin(pts: [*]const f64, n: u32) u32 {
    const grid = &(session.grid orelse return 0);
    const poly = polygon(pts, n) orelse return 0;
    const nodes = grid.query(allocator, poly) catch return 0;
    if (session.area_starts.len != 0) allocator.free(session.area_starts);
    session.area_starts = nodes;
    return @intCast(nodes.len);
}

/// Writes up to `cap` (lat, lon) f32 pairs from the list `zi_area_begin` stored,
/// starting at `offset`; returns how many pairs were written.
export fn zi_area_page(offset: u32, out: [*]f32, cap: u32) u32 {
    const graph = session.graph orelse return 0;
    if (offset >= session.area_starts.len) return 0;
    const count = @min(session.area_starts.len - offset, cap);
    for (session.area_starts[offset..][0..count], 0..) |idx, i| {
        out[i * 2] = graph.nodeLat(idx);
        out[i * 2 + 1] = graph.nodeLon(idx);
    }
    return @intCast(count);
}

/// Starts a search over the polygon. `max_elevation_m` is only used when
/// `max_distance_m` is 0, matching the CLI's two modes. `dedup_permille` is the
/// overlap ratio above which two routes count as the same climb (1000 disables).
export fn zi_search_start(
    pts: [*]const f64,
    n: u32,
    max_distance_m: u32,
    max_elevation_m: u32,
    max_results: u32,
    dedup_permille: u32,
) i32 {
    const graph = session.graph orelse return ZI_ERR_STATE;
    if (session.grid == null) return ZI_ERR_STATE;
    const poly = polygon(pts, n) orelse return ZI_ERR_ARGS;

    if (session.engine) |*engine| engine.deinit();
    session.engine = null;
    if (session.starts.len != 0) allocator.free(session.starts);
    session.starts = &.{};

    const end_condition: solve.EndCondition = if (max_distance_m > 0)
        .{ .max_distance = max_distance_m }
    else if (max_elevation_m > 0)
        .{ .at_least_elevation = max_elevation_m }
    else
        return ZI_ERR_ARGS;

    const starts = session.grid.?.query(allocator, poly) catch return ZI_ERR_ALLOC;
    if (starts.len == 0) {
        allocator.free(starts);
        return ZI_ERR_ARGS;
    }
    session.starts = starts;

    session.engine = Engine.init(
        allocator,
        graph,
        session.starts,
        end_condition,
        if (max_results == 0) 8 else max_results,
        @min(@as(f64, @floatFromInt(dedup_permille)), 1000.0) / 1000.0,
    ) catch return ZI_ERR_ALLOC;
    return ZI_OK;
}

/// Advances the search. Returns 1 while start nodes are left, 0 when finished.
export fn zi_search_step(budget: u32) i32 {
    const engine = &(session.engine orelse return ZI_ERR_STATE);
    const more = engine.step(if (budget == 0) SEARCH_STEP else budget) catch return ZI_ERR_ALLOC;
    return if (more) 1 else 0;
}

/// [scanned, total, considered, accepted, suppressed, best_elevation, finished, revision]
export fn zi_search_stats(out: [*]u32) void {
    const engine = &(session.engine orelse {
        @memset(out[0..8], 0);
        return;
    });
    const st = engine.stats();
    out[0] = st.scanned;
    out[1] = st.total;
    out[2] = st.considered;
    out[3] = st.accepted;
    out[4] = st.suppressed;
    out[5] = @intCast(@max(st.best_elevation, 0));
    out[6] = @intFromBool(st.finished);
    out[7] = st.revision;
}

export fn zi_route_count() u32 {
    const engine = &(session.engine orelse return 0);
    return @intCast(engine.routes().len);
}

/// [start_idx, elevation, distance, point_count] for route `index`.
export fn zi_route_meta(index: u32, out: [*]u32) i32 {
    const engine = &(session.engine orelse return ZI_ERR_STATE);
    const routes = engine.routes();
    if (index >= routes.len) return ZI_ERR_ARGS;
    const route = routes[index];
    out[0] = route.start_idx;
    out[1] = @intCast(@max(route.elevation, 0));
    out[2] = @intCast(@max(route.distance, 0));
    out[3] = @intCast(route.points.len);
    return ZI_OK;
}

/// Writes route `index` as (lat, lon, elevation) triples and returns the number
/// written, or the required length when `cap` is too small.
export fn zi_route_points(index: u32, out: [*]f32, cap: u32) u32 {
    const graph = session.graph orelse return 0;
    const engine = &(session.engine orelse return 0);
    const routes = engine.routes();
    if (index >= routes.len) return 0;
    return graph.writePathPoints(routes[index].points, out[0..cap]);
}
