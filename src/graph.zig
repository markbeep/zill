const std = @import("std");

pub const Node = struct {
    id: i64,
    lat: f32,
    lon: f32,
    elev: ?f32,
};

pub const Edge = packed struct {
    from: usize, // Index in nodes array
    to: usize, // Index in nodes array
    elev_gain: u16,
    elev_loss: u16,
    distance: u32,
};

pub const FileHeader = struct {
    const MAGIC = [8]u8{ 'Z', 'I', 'L', 'L', 0, 0, 0, 0 };

    magic: [8]u8 = MAGIC,
    node_count: usize,
    edge_count: usize,
};

pub const DynamicGraph = struct {
    allocator: std.mem.Allocator,

    nodes: std.ArrayList(Node),
    edges: std.ArrayList(Edge),
    node_edges: std.ArrayList(std.ArrayList(u32)), // One list of edge indices per node (parallel to nodes), so edges can be added in any order.
    osm_id_to_node_idx: std.AutoHashMap(i64, u32),

    pub fn init(allocator: std.mem.Allocator) DynamicGraph {
        return DynamicGraph{
            .allocator = allocator,
            .nodes = std.ArrayList(Node).empty,
            .edges = std.ArrayList(Edge).empty,
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
            Node{
                .id = id,
                .lat = lat,
                .lon = lon,
                .elev = elev,
            },
        );
        try self.node_edges.append(self.allocator, std.ArrayList(u32).empty);
        try self.osm_id_to_node_idx.put(id, idx);
        return idx;
    }

    pub fn addEdge(self: *DynamicGraph, from_idx: usize, to_idx: usize, elev_gain: u16, elev_loss: u16, distance: u32) !void {
        const idx: u32 = @intCast(self.edges.items.len);
        try self.edges.append(
            self.allocator,
            Edge{
                .from = from_idx,
                .to = to_idx,
                .elev_gain = elev_gain,
                .elev_loss = elev_loss,
                .distance = distance,
            },
        );
        try self.node_edges.items[from_idx].append(self.allocator, idx);
    }

    pub const EdgeIterator = struct {
        graph: *DynamicGraph,
        edge_indices: []const u32,
        pos: usize = 0,

        pub fn next(self: *EdgeIterator) ?Edge {
            if (self.pos >= self.edge_indices.len) return null;
            const edge = self.graph.edges.items[self.edge_indices[self.pos]];
            self.pos += 1;
            return edge;
        }
    };

    pub fn iterateOutgoingEdges(self: *DynamicGraph, from_idx: usize) EdgeIterator {
        return .{
            .graph = self,
            .edge_indices = self.node_edges.items[from_idx].items,
        };
    }

    pub fn exportToWriter(self: *DynamicGraph, writer: *std.Io.Writer) !void {
        // Header
        const header = FileHeader{
            .node_count = self.nodes.items.len,
            .edge_count = self.edges.items.len,
        };
        try writer.writeAll(std.mem.asBytes(&header));

        // Nodes
        for (self.nodes.items) |n| {
            try writer.writeAll(std.mem.asBytes(&n));
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
        var header: FileHeader = undefined;
        try reader.readSliceAll(std.mem.asBytes(&header));
        if (!std.mem.eql(u8, &header.magic, &FileHeader.MAGIC)) {
            return error.InvalidFileFormat;
        }

        // Read nodes
        for (0..header.node_count) |i| {
            var node: Node = undefined;
            try reader.readSliceAll(std.mem.asBytes(&node));
            try graph.nodes.append(allocator, node);
            try graph.node_edges.append(allocator, std.ArrayList(u32).empty);
            try graph.osm_id_to_node_idx.put(node.id, @intCast(i));
        }

        // Read edges
        for (0..header.edge_count) |i| {
            var edge: Edge = undefined;
            try reader.readSliceAll(std.mem.asBytes(&edge));
            try graph.edges.append(allocator, edge);
            try graph.node_edges.items[edge.from].append(allocator, @intCast(i));
        }

        return graph;
    }
};

test "basic graph" {
    var graph = DynamicGraph.init(std.testing.allocator);
    defer graph.deinit();

    const node_idx1 = try graph.addNode(1, 10.0, 20.0, 100.0);
    const node_idx2 = try graph.addNode(2, 11.0, 21.0, 200.0);
    try graph.addEdge(node_idx1, node_idx2, 50, 30, 100);

    try std.testing.expect(graph.nodes.items.len == 2);
    try std.testing.expect(graph.edges.items.len == 1);

    const edge = graph.edges.items[0];
    try std.testing.expect(edge.from == node_idx1);
    try std.testing.expect(edge.to == node_idx2);
    try std.testing.expect(edge.elev_gain == 50);
    try std.testing.expect(edge.elev_loss == 30);
    try std.testing.expect(edge.distance == 100);
}

test "iterate" {
    var graph = DynamicGraph.init(std.testing.allocator);
    defer graph.deinit();

    const node_idx0 = try graph.addNode(1, 10.0, 20.0, 100.0);
    const node_idx1 = try graph.addNode(2, 11.0, 21.0, 200.0);
    const node_idx2 = try graph.addNode(3, 12.0, 22.0, 300.0);
    const node_idx3 = try graph.addNode(4, 13.0, 23.0, 400.0);
    try graph.addEdge(node_idx0, node_idx1, 50, 30, 100);
    try graph.addEdge(node_idx0, node_idx2, 60, 40, 150);
    try graph.addEdge(node_idx1, node_idx3, 70, 50, 200);

    var iter = graph.iterateOutgoingEdges(node_idx0);
    var count: usize = 0;
    while (iter.next()) |edge| : (count += 1) {
        try std.testing.expect(edge.from == node_idx0);
        if (count == 0) {
            try std.testing.expect(edge.to == node_idx1);
            try std.testing.expect(edge.elev_gain == 50);
            try std.testing.expect(edge.elev_loss == 30);
            try std.testing.expect(edge.distance == 100);
        } else if (count == 1) {
            try std.testing.expect(edge.to == node_idx2);
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
    var graph = DynamicGraph.init(std.testing.allocator);
    defer graph.deinit();

    const node_idx0 = try graph.addNode(1, 10.0, 20.0, 100.0);
    const node_idx1 = try graph.addNode(2, 11.0, 21.0, 200.0);
    const node_idx2 = try graph.addNode(3, 12.0, 22.0, 300.0);

    // Edges can be added in any order, and to any node, after the fact.
    try graph.addEdge(node_idx1, node_idx2, 70, 50, 200);
    try graph.addEdge(node_idx0, node_idx2, 60, 40, 150);
    try graph.addEdge(node_idx0, node_idx1, 50, 30, 100);

    var iter = graph.iterateOutgoingEdges(node_idx0);
    var count: usize = 0;
    while (iter.next()) |edge| : (count += 1) {
        try std.testing.expect(edge.from == node_idx0);
        if (count == 0) {
            try std.testing.expect(edge.to == node_idx2);
        } else if (count == 1) {
            try std.testing.expect(edge.to == node_idx1);
        } else {
            try std.testing.expect(false);
        }
    }
    try std.testing.expect(count == 2);
}

test "export" {
    var graph = DynamicGraph.init(std.testing.allocator);
    defer graph.deinit();

    const node_idx1 = try graph.addNode(1, 10.0, 20.0, 100.0);
    const node_idx2 = try graph.addNode(2, 11.0, 21.0, 200.0);
    try graph.addEdge(node_idx1, node_idx2, 50, 30, 100);

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try graph.exportToWriter(&writer);

    var reader = std.Io.Reader.fixed(&buffer);
    var loaded_graph = try DynamicGraph.fromReader(std.testing.allocator, &reader);
    defer loaded_graph.deinit();

    try std.testing.expect(loaded_graph.nodes.items.len == 2);
    try std.testing.expect(loaded_graph.edges.items.len == 1);
    const loaded_edge = loaded_graph.edges.items[0];
    try std.testing.expect(loaded_edge.from == node_idx1);
    try std.testing.expect(loaded_edge.to == node_idx2);

    var iter = loaded_graph.iterateOutgoingEdges(node_idx1);
    const loaded_adj_edge = iter.next().?;
    try std.testing.expect(loaded_adj_edge.to == node_idx2);
    try std.testing.expect(iter.next() == null);
}
