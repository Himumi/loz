// I need to create union Result type for a better error message.
pub fn render(
    gpa: Allocator,
    ctx: *Ctx,
    tree: ast.Ast,
    resolved: Resolver.Result,
) RendererError!void {
    var renderer: Renderer = try .init(gpa, ctx, resolved);
    defer renderer.deinit();

    return try renderer.render(tree.list);
}

pub fn print(
    gpa: Allocator,
    ctx: *Ctx,
    tree: ast.Ast,
    resolved: Resolver.Result,
) RendererError!void {
    var renderer: Renderer = try .init(gpa, ctx, resolved);
    defer renderer.deinit();

    return try renderer.print(tree.list);
}

pub const RendererError = Renderer.Error || Env.Error || Io.Writer.Error || Allocator.Error;

const Renderer = struct {
    allocator: Allocator,
    ctx: *Ctx,
    // The global Env.
    globals: *Env,
    // The current Env.
    env: *Env,
    // Collection of local envs.
    closures: ArrayList(*Env) = .empty,
    // The Return statement indicator..
    had_return: ?ast.Object = null,
    // Interpreter does not own the ownership.
    resolved: Resolver.Result,
    // The collection of classes methods.
    // The objects' ownerships belong to the Interpreter.
    //
    // Store the Callable methods instead in Callable Object
    // to prevent releasing the hash at runtime.
    classes_methods: ArrayList(Table),
    // The collection of instances fields/members.
    // The objects' ownerships belong to the Interpreter.
    //
    // Store the instances fields instead in Instance Object
    // to prevent releasing the hash at runtime.
    instances_fields: ArrayList(Table),

    pub const Error = error{
        InvalidBinaryOperands,
        InvalidUnaryOperand,
        InvalidFunctionArity,
        ExpectedCallable,
        ExpectedFunction,
        ExpectedMethodFunction,
        OnlyInstanceHasProperty,
        UndefinedProperty,
    };
    const Table = StringHashMap(ast.Object);

    pub fn init(gpa: Allocator, ctx: *Ctx, resolved: Resolver.Result) Allocator.Error!Renderer {
        const env = try Env.create(gpa, null);
        errdefer env.deinit();

        return .{
            .allocator = gpa,
            .ctx = ctx,

            .had_return = null,
            .resolved = resolved,

            .globals = env,
            .env = env,
            .closures = .empty,

            .classes_methods = .empty,
            .instances_fields = .empty,
        };
    }

    pub fn deinit(self: *Renderer) void {
        for (self.closures.items) |closure| {
            closure.destroy(self.allocator);
        }
        self.closures.deinit(self.allocator);

        for (self.instances_fields.items) |*fields| {
            var it = fields.valueIterator();
            while (it.next()) |value_ptr| {
                value_ptr.deinit(self.allocator);
            }
            fields.deinit();
        }
        self.instances_fields.deinit(self.allocator);

        for (self.classes_methods.items) |*methods| {
            var it = methods.valueIterator();
            while (it.next()) |value_ptr| {
                value_ptr.deinit(self.allocator);
            }
            methods.deinit();
        }
        self.classes_methods.deinit(self.allocator);

        if (self.had_return) |had_return| {
            had_return.deinit(self.allocator);
        }
        self.env.destroy(self.allocator);
    }

    pub fn render(self: *Renderer, list: []const *ast.Stmt) RendererError!void {
        for (list) |statement| {
            const object = try self.execute(statement);
            defer object.deinit(self.allocator);
        }
    }

    pub fn print(self: *Renderer, list: []const *ast.Stmt) RendererError!void {
        for (list) |statement| {
            const object = try self.execute(statement);
            defer object.deinit(self.allocator);

            if (object != .nil) {
                try object.toPrintln(self.ctx.stream.out);
            }
        }
    }

    // Statements //

    pub fn execute(self: *Renderer, stmt: *ast.Stmt) RendererError!ast.Object {
        return switch (stmt.*) {
            .expr_statement => |expr_stmt| try self.evaluate(expr_stmt.expression),
            .fun_statement => |fun_stmt| try self.funStatement(stmt, fun_stmt),
            .if_statement => |if_stmt| try self.ifStatement(if_stmt),
            .print_statement => |print_stmt| try self.printStatement(print_stmt),
            .return_statement => |return_stmt| try self.returnStatement(return_stmt),
            .var_statement => |var_stmt| try self.varStatement(var_stmt),
            .while_statement => |while_stmt| try self.whileStatement(while_stmt),
            .block_statement => |block_stmt| try self.blockStatement(block_stmt),
            .class_statement => |class_stmt| try self.classStatement(stmt, class_stmt),
        };
    }

    fn evaluateOptional(self: *Renderer, optional_expr: ?*ast.Expr) !ast.Object {
        if (optional_expr) |expr| {
            return try self.evaluate(expr);
        }
        return .nil;
    }

    fn funStatement(self: *Renderer, stmt: *ast.Stmt, fun_stmt: ast.Function) !ast.Object {
        // Transfer the value's ownership to interpreter env.
        try self.env.define(self.allocator, fun_stmt.name.lexeme, .{
            .callable = .{
                // It borrowed statement and current env.
                .fun = .init(stmt, fun_stmt.params.len, self.env, false),
            },
        });
        return .nil;
    }

    fn classStatement(self: *Renderer, stmt: *ast.Stmt, class_stmt: ast.Class) !ast.Object {
        try self.env.define(self.allocator, class_stmt.name.lexeme, .nil);

        var methods: Table = .init(self.allocator);
        defer methods.deinit();

        // Look for the initializer arity.
        var arity: usize = 0;

        // Map the class's methods.
        for (class_stmt.methods) |method| {
            if (method.* != .fun_statement) {
                return self.panic(class_stmt.name, error.ExpectedMethodFunction);
            }
            const fun_stmt = method.fun_statement;

            const is_init = mem.eql(u8, fun_stmt.name.lexeme, "init");
            if (is_init) {
                arity = fun_stmt.params.len;
            }

            // Transfer the Function Callable's ownership to methods hash.
            try methods.put(method.fun_statement.name.lexeme, .{
                .callable = .{
                    // It borrowed statement and current env.
                    .fun = .init(method, fun_stmt.params.len, self.env, is_init),
                },
            });
        }

        // Transfer the methods' ownership to interpreter's methods.
        const method_index = try self.appendMethod(methods.move());

        // Transfer the Class Callable's ownership to environment.
        try self.env.assign(self.allocator, class_stmt.name.lexeme, .{
            .callable = .{
                // It borrowed statement.
                .class = .init(stmt, arity, method_index),
            },
        });
        return .nil;
    }

    fn ifStatement(self: *Renderer, if_stmt: ast.IF) !ast.Object {
        const condition = try self.evaluate(if_stmt.condition);
        defer condition.deinit(self.allocator);

        if (isTruthy(condition)) {
            return try self.execute(if_stmt.then_stmt);
        }

        if (if_stmt.else_stmt) |else_stmt| {
            return try self.execute(else_stmt);
        }
        return .nil;
    }

    fn printStatement(self: *Renderer, print_stmt: ast.Print) !ast.Object {
        const object = try self.evaluate(print_stmt.expression);
        defer object.deinit(self.allocator);

        try object.toPrintln(self.ctx.stream.out);
        return .nil;
    }

    fn returnStatement(self: *Renderer, return_stmt: ast.Return) !ast.Object {
        const object = try self.evaluateOptional(return_stmt.value);

        if (self.had_return) |return_value| {
            return_value.deinit(self.allocator);
        }
        // Transfer the object's ownership to interpreter's had_return.
        self.had_return = object;

        return .nil;
    }

    fn varStatement(self: *Renderer, var_stmt: ast.Var) !ast.Object {
        const object = try self.evaluateOptional(var_stmt.initializer);
        errdefer object.deinit(self.allocator);

        // Transfer the object's ownership to interpreter env.
        try self.env.define(self.allocator, var_stmt.name.lexeme, object);
        return try object.dupe(self.allocator);
    }

    fn whileStatement(self: *Renderer, while_stmt: ast.While) !ast.Object {
        while (true) {
            const condition = try self.evaluate(while_stmt.condition);
            defer condition.deinit(self.allocator);

            if (!isTruthy(condition)) break;

            const object = try self.execute(while_stmt.body);
            defer object.deinit(self.allocator);
        }
        return .nil;
    }

    fn blockStatement(self: *Renderer, block_stmt: ast.Block) !ast.Object {
        for (block_stmt.list) |value_statement| {
            const object = try self.execute(value_statement);
            defer object.deinit(self.allocator);

            if (self.had_return) |result| {
                self.had_return = null;
                return result;
            }
        }
        return .nil;
    }

    // Expressions //

    fn evaluate(self: *Renderer, exp: *ast.Expr) RendererError!ast.Object {
        return switch (exp.*) {
            .binary => |binary| try self.binaryExpression(binary),
            .call => |call| try self.callExpression(call),
            .get => |get| try self.getExpression(get),
            .grouping => |group| try self.evaluate(group.expression),
            .unary => |unary| try self.unaryExpression(unary),
            .literal => |literal| try literal.value.dupe(self.allocator),
            .logical => |logical| try self.logicalExpression(logical),
            .set => |set| try self.setExpression(set),
            .variable => |variable| try self.variableExpression(exp, variable),
            .assign => |assign| try self.assignExpression(exp, assign),
            .this => |this| try self.thisExpression(exp, this),
        };
    }

    fn binaryExpression(self: *Renderer, binary: ast.Binary) !ast.Object {
        const left = try self.evaluate(binary.left);
        defer left.deinit(self.allocator);

        const right = try self.evaluate(binary.right);
        defer right.deinit(self.allocator);

        if (binary.operator.tag == .plus) {
            if (left.isNumber() and right.isNumber()) {
                return .{ .number = left.number + right.number };
            }
            if (left.isString() and right.isString()) {
                return .{
                    .string = try mem.concat(self.allocator, u8, &.{
                        left.string,
                        right.string,
                    }),
                };
            }
            if (left.isString() and right.isNumber()) {
                return .{
                    .string = try fmt.allocPrint(self.allocator, "{s}{}", .{
                        left.string,
                        right.number,
                    }),
                };
            }
        }
        if (left.isNumber() and right.isNumber()) {
            switch (binary.operator.tag) {
                .greater => {
                    return .{ .boolean = left.number > right.number };
                },
                .greater_equal => {
                    return .{ .boolean = left.number >= right.number };
                },
                .less => {
                    return .{ .boolean = left.number < right.number };
                },
                .less_equal => {
                    return .{ .boolean = left.number <= right.number };
                },
                .minus => {
                    return .{ .number = left.number - right.number };
                },
                .slash => {
                    return .{ .number = left.number / right.number };
                },
                .star => {
                    return .{ .number = left.number * right.number };
                },
                else => {},
            }
        }
        if (left.isSameTypeWith(right)) {
            switch (binary.operator.tag) {
                .equal_equal => {
                    return .{ .boolean = isEqual(left, right) };
                },
                .bang_equal => {
                    return .{ .boolean = !isEqual(left, right) };
                },
                else => {},
            }
        }
        return self.panic(binary.operator, error.InvalidBinaryOperands);
    }

    fn callExpression(self: *Renderer, call: ast.Call) !ast.Object {
        var callee = try self.evaluate(call.callee);
        defer callee.deinit(self.allocator);

        if (callee != .callable) {
            return self.panic(call.paren, error.ExpectedCallable);
        }
        const callable = callee.callable;

        var list: ArrayList(ast.Object) = try .initCapacity(self.allocator, call.args.len);
        defer {
            for (list.items) |item| item.deinit(self.allocator);
            list.deinit(self.allocator);
        }

        for (call.args) |arg| {
            const object = try self.evaluate(arg);
            errdefer object.deinit(self.allocator);
            try list.append(self.allocator, object);
        }

        if (list.items.len != callable.arity()) {
            return self.panic(call.paren, error.InvalidFunctionArity);
        }

        // The args owns the container memory.
        const args = try list.toOwnedSlice(self.allocator);
        defer self.allocator.free(args);

        // The evaluated objects belongs to the next process.
        errdefer for (args) |arg| arg.deinit(self.allocator);

        // Transfer only the objects' ownership, the container belongs to the caller.
        return switch (callable) {
            .fun => |fun| self.callFn(fun, args),
            .class => |class| self.callClass(class, args),
        } catch |err| {
            return self.panic(call.paren, err);
        };
    }

    fn callFn(self: *Renderer, fun: ast.FunCall, args: []const ast.Object) !ast.Object {
        if (fun.stmt.* != .fun_statement) {
            return error.ExpectedFunction;
        }
        const fun_stmt = fun.stmt.fun_statement;

        const global_env = self.env;
        defer self.env = global_env;

        // Append the function's closure.
        var fun_env = fun.closure;
        fun_env.enclosing = global_env;
        defer fun_env.enclosing = null;

        const local_env = try Env.create(self.allocator, fun_env);
        self.env = local_env;

        // Transfer argument's ownership to local_env..
        for (fun_stmt.params, 0..) |param, i| {
            try self.env.define(self.allocator, param.lexeme, args[i]);
        }
        var block: ast.Stmt = .{ .block_statement = fun_stmt.body };

        const object = try self.execute(&block);
        errdefer object.deinit(self.allocator);

        // Validate the return object.
        if (object == .callable) {
            // Transfer the local env's ownership to interpreter's closures.
            try self.closures.append(self.allocator, local_env);
        } else {
            // It does not need the local env anymore.
            local_env.destroy(self.allocator);
        }

        if (fun.is_init) {
            // When it returns "this" inside the "init" method.
            defer object.deinit(self.allocator);

            const value = try fun.closure.getAt(0, "this");
            return try value.dupe(self.allocator);
        }

        return object;
    }

    fn callClass(self: *Renderer, class: ast.ClassCall, args: []const ast.Object) !ast.Object {
        const fields_index = try self.appendInstance(.init(self.allocator));
        const instance: ast.Object = .{
            .instance = .init(class.stmt, fields_index, class.methods),
        };

        const methods = &self.classes_methods.items[class.methods];
        if (methods.get("init")) |initializer| {
            const binded = try self.bind(initializer, instance);
            defer binded.deinit(self.allocator);
            // Call the binded init method to initialize the class.
            return try self.callFn(binded.callable.fun, args);
        }
        return instance;
    }

    fn getExpression(self: *Renderer, get: ast.Get) !ast.Object {
        const value = try self.evaluate(get.object);
        defer value.deinit(self.allocator);

        if (value != .instance) {
            return self.panic(get.name, error.OnlyInstanceHasProperty);
        }
        const instance = value.instance;

        if (self.instances_fields.items.len > 0) {
            const fields = &self.instances_fields.items[instance.fields];
            if (fields.get(get.name.lexeme)) |object| {
                return object.dupe(self.allocator);
            }
        }

        if (self.classes_methods.items.len > 0) {
            const methods = &self.classes_methods.items[instance.methods];
            if (methods.get(get.name.lexeme)) |method| {
                // Bind the current the instance to fun callable.
                return self.bind(method, value) catch |err| {
                    return self.panic(get.name, err);
                };
            }
        }
        return self.panic(get.name, error.UndefinedProperty);
    }

    fn unaryExpression(self: *Renderer, unary: ast.Unary) !ast.Object {
        const right = try self.evaluate(unary.right);
        defer right.deinit(self.allocator);

        return switch (unary.operator.tag) {
            .bang => .{ .boolean = !isTruthy(right) },
            .minus => {
                if (right.isNumber()) {
                    return .{ .number = -right.number };
                }
                return self.panic(unary.operator, error.InvalidUnaryOperand);
            },
            else => .nil,
        };
    }

    fn logicalExpression(self: *Renderer, logical: ast.Logical) !ast.Object {
        const left = try self.evaluate(logical.left);
        errdefer left.deinit(self.allocator);

        if (logical.operator.tag == .keyword_or) {
            if (isTruthy(left)) return left;
        } else {
            if (!isTruthy(left)) return left;
        }
        left.deinit(self.allocator);
        return try self.evaluate(logical.right);
    }

    fn setExpression(self: *Renderer, set: ast.Set) !ast.Object {
        const object = try self.evaluate(set.object);
        defer object.deinit(self.allocator);

        if (object != .instance) {
            return self.panic(set.name, error.OnlyInstanceHasProperty);
        }
        const instance = object.instance;

        const value = try self.evaluate(set.value);
        errdefer value.deinit(self.allocator);

        const gput = try self
            .instances_fields
            .items[instance.fields]
            .getOrPut(set.name.lexeme);

        // Transfer the value's ownership to the instance.
        if (gput.found_existing) {
            gput.value_ptr.deinit(self.allocator);
        } else {
            gput.key_ptr.* = set.name.lexeme;
        }
        gput.value_ptr.* = value;

        return try value.dupe(self.allocator);
    }

    fn variableExpression(self: *Renderer, expr: *ast.Expr, variable: ast.Variable) !ast.Object {
        // The object belongs to Env.
        const object = try self.lookUp(variable.name.lexeme, expr);
        return try object.dupe(self.allocator);
    }

    fn lookUp(self: *Renderer, name: []const u8, key: *ast.Expr) !ast.Object {
        if (self.resolved.get(key)) |distance| {
            return try self.env.getAt(distance, name);
        }
        return try self.globals.get(name);
    }

    fn assignExpression(self: *Renderer, expr: *ast.Expr, assign: ast.Assign) !ast.Object {
        const object = try self.evaluate(assign.value);
        errdefer object.deinit(self.allocator);

        // Transfer the value's ownership to interpreter's env.
        if (self.resolved.get(expr)) |distance| {
            try self.env.assignAt(self.allocator, distance, assign.name.lexeme, object);
        } else {
            try self.globals.assign(self.allocator, assign.name.lexeme, object);
        }
        return try object.dupe(self.allocator);
    }

    fn thisExpression(self: *Renderer, expr: *ast.Expr, this: ast.This) !ast.Object {
        // The object belongs to Env.
        const object = try self.lookUp(this.name.lexeme, expr);
        return try object.dupe(self.allocator);
    }

    // Create a new Fun Callable with instance appended to closure env.
    fn bind(self: *Renderer, method: ast.Object, this: ast.Object) !ast.Object {
        if (method != .callable) {
            return error.ExpectedCallable;
        }
        const callable = method.callable;

        if (callable != .fun) {
            return error.ExpectedFunction;
        }
        const fun = callable.fun;

        const local_env = try Env.create(self.allocator, fun.closure);
        errdefer local_env.deinit(self.allocator);

        // Append the this instnace to a new instance closure's Env.
        try local_env.define(self.allocator, "this", this);
        try self.closures.append(self.allocator, local_env);

        // Transfer the object's ownership to the caller.
        return .{
            .callable = .{
                .fun = .init(fun.stmt, fun.arity, local_env, fun.is_init),
            },
        };
    }

    // Pass the ownership to Interpreter's instances_fields.
    // It returns the instance fields location.
    fn appendInstance(self: *Renderer, instance: Table) !usize {
        const fields_index = self.instances_fields.items.len;
        try self.instances_fields.append(self.allocator, instance);
        return fields_index;
    }

    // Pass the ownership to Interpreter's classes_methods.
    // It returns the classes methods location.
    fn appendMethod(self: *Renderer, method: Table) !usize {
        const method_index = self.classes_methods.items.len;
        try self.classes_methods.append(self.allocator, method);
        return method_index;
    }

    // Truthy values are numbers, strings, and true.
    // Falsey values are false and nil.
    fn isTruthy(object: ast.Object) bool {
        return switch (object) {
            .boolean => |boolean| boolean,
            .nil => false,
            else => true,
        };
    }

    fn isEqual(a: ast.Object, b: ast.Object) bool {
        if (a.isNil() and b.isNil()) {
            return true;
        }
        if (a.isNil()) {
            return false;
        }
        if (a.isNumber() and b.isNumber()) {
            return a.number == b.number;
        }
        if (a.isString() and b.isString()) {
            return mem.eql(u8, a.string, b.string);
        }
        if (a.isBoolean() and b.isBoolean()) {
            return a.boolean == b.boolean;
        }
        // If both side are difference types.
        return false;
    }

    fn panic(self: *Renderer, token: Token, err: RendererError) RendererError {
        try self.ctx.panic("[{}] Error: {s}\n", .{ token.line, try getMessage(err) });
        return err;
    }

    fn getMessage(err: RendererError) RendererError![]const u8 {
        return switch (err) {
            error.UndefinedVariable => "Undefined Variable.",
            error.InvalidBinaryOperands => "Invalid Binary Operands.",
            error.InvalidUnaryOperand => "Invalid Unary Operand.",
            error.InvalidFunctionArity => "Invalid Function Arity.",
            error.ExpectedCallable => "Expected Callable.",
            error.ExpectedFunction => "Expected Function Statement.",
            error.ExpectedMethodFunction => "Expected Method Function Statement.",
            error.OnlyInstanceHasProperty => "Only Instance Has Property.",
            error.UndefinedProperty => "UndefinedProperty",
            else => return err,
        };
    }
};

