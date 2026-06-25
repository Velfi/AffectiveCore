# AffectiveCore Apple

SwiftUI frontend for AffectiveCore. The app shares the same views on iOS and macOS.

The macOS build talks to the existing Zig MCP server over stdio:

```sh
zig build mcp
swift build --package-path apple/AffectiveCore
swift run --package-path apple/AffectiveCore AffectiveCoreApple
```

iOS builds compile the same UI, but local stdio transport intentionally fails with a clear error because iOS cannot launch `affective-core-mcp`. Add a network bridge for `tools/call` before enabling live iOS connections.

The default macOS server path is:

```text
/Users/zelda/Documents/AffectiveCore/zig-out/bin/affective-core-mcp
```

Change it in the connection field if the binary moves.
