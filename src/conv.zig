const std = @import("std");
const zillconv = @import("zillconv");

fn usage() void {
    std.debug.print("usage: zillconv [--geotiff <path>] [--osm <path>] [-o <path>]\n", .{});
}

pub fn main(init: std.process.Init) !void {
    var options: zillconv.Options = .{};
    var args = init.minimal.args.iterate();
    _ = args.next(); // program name
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            usage();
            return;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            options.output_path = args.next() orelse return error.InvalidArguments;
        } else if (std.mem.eql(u8, arg, "--geotiff")) {
            options.geotiff_path = args.next() orelse return error.InvalidArguments;
        } else if (std.mem.eql(u8, arg, "--osm")) {
            options.osm_path = args.next() orelse return error.InvalidArguments;
        } else {
            usage();
            return error.InvalidArguments;
        }
    }
    try zillconv.generate(init.gpa, init.io, options);
}