test "interpreter" {
    // Literal Evaluation
    try testInterpreter("10;", "10");
    try testInterpreter("12.34;", "12.34");
    try testInterpreter("false;", "false");
    try testInterpreter(
        \\ "Hello world";
    , "Hello world");
    try testInterpreter("nil;", "");

    // Grouping Evaluation
    try testInterpreter("(10);", "10");
    try testInterpreter("(12.34);", "12.34");
    try testInterpreter("(true);", "true");
    try testInterpreter(
        \\ ("Hello World");
    , "Hello World");
    try testInterpreter("(nil);", "");

    // Binary Evaluation
    try testInterpreter("10 + 10;", "20");
    try testInterpreter(
        \\ "Hello " + "world";
    , "Hello world");
    try testInterpreter(
        \\ "Hello " + 10;
    , "Hello 10");
    try testInterpreter("10 > 10;", "false");
    try testInterpreter("10 >= 10;", "true");
    try testInterpreter("10 < 10;", "false");
    try testInterpreter("10 <= 10;", "true");
    try testInterpreter("10 - 10;", "0");
    try testInterpreter("10 / 10;", "1");
    try testInterpreter("10 * 10;", "100");
    try testInterpreter("10 == 10;", "true");
    try testInterpreter("10 != 10;", "false");
    try testInterpreter(
        \\ "hello" == "hello";
    , "true");
    try testInterpreter(
        \\ "hello" != "hello";
    , "false");
    try testInterpreter("true == true;", "true");
    try testInterpreter("true != true;", "false");
    try testInterpreter("nil == nil;", "true");
    try testInterpreter("nil != nil;", "false");

    // Or Logical Evaluation
    try testInterpreter("false or false;", "false");
    try testInterpreter("true or false;", "true");
    try testInterpreter("false or true;", "true");
    try testInterpreter("true or true;", "true");

    // And Logical Evaluation
    try testInterpreter("false and false;", "false");
    try testInterpreter("false and true;", "false");
    try testInterpreter("true and false;", "false");
    try testInterpreter("true and true;", "true");

    // Unary Evaluation
    try testInterpreter("!true;", "false");
    try testInterpreter("!10;", "false");
    try testInterpreter(
        \\ !"hello";
    , "false");
    try testInterpreter("!nil;", "true");
    try testInterpreter("-10;", "-10");

    // Assign Evaluation
    try testInterpreter(
        \\ var name = "John Wick";
    , "John Wick");

    // Variable Evaluation
    try testInterpreter("var name;", "");
    try testInterpreter(
        \\ var name = "John Wick";
    , "John Wick");

    // Print Evaluation
    try testInterpreter(
        \\ print "hello world";
    , "hello world\n");

    // Block Evaluation
    try testInterpreter(
        \\ { print "hello world"; }
    , "hello world\n");

    // If Evaluation
    try testInterpreter(
        \\ if (true) { print true; } else { print false; }
    , "true\n");
    try testInterpreter(
        \\ if (false) { print true; } else { print false; }
    , "false\n");
    try testInterpreter(
        \\ if (true) print true; else print false;
    , "true\n");
    try testInterpreter(
        \\ if (false) print true; else print false;
    , "false\n");
    try testInterpreter(
        \\ if (false) if (true) print true; else print false;
    , "");
    try testInterpreter(
        \\ if (true) if (false) print true; else print false;
    , "false\n");
    try testInterpreter(
        \\ if (true) 10; else 20;
    , "10");
    try testInterpreter(
        \\ if (false) 10; else 20;
    , "20");

    // While Evaluation
    try testInterpreter(
        \\ var i = 1;
        \\ while(i <= 2) { print "hello"; i = i + 1; }
    , "1hello\nhello\n");

    // For Evaluation
    try testInterpreter(
        \\ for(var i = 0; i < 5; i = i + 1) print i;
    , "0\n1\n2\n3\n4\n");

    // Fun Evaluation
    try testInterpreter(
        \\ fun count(n) {
        \\   if (n > 1) count(n - 1);
        \\   print n;
        \\ }
        \\ count(3);
    , "1\n2\n3\n");

    try testInterpreter(
        \\ fun fib(n) {
        \\   if (n < 2) return n;
        \\   return fib(n - 2) + fib(n - 1);
        \\ }
        \\ fib(10);
    , "55");

    try testInterpreter(
        \\ fun makeCounter() {
        \\   var i = 0;
        \\   fun count() {
        \\     i = i + 1;
        \\     print i;
        \\   }
        \\
        \\   return count;
        \\ }
        \\
        \\ var counter = makeCounter();
        \\ counter();
        \\ counter(); // "2".
    , "<fn count>1\n2\n");

    // Resovler Evaluation
    try testInterpreter(
        \\ var a = "global";
        \\ {
        \\   fun showA() {
        \\     print a;
        \\   }
        \\ 
        \\   showA();
        \\   var a = "block";
        \\   showA();
        \\ }
    , "globalglobal\nblock\n");

    // Classes Evaluation
    try testInterpreter(
        \\ class Breakfast {
        \\   cook() {
        \\     print "Eggs a-fryin'!";
        \\   }
        \\ 
        \\   serve(who) {
        \\     print "Enjoy your breakfast, " + who + ".";
        \\   }
        \\ }
        \\ print Breakfast;
    , "<class Breakfast>\n");

    try testInterpreter(
        \\ class Bacon {
        \\   eat() {
        \\     print "Crunch crunch crunch!";
        \\   }
        \\ }
        \\ 
        \\ Bacon().eat();
    , "Crunch crunch crunch!\n");

    try testInterpreter(
        \\ class User {
        \\   init(name) {
        \\     this.name = name;
        \\   }
        \\ 
        \\   greet() {
        \\     print "hello, I am " + this.name;
        \\   }
        \\ }
        \\
        \\ var john = User("John");
        \\ john.greet();
    , "<User instance>hello, I am John\n");
}

