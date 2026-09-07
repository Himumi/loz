pub fn compile(
    gpa: Allocator,
    ctx: *Context,
    strings: *Strings,
    source: [:0]const u8,
) CompilerError!Chunk {
    var compiler: Compiler = .init(gpa, source);
    defer compiler.deinit();
    return try compiler.compile(ctx, strings);
}

pub const CompilerError =
    Compiler.Error ||
    Allocator.Error ||
    Io.Writer.Error;

const LoopContext = struct {
    continue_index: offset,
    break_statements: std.ArrayList(offset),

    pub fn init(continue_index: offset) LoopContext {
        return .{
            .continue_index = continue_index,
            .break_statements = .empty,
        };
    }

    pub fn deinit(self: *LoopContext, gpa: Allocator) void {
        self.break_statements.deinit(gpa);
    }

    const offset = usize;
};

pub const Compiler = struct {
    allocator: Allocator,
    /// Borrow from the caller.
    source: [:0]const u8,
    /// Borrow from the caller.
    strings: *Strings,
    /// Borrow from the caller.
    ctx: *Context,
    /// Borrow from the caller.
    chunk: *Chunk.Builder,

    global_symbols: std.AutoHashMap(*String, u32),
    loop_ctx: std.ArrayList(*LoopContext),
    scanner: Scanner,
    scope: utils.Scope,

    current: Token,
    previous: Token,

    had_error: bool,
    panic_mode: bool,

    // TODO: Need a better error message.
    pub const Error = error{
        InvalidToken,
        ExpectedExpression,
        ExpectedLeftParen,
        TooManyConstants,
        TooManyLocalVariables,
        InvalidCharacter,
    };

    pub const Precedence = enum(u8) {
        none,
        assignment,
        @"or",
        @"and",
        equality,
        comparison,
        term,
        factor,
        unary,
        call,
        primary,
    };

    pub const Rule = struct {
        prefix: Kind = .null,
        infix: Kind = .null,
        precedence: Precedence = .none,

        pub const empty: Rule = .{
            .prefix = .null,
            .infix = .null,
            .precedence = .none,
        };

        pub const Kind = enum {
            null,
            number,
            string,
            @"and",
            @"or",
            group,
            unary,
            binary,
            literal,
            variable,
        };
    };

    const RuleList = std.EnumArray(Token.Tag, Rule);

    pub fn init(gpa: Allocator, source: [:0]const u8) Compiler {
        return .{
            .allocator = gpa,
            .source = source,
            .ctx = undefined,
            .strings = undefined,

            .chunk = undefined,
            .scanner = .init(source),

            .scope = .empty,
            .global_symbols = .init(gpa),
            .loop_ctx = .empty,

            .current = undefined,
            .previous = undefined,

            .had_error = false,
            .panic_mode = false,
        };
    }

    pub fn deinit(self: *Compiler) void {
        self.global_symbols.deinit();
        self.loop_ctx.deinit(self.allocator);
    }

    pub fn compile(self: *Compiler, ctx: *Context, strings: *Strings) CompilerError!Chunk {
        // Initialize the chunk here to prevent mismatching memory ownership.
        var chunk: Chunk.Builder = .empty;
        defer chunk.deinit(self.allocator);

        // Borrow the chunk memory.
        self.chunk = &chunk;
        // Borrow the context memory.
        self.ctx = ctx;
        // Borrow the Strings memory.
        self.strings = strings;

        // Make sure to false at start up.
        self.had_error = false;
        self.panic_mode = false;

        // Add the first token.
        try self.advance();

        // Compile one expression.
        while (self.current.tag != .eof) {
            try self.declaration();
        }
        try self.consume(.eof, "Expect end of expression.");

        try self.emitReturn();
        // if (!self.had_error) {
        // }

        // The caller ownes the ownership.
        return try chunk.toOwnedSlice(self.allocator);
    }

    fn declaration(self: *Compiler) CompilerError!void {
        switch (self.current.tag) {
            .keyword_var => {
                try self.advance();
                try self.varDeclaration();
            },
            else => try self.statement(),
        }
        // TODO: Move this sync function to compile function with another error handling.
        if (self.panic_mode) try self.sync();
    }

    fn varDeclaration(self: *Compiler) CompilerError!void {
        const previous_line = self.previous.line;
        try self.consume(.identifier, "Expect variable name.");

        const global_index = try self.parseVariableName();

        if (self.current.tag == .equal) {
            try self.advance();
            try self.expression();
        } else {
            try self.emitByte(.op_nil);
        }
        try self.consume(.semicolon, "Expect ';' after variable expression.");

        try self.defineVariable(global_index, previous_line);
    }

    fn parseVariableName(self: *Compiler) !u32 {
        try self.declareVariable();
        if (self.scope.depth > 0) return 0;

        return try self.identifierConstant(self.previous);
    }

    fn declareVariable(self: *Compiler) CompilerError!void {
        // NOTE: Immediately return if the current declaration in global scope.
        if (self.scope.depth == 0) return;
        const token = self.previous;

        if (self.scope.count > 0) {
            var index: isize = self.scope.count - 1;
            while (index >= 0) : (index -= 1) {
                const local = self.scope.locals[@intCast(index)];

                if (local.depth) |depth| {
                    if (depth < self.scope.depth) break;
                }

                if (token.equalLexeme(self.source, local.token)) {
                    try self.errorAt(token, "Already a variable with this name in this scope.");
                }
            }
        }

        self.scope.add(token) catch |err| {
            try self.errorAt(self.previous, "Too many local variables in scope.");
            return err;
        };
    }

    fn defineVariable(self: *Compiler, global_index: u32, line: u32) !void {
        if (self.scope.depth > 0) return self.scope.mark();

        const code: Chunk.Code = if (global_index < values.max_u8)
            .op_define_global
        else
            .op_define_global_long;

        try self.emitByte(code);
        try self.emitLiteral(global_index, line);
    }

    fn resolveLocal(self: *Compiler, token: Token) Io.Writer.Error!?u32 {
        if (self.scope.count == 0) return null;

        var index: isize = self.scope.count - 1;
        while (index >= 0) : (index -= 1) {
            const local = self.scope.locals[@intCast(index)];

            if (!token.equalLexeme(self.source, local.token)) continue;

            if (local.depth == null) {
                // TODO: Need to return an error.
                try self.errorAt(token, "Can't read local variable in its own initializer.");
            }
            return @intCast(index);
        }
        return null;
    }

    fn identifierConstant(self: *Compiler, token: Token) !u32 {
        const lexeme = token.lexeme(self.source);

        const head = try self.putToStrings(lexeme);
        return try self.makeConstant(.{ .object = head });
    }

    fn statement(self: *Compiler) CompilerError!void {
        switch (self.current.tag) {
            .keyword_print => {
                try self.advance();
                try self.printStatement();
            },
            .keyword_if => {
                try self.advance();
                try self.ifStatement();
            },
            .keyword_while => {
                try self.advance();
                try self.whileStatement();
            },
            .keyword_for => {
                try self.advance();
                try self.forStatement();
            },
            .l_brace => {
                try self.advance();

                self.beginScope();
                try self.block();
                try self.endScope();
            },
            .keyword_break => try self.breakStatement(),
            .keyword_continue => try self.continueStatement(),
            else => try self.expressionStatement(),
        }
    }

    fn printStatement(self: *Compiler) CompilerError!void {
        try self.expression();
        try self.consume(.semicolon, "Expect ';' after value.");
        try self.emitByte(.op_print);
    }

    fn expressionStatement(self: *Compiler) CompilerError!void {
        try self.expression();
        try self.consume(.semicolon, "Expect ';' after value.");
        try self.emitByte(.op_pop);
    }

    fn ifStatement(self: *Compiler) CompilerError!void {
        try self.consume(.l_paren, "Expect '(' after 'if'.");
        try self.expression();
        try self.consume(.r_paren, "Expect ')' after condition.");

        const then_index = try self.emitJump(.op_jump_if_false);
        try self.emitByte(.op_pop);
        try self.statement();

        const else_index = try self.emitJump(.op_jump);
        try self.patchJump(@intCast(then_index));

        try self.emitByte(.op_pop);
        if (self.current.tag == .keyword_else) {
            try self.advance();
            try self.statement();
        }
        try self.patchJump(else_index);
    }

    fn whileStatement(self: *Compiler) CompilerError!void {
        // Condition
        const loop_start = self.chunk.codes.items.len;
        try self.consume(.l_paren, "Expect '(' after 'while'.");
        try self.expression();
        try self.consume(.r_paren, "Expect ')' after condition.");

        var loop_ctx: LoopContext = .init(loop_start);
        defer loop_ctx.deinit(self.allocator);

        try self.loop_ctx.append(self.allocator, &loop_ctx);

        const exit_index = try self.emitJump(.op_jump_if_false);
        try self.emitByte(.op_pop);

        // Statement Body.
        try self.statement();
        try self.emitLoop(loop_start);

        try self.patchJump(exit_index);
        try self.emitByte(.op_pop);

        // Patch the 'break' statements.
        for (loop_ctx.break_statements.items) |break_index| {
            try self.patchJump(@intCast(break_index));
        }
        _ = self.loop_ctx.pop();
    }

    fn forStatement(self: *Compiler) CompilerError!void {
        var loop_ctx: LoopContext = .init(undefined);
        defer loop_ctx.deinit(self.allocator);

        try self.loop_ctx.append(self.allocator, &loop_ctx);
        self.beginScope();

        // Initializer
        try self.consume(.l_paren, "Expect '(' after 'for'.");
        switch (self.current.tag) {
            .semicolon => try self.advance(),
            .keyword_var => {
                try self.advance();
                try self.varDeclaration();
            },
            else => try self.expressionStatement(),
        }

        // Condition
        var loop_start = self.chunk.codes.items.len;
        var exit_index: ?u32 = null;

        loop_ctx.continue_index = loop_start;

        if (self.current.tag != .semicolon) {
            try self.expression();
            try self.consume(.semicolon, "Expect ';' after loop condition.");

            exit_index = try self.emitJump(.op_jump_if_false);
            try self.emitByte(.op_pop);
        }

        // Increment Clause
        if (self.current.tag != .r_paren) {
            const body_index = try self.emitJump(.op_jump);
            const increment_start = self.chunk.codes.items.len;

            loop_ctx.continue_index = increment_start;

            try self.expression();
            try self.emitByte(.op_pop);

            try self.consume(.r_paren, "Expect ')' after for clauses.");

            try self.emitLoop(loop_start);
            try self.patchJump(body_index);

            // Set the loop starting point to increment part.
            loop_start = increment_start;
        }

        // Statement Body
        try self.statement();
        try self.emitLoop(loop_start);

        if (exit_index) |index| {
            try self.patchJump(index);
            try self.emitByte(.op_pop);
        }
        try self.endScope();

        // Patch the 'break' statements.
        for (loop_ctx.break_statements.items) |break_index| {
            try self.patchJump(@intCast(break_index));
        }
        _ = self.loop_ctx.pop();
    }

    fn breakStatement(self: *Compiler) CompilerError!void {
        try self.consume(.keyword_break, "Expect 'break'.");
        if (self.loop_ctx.items.len == 0) {
            return try self.errorAt(self.previous, "Can't use 'break' outside of a loop.");
        }

        try self.consume(.semicolon, "Expect ';' after 'break'.");
        const loop_ctx = self.loop_ctx.getLast();

        const break_index = try self.emitJump(.op_jump);
        try loop_ctx.break_statements.append(self.allocator, break_index);
    }

    fn continueStatement(self: *Compiler) CompilerError!void {
        try self.consume(.keyword_continue, "Expect 'continue'.");

        if (self.loop_ctx.items.len == 0) {
            return try self.errorAt(self.previous, "Can't use 'continue' outside of a loop.");
        }
        try self.consume(.semicolon, "Expect ';' after 'continue'.");

        const loop_ctx = self.loop_ctx.getLast();
        try self.emitLoop(loop_ctx.continue_index);
    }

    fn expression(self: *Compiler) CompilerError!void {
        try self.parsePrecedence(.assignment);
    }

    fn block(self: *Compiler) CompilerError!void {
        while (self.current.tag != .r_brace and self.current.tag != .eof) {
            try self.declaration();
        }
        try self.consume(.r_brace, "Expect '}' after block.");
    }

    fn parsePrecedence(self: *Compiler, precedence: Precedence) CompilerError!void {
        try self.advance();

        const prefix_rule = rules.get(self.previous.tag).prefix;
        if (prefix_rule == .null) {
            return try self.errorAt(self.previous, "Expect Expression.");
        }

        const prece_int = @intFromEnum(precedence);
        const assign_int = @intFromEnum(Precedence.assignment);

        const assignable = prece_int <= assign_int;
        try self.parseRule(prefix_rule, assignable);

        while (true) {
            const curr_prece = rules.get(self.current.tag).precedence;
            const curr_prece_int = @intFromEnum(curr_prece);

            if (prece_int > curr_prece_int) break;
            try self.advance();

            const infix_rule = rules.get(self.previous.tag).infix;
            try self.parseRule(infix_rule, assignable);
        }

        if (assignable and self.current.tag == .equal) {
            try self.errorAt(self.current, "Invalid assignment target.");
            try self.advance();
        }
    }

    fn parseRule(self: *Compiler, rule: Rule.Kind, assignable: bool) CompilerError!void {
        switch (rule) {
            .literal => try self.parseLiteral(),
            .number => try self.parseNumber(),
            .string => try self.parseString(),
            .@"and" => try self.parseAnd(),
            .@"or" => try self.parseOr(),
            .group => try self.parseGroup(),
            .binary => try self.parseBinary(),
            .unary => try self.parseUnary(),
            .variable => try self.parseVariable(assignable),
            .null => {},
        }
    }

    fn parseLiteral(self: *Compiler) CompilerError!void {
        switch (self.previous.tag) {
            .keyword_false => try self.emitByte(.op_false),
            .keyword_nil => try self.emitByte(.op_nil),
            .keyword_true => try self.emitByte(.op_true),
            else => unreachable,
        }
    }

    fn parseNumber(self: *Compiler) !void {
        const value = try fmt.parseFloat(f64, self.previous.lexeme(self.source));
        try self.emitConstant(.{ .number = value });
    }

    fn parseString(self: *Compiler) !void {
        const lexeme = self.previous.lexeme(self.source);
        const str = lexeme[1 .. lexeme.len - 1];

        const head = try self.putToStrings(str);
        try self.emitConstant(.{ .object = head });
    }

    fn parseAnd(self: *Compiler) !void {
        const end_index = try self.emitJump(.op_jump_if_false);

        try self.emitByte(.op_pop);
        try self.parsePrecedence(.@"and");

        try self.patchJump(end_index);
    }

    fn parseOr(self: *Compiler) !void {
        const else_index = try self.emitJump(.op_jump_if_false);
        const end_index = try self.emitJump(.op_jump);

        try self.patchJump(else_index);
        try self.emitByte(.op_pop);

        try self.parsePrecedence(.@"or");
        try self.patchJump(end_index);
    }

    fn parseGroup(self: *Compiler) CompilerError!void {
        try self.expression();
        try self.consume(.r_paren, "Expect ')' after expression.");
    }

    fn parseUnary(self: *Compiler) CompilerError!void {
        const operator_tag = self.previous.tag;

        try self.parsePrecedence(.unary);
        switch (operator_tag) {
            .minus => try self.emitByte(.op_negate),
            .bang => try self.emitByte(.op_not),
            else => unreachable,
        }
    }

    fn parseBinary(self: *Compiler) CompilerError!void {
        const operator_tag = self.previous.tag;

        const rule = rules.get(operator_tag);
        const precedence_int = @intFromEnum(rule.precedence);

        // Need to higher up the precedence.
        const next_precedence: Precedence = @enumFromInt(precedence_int + 1);
        try self.parsePrecedence(next_precedence);

        switch (operator_tag) {
            .bang_equal => {
                try self.emitByte(.op_equal);
                try self.emitByte(.op_not);
            },
            .equal_equal => try self.emitByte(.op_equal),
            .greater => try self.emitByte(.op_greater),
            .greater_equal => {
                try self.emitByte(.op_less);
                try self.emitByte(.op_not);
            },
            .less => try self.emitByte(.op_less),
            .less_equal => {
                try self.emitByte(.op_greater);
                try self.emitByte(.op_not);
            },
            .plus => try self.emitByte(.op_add),
            .minus => try self.emitByte(.op_subtract),
            .star => try self.emitByte(.op_multiply),
            .slash => try self.emitByte(.op_divide),
            else => unreachable,
        }
    }

    fn parseVariable(self: *Compiler, assignable: bool) CompilerError!void {
        try self.namedVariable(self.previous, assignable);
    }

    fn namedVariable(self: *Compiler, token: Token, assignable: bool) CompilerError!void {
        const local_index = try self.resolveLocal(token);
        const arg_index: u32 = if (local_index) |index|
            index
        else
            try self.identifierConstant(token);

        const is_short = arg_index < values.max_u8;
        const is_assignable = assignable and self.current.tag == .equal;

        if (is_assignable) {
            try self.advance();
            try self.expression();
        }

        const code: Chunk.Code = blk: {
            if (is_assignable and local_index != null) {
                break :blk if (is_short)
                    .op_set_local
                else
                    .op_set_local_long;
            }

            if (is_assignable and local_index == null) {
                break :blk if (is_short)
                    .op_set_global
                else
                    .op_set_global_long;
            }

            if (!is_assignable and local_index != null) {
                break :blk if (is_short)
                    .op_get_local
                else
                    .op_get_local_long;
            }

            break :blk if (is_short)
                .op_get_global
            else
                .op_get_global_long;
        };

        try self.emitByte(code);
        try self.emitLiteral(arg_index, token.line);
    }

    fn advance(self: *Compiler) Io.Writer.Error!void {
        self.previous = self.current;

        while (true) {
            self.current = self.scanner.next();
            if (self.current.tag != .invalid) break;
            // TODO: Create invalid token validator.
            try self.errorAt(self.current, "Invalid token.");
        }
    }

    // TODO: Need a better error handling.
    fn errorAt(self: *Compiler, token: Token, message: []const u8) Io.Writer.Error!void {
        if (self.panic_mode) return;
        self.panic_mode = true;

        // TODO: Use Global Context for stderr.
        try self.ctx.stream.err.print("[line {}] Error", .{token.line});

        switch (token.tag) {
            .eof => try self.ctx.stream.err.print(" at end", .{}),
            .invalid => {
                // Nothing
            },
            else => try self.ctx.stream.err.print(" at '{s}'", .{token.lexeme(self.source)}),
        }

        try self.ctx.stream.err.print(": {s}\n", .{message});
        self.had_error = true;
    }

    fn consume(self: *Compiler, tag: Token.Tag, message: []const u8) Io.Writer.Error!void {
        if (self.current.tag == tag) {
            return try self.advance();
        }
        try self.errorAt(self.current, message);
    }

    fn makeConstant(self: *Compiler, value: Value) (Allocator.Error || Io.Writer.Error)!u32 {
        // Prevent deduplication for constant values.
        for (self.chunk.constants.items, 0..) |constant, index| {
            if (constant.isEqual(value)) return @intCast(index);
        }

        const index = try self.chunk.addValue(self.allocator, value);
        if (index > values.max_u24) { // Update based on constant long.
            // TODO: Need an error.
            try self.errorAt(self.previous, "Too many constants in one chunk");
            return 0;
        }
        return index;
    }

    fn emitByte(self: *Compiler, code: Chunk.Code) Allocator.Error!void {
        try self.chunk.writeChunk(self.allocator, code, self.previous.line);
    }

    fn emitConstant(self: *Compiler, value: Value) (Allocator.Error || Io.Writer.Error)!void {
        const value_index = try self.makeConstant(value);
        try self.chunk.writeConstant(self.allocator, @intCast(value_index), self.previous.line);
    }

    fn emitJump(self: *Compiler, instruction: Chunk.Code) !u32 {
        try self.emitByte(instruction);

        try self.emitByte(.op_empty);
        try self.emitByte(.op_empty);

        return @intCast(self.chunk.codes.items.len - 2);
    }

    fn patchJump(self: *Compiler, offset: u32) !void {
        const jump_index = self.chunk.codes.items.len - offset - 2;
        if (jump_index > values.max_u16) {
            try self.errorAt(self.current, "Too much code to jump over.");
        }

        for (utils.writeU16(@intCast(jump_index)), offset..) |byte, index| {
            self.chunk.codes.items[index] = byte;
        }
    }

    fn emitLiteral(self: *Compiler, index: u32, line: u32) Allocator.Error!void {
        if (index < values.max_u8) {
            try self.chunk.writeLiteral(self.allocator, @intCast(index), line);
        } else {
            for (utils.writeU24(index)) |byte| {
                try self.chunk.writeLiteral(self.allocator, byte, line);
            }
        }
    }

    fn emitLoop(self: *Compiler, loop_start: usize) !void {
        try self.emitByte(.op_loop);

        const offset = self.chunk.codes.items.len - loop_start + 2;
        if (offset > values.max_u16) {
            try self.errorAt(self.previous, "Loop body too large.");
        }

        for (utils.writeU16(@intCast(offset))) |byte| {
            try self.emitByte(@enumFromInt(byte));
        }
    }

    fn emitReturn(self: *Compiler) Allocator.Error!void {
        try self.emitByte(.op_return);
    }

    fn endCompiler(self: *Compiler) Allocator.Error!void {
        try self.emitReturn();
    }

    fn beginScope(self: *Compiler) void {
        self.scope.depth += 1;
    }

    fn endScope(self: *Compiler) !void {
        // TODO: Need an error handling if it is being called in global scope.
        if (self.scope.depth == 0) return;
        self.scope.depth -= 1;

        while (self.scope.count > 0) : (self.scope.count -= 1) {
            const local = self.scope.locals[self.scope.count - 1];
            if (local.depth) |depth| {
                if (depth <= self.scope.depth) break;
            }
            try self.emitByte(.op_pop);
        }
    }

    fn putToStrings(self: *Compiler, str: []const u8) !*Object {
        const gop = try self.strings.getOrPut(str);
        if (!gop.found_existing) {
            const string_object = try self.allocator.create(String);
            errdefer self.allocator.destroy(string_object);

            string_object.* = .init(.@"const", str, Object{
                .kind = .string,
                .next = null,
            });

            gop.value_ptr.* = string_object;
        }
        return &gop.value_ptr.*.head;
    }

    fn sync(self: *Compiler) CompilerError!void {
        self.panic_mode = false;

        while (self.current.tag != .eof) {
            if (self.previous.tag == .keyword_return) return;
            switch (self.current.tag) {
                .keyword_class,
                .keyword_fun,
                .keyword_var,
                .keyword_for,
                .keyword_if,
                .keyword_while,
                .keyword_print,
                .keyword_return,
                => return,
                else => {},
            }
            try self.advance();
        }
    }

    const rules: RuleList = .initDefault(Rule.empty, .{
        .l_paren = .{
            .prefix = .group,
            .infix = .null,
            .precedence = .none,
        },
        .plus = .{
            .prefix = .null,
            .infix = .binary,
            .precedence = .term,
        },
        .minus = .{
            .prefix = .unary,
            .infix = .binary,
            .precedence = .term,
        },
        .slash = .{
            .prefix = .null,
            .infix = .binary,
            .precedence = .factor,
        },
        .star = .{
            .prefix = .null,
            .infix = .binary,
            .precedence = .factor,
        },
        .number = .{
            .prefix = .number,
            .infix = .null,
            .precedence = .none,
        },
        .string = .{
            .prefix = .string,
            .infix = .null,
            .precedence = .none,
        },
        .identifier = .{
            .prefix = .variable,
            .infix = .null,
            .precedence = .none,
        },
        .keyword_and = .{
            .prefix = .null,
            .infix = .@"and",
            .precedence = .@"and",
        },
        .keyword_or = .{
            .prefix = .null,
            .infix = .@"or",
            .precedence = .@"or",
        },
        .keyword_nil = .{
            .prefix = .literal,
            .infix = .null,
            .precedence = .none,
        },
        .keyword_false = .{
            .prefix = .literal,
            .infix = .null,
            .precedence = .none,
        },
        .keyword_true = .{
            .prefix = .literal,
            .infix = .null,
            .precedence = .none,
        },
        .bang = .{
            .prefix = .unary,
            .infix = .null,
            .precedence = .none,
        },
        .bang_equal = .{
            .prefix = .null,
            .infix = .binary,
            .precedence = .equality,
        },
        .equal_equal = .{
            .prefix = .null,
            .infix = .binary,
            .precedence = .equality,
        },
        .greater = .{
            .prefix = .null,
            .infix = .binary,
            .precedence = .comparison,
        },
        .greater_equal = .{
            .prefix = .null,
            .infix = .binary,
            .precedence = .comparison,
        },
        .less = .{
            .prefix = .null,
            .infix = .binary,
            .precedence = .comparison,
        },
        .less_equal = .{
            .prefix = .null,
            .infix = .binary,
            .precedence = .comparison,
        },
    });
};

const std = @import("std");
const math = std.math;
const mem = std.mem;
const fmt = std.fmt;
const testing = std.testing;

const Allocator = mem.Allocator;
const Io = std.Io;

const tokenizer = @import("tokenizer.zig");
const utils = @import("utils.zig");
const values = @import("values.zig");
const Chunk = @import("Chunk.zig");
const Context = @import("Context.zig");
const Strings = utils.Strings;
const Object = values.Object;
const String = values.String;
const Value = values.Value;
const Scanner = tokenizer.Scanner;
const Token = tokenizer.Token;
