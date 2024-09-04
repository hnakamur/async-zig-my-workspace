const std = @import("std");
const builtin = @import("builtin");

pub fn main() !void {
    const message = "Hello world from raw syscall!\n";
    const n = writeToStdout(message);
    std.debug.assert(n == message.len);
}

fn writeToStdout(message: []const u8) usize {
    const msg_ptr = message.ptr;
    const len = message.len;
    switch (builtin.os.tag) {
        .linux => {
            switch (builtin.target.cpu.arch) {
                .x86_64 => {
                    return asm volatile ("syscall"
                        : [ret] "=r" (-> usize),
                        : [number] "r" (@intFromEnum(std.os.linux.SYS.write)),
                          [arg1] "{rdi}" (1),
                          [arg2] "{rsi}" (msg_ptr),
                          [arg3] "{rdx}" (len),
                    );
                },
                else => @panic("unsupported target cpu arch"),
            }
        },
        .macos, .ios, .watchos, .tvos, .visionos => {
            switch (builtin.target.cpu.arch) {
                .aarch64 => {
                    return asm volatile (
                        \\ mov x16, 4
                        \\ mov x0, 1
                        \\ svc 0
                        : [ret] "=r" (-> usize),
                        : [arg2] "{x1}" (msg_ptr),
                          [arg3] "{x2}" (len),
                    );
                },
                else => @panic("unsupported target cpu arch"),
            }
        },
        else => {},
    }
}
