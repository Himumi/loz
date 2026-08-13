pub fn parse(gpa: Allocator, ctx: *Context, source: [:0]const u8) AnalyzerError!ast.Ast {
    var analyzer: Analyzer = .empty;
    return try analyzer.parse(gpa, ctx, source);
}

const max_function_arity: u8 = 255;
const AnalyzerError =
    Analyzer.Error ||
    Lexer.Error ||
    Allocator.Error ||
    Io.Writer.Error ||
    fmt.ParseFloatError;

pub const Analyzer = struct {
    lexer: Lexer,
    current: Token,

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

    pub const empty: Analyzer = .{
        .lexer = undefined,
        .current = undefined,
    };

    pub fn parse(
        self: *Analyzer,
        gpa: Allocator,
        ctx: *Context,
        source: [:0]const u8,
    ) AnalyzerError!ast.Ast {
        self.lexer = Lexer.init(source);
        self.current = self.lexer.next() catch |err| {
            try self.report(ctx, err);
            return err;
        };
        var list: ArrayList(*ast.Stmt) = .empty;
        defer {
            for (list.items) |item| item.destroy(gpa);
            list.deinit(gpa);
        }
        while (self.current.tag != .eof) {
            if (self.declaration(gpa, ctx)) |parsed| {
                try list.append(gpa, parsed);
            } else |err| {
                try self.report(ctx, err);
                try self.sync();
            }
        }
        return .init(source, try list.toOwnedSlice(gpa));
    }

    // Declarations //

    fn declaration(self: *Analyzer, gpa: Allocator, ctx: *Context) AnalyzerError!*ast.Stmt {
        switch (self.current.tag) {
            .keyword_var => {
                self.current = try self.lexer.next();
                return try self.varDeclaration(gpa, ctx);
            },
            .keyword_fun => {
                self.current = try self.lexer.next();
                return try self.funDeclaration(gpa, ctx);
            },
            .keyword_class => {
                self.current = try self.lexer.next();
                return try self.classDeclaration(gpa, ctx);
            },
            else => return self.statement(gpa, ctx),
        }
    }

    fn varDeclaration(self: *Analyzer, gpa: Allocator, ctx: *Context) AnalyzerError!*ast.Stmt {
        const name = self.current;
        try self.consume(.identifier, error.ExpectedVariableName);

        const init_value: ?*ast.Expr = blk: {
            if (self.current.tag != .equal) {
                break :blk null;
            }
            self.current = try self.lexer.next();
            break :blk try self.expression(gpa, ctx);
        };
        errdefer if (init_value) |value| value.destroy(gpa);

        try self.consume(.semicolon, error.ExpectedSemicolon);
        return try ast.Var.create(gpa, name, init_value);
    }

    fn funDeclaration(self: *Analyzer, gpa: Allocator, ctx: *Context) AnalyzerError!*ast.Stmt {
        const name = self.current;

        try self.consume(.identifier, error.ExpectedFunctionName);
        try self.consume(.left_paren, error.ExpectedLeftParen);

        const params = try self.parameters(gpa, ctx);
        errdefer gpa.free(params);

        try self.consume(.right_paren, error.ExpectedRightParen);
        try self.consume(.left_brace, error.ExpectedLeftBrace);

        const body = try self.blockList(gpa, ctx);
        errdefer {
            for (body) |stmt| stmt.destroy(gpa);
            gpa.free(body);
        }

        return try ast.Function.create(gpa, .init(name, params, .init(body)));
    }

    fn parameters(self: *Analyzer, gpa: Allocator, ctx: *Context) AnalyzerError![]const Token {
        var list_params: ArrayList(Token) = .empty;
        defer list_params.deinit(gpa);

        if (self.current.tag != .right_paren) {
            while (true) {
                if (list_params.items.len >= @as(usize, max_function_arity)) {
                    try self.report(ctx, error.TooManyParameters);
                }
                try list_params.append(gpa, self.current);
                try self.consume(.identifier, error.ExpectedParameterName);

                if (self.current.tag != .comma) break;
                self.current = try self.lexer.next();
            }
        }
        return try list_params.toOwnedSlice(gpa);
    }

    fn classDeclaration(self: *Analyzer, gpa: Allocator, ctx: *Context) AnalyzerError!*ast.Stmt {
        const name = self.current;
        try self.consume(.identifier, error.ExpectedClassName);
        try self.consume(.left_brace, error.ExpectedLeftBrace);

        var list: ArrayList(*ast.Stmt) = .empty;
        defer {
            for (list.items) |item| item.destroy(gpa);
            list.deinit(gpa);
        }

        while (self.current.tag != .right_brace and self.current.tag != .eof) {
            const method = try self.funDeclaration(gpa, ctx);
            errdefer method.destroy(gpa);
            try list.append(gpa, method);
        }
        try self.consume(.right_brace, error.ExpectedRightBrace);

        const methods = try list.toOwnedSlice(gpa);
        errdefer {
            for (methods) |method| method.destroy(gpa);
            gpa.free(methods);
        }

        return try ast.Class.create(gpa, .init(name, methods));
    }

    // Statemnets //

    fn statement(self: *Analyzer, gpa: Allocator, ctx: *Context) AnalyzerError!*ast.Stmt {
        switch (self.current.tag) {
            .keyword_for => {
                self.current = try self.lexer.next();
                return self.forStatement(gpa, ctx);
            },
            .keyword_if => {
                self.current = try self.lexer.next();
                return try self.ifStatement(gpa, ctx);
            },
            .keyword_print => {
                self.current = try self.lexer.next();
                return try self.printStatement(gpa, ctx);
            },
            .keyword_return => {
                return try self.returnStatement(gpa, ctx);
            },
            .keyword_while => {
                self.current = try self.lexer.next();
                return try self.whileStatement(gpa, ctx);
            },
            .left_brace => {
                self.current = try self.lexer.next();
                return try self.blockStatement(gpa, ctx);
            },
            else => return try self.expressionStatement(gpa, ctx),
        }
    }

    fn forStatement(self: *Analyzer, gpa: Allocator, ctx: *Context) AnalyzerError!*ast.Stmt {
        try self.consume(.left_paren, error.ExpectedLeftParen);

        const initializer: ?*ast.Stmt = blk: {
            switch (self.current.tag) {
                .semicolon => {
                    self.current = try self.lexer.next();
                    break :blk null;
                },
                .keyword_var => {
                    self.current = try self.lexer.next();
                    break :blk try self.varDeclaration(gpa, ctx);
                },
                else => break :blk try self.expressionStatement(gpa, ctx),
            }
        };
        errdefer if (initializer) |init_value| init_value.destroy(gpa);

        const condition = blk: {
            if (self.current.tag != .semicolon) {
                break :blk try self.expression(gpa, ctx);
            }
            break :blk try ast.Literal.create(gpa, .{ .boolean = true });
        };
        errdefer condition.destroy(gpa);

        try self.consume(.semicolon, error.ExpectedSemicolon);

        const increment: ?*ast.Stmt = blk: {
            if (self.current.tag == .right_paren) {
                break :blk null;
            }
            const exp = try self.expression(gpa, ctx);
            errdefer exp.destroy(gpa);

            break :blk try ast.Expression.create(gpa, exp);
        };
        errdefer if (increment) |increment_value| increment_value.destroy(gpa);

        try self.consume(.right_paren, error.ExpectedRightParen);

        var body = try self.statement(gpa, ctx);
        errdefer body.destroy(gpa);

        if (increment) |value| {
            body = try ast.Block.dupeFrom(gpa, &.{ body, value });
        }
        body = try ast.While.create(gpa, condition, body);

        if (initializer) |init_value| {
            body = try ast.Block.dupeFrom(gpa, &.{ init_value, body });
        }
        return body;
    }

    fn ifStatement(self: *Analyzer, gpa: Allocator, ctx: *Context) AnalyzerError!*ast.Stmt {
        try self.consume(.left_paren, error.ExpectedLeftParen);

        const condition = try self.expression(gpa, ctx);
        errdefer condition.destroy(gpa);

        try self.consume(.right_paren, error.ExpectedRightParen);

        const then_stmt = try self.statement(gpa, ctx);
        errdefer then_stmt.destroy(gpa);

        const else_stmt: ?*ast.Stmt = blK: {
            if (self.current.tag != .keyword_else) {
                break :blK null;
            }
            self.current = try self.lexer.next();
            break :blK try self.statement(gpa, ctx);
        };
        errdefer if (else_stmt) |stmt| stmt.destroy(gpa);

        return try ast.IF.create(gpa, condition, then_stmt, else_stmt);
    }

    fn printStatement(self: *Analyzer, gpa: Allocator, ctx: *Context) AnalyzerError!*ast.Stmt {
        const value = try self.expression(gpa, ctx);
        errdefer value.destroy(gpa);

        try self.consume(.semicolon, error.ExpectedSemicolon);
        return try ast.Print.create(gpa, value);
    }

    fn returnStatement(self: *Analyzer, gpa: Allocator, ctx: *Context) AnalyzerError!*ast.Stmt {
        const keyword = self.current;
        self.current = try self.lexer.next();

        const value =
            if (self.current.tag != .semicolon) try self.expression(gpa, ctx) else null;
        errdefer if (value) |exp| exp.destroy(gpa);

        try self.consume(.semicolon, error.ExpectedSemicolon);
        return try ast.Return.create(gpa, keyword, value);
    }

    fn whileStatement(self: *Analyzer, gpa: Allocator, ctx: *Context) AnalyzerError!*ast.Stmt {
        try self.consume(.left_paren, error.ExpectedLeftParen);

        const condition = try self.expression(gpa, ctx);
        errdefer condition.destroy(gpa);

        try self.consume(.right_paren, error.ExpectedRightParen);

        const body = try self.statement(gpa, ctx);
        errdefer body.destroy(gpa);

        return ast.While.create(gpa, condition, body);
    }

    fn blockStatement(self: *Analyzer, gpa: Allocator, ctx: *Context) AnalyzerError!*ast.Stmt {
        const block_list = try self.blockList(gpa, ctx);
        errdefer {
            for (block_list) |stmt| stmt.destroy(gpa);
            gpa.free(block_list);
        }
        return try ast.Block.create(gpa, .init(block_list));
    }

    fn blockList(self: *Analyzer, gpa: Allocator, ctx: *Context) AnalyzerError![]const *ast.Stmt {
        var list: ArrayList(*ast.Stmt) = .empty;
        defer { // If it succeeds it has no items anymore.
            for (list.items) |item| item.destroy(gpa);
            list.deinit(gpa);
        }
        while (self.current.tag != .right_brace and self.current.tag != .eof) {
            const current_statement = try self.declaration(gpa, ctx);
            errdefer current_statement.destroy(gpa);

            try list.append(gpa, current_statement);
        }
        try self.consume(.right_brace, error.ExpectedRightBrace);

        return try list.toOwnedSlice(gpa);
    }

    fn expressionStatement(self: *Analyzer, gpa: Allocator, ctx: *Context) AnalyzerError!*ast.Stmt {
        const value = try self.expression(gpa, ctx);
        errdefer value.destroy(gpa);

        try self.consume(.semicolon, error.ExpectedSemicolon);
        return try ast.Expression.create(gpa, value);
    }

    // Expressions //

    fn expression(self: *Analyzer, gpa: Allocator, ctx: *Context) AnalyzerError!*ast.Expr {
        return try self.assignment(gpa, ctx);
    }

    fn assignment(self: *Analyzer, gpa: Allocator, ctx: *Context) AnalyzerError!*ast.Expr {
        const left = try self.logicOr(gpa, ctx);
        errdefer left.destroy(gpa);

        if (self.current.tag == .equal) {
            self.current = try self.lexer.next();

            const value = try self.assignment(gpa, ctx);
            errdefer value.destroy(gpa);

            if (left.* == .variable) {
                defer left.destroy(gpa);
                return try ast.Assign.create(gpa, left.variable.name, value);
            } else if (left.* == .get) {
                defer gpa.destroy(left);
                return try ast.Set.create(gpa, left.get.object, left.get.name, value);
            }
            try self.report(ctx, error.InvalidAssignmentTarget);
        }
        return left;
    }

    fn logicOr(self: *Analyzer, gpa: Allocator, ctx: *Context) AnalyzerError!*ast.Expr {
        var left = try self.logicAnd(gpa, ctx);
        errdefer left.destroy(gpa);

        while (self.current.tag == .keyword_or) {
            const operator = self.current;
            self.current = try self.lexer.next();

            const right = try self.logicAnd(gpa, ctx);
            errdefer right.destroy(gpa);

            left = try ast.Logical.create(gpa, left, operator, right);
        }
        return left;
    }

    fn logicAnd(self: *Analyzer, gpa: Allocator, ctx: *Context) AnalyzerError!*ast.Expr {
        var left = try self.equality(gpa, ctx);
        errdefer left.destroy(gpa);

        while (self.current.tag == .keyword_and) {
            const operator = self.current;
            self.current = try self.lexer.next();

            const right = try self.equality(gpa, ctx);
            errdefer right.destroy(gpa);

            left = try ast.Logical.create(gpa, left, operator, right);
        }
        return left;
    }

    fn equality(self: *Analyzer, gpa: Allocator, ctx: *Context) AnalyzerError!*ast.Expr {
        var left = try self.comparison(gpa, ctx);
        errdefer left.destroy(gpa);

        while (true) {
            switch (self.current.tag) {
                .bang_equal,
                .equal_equal,
                => {
                    const operator = self.current;
                    self.current = try self.lexer.next();

                    const right = try self.comparison(gpa, ctx);
                    errdefer right.destroy(gpa);

                    left = try ast.Binary.create(gpa, left, operator, right);
                },
                else => break,
            }
        }
        return left;
    }

    fn comparison(self: *Analyzer, gpa: Allocator, ctx: *Context) AnalyzerError!*ast.Expr {
        var left = try self.term(gpa, ctx);
        errdefer left.destroy(gpa);

        while (true) {
            switch (self.current.tag) {
                .greater,
                .greater_equal,
                .less,
                .less_equal,
                => {
                    const operator = self.current;
                    self.current = try self.lexer.next();

                    const right = try self.term(gpa, ctx);
                    errdefer right.destroy(gpa);

                    left = try ast.Binary.create(gpa, left, operator, right);
                },
                else => break,
            }
        }
        return left;
    }

    fn term(self: *Analyzer, gpa: Allocator, ctx: *Context) AnalyzerError!*ast.Expr {
        var left = try self.factor(gpa, ctx);
        errdefer left.destroy(gpa);

        while (true) {
            switch (self.current.tag) {
                .minus,
                .plus,
                => {
                    const operator = self.current;
                    self.current = try self.lexer.next();

                    const right = try self.factor(gpa, ctx);
                    errdefer right.destroy(gpa);

                    left = try ast.Binary.create(gpa, left, operator, right);
                },
                else => break,
            }
        }
        return left;
    }

    fn factor(self: *Analyzer, gpa: Allocator, ctx: *Context) AnalyzerError!*ast.Expr {
        var left = try self.unary(gpa, ctx);
        errdefer left.destroy(gpa);

        while (true) {
            switch (self.current.tag) {
                .slash,
                .star,
                => {
                    const operator = self.current;
                    self.current = try self.lexer.next();

                    const right = try self.unary(gpa, ctx);
                    errdefer right.destroy(gpa);

                    left = try ast.Binary.create(gpa, left, operator, right);
                },
                else => break,
            }
        }
        return left;
    }

    fn unary(self: *Analyzer, gpa: Allocator, ctx: *Context) AnalyzerError!*ast.Expr {
        switch (self.current.tag) {
            .bang,
            .minus,
            => {
                const operator = self.current;
                self.current = try self.lexer.next();

                const right = try self.unary(gpa, ctx);
                errdefer right.destroy(gpa);

                return try ast.Unary.create(gpa, operator, right);
            },
            else => return try self.call(gpa, ctx),
        }
    }

    fn call(self: *Analyzer, gpa: Allocator, ctx: *Context) AnalyzerError!*ast.Expr {
        var exp = try self.primary(gpa, ctx);
        errdefer exp.destroy(gpa);

        while (true) {
            switch (self.current.tag) {
                .left_paren => {
                    self.current = try self.lexer.next();

                    const args = try self.arguments(gpa, ctx);
                    errdefer {
                        for (args) |arg| arg.destroy(gpa);
                        gpa.free(args);
                    }

                    const paren = self.current;
                    try self.consume(.right_paren, error.ExpectedRightParen);

                    exp = try ast.Call.create(gpa, .init(exp, paren, args));
                },
                .dot => {
                    self.current = try self.lexer.next();

                    const name = self.current;
                    try self.consume(.identifier, error.ExpectedPropertyName);

                    exp = try ast.Get.create(gpa, name, exp);
                },
                else => break,
            }
        }

        return exp;
    }

    fn arguments(self: *Analyzer, gpa: Allocator, ctx: *Context) AnalyzerError![]const *ast.Expr {
        var list: ArrayList(*ast.Expr) = .empty;
        defer {
            for (list.items) |item| item.destroy(gpa);
            list.deinit(gpa);
        }
        if (self.current.tag != .right_paren) {
            while (true) {
                if (list.items.len >= @as(usize, max_function_arity)) {
                    try self.report(ctx, error.TooManyArguments);
                }
                const arg = try self.expression(gpa, ctx);
                errdefer arg.destroy(gpa);

                try list.append(gpa, arg);

                if (self.current.tag != .comma) break;
                self.current = try self.lexer.next();
            }
        }
        return try list.toOwnedSlice(gpa);
    }

    fn primary(self: *Analyzer, gpa: Allocator, ctx: *Context) AnalyzerError!*ast.Expr {
        const token = self.current;
        switch (token.tag) {
            .keyword_false => {
                self.current = try self.lexer.next();
                return try ast.Literal.create(gpa, .{ .boolean = false });
            },
            .keyword_true => {
                self.current = try self.lexer.next();
                return try ast.Literal.create(gpa, .{ .boolean = true });
            },
            .keyword_nil => {
                self.current = try self.lexer.next();
                return try ast.Literal.create(gpa, .nil);
            },
            .keyword_this => {
                self.current = try self.lexer.next();
                return try ast.This.create(gpa, token);
            },
            .string => {
                self.current = try self.lexer.next();
                return try ast.Literal.create(gpa, .{ .string = token.lexeme });
            },
            .number => {
                self.current = try self.lexer.next();
                return try ast.Literal.create(gpa, .{
                    .number = try fmt.parseFloat(f64, token.lexeme),
                });
            },
            .identifier => {
                self.current = try self.lexer.next();
                return try ast.Variable.create(gpa, token);
            },
            .left_paren => {
                self.current = try self.lexer.next();

                const exp = try self.expression(gpa, ctx);
                errdefer exp.destroy(gpa);

                try self.consume(.right_paren, error.ExpectedRightParen);
                return try ast.Grouping.create(gpa, exp);
            },
            else => return error.ExpectedAnExpression,
        }
    }

    fn consume(self: *Analyzer, expected: Token.Tag, return_err: AnalyzerError) AnalyzerError!void {
        if (self.current.tag != expected) {
            return return_err;
        }
        self.current = try self.lexer.next();
    }

    fn getMessage(_: Analyzer, err: AnalyzerError) ![]const u8 {
        return switch (err) {
            error.ExpectedRightParen => "Expected A Right Parenthesize.",
            error.ExpectedAnExpression => "Expected An Expression.",
            error.ExpectedSemicolon => "Expected Semicolon After Expression.",
            error.ExpectedVariableName => "Expected A Variable Name.",
            error.UnterminatedString => "Unterminated String.",
            error.UnterminatedBlockComment => "Unterminated Block Comment.",
            error.UnexpectedCharacter => "Unexpected Character.",
            error.InvalidCharacter => "Invalid Character.",
            error.TooManyArguments => "Can't Have More Than 255 Arguments.",
            else => err,
        };
    }

    fn report(self: *Analyzer, ctx: *Context, err: AnalyzerError) AnalyzerError!void {
        const message = try self.getMessage(err);
        const line = self.current.line;
        try ctx.report("[{}] Error: {s}\n", .{ line, message });
    }

    // maybe it will brake the program.
    fn sync(self: *Analyzer) !void {
        while (self.current.tag != .eof) {
            switch (self.current.tag) {
                .keyword_class,
                .keyword_fun,
                .keyword_for,
                .keyword_if,
                .keyword_while,
                .keyword_print,
                .keyword_return,
                => break,
                .semicolon => {
                    self.current = try self.lexer.next();
                    break;
                },
                else => self.current = try self.lexer.next(),
            }
        }
    }
};

