const std = @import("std");
const eql = std.mem.eql;
const tiff = @import("tiff.zig");
const c = @import("readosm");
const graph = @import("zill");
const options = @import("options");

pub const Coordinate = struct {
    lat: f32,
    lon: f32,
    elev: ?f32,
};

// ------------

const WayFinderData = struct {
    progress: std.Progress.Node = undefined,
    node_counts: *std.AutoHashMap(i64, u32),
    ways: *std.AutoHashMap(i64, void),
};

pub fn findRelevantNodes(
    path: []const u8,
    progress: std.Progress.Node,
    node_counts: *std.AutoHashMap(i64, u32),
    relevant_ways: *std.AutoHashMap(i64, void),
) !void {
    var data = WayFinderData{
        .progress = progress.start("parsing ways", 0),
        .node_counts = node_counts,
        .ways = relevant_ways,
    };
    defer data.progress.end();

    var handle: ?*const anyopaque = null;
    if (c.readosm_open(path.ptr, &handle) != c.READOSM_OK)
        return error.OpenFailed;
    defer _ = c.readosm_close(handle);

    if (c.readosm_parse(handle, &data, null, parseWayCallback, null) != c.READOSM_OK) {
        return error.ParseFailed;
    }
}

fn parseWayCallback(user_data: ?*const anyopaque, way_ptr: [*c]const c.readosm_way) callconv(.c) c_int {
    const relevant: *WayFinderData = @ptrCast(@alignCast(@constCast(user_data)));
    const way = way_ptr.*;

    switch (options.way_type) {
        .walkable => {
            if (!isWalkable(options.allow_ferry, way)) return c.READOSM_OK;
        },
        .cycleable => {
            if (!isCycleable(options.allow_ferry, way)) return c.READOSM_OK;
        },
        .roadbike => {
            if (!isRoadBikeWay(options.allow_ferry, way)) return c.READOSM_OK;
        },
    }

    var n: usize = 0;
    while (n < way.node_ref_count) : (n += 1) {
        const e = relevant.node_counts.getOrPut(way.node_refs[n]) catch return c.READOSM_ABORT;
        e.value_ptr.* = if (e.found_existing) e.value_ptr.* + 1 else 1;
    }

    relevant.ways.put(way.id, {}) catch return c.READOSM_ABORT;
    relevant.progress.completeOne();
    return c.READOSM_OK;
}

// ------------

const NodeData = struct {
    progress: std.Progress.Node = undefined,
    transformer: tiff.CoordinateTransformer,
    geo: tiff.GeoTiff,
    node_counts: std.AutoHashMap(i64, u32),
    nodes: *std.AutoHashMap(i64, Coordinate),
};

pub fn extractNodeElevations(
    path: []const u8,
    progress: std.Progress.Node,
    geo: tiff.GeoTiff,
    node_counts: std.AutoHashMap(i64, u32),
    nodes: *std.AutoHashMap(i64, Coordinate),
) !void {
    var elevs = NodeData{
        .progress = progress.start("parsing nodes", node_counts.count()),
        .transformer = try tiff.CoordinateTransformer.init(geo.defn.PCS),
        .geo = geo,
        .node_counts = node_counts,
        .nodes = nodes,
    };
    defer elevs.transformer.deinit();
    defer elevs.progress.end();

    var handle: ?*const anyopaque = null;
    if (c.readosm_open(path.ptr, &handle) != c.READOSM_OK)
        return error.OpenFailed;
    defer _ = c.readosm_close(handle);

    if (c.readosm_parse(handle, &elevs, parseNodeCallback, null, null) != c.READOSM_OK) {
        return error.ParseFailed;
    }
}

fn parseNodeCallback(user_data: ?*const anyopaque, node_ptr: [*c]const c.readosm_node) callconv(.c) c_int {
    const data: *NodeData = @ptrCast(@alignCast(@constCast(user_data)));
    const node = node_ptr.*;

    if (data.node_counts.get(node.id) == null) return c.READOSM_OK;

    const coords = data.transformer.transform(node.longitude, node.latitude);
    const elev = data.geo.readElevation(coords.x, coords.y) catch return c.READOSM_ABORT;

    data.nodes.put(node.id, .{
        .lat = @floatCast(node.latitude),
        .lon = @floatCast(node.longitude),
        .elev = elev,
    }) catch return c.READOSM_ABORT;

    data.progress.completeOne();
    return c.READOSM_OK;
}

