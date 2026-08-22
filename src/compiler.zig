pub fn compile(source: [:0]const u8) !void {
    _ = source;
}

test "compiler" {
    try testCompiler(
        \\ print 1 + 2;
        \\
    ,
        \\   1 31 'print'
        \\   | 21 '1'
        \\   |  7 '+'
        \\   | 21 '2'
        \\   |  8 ';'
        \\   2 39 ''
        \\
    );
}

fn testCompiler(source: [:0]const u8, expected: []const u8) !void {
    const gpa = testing.allocator;

    var stream: Io.Writer.Allocating = .init(gpa);
    defer stream.deinit();

    const writer = &stream.writer;

    var scanner: tokenizer.Scanner = .init(source);

    var line: u32 = 0;
    while (true) {
        const token = scanner.next();
        if (line != token.line) {
            try writer.print("{d:>4} ", .{token.line});
            line = token.line;
        } else {
            try writer.print("   | ", .{});
        }
        try writer.print("{d:2} '{s}'\n", .{ token.tag, token.lexeme(source) });

        if (token.tag == .eof) break;
    }

    try testing.expectEqualSlices(u8, expected, stream.written());
}

const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const Allocator = mem.Allocator;
const Io = std.Io;

const tokenizer = @import("tokenizer.zig");
