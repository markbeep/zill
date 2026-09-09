const std = @import("std");
const eql = std.mem.eql;
const tiff = @import("tiff.zig");
const c = @import("readosm");
const graph = @import("graph.zig");

const Coordinate = packed struct {
    lat: f32,
    lon: f32,
    elev: f32,
};
const WayData = packed struct {
    elev_gain: f32,
    elev_loss: f32,
    distance: f32,
};

const RouteFilter = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    geo: tiff.GeoTiff,

    nodes: std.AutoHashMap(i64, Coordinate),
    ways: std.AutoHashMap(i64, ?WayData),
    needed_node_ids: std.AutoHashMap(i64, u32),

    transformer: tiff.CoordinateTransformer,

    parent_progress: std.Progress.Node,
    relation_progress: std.Progress.Node,
    way_progress: std.Progress.Node,
    node_progress: std.Progress.Node,
    way_data_progress: std.Progress.Node,

    graph: graph.DynamicGraph,

    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        geo: tiff.GeoTiff,
        progress: std.Progress.Node,
    ) !RouteFilter {
        const transformer = try tiff.CoordinateTransformer.init(geo.defn.PCS);

        return RouteFilter{
            .io = io,
            .allocator = allocator,
            .geo = geo,
            .nodes = std.AutoHashMap(i64, Coordinate).init(allocator),
            .ways = std.AutoHashMap(i64, ?WayData).init(allocator),
            .needed_node_ids = std.AutoHashMap(i64, u32).init(allocator),
            .transformer = transformer,
            .parent_progress = progress,
            .relation_progress = undefined,
            .way_progress = undefined,
            .way_data_progress = undefined,
            .node_progress = undefined,
            .graph = graph.DynamicGraph.init(allocator),
        };
    }

    pub fn deinit(self: *RouteFilter) void {
        self.nodes.deinit();
        self.ways.deinit();
        self.transformer.deinit();
        self.needed_node_ids.deinit();
        self.parent_progress.end();
        self.graph.deinit();
    }
};

fn parseNodeCallback(user_data: ?*const anyopaque, node_ptr: [*c]const c.readosm_node) callconv(.c) c_int {
    const filter: *RouteFilter = @ptrCast(@alignCast(@constCast(user_data)));
    const node = node_ptr.*;

    if (filter.needed_node_ids.get(node.id) == null) return c.READOSM_OK;

    const coords = filter.transformer.transform(node.longitude, node.latitude);
    const elev = (filter.geo.readElevation(filter.allocator, coords.x, coords.y) catch return c.READOSM_ABORT) orelse return c.READOSM_OK;

    filter.nodes.put(node.id, .{
        .lat = @floatCast(node.latitude),
        .lon = @floatCast(node.longitude),
        .elev = elev,
    }) catch return c.READOSM_ABORT;

    filter.node_progress.completeOne();
    return c.READOSM_OK;
}

fn parseWayCallback(user_data: ?*const anyopaque, way_ptr: [*c]const c.readosm_way) callconv(.c) c_int {
    const filter: *RouteFilter = @ptrCast(@alignCast(@constCast(user_data)));
    const way = way_ptr.*;

    if (way.node_ref_count == 0) return c.READOSM_OK;
    if (!isWalkable(way)) return c.READOSM_OK;

    var n: usize = 0;
    while (n < way.node_ref_count) : (n += 1) {
        const e = filter.needed_node_ids.getOrPut(way.node_refs[n]) catch return c.READOSM_ABORT;
        e.value_ptr.* = if (e.found_existing) e.value_ptr.* + 1 else 1;
    }

    filter.ways.put(way.id, null) catch return c.READOSM_ABORT;
    filter.way_progress.completeOne();
    return c.READOSM_OK;
}

fn parseWayElevationDistance(user_data: ?*const anyopaque, way_ptr: [*c]const c.readosm_way) callconv(.c) c_int {
    const filter: *RouteFilter = @ptrCast(@alignCast(@constCast(user_data)));
    const way = way_ptr.*;

    if (way.node_ref_count == 0) return c.READOSM_OK;
    if (filter.ways.get(way.id) == null) return c.READOSM_OK;

    const NodeData = struct {
        ref: i64,
        coords: Coordinate,
    };

    var accum_dist: f32 = 0;
    var accum_elev_gain: f32 = 0;
    var accum_elev_loss: f32 = 0;

    var last_node: NodeData = .{
        .ref = way.node_refs[0],
        .coords = filter.nodes.get(way.node_refs[0]) orelse return c.READOSM_ABORT,
    };
    var last_idx = filter.graph.addNode(last_node.ref, last_node.coords.lat, last_node.coords.lon, last_node.coords.elev) catch return c.READOSM_ABORT;

    for (way.node_refs[1..@intCast(way.node_ref_count - 1)], 1..) |ref, i| {
        const coords = filter.nodes.get(ref) orelse return c.READOSM_ABORT;
        const way_count = filter.needed_node_ids.get(ref) orelse return c.READOSM_ABORT;

        accum_dist += @floatCast(haversineMeters(last_node.coords, coords));
        const elev_diff = coords.elev - last_node.coords.elev;
        if (elev_diff > 0) {
            accum_elev_gain += elev_diff;
        } else {
            accum_elev_loss += -elev_diff;
        }

        if (way_count > 1 or i == way.node_ref_count - 1) {
            const new_idx = filter.graph.addNode(ref, coords.lat, coords.lon, coords.elev) catch return c.READOSM_ABORT;
            filter.graph.addEdge(
                last_idx,
                new_idx,
                @trunc(accum_elev_gain),
                @trunc(accum_elev_loss),
                @trunc(accum_dist),
            ) catch return c.READOSM_ABORT;

            last_node = NodeData{ .ref = ref, .coords = coords };
            accum_dist = 0;
            accum_elev_gain = 0;
            accum_elev_loss = 0;
            last_idx = new_idx;
        }
    }

    filter.way_data_progress.completeOne();
    return c.READOSM_OK;
}

