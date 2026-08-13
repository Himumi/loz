pub const TokenList = std.MultiArrayList(Token);

pub const Token = struct {
    tag: Tag,
    loc: Loc,

    const Loc = struct {
        start: u32,
        end: u32,
    };
    pub const Index = u32;

    pub fn lexeme(self: Token, source: [:0]const u8) []const u8 {
        const start: usize = @intCast(self.loc.start);
        const end: usize = @intCast(self.loc.end);
        return source[start..end];
    }

    pub const Tag = enum(u32) {
        // Keywords
        keyword_and = 0,
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

        // End-Of-File
        eof,

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

pub fn scan(gpa: Allocator, ctx: *Context, source: [:0]const u8) LexerError!TokenList.Slice {
    var lexer: Lexer = .empty;
    try lexer.scan(gpa, ctx, source);
    return lexer.toOwnSlice();
}

pub const Lexer = struct {
    index: usize = 0,

    // It borrowed the memory
    source: [:0]const u8,

    // The result
    tokens: TokenList = .empty,

    pub const Error = error{
        UnexpectedCharacter,
        UnexpectedNullCharacter,
        UnterminatedString,
        UnterminatedBlockComment,
    };

    pub const empty: Lexer = .{
        .source = undefined,
        .index = 0,
        .tokens = .empty,
    };

    pub fn deinit(self: *Lexer, gpa: Allocator) void {
        self.tokens.deinit(gpa);
    }

    /// Tokenize the input source.
    /// It does not reset the index tracker.
    ///
    /// NOTE: The caller has to Append new data to the previous
    /// to keep tokenize follows the previous index tracker.
    pub fn scan(
        self: *Lexer,
        gpa: Allocator,
        ctx: *Context,
        source: [:0]const u8,
    ) LexerError!void {
        self.source = source;

        // Consume data until EOF.
        while (true) {
            const token = self.next() catch |err| {
                // TODO: Need to separate it from tokenizer.
                try report(ctx, self.source, self.index, try getMessage(err));
                return err;
            };
            try self.tokens.append(gpa, token);
            if (token.tag == .eof) break;
        }
    }

    /// The caller borrows the memory.
    pub fn slice(self: Lexer) TokenList.Slice {
        return self.tokens.slice();
    }

    /// The caller owns the memory. Resets the struct's state.
    pub fn toOwnSlice(self: *Lexer) TokenList.Slice {
        return self.tokens.toOwnedSlice();
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
            .tag = .eof,
            .loc = .{
                .start = @intCast(self.index),
                .end = 0,
            },
        };

        state: switch (State.start) {
            .start => {
                switch (self.source[self.index]) {
                    0 => {
                        if (self.index < self.source.len) {
                            return error.UnexpectedNullCharacter;
                        }
                        return .{
                            .tag = .eof,
                            .loc = .{
                                .start = @intCast(self.index),
                                .end = @intCast(self.index),
                            },
                        };
                    },
                    ' ', '\r', '\t' => {
                        self.index += 1;
                        result.loc.start = @intCast(self.index);
                        continue :state .start;
                    },
                    '\n' => {
                        self.index += 1;
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
                    '\n' => continue :state .block_comment,
                    '*' => {
                        switch (self.source[self.index + 1]) {
                            '/' => {
                                self.index += 2;
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
                        continue :state .start;
                    },
                    else => continue :state .line_comment,
                }
            },

            .string_literal => {
                self.index += 1;
                switch (self.source[self.index]) {
                    0 => return error.UnterminatedString,
                    '\n' => continue :state .string_literal,
                    '"' => {
                        self.index += 1;
                        result.tag = .string;
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
                        result.loc.end = @intCast(self.index);

                        const lexeme = result.lexeme(self.source);
                        result.tag = Token.keywords.get(lexeme) orelse .identifier;

                        return result;
                    },
                }
            },
        }

        result.loc.end = @intCast(self.index);
        return result;
    }
};

pub fn getMessage(err: LexerError) ![]const u8 {
    return switch (err) {
        error.UnexpectedCharacter => "Unexpected Character.",
        error.UnexpectedNullCharacter => "Unexpected Null Character.",
        error.UnterminatedString => "Unterminated String.",
        error.UnterminatedBlockComment => "Unterminated Block Comment.",
        else => err,
    };
}

// TODO: Need to separate from tokenizer.
pub fn report(ctx: *Context, source: [:0]const u8, index: usize, message: []const u8) !void {
    const line = Line.get(source, index);
    const position = index - line.loc.start;
    const lexeme = source[line.loc.start..line.loc.end];

    try ctx.report(
        \\{}:{} Error: {s}
        \\{s}
        \\{s:>[5]}
        \\
    , .{ line.pos, position, message, lexeme, "^", position });
}

pub const Line = struct {
    pos: usize,
    loc: Loc,

    const Loc = struct {
        start: usize,
        end: usize,
    };

    pub fn get(source: [:0]const u8, index: usize) Line {
        var count: usize = 1;
        var start: usize = 0;

        var is_found: bool = false;

        var i: usize = 0;
        while (i < source.len) : (i += 1) {
            if (i == index) {
                is_found = true;
            }

            const byte = source[i];
            if (byte == '\n') {
                if (is_found) break;
                count += 1;
                if ((i + 1) <= source.len) {
                    start = i + 1;
                }
            }
        }

        return .{
            .pos = count,
            .loc = .{
                .start = start,
                .end = i,
            },
        };
    }
};

test "getLine" {
    const source =
        \\ var name = "john";
        \\ print name;
        \\ print name;
    ;

    const line = Line.get(source, 25);
    try testing.expectEqual(line.pos, 2);
    try testing.expectEqual(line.loc.start, 20);
    try testing.expectEqual(line.loc.end, 32);
}

test "succeeds lexer" {
    try testLexer(" ( ", 2, "( EOF");
    try testLexer(" ) ", 2, ") EOF");
    try testLexer(" { ", 2, "{ EOF");
    try testLexer(" } ", 2, "} EOF");
    try testLexer(" , ", 2, ", EOF");
    try testLexer(" . ", 2, ". EOF");
    try testLexer(" - ", 2, "- EOF");
    try testLexer(" + ", 2, "+ EOF");
    try testLexer(" ; ", 2, "; EOF");
    try testLexer(" * ", 2, "* EOF");
    try testLexer(" ! ", 2, "! EOF");
    try testLexer(" != ", 2, "!= EOF");
    try testLexer(" = ", 2, "= EOF");
    try testLexer(" == ", 2, "== EOF");
    try testLexer(" < ", 2, "< EOF");
    try testLexer(" <= ", 2, "<= EOF");
    try testLexer(" > ", 2, "> EOF");
    try testLexer(" >= ", 2, ">= EOF");
    try testLexer(" / ", 2, "/ EOF");
    try testLexer(" \r\t", 1, "EOF"); // Ignored characters.
    try testLexer("\n", 1, "EOF"); // Add line by one.
    try testLexer(" and ", 2, "and EOF");
    try testLexer(" class ", 2, "class EOF");
    try testLexer(" else ", 2, "else EOF");
    try testLexer(" false ", 2, "false EOF");
    try testLexer(" for ", 2, "for EOF");
    try testLexer(" fun ", 2, "fun EOF");
    try testLexer(" if ", 2, "if EOF");
    try testLexer(" nil ", 2, "nil EOF");
    try testLexer(" or ", 2, "or EOF");
    try testLexer(" print ", 2, "print EOF");
    try testLexer(" return ", 2, "return EOF");
    try testLexer(" super ", 2, "super EOF");
    try testLexer(" this ", 2, "this EOF");
    try testLexer(" true ", 2, "true EOF");
    try testLexer(" var ", 2, "var EOF");
    try testLexer(" while ", 2, "while EOF");
    try testLexer(" identifier ", 2, "identifier EOF");
    try testLexer(" 123 ", 2, "123 EOF");
    try testLexer(" 1.23 ", 2, "1.23 EOF");
    try testLexer(
        \\ "hello"
    , 2,
        \\"hello" EOF
    );
    try testLexer(
        \\ "hello
        \\ world"
    , 2,
        \\"hello
        \\ world" EOF
    );
    try testLexer(
        \\ // inline comment
    , 1, "EOF");
    try testLexer(
        \\ /*
        \\   multiline comments
        \\ */
    , 1, "EOF");
}

test "fails scanner" {
    try testFailLexer(
        \\ "a string
    ,
        error.UnterminatedString,

        \\1:10 Error: Unterminated String.
        \\ "a string
        \\         ^
        \\
        ,
    );
    try testFailLexer(
        \\ /* block comment
        \\ without the end
    ,
        error.UnterminatedBlockComment,
        \\2:16 Error: Unterminated Block Comment.
        \\ without the end
        \\               ^
        \\
        ,
    );
}

fn testLexer(source: [:0]const u8, expected_len: usize, expected: []const u8) !void {
    const gpa = testing.allocator;

    var stream: Io.Writer.Allocating = .init(gpa);
    defer stream.deinit();

    var writer = &stream.writer;
    var ctx: Context = .init(undefined, .{ .err = writer });

    var tokens = try scan(gpa, &ctx, source);
    defer tokens.deinit(gpa);

    for (0..tokens.len) |index| {
        const token = tokens.get(index);
        if (index > 0) {
            try writer.writeByte(' ');
        }

        if (token.tag == .eof) {
            try writer.print("{s}", .{token.tag.symbol()});
            break;
        }
        try writer.print("{s}", .{token.lexeme(source)});
    }

    try testing.expectEqual(expected_len, tokens.len);
    try testing.expectEqualSlices(u8, expected, writer.buffered());
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
