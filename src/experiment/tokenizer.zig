pub const Token = struct {
    // lexeme does not own the memory ownership.
    lexeme: []const u8,
    line: usize,
    tag: Tag,

    pub fn init(tag: Tag, lexeme: []const u8, line: usize) Token {
        return .{
            .lexeme = lexeme,
            .tag = tag,
            .line = line,
        };
    }

    /// Call deinit if you know the Token has an indenpendent lifetime.
    pub fn deinit(self: Token, gpa: Allocator) void {
        gpa.free(self.lexeme);
    }

    pub fn dupe(self: Token, gpa: Allocator) Allocator.Error!Token {
        return .{
            .lexeme = try gpa.dupe(u8, self.lexeme),
            .tag = self.tag,
            .line = self.line,
        };
    }

    pub const Tag = enum(u8) {
        // Single Character Tokens
        left_paren,
        right_paren,
        left_brace,
        right_brace,
        comma,
        dot,
        minus,
        plus,
        semicolon,
        slash,
        star,

        // One or Two Character Tokens
        bang,
        bang_equal,
        equal,
        equal_equal,
        greater,
        greater_equal,
        less,
        less_equal,

        // Literals
        identifier,
        string,
        number,

        // Keywords
        keyword_and,
        keyword_class,
        keyword_else,
        keyword_false,
        keyword_fun,
        keyword_for,
        keyword_if,
        keyword_nil,
        keyword_or,
        keyword_print,
        keyword_return,
        keyword_super,
        keyword_this,
        keyword_true,
        keyword_var,
        keyword_while,

        // End-Of-File
        eof,

        // Maybe i will use this for errors.
        fn lexeme(tag: Tag) ?[]const u8 {
            return switch (tag) {
                // Literals
                .identifier,
                .string,
                .number,
                .eof,
                => null,

                .left_paren => "(",
                .right_paren => ")",
                .left_brace => "{",
                .right_brace => "}",
                .comma => ",",
                .dot => ".",
                .minus => "-",
                .plus => "+",
                .semicolon => ":",
                .slash => "/",
                .star => "*",

                .bang => "!",
                .bang_equal => "!=",
                .equal => "=",
                .equal_equal => "==",
                .greater => ">",
                .greater_equal => ">=",
                .less => "<",
                .less_equal => "<=",

                // Keywords
                .keyword_and => "and",
                .keyword_class => "class",
                .keyword_else => "else",
                .keyword_false => "false",
                .keyword_fun => "fun",
                .keyword_for => "for",
                .keyword_if => "if",
                .keyword_nil => "nil",
                .keyword_or => "or",
                .keyword_print => "print",
                .keyword_return => "return",
                .keyword_super => "super",
                .keyword_this => "this",
                .keyword_true => "true",
                .keyword_var => "var",
                .keyword_while => "while",
            };
        }

        pub fn symbol(tag: Tag) []const u8 {
            return tag.lexeme() orelse switch (tag) {
                .identifier => "an identifier",
                .string => "a string",
                .number => "a number",
                .eof => "EOF",
                else => unreachable,
            };
        }
    };

    pub const keywords: StaticStringMap(Tag) = .initComptime(.{
        .{ "and", .keyword_and },
        .{ "class", .keyword_class },
        .{ "else", .keyword_else },
        .{ "false", .keyword_false },
        .{ "for", .keyword_for },
        .{ "fun", .keyword_fun },
        .{ "if", .keyword_if },
        .{ "nil", .keyword_nil },
        .{ "or", .keyword_or },
        .{ "print", .keyword_print },
        .{ "return", .keyword_return },
        .{ "super", .keyword_super },
        .{ "this", .keyword_this },
        .{ "true", .keyword_true },
        .{ "var", .keyword_var },
        .{ "while", .keyword_while },
    });
};

const LexerError =
    Lexer.Error ||
    Allocator.Error ||
    Io.Writer.Error;

pub fn scan(gpa: Allocator, ctx: *Context, source: [:0]const u8) LexerError![]Token {
    var lexer: Lexer = .init(source);
    return try lexer.scan(gpa, ctx);
}