fn isWalkable(way: c.readosm_way) bool {
    var i: usize = 0;
    while (i < way.tag_count) : (i += 1) {
        const key = std.mem.span(way.tags[i].key);
        const value = std.mem.span(way.tags[i].value);

        // https://wiki.openstreetmap.org/wiki/Key:foot
        if (eql(u8, key, "foot")) {
            if (any(value, &.{ "no", "private" })) {
                return false;
            }
            if (any(value, &.{ "yes", "designated" })) {
                return true;
            }
        }

        // https://wiki.openstreetmap.org/wiki/Key:access
        if (eql(u8, key, "access")) {
            if (any(value, &.{ "no", "private" })) {
                return false;
            }
            if (any(value, &.{ "yes", "designated" })) {
                return true;
            }
        }

        // https://wiki.openstreetmap.org/wiki/Key:highway
        if (eql(u8, key, "highway")) {
            // Default pedestrian infrastructure
            if (any(value, &.{ "footway", "pedestrian", "path", "steps", "living_street", "track" }))
                return true;

            // Standard street grid
            if (any(value, &.{ "residential", "service", "unclassified", "tertiary", "secondary" }))
                return true;
        }
    }
    return false;
}

fn any(v: []const u8, comptime targets: []const []const u8) bool {
    inline for (targets) |target| {
        if (std.mem.eql(u8, v, target)) {
            return true;
        }
    }
    return false;
}

pub fn generateGraph(
    io: std.Io,
    allocator: std.mem.Allocator,
    geo: tiff.GeoTiff,
    progress: std.Progress.Node,
    path: []const u8,
) !void {
    var filter = try RouteFilter.init(io, allocator, geo, progress);
    defer filter.deinit();
    var handle: ?*const anyopaque = null;

    // find all relevant ways and node ids
    {
        if (c.readosm_open(path.ptr, &handle) != c.READOSM_OK)
            return error.OpenFailed;
        defer _ = c.readosm_close(handle);

        filter.way_progress = filter.parent_progress.start("parsing ways", 0);
        defer filter.way_progress.end();
        if (c.readosm_parse(handle, &filter, null, parseWayCallback, null) != c.READOSM_OK) {
            return error.ParseFailed;
        }
    }

    @import("plot.zig").printWayDegreeDistribution(filter.needed_node_ids);

    // find all relevant nodes and elevations
    {
        if (c.readosm_open(path.ptr, &handle) != c.READOSM_OK)
            return error.OpenFailed;
        defer _ = c.readosm_close(handle);

        filter.node_progress = filter.parent_progress.start("parsing nodes", filter.needed_node_ids.count());
        defer filter.node_progress.end();
        if (c.readosm_parse(handle, &filter, parseNodeCallback, null, null) != c.READOSM_OK) {
            return error.ParseFailed;
        }
    }

    // get total distance elev of each way
    {
        if (c.readosm_open(path.ptr, &handle) != c.READOSM_OK)
            return error.OpenFailed;
        defer _ = c.readosm_close(handle);

        filter.way_data_progress = filter.parent_progress.start("parsing way data", filter.ways.count());
        defer filter.way_data_progress.end();
        if (c.readosm_parse(handle, &filter, null, parseWayElevationDistance, null) != c.READOSM_OK) {
            return error.ParseFailed;
        }
    }

    {
        var f = try std.Io.Dir.cwd().createFile(io, "data/graph.zill", .{});
        defer f.close(io);
        var buffer: [1024]u8 = undefined;
        var writer = f.writer(io, &buffer);
        try filter.graph.exportToWriter(&writer.interface);
        std.debug.print("Graph exported to graph.zill\n", .{});
    }
}

/// Computes great-circle distance between two coordinates in meters
pub fn haversineMeters(p1: Coordinate, p2: Coordinate) f64 {
    const r_earth = 6_371_000.0; // Mean Earth radius in meters

    const d_lat = std.math.degreesToRadians(p2.lat - p1.lat);
    const d_lon = std.math.degreesToRadians(p2.lon - p1.lon);

    const lat1_rad = std.math.degreesToRadians(p1.lat);
    const lat2_rad = std.math.degreesToRadians(p2.lat);

    const sin_dlat_2 = @sin(d_lat / 2.0);
    const sin_dlon_2 = @sin(d_lon / 2.0);

    const a = (sin_dlat_2 * sin_dlat_2) +
        (@cos(lat1_rad) * @cos(lat2_rad) * sin_dlon_2 * sin_dlon_2);

    const _c = 2.0 * std.math.atan2(@sqrt(a), @sqrt(1.0 - a));

    return r_earth * _c;
}

test "haversineMeters test" {
    const p1 = Coordinate{ .lat = 47.44062272339814, .lon = 8.884900444931503, .elev = 0 };
    const p2 = Coordinate{ .lat = 47.46571031478965, .lon = 8.49570105230328, .elev = 0 };
    const distance = haversineMeters(p1, p2);
    try std.testing.expect(@abs(distance - 29396.19) < 100.0);
}
