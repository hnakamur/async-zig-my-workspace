const std = @import("std");

pub fn main() !void {
    const address = try std.net.Address.parseIp("127.0.0.1", 8080);
    var net_server = try address.listen(.{ .reuse_address = true });
    defer net_server.deinit();
    const server_thread = try std.Thread.spawn(.{}, struct {
        fn run(net_svr: *std.net.Server) anyerror!void {
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
    }.run, .{&net_server});
    defer server_thread.join();
}