pub const Lexer = struct {
    // source does not own the memory ownership.
    source: [:0]const u8,
    // Lexer tracker properties.
    index: usize,
    start: usize,
    line: usize,

    pub const Error = error{
        UnexpectedCharacter,
        UnterminatedString,
        UnterminatedBlockComment,
    };

    pub fn init(source: [:0]const u8) Lexer {
        return .{
            .source = source,
            .index = 0,
            .start = 0,
            .line = 1,
        };
    }

    pub fn scan(self: *Lexer, gpa: Allocator, ctx: *Context) LexerError![]Token {
        var list: ArrayList(Token) = .empty;
        defer list.deinit(gpa);
        // Consume data until EOF.
        while (true) {
            const token = self.next() catch |err| {
                try self.report(ctx, err);
                return err;
            };
            try list.append(gpa, token);
            if (token.tag == .eof) break;
        }
        return try list.toOwnedSlice(gpa);
    }

    const State = enum {
        start,
        bang,
        equal,
        unexpected,
        less,
        greater,
        slash,
        string_literal,
        number_literal,
        float_literal,
        identifier,
        line_comment,
        block_comment,
    };

    pub fn next(self: *Lexer) Error!Token {
        var result: Token = .{
            .tag = undefined,
            .line = undefined,
            .lexeme = undefined,
        };
        const string_literal_line = self.line;
        self.start = self.index;

        state: switch (State.start) {
            .start => {
                switch (self.source[self.index]) {
                    0 => return .init(.eof, "", self.line),
                    ' ', '\r', '\t' => {
                        self.index += 1;
                        self.start = self.index;
                        continue :state .start;
                    },
                    '\n' => {
                        self.index += 1;
                        self.start = self.index;
                        self.line += 1;
                        continue :state .start;
                    },
                    '(' => {
                        self.index += 1;
                        result.tag = .left_paren;
                    },
                    ')' => {
                        self.index += 1;
                        result.tag = .right_paren;
                    },
                    '{' => {
                        self.index += 1;
                        result.tag = .left_brace;
                    },
                    '}' => {
                        self.index += 1;
                        result.tag = .right_brace;
                    },
                    ',' => {
                        self.index += 1;
                        result.tag = .comma;
                    },
                    '.' => {
                        self.index += 1;
                        result.tag = .dot;
                    },
                    '-' => {
                        self.index += 1;
                        result.tag = .minus;
                    },
                    '+' => {
                        self.index += 1;
                        result.tag = .plus;
                    },
                    ';' => {
                        self.index += 1;
                        result.tag = .semicolon;
                    },
                    '*' => {
                        self.index += 1;
                        result.tag = .star;
                    },
                    '!' => continue :state .bang,
                    '=' => continue :state .equal,
                    '<' => continue :state .less,
                    '>' => continue :state .greater,
                    '/' => continue :state .slash,
                    '"' => continue :state .string_literal,
                    '0'...'9' => continue :state .number_literal,
                    'a'...'z', 'A'...'Z', '_' => continue :state .identifier,
                    else => continue :state .unexpected,
                }
            },
            .unexpected => return error.UnexpectedCharacter,
            .bang => {
                self.index += 1;
                switch (self.source[self.index]) {
                    '=' => {
                        self.index += 1;
                        result.tag = .bang_equal;
                    },
                    else => result.tag = .bang,
                }
            },
            .equal => {
                self.index += 1;
                switch (self.source[self.index]) {
                    '=' => {
                        self.index += 1;
                        result.tag = .equal_equal;
                    },
                    else => result.tag = .equal,
                }
            },
            .less => {
                self.index += 1;
                switch (self.source[self.index]) {
                    '=' => {
                        self.index += 1;
                        result.tag = .less_equal;
                    },
                    else => result.tag = .less,
                }
            },
            .greater => {
                self.index += 1;
                switch (self.source[self.index]) {
                    '=' => {
                        self.index += 1;
                        result.tag = .greater_equal;
                    },
                    else => result.tag = .greater,
                }
            },
            .slash => {
                self.index += 1;
                switch (self.source[self.index]) {
                    '/' => continue :state .line_comment,
                    '*' => continue :state .block_comment,
                    else => result.tag = .slash,
                }
            },
            .block_comment => {
                self.index += 1;
                switch (self.source[self.index]) {
                    0 => return error.UnterminatedBlockComment,
                    '\n' => {
                        self.line += 1;
                        continue :state .block_comment;
                    },
                    '*' => {
                        switch (self.source[self.index + 1]) {
                            '/' => {
                                self.index += 2;
                                self.start = self.index;
                                continue :state .start;
                            },
                            else => continue :state .block_comment,
                        }
                    },
                    else => continue :state .block_comment,
                }
            },
            .line_comment => {
                self.index += 1;
                switch (self.source[self.index]) {
                    0 => {
                        if (self.index != self.source.len) {
                            continue :state .unexpected;
                        }
                        continue :state .start;
                    },
                    '\n' => {
                        self.index += 1;
                        self.line += 1;
                        self.start += self.index;
                        continue :state .start;
                    },
                    else => continue :state .line_comment,
                }
            },
            .string_literal => {
                self.index += 1;
                switch (self.source[self.index]) {
                    0 => return error.UnterminatedString,
                    '\n' => {
                        self.line += 1;
                        continue :state .string_literal;
                    },
                    '"' => {
                        self.index += 1;
                        const lexeme = self.source[self.start + 1 .. self.index - 1];
                        return .init(.string, lexeme, string_literal_line);
                    },
                    else => continue :state .string_literal,
                }
            },
            .number_literal => {
                self.index += 1;
                switch (self.source[self.index]) {
                    '.' => continue :state .float_literal,
                    '0'...'9' => continue :state .number_literal,
                    else => result.tag = .number,
                }
            },
            .float_literal => {
                self.index += 1;
                switch (self.source[self.index]) {
                    '0'...'9' => continue :state .float_literal,
                    else => result.tag = .number,
                }
            },
            .identifier => {
                self.index += 1;
                switch (self.source[self.index]) {
                    'a'...'z', 'A'...'Z', '_', '0'...'9' => continue :state .identifier,
                    else => {
                        const lexeme = self.source[self.start..self.index];
                        const tag = Token.keywords.get(lexeme) orelse .identifier;
                        return .init(tag, lexeme, self.line);
                    },
                }
            },
        }

        result.line = self.line;
        result.lexeme = self.source[self.start..self.index];
        return result;
    }

    fn report(self: *Lexer, ctx: *Context, err: Error) !void {
        const message = switch (err) {
            error.UnexpectedCharacter => "Unexpected Character.",
            error.UnterminatedString => "Unterminated String.",
            error.UnterminatedBlockComment => "Unterminated Block Comment.",
        };
        try ctx.report("[{}] Error: {s}\n", .{ self.line, message });
    }
};

