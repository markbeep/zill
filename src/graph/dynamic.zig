const std = @import("std");
const s = @import("shared.zig");

pub const DynamicGraph = struct {
    allocator: std.mem.Allocator,

    nodes: std.ArrayList(s.Node),
    edges: std.ArrayList(s.Edge),
    node_edges: std.ArrayList(std.ArrayList(u32)),
    osm_id_to_node_idx: std.AutoHashMap(i64, u32),

    pub fn init(allocator: std.mem.Allocator) DynamicGraph {
        return DynamicGraph{
            .allocator = allocator,
            .nodes = std.ArrayList(s.Node).empty,
            .edges = std.ArrayList(s.Edge).empty,
            .node_edges = std.ArrayList(std.ArrayList(u32)).empty,
            .osm_id_to_node_idx = std.AutoHashMap(i64, u32).init(allocator),
        };
    }

    pub fn deinit(self: *DynamicGraph) void {
        for (self.node_edges.items) |*edge_list| {
            edge_list.deinit(self.allocator);
        }
        self.node_edges.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.edges.deinit(self.allocator);
        self.osm_id_to_node_idx.deinit();
    }

    pub fn addNode(self: *DynamicGraph, id: i64, lat: f32, lon: f32, elev: ?f32) !u32 {
        if (self.osm_id_to_node_idx.get(id)) |existing_idx| {
            return existing_idx;
        }
        const idx: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(
            self.allocator,
            s.Node{
                .id = id,
                .lat = lat,
                .lon = lon,
                .elev = if (elev) |e| @trunc(e) else null,
            },
        );
        try self.node_edges.append(self.allocator, std.ArrayList(u32).empty);
        try self.osm_id_to_node_idx.put(id, idx);
        return idx;
    }

    pub fn addEdge(self: *DynamicGraph, u_idx: u32, v_idx: u32, elev_gain: u16, elev_loss: u16, distance: u32) !void {
        const idx: u32 = @intCast(self.edges.items.len);
        try self.edges.append(
            self.allocator,
            s.Edge{
                .u_idx = u_idx,
                .v_idx = v_idx,
                .elev_gain = elev_gain,
                .elev_loss = elev_loss,
                .distance = distance,
            },
        );
        try self.node_edges.items[u_idx].append(self.allocator, idx);
    }

    pub const EdgeIterator = struct {
        graph: *DynamicGraph,
        edge_indices: []const u32,
        pos: usize = 0,

        pub fn next(self: *EdgeIterator) ?s.Edge {
            if (self.pos >= self.edge_indices.len) return null;
            const edge = self.graph.edges.items[self.edge_indices[self.pos]];
            self.pos += 1;
            return edge;
        }
    };

    pub fn iterateOutgoingEdges(self: *DynamicGraph, u_idx: usize) EdgeIterator {
        return .{
            .graph = self,
            .edge_indices = self.node_edges.items[u_idx].items,
        };
    }

    pub fn exportToWriter(self: *DynamicGraph, writer: *std.Io.Writer) !void {
        // Header
        const header = s.FileHeader{
            .node_count = self.nodes.items.len,
            .edge_count = self.edges.items.len,
        };
        try writer.writeAll(std.mem.asBytes(&header));

        // Nodes
        for (self.nodes.items) |n| {
            const packed_node = s.PackedNode{
                .id = n.id,
                .lat = n.lat,
                .lon = n.lon,
                .elev = if (n.elev) |e| e else s.PackedNode.INVALID_ELEV,
            };
            try writer.writeAll(std.mem.asBytes(&packed_node));
        }
        // Edges
        for (self.edges.items) |e| {
            try writer.writeAll(std.mem.asBytes(&e));
        }
        try writer.flush();
    }

    pub fn fromReader(allocator: std.mem.Allocator, reader: *std.Io.Reader) !DynamicGraph {
        var graph = DynamicGraph.init(allocator);

        // Read header
        var header: s.FileHeader = undefined;
        try reader.readSliceAll(std.mem.asBytes(&header));
        if (!std.mem.eql(u8, &header.magic, &s.FileHeader.MAGIC)) {
            return error.InvalidFileFormat;
        }

        if (!s.validVersion(header.version)) {
            std.debug.print("Unsupported version: {d}.{d}.{d}\n", .{ header.version[0], header.version[1], header.version[2] });
            return error.UnsupportedVersion;
        }

        // Read nodes
        for (0..header.node_count) |i| {
            var packed_node: s.PackedNode = undefined;
            try reader.readSliceAll(std.mem.asBytes(&packed_node));
            const node = s.Node{
                .id = packed_node.id,
                .lat = packed_node.lat,
                .lon = packed_node.lon,
                .elev = if (packed_node.elev == s.PackedNode.INVALID_ELEV) null else @intCast(packed_node.elev),
            };
            try graph.nodes.append(allocator, node);
            try graph.node_edges.append(allocator, std.ArrayList(u32).empty);
            try graph.osm_id_to_node_idx.put(node.id, @intCast(i));
        }

        // Read edges
        for (0..header.edge_count) |i| {
            var edge: s.Edge = undefined;
            try reader.readSliceAll(std.mem.asBytes(&edge));
            try graph.edges.append(allocator, edge);
            try graph.node_edges.items[edge.u_idx].append(allocator, @intCast(i));
        }

        // Edges the other way
        for (0..header.edge_count) |i| {
            const edge = graph.edges.items[i];
            const flipped = s.Edge{
                .u_idx = edge.v_idx,
                .v_idx = edge.u_idx,
                .elev_gain = edge.elev_loss,
                .elev_loss = edge.elev_gain,
                .distance = edge.distance,
            };
            try graph.edges.append(allocator, flipped);
            try graph.node_edges.items[flipped.u_idx].append(allocator, @intCast(i + header.edge_count));
        }

        return graph;
    }
};

