fn run(gpa: Allocator, ctx: *Context, source: [:0]const u8, is_repl: bool) !void {
    var arena_allocator: ArenaAllocator = .init(gpa);
    defer arena_allocator.deinit();

    // Borrewed ast_tree to interpreter.
    const ast_tree = try analyzer.parse(arena_allocator.allocator(), ctx, source);

    if (is_repl) {
        try interpreter.print(gpa, ctx, ast_tree);
    } else {
        try interpreter.render(gpa, ctx, ast_tree);
    }
}

pub fn runPrompt(gpa: Allocator, ctx: *Context) !void {
    var arena_allocator: ArenaAllocator = .init(gpa);
    defer arena_allocator.deinit();

    const arena = arena_allocator.allocator();
    while (true) {
        defer {
            debug.assert(arena_allocator.reset(.retain_capacity));
            ctx.status.had_error = false;
        }

        try ctx.stream.err.writeAll("> ");
        try ctx.stream.err.flush();

        const line = try readLine(arena, ctx.stream.in);
        run(gpa, ctx, line, true) catch |err| {
            if (ctx.status.had_error) continue; // Keep running REPL.
            if (ctx.status.is_panic) process.exit(70);
            return err;
        };
        try ctx.stream.out.flush();
    }
}

fn readLine(arena: Allocator, reader: *Io.Reader) ![:0]const u8 {
    var recorder: Io.Writer.Allocating = .init(arena);

    var i: usize = 0;
    loop: while (true) : (i += 1) {
        const line = reader.takeDelimiterInclusive('\n') catch |err|
            switch (err) {
                error.EndOfStream => break :loop,
                else => return err,
            };
        try recorder.writer.writeAll(line);

        const end_semicolon = mem.endsWith(u8, line, ";\n");
        const end_block = mem.endsWith(u8, line, "}\n");

        if (i == 0 and (end_semicolon or end_block)) break;
        if (i > 0 and end_block) break;
    }
    return try recorder.toOwnedSliceSentinel(0);
}

pub fn runFile(gpa: Allocator, ctx: *Context) !void {
    var arena_allocator: ArenaAllocator = .init(gpa);
    defer arena_allocator.deinit();

    const arena = arena_allocator.allocator();
    var recorder: Io.Writer.Allocating = .init(arena);

    while (true) {
        const line = ctx.stream.in.takeDelimiterInclusive('\n') catch |err|
            switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
        try recorder.writer.writeAll(line);
    }
    run(gpa, ctx, try recorder.toOwnedSliceSentinel(0), false) catch |err| {
        if (ctx.status.had_error) process.exit(65);
        if (ctx.status.is_panic) process.exit(70);
        return err;
    };
    try ctx.stream.out.flush();
}

const std = @import("std");
const debug = std.debug;
const heap = std.heap;
const mem = std.mem;
const process = std.process;
const Allocator = mem.Allocator;
const ArenaAllocator = heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const Io = std.Io;

const ast_printer = @import("ast_printer.zig");
const analyzer = @import("analyzer.zig");
const tokenizer = @import("tokenizer.zig");
const interpreter = @import("interpreter.zig");
const Context = @import("Context.zig");
const Token = tokenizer.Token;
