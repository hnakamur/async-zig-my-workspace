const std = @import("std");

const DEFAULT_STACK_SIZE = 1024 * 1024 * 2;
const MAX_THREADS = 4;
var RUNTIME: *Runtime = undefined;

const Runtime = struct {
    threads: std.ArrayList(Thread),
    current: usize,

    fn new(allocator: std.mem.Allocator) !Runtime {
        const base_thread = Thread{
            .id = 0,
            .stack = try std.ArrayList(u8).initCapacity(allocator, DEFAULT_STACK_SIZE),
            .ctx = undefined,
            .state = .running,
            .task = null,
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
        asm volatile (
            \\ call %[tSwitch:P]
            :
            : [tSwitch] "X" (&tSwitch),
              [arg1] "{rdi}" (old_ctx),
              [arg2] "{rsi}" (new_ctx),
        );

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
        available.task = f;
        available.ctx.thread_ptr = @intFromPtr(available);
        std.mem.writeInt(u64, available.stack.items[index - 16 ..][0..8], @intFromPtr(&guard), .little);
        std.mem.writeInt(u64, available.stack.items[index - 24 ..][0..8], @intFromPtr(&skip), .little);
        std.mem.writeInt(u64, available.stack.items[index - 32 ..][0..8], @intFromPtr(&call), .little);
        available.ctx.rsp = @intFromPtr(&available.stack.items[index - 32]);

        available.state = .ready;
    }
};

fn call(thread: u64) void {
    const thread_ptr: *Thread = @ptrFromInt(thread);
    if (thread_ptr.task) |task| {
        task();
        thread_ptr.task = null;
    }
}

fn guard() void {
    std.debug.print("THREAD {} FINISHED.\n", .{RUNTIME.threads.items[RUNTIME.current].id});
    RUNTIME.tReturn();
}

fn skip() callconv(.Naked) void {
    asm volatile ("ret");
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
    stack: std.ArrayList(u8),
    ctx: ThreadContext,
    state: State,
    task: ?*const fn () void,

    fn new(allocator: std.mem.Allocator, id: usize) !Thread {
        var stack = try std.ArrayList(u8).initCapacity(allocator, DEFAULT_STACK_SIZE);
        stack.appendNTimesAssumeCapacity(0, DEFAULT_STACK_SIZE);
        return Thread{
            .id = id,
            .stack = stack,
            .ctx = undefined,
            .state = .available,
            .task = null,
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
    thread_ptr: u64,
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
        \\ movq 0x38(%rsi), %rdi
        \\ ret
        ::: "rsp", "r15", "r14", "r13", "rbx", "rbp", "rdi");
}

pub fn main() !void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = general_purpose_allocator.allocator();

    var runtime = try Runtime.new(gpa);
    runtime.init();

    try runtime.spawn(struct {
        fn f() void {
            std.debug.print("I haven't implemented a timer in this example.\n", .{});
            yieldThread();
            std.debug.print("Finally, notice how the tasks are executed concurrently.\n", .{});
        }
    }.f);

    try runtime.spawn(struct {
        fn f() void {
            std.debug.print("But we can still nest tasks...\n", .{});
            RUNTIME.spawn(struct {
                fn f() void {
                    std.debug.print("...like this!\n", .{});
                }
            }.f) catch |err| {
                std.log.err("spawn failed: {s}.\n", .{@errorName(err)});
            };
        }
    }.f);

    runtime.run();
}
