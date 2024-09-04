const std = @import("std");

pub fn main() !void {
    const message = "Hello world from raw syscall!\n";
    const n = writeToStdout(message);
    std.debug.assert(n == message.len);
}

fn writeToStdout(message: []const u8) usize {
    const msg_ptr = message.ptr;
    const len = message.len;
    return asm volatile ("syscall"
        : [ret] "=r" (-> usize),
        : [number] "r" (@intFromEnum(std.os.linux.SYS.write)),
          [arg1] "{rdi}" (1),
          [arg2] "{rsi}" (msg_ptr),
          [arg3] "{rdx}" (len),
    );
}
