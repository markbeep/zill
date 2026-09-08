const std = @import("std");
const tiff = @import("tiff.zig");

const c = @cImport({
    @cInclude("readosm.h");
});

const Coordinate = packed struct { lat: f32, lon: f32, elev: f32 };

const RouteFilter = struct {
    allocator: std.mem.Allocator,
    geo: tiff.GeoTiff,
    route_type: []const u8,

    nodes: std.AutoHashMap(i64, Coordinate),
    needed_node_ids: std.AutoHashMap(i64, void),
    needed_way_ids: std.AutoHashMap(i64, void),

    node_count: usize = 0,
    way_count: usize = 0,
    rel_count: usize = 0,
    max_id: i64 = 0,
    max_elev: f32 = 0.0,

    transformer: tiff.CoordinateTransformer,

    pub fn init(allocator: std.mem.Allocator, geo: tiff.GeoTiff, route_type: []const u8) !RouteFilter {
        const transformer = try tiff.CoordinateTransformer.init(geo.defn.PCS);

        return RouteFilter{
            .allocator = allocator,
            .geo = geo,
            .route_type = route_type,
            .nodes = std.AutoHashMap(i64, Coordinate).init(allocator),
            .needed_node_ids = std.AutoHashMap(i64, void).init(allocator),
            .needed_way_ids = std.AutoHashMap(i64, void).init(allocator),
            .transformer = transformer,
        };
    }

    pub fn deinit(self: *RouteFilter) void {
        self.needed_way_ids.deinit();
        self.nodes.deinit();
        self.transformer.deinit();
    }
};

fn parseNodeCallback(user_data: ?*const anyopaque, node_ptr: [*c]const c.readosm_node) callconv(.c) c_int {
    const filter: *RouteFilter = @ptrCast(@alignCast(@constCast(user_data)));
    const node = node_ptr.*;

    filter.node_count += 1;
    if (filter.node_count % 10000 == 0) {
        std.debug.print("Processed {d} nodes, added {d}\n", .{ filter.node_count, filter.nodes.count() });
    }

    if (filter.needed_node_ids.get(node.id) == null) return c.READOSM_OK;

    const coords = filter.transformer.transform(node.longitude, node.latitude);
    const elev = (filter.geo.readElevation(filter.allocator, coords.x, coords.y) catch return c.READOSM_ABORT) orelse return c.READOSM_OK;

    if (elev > filter.max_elev) {
        filter.max_elev = elev;
        filter.max_id = node.id;
    }

    filter.nodes.put(node.id, .{
        .lat = @floatCast(node.latitude),
        .lon = @floatCast(node.longitude),
        .elev = elev,
    }) catch return c.READOSM_ABORT;

    return c.READOSM_OK;
}

fn parseWayCallback(user_data: ?*const anyopaque, way_ptr: [*c]const c.readosm_way) callconv(.c) c_int {
    const filter: *RouteFilter = @ptrCast(@alignCast(@constCast(user_data)));
    const way = way_ptr.*;

    filter.way_count += 1;
    if (filter.way_count % 100000 == 0) {
        std.debug.print("Processed {d} ways\n", .{filter.way_count});
    }

    if (filter.needed_way_ids.get(way.id) == null) return c.READOSM_OK;

    var n: usize = 0;
    while (n < way.node_ref_count) : (n += 1) {
        filter.needed_node_ids.put(way.node_refs[n], {}) catch return c.READOSM_ABORT;
    }
    return c.READOSM_OK;
}

fn parseRelationCallback(user_data: ?*const anyopaque, rel_ptr: [*c]const c.readosm_relation) callconv(.c) c_int {
    const filter: *RouteFilter = @ptrCast(@alignCast(@constCast(user_data)));
    const rel = rel_ptr.*;

    var is_route: bool = false;
    var matches_type: bool = false;

    var i: usize = 0;
    while (i < rel.tag_count) : (i += 1) {
        const tag = rel.tags[i];
        const key = std.mem.span(tag.key);
        const value = std.mem.span(tag.value);

        if (std.mem.eql(u8, key, "type") and std.mem.eql(u8, value, "route")) {
            is_route = true;
        } else if (std.mem.eql(u8, key, "route") and std.mem.eql(u8, value, filter.route_type)) {
            matches_type = true;
        }
        if (is_route and matches_type) {
            break;
        }
    }

    if (!is_route or !matches_type) {
        return c.READOSM_OK;
    }

    filter.rel_count += 1;

    var m: usize = 0;
    while (m < rel.member_count) : (m += 1) {
        const member = rel.members[m];
        if (member.member_type == c.READOSM_MEMBER_WAY) {
            filter.needed_way_ids.put(member.id, {}) catch return c.READOSM_ABORT;
        }
    }

    return c.READOSM_OK;
}

pub fn call(allocator: std.mem.Allocator, geo: tiff.GeoTiff, path: []const u8, route_type: []const u8) !void {
    var filter = try RouteFilter.init(allocator, geo, route_type);
    defer filter.deinit();

    var handle: ?*const anyopaque = null;
    if (c.readosm_open(path.ptr, &handle) != c.READOSM_OK)
        return error.OpenFailed;

    // find all relevant relations and way-ids
    if (c.readosm_parse(handle, &filter, null, null, parseRelationCallback) != c.READOSM_OK) {
        _ = c.readosm_close(handle);
        return error.ParseFailed;
    }
    std.debug.print("Found {d} relations of type '{s}' and {d} ways\n", .{ filter.rel_count, filter.route_type, filter.needed_way_ids.count() });

    // find all relevant ways and node ids
    _ = c.readosm_close(handle);
    if (c.readosm_open(path.ptr, &handle) != c.READOSM_OK)
        return error.OpenFailed;
    if (c.readosm_parse(handle, &filter, null, parseWayCallback, null) != c.READOSM_OK) {
        return error.ParseFailed;
    }
    std.debug.print("Found {d} ways and {d} nodes\n", .{ filter.way_count, filter.needed_node_ids.count() });

    // find all relevant nodes and elevations
    _ = c.readosm_close(handle);
    if (c.readosm_open(path.ptr, &handle) != c.READOSM_OK)
        return error.OpenFailed;
    defer _ = c.readosm_close(handle);
    if (c.readosm_parse(handle, &filter, parseNodeCallback, null, null) != c.READOSM_OK) {
        return error.ParseFailed;
    }
    std.debug.print("Found {d} nodes with elevation data\n", .{filter.nodes.count()});
    std.debug.print("Max elevation found: {d:.2} meters at node ID {d}\n", .{ filter.max_elev, filter.max_id });
}
