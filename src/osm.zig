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

    pub fn init(io: std.Io, allocator: std.mem.Allocator, geo: tiff.GeoTiff) !RouteFilter {
        const transformer = try tiff.CoordinateTransformer.init(geo.defn.PCS);

        return RouteFilter{
            .io = io,
            .allocator = allocator,
            .geo = geo,
            .nodes = std.AutoHashMap(i64, Coordinate).init(allocator),
            .ways = std.AutoHashMap(i64, ?WayData).init(allocator),
            .needed_node_ids = std.AutoHashMap(i64, u32).init(allocator),
            .transformer = transformer,
            .parent_progress = std.Progress.start(io, .{ .root_name = "filtering OSM routes", .estimated_total_items = 3 }),
            .relation_progress = undefined,
            .way_progress = undefined,
            .way_data_progress = undefined,
            .node_progress = undefined,
        };
    }

    pub fn deinit(self: *RouteFilter) void {
        self.nodes.deinit();
        self.ways.deinit();
        self.transformer.deinit();
        self.needed_node_ids.deinit();
        self.parent_progress.end();
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

    if (filter.ways.get(way.id) == null) return c.READOSM_OK;

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

pub fn call(io: std.Io, allocator: std.mem.Allocator, geo: tiff.GeoTiff, path: []const u8) !void {
    var filter = try RouteFilter.init(io, allocator, geo);
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

    const g = graph.DynamicGraph.init(allocator);
    _ = g;

    // get total distance elev of each way
    // {
    //     if (c.readosm_open(path.ptr, &handle) != c.READOSM_OK)
    //         return error.OpenFailed;
    //     defer _ = c.readosm_close(handle);

    //     filter.way_data_progress = filter.parent_progress.start("parsing way data", filter.ways.count());
    //     defer filter.way_data_progress.end();
    //     if (c.readosm_parse(handle, &filter, null, parseWayElevationDistance, null) != c.READOSM_OK) {
    //         return error.ParseFailed;
    //     }
    // }
}
