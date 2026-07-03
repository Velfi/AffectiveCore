const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("setjmp.h");
});

threadlocal var embedded_export_jmp_buf: ?*c.jmp_buf = null;
threadlocal var embedded_export_panic_message: []const u8 = "embedded export panic";

/// Release embedded builds convert panics into a recoverable longjmp at export boundaries.
/// Debug builds keep the default trap behavior for faster iteration.
pub const Panic = std.debug.FullPanic(struct {
    fn panic(msg: []const u8, ret_addr: ?usize) noreturn {
        if (embedded_export_jmp_buf) |buf| {
            embedded_export_panic_message = msg;
            _ = c.longjmp(buf, 1);
        }
        std.debug.defaultPanic(msg, ret_addr);
    }
}.panic);

pub fn panicMessage() []const u8 {
    return embedded_export_panic_message;
}

pub const ExportGuard = struct {
    jmp_buf: c.jmp_buf = undefined,
    panicked: bool = false,
    active: bool = false,

    pub fn init() ExportGuard {
        var guard: ExportGuard = .{};
        if (builtin.mode == .Debug) return guard;
        if (c.setjmp(&guard.jmp_buf) != 0) {
            guard.panicked = true;
            return guard;
        }
        embedded_export_jmp_buf = &guard.jmp_buf;
        guard.active = true;
        return guard;
    }

    pub fn deinit(self: *ExportGuard) void {
        if (self.active) embedded_export_jmp_buf = null;
    }
};
