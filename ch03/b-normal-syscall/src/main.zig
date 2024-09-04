const std = @import("std");
const builtin = @import("builtin");
const native_arch = builtin.cpu.arch;

pub fn main() !void {
    const message = "Hello world from raw syscall!\n";
    const n = writeToStdout(message);
    std.debug.assert(n == message.len);
}

pub const WINAPI: std.builtin.CallingConvention = if (native_arch == .x86)
    .Stdcall
else
    .C;

pub const BOOL = c_int;
pub const DWORD = u32;
pub const HANDLE = *anyopaque;
pub const LPVOID = *anyopaque;

pub extern "kernel32" fn GetStdHandle(
    nStdHandle: DWORD,
) callconv(WINAPI) HANDLE;

pub extern "kernel32" fn WriteConsoleW(
    hConsoleOutput: HANDLE,
    lpBuffer: [*]const u16,
    nNumberOfCharsToWrite: DWORD,
    lpNumberOfCharsWritten: ?*DWORD,
    lpReserved: ?LPVOID,
) callconv(WINAPI) BOOL;

fn writeToStdout(message: []const u8) isize {
    switch (builtin.os.tag) {
        .windows => {
            const handle = GetStdHandle(@bitCast(@as(i32, -11)));
            var utf16le_buf: [256]u16 = undefined;
            if (std.unicode.utf8ToUtf16Le(&utf16le_buf, message)) |len| {
                var output: u32 = undefined;
                const rc = WriteConsoleW(handle, (&utf16le_buf).ptr, @as(DWORD, @intCast(len)), &output, null);
                if (rc == 0) {
                    std.log.err("WriteConsoleW error", .{});
                    return -1;
                }
                return output;
            } else |err| {
                std.log.err("cannot convert message: {s}", .{@errorName(err)});
                return -1;
            }
        },
        else => {
            const msg_ptr = message.ptr;
            const len = message.len;
            return std.c.write(1, msg_ptr, len);
        },
    }
}