fn testInterpreter(
    source: [:0]const u8,
    print_out: []const u8,
) !void {
    const gpa = testing.allocator;

    var buffer: [1024]u8 = undefined;
    var io_out: Io.Writer = .fixed(&buffer);

    var ctx: Ctx = .init(undefined, .{ .out = &io_out, .err = &io_out });

    const stmt_list = try analyzer.parse(gpa, &ctx, source);
    defer stmt_list.deinit(gpa);

    var resolved = try resolver.resolve(gpa, &ctx, stmt_list.list);
    defer resolved.deinit();

    var renderer: Renderer = try .init(gpa, &ctx, resolved);
    defer renderer.deinit();

    for (stmt_list.list) |stmt| {
        const object = try renderer.execute(stmt);
        defer object.deinit(renderer.allocator);

        if (object != .nil) {
            try object.toPrint(&io_out);
        }
    }
    try testing.expectEqualSlices(u8, print_out, io_out.buffered());
}

const std = @import("std");
const debug = std.debug;
const fmt = std.fmt;
const heap = std.heap;
const mem = std.mem;
const testing = std.testing;
const Allocator = mem.Allocator;
const ArenaAllocator = heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;
const Io = std.Io;
const StringHashMap = std.StringHashMap;

const analyzer = @import("analyzer.zig");
const ast = @import("ast.zig");
const Ctx = @import("Context.zig");
const Env = @import("EnvSoa.zig");
const resolver = @import("resolver.zig");
const tokenizer = @import("tokenizer.zig");
const Resolver = resolver.Resolver;
const Token = tokenizer.Token;
