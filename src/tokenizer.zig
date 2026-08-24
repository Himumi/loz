pub const TokenList = MultiArrayList(Token);

pub const Token = struct {
    tag: Tag,
    loc: Loc,
    line: u32,

    pub const Loc = struct {
        start: u32,
        end: u32,
    };

    pub fn lexeme(self: Token, source: [:0]const u8) []const u8 {
        const start: usize = @intCast(self.loc.start);
        const end: usize = @intCast(self.loc.end);
        return source[start..end];
    }

    pub const Tag = enum {
        // Single character tokens.
        l_paren,
        r_paren,
        l_brace,
        r_brace,
        comma,
        dot,
        minus,
        plus,
        semicolon,
        slash,
        star,

        // One or two character tokens.
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
        // NOTE: Include '"' at the beginning and the end.
        string,
        number,

        // Keywords
        keyword_and,
        keyword_class,
        keyword_else,
        keyword_false,
        keyword_for,
        keyword_fun,
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

        invalid,
        eof,

        pub fn lexeme(tag: Tag) ?[]const u8 {
            return switch (tag) {
                // Literals
                .identifier,
                .string,
                .number,
                .eof,
                .invalid,
                => null,

                .l_paren => "(",
                .r_paren => ")",
                .l_brace => "{",
                .r_brace => "}",
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
                .invalid => "an invalid",
                else => unreachable,
            };
        }
    };

    const keywords: std.StaticStringMap(Tag) = .initComptime(.{
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

    pub fn getKeyword(input: []const u8) ?Tag {
        return keywords.get(input);
    }

    pub fn matchKeyword(input: []const u8) ?Tag {
        switch (input[0]) {
            'a' => return checkKeyword(input[1..], "nd", .keyword_and),
            'c' => return checkKeyword(input[1..], "lass", .keyword_class),
            'e' => return checkKeyword(input[1..], "lse", .keyword_else),
            'f' => {
                if (input.len > 1) {
                    switch (input[1]) {
                        'a' => return checkKeyword(input[2..], "lse", .keyword_false),
                        'o' => return checkKeyword(input[2..], "r", .keyword_for),
                        'u' => return checkKeyword(input[2..], "n", .keyword_fun),
                        else => {},
                    }
                }
            },
            'i' => return checkKeyword(input[1..], "f", .keyword_if),
            'n' => return checkKeyword(input[1..], "il", .keyword_nil),
            'o' => return checkKeyword(input[1..], "r", .keyword_or),
            'p' => return checkKeyword(input[1..], "rint", .keyword_print),
            'r' => return checkKeyword(input[1..], "eturn", .keyword_return),
            's' => return checkKeyword(input[1..], "uper", .keyword_super),
            't' => {
                if (input.len > 1) {
                    switch (input[1]) {
                        'h' => return checkKeyword(input[2..], "is", .keyword_this),
                        'r' => return checkKeyword(input[2..], "ue", .keyword_true),
                        else => {},
                    }
                }
            },
            'v' => return checkKeyword(input[1..], "ar", .keyword_var),
            'w' => return checkKeyword(input[1..], "hile", .keyword_while),
            else => {},
        }
        return null;
    }

    fn checkKeyword(actual: []const u8, expected: []const u8, return_tag: Tag) ?Tag {
        if (actual.len == expected.len and mem.eql(u8, actual, expected)) {
            return return_tag;
        }
        return null;
    }
};

test "matchKeyword" {
    try testMatchKeyword("and", .keyword_and);
    try testMatchKeyword("class", .keyword_class);
    try testMatchKeyword("else", .keyword_else);
    try testMatchKeyword("false", .keyword_false);
    try testMatchKeyword("for", .keyword_for);
    try testMatchKeyword("fun", .keyword_fun);
    try testMatchKeyword("flambe", .identifier);
    try testMatchKeyword("if", .keyword_if);
    try testMatchKeyword("nil", .keyword_nil);
    try testMatchKeyword("print", .keyword_print);
    try testMatchKeyword("return", .keyword_return);
    try testMatchKeyword("super", .keyword_super);
    try testMatchKeyword("this", .keyword_this);
    try testMatchKeyword("true", .keyword_true);
    try testMatchKeyword("turbo", .identifier);
    try testMatchKeyword("var", .keyword_var);
    try testMatchKeyword("while", .keyword_while);
    try testMatchKeyword("name", .identifier);
}

fn testMatchKeyword(input: []const u8, expected: Token.Tag) !void {
    const result = Token.matchKeyword(input) orelse .identifier;
    try testing.expectEqual(expected, result);
}

pub const Scanner = struct {
    source: [:0]const u8,
    index: usize,
    line: usize,

    pub fn init(source: [:0]const u8) Scanner {
        return .{
            .source = source,
            .index = 0,
            .line = 1,
        };
    }

    const State = enum {
        start,
        invalid,
        new_line,
        skip_whitespace,

        bang,
        equal,
        less,
        greater,
        slash,

        string_literal,
        number_literal,
        float_literal,

        identifier,

        line_comment,
        // block_comment,
    };

    /// The caller owns the TokenList.
    pub fn scan(self: *Scanner, gpa: Allocator) Allocator.Error!TokenList.Slice {
        var tokens: TokenList = .empty;
        defer tokens.deinit(gpa);

        while (true) {
            const token = self.next();
            try tokens.append(gpa, token);
            if (token.tag == .eof) break;
        }

        return tokens.toOwnedSlice();
    }

    pub fn next(self: *Scanner) Token {
        var result: Token = .{
            .tag = .eof,
            .loc = .{
                .start = @intCast(self.index),
                .end = 0,
            },
            .line = @intCast(self.line),
        };

        state: switch (State.start) {
            .start => switch (self.source[self.index]) {
                0 => {
                    if (self.index == self.source.len) {
                        return .{
                            .tag = .eof,
                            .line = @intCast(self.line),
                            .loc = .{
                                .start = @intCast(self.index),
                                .end = @intCast(self.index),
                            },
                        };
                    } else {
                        continue :state .invalid;
                    }
                },
                '(' => {
                    self.index += 1;
                    result.tag = .l_paren;
                },
                ')' => {
                    self.index += 1;
                    result.tag = .r_paren;
                },
                '{' => {
                    self.index += 1;
                    result.tag = .l_brace;
                },
                '}' => {
                    self.index += 1;
                    result.tag = .r_brace;
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
                ' ', '\r', '\t' => continue :state .skip_whitespace,
                '\n' => continue :state .new_line,
                '!' => continue :state .bang,
                '=' => continue :state .equal,
                '<' => continue :state .less,
                '>' => continue :state .greater,
                '/' => continue :state .slash,
                '"' => continue :state .string_literal,
                '0'...'9' => continue :state .number_literal,
                'a'...'z', 'A'...'Z', '_' => continue :state .identifier,
                else => continue :state .invalid,
            },

            .invalid => {
                self.index += 1;
                switch (self.source[self.index]) {
                    0 => if (self.index == self.source.len) {
                        result.tag = .invalid;
                    } else {
                        continue :state .invalid;
                    },
                    '\n' => result.tag = .invalid,
                    else => continue :state .invalid,
                }
            },

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
                    // '*' => continue :state .block_comment,
                    else => result.tag = .slash,
                }
            },

            .line_comment => {
                self.index += 1;
                switch (self.source[self.index]) {
                    0 => {
                        if (self.index != self.source.len) {
                            continue :state .invalid;
                        }
                        continue :state .start;
                    },
                    '\n' => continue :state .new_line,
                    else => continue :state .line_comment,
                }
            },

            .string_literal => {
                self.index += 1;
                switch (self.source[self.index]) {
                    0 => {
                        if (self.index != self.source.len) {
                            continue :state .invalid;
                        } else {
                            result.tag = .invalid;
                        }
                    },
                    '\n' => {
                        self.line += 1;
                        continue :state .string_literal;
                    },
                    '"' => {
                        self.index += 1;
                        // NOTE: Include '"' at the beginning and the end.
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
                        result.line = @intCast(self.line);
                        result.loc.end = @intCast(self.index);

                        const lexeme = result.lexeme(self.source);
                        result.tag = Token.matchKeyword(lexeme) orelse .identifier;

                        return result;
                    },
                }
            },

            .new_line => {
                self.line += 1;
                continue :state .skip_whitespace;
            },

            .skip_whitespace => {
                self.index += 1;
                result.loc.start = @intCast(self.index);
                continue :state .start;
            },
        }

        result.line = @intCast(self.line);
        result.loc.end = @intCast(self.index);
        return result;
    }
};

/// For debugging purpose
pub fn dump(source: [:0]const u8) !void {
    var scanner: Scanner = .init(source);

    var line: u32 = 0;
    while (true) {
        const token = scanner.next();
        if (line != token.line) {
            try std.debug.print("{d:>4} ", .{token.line});
            line = token.line;
        } else {
            try std.debug.print("   | ", .{});
        }
        try std.debug.print("{d:2} '{s}'\n", .{ token.tag, token.lexeme(source) });

        if (token.tag == .eof) break;
    }
}

test "succeeds scanner" {
    try testScanner("(", 2, "( EOF");
    try testScanner(")", 2, ") EOF");
    try testScanner("{", 2, "{ EOF");
    try testScanner("}", 2, "} EOF");
    try testScanner(",", 2, ", EOF");
    try testScanner(".", 2, ". EOF");
    try testScanner("-", 2, "- EOF");
    try testScanner("+", 2, "+ EOF");
    try testScanner(";", 2, "; EOF");
    try testScanner("*", 2, "* EOF");
    try testScanner("!", 2, "! EOF");
    try testScanner("!=", 2, "!= EOF");
    try testScanner("=", 2, "= EOF");
    try testScanner("==", 2, "== EOF");
    try testScanner("<", 2, "< EOF");
    try testScanner("<=", 2, "<= EOF");
    try testScanner(">", 2, "> EOF");
    try testScanner(">=", 2, ">= EOF");
    try testScanner("/", 2, "/ EOF");
    try testScanner("\r\t", 1, "EOF"); // Ignored characters.
    try testScanner("\n", 1, "EOF"); // Add line by one.
    try testScanner("and", 2, "and EOF");
    try testScanner("class", 2, "class EOF");
    try testScanner("else", 2, "else EOF");
    try testScanner("false", 2, "false EOF");
    try testScanner("for", 2, "for EOF");
    try testScanner("fun", 2, "fun EOF");
    try testScanner("if", 2, "if EOF");
    try testScanner("nil", 2, "nil EOF");
    try testScanner("or", 2, "or EOF");
    try testScanner("print", 2, "print EOF");
    try testScanner("return", 2, "return EOF");
    try testScanner("super", 2, "super EOF");
    try testScanner("this", 2, "this EOF");
    try testScanner("true", 2, "true EOF");
    try testScanner("var", 2, "var EOF");
    try testScanner("while", 2, "while EOF");
    try testScanner("identifier", 2, "identifier EOF");
    try testScanner("123", 2, "123 EOF");
    try testScanner("1.23", 2, "1.23 EOF");
    try testScanner(
        \\ "hello"
    , 2,
        \\"hello" EOF
    );
    try testScanner(
        \\ "hello
        \\ world"
    , 2,
        \\"hello
        \\ world" EOF
    );
    try testScanner(
        \\ // inline comment
    , 1, "EOF");

    try testScanner(
        \\"hello
    , 2, "an invalid EOF");
}

fn testScanner(source: [:0]const u8, expected_len: usize, expected: []const u8) !void {
    const gpa = testing.allocator;

    var stream: Io.Writer.Allocating = .init(gpa);
    defer stream.deinit();

    var writer = &stream.writer;
    var scanner: Scanner = .init(source);

    var tokens = try scanner.scan(gpa);
    defer tokens.deinit(gpa);

    for (0..tokens.len) |index| {
        const token = tokens.get(index);
        if (index > 0) {
            try writer.writeByte(' ');
        }

        if (token.tag == .eof) {
            try writer.print("{s}", .{token.tag.symbol()});
            break;
        } else if (token.tag == .invalid) {
            try writer.print("{s}", .{token.tag.symbol()});
        } else {
            try writer.print("{s}", .{token.lexeme(source)});
        }
    }

    try testing.expectEqual(expected_len, tokens.len);
    try testing.expectEqualSlices(u8, expected, writer.buffered());
}

const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const Allocator = mem.Allocator;
const Io = std.Io;
const MultiArrayList = std.MultiArrayList;