// ------------

const WayComputeData = struct {
    progress: std.Progress.Node = undefined,
    nodes: std.AutoHashMap(i64, Coordinate),
    node_counts: std.AutoHashMap(i64, u32),
    visited_ways: std.AutoHashMap(i64, void),
    graph: *graph.DynamicGraph,
};

pub fn computeWayElevations(
    path: []const u8,
    progress: std.Progress.Node,
    nodes: std.AutoHashMap(i64, Coordinate),
    node_counts: std.AutoHashMap(i64, u32),
    visited_ways: std.AutoHashMap(i64, void),
    g: *graph.DynamicGraph,
) !void {
    var data = WayComputeData{
        .progress = progress.start("parsing way data", visited_ways.count()),
        .nodes = nodes,
        .node_counts = node_counts,
        .visited_ways = visited_ways,
        .graph = g,
    };
    defer data.progress.end();

    var handle: ?*const anyopaque = null;
    if (c.readosm_open(path.ptr, &handle) != c.READOSM_OK)
        return error.OpenFailed;
    defer _ = c.readosm_close(handle);

    if (c.readosm_parse(handle, &data, null, parseWayElevationDistance, null) != c.READOSM_OK) {
        return error.ParseFailed;
    }
}

fn parseWayElevationDistance(user_data: ?*const anyopaque, way_ptr: [*c]const c.readosm_way) callconv(.c) c_int {
    const elevs: *WayComputeData = @ptrCast(@alignCast(@constCast(user_data)));
    const way = way_ptr.*;
    if (elevs.visited_ways.get(way.id) == null) return c.READOSM_OK;

    var accum_dist: f32 = 0;
    var accum_elev_gain: f32 = 0;
    var accum_elev_loss: f32 = 0;

    var last_node = .{
        .ref = way.node_refs[0],
        .coords = elevs.nodes.get(way.node_refs[0]) orelse return c.READOSM_ABORT,
    };

    var last_idx = elevs.graph.addNode(last_node.ref, last_node.coords.lat, last_node.coords.lon, last_node.coords.elev) catch return c.READOSM_ABORT;

    for (way.node_refs[1..@intCast(way.node_ref_count)], 1..) |ref, i| {
        const way_count = elevs.node_counts.get(ref) orelse return c.READOSM_ABORT;
        const coords = elevs.nodes.get(ref) orelse return c.READOSM_ABORT;

        accum_dist += @floatCast(haversineMeters(last_node.coords, coords));
        if (coords.elev != null and last_node.coords.elev != null) {
            // NOTE: if no elev data is present, we simply ignore it. Mostly means that ways going outside of the GeoTIFF bounds will be missing some elevation data
            const elev_diff = coords.elev.? - last_node.coords.elev.?;
            if (elev_diff > 0) {
                accum_elev_gain += elev_diff;
            } else {
                accum_elev_loss += -elev_diff;
            }
        }
        last_node = .{ .ref = ref, .coords = coords };

        // chunk the way into segments if its over 100m
        if (way_count > 1 or i == way.node_ref_count - 1 or accum_dist > 100.0) {
            const new_idx = elevs.graph.addNode(ref, coords.lat, coords.lon, coords.elev) catch return c.READOSM_ABORT;
            elevs.graph.addEdge(
                last_idx,
                new_idx,
                @trunc(accum_elev_gain),
                @trunc(accum_elev_loss),
                @trunc(accum_dist),
            ) catch return c.READOSM_ABORT;

            accum_dist = 0;
            accum_elev_gain = 0;
            accum_elev_loss = 0;
            last_idx = new_idx;
        }
    }

    elevs.progress.completeOne();
    return c.READOSM_OK;
}

// ------------