test "succeeds analyzer" {
    // Primary
    try testAnalyzer("10;", "10");
    try testAnalyzer("10.1;", "10.1");
    try testAnalyzer("true;", "true");
    try testAnalyzer("false;", "false");
    try testAnalyzer("nil;", "nil");
    try testAnalyzer("(true);", "(group true)");

    // Unary
    try testAnalyzer("!true;", "(! true)");
    try testAnalyzer("-10;", "(- 10)");

    // Factory
    try testAnalyzer("10 * 20;", "(* 10 20)");
    try testAnalyzer("20 / 10;", "(/ 20 10)");

    // Terminal
    try testAnalyzer("10 + 20;", "(+ 10 20)");
    try testAnalyzer("20 - 10;", "(- 20 10)");

    // Comparison
    try testAnalyzer("10 <= 10;", "(<= 10 10)");
    try testAnalyzer("10 >= 10;", "(>= 10 10)");
    try testAnalyzer("10 < 10;", "(< 10 10)");
    try testAnalyzer("10 > 10;", "(> 10 10)");

    // Equality
    try testAnalyzer("10 == 10;", "(== 10 10)");
    try testAnalyzer("10 != 10;", "(!= 10 10)");

    // Logical
    try testAnalyzer("true and true;", "(and true true)");
    try testAnalyzer("true or true;", "(or true true)");

    // Combination
    try testAnalyzer(
        "(!true == (10 + 1 * 0 <= -1));",
        "(group (== (! true) (group (<= (+ 10 (* 1 0)) (- 1)))))",
    );

    // Assignment
    try testAnalyzer(
        \\ a = 10;
    , "(assign a 10)");

    // Call
    try testAnalyzer("sum(1, 2);", "(call sum ')' (args 1 2))");
    try testAnalyzer("hello();", "(call hello ')')");

    // Variable Statement
    try testAnalyzer("var ten = 10;", "(var ten 10)");
    try testAnalyzer("var ten;", "(var ten)");

    // Print Statement
    try testAnalyzer("print ten;", "(print ten)");
    try testAnalyzer(
        \\ print "hello";
    , "(print hello)");

    // Block Statement
    try testAnalyzer(
        \\ {
        \\   var a = 0;
        \\   a = 1;
        \\   print a;
        \\ }
    , "(block (var a 0) (assign a 1) (print a))");

    // If Statement
    try testAnalyzer(
        \\ if (true) { print 10; } else { print 0; }
    , "(if true (block (print 10)) (block (print 0)))");
    try testAnalyzer(
        \\ if (true == true) { print 10; } else { print 0; }
    , "(if (== true true) (block (print 10)) (block (print 0)))");

    // While Statement
    try testAnalyzer(
        \\ while(true) print true;
    , "(while true (print true))");
    try testAnalyzer(
        \\ while(true) {
        \\   var value = 10;
        \\   print value;
        \\ }
    , "(while true (block (var value 10) (print value)))");

    // For Statement
    try testAnalyzer(
        \\ for(var i = 0; i < 2; i = i + 1) print i;
    , "(block (var i 0) (while (< i 2) (block (print i) (assign i (+ i 1)))))");

    try testAnalyzer(
        \\ fun greet() { print "hello"; }
    , "(fun greet (print hello))");

    // Return Statement
    try testAnalyzer(
        \\ return "hello";
    , "(return hello)");

    // Class Statement.
    try testAnalyzer(
        \\ class DevonshireCream {
        \\   serveOn() {
        \\     return "Scones";
        \\   }
        \\ }
    , "(class DevonshireCream (fun serveOn (return Scones)))");

    // Get Expression.
    try testAnalyzer(
        \\ user.name.first;
    , "(get first (get name user))");

    // Set Expression
    try testAnalyzer(
        \\ user.name.first = "John";
    , "(set first (get name user) John)");

    try testAnalyzer(
        \\ Bacon().eat();
    , "(call (get eat (call Bacon ')')) ')')");
}

