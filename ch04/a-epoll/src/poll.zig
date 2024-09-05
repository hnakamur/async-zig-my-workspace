const std = @import("std");
const posix = std.posix;
const system = posix.system;
const EPOLL = std.os.linux.EPOLL;

pub const Event = system.epoll_event;
pub const IN = EPOLL.IN;
pub const ET = EPOLL.ET;

pub const Poll = struct {
    registry: Registry,

    pub fn init() !Poll {
        const raw_fd = try posix.epoll_create1(0);
        return Poll{
            .registry = Registry{ .raw_fd = raw_fd },
        };
    }

    pub fn deinit(self: *Poll) void {
        self.registry.deinit();
    }

    pub fn poll(self: *Poll, events: []Event, timeout_milliseconds: ?i32) usize {
        const timeout = if (timeout_milliseconds) |ms| ms else -1;
        return posix.epoll_wait(self.registry.raw_fd, events, timeout);
    }
};

pub const Registry = struct {
    raw_fd: i32,

    pub fn register(self: *Registry, source: *std.net.Stream, event: *Event) !void {
        return posix.epoll_ctl(self.raw_fd, EPOLL.CTL_ADD, source.handle, event);
    }

    pub fn deinit(self: *Registry) void {
        posix.close(self.raw_fd);
    }
};
