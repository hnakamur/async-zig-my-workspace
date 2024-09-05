const std = @import("std");

pub fn main() !void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = general_purpose_allocator.allocator();

    const address = try std.net.Address.parseIp("127.0.0.1", 8080);
    var net_server = try address.listen(.{ .reuse_address = true, .kernel_backlog = 128 });
    defer net_server.deinit();

    const n_threads = try std.Thread.getCpuCount();
    var server_threads = try std.ArrayList(std.Thread).initCapacity(gpa, n_threads);
    defer server_threads.deinit();
    var request_counter = std.atomic.Value(usize).init(0);
    var i: usize = 0;
    while (i < n_threads) : (i += 1) {
        const server_thread = try std.Thread.spawn(.{}, struct {
            fn run(net_svr: *std.net.Server, counter: *std.atomic.Value(usize)) anyerror!void {
                var header_buffer: [1024]u8 = undefined;

                while (true) {
                    const conn = try net_svr.accept();
                    defer conn.stream.close();

                    var server = std.http.Server.init(conn, &header_buffer);
                    var request = try server.receiveHead();
                    var iter = std.mem.splitScalar(u8, request.head.target, '/');
                    if (iter.next()) |_| {
                        if (iter.next()) |delay_ms_str| {
                            if (iter.next()) |message| {
                                if (std.fmt.parseUnsigned(usize, delay_ms_str, 10)) |delay_ms| {
                                    const count = counter.fetchAdd(1, .seq_cst);
                                    std.debug.print("{} - {}ms: {s}\n", .{ count, delay_ms, message });
                                    std.time.sleep(delay_ms * std.time.ns_per_ms);
                                    try request.respond(message, .{});
                                    continue;
                                } else |_| {
                                    try request.respond("delay must be an unsigned integer: /{delay}/{message}\n", .{
                                        .status = .unprocessable_entity,
                                    });
                                    continue;
                                }
                            }
                        }
                    }
                    try request.respond("Usage: /{delay}/{message}\n", .{
                        .status = .unprocessable_entity,
                    });
                }
            }
        }.run, .{ &net_server, &request_counter });
        try server_threads.append(server_thread);
    }

    i = 0;
    while (i < n_threads) : (i += 1) {
        server_threads.items[i].join();
    }
}
