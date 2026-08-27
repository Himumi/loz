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

    global_symbols: *std.AutoHashMap(*String, u32),

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
            variable,
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

            .global_symbols = undefined,

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

        var global_symbols: std.AutoHashMap(*String, u32) = .init(gpa);
        defer global_symbols.deinit();

        // Borrow the chunk memory.
        self.chunk = &chunk;
        // Borrow the context memory.
        self.ctx = ctx;
        // Borrow the global_symbols memory.
        self.global_symbols = &global_symbols;

        // Make sure to false at start up.
        self.had_error = false;
        self.panic_mode = false;

        // Add the first token.
        try self.advance();

        // Compile one expression.
        while (self.current.tag != .eof) {
            try self.declaration(gpa);
        }
        try self.consume(.eof, "Expect end of expression.");

        try self.emitReturn(gpa);
        // if (!self.had_error) {
        // }

        // The caller ownes the ownership.
        return chunk;
    }

    fn declaration(self: *Compiler, gpa: Allocator) CompilerError!void {
        switch (self.current.tag) {
            .keyword_var => {
                try self.advance();
                try self.varDeclaration(gpa);
            },
            else => try self.statement(gpa),
        }
        if (self.panic_mode) try self.sync();
    }

    fn varDeclaration(self: *Compiler, gpa: Allocator) CompilerError!void {
        const previous_line = self.previous.line;
        const global_index = try self.parseVariable(gpa, "Expect variable name.");

        if (self.current.tag == .equal) {
            try self.advance();
            try self.expression(gpa);
        } else {
            try self.emitByte(gpa, .op_nil);
        }
        try self.consume(.semicolon, "Expect ';' after variable expression.");

        try self.defineVariable(gpa, global_index, previous_line);
    }

    fn parseVariable(self: *Compiler, gpa: Allocator, err_message: []const u8) !u32 {
        try self.consume(.identifier, err_message);
        return try self.identifierConstant(gpa, self.previous);
    }

    fn identifierConstant(self: *Compiler, gpa: Allocator, token: Token) !u32 {
        const lexeme = token.lexeme(self.source);

        const gop = try self.strings.getOrPut(lexeme);
        if (!gop.found_existing) {
            const string_object = try gpa.create(String);
            errdefer gpa.destroy(string_object);

            string_object.* = .init(.@"const", lexeme, Object{
                .kind = .string,
                .next = null,
            });

            gop.value_ptr.* = string_object;
        }

        return self.makeConstant(gpa, .{ .object = &gop.value_ptr.*.head });
    }

    fn defineVariable(self: *Compiler, gpa: Allocator, global_index: u32, line: u32) !void {
        const code: Chunk.Code =
            if (global_index < 256) .op_define_global else .op_define_global_long;

        try self.emitByte(gpa, code);
        try self.emitLiteral(gpa, global_index, line);
    }

    fn statement(self: *Compiler, gpa: Allocator) CompilerError!void {
        switch (self.current.tag) {
            .keyword_print => {
                try self.advance();
                try self.printStatement(gpa);
            },
            else => try self.expressionStatement(gpa),
        }
    }

    fn printStatement(self: *Compiler, gpa: Allocator) CompilerError!void {
        try self.expression(gpa);
        try self.consume(.semicolon, "Expect ';' after value.");
        try self.emitByte(gpa, .op_print);
    }

    fn expressionStatement(self: *Compiler, gpa: Allocator) CompilerError!void {
        try self.expression(gpa);
        try self.consume(.semicolon, "Expect ';' after value.");
        try self.emitByte(gpa, .op_pop);
    }

    fn expression(self: *Compiler, gpa: Allocator) CompilerError!void {
        try self.parsePrecedence(gpa, .assignment);
    }

    fn sync(self: *Compiler) CompilerError!void {
        self.panic_mode = false;

        while (self.current.tag != .eof) {
            if (self.previous.tag == .keyword_return) return;
            switch (self.current.tag) {
                .keyword_class,
                .keyword_fun,
                .keyword_var,
                .keyword_for,
                .keyword_if,
                .keyword_while,
                .keyword_print,
                .keyword_return,
                => return,
                else => {},
            }
            try self.advance();
        }
    }

    fn parsePrecedence(self: *Compiler, gpa: Allocator, precedence: Precedence) CompilerError!void {
        try self.advance();

        const prefix_rule = rules.get(self.previous.tag).prefix;
        if (prefix_rule == .null) {
            try self.errorAt(self.previous, "Expect Expression.");
            return error.ExpectedExpression;
        }

        const prece_int = @intFromEnum(precedence);
        const assign_int = @intFromEnum(Precedence.assignment);

        const assignable = prece_int <= assign_int;
        try self.parseRule(gpa, prefix_rule, assignable);

        while (true) {
            const curr_prece_int = @intFromEnum(rules.get(self.current.tag).precedence);

            if (prece_int > curr_prece_int) break;
            try self.advance();

            const infix_rule = rules.get(self.previous.tag).infix;
            try self.parseRule(gpa, infix_rule, assignable);
        }

        if (assignable and self.current.tag == .equal) {
            try self.errorAt(self.current, "Invalid assignment target.");
            try self.advance();
        }
    }

    fn parseRule(
        self: *Compiler,
        gpa: Allocator,
        rule: Rule.Kind,
        assignable: bool,
    ) CompilerError!void {
        return switch (rule) {
            .literal => try self.literal(gpa),
            .number => try self.number(gpa),
            .string => try self.string(gpa),
            .group => try self.grouping(gpa),
            .binary => try self.binary(gpa),
            .unary => try self.unary(gpa),
            .variable => try self.variable(gpa, assignable),
            .null => {},
        };
    }

    fn number(self: *Compiler, gpa: Allocator) !void {
        const value = try fmt.parseFloat(f64, self.previous.lexeme(self.source));
        try self.emitConstant(gpa, .{ .number = value });
    }

    fn string(self: *Compiler, gpa: Allocator) !void {
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

        const head = &gop.value_ptr.*.head;
        try self.emitConstant(gpa, .{ .object = head });
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

    fn variable(self: *Compiler, gpa: Allocator, assignable: bool) CompilerError!void {
        try self.namedVariable(gpa, self.previous, assignable);
    }

    fn namedVariable(
        self: *Compiler,
        gpa: Allocator,
        token: Token,
        assignable: bool,
    ) CompilerError!void {
        const arg_index = try self.identifierConstant(gpa, token);

        if (assignable and self.current.tag == .equal) {
            try self.advance();
            try self.expression(gpa);

            try self.emitByte(gpa, if (arg_index < 256) .op_set_global else .op_set_global_long);
        } else {
            try self.emitByte(gpa, if (arg_index < 256) .op_get_global else .op_get_global_long);
        }

        try self.emitLiteral(gpa, arg_index, token.line);
    }

    fn advance(self: *Compiler) Io.Writer.Error!void {
        self.previous = self.current;

        while (true) {
            self.current = self.scanner.next();
            if (self.current.tag != .invalid) break;
            // TODO: Create invalid token validator.
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
        try self.chunk.writeConstant(gpa, @intCast(value_index), self.previous.line);
    }

    fn emitLiteral(self: *Compiler, gpa: Allocator, index: u32, line: u32) Allocator.Error!void {
        if (index < 256) {
            try self.chunk.writeLiteral(gpa, @intCast(index), line);
        } else {
            for (Chunk.trucate3Bytes(index)) |byte| {
                try self.chunk.writeLiteral(gpa, byte, line);
            }
        }
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
        // Prevent deduplication for constants.
        if (value.isString()) {
            for (self.chunk.constants.items, 0..) |constant, index| {
                if (constant.isString() and constant.isEqual(value)) {
                    return @intCast(index);
                }
            }
        }

        const index = try self.chunk.addValue(gpa, value);
        if (index > 16_777_215) { // Update based on constant long.
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
        .identifier = .{
            .prefix = .variable,
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
    try testCompile("print (1 + 2) * 3;", "9");
    try testCompile("print 1 + 2 * 3;", "7");
    try testCompile("print 10 - 5 / 1;", "5");
    try testCompile("print true;", "true");
    try testCompile("print false;", "false");
    try testCompile("print nil;", "nil");
    try testCompile("print !true;", "false");
    try testCompile("print !false;", "true");
    try testCompile("print !nil;", "true");
    try testCompile("print !10;", "false");
    try testCompile("print 10 == 10;", "true");
    try testCompile("print 10 != 10;", "false");
    try testCompile("print 10 < 10;", "false");
    try testCompile("print 10 <= 10;", "true");
    try testCompile("print 10 > 10;", "false");
    try testCompile("print 10 >= 10;", "true");
    try testCompile("print !(5 - 4 > 3 * 2 == !nil);", "true");
    try testCompile(
        \\ print "hello";
    , "hello");

    try testCompile(
        \\ print "hello, " + "world!";
    , "hello, world!");

    try testCompile(
        \\ print "hello" == "hello";
    , "true");
    try testCompile(
        \\ print "hello" == "world";
    , "false");

    try testCompile(
        \\ var name = "John";
        \\ print "Hello " + name;
    , "Hello John");

    try testCompile(
        \\ var name;
        \\ name = "John";
        \\ print name;
    , "John");

    try testCompile(
        \\ var breakfast = "beignets";
        \\ var beverage = "cafe au lait";
        \\ breakfast = "beignets with " + beverage;
        \\
        \\ print breakfast;
    , "beignets with cafe au lait");
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
