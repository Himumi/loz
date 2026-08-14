pub fn parse(gpa: Allocator, ctx: *Ctx, source: [:0]const u8) !ast.Ast {
    var tokens = try tokenizer.scan(gpa, ctx, source);
    errdefer tokens.deinit(gpa);

    var parser: Parser = .init(gpa, ctx);
    defer parser.deinit();

    try parser.parse(source, tokens, 0);
    return try parser.toOwnSlice();
}

const PaserError =
    Parser.Error ||
    Allocator.Error ||
    Io.Writer.Error ||
    fmt.ParseFloatError;

pub const Parser = struct {
    allocator: Allocator,
    ctx: *Ctx,
    index: usize = 0,

    /// It borrowed the memory.
    source: [:0]const u8,
    tokens: TokenList.Slice,

    // The results
    roots: ArrayList(u32) = .empty,
    nodes: ast.NodeList = .empty,
    literals: ArrayList(ast.Value) = .empty,
    extra: ArrayList(u32) = .empty,

    pub const Error = error{
        ExpectedLeftParen,
        ExpectedLeftBrace,
        ExpectedRightParen,
        ExpectedRightBrace,
        ExpectedAnExpression,
        ExpectedSemicolon,
        ExpectedVariableName,
        ExpectedFunctionName,
        ExpectedClassName,
        ExpectedParameterName,
        ExpectedPropertyName,
        InvalidAssignmentTarget,
        TooManyArguments,
        TooManyParameters,
    };

    pub fn init(gpa: Allocator, ctx: *Ctx) Parser {
        return .{
            .allocator = gpa,
            .ctx = ctx,
            .source = undefined,
            .tokens = undefined,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.roots.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.literals.deinit(self.allocator);
        self.extra.deinit(self.allocator);
    }

    /// Parse the tokens to AST nodes.
    /// It does not reset the index tracker.
    ///
    /// NOTE: The caller has to Append new data to the previous
    /// to keep parsing follows the previous index tracker.
    pub fn parse(
        self: *Parser,
        /// Borrow the source memory.
        source: [:0]const u8,
        /// Borrow the tokens memory.
        tokens: TokenList.Slice,
        offset: usize,
    ) PaserError!void {
        self.source = source;
        self.tokens = tokens;
        self.index = offset;

        while (self.current().tag != .eof) {
            if (self.declaration()) |parent_index| {
                try self.roots.append(self.allocator, @intCast(parent_index));
            } else |err| {
                try self.report(err);
                try self.sync();
            }
        }
    }

    /// The caller borrows the memory temporary.
    pub fn slice(self: Parser) ast.Ast {
        return .{
            .source = self.source,

            .roots = self.roots.items,
            .nodes = self.nodes.slice(),
            .tokens = self.tokens,
            .literals = self.literals.items,

            .symbols = &.{},
            .resolved = undefined,
            .extra = self.extra.items,
        };
    }

    /// The caller owns the memory. Resets the struct's state.
    pub fn toOwnSlice(self: *Parser) !ast.Ast {
        self.index = 0;

        const roots = try self.roots.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(roots);

        var nodes = self.nodes.toOwnedSlice();
        errdefer nodes.deinit(self.allocator);

        const literals = try self.literals.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(literals);

        const extra = try self.extra.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(extra);

        return .{
            .source = self.source,

            .roots = roots,
            .nodes = nodes,
            .tokens = self.tokens,
            .literals = literals,

            .symbols = &.{},
            .resolved = undefined,
            .extra = extra,
        };
    }

    pub fn declaration(self: *Parser) PaserError!u32 {
        switch (self.current().tag) {
            .keyword_var => {
                self.index += 1;
                return try self.varDeclaration();
            },
            .keyword_fun => {
                self.index += 1;
                return try self.funDeclaration();
            },
            .keyword_class => {
                self.index += 1;
                return try self.classDeclaration();
            },
            else => return try self.statement(),
        }
    }

    fn varDeclaration(self: *Parser) PaserError!u32 {
        // NOTE: Append the var node first (parent).
        var var_node: ast.Node = .init(.@"var", @intCast(self.index), .empty);
        const var_index = try self.appendNode(var_node);

        try self.consume(.identifier, error.ExpectedVariableName);

        const init_index: ?u32 = blk: {
            if (self.current().tag == .equal) {
                self.index += 1;
                break :blk try self.expression();
            }
            break :blk null;
        };
        try self.consume(.semicolon, error.ExpectedSemicolon);

        if (init_index) |index| {
            var_node.data.lhs = index;
            self.nodes.set(@intCast(var_index), var_node);
        }
        return var_index;
    }

    fn funDeclaration(self: *Parser) PaserError!u32 {
        // NOTE: Append the fun node first (parent).
        var fun_node: ast.Node = .init(.fun, @intCast(self.index), .empty);
        const fun_index = try self.appendNode(fun_node);

        try self.consume(.identifier, error.ExpectedFunctionName);
        try self.consume(.left_paren, error.ExpectedLeftParen);

        const params_index = try self.parameters();
        try self.consume(.right_paren, error.ExpectedRightParen);

        const body_index = try self.statement();

        fun_node.data = .init(params_index, body_index);
        self.nodes.set(@intCast(fun_index), fun_node);

        return fun_index;
    }

    fn parameters(self: *Parser) PaserError!u32 {
        var list: ArrayList(u32) = .empty;
        defer list.deinit(self.allocator);

        if (self.current().tag != .right_paren) {
            while (true) {
                if (list.items.len >= @as(usize, max_function_arity)) {
                    try self.report(error.TooManyParameters);
                }
                try list.append(self.allocator, @intCast(self.index));
                try self.consume(.identifier, error.ExpectedParameterName);

                if (self.current().tag != .comma) break;
                self.index += 1;
            }
        }

        const extra_index: u32 = @intCast(self.extra.items.len);
        if (list.items.len > 0) {
            try self.appendExtra(@intCast(list.items.len), list.items);
        } else {
            try self.appendExtra(0, &.{});
        }
        return extra_index;
    }

    fn classDeclaration(self: *Parser) PaserError!u32 {
        var class_node: ast.Node = .init(.class, @intCast(self.index), .empty);

        try self.consume(.identifier, error.ExpectedClassName);
        try self.consume(.left_brace, error.ExpectedLeftBrace);

        // NOTE: Append the class node first (parent).
        const class_index = try self.appendNode(class_node);

        var list: ArrayList(u32) = .empty;
        defer list.deinit(self.allocator);

        while (true) {
            const current_token = self.current();
            if (current_token.tag == .right_brace or current_token.tag == .eof) break;

            const method_index = try self.funDeclaration();
            try list.append(self.allocator, method_index);
        }
        try self.consume(.right_brace, error.ExpectedRightBrace);

        const offset: u32 = @intCast(self.extra.items.len);
        if (list.items.len > 0) {
            try self.extra.appendSlice(self.allocator, list.items);
        }

        class_node.data = .init(offset, @intCast(self.extra.items.len));
        self.nodes.set(@intCast(class_index), class_node);

        return class_index;
    }

    pub fn statement(self: *Parser) PaserError!u32 {
        switch (self.current().tag) {
            .keyword_for => {
                self.index += 1;
                return try self.forStatement();
            },
            .keyword_if => {
                self.index += 1;
                return try self.ifStatement();
            },
            .keyword_print => {
                self.index += 1;
                return try self.printStatement();
            },
            .keyword_return => {
                return try self.returnStatement();
            },
            .keyword_while => {
                self.index += 1;
                return try self.whileStatement();
            },
            .left_brace => {
                self.index += 1;
                return try self.blockStatement();
            },
            else => return try self.exprStatement(),
        }
    }

    fn forStatement(self: *Parser) PaserError!u32 {
        try self.consume(.left_paren, error.ExpectedLeftParen);

        // NOTE: Append the block node first (parent).
        var block_node: ast.Node = .init(.block, 0, .empty);
        const block_index = try self.appendNode(block_node);

        const init_index: ?u32 = blk: {
            switch (self.current().tag) {
                .semicolon => {
                    self.index += 1;
                    break :blk null;
                },
                .keyword_var => {
                    self.index += 1;
                    break :blk try self.varDeclaration();
                },
                else => break :blk try self.exprStatement(),
            }
        };

        // NOTE: Append the while node after the block node.
        var while_node: ast.Node = .init(.@"while", 0, .empty);
        const while_index = try self.appendNode(while_node);

        const cond_index: u32 = blk: {
            if (self.current().tag != .semicolon) {
                break :blk try self.expression();
            }

            const default_index = try self.appendValue(.{ .boolean = true });
            break :blk try self.appendNode(
                .init(.literal, 0, .init(default_index, 0)),
            );
        };
        try self.consume(.semicolon, error.ExpectedSemicolon);

        const inc_index: ?u32 = blk: {
            if (self.current().tag == .right_paren) {
                break :blk null;
            }
            break :blk try self.expression();
        };
        try self.consume(.right_paren, error.ExpectedRightParen);

        var body_index = try self.statement();
        if (inc_index) |index| {
            const offset: u32 = @intCast(self.extra.items.len);
            try self.extra.appendSlice(self.allocator, &.{ body_index, index });

            body_index = try self.appendNode(
                .init(.block, 0, .init(offset, @intCast(self.extra.items.len))),
            );
        }

        while_node.data = .init(cond_index, body_index);
        self.nodes.set(@intCast(while_index), while_node);

        const offset: u32 = @intCast(self.extra.items.len);
        if (init_index) |index| {
            try self.extra.append(self.allocator, index);
        }
        try self.extra.append(self.allocator, while_index);

        block_node.data = .init(offset, @intCast(self.extra.items.len));
        self.nodes.set(@intCast(block_index), block_node);

        return block_index;
    }

    fn ifStatement(self: *Parser) PaserError!u32 {
        try self.consume(.left_paren, error.ExpectedLeftParen);

        // NOTE: Append the if node first (parent).
        var if_node: ast.Node = .init(.@"if", 0, .empty);
        const if_index = try self.appendNode(if_node);

        const cond_index = try self.expression();
        try self.consume(.right_paren, error.ExpectedRightParen);

        const then_index = try self.statement();
        const else_index: ?u32 = blk: {
            if (self.current().tag == .keyword_else) {
                self.index += 1;
                break :blk try self.statement();
            }
            break :blk null;
        };

        const extra_index: u32 = @intCast(self.extra.items.len);
        if (else_index) |index| {
            try self.appendExtra(2, &.{ then_index, index });
        } else {
            try self.appendExtra(1, &.{then_index});
        }

        if_node.data = .init(cond_index, extra_index);
        self.nodes.set(@intCast(if_index), if_node);

        return if_index;
    }

    fn printStatement(self: *Parser) PaserError!u32 {
        // NOTE: Append the print node first (parent).
        var print_node: ast.Node = .init(.print, 0, .empty);
        const print_index = try self.appendNode(print_node);

        const value_index = try self.expression();
        try self.consume(.semicolon, error.ExpectedSemicolon);

        print_node.data.lhs = value_index;
        self.nodes.set(@intCast(print_index), print_node);

        return print_index;
    }

    fn returnStatement(self: *Parser) PaserError!u32 {
        // NOTE: Append the print node first (parent).
        var return_node: ast.Node = .init(.@"return", @intCast(self.index), .empty);
        const return_index = try self.appendNode(return_node);

        self.index += 1;

        const value_index: ?u32 = blk: {
            if (self.current().tag != .semicolon) {
                break :blk try self.expression();
            }
            break :blk null;
        };
        try self.consume(.semicolon, error.ExpectedSemicolon);

        if (value_index) |index| {
            return_node.data.lhs = index;
            self.nodes.set(@intCast(return_index), return_node);
        }
        return return_index;
    }

    fn whileStatement(self: *Parser) PaserError!u32 {
        // NOTE: Append the while node first (parent).
        var while_node: ast.Node = .init(.@"while", 0, .empty);
        const while_index = try self.appendNode(while_node);

        try self.consume(.left_paren, error.ExpectedLeftParen);

        const cond_index = try self.expression();
        try self.consume(.right_paren, error.ExpectedRightParen);

        const body_index = try self.statement();

        while_node.data = .init(cond_index, body_index);
        self.nodes.set(@intCast(while_index), while_node);

        return while_index;
    }

    fn blockStatement(self: *Parser) PaserError!u32 {
        // NOTE: Append the block node first (parent).
        var block_node: ast.Node = .init(.block, 0, .empty);
        const block_index = try self.appendNode(block_node);

        var list: ArrayList(u32) = .empty;
        defer list.deinit(self.allocator);

        while (true) {
            const current_token = self.current();
            if (current_token.tag == .right_brace or current_token.tag == .eof) break;

            const stmt_index = try self.declaration();
            try list.append(self.allocator, stmt_index);
        }
        try self.consume(.right_brace, error.ExpectedRightBrace);

        if (list.items.len > 0) {
            block_node.data = .{
                .lhs = @intCast(self.extra.items.len),
                .rhs = @intCast(self.extra.items.len + list.items.len),
            };
            try self.extra.appendSlice(self.allocator, list.items);
            self.nodes.set(@intCast(block_index), block_node);
        }
        return block_index;
    }

    pub fn exprStatement(self: *Parser) PaserError!u32 {
        // NOTE: Append the expr node first (parent).
        var expr_node: ast.Node = .init(.expr, @intCast(self.index), .empty);
        const expr_index = try self.appendNode(expr_node);

        const value_index = try self.expression();
        try self.consume(.semicolon, error.ExpectedSemicolon);

        expr_node.data.lhs = value_index;
        self.nodes.set(@intCast(expr_index), expr_node);

        return expr_index;
    }

    pub fn expression(self: *Parser) PaserError!u32 {
        return try self.assignment();
    }

    pub fn assignment(self: *Parser) PaserError!u32 {
        const left_index = try self.logicOr();

        if (self.tokens.get(self.index).tag == .equal) {
            self.index += 1;
            const value_index = try self.assignment();

            const left_node = self.nodes.get(@intCast(left_index));
            if (left_node.tag == .variable) {
                return try self.appendNode(
                    .init(.assign, left_node.token, .init(value_index, 0)),
                );
            } else if (left_node.tag == .get) {
                return try self.appendNode(
                    .init(.set, left_node.token, .init(left_node.data.lhs, value_index)),
                );
            }
            try self.report(error.InvalidAssignmentTarget);
        }

        return left_index;
    }

    fn logicOr(self: *Parser) PaserError!u32 {
        var left_index = try self.logicAnd();

        while (self.tokens.get(self.index).tag == .keyword_or) {
            const operator_index: u32 = @intCast(self.index);
            self.index += 1;

            const right_index = try self.logicAnd();
            left_index = try self.appendNode(
                .init(.logical, operator_index, .init(left_index, right_index)),
            );
        }
        return left_index;
    }

    fn logicAnd(self: *Parser) PaserError!u32 {
        var left_index = try self.equality();

        while (self.tokens.get(self.index).tag == .keyword_and) {
            const operator_index: u32 = @intCast(self.index);
            self.index += 1;

            const right_index = try self.equality();
            left_index = try self.appendNode(
                .init(.logical, operator_index, .init(left_index, right_index)),
            );
        }
        return left_index;
    }

    fn equality(self: *Parser) PaserError!u32 {
        var left_index = try self.comparison();

        while (true) {
            switch (self.current().tag) {
                .bang_equal,
                .equal_equal,
                => {
                    const operator_index: u32 = @intCast(self.index);
                    self.index += 1;

                    const right_index = try self.comparison();
                    left_index = try self.appendNode(
                        .init(.binary, operator_index, .init(left_index, right_index)),
                    );
                },
                else => break,
            }
        }
        return left_index;
    }

    fn comparison(self: *Parser) PaserError!u32 {
        var left_index = try self.term();

        while (true) {
            switch (self.current().tag) {
                .greater,
                .greater_equal,
                .less,
                .less_equal,
                => {
                    const operator_index: u32 = @intCast(self.index);
                    self.index += 1;

                    const right_index = try self.term();
                    left_index = try self.appendNode(
                        .init(.binary, operator_index, .init(left_index, right_index)),
                    );
                },
                else => break,
            }
        }
        return left_index;
    }

    fn term(self: *Parser) PaserError!u32 {
        var left_index = try self.factor();

        while (true) {
            switch (self.current().tag) {
                .minus,
                .plus,
                => {
                    const operator_index: u32 = @intCast(self.index);
                    self.index += 1;

                    const right_index = try self.factor();
                    left_index = try self.appendNode(
                        .init(.binary, operator_index, .init(left_index, right_index)),
                    );
                },
                else => break,
            }
        }
        return left_index;
    }

    fn factor(self: *Parser) PaserError!u32 {
        var left_index = try self.unary();

        while (true) {
            switch (self.current().tag) {
                .slash,
                .star,
                => {
                    const operator_index: u32 = @intCast(self.index);
                    self.index += 1;

                    const right_index = try self.unary();
                    left_index = try self.appendNode(
                        .init(.binary, operator_index, .init(left_index, right_index)),
                    );
                },
                else => break,
            }
        }
        return left_index;
    }

    fn unary(self: *Parser) PaserError!u32 {
        switch (self.current().tag) {
            .bang,
            .minus,
            => {
                const operator_index: u32 = @intCast(self.index);
                self.index += 1;

                const right_index = try self.unary();
                return try self.appendNode(
                    .init(.unary, operator_index, .init(right_index, 0)),
                );
            },
            else => return try self.call(),
        }
    }

    fn call(self: *Parser) PaserError!u32 {
        var expr_index = try self.primary();

        while (true) {
            switch (self.current().tag) {
                .left_paren => {
                    self.index += 1;
                    const args_index = try self.arguments();

                    const paren_index: u32 = @intCast(self.index);
                    try self.consume(.right_paren, error.ExpectedRightParen);

                    expr_index = try self.appendNode(
                        .init(.call, paren_index, .init(expr_index, args_index)),
                    );
                },
                .dot => {
                    self.index += 1;

                    const name_index: u32 = @intCast(self.index);
                    try self.consume(.identifier, error.ExpectedPropertyName);

                    expr_index = try self.appendNode(
                        .init(.get, name_index, .init(expr_index, 0)),
                    );
                },
                else => break,
            }
        }
        return expr_index;
    }

    const max_function_arity: u8 = 255;

    fn arguments(self: *Parser) !u32 {
        var list: ArrayList(u32) = .empty;
        defer list.deinit(self.allocator);

        if (self.tokens.get(self.index).tag != .right_paren) {
            while (true) {
                if (list.items.len >= @as(usize, max_function_arity)) {
                    try self.report(error.TooManyArguments);
                }
                try list.append(self.allocator, try self.expression());

                if (self.tokens.get(self.index).tag != .comma) break;
                self.index += 1;
            }
        }

        const args_offset: u32 = @intCast(self.extra.items.len);

        try self.appendExtra(@intCast(list.items.len), list.items);

        return args_offset;
    }

    fn primary(self: *Parser) PaserError!u32 {
        const token_index: u32 = @intCast(self.index);
        const token = self.tokens.get(self.index);

        switch (token.tag) {
            .keyword_this => {
                self.index += 1;
                return try self.appendNode(.init(.this, token_index, .empty));
            },
            .keyword_false => {
                self.index += 1;
                const value_index = try self.appendValue(.{ .boolean = false });
                return try self.appendNode(
                    .init(.literal, token_index, .init(value_index, 0)),
                );
            },
            .keyword_true => {
                self.index += 1;
                const value_index = try self.appendValue(.{ .boolean = true });
                return try self.appendNode(
                    .init(.literal, token_index, .init(value_index, 0)),
                );
            },
            .keyword_nil => {
                self.index += 1;
                const value_index = try self.appendValue(.nil);
                return try self.appendNode(
                    .init(.literal, token_index, .init(value_index, 0)),
                );
            },
            .string => {
                self.index += 1;
                const value_index = try self.appendValue(.{
                    .string = .{ .literal = token_index },
                });
                return try self.appendNode(
                    .init(.literal, token_index, .init(value_index, 0)),
                );
            },
            .number => {
                self.index += 1;
                const value_index = try self.appendValue(.{
                    .number = try fmt.parseFloat(f64, token.lexeme(self.source)),
                });
                return try self.appendNode(
                    .init(.literal, token_index, .init(value_index, 0)),
                );
            },
            .identifier => {
                self.index += 1;
                return try self.appendNode(.init(.variable, token_index, .empty));
            },
            .left_paren => {
                self.index += 1;
                const expr_index = try self.expression();

                try self.consume(.right_paren, error.ExpectedRightParen);
                return try self.appendNode(
                    .init(.group, 0, .init(expr_index, 0)),
                );
            },
            else => return error.ExpectedAnExpression,
        }
    }

    fn appendExtra(self: *Parser, len: u32, list: []const u32) !void {
        try self.extra.append(self.allocator, len);
        try self.extra.appendSlice(self.allocator, list);
    }

    fn appendNode(self: *Parser, node: ast.Node) !u32 {
        const index = self.nodes.len;
        try self.nodes.append(self.allocator, node);
        return @intCast(index);
    }

    fn appendValue(self: *Parser, value: ast.Value) !u32 {
        const index = self.literals.items.len;
        try self.literals.append(self.allocator, value);
        return @intCast(index);
    }

    fn consume(self: *Parser, expected: Token.Tag, err: PaserError) PaserError!void {
        if (self.tokens.get(self.index).tag != expected) {
            return err;
        }
        self.index += 1;
    }

    fn current(self: Parser) Token {
        return self.tokens.get(self.index);
    }

    fn getMessage(err: PaserError) ![]const u8 {
        return switch (err) {
            error.ExpectedLeftParen => "Expected Left Parenthesize",
            error.ExpectedLeftBrace => "Expected Left Brace",
            error.ExpectedRightParen => "Expected Right Parenthisize",
            error.ExpectedRightBrace => "Expected Right Brace",
            error.ExpectedAnExpression => "Expeceted An Expression",
            error.ExpectedSemicolon => "Expected Semicolon",
            error.ExpectedVariableName => "Expected Variable Name",
            error.ExpectedFunctionName => "Expected Function Name",
            error.ExpectedClassName => "Expected Class Name",
            error.ExpectedParameterName => "Expected Parameter Name",
            error.ExpectedPropertyName => "Expected Property Name",
            error.InvalidAssignmentTarget => "Invalid Assignment Target",
            error.TooManyArguments => "Can't Have More Than 255 Arguments.",
            error.TooManyParameters => "Can't Have More Than 255 Parameters.",
            else => err,
        };
    }

    fn report(self: *Parser, err: PaserError) PaserError!void {
        const token = self.current();
        const message = try getMessage(err);
        // TODO: Need to separate it from tokenizer.
        try tokenizer.report(self.ctx, self.source, token.loc.start, message);
    }

    fn sync(self: *Parser) !void {
        while (self.tokens.get(self.index).tag != .eof) {
            switch (self.tokens.get(self.index).tag) {
                .keyword_class,
                .keyword_fun,
                .keyword_for,
                .keyword_if,
                .keyword_while,
                .keyword_print,
                .keyword_return,
                => break,
                .semicolon => {
                    self.index += 1;
                    break;
                },
                else => self.index += 1,
            }
        }
    }
};

test "parser" {
    try testParser(" 10; ", "<number 10>");
    try testParser(" 10.1; ", "<number 10.1>");
    try testParser(" true; ", "<boolean true>");
    try testParser(" false; ", "<boolean false>");
    try testParser(" nil; ", "<nil>");
    try testParser("(true); ", "(group <boolean true>)");

    // Unary
    try testParser(" !true; ", "(! <boolean true>)");
    try testParser(" -10; ", "(- <number 10>)");

    // Factory
    try testParser(" 10 * 20; ", "(* <number 10> <number 20>)");
    try testParser(" 20 / 10; ", "(/ <number 20> <number 10>)");

    // Terminal
    try testParser(" 10 + 20; ", "(+ <number 10> <number 20>)");
    try testParser(" 20 - 10; ", "(- <number 20> <number 10>)");

    // Comparison
    try testParser(" 10 <= 10; ", "(<= <number 10> <number 10>)");
    try testParser(" 10 >= 10; ", "(>= <number 10> <number 10>)");
    try testParser(" 10 < 10; ", "(< <number 10> <number 10>)");
    try testParser(" 10 > 10; ", "(> <number 10> <number 10>)");

    // Equality
    try testParser(" 10 == 10; ", "(== <number 10> <number 10>)");
    try testParser(" 10 != 10; ", "(!= <number 10> <number 10>)");

    // Combination
    try testParser(" true and true; ", "(and <boolean true> <boolean true>)");
    try testParser(" true or true; ", "(or <boolean true> <boolean true>)");

    // Assignment
    try testParser(" a = 10; ", "(assign a <number 10>)");

    // Call
    try testParser("sum(1, 2);", "(call sum ')' (args <number 1> <number 2>))");
    try testParser("hello();", "(call hello ')')");

    // Variable Statement
    try testParser(" var ten = 10; ", "(var ten <number 10>)");
    try testParser(" var ten; ", "(var ten)");

    // Print Statement
    try testParser(" print ten; ", "(print ten)");
    try testParser(" print 10; ", "(print <number 10>)");

    // Block Statement
    try testParser(
        \\ {
        \\   var a = 0;
        \\   a = 1;
        \\   print a;
        \\ }
    ,
        \\(block
        \\  (var a <number 0>)
        \\  (assign a <number 1>)
        \\  (print a)
        \\)
    );

    // If Statement
    try testParser(
        \\ if (true) { print 10; } else { print 0; }
    ,
        \\(if <boolean true> (block
        \\  (print <number 10>)
        \\) (block
        \\  (print <number 0>)
        \\))
    );

    try testParser(
        \\ if (true == true) print 10; else print 0;
    , "(if (== <boolean true> <boolean true>) (print <number 10>) (print <number 0>))");

    try testParser(
        \\ if (true == true) print 10;
    , "(if (== <boolean true> <boolean true>) (print <number 10>))");

    // While Statement
    try testParser(
        \\ while(true) print true;
    , "(while <boolean true> (print <boolean true>))");
    try testParser(
        \\ while(true) {
        \\   var value = 10;
        \\   print value;
        \\ }
    ,
        \\(while <boolean true> (block
        \\  (var value <number 10>)
        \\  (print value)
        \\))
    );

    // For Statement
    try testParser(
        \\ for(var i = 0; i < 2; i = i + 1) print i;
    ,
        \\(block
        \\  (var i <number 0>)
        \\  (while (< i <number 2>) (block
        \\    (print i)
        \\    (assign i (+ i <number 1>))
        \\  ))
        \\)
    );

    // Fun Statement
    try testParser(
        \\ fun greet() { print "hello"; }
    ,
        \\(fun greet (block
        \\  (print <string literal 6>)
        \\))
    );

    // Return Statement
    try testParser(" return 10; ", "(return <number 10>)");

    // Class Statement.
    try testParser(
        \\ class DevonshireCream {
        \\   serveOn() {
        \\     return "Scones";
        \\   }
        \\ }
    ,
        \\(class DevonshireCream
        \\  (fun serveOn (block
        \\    (return <string literal 8>)
        \\  ))
        \\)
    );

    // Get Expression.
    try testParser(
        \\ user.name.first;
    , "(get first (get name user))");

    // Set Expression
    try testParser(
        \\ user.name.first = "John";
    , "(set first (get name user) <string literal 6>)");

    try testParser(
        \\ Bacon().eat();
    , "(call (get eat (call Bacon ')')) ')')");
}

fn testParser(source: [:0]const u8, expected: []const u8) !void {
    const gpa = testing.allocator;

    var stream: Io.Writer.Allocating = .init(gpa);
    defer stream.deinit();

    var ctx: Ctx = .init(undefined, .{ .err = &stream.writer });

    var tree = try parse(gpa, &ctx, source);
    defer tree.deinit(gpa);

    for (tree.roots) |index| {
        try ast_printer.print(&stream.writer, tree, @intCast(index));
    }
    try testing.expectEqualSlices(u8, expected, stream.written());
}

test "parsing continuosly" {
    const gpa = testing.allocator;
    const source = "var number = 10;";

    var lexer: Lexer = .empty;
    defer lexer.deinit(gpa);

    try lexer.scan(gpa, undefined, source, 0);
    var tokens = lexer.slice();

    var parser: Parser = .init(gpa, undefined);
    defer parser.deinit();

    try parser.parse(source, tokens, 0);
    try testing.expectEqual(1, parser.roots.items.len);

    const new_source = source ++ " print number;";
    const token_offset = tokens.len;

    try lexer.scan(gpa, undefined, new_source, source.len);
    tokens = lexer.slice();

    // Continue to parsing from the current parser's index.
    try parser.parse(new_source, tokens, token_offset);
    try testing.expectEqual(2, parser.roots.items.len);
}

const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const testing = std.testing;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;

const ast = @import("ast.zig");
const ast_printer = @import("ast_printer.zig");
const tokenizer = @import("tokenizer.zig");
const Ctx = @import("Context.zig");
const Lexer = tokenizer.Lexer;
const Token = tokenizer.Token;
const TokenList = tokenizer.TokenList;
