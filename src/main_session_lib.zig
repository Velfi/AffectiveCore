//! Root module for libaffective-core-session.a. Forces analysis of the BSP
//! session shim exports (affective_session_start/stop) without exporting the
//! CLI entry point, so hosts can link the archive into their own executable.
comptime {
    _ = @import("main_session.zig");
}
