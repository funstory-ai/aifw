const std = @import("std");
const core = @import("aifw_core");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var session = try core.Session.init(allocator);
    defer session.deinit();

    const input = "Hi, my email is example.test@funstory.com";
    const out_mask = session.getPipeline(.mask).run(input, allocator);
    const out_restore = session.getPipeline(.restore).run(input, allocator);

    std.debug.print("mask={s} restore={s}\n", .{ out_mask, out_restore });
}