fn testAnalyzer(source: [:0]const u8, expected: []const u8) !void {
    const gpa = testing.allocator;
    const io = testing.io;

    var stream_buffer: [256]u8 = undefined;
    var stream: Io.Writer = .fixed(&stream_buffer);

    var ctx: Context = .init(io, .{
        .out = &stream,
        .err = &stream,
    });

    const ast_tree = try parse(gpa, &ctx, source);
    defer ast_tree.deinit(gpa);

    for (ast_tree.list) |parsed| {
        try ast_printer.printStmt(&stream, parsed);
    }
    try testing.expectEqualSlices(u8, expected, stream.buffered());
}

test "fails analyzer" {
    const gpa = testing.allocator;
    try testFailParser(gpa,
        \\ (10 - 10;
    , "[1] Error: Expected A Right Parenthesize.\n");
}

fn testFailParser(
    gpa: Allocator,
    source: [:0]const u8,
    expected_message: []const u8,
) !void {
    var buffer: [256]u8 = undefined;
    var io_err: Io.Writer = .fixed(&buffer);

    var ctx: Context = .init(undefined, .{ .err = &io_err });

    _ = try parse(gpa, &ctx, source);
    try testing.expectEqualSlices(u8, expected_message, io_err.buffered());
}

const std = @import("std");
const fmt = std.fmt;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const StaticStringMap = std.StaticStringMap;

const ast = @import("ast.zig");
const ast_printer = @import("ast_printer.zig");
const Context = @import("Context.zig");
const tokenizer = @import("tokenizer.zig");
const Lexer = tokenizer.Lexer;
const Token = tokenizer.Token;