fn isWalkable(comptime allow_ferry: bool, way: c.readosm_way) bool {
    var walkable = false;

    for (way.tags[0..@intCast(way.tag_count)]) |tag| {
        const key = std.mem.span(tag.key);
        const value = std.mem.span(tag.value);

        if (!allow_ferry) {
            if (eql(u8, key, "ferry") and eql(u8, value, "yes")) {
                return false;
            }
            if (eql(u8, key, "amenity") and eql(u8, value, "ferry_terminal")) {
                return false;
            }
            if (eql(u8, key, "route") and eql(u8, value, "ferry")) {
                return false;
            }
        }

        // https://wiki.openstreetmap.org/wiki/Key:foot
        if (eql(u8, key, "foot")) {
            if (any(value, &.{ "no", "private" })) {
                return false;
            }
            if (any(value, &.{ "yes", "designated" })) {
                walkable = true;
                continue;
            }
        }

        // https://wiki.openstreetmap.org/wiki/Key:access
        if (eql(u8, key, "access")) {
            if (any(value, &.{ "no", "private" })) {
                return false;
            }
            if (any(value, &.{ "yes", "designated" })) {
                walkable = true;
                continue;
            }
        }

        // https://wiki.openstreetmap.org/wiki/Key:highway
        if (eql(u8, key, "highway")) {
            // Default pedestrian infrastructure
            if (any(value, &.{ "footway", "pedestrian", "path", "steps", "living_street", "track" })) {
                walkable = true;
                continue;
            }

            // Standard street grid
            if (any(value, &.{ "residential", "service", "unclassified", "tertiary", "secondary" })) {
                walkable = true;
                continue;
            }
        }
    }

    return walkable;
}

pub fn isCycleable(comptime allow_ferry: bool, way: c.readosm_way) bool {
    var highway: ?[]const u8 = null;
    var bicycle: ?[]const u8 = null;
    var access: ?[]const u8 = null;
    var vehicle: ?[]const u8 = null;
    var cycleway: ?[]const u8 = null;
    var cycleway_left: ?[]const u8 = null;
    var cycleway_right: ?[]const u8 = null;
    var cycleway_both: ?[]const u8 = null;
    var is_ferry = false;

    // 1. Gather relevant tags
    for (way.tags[0..@intCast(way.tag_count)]) |tag| {
        const key = std.mem.span(tag.key);
        const value = std.mem.span(tag.value);

        if (eql(u8, key, "highway")) {
            highway = value;
        } else if (eql(u8, key, "bicycle")) {
            bicycle = value;
        } else if (eql(u8, key, "access")) {
            access = value;
        } else if (eql(u8, key, "vehicle")) {
            vehicle = value;
        } else if (eql(u8, key, "cycleway")) {
            cycleway = value;
        } else if (eql(u8, key, "cycleway:left")) {
            cycleway_left = value;
        } else if (eql(u8, key, "cycleway:right")) {
            cycleway_right = value;
        } else if (eql(u8, key, "cycleway:both")) {
            cycleway_both = value;
        } else if (eql(u8, key, "route") and eql(u8, value, "ferry")) {
            is_ferry = true;
        } else if (eql(u8, key, "ferry") and eql(u8, value, "yes")) {
            is_ferry = true;
        } else if (eql(u8, key, "amenity") and eql(u8, value, "ferry_terminal")) {
            is_ferry = true;
        }
    }

    if (!allow_ferry and is_ferry) {
        return false;
    }

    const hw = highway orelse return false;

    // 2. Explicit bicycle access overrides everything else
    if (bicycle) |b| {
        if (any(b, &.{ "no", "private", "dismount", "use_sidepath" })) return false;
        if (any(b, &.{ "yes", "designated", "permissive" })) return true;
    }

    // 3. Vehicle-level restrictions
    if (vehicle) |v| {
        if (any(v, &.{ "no", "private" })) return false;
        if (any(v, &.{ "yes", "designated", "permissive" })) return true;
    }

    // 4. General access restrictions
    if (access) |a| {
        if (any(a, &.{ "no", "private" })) return false;
    }

    // 5. Explicit cycleway infrastructure alongside/on roads
    inline for (&.{ cycleway, cycleway_left, cycleway_right, cycleway_both }) |cway_tag| {
        if (cway_tag) |cway| {
            if (!any(cway, &.{ "no", "none" })) return true;
        }
    }

    // 6. Dedicated cycling infrastructure
    if (eql(u8, hw, "cycleway")) {
        return true;
    }

    // 7. Inherently prohibited infrastructure for standard cycling
    if (any(hw, &.{
        "motorway",
        "motorway_link",
        "steps",
        "corridor",
        "elevator",
        "proposed",
        "construction",
        "abandoned",
        "platform",
    })) {
        return false;
    }

    // 8. Pedestrian/hiking infrastructure requires explicit bicycle allowance
    // (Checked above: if bicycle=yes was present, it already returned true)
    if (any(hw, &.{ "footway", "pedestrian", "path", "bridleway" })) {
        return false;
    }

    // 9. Standard road network (bicycles allowed by default)
    if (any(hw, &.{
        "residential",
        "living_street",
        "service",
        "unclassified",
        "tertiary",
        "tertiary_link",
        "secondary",
        "secondary_link",
        "primary",
        "primary_link",
        "track",
        "road",
    })) {
        return true;
    }

    return false;
}

