const std = @import("std");

// This is the minimum size that worked.
// When I changed to a smaller value, Segmentation fault (core dumped)
// occurred with no output from hello function.
const SSIZE = 1024 + 256 + 16;

const ThreadContext = struct {
    rsp: u64,
};

fn hello() void {
    std.debug.print("I LOVE WAKING UP ON A NEW STACK!\n", .{});
    while (true) {
        std.time.sleep(std.time.ns_per_s);
        std.debug.print(".", .{});
    }
}

fn gtSwitch(new: *const ThreadContext) void {
    asm volatile (
        \\ movq (%[arg1]), %rsp
        \\ ret
        :
        : [arg1] "r" (new),
        : "rsp"
    );
}

pub fn main() !void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = general_purpose_allocator.allocator();

    var ctx: ThreadContext = undefined;
    var stack = try gpa.alignedAlloc(u8, 16, SSIZE);
    defer gpa.free(stack);

    @memset(stack, 0);
    const index = ((@intFromPtr(stack.ptr) + SSIZE) & ~@as(usize, 15)) - @intFromPtr(stack.ptr) - 16;
    std.debug.print("&stack[sb_aligned_index]=0x{x}\n", .{@intFromPtr(stack.ptr) + index});
    std.mem.writeInt(u64, stack[index..][0..8], @intFromPtr(&hello), .little);
    ctx.rsp = @intFromPtr(&stack[index]);
    gtSwitch(&ctx);
}