test "Token.string" {
    var buffer: [1024]u8 = undefined;

    try testToken(&buffer, .init(.bang_equal, "!=", 1), "!= != 1");
    try testToken(&buffer, .init(.keyword_and, "and", 1), "and and 1");
    try testToken(&buffer, .init(.keyword_if, "if", 1), "if if 1");
    try testToken(&buffer, .init(.keyword_var, "var", 1), "var var 1");
    try testToken(&buffer, .init(.identifier, "name", 1), "an identifier name 1");
    try testToken(&buffer, .init(.plus, "+", 1), "+ + 1");
    try testToken(&buffer, .init(.keyword_true, "true", 1), "true true 1");
    try testToken(&buffer, .init(.number, "123", 1), "a number 123 1");
    try testToken(&buffer, .init(.string, "hello", 1), "a string hello 1");
}

test "succeeds lexer" {
    const eof: Token = .init(.eof, "", 1);

    try testLexer("(", &.{ .init(.left_paren, "(", 1), eof });
    try testLexer(")", &.{ .init(.right_paren, ")", 1), eof });
    try testLexer("{", &.{ .init(.left_brace, "{", 1), eof });
    try testLexer("}", &.{ .init(.right_brace, "}", 1), eof });
    try testLexer(",", &.{ .init(.comma, ",", 1), eof });
    try testLexer(".", &.{ .init(.dot, ".", 1), eof });
    try testLexer("-", &.{ .init(.minus, "-", 1), eof });
    try testLexer("+", &.{ .init(.plus, "+", 1), eof });
    try testLexer(";", &.{ .init(.semicolon, ";", 1), eof });
    try testLexer("*", &.{ .init(.star, "*", 1), eof });
    try testLexer("!", &.{ .init(.bang, "!", 1), eof });
    try testLexer("!=", &.{ .init(.bang_equal, "!=", 1), eof });
    try testLexer("=", &.{ .init(.equal, "=", 1), eof });
    try testLexer("==", &.{ .init(.equal_equal, "==", 1), eof });
    try testLexer("<", &.{ .init(.less, "<", 1), eof });
    try testLexer("<=", &.{ .init(.less_equal, "<=", 1), eof });
    try testLexer(">", &.{ .init(.greater, ">", 1), eof });
    try testLexer(">=", &.{ .init(.greater_equal, ">=", 1), eof });
    try testLexer("/", &.{ .init(.slash, "/", 1), eof });
    try testLexer(" \r\t", &.{eof}); // Ignored characters.
    try testLexer("\n", &.{.init(.eof, "", 2)}); // Add line by one.
    try testLexer("and", &.{ .init(.keyword_and, "and", 1), eof });
    try testLexer("class", &.{ .init(.keyword_class, "class", 1), eof });
    try testLexer("else", &.{ .init(.keyword_else, "else", 1), eof });
    try testLexer("false", &.{ .init(.keyword_false, "false", 1), eof });
    try testLexer("for", &.{ .init(.keyword_for, "for", 1), eof });
    try testLexer("fun", &.{ .init(.keyword_fun, "fun", 1), eof });
    try testLexer("if", &.{ .init(.keyword_if, "if", 1), eof });
    try testLexer("nil", &.{ .init(.keyword_nil, "nil", 1), eof });
    try testLexer("or", &.{ .init(.keyword_or, "or", 1), eof });
    try testLexer("print", &.{ .init(.keyword_print, "print", 1), eof });
    try testLexer("return", &.{ .init(.keyword_return, "return", 1), eof });
    try testLexer("super", &.{ .init(.keyword_super, "super", 1), eof });
    try testLexer("this", &.{ .init(.keyword_this, "this", 1), eof });
    try testLexer("true", &.{ .init(.keyword_true, "true", 1), eof });
    try testLexer("var", &.{ .init(.keyword_var, "var", 1), eof });
    try testLexer("while", &.{ .init(.keyword_while, "while", 1), eof });
    try testLexer("identifier", &.{ .init(.identifier, "identifier", 1), eof });
    try testLexer("123", &.{ .init(.number, "123", 1), eof });
    try testLexer("1.23", &.{ .init(.number, "1.23", 1), eof });
    try testLexer(
        \\ "hello"
    , &.{ .init(.string, "hello", 1), eof });
    try testLexer(
        \\ "hello
        \\ world"
    , &.{ .init(.string, "hello\n world", 1), .init(.eof, "", 2) });
    try testLexer(
        \\ // inline comment
    , &.{eof});
    try testLexer(
        \\ /*
        \\   multiline comments
        \\ */
    , &.{.init(.eof, "", 3)});
}

