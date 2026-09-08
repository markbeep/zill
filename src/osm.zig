const std = @import("std");
const tiff = @import("tiff.zig");

const c = @cImport({
    @cInclude("readosm.h");
});

const Coordinate = packed struct { lat: f32, lon: f32, elev: f32 };

const RouteFilter = struct {
    allocator: std.mem.Allocator,
    geo: tiff.GeoTiff,
    nodes: std.AutoHashMap(i64, Coordinate),
    route_type: []const u8,
    needed_way_ids: std.AutoHashMap(i64, void),
    rel_count: usize = 0,

    max_id: i64 = 0,
    max_elev: f32 = 0.0,

    node_count: usize = 0,
    transformer: tiff.CoordinateTransformer,

    pub fn init(allocator: std.mem.Allocator, geo: tiff.GeoTiff, route_type: []const u8) !RouteFilter {
        const transformer = try tiff.CoordinateTransformer.init(geo.defn.PCS);

        return RouteFilter{
            .allocator = allocator,
            .geo = geo,
            .nodes = std.AutoHashMap(i64, Coordinate).init(allocator),
            .route_type = route_type,
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

    if (filter.node_count % 1000 == 0) {
        std.debug.print("Processed {d} nodes, added {d}\n", .{ filter.node_count, filter.nodes.count() });
    }

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

    defer _ = c.readosm_close(handle);

    if (c.readosm_parse(
        handle,
        &filter,
        parseNodeCallback,
        null,
        parseRelationCallback,
    ) != c.READOSM_OK) {
        return error.ParseFailed;
    }

    std.debug.print("Found {d} relations of type '{s}' and {d} ways\n", .{ filter.rel_count, filter.route_type, filter.needed_way_ids.count() });
    std.debug.print("Max elevation found: {d:.2} meters at node ID {d}\n", .{ filter.max_elev, filter.max_id });
}
