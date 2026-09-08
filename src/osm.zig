const std = @import("std");
const c = @cImport({
    @cInclude("readosm.h");
});

const COUNT = true;

const RouteFilter = struct {
    allocator: std.mem.Allocator,
    route_type: []const u8,
    needed_way_ids: std.AutoHashMap(i64, void),
    rel_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, route_type: []const u8) RouteFilter {
        return RouteFilter{
            .allocator = allocator,
            .route_type = route_type,
            .needed_way_ids = std.AutoHashMap(i64, void).init(allocator),
        };
    }

    pub fn deinit(self: *RouteFilter) void {
        self.needed_way_ids.deinit();
    }
};

fn parseRelationCallback(user_data: ?*const anyopaque, rel_ptr: [*c]const c.readosm_relation) callconv(.c) c_int {
    const filter: *RouteFilter = @ptrCast(@alignCast(@constCast(user_data)));
    const rel = rel_ptr.*;

    if (COUNT) {
        filter.rel_count += 1;
        return c.READOSM_OK;
    }

    var is_route: bool = false;
    var matches_type: bool = false;

    if (rel.tag_count == 350) std.debug.print("ID {d} has 350 tags\n", .{rel.id});

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

pub fn call(path: []const u8, route_type: []const u8) !void {
    var filter = RouteFilter.init(std.heap.page_allocator, route_type);
    defer filter.deinit();

    var handle: ?*const anyopaque = null;
    if (c.readosm_open(path.ptr, &handle) != c.READOSM_OK)
        return error.OpenFailed;

    defer _ = c.readosm_close(handle);

    if (c.readosm_parse(handle, &filter, null, null, parseRelationCallback) != c.READOSM_OK) {
        return error.ParseFailed;
    }

    std.debug.print("Found {d} relations of type '{s}' and {d} ways\n", .{ filter.rel_count, filter.route_type, filter.needed_way_ids.count() });
}
