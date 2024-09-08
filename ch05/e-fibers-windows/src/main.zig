const std = @import("std");
const builtin = @import("builtin");
const WINAPI = std.os.windows.WINAPI;

const DEFAULT_STACK_SIZE = 1024 * 1024 * 2;
const MAX_THREADS = 4;
var RUNTIME: *Runtime = undefined;

const Runtime = struct {
    threads: std.ArrayList(Thread),
    current: usize,

    fn new(allocator: std.mem.Allocator) !Runtime {
        var stack = try std.ArrayListAligned(u8, 16).initCapacity(allocator, DEFAULT_STACK_SIZE);
        stack.appendNTimesAssumeCapacity(0, DEFAULT_STACK_SIZE);
        const base_thread = Thread{
            .id = 0,
            .stack = stack,
            .ctx = undefined,
            .state = .running,
        };

        var threads = try std.ArrayList(Thread).initCapacity(allocator, MAX_THREADS);

        threads.appendAssumeCapacity(base_thread);
        var i: usize = 1;
        while (i < MAX_THREADS) : (i += 1) {
            threads.appendAssumeCapacity(try Thread.new(allocator, i));
        }

        return Runtime{
            .threads = threads,
            .current = 0,
        };
    }

    fn init(self: *Runtime) void {
        RUNTIME = self;
    }

    fn run(self: *Runtime) void {
        while (self.tYield()) {}
        std.process.exit(0);
    }

    fn tReturn(self: *Runtime) void {
        if (self.current != 0) {
            self.threads.items[self.current].state = .available;
            _ = self.tYield();
        }
    }

    noinline fn tYield(self: *Runtime) bool {
        var pos = self.current;
        while (self.threads.items[pos].state != .ready) {
            pos += 1;
            if (pos == self.threads.items.len) {
                pos = 0;
            }
            if (pos == self.current) {
                return false;
            }
        }

        if (self.threads.items[self.current].state != .available) {
            self.threads.items[self.current].state = .ready;
        }

        self.threads.items[pos].state = .running;
        const old_pos = self.current;
        self.current = pos;

        const old_ctx = &self.threads.items[old_pos].ctx;
        const new_ctx = &self.threads.items[pos].ctx;
        switch (builtin.os.tag) {
            .linux => asm volatile (
                \\ call %[tSwitch:P]
                :
                : [tSwitch] "X" (&tSwitch),
                  [arg1] "{rdi}" (old_ctx),
                  [arg2] "{rsi}" (new_ctx),
            ),
            .windows => asm volatile (
                \\ call %[tSwitch:P]
                :
                : [tSwitch] "X" (&tSwitch),
                  [arg1] "{rcx}" (old_ctx),
                  [arg2] "{rdx}" (new_ctx),
                : "rax"
            ),
            else => @panic("unsupported platform"),
        }

        return self.threads.items.len > 0;
    }

    fn spawn(self: *Runtime, f: *const fn () void) !void {
        var i: usize = 0;
        while (i < self.threads.items.len) : (i += 1) {
            if (self.threads.items[i].state == .available) {
                break;
            }
        }
        if (i == self.threads.items.len) {
            return error.NoAvailableThread;
        }
        const available: *Thread = &self.threads.items[i];
        const size = available.stack.items.len;

        const index = ((@intFromPtr(available.stack.items.ptr) + size) & ~@as(usize, 15)) - @intFromPtr(available.stack.items.ptr);
        std.mem.writeInt(u64, available.stack.items[index - 16 ..][0..8], @intFromPtr(&guard), .little);
        std.mem.writeInt(u64, available.stack.items[index - 24 ..][0..8], @intFromPtr(&skip), .little);
        std.mem.writeInt(u64, available.stack.items[index - 32 ..][0..8], @intFromPtr(f), .little);
        available.ctx.rsp = @intFromPtr(&available.stack.items[index - 32]);

        // see: https://docs.microsoft.com/en-us/cpp/build/stack-usage?view=vs-2019#stack-allocation
        if (builtin.os.tag == .windows) {
            available.ctx.stack_start = @intFromPtr(available.stack.items.ptr) + index;
            available.ctx.stack_end = @intFromPtr(available.stack.items.ptr);
        }

        available.state = .ready;
    }
};

fn skip() callconv(.Naked) void {
    asm volatile ("ret");
}

fn guard() void {
    RUNTIME.tReturn();
}

fn yieldThread() void {
    _ = RUNTIME.tYield();
}

const State = enum {
    available,
    running,
    ready,
};

const Thread = struct {
    id: usize,
    stack: std.ArrayListAligned(u8, 16),
    ctx: ThreadContext,
    state: State,

    fn new(allocator: std.mem.Allocator, id: usize) !Thread {
        var stack = try std.ArrayListAligned(u8, 16).initCapacity(allocator, DEFAULT_STACK_SIZE);
        stack.appendNTimesAssumeCapacity(0, DEFAULT_STACK_SIZE);
        return Thread{
            .id = id,
            .stack = stack,
            .ctx = undefined,
            .state = .available,
        };
    }
};

