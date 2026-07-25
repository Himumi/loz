const Context = @This();

io: Io,
stream: Stream,
status: Status,

pub fn init(io: Io, stream: Stream) Context {
    return .{
        .io = io,
        .stream = stream,
        .status = .{
            .had_error = false,
            .is_panic = false,
        },
    };
}

pub const Stream = struct {
    out: *Io.Writer = undefined,
    err: *Io.Writer = undefined,
    in: *Io.Reader = undefined,

    pub fn init(out: *Io.Writer, err: *Io.Writer, in: *Io.Reader) Stream {
        return .{
            .out = out,
            .err = err,
            .in = in,
        };
    }
};

pub const Status = struct {
    had_error: bool,
    is_panic: bool,
};

/// report prints errors and set had_error to true.
pub fn report(self: *Context, comptime fmt: []const u8, args: anytype) Io.Writer.Error!void {
    try self.stream.err.print(fmt, args);
    try self.stream.err.flush();
    self.status.had_error = true;
}

/// panic stops the runtime and prints errors.
pub fn panic(self: *Context, comptime fmt: []const u8, args: anytype) Io.Writer.Error!void {
    try self.stream.err.print(fmt, args);
    try self.stream.err.flush();
    self.status.is_panic = true;
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Env = @import("EnvSoa.zig");
