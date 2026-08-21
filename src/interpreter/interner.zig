pub const Symbol = u32;
pub const SymbolList = []const Symbol;

pub fn resolve(gpa: Allocator, source: [:0]const u8, tokens: TokenList.Slice) !SymbolList {
    var interner: Interner = try .initCapacity(gpa, tokens.len);
    defer interner.deinit();

    return try interner.resolve(source, tokens);
}

pub const Interner = struct {
    allocator: Allocator,
    /// It keeps the mapping tokens.
    recorder: std.StringHashMap(Symbol),
    /// It stores the tokens same length size.
    /// It empties every iteration.
    result: ArrayList(Symbol) = .empty,
    /// It keeps the counter symbol.
    counter: u32 = @intCast(Token.keywords.values().len),

    pub fn init(gpa: Allocator) Interner {
        return .{
            .allocator = gpa,
            .recorder = .init(gpa),
            .result = .empty,
            .counter = @intCast(Token.keywords.values().len),
        };
    }

    pub fn initCapacity(gpa: Allocator, len: usize) Allocator.Error!Interner {
        return .{
            .allocator = gpa,
            .recorder = .init(gpa),
            .result = try .initCapacity(gpa, len),
            .counter = @intCast(Token.keywords.values().len),
        };
    }

    pub fn deinit(self: *Interner) void {
        self.recorder.deinit();
        self.result.deinit(self.allocator);
    }

    /// Maps the same lexemes to a symbol.
    /// It has a same length with input tokens.
    pub fn resolve(
        self: *Interner,
        source: [:0]const u8,
        tokens: TokenList.Slice,
    ) Allocator.Error!SymbolList {
        for (0..tokens.len) |index| {
            const token = tokens.get(index);
            const lexeme = token.lexeme(source);

            if (Token.keywords.get(lexeme)) |symbol| {
                try self.result.append(self.allocator, @intFromEnum(symbol));
            } else if (self.recorder.get(lexeme)) |symbol| {
                try self.result.append(self.allocator, symbol);
            } else {
                try self.recorder.put(lexeme, self.counter);
                try self.result.append(self.allocator, self.counter);
                self.counter += 1;
            }
        }

        return self.result.toOwnedSlice(self.allocator);
    }
};

test "interner" {
    const gpa = testing.allocator;
    const source = "var number = 10; print number;";

    var tokens = try tokenizer.scan(gpa, undefined, source);
    defer tokens.deinit(gpa);

    var interner: Interner = .init(gpa);
    defer interner.deinit();

    const symbols = try interner.resolve(source, tokens);
    defer gpa.free(symbols);

    try testing.expectEqualSlices(u32, &.{ 14, 16, 17, 18, 19, 9, 16, 19, 20 }, symbols);
}

const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;

const tokenizer = @import("tokenizer.zig");
const Token = tokenizer.Token;
const TokenList = tokenizer.TokenList;
