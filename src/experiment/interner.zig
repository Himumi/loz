pub const Symbol = u32;
pub const SymbolList = []const Symbol;

pub fn resolve(gpa: Allocator, source: [:0]const u8, tokens: TokenList.Slice) !SymbolList {
    var interner: Interner = try .initCapacity(gpa, tokens.len);
    defer interner.deinit(gpa);

    return try interner.resolve(gpa, source, tokens);
}

pub const Interner = struct {
    /// It keeps the mapping tokens.
    recorder: std.array_hash_map.String(Symbol) = .empty,
    /// It stores the tokens same length size.
    /// It empties every iteration.
    result: ArrayList(Symbol) = .empty,
    /// It keeps the counter symbol.
    counter: u32 = 0,

    pub const empty: Interner = .{
        .recorder = .empty,
        .result = .empty,
        .counter = 0,
    };

    pub fn initCapacity(gpa: Allocator, len: usize) Allocator.Error!Interner {
        return .{
            .recorder = .empty,
            .result = try .initCapacity(gpa, len),
            .counter = 0,
        };
    }

    pub fn deinit(self: *Interner, gpa: Allocator) void {
        self.recorder.deinit(gpa);
        self.result.deinit(gpa);
    }

    /// Maps the same lexemes to a symbol.
    /// It has a same length with input tokens.
    pub fn resolve(
        self: *Interner,
        gpa: Allocator,
        source: [:0]const u8,
        tokens: TokenList.Slice,
    ) Allocator.Error!SymbolList {
        for (0..tokens.len) |index| {
            const token = tokens.get(index);
            const lexeme = token.lexeme(source);

            if (self.recorder.get(lexeme)) |symbol| {
                try self.result.append(gpa, symbol);
            } else {
                try self.recorder.put(gpa, lexeme, self.counter);
                try self.result.append(gpa, self.counter);
                self.counter += 1;
            }
        }

        return self.result.toOwnedSlice(gpa);
    }
};

test "interner" {
    const gpa = testing.allocator;
    const source = "var number = 10; print number;";

    var tokens = try tokenizer.scan(gpa, undefined, source);
    defer tokens.deinit(gpa);

    var interner: Interner = .empty;
    defer interner.deinit(gpa);

    const symbols = try interner.resolve(gpa, source, tokens);
    defer gpa.free(symbols);

    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4, 5, 1, 4, 6 }, symbols);
}

const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;

const tokenizer = @import("tokenizer.zig");
const TokenList = tokenizer.TokenList;
