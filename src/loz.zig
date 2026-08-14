fn run(gpa: Allocator, ctx: *Context, source: [:0]const u8, is_repl: bool) !void {
    var arena_allocator: ArenaAllocator = .init(gpa);
    defer arena_allocator.deinit();

    const arena = arena_allocator.allocator();

    // Borrewed ast_tree to interpreter.
    var tree = try parser.parse(arena, ctx, source);
    tree.resolved = try resolver.resolve(arena, ctx, tree);
    tree.symbols = try interner.resolve(arena, source, tree.tokens);

    if (ctx.status.had_error) return;

    if (is_repl) {
        try interpreter.print(gpa, ctx, tree);
    } else {
        try interpreter.render(gpa, ctx, tree);
    }
}

pub fn runPrompt(gpa: Allocator, ctx: *Context) !void {
    var arena_allocator: ArenaAllocator = .init(gpa);
    defer arena_allocator.deinit();

    const arena = arena_allocator.allocator();

    var recorder: Io.Writer.Allocating = .init(gpa);
    defer recorder.deinit();

    const writer = &recorder.writer;

    var lexer: Lexer = .empty;
    defer lexer.deinit(gpa);

    var analyzer: Parser = .init(gpa, ctx);
    defer analyzer.deinit();

    var renderer: Renderer = try .init(gpa, ctx);
    defer renderer.deinit();

    while (true) {
        try ctx.stream.err.writeAll("><> ");
        try ctx.stream.err.flush();

        const source_offset = recorder.written().len;
        const tokens_offset = lexer.tokens.len;

        try readLine(writer, ctx.stream.in);

        const line = try recorder.toOwnedSliceSentinel(0);
        defer gpa.free(line);

        // Parse the new line.
        try lexer.scan(gpa, ctx, line, source_offset);
        try analyzer.parse(line, lexer.slice(), tokens_offset);

        // Borrow the memory.
        var tree = analyzer.slice();

        // Resolve the escaped variables and symbols.
        tree.resolved = try resolver.resolve(arena, ctx, tree);
        tree.symbols = try interner.resolve(arena, line, tree.tokens);

        const last_node = tree.roots[tree.roots.len - 1];

        // Evaluate the current line.
        const object = try renderer.execute(tree, last_node);
        if (object != .nil) {
            try renderer.dumpln(ctx.stream.out, object);
        }

        // Move back the memory to the recorder for the next evaluation.
        try recorder.writer.writeAll(line);

        _ = arena_allocator.reset(.retain_capacity);
        ctx.status.had_error = false;

        try ctx.stream.out.flush();
    }
}

fn readLine(writer: *Io.Writer, reader: *Io.Reader) !void {
    var i: usize = 0;
    loop: while (true) : (i += 1) {
        const line = reader.takeDelimiterInclusive('\n') catch |err|
            switch (err) {
                error.EndOfStream => break :loop,
                else => return err,
            };
        try writer.writeAll(line);

        const end_semicolon = mem.endsWith(u8, line, ";\n");
        const end_block = mem.endsWith(u8, line, "}\n");

        if (i == 0 and (end_semicolon or end_block)) break;
        if (i > 0 and end_block) break;
    }
}

pub fn runFile(gpa: Allocator, ctx: *Context) !void {
    var arena_allocator: ArenaAllocator = .init(gpa);
    defer arena_allocator.deinit();

    const arena = arena_allocator.allocator();
    var recorder: ArrayList(u8) = .empty;

    while (true) {
        const line = ctx.stream.in.takeDelimiterInclusive('\n') catch |err|
            switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
        try recorder.appendSlice(arena, line);
    }
    run(gpa, ctx, try recorder.toOwnedSliceSentinel(arena, 0), false) catch |err| {
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

// const analyzer = @import("analyzer.zig");
const ast_printer = @import("ast_printer.zig");
const Context = @import("Context.zig");
const interner = @import("interner.zig");
const interpreter = @import("interpreter.zig");
const parser = @import("parser.zig");
const resolver = @import("resolver.zig");
const tokenizer = @import("tokenizer.zig");
const Lexer = tokenizer.Lexer;
const Token = tokenizer.Token;
const Parser = parser.Parser;
const Renderer = interpreter.Renderer;
