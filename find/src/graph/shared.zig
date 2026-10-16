const std = @import("std");
const opts = @import("options");

pub const INVALID_ELEV: u16 = 0xFFFF;

/// In-memory node.
pub const Node = struct {
    id: i64,
    lat: f32,
    lon: f32,
    elev: ?u16,
};

/// In-memory edge, stored once per OSM way segment. The reverse direction is
/// derived (see `HalfEdge` and `DynamicGraph.fromReader`), never stored twice.
pub const Edge = struct {
    u_idx: u32,
    v_idx: u32,
    elev_gain: u16,
    elev_loss: u16,
    distance: u32,
};

/// One traversal step out of a node: the node it reaches and the cost of the
/// edge in that direction. Both graph representations hand these out.
pub const HalfEdge = struct {
    to: u32,
    gain: u16,
    loss: u16,
    distance: u32,
};

pub const FileHeader = extern struct {
    pub const MAGIC = [4]u8{ 'Z', 'I', 'L', 'L' };
    const v = opts.version;

    node_count: u64,
    edge_count: u64,
    magic: [4]u8 = MAGIC,
    version: [4]u8 = .{ v.major, v.minor, v.patch, 0 },
};

pub const MIN_VERSION = std.SemanticVersion{ .major = 0, .minor = 0, .patch = 2 };

/// The file is a header followed by nine typed sections of the "struct of
/// arrays" kind, each aligned to its element size so a loader can take a typed
/// slice straight out of the mapped bytes. Records are never padded, which is
/// what keeps the walkable Swiss graph near 145 MB instead of 200 MB.
pub const Sections = struct {
    ids: u64,
    lats: u64,
    lons: u64,
    elevs: u64,
    edges_u: u64,
    edges_v: u64,
    edges_gain: u64,
    edges_loss: u64,
    edges_dist: u64,
    total: u64,

    pub fn init(node_count: u64, edge_count: u64) Sections {
        const ids = align8(@sizeOf(FileHeader));
        const lats = ids + node_count * @sizeOf(i64);
        const lons = lats + node_count * @sizeOf(f32);
        const elevs = lons + node_count * @sizeOf(f32);
        const edges_u = align8(elevs + node_count * @sizeOf(u16));
        const edges_v = edges_u + edge_count * @sizeOf(u32);
        const edges_gain = edges_v + edge_count * @sizeOf(u32);
        const edges_loss = edges_gain + edge_count * @sizeOf(u16);
        const edges_dist = align8(edges_loss + edge_count * @sizeOf(u16));
        return .{
            .ids = ids,
            .lats = lats,
            .lons = lons,
            .elevs = elevs,
            .edges_u = edges_u,
            .edges_v = edges_v,
            .edges_gain = edges_gain,
            .edges_loss = edges_loss,
            .edges_dist = edges_dist,
            .total = align8(edges_dist + edge_count * @sizeOf(u32)),
        };
    }
};

fn align8(x: u64) u64 {
    return (x + 7) & ~@as(u64, 7);
}

pub fn validVersion(ver: [4]u8) bool {
    const input = std.SemanticVersion{
        .major = ver[0],
        .minor = ver[1],
        .patch = ver[2],
    };
    const range = std.SemanticVersion.Range{
        .min = MIN_VERSION,
        .max = opts.version,
    };
    return range.includesVersion(input);
}

/// The exact byte length a `.zl` file must have to match its header. A file
/// that disagrees would otherwise be read as valid-but-wrong coordinates.
pub fn fileSize(node_count: u64, edge_count: u64) u64 {
    return Sections.init(node_count, edge_count).total;
}

test "layout is dense and aligned" {
    const s = Sections.init(1000, 2000);
    try std.testing.expectEqual(@as(u64, 24), s.ids);
    try std.testing.expectEqual(@as(u64, 24 + 1000 * 8), s.lats);
    try std.testing.expectEqual(s.lats + 1000 * 4, s.lons);
    try std.testing.expectEqual(s.lons + 1000 * 4, s.elevs);
    // Every section starts on its own alignment.
    try std.testing.expectEqual(@as(u64, 0), s.lats % 4);
    try std.testing.expectEqual(@as(u64, 0), s.edges_u % 4);
    try std.testing.expectEqual(@as(u64, 0), s.edges_dist % 4);
    try std.testing.expectEqual(@as(u64, 0), s.total % 8);
    // 18 bytes per node, 16 per edge, plus padding only between sections.
    const dense = 24 + 1000 * 18 + 2000 * 16;
    try std.testing.expect(s.total >= dense and s.total - dense < 8);

    // An odd node count still leaves every section aligned.
    const odd = Sections.init(3, 3);
    try std.testing.expectEqual(@as(u64, 0), odd.edges_u % 4);
    try std.testing.expectEqual(@as(u64, 0), odd.edges_dist % 4);
}
