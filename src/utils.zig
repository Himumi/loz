/// Table does not own the memory.
pub const Table = std.StringHashMap(*String);

const std = @import("std");

const values = @import("values.zig");
const String = values.String;
