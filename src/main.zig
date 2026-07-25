var stdout_buffer: [8192]u8 = undefined;
var stderr_buffer: [4096]u8 = undefined;
var stdin_buffer: [4096]u8 = undefined;

pub fn main(init: std.process.Init) !void {
    var debug_allocator: DebugAllocator(.{}) = .init;
    defer debug.assert(debug_allocator.deinit() == .ok);

    const io = init.io;
    const gpa = debug_allocator.allocator();

    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_writer = Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 2) {
        try printTo(stderr, "Usage: Loz [script]\n", .{});
        std.process.exit(64);
    }

    const file = try openFile(io, args);
    defer file.close(io);

    var file_reader = file.reader(io, &stdin_buffer);
    const reader = &file_reader.interface;

    var ctx: Context = .init(io, .init(stdout, stderr, reader));
    if (args.len == 1) {
        try loz.runPrompt(gpa, &ctx); // Run interactive prompt (REPL)
    } else {
        try loz.runFile(gpa, &ctx); // Compile the file.
    }
    try stdout.flush();
}

fn openFile(io: Io, args: []const []const u8) !Io.File {
    if (args.len == 2) {
        return Io.Dir.cwd().openFile(io, args[1], .{});
    }
    return Io.File.stdin();
}

fn printTo(writer: *Io.Writer, comptime fmt: []const u8, args: anytype) !void {
    try writer.print(fmt, args);
    try writer.flush();
}

fn Clock() ast.Object {
    const clockCall = struct {
        pub fn call(
            ptr: *anyopaque,
            gpa: Allocator,
            ctx: *Context,
            args: []const ast.Object,
        ) anyerror!ast.Object {
            _ = .{ ptr, gpa, ctx, args };
            const clock: std.Io.Clock = .real;
            const timestamp: i64 = @divTrunc(clock.now(ctx.io).toMilliseconds(), 1000);
            return .{
                .number = @floatFromInt(timestamp),
            };
        }
    }.call;

    return .{ .callable = .{
        .arity = 0,
        .callFn = clockCall,
    } };
}

const std = @import("std");
const debug = std.debug;
const heap = std.heap;
const mem = std.mem;
const Allocator = mem.Allocator;
const DebugAllocator = heap.DebugAllocator;
const Io = std.Io;

const ast = @import("ast.zig");
const Context = @import("Context.zig");
const Env = @import("EnvSoa.zig");
const loz = @import("loz.zig");
