const std = @import("std");

pub fn main() !void {
    std.debug.print("So, we start the program here!\n", .{});

    const t1 = try std.Thread.spawn(.{}, struct {
        fn f() void {
            std.time.sleep(200 * std.time.ns_per_ms);
            std.debug.print("The long running tasks finish last!\n", .{});
        }
    }.f, .{});
    const t2 = try std.Thread.spawn(.{}, struct {
        fn f() void {
            std.time.sleep(100 * std.time.ns_per_ms);
            std.debug.print("We can chain callbacks...\n", .{});
            if (std.Thread.spawn(.{}, struct {
                fn f() void {
                    std.time.sleep(10 * std.time.ns_per_ms);
                    std.debug.print("...like this!\n", .{});
                }
            }.f, .{})) |t3| {
                t3.join();
            } else |err| {
                std.debug.print("caught error: {s}", .{@errorName(err)});
            }
        }
    }.f, .{});
    std.debug.print("The tasks run concurrently!\n", .{});

    t1.join();
    t2.join();
}
