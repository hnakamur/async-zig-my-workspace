const std = @import("std");

const DEFAULT_STACK_SIZE = 1024 * 1024 * 2;
const MAX_THREADS = 4;
var RUNTIME: usize = 0;

const Runtime = struct {
    threads: std.ArrayList(Thread),
    current: usize,

    fn new(allocator: std.mem.Allocator) !Runtime {
        const base_thread = Thread{
            .stack = try std.ArrayList(u8).initCapacity(allocator, DEFAULT_STACK_SIZE),
            .ctx = undefined,
            .state = .running,
        };

        var threads = try std.ArrayList(Thread).initCapacity(allocator, MAX_THREADS);

        threads.appendAssumeCapacity(base_thread);
        var i: usize = 1;
        while (i < MAX_THREADS) : (i += 1) {
            threads.appendAssumeCapacity(try Thread.new(allocator));
        }

        return Runtime{
            .threads = threads,
            .current = 0,
        };
    }

    fn init(self: *const Runtime) void {
        RUNTIME = @intFromPtr(self);
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
        asm volatile (
            \\ call %[tSwitch:P]
            :
            : [tSwitch] "X" (&tSwitch),
              [arg1] "{rdi}" (old_ctx),
              [arg2] "{rsi}" (new_ctx),
        );

        return self.threads.items.len > 0;
    }

    fn spawn(self: *Runtime, f: fn () void) !void {
        var i: usize = 0;
        while (i < self.threads.items.len) : (i += 1) {
            if (self.threads.items[i].state == .available) {
                break;
            }
        }
        if (i == self.threads.items.len) {
            return error.NoAvailableThread;
        }
        const available = &self.threads.items[i];
        const size = available.stack.items.len;

        const index = ((@intFromPtr(available.stack.items.ptr) + size) & ~@as(usize, 15)) - @intFromPtr(available.stack.items.ptr);
        std.mem.writeInt(u64, available.stack.items[index - 16 ..][0..8], @intFromPtr(&guard), .little);
        std.mem.writeInt(u64, available.stack.items[index - 24 ..][0..8], @intFromPtr(&skip), .little);
        std.mem.writeInt(u64, available.stack.items[index - 32 ..][0..8], @intFromPtr(&f), .little);
        available.ctx.rsp = @intFromPtr(&available.stack.items[index - 32]);

        available.state = .ready;
    }
};

fn guard() void {
    const rt_ptr: *Runtime = @ptrFromInt(RUNTIME);
    rt_ptr.tReturn();
}

fn skip() callconv(.Naked) void {
    asm volatile ("ret");
}

fn yieldThread() void {
    const rt_ptr: *Runtime = @ptrFromInt(RUNTIME);
    _ = rt_ptr.tYield();
}

const State = enum {
    available,
    running,
    ready,
};

const Thread = struct {
    stack: std.ArrayList(u8),
    ctx: ThreadContext,
    state: State,

    fn new(allocator: std.mem.Allocator) !Thread {
        var stack = try std.ArrayList(u8).initCapacity(allocator, DEFAULT_STACK_SIZE);
        stack.appendNTimesAssumeCapacity(0, DEFAULT_STACK_SIZE);
        return Thread{
            .stack = stack,
            .ctx = undefined,
            .state = .available,
        };
    }
};

const ThreadContext = struct {
    rsp: u64,
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    rbx: u64,
    rbp: u64,
};

export fn tSwitch() callconv(.Naked) void {
    asm volatile (
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
        ::: "rsp", "r15", "r14", "r13", "rbx", "rbp");
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
