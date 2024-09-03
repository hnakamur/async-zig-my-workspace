const std = @import("std");

pub fn main() !void {
    const t = @as(usize, 100);
    const ptr: *const usize = &t;
    // const ptr: *const usize = @ptrFromInt(16);
    const x = dereference(ptr);
    std.debug.print("ptr={}, x={}\n", .{ @intFromPtr(ptr), x });
}

fn dereference(ptr: *const usize) usize {
    return asm ("movq (%[ptr]), %[ret]"
        : [ret] "=r" (-> usize),
        : [ptr] "r" (@intFromPtr(ptr)),
    );
}
