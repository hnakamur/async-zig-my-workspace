const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const native_os = builtin.os.tag;

const PollStateTag = enum {
    ready,
    not_ready,
};

const PollState = union(PollStateTag) {
    ready: []const u8,
    not_ready: void,
};

const Future = struct {
    const VTable = struct {
        poll: *const fn (ctx: *anyopaque) PollState,
        destroy: *const fn (ctx: *anyopaque) void,
    };

    ptr: *anyopaque,
    vtable: *const VTable,

    fn poll(self: Future) PollState {
        return self.vtable.poll(self.ptr);
    }

    fn destroy(self: Future) void {
        self.vtable.destroy(self.ptr);
    }
};

const Http = struct {
    fn get(allocator: std.mem.Allocator, path: []const u8) !Future {
        var fut_ptr = try allocator.create(HttpGetFuture);
        fut_ptr.* = HttpGetFuture.new(allocator, path);
        return fut_ptr.future();
    }
};

const HttpGetFuture = struct {
    stream: std.net.Stream,
    buffer: std.ArrayList(u8),
    path: []const u8,

    fn new(allocator: std.mem.Allocator, path: []const u8) HttpGetFuture {
        return HttpGetFuture{
            .stream = .{ .handle = -1 },
            .buffer = std.ArrayList(u8).init(allocator),
            .path = path,
        };
    }

    fn deinit(self: *HttpGetFuture) void {
        self.buffer.deinit();
    }

    fn destroy(ctx: *anyopaque) void {
        var self: *HttpGetFuture = @ptrCast(@alignCast(ctx));
        const allocator = self.buffer.allocator;
        self.deinit();
        allocator.destroy(self);
    }

    fn writeRequest(self: *HttpGetFuture) !void {
        const stream = try tcpConnectToAddressNonBlock(try std.net.Address.parseIp4("127.0.0.1", 8080));
        var req_buf: [256]u8 = undefined;
        const req = formatReq(&req_buf, self.path);
        try stream.writeAll(req);
        self.stream = stream;
    }

    fn future(self: *HttpGetFuture) Future {
        return .{ .ptr = self, .vtable = &.{
            .poll = poll,
            .destroy = destroy,
        } };
    }

    fn poll(ctx: *anyopaque) PollState {
        const self: *HttpGetFuture = @ptrCast(@alignCast(ctx));

        if (self.stream.handle == -1) {
            std.debug.print("FIRST POLL - START OPERATION\n", .{});
            self.writeRequest() catch |err| {
                std.log.err("writeRequest failed: {s}", .{@errorName(err)});
                @panic("panic since we omit error handling");
            };
            return .not_ready;
        }

        var buf = std.ArrayList(u8).initCapacity(self.buffer.allocator, 4096) catch |err| {
            std.log.err("failed to allocate buf: {s}", .{@errorName(err)});
            @panic("panic since we omit error handling");
        };
        buf.appendNTimesAssumeCapacity(0, buf.capacity);
        while (true) {
            if (self.stream.read(buf.items)) |n| {
                if (n == 0) {
                    const s = self.buffer.items[0..self.buffer.items.len];
                    return .{ .ready = s };
                } else {
                    self.buffer.appendSlice(buf.items[0..n]) catch |err| {
                        std.log.err("failed to append slice: {s}", .{@errorName(err)});
                        @panic("panic since we omit error handling");
                    };
                }
            } else |err| {
                switch (err) {
                    error.WouldBlock => return .not_ready,
                    else => {
                        std.log.err("failed to read from connection: {s}", .{@errorName(err)});
                        @panic("panic since we omit error handling");
                    },
                }
            }
        }
    }
};

fn formatReq(dest: []u8, path: []const u8) []u8 {
    const req_fmt = "GET {s} HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Connection: close\r\n" ++
        "\r\n";
    if (std.fmt.bufPrint(dest, req_fmt, .{path})) |ret| {
        return ret;
    } else |err| {
        std.log.err("failed to format request: {s}", .{@errorName(err)});
        @panic("panic since we omit error handling");
    }
}

fn tcpConnectToAddressNonBlock(address: std.net.Address) std.net.TcpConnectToAddressError!std.net.Stream {
    const nonblock = 1;
    const sock_flags = posix.SOCK.STREAM | nonblock |
        (if (native_os == .windows) 0 else posix.SOCK.CLOEXEC);
    const sockfd = try posix.socket(address.any.family, sock_flags, posix.IPPROTO.TCP);
    errdefer std.net.Stream.close(.{ .handle = sockfd });

    try posix.connect(sockfd, &address.any, address.getOsSockLen());

    return std.net.Stream{ .handle = sockfd };
}

const StateTag = enum {
    start,
    wait1,
    wait2,
    resolved,
};

const State = union(StateTag) {
    start: void,
    wait1: Future,
    wait2: Future,
    resolved: void,
};

const Coroutine = struct {
    state: State,
    allocator: std.mem.Allocator,

    fn new(allocator: std.mem.Allocator) Coroutine {
        return .{
            .state = .start,
            .allocator = allocator,
        };
    }

    fn deinit(_: *Coroutine) void {}

    fn poll(ctx: *anyopaque) PollState {
        const self: *Coroutine = @ptrCast(@alignCast(ctx));
        while (true) {
            switch (self.state) {
                .start => {
                    std.debug.print("Program starting\n", .{});
                    const fut1 = Http.get(self.allocator, "/600/HelloWorld1") catch |err| {
                        std.log.err("failed to create HttpGetFuture: {s}", .{@errorName(err)});
                        @panic("panic since we omit error handling");
                    };
                    self.state = .{ .wait1 = fut1 };
                },

                .wait1 => |*fut| switch (fut.poll()) {
                    .ready => |txt| {
                        std.debug.print("{s}\n", .{txt});
                        fut.destroy();
                        const fut2 = Http.get(self.allocator, "/400/HelloWorld2") catch |err| {
                            std.log.err("failed to create HttpGetFuture: {s}", .{@errorName(err)});
                            @panic("panic since we omit error handling");
                        };
                        self.state = .{ .wait2 = fut2 };
                    },
                    .not_ready => return .not_ready,
                },

                .wait2 => |*fut2| switch (fut2.poll()) {
                    .ready => |txt2| {
                        std.debug.print("{s}\n", .{txt2});
                        fut2.destroy();
                        self.state = .resolved;
                        return .{ .ready = "" };
                    },
                    .not_ready => return .not_ready,
                },

                .resolved => @panic("Polled a resolved future"),
            }
        }
    }

    fn destroy(ctx: *anyopaque) void {
        var self: *Coroutine = @ptrCast(@alignCast(ctx));
        self.deinit();
        self.allocator.destroy(self);
    }

    fn future(self: *Coroutine) Future {
        return .{ .ptr = self, .vtable = &.{
            .poll = poll,
            .destroy = destroy,
        } };
    }
};

fn asyncMain(allocator: std.mem.Allocator) !Future {
    var coro_ptr = try allocator.create(Coroutine);
    coro_ptr.* = Coroutine.new(allocator);
    return coro_ptr.future();
}

pub fn main() !void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = general_purpose_allocator.allocator();

    var fut = try asyncMain(gpa);
    defer fut.destroy();
    while (true) {
        switch (fut.poll()) {
            .not_ready => std.debug.print("Schedule other tasks\n", .{}),
            .ready => |_| return,
        }

        // Since we print every poll, slow down the loop
        std.time.sleep(100 * std.time.ns_per_ms);
    }
}