pub fn isRoadBikeSurface(way: c.readosm_way) bool {
    var highway: ?[]const u8 = null;
    var surface: ?[]const u8 = null;
    var smoothness: ?[]const u8 = null;
    var tracktype: ?[]const u8 = null;

    for (way.tags[0..@intCast(way.tag_count)]) |tag| {
        const k = std.mem.span(tag.key);
        const v = std.mem.span(tag.value);

        if (eql(u8, k, "highway")) {
            highway = v;
        } else if (eql(u8, k, "surface")) {
            surface = v;
        } else if (eql(u8, k, "smoothness")) {
            smoothness = v;
        } else if (eql(u8, k, "tracktype")) {
            tracktype = v;
        }
    }

    const hw = highway orelse return false;

    // 1. Smoothness check (reject rough/poor road conditions)
    if (smoothness) |sm| {
        if (any(sm, &.{
            "bad",
            "very_bad",
            "horrible",
            "very_horrible",
            "impassable",
            "robust_wheels",
            "high_clearance",
            "off_road_wheels",
        })) {
            return false;
        }
    }

    // 2. Agricultural / Forestry tracktype validation
    if (tracktype) |tt| {
        // Only solid, sealed paved tracks (grade1) are suitable for road bikes
        if (!eql(u8, tt, "grade1")) return false;
    }

    // 3. Explicit surface checks
    if (surface) |s| {
        // Fast-pass for confirmed smooth paved materials
        if (any(s, &.{
            "asphalt",
            "paved",
            "concrete",
            "concrete:lanes",
            "concrete:plates",
            "tarmac",
            "chipseal",
        })) {
            return true;
        }

        // Explicitly reject cobblestones, sett, and all unpaved types
        if (any(s, &.{
            "unpaved",
            "compacted",
            "fine_gravel",
            "gravel",
            "pebblestone",
            "dirt",
            "earth",
            "ground",
            "grass",
            "grass_paver",
            "sand",
            "mud",
            "scree",
            "wood",
            "sett",
            "cobblestone",
            "cobblestone:flattened",
            "unhewn_cobblestone",
        })) {
            return false;
        }

        // Any other non-standard surface tag is assumed non-rideable for a road bike
        return false;
    }

    // 4. Default inference when `surface` is missing:
    // Tracks, paths, and bridleways default to unpaved unless explicitly marked paved
    if (any(hw, &.{ "track", "path", "bridleway", "footway" })) {
        return false;
    }

    // Standard classified roads and dedicated cycleways are paved by default in most regions
    if (any(hw, &.{
        "primary",
        "primary_link",
        "secondary",
        "secondary_link",
        "tertiary",
        "tertiary_link",
        "unclassified",
        "residential",
        "living_street",
        "cycleway",
    })) {
        return true;
    }

    return false;
}

pub fn isRoadBikeWay(comptime allow_ferry: bool, way: c.readosm_way) bool {
    // 1. Must be legally cycleable
    if (!isCycleable(allow_ferry, way)) return false;

    // 2. Must be paved and smooth enough for skinny road tires
    if (!isRoadBikeSurface(way)) return false;

    return true;
}

fn any(v: []const u8, comptime targets: []const []const u8) bool {
    inline for (targets) |target| {
        if (std.mem.eql(u8, v, target)) {
            return true;
        }
    }
    return false;
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
