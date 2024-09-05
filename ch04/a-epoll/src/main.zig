const std = @import("std");
const builtin = @import("builtin");
const native_os = builtin.os.tag;
const posix = std.posix;
const poll = @import("poll.zig");

const HandledIdMap = std.AutoHashMap(usize, void);

fn handle_events(events: []poll.Event, streams: []std.net.Stream, handled: *HandledIdMap) !usize {
    var handled_events: usize = 0;
    for (events) |*event| {
        const index = event.data.u64;
        var data: [4096]u8 = undefined;

        while (true) {
            if (streams[index].read(&data)) |n| {
                if (n == 0) {
                    const res = try handled.getOrPut(index);
                    if (res.found_existing) {
                        break;
                    }
                    handled_events += 1;
                    break;
                } else {
                    const txt = data[0..n];
                    std.log.debug("RECEIVED: {}\n{s}\n------\n", .{ index, txt });
                }
            } else |err| {
                switch (err) {
                    error.WouldBlock => break,
                    else => return err,
                }
            }
        }
    }
    return handled_events;
}

pub fn tcpConnectToAddressNonBlock(address: std.net.Address) std.net.TcpConnectToAddressError!std.net.Stream {
    const nonblock = 1;
    const sock_flags = posix.SOCK.STREAM | nonblock |
        (if (native_os == .windows) 0 else posix.SOCK.CLOEXEC);
    const sockfd = try posix.socket(address.any.family, sock_flags, posix.IPPROTO.TCP);
    errdefer std.net.Stream.close(.{ .handle = sockfd });

    try posix.connect(sockfd, &address.any, address.getOsSockLen());

    return std.net.Stream{ .handle = sockfd };
}

pub fn main() !void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = general_purpose_allocator.allocator();

    const n_events = 5;

    const address = try std.net.Address.parseIp4("127.0.0.1", 8080);

    var pl = try poll.Poll.init();
    defer pl.deinit();

    var req_buf: [256]u8 = undefined;
    const req_fmt = "GET {s} HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Connection: close\r\n" ++
        "\r\n";
    var url_path_buf: [64]u8 = undefined;
    var events: [n_events]poll.Event = undefined;
    var streams: [n_events]std.net.Stream = undefined;
    var i: usize = 0;
    while (i < n_events) : (i += 1) {
        const delay = (n_events - i) * 1000;
        const url_path = try std.fmt.bufPrint(&url_path_buf, "/{}/request-{}", .{ delay, i });
        const request = try std.fmt.bufPrint(&req_buf, req_fmt, .{url_path});
        streams[i] = try std.net.tcpConnectToAddress(address);
        try streams[i].writeAll(request);

        events[i] = .{
            .events = poll.IN | poll.ET,
            .data = .{ .u64 = i },
        };
        try pl.registry.register(&streams[i], &events[i]);
    }

    var handled_ids = HandledIdMap.init(gpa);
    defer handled_ids.deinit();

    var handled_events: usize = 0;
    while (handled_events < n_events) {
        var polled_events: [n_events]poll.Event = undefined;
        const n_polled_events = pl.poll(&polled_events, null);
        if (n_polled_events == 0) {
            std.log.debug("TIMEOUT (OR SPURIOUS EVENT NOTIFICATION)\n", .{});
            continue;
        }
        handled_events += try handle_events(polled_events[0..n_polled_events], &streams, &handled_ids);
    }

    std.log.debug("FINISHED\n", .{});
}