test "fails scanner" {
    try testFailLexer(
        \\ "a string
    ,
        error.UnterminatedString,
        "[1] Error: Unterminated String.\n",
    );
    try testFailLexer(
        \\ /* block comment
        \\ without the end
    ,
        error.UnterminatedBlockComment,
        "[2] Error: Unterminated Block Comment.\n",
    );
}

fn testToken(buffer: []u8, token: Token, expected: []const u8) !void {
    const joined = try fmt.bufPrint(buffer, "{s} {s} {}", .{
        token.tag.symbol(),
        token.lexeme,
        token.line,
    });
    try testing.expectEqualSlices(u8, expected, joined);
}

fn testLexer(source: [:0]const u8, expecteds: []const Token) !void {
    const gpa = testing.allocator;

    const tokens = try scan(gpa, undefined, source);
    defer gpa.free(tokens);

    try testing.expectEqual(expecteds.len, tokens.len);
    for (tokens, expecteds) |token, expected| {
        try testing.expectEqual(expected.tag, token.tag);
        try testing.expectEqualSlices(u8, expected.lexeme, token.lexeme);
        try testing.expectEqual(expected.line, token.line);
    }
}

fn testFailLexer(
    source: [:0]const u8,
    expected_error: anyerror,
    expected_message: []const u8,
) !void {
    const gpa = testing.allocator;

    var buffer: [1024]u8 = undefined;
    var io_err: Io.Writer = .fixed(&buffer);

    var ctx: Context = .init(undefined, .{ .err = &io_err });
    _ = scan(gpa, &ctx, source) catch |err| {
        try testing.expectEqual(expected_error, err);
        try testing.expectEqualSlices(u8, expected_message, io_err.buffered());
    };
}

const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const testing = std.testing;

const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const StaticStringMap = std.StaticStringMap;

const Context = @import("Context.zig");
