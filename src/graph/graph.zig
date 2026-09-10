const dyn = @import("dynamic.zig");
const shared = @import("shared.zig");

pub const Node = shared.Node;
pub const Edge = shared.Edge;
pub const FileHeader = shared.FileHeader;

pub const DynamicGraph = dyn.DynamicGraph;

test {
    @import("std").testing.refAllDecls(@This());
}
