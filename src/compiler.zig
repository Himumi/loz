pub fn compile(
    gpa: Allocator,
    ctx: *Context,
    strings: *Strings,
    source: [:0]const u8,
) CompilerError!Chunk {
    var compiler: Compiler = .init(source, strings);
    return compiler.compile(gpa, ctx);
}

pub const CompilerError =
    Compiler.Error ||
    Allocator.Error ||
    Io.Writer.Error;

pub const Compiler = struct {
    /// Borrow from the caller.
    strings: *Strings,
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

    // TODO: Need a better error message.
    pub const Error = error{
        InvalidToken,
        ExpectedExpression,
        ExpectedLeftParen,
        TooManyConstants,
        InvalidCharacter,
    };

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

        pub const Kind = enum {
            null,
            number,
            string,
            group,
            unary,
            binary,
            literal,
        };
    };

    const RuleList = std.EnumArray(Token.Tag, Rule);

    pub fn init(source: [:0]const u8, strings: *Strings) Compiler {
        return .{
            .strings = strings,
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

    pub fn compile(
        self: *Compiler,
        gpa: Allocator,
        ctx: *Context,
    ) CompilerError!Chunk {
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
            try self.errorAt(self.previous, "Expect Expression.");
            return error.ExpectedExpression;
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
            .literal => try self.literal(gpa),
            .number => try self.number(gpa),
            .string => try self.string(gpa),
            .group => try self.grouping(gpa),
            .binary => try self.binary(gpa),
            .unary => try self.unary(gpa),
            .null => {},
        };
    }

    fn number(self: *Compiler, gpa: Allocator) CompilerError!void {
        const value = try fmt.parseFloat(f64, self.previous.lexeme(self.source));
        try self.emitConstant(gpa, .{ .number = value });
    }

    fn string(self: *Compiler, gpa: Allocator) CompilerError!void {
        const lexeme = self.previous.lexeme(self.source);
        const str = lexeme[1 .. lexeme.len - 1];

        const gop = try self.strings.getOrPut(str);
        if (!gop.found_existing) {
            // NOTE: Use imperative way for readability.
            const string_object = try gpa.create(String);
            errdefer gpa.destroy(string_object);

            string_object.* = .init(.@"const", str, Object{
                .kind = .string,
                .next = null,
            });

            gop.value_ptr.* = string_object;
        }

        try self.emitConstant(gpa, .{ .object = &gop.value_ptr.*.head });
    }

    fn grouping(self: *Compiler, gpa: Allocator) CompilerError!void {
        try self.expression(gpa);
        try self.consume(.r_paren, "Expect ')' after expression.");
    }

    fn unary(self: *Compiler, gpa: Allocator) CompilerError!void {
        const operator_tag = self.previous.tag;

        try self.parsePrecedence(gpa, .unary);

        switch (operator_tag) {
            .minus => try self.emitByte(gpa, .op_negate),
            .bang => try self.emitByte(gpa, .op_not),
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
            .bang_equal => {
                try self.emitByte(gpa, .op_equal);
                try self.emitByte(gpa, .op_not);
            },
            .equal_equal => try self.emitByte(gpa, .op_equal),
            .greater => try self.emitByte(gpa, .op_greater),
            .greater_equal => {
                try self.emitByte(gpa, .op_less);
                try self.emitByte(gpa, .op_not);
            },
            .less => try self.emitByte(gpa, .op_less),
            .less_equal => {
                try self.emitByte(gpa, .op_greater);
                try self.emitByte(gpa, .op_not);
            },
            .plus => try self.emitByte(gpa, .op_add),
            .minus => try self.emitByte(gpa, .op_subtract),
            .star => try self.emitByte(gpa, .op_multiply),
            .slash => try self.emitByte(gpa, .op_divide),
            else => {},
        }
    }

    fn literal(self: *Compiler, gpa: Allocator) CompilerError!void {
        switch (self.previous.tag) {
            .keyword_false => try self.emitByte(gpa, .op_false),
            .keyword_nil => try self.emitByte(gpa, .op_nil),
            .keyword_true => try self.emitByte(gpa, .op_true),
            else => {},
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

    fn consume(self: *Compiler, tag: Token.Tag, message: []const u8) Io.Writer.Error!void {
        if (self.current.tag == tag) {
            return try self.advance();
        }
        try self.errorAt(self.current, message);
    }

    fn emitByte(self: *Compiler, gpa: Allocator, code: Chunk.Code) Allocator.Error!void {
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
        try self.emitByte(gpa, .op_return);
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
            try self.errorAt(self.previous, "Too many constants in one chunk");
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
        .string = .{
            .prefix = .string,
            .infix = .null,
            .precedence = .none,
        },
        .keyword_nil = .{
            .prefix = .literal,
            .infix = .null,
            .precedence = .none,
        },
        .keyword_false = .{
            .prefix = .literal,
            .infix = .null,
            .precedence = .none,
        },
        .keyword_true = .{
            .prefix = .literal,
            .infix = .null,
            .precedence = .none,
        },
        .bang = .{
            .prefix = .unary,
            .infix = .null,
            .precedence = .none,
        },
        .bang_equal = .{
            .prefix = .null,
            .infix = .binary,
            .precedence = .equality,
        },
        .equal_equal = .{
            .prefix = .null,
            .infix = .binary,
            .precedence = .equality,
        },
        .greater = .{
            .prefix = .null,
            .infix = .binary,
            .precedence = .comparison,
        },
        .greater_equal = .{
            .prefix = .null,
            .infix = .binary,
            .precedence = .comparison,
        },
        .less = .{
            .prefix = .null,
            .infix = .binary,
            .precedence = .comparison,
        },
        .less_equal = .{
            .prefix = .null,
            .infix = .binary,
            .precedence = .comparison,
        },
    });
};

test "compiler" {
    try testCompile("(1 + 2) * 3", "9");
    try testCompile("1 + 2 * 3", "7");
    try testCompile("10 - 5 / 1", "5");
    try testCompile("true", "true");
    try testCompile("false", "false");
    try testCompile("nil", "nil");
    try testCompile("!true", "false");
    try testCompile("!false", "true");
    try testCompile("!nil", "true");
    try testCompile("!10", "false");
    try testCompile("10 == 10", "true");
    try testCompile("10 != 10", "false");
    try testCompile("10 < 10", "false");
    try testCompile("10 <= 10", "true");
    try testCompile("10 > 10", "false");
    try testCompile("10 >= 10", "true");
    try testCompile("!(5 - 4 > 3 * 2 == !nil)", "true");
    try testCompile(
        \\ "hello"
    , "hello");

    try testCompile(
        \\ "hello, " + "world!"
    , "hello, world!");

    try testCompile(
        \\ "hello" == "hello"
    , "true");
    try testCompile(
        \\ "hello" == "world"
    , "false");
}

fn testCompile(source: [:0]const u8, expected: []const u8) !void {
    const gpa = testing.allocator;

    var stream: Io.Writer.Allocating = .init(gpa);
    defer stream.deinit();

    var ctx: Context = .init(undefined, .{ .out = &stream.writer, .err = &stream.writer });

    var vm: VM = try .initCapacity(gpa, 256);
    defer vm.deinit(gpa);

    try vm.interpret(gpa, &ctx, source);
    try testing.expectEqualSlices(u8, expected, stream.written());
}

const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const testing = std.testing;

const Allocator = mem.Allocator;
const Io = std.Io;

const tokenizer = @import("tokenizer.zig");
const values = @import("values.zig");
const Chunk = @import("Chunk.zig");
const Context = @import("Context.zig");
const utils = @import("utils.zig");
const VM = @import("VM.zig");
const Strings = utils.Table;
const Object = values.Object;
const String = values.String;
const Value = values.Value;
const Scanner = tokenizer.Scanner;
const Token = tokenizer.Token;