test "basic graph" {
    var dyn = DynamicGraph.init(std.testing.allocator);
    defer dyn.deinit();

    const node_idx1 = try dyn.addNode(1, 10.0, 20.0, 100.0);
    const node_idx2 = try dyn.addNode(2, 11.0, 21.0, 200.0);
    try dyn.addEdge(node_idx1, node_idx2, 50, 30, 100);

    try std.testing.expect(dyn.nodes.items.len == 2);
    try std.testing.expect(dyn.edges.items.len == 1);

    const edge = dyn.edges.items[0];
    try std.testing.expect(edge.u_idx == node_idx1);
    try std.testing.expect(edge.v_idx == node_idx2);
    try std.testing.expect(edge.elev_gain == 50);
    try std.testing.expect(edge.elev_loss == 30);
    try std.testing.expect(edge.distance == 100);
}

test "iterate" {
    var dyn = DynamicGraph.init(std.testing.allocator);
    defer dyn.deinit();

    const node_idx0 = try dyn.addNode(1, 10.0, 20.0, 100.0);
    const node_idx1 = try dyn.addNode(2, 11.0, 21.0, 200.0);
    const node_idx2 = try dyn.addNode(3, 12.0, 22.0, 300.0);
    const node_idx3 = try dyn.addNode(4, 13.0, 23.0, 400.0);
    try dyn.addEdge(node_idx0, node_idx1, 50, 30, 100);
    try dyn.addEdge(node_idx0, node_idx2, 60, 40, 150);
    try dyn.addEdge(node_idx1, node_idx3, 70, 50, 200);

    var iter = dyn.iterateOutgoingEdges(node_idx0);
    var count: usize = 0;
    while (iter.next()) |edge| : (count += 1) {
        try std.testing.expect(edge.u_idx == node_idx0);
        if (count == 0) {
            try std.testing.expect(edge.v_idx == node_idx1);
            try std.testing.expect(edge.elev_gain == 50);
            try std.testing.expect(edge.elev_loss == 30);
            try std.testing.expect(edge.distance == 100);
        } else if (count == 1) {
            try std.testing.expect(edge.v_idx == node_idx2);
            try std.testing.expect(edge.elev_gain == 60);
            try std.testing.expect(edge.elev_loss == 40);
            try std.testing.expect(edge.distance == 150);
        } else {
            try std.testing.expect(false);
        }
    }
    try std.testing.expect(count == 2);
}

test "add edges later" {
    var dyn = DynamicGraph.init(std.testing.allocator);
    defer dyn.deinit();

    const node_idx0 = try dyn.addNode(1, 10.0, 20.0, 100.0);
    const node_idx1 = try dyn.addNode(2, 11.0, 21.0, 200.0);
    const node_idx2 = try dyn.addNode(3, 12.0, 22.0, 300.0);

    // Edges can be added in any order, and to any node, after the fact.
    try dyn.addEdge(node_idx1, node_idx2, 70, 50, 200);
    try dyn.addEdge(node_idx0, node_idx2, 60, 40, 150);
    try dyn.addEdge(node_idx0, node_idx1, 50, 30, 100);

    var iter = dyn.iterateOutgoingEdges(node_idx0);
    var count: usize = 0;
    while (iter.next()) |edge| : (count += 1) {
        try std.testing.expect(edge.u_idx == node_idx0);
        if (count == 0) {
            try std.testing.expect(edge.v_idx == node_idx2);
        } else if (count == 1) {
            try std.testing.expect(edge.v_idx == node_idx1);
        } else {
            try std.testing.expect(false);
        }
    }
    try std.testing.expect(count == 2);
}

test "export" {
    var dyn = DynamicGraph.init(std.testing.allocator);
    defer dyn.deinit();

    const node_idx1 = try dyn.addNode(1, 10.0, 20.0, 100.0);
    const node_idx2 = try dyn.addNode(2, 11.0, 21.0, 200.0);
    try dyn.addEdge(node_idx1, node_idx2, 50, 30, 100);

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try dyn.exportToWriter(&writer);

    var reader = std.Io.Reader.fixed(&buffer);
    var loaded_graph = try DynamicGraph.fromReader(std.testing.allocator, &reader);
    defer loaded_graph.deinit();

    try std.testing.expect(loaded_graph.nodes.items.len == 2);
    try std.testing.expect(loaded_graph.edges.items.len == 1);
    const loaded_edge = loaded_graph.edges.items[0];
    try std.testing.expect(loaded_edge.u_idx == node_idx1);
    try std.testing.expect(loaded_edge.v_idx == node_idx2);

    var iter = loaded_graph.iterateOutgoingEdges(node_idx1);
    const loaded_adj_edge = iter.next().?;
    try std.testing.expect(loaded_adj_edge.v_idx == node_idx2);
    try std.testing.expect(iter.next() == null);
}
