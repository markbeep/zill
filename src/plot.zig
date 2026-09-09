const std = @import("std");

pub fn printWayDegreeDistribution(node_counts: std.AutoHashMap(i64, u32)) void {
    const max_track_deg = 350;
    // Indices 0..350 for exact degrees, index 351 for overflow (351+)
    var degree_bins = [_]u64{0} ** (max_track_deg + 2);
    var total_nodes: u64 = 0;

    var iter = node_counts.valueIterator();
    while (iter.next()) |count| {
        const c = count.*;
        if (c <= max_track_deg) {
            degree_bins[c] += 1;
        } else {
            degree_bins[max_track_deg + 1] += 1;
        }
        total_nodes += 1;
    }

    if (total_nodes == 0) return;

    var max_bin: u64 = 0;
    for (degree_bins[1..]) |val| {
        if (val > max_bin) max_bin = val;
    }

    const max_bar_width: usize = 36;
    std.debug.print("\n=== OSM Node Degree Distribution (Total: {d}) ===\n", .{total_nodes});

    for (1..degree_bins.len) |deg| {
        const count = degree_bins[deg];
        if (count == 0) continue;

        const pct = (@as(f64, @floatFromInt(count)) / @as(f64, @floatFromInt(total_nodes))) * 100.0;
        const bar_len = if (max_bin > 0) (count * max_bar_width) / max_bin else 0;

        if (deg <= max_track_deg) {
            std.debug.print("{d:>4} ways | ", .{deg});
        } else {
            std.debug.print("{d:>3}+ ways | ", .{max_track_deg + 1});
        }

        var i: usize = 0;
        while (i < bar_len) : (i += 1) {
            std.debug.print("■", .{});
        }
        std.debug.print(" {d} ({d:.2}%)\n", .{ count, pct });
    }
}
