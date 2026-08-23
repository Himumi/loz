pub fn compile(gpa: Allocator, ctx: *Context, source: [:0]const u8) CompilerError!Chunk {
    var compiler: Compiler = .init(source);
    return compiler.compile(gpa, ctx);
}

const CompilerError = Allocator.Error || Io.Writer.Error || fmt.ParseFloatError;

const Compiler = struct {
    source: [:0]const u8,
    /// Borrow from the caller.
    ctx: *Context,
    /// Borrow from the caller.
    chunk: *Chunk,
    scanner: Scanner,

    current: Token,
    previous: Token,

    had_error: bool,
    panic_mode: bool,

    pub const Precedence = enum(u8) {
        none,
        assignment,
        @"or",
        @"and",
        equality,
        comparison,
        term,
        factor,
        unary,
        call,
        primary,
    };

    pub const Rule = struct {
        prefix: Kind = .null,
        infix: Kind = .null,
        precedence: Precedence = .none,

        pub const empty: Rule = .{
            .prefix = .null,
            .infix = .null,
            .precedence = .none,
        };

        pub const Kind = enum { null, number, group, unary, binary };
    };

    const RuleList = std.EnumArray(Token.Tag, Rule);

    pub fn init(source: [:0]const u8) Compiler {
        return .{
            .source = source,
            .ctx = undefined,

            .chunk = undefined,
            .scanner = .init(source),

            .current = undefined,
            .previous = undefined,

            .had_error = false,
            .panic_mode = false,
        };
    }

    pub fn compile(self: *Compiler, gpa: Allocator, ctx: *Context) CompilerError!Chunk {
        // Initialize the chunk here to prevent mismatching memory ownership.
        var chunk: Chunk = .empty;
        errdefer chunk.deinit(gpa);

        // Borrow the chunk memory.
        self.chunk = &chunk;
        // Borrow the context memory.
        self.ctx = ctx;

        // Make sure to false at start up.
        self.had_error = false;
        self.panic_mode = false;

        // Add the first token.
        try self.advance();

        // Compile one expression.
        try self.expression(gpa);
        try self.consume(.eof, "Expect end of expression.");

        try self.emitReturn(gpa);
        // if (!self.had_error) {
        // }

        // The caller ownes the ownership.
        return chunk;
    }

    fn expression(self: *Compiler, gpa: Allocator) CompilerError!void {
        try self.parsePrecedence(gpa, .assignment);
    }

    fn parsePrecedence(self: *Compiler, gpa: Allocator, precedence: Precedence) CompilerError!void {
        try self.advance();

        const prefix_rule = rules.get(self.previous.tag).prefix;
        if (prefix_rule == .null) {
            return try self.report("Expect Expression.");
        }

        try self.parseRule(gpa, prefix_rule);

        while (true) {
            const prece_int = @intFromEnum(precedence);
            const curr_prece_int = @intFromEnum(rules.get(self.current.tag).precedence);

            if (prece_int > curr_prece_int) break;
            try self.advance();

            const infix_rule = rules.get(self.previous.tag).infix;
            try self.parseRule(gpa, infix_rule);
        }
    }

    fn parseRule(self: *Compiler, gpa: Allocator, rule: Rule.Kind) CompilerError!void {
        return switch (rule) {
            .number => try self.number(gpa),
            .group => try self.grouping(gpa),
            .binary => try self.binary(gpa),
            .unary => try self.unary(gpa),
            .null => {},
        };
    }

    fn number(self: *Compiler, gpa: Allocator) CompilerError!void {
        const value = try fmt.parseFloat(Value, self.previous.lexeme(self.source));
        try self.emitConstant(gpa, value);
    }

    fn grouping(self: *Compiler, gpa: Allocator) CompilerError!void {
        try self.expression(gpa);
        try self.consume(.r_paren, "Expect ')' after expression.");
    }

    fn unary(self: *Compiler, gpa: Allocator) CompilerError!void {
        const operator_tag = self.previous.tag;

        try self.parsePrecedence(gpa, .unary);

        switch (operator_tag) {
            .minus => try self.emitByte(gpa, .negate),
            else => return,
        }
    }

    fn binary(self: *Compiler, gpa: Allocator) CompilerError!void {
        const operator_tag = self.previous.tag;

        const rule = rules.get(operator_tag);
        const precedence_int = @intFromEnum(rule.precedence);

        // Need to higher up the precedence.
        const next_precedence: Precedence = @enumFromInt(precedence_int + 1);
        try self.parsePrecedence(gpa, next_precedence);

        switch (operator_tag) {
            .plus => try self.emitByte(gpa, .add),
            .minus => try self.emitByte(gpa, .subtract),
            .star => try self.emitByte(gpa, .multiply),
            .slash => try self.emitByte(gpa, .divide),
            else => return,
        }
    }

    fn advance(self: *Compiler) Io.Writer.Error!void {
        self.previous = self.current;

        while (true) {
            self.current = self.scanner.next();
            if (self.current.tag != .invalid) break;
            // NOTE: Create invalid token validator.
            try self.errorAt(self.current, "Invalid token.");
        }
    }

    fn errorAt(self: *Compiler, token: Token, message: []const u8) Io.Writer.Error!void {
        if (self.panic_mode) return;
        self.panic_mode = true;

        // TODO: Use Global Context for stderr.
        try self.ctx.stream.err.print("[line {}] Error", .{token.line});

        switch (token.tag) {
            .eof => try self.ctx.stream.err.print(" at end", .{}),
            .invalid => {
                // Nothing
            },
            else => try self.ctx.stream.err.print(" at '{s}'", .{token.lexeme(self.source)}),
        }

        try self.ctx.stream.err.print(": {s}\n", .{message});
        self.had_error = true;
    }

    fn report(self: Compiler, message: []const u8) Io.Writer.Error!void {
        try self.ctx.stream.err.print("{s}\n", .{message});
    }

    fn consume(self: *Compiler, tag: Token.Tag, message: []const u8) Io.Writer.Error!void {
        if (self.current.tag == tag) {
            return try self.advance();
        }
        try self.errorAt(self.current, message);
    }

    fn emitByte(self: *Compiler, gpa: Allocator, code: Chunk.OpCode) Allocator.Error!void {
        try self.chunk.writeChunk(gpa, code, self.previous.line);
    }

    fn emitConstant(
        self: *Compiler,
        gpa: Allocator,
        value: Value,
    ) (Allocator.Error || Io.Writer.Error)!void {
        const value_index = try self.makeConstant(gpa, value);
        try self.chunk.writeConstant(gpa, value_index, self.previous.line);
    }

    fn emitReturn(self: *Compiler, gpa: Allocator) Allocator.Error!void {
        try self.emitByte(gpa, .@"return");
    }

    fn endCompiler(self: *Compiler, gpa: Allocator) Allocator.Error!void {
        try self.emitReturn(gpa);
    }

    fn makeConstant(
        self: *Compiler,
        gpa: Allocator,
        value: Value,
    ) (Allocator.Error || Io.Writer.Error)!u32 {
        const index = try self.chunk.addValue(gpa, value);
        if (index > 256) {
            try self.report("Too many constants in one chunk");
            return 0;
        }
        return index;
    }

    const rules: RuleList = .initDefault(Rule.empty, .{
        .l_paren = .{
            .prefix = .group,
            .infix = .null,
            .precedence = .none,
        },
        .plus = .{
            .prefix = .null,
            .infix = .binary,
            .precedence = .term,
        },
        .minus = .{
            .prefix = .unary,
            .infix = .binary,
            .precedence = .term,
        },
        .slash = .{
            .prefix = .null,
            .infix = .binary,
            .precedence = .factor,
        },
        .star = .{
            .prefix = .null,
            .infix = .binary,
            .precedence = .factor,
        },
        .number = .{
            .prefix = .number,
            .infix = .null,
            .precedence = .none,
        },
    });
};

test "compiler" {
    const gpa = testing.allocator;
    const source = "1 + 2 * 3";

    var stream: Io.Writer.Allocating = .init(gpa);
    defer stream.deinit();

    var ctx: Context = .init(undefined, .{ .out = &stream.writer, .err = &stream.writer });

    var vm: VM = .empty;
    defer vm.deinit(gpa);

    try vm.interpret(gpa, &ctx, source);
    try testing.expectEqualSlices(u8, "7", stream.written());

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
const fmt = std.fmt;
const testing = std.testing;

const Allocator = mem.Allocator;
const Io = std.Io;

const tokenizer = @import("tokenizer.zig");
const Chunk = @import("Chunk.zig");
const Context = @import("Context.zig");
const VM = @import("VM.zig");
const Scanner = tokenizer.Scanner;
const Token = tokenizer.Token;
const Value = Chunk.Value;
