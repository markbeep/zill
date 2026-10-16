const std = @import("std");
const opts = @import("options");
const dyn = @import("dynamic.zig");

pub const PackedNode = packed struct {
    pub const INVALID_ELEV: u16 = 0xFFFF;
    id: i64,
    lat: f32,
    lon: f32,
    elev: u16,
};

pub const Node = struct {
    id: i64,
    lat: f32,
    lon: f32,
    elev: ?u16,
};

pub const Edge = packed struct {
    u_idx: u32, // Index in nodes array
    v_idx: u32, // Index in nodes array
    elev_gain: u16,
    elev_loss: u16,
    distance: u32,
};

pub const FileHeader = struct {
    pub const MAGIC = [4]u8{ 'Z', 'I', 'L', 'L' };
    const v = opts.version;

    magic: [4]u8 = MAGIC,
    version: [4]u8 = .{ v.major, v.minor, v.patch, 0 },
    node_count: u64,
    edge_count: u64,
};

pub const MIN_VERSION = std.SemanticVersion{ .major = 0, .minor = 0, .patch = 0 };

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
