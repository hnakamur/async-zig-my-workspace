const std = @import("std");

pub fn main() !void {
    const message = "Hello world from raw syscall!\n";
    const n = writeToStdout(message);
    std.debug.assert(n == message.len);
}

fn writeToStdout(message: []const u8) isize {
    const msg_ptr = message.ptr;
    const len = message.len;
    return std.c.write(1, msg_ptr, len);
}
