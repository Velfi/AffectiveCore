const std = @import("std");

/// Appends a random JSON value (bounded depth) for parser fuzzing.
pub fn appendRandomValue(allocator: std.mem.Allocator, out: *std.ArrayList(u8), random: std.Random, depth: usize) std.mem.Allocator.Error!void {
    if (depth == 0) return appendRandomScalar(allocator, out, random);
    switch (random.intRangeLessThan(u8, 0, 8)) {
        0, 1, 2, 3 => try appendRandomScalar(allocator, out, random),
        4, 5 => {
            try out.append(allocator, '[');
            const count = random.intRangeLessThan(usize, 0, 5);
            var i: usize = 0;
            while (i < count) : (i += 1) {
                if (i > 0) try out.append(allocator, ',');
                try appendRandomValue(allocator, out, random, depth - 1);
            }
            try out.append(allocator, ']');
        },
        else => {
            try out.append(allocator, '{');
            const count = random.intRangeLessThan(usize, 0, 5);
            var i: usize = 0;
            while (i < count) : (i += 1) {
                if (i > 0) try out.append(allocator, ',');
                try appendRandomString(allocator, out, random);
                try out.append(allocator, ':');
                try appendRandomValue(allocator, out, random, depth - 1);
            }
            try out.append(allocator, '}');
        },
    }
}

pub fn appendRandomScalar(allocator: std.mem.Allocator, out: *std.ArrayList(u8), random: std.Random) std.mem.Allocator.Error!void {
    switch (random.intRangeLessThan(u8, 0, 10)) {
        0 => try out.appendSlice(allocator, "null"),
        1 => try out.appendSlice(allocator, "true"),
        2 => try out.appendSlice(allocator, "false"),
        3 => try out.print(allocator, "{d}", .{random.int(i64)}),
        4 => try out.print(allocator, "{d}", .{random.int(i32)}),
        5 => try out.appendSlice(allocator, "1.0e308"),
        6 => try out.appendSlice(allocator, "-1.0e309"),
        7 => try out.print(allocator, "{d}", .{random.float(f64) * 2.0e6 - 1.0e6}),
        else => try appendRandomString(allocator, out, random),
    }
}

pub fn appendRandomString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), random: std.Random) std.mem.Allocator.Error!void {
    try out.append(allocator, '"');
    const len = random.intRangeLessThan(usize, 0, 24);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        switch (random.intRangeLessThan(u8, 0, 6)) {
            0 => try out.appendSlice(allocator, "\\u00ff"),
            1 => try out.appendSlice(allocator, "\\n"),
            2 => try out.appendSlice(allocator, "\\\""),
            3 => try out.appendSlice(allocator, "é"),
            else => try out.append(allocator, escapeQuoteCollision(random.intRangeAtMost(u8, 0x20, 0x7e))),
        }
    }
    try out.append(allocator, '"');
}

/// Returns a corrupted copy of `input`: truncated, byte-flipped, or spliced.
pub fn mutate(allocator: std.mem.Allocator, random: std.Random, input: []const u8) std.mem.Allocator.Error![]u8 {
    if (input.len == 0) return allocator.dupe(u8, input);
    switch (random.intRangeLessThan(u8, 0, 3)) {
        0 => {
            const len = random.intRangeLessThan(usize, 1, input.len);
            return allocator.dupe(u8, input[0..len]);
        },
        1 => {
            const copy = try allocator.dupe(u8, input);
            const flips = random.intRangeAtMost(usize, 1, 8);
            var i: usize = 0;
            while (i < flips) : (i += 1) {
                copy[random.intRangeLessThan(usize, 0, copy.len)] = random.int(u8);
            }
            return copy;
        },
        else => {
            var out = try std.ArrayList(u8).initCapacity(allocator, input.len + 16);
            const at = random.intRangeLessThan(usize, 0, input.len);
            out.appendSliceAssumeCapacity(input[0..at]);
            var i: usize = 0;
            const extra = random.intRangeAtMost(usize, 1, 16);
            while (i < extra) : (i += 1) try out.append(allocator, random.int(u8));
            try out.appendSlice(allocator, input[at..]);
            return out.toOwnedSlice(allocator);
        },
    }
}

fn escapeQuoteCollision(byte: u8) u8 {
    return if (byte == '"' or byte == '\\') 'x' else byte;
}