const ThreadContext = switch (builtin.os.tag) {
    .linux => struct {
        rsp: u64,
        r15: u64,
        r14: u64,
        r13: u64,
        r12: u64,
        rbx: u64,
        rbp: u64,
    },
    .windows => struct {
        xmm6: [2]u64,
        xmm7: [2]u64,
        xmm8: [2]u64,
        xmm9: [2]u64,
        xmm10: [2]u64,
        xmm11: [2]u64,
        xmm12: [2]u64,
        xmm13: [2]u64,
        xmm14: [2]u64,
        xmm15: [2]u64,
        rsp: u64,
        r15: u64,
        r14: u64,
        r13: u64,
        r12: u64,
        rbx: u64,
        rbp: u64,
        rdi: u64,
        rsi: u64,
        stack_start: u64,
        stack_end: u64,
    },
    else => @panic("unsupported platform"),
};

export fn tSwitch() callconv(.Naked) void {
    switch (builtin.os.tag) {
        .linux => asm volatile (
            \\ movq %rsp, 0x00(%rdi)
            \\ movq %r15, 0x08(%rdi)
            \\ movq %r14, 0x18(%rdi)
            \\ movq %r13, 0x20(%rdi)
            \\ movq %rbx, 0x28(%rdi)
            \\ movq %rbp, 0x30(%rdi)
            \\ movq 0x00(%rsi), %rsp
            \\ movq 0x08(%rsi), %r15
            \\ movq 0x18(%rsi), %r14
            \\ movq 0x20(%rsi), %r13
            \\ movq 0x28(%rsi), %rbx
            \\ movq 0x30(%rsi), %rbp
            \\ ret
            ::: "rsp", "r15", "r14", "r13", "rbx", "rbp"),
        .windows => asm volatile (
            \\ movaps %xmm6, 0x00(%rcx)
            \\ movaps %xmm7, 0x10(%rcx)
            \\ movaps %xmm8, 0x20(%rcx)
            \\ movaps %xmm9, 0x30(%rcx)
            \\ movaps %xmm10, 0x40(%rcx)
            \\ movaps %xmm11, 0x50(%rcx)
            \\ movaps %xmm12, 0x60(%rcx)
            \\ movaps %xmm13, 0x70(%rcx)
            \\ movaps %xmm14, 0x80(%rcx)
            \\ movaps %xmm15, 0x90(%rcx)
            \\ movq %rsp, 0xa0(%rcx)
            \\ movq %r15, 0xa8(%rcx)
            \\ movq %r14, 0xb0(%rcx)
            \\ movq %r13, 0xb8(%rcx)
            \\ movq %r12, 0xc0(%rcx)
            \\ movq %rbx, 0xc8(%rcx)
            \\ movq %rbp, 0xd0(%rcx)
            \\ movq %rdi, 0xd8(%rcx)
            \\ movq %rsi, 0xe0(%rcx)
            \\ movq %%gs:0x08, %rax
            \\ movq %rax, 0xe8(%rcx)
            \\ movq %%gs:0x10, %rax
            \\ movq %rax, 0xf0(%rcx)
            \\ movaps 0x00(%rdx), %xmm6
            \\ movaps 0x10(%rdx), %xmm7
            \\ movaps 0x20(%rdx), %xmm8
            \\ movaps 0x30(%rdx), %xmm9
            \\ movaps 0x40(%rdx), %xmm10
            \\ movaps 0x50(%rdx), %xmm11
            \\ movaps 0x60(%rdx), %xmm12
            \\ movaps 0x70(%rdx), %xmm13
            \\ movaps 0x80(%rdx), %xmm14
            \\ movaps 0x90(%rdx), %xmm15
            \\ movq 0xa0(%rdx), %rsp
            \\ movq 0xa8(%rdx), %r15
            \\ movq 0xb0(%rdx), %r14
            \\ movq 0xb8(%rdx), %r13
            \\ movq 0xc0(%rdx), %r12
            \\ movq 0xc8(%rdx), %rbx
            \\ movq 0xd0(%rdx), %rbp
            \\ movq 0xd8(%rdx), %rdi
            \\ movq 0xe0(%rdx), %rsi
            \\ movq 0xe8(%rdx), %rax
            \\ movq %rax, %%gs:0x08
            \\ movq 0xf0(%rdx), %rax
            \\ movq %rax, %%gs:0x10
            \\ ret
            ::: "rax"),
        else => @panic("unsupported platform"),
    }
}

pub fn main() !void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = general_purpose_allocator.allocator();

    var runtime = try Runtime.new(gpa);
    runtime.init();

    try runtime.spawn(struct {
        fn f() void {
            std.debug.print("THREAD 1 STARTING\n", .{});
            const id = 1;
            var i: usize = 0;
            while (i < 10) : (i += 1) {
                std.debug.print("thread: {} counter: {}\n", .{ id, i });
                yieldThread();
            }
            std.debug.print("THREAD 1 FINISHED\n", .{});
        }
    }.f);

    try runtime.spawn(struct {
        fn f() void {
            std.debug.print("THREAD 2 STARTING\n", .{});
            const id = 2;
            var i: usize = 0;
            while (i < 15) : (i += 1) {
                std.debug.print("thread: {} counter: {}\n", .{ id, i });
                yieldThread();
            }
            std.debug.print("THREAD 2 FINISHED\n", .{});
        }
    }.f);

    runtime.run();
}
