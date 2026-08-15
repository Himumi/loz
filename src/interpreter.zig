pub fn render(gpa: Allocator, ctx: *Ctx, tree: ast.Ast) RendererError!void {
    var renderer: Renderer = try .init(gpa, ctx);
    defer renderer.deinit();

    return try renderer.render(tree);
}

pub fn print(gpa: Allocator, ctx: *Ctx, tree: ast.Ast) RendererError!void {
    var renderer: Renderer = try .init(gpa, ctx);
    defer renderer.deinit();

    return try renderer.print(tree);
}

pub const RendererError = Renderer.Error || Env.Error || Io.Writer.Error || Allocator.Error;

pub const Renderer = struct {
    allocator: Allocator,
    ctx: *Ctx,
    tree: ast.Ast,

    env: *Env,
    env_list: ArrayList(*Env),

    // Rope Strings store.
    string_hash: AutoHashMap(ast.String, Distance),
    string_pool: ast.Store(ast.String),

    fun_list: ArrayList(ast.Fun),
    class_list: ArrayList(ast.Class),
    instance_list: ArrayList(ast.Instance),

    fields_list: ArrayList(ast.Store(ast.Object)),
    methods_list: ArrayList(ast.Store(FunIndex)),

    had_return: ?ast.Object,

    const Distance = u32;
    const FunIndex = u32;

    pub const Error = error{
        InvalidBinaryOperands,
        InvalidUnaryOperand,
        InvalidFunctionArity,
        ExpectedCallable,
        ExpectedFunction,
        ExpectedMethodFunction,
        OnlyInstanceHasProperty,
        NotFoundString,
        UndefinedProperty,
        UninitializedInstance,
    };

    pub fn init(gpa: Allocator, ctx: *Ctx) Allocator.Error!Renderer {
        const env = try Env.create(gpa, null);
        errdefer env.deinit(gpa);

        var env_list: ArrayList(*Env) = .empty;
        errdefer env_list.deinit(gpa);

        try env_list.append(gpa, env);

        return .{
            .allocator = gpa,
            .ctx = ctx,
            .tree = undefined,

            .env = env,
            .env_list = env_list,

            .string_hash = .init(gpa),
            .string_pool = .empty,

            .fun_list = .empty,
            .class_list = .empty,
            .instance_list = .empty,

            .fields_list = .empty,
            .methods_list = .empty,

            .had_return = null,
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.string_hash.deinit();
        self.string_pool.deinit(self.allocator);

        self.fun_list.deinit(self.allocator);
        self.class_list.deinit(self.allocator);
        self.instance_list.deinit(self.allocator);

        for (self.fields_list.items) |*fields| {
            fields.deinit(self.allocator);
        }
        self.fields_list.deinit(self.allocator);

        for (self.methods_list.items) |*methods| {
            methods.deinit(self.allocator);
        }
        self.methods_list.deinit(self.allocator);

        for (self.env_list.items) |env| {
            env.destroy(self.allocator);
        }
        self.env_list.deinit(self.allocator);
    }

    pub fn render(self: *Renderer, tree: ast.Ast) RendererError!void {
        var arena_allocator: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena_allocator.deinit();

        const runtime_arena = arena_allocator.allocator();
        self.tree = tree;

        for (self.tree.roots) |root| {
            _ = try self.evaluate(runtime_arena, root);
            _ = arena_allocator.reset(.retain_capacity);
        }
    }

    pub fn print(self: *Renderer, tree: ast.Ast) RendererError!void {
        var arena_allocator: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena_allocator.deinit();

        const runtime_arena = arena_allocator.allocator();
        self.tree = tree;

        for (self.tree.roots) |root| {
            const object = try self.evaluate(runtime_arena, root);
            if (object != .nil) {
                try self.dumpln(self.ctx.stream.out, object);
            }
            _ = arena_allocator.reset(.retain_capacity);
        }
    }

    pub fn execute(self: *Renderer, tree: ast.Ast, node_index: u32) RendererError!ast.Object {
        var arena_allocator: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena_allocator.deinit();

        const runtime_arena = arena_allocator.allocator();
        self.tree = tree;

        return try self.evaluate(runtime_arena, node_index);
    }

    fn evaluate(self: *Renderer, gpa: Allocator, node_index: u32) RendererError!ast.Object {
        const node = self.tree.getNode(node_index);
        return switch (node.tag) {
            // Expressions //

            .binary => try self.evalBinary(gpa, node_index),
            .call => try self.evalCall(node_index),
            .get => try self.evalGet(gpa, node_index),
            .group => try self.evaluate(gpa, node.data.lhs),
            .unary => try self.evalUnary(gpa, node_index),
            .literal => ast.Object.from(self.tree.getLiteral(node.data.lhs)),
            .logical => try self.evalLogical(gpa, node_index),
            .set => try self.evalSet(gpa, node_index),
            .variable => try self.lookUp(node_index, node.token),
            .assign => try self.evalAssign(gpa, node_index),
            .this => try self.lookUp(node_index, node.token),

            // // Statements //

            .expr => try self.evaluate(gpa, node.data.lhs),
            .fun => try self.evalFun(node_index),
            .@"if" => try self.evalIf(gpa, node_index),
            .print => {
                const object = try self.evaluate(gpa, node.data.lhs);
                try self.dumpln(self.ctx.stream.out, object);
                return .nil;
            },
            .@"return" => {
                self.had_return = try self.evalOptional(gpa, node.data.lhs);
                return .nil;
            },
            .@"var" => {
                const object = try self.evalOptional(gpa, node.data.lhs);
                try self.env.define(self.allocator, self.tree.getSymbol(node.token), object);
                return object;
            },
            .@"while" => try self.evalWhile(node_index),
            .block => try self.evalBlock(gpa, node_index),
            .class => try self.evalClass(gpa, node_index),
        };
    }

    fn evalAssign(self: *Renderer, gpa: Allocator, assign_index: u32) !ast.Object {
        const node = self.tree.getNode(assign_index);
        const assign_symbol = self.tree.getSymbol(node.token);

        const object = try self.evaluate(gpa, node.data.lhs);

        if (self.tree.resolved.getForward(assign_index)) |distance| {
            try self.env.lookUp(distance).set(assign_symbol, object);
        } else {
            // Assign the object to Global Env.
            try self.env_list.items[0].assign(assign_symbol, object);
        }
        return object;
    }

    fn evalBinary(self: *Renderer, gpa: Allocator, binary_index: u32) !ast.Object {
        const node = self.tree.getNode(binary_index);

        const operator = self.tree.getToken(node.token);
        const left = try self.evaluate(gpa, node.data.lhs);
        const right = try self.evaluate(gpa, node.data.rhs);

        if (operator.tag == .plus) {
            if (left.isNumber() and right.isNumber()) {
                return .{ .number = left.number + right.number };
            }
            if (left.isString() and right.isString()) {
                return .{ .string = try self.concat(left.string, right.string) };
            }
            if (left.isString() and right.isNumber()) {
                return .{ .string = try self.concat(left.string, .fromNumber(right.number)) };
            }
        }
        if (left.isNumber() and right.isNumber()) {
            switch (operator.tag) {
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
        if (left.isSame(right)) {
            switch (operator.tag) {
                .equal_equal => {
                    return .{ .boolean = try self.isEqual(left, right) };
                },
                .bang_equal => {
                    return .{ .boolean = !try self.isEqual(left, right) };
                },
                else => {},
            }
        }
        return self.panic(operator, error.InvalidBinaryOperands);
    }

    fn evalBlock(self: *Renderer, gpa: Allocator, block_index: u32) !ast.Object {
        const node = self.tree.getNode(block_index);
        const list = self.tree.sliceExtra(node.data.lhs, node.data.rhs);

        for (list) |index| {
            _ = try self.evaluate(gpa, index);

            if (self.had_return) |result| {
                self.had_return = null;
                return result;
            }
        }
        return .nil;
    }

    fn evalCall(self: *Renderer, call_index: u32) !ast.Object {
        var arena_allocator: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena_allocator.deinit();

        const arena = arena_allocator.allocator();

        const node = self.tree.getNode(call_index);
        const token = self.tree.getToken(node.token);

        const callee = try self.evaluate(arena, node.data.lhs);

        if (!callee.isFun() and !callee.isClass()) {
            return self.panic(token, error.ExpectedCallable);
        }

        const offset = node.data.rhs + 1;
        const len = self.tree.getExtra(node.data.rhs);

        var list: ArrayList(ast.Object) = try .initCapacity(arena, @intCast(len));

        // Append the evaluated arguments to a list.
        for (self.tree.sliceExtra(offset, offset + len)) |arg_index| {
            try list.append(arena, try self.evaluate(arena, arg_index));
        }

        // Validate the callable's arity with actual arguments length.
        const arity_len: usize = @intCast(self.arity(callee));
        if (list.items.len != arity_len) {
            return self.panic(token, error.InvalidFunctionArity);
        }

        return switch (callee) {
            .fun => |fun_index| try self.callFn(arena, fun_index, list.items),
            .class => |class_index| try self.callClass(arena, class_index, list.items),
            else => return self.panic(token, error.ExpectedCallable),
        };
    }

    fn evalClass(self: *Renderer, gpa: Allocator, class_index: u32) !ast.Object {
        const node = self.tree.getNode(class_index);

        const class_symbol = self.tree.getSymbol(node.token);
        try self.env.define(self.allocator, class_symbol, .nil);

        var methods: ast.Store(u32) = .empty;
        errdefer methods.deinit(gpa);

        // Map the class's methods.
        for (self.tree.sliceExtra(node.data.lhs, node.data.rhs)) |method_index| {
            const method_node = self.tree.getNode(method_index);
            const method_token = self.tree.getToken(method_node.token);

            if (method_node.tag != .fun) {
                return self.panic(method_token, error.ExpectedMethodFunction);
            }

            const is_init = mem.eql(u8, method_token.lexeme(self.tree.source), "init");
            // Store the class's methods (fun) to interpreter's fun_list.
            const index = try self.appendFun(.{
                .tag = if (is_init) .init else .fun,
                .stmt = method_index,
                .arity = @intCast(self.tree.getExtra(method_node.data.lhs)),
                .closure = self.env,
            });
            try methods.append(self.allocator, self.tree.getSymbol(method_node.token), index);
        }

        // Store the class's methods to interpreter's methods_list.
        const method_index = try self.appendMethods(methods);

        // Store the class's Class to interpreter's class_list.
        const index = try self.appendClass(.{
            .stmt = class_index,
            .super = 0,
            .methods = method_index,
        });
        try self.env.assign(class_symbol, .{ .class = index });
        return .nil;
    }

    fn evalFun(self: *Renderer, fun_index: u32) !ast.Object {
        const node = self.tree.getNode(fun_index);

        const token = self.tree.getToken(node.token);
        const lexeme = token.lexeme(self.tree.source);
        const symbol = self.tree.getSymbol(node.token);

        const index = try self.appendFun(.{
            .tag = if (mem.eql(u8, lexeme, "init")) .init else .fun,
            .stmt = fun_index,
            .arity = @intCast(self.tree.getExtra(node.data.lhs)),
            .closure = self.env,
        });
        try self.env.define(self.allocator, symbol, .{ .fun = index });
        return .nil;
    }

    fn evalIf(self: *Renderer, gpa: Allocator, if_index: u32) !ast.Object {
        const node = self.tree.getNode(if_index);
        const condition = try self.evaluate(gpa, node.data.lhs);

        const offset = node.data.rhs + 1;
        const len = self.tree.getExtra(node.data.rhs);

        // Evaluate 'Then' node.
        if (isTruthy(condition)) {
            return try self.evaluate(gpa, self.tree.getExtra(offset));
        }
        // Evaluate 'Else' node.
        if (len > 1) {
            return try self.evaluate(gpa, self.tree.getExtra(offset + 1));
        }
        return .nil;
    }

    fn evalGet(self: *Renderer, gpa: Allocator, get_index: u32) !ast.Object {
        const node = self.tree.getNode(get_index);
        const token = self.tree.getToken(node.token);
        const get_symbol = self.tree.getSymbol(node.token);

        const value = try self.evaluate(gpa, node.data.lhs);

        if (!value.isInstance()) {
            return self.panic(token, error.OnlyInstanceHasProperty);
        }
        const instance = self.getInstance(value.instance);

        // Get the instance's field.
        if (self.fields_list.items.len > 0) {
            const fields = self.getFieldsPtr(instance.fields);
            if (fields.getForward(get_symbol)) |object| {
                return object;
            }
        }

        // Get the instance's method.
        if (self.methods_list.items.len > 0) {
            const methods = self.getMethodPtr(instance.methods);
            if (methods.getForward(get_symbol)) |method| {
                return try self.bind(method, value);
            }
        }
        return self.panic(token, error.UndefinedProperty);
    }

    fn evalLogical(self: *Renderer, gpa: Allocator, logical_index: u32) !ast.Object {
        const node = self.tree.getNode(logical_index);

        const operator = self.tree.getToken(node.token);
        const left = try self.evaluate(gpa, node.data.lhs);

        if (operator.tag == .keyword_or) {
            if (isTruthy(left)) return left;
        } else {
            if (!isTruthy(left)) return left;
        }
        return try self.evaluate(gpa, node.data.rhs);
    }

    fn evalOptional(self: *Renderer, gpa: Allocator, node_index: u32) !ast.Object {
        if (node_index == 0) {
            return .nil;
        }
        return try self.evaluate(gpa, node_index);
    }

    fn evalSet(self: *Renderer, gpa: Allocator, set_index: u32) !ast.Object {
        const node = self.tree.getNode(set_index);
        const token = self.tree.getToken(node.token);
        const set_symbol = self.tree.getSymbol(node.token);

        const object = try self.evaluate(gpa, node.data.lhs);

        if (!object.isInstance()) {
            return self.panic(token, error.OnlyInstanceHasProperty);
        }
        const instance = self.getInstance(object.instance);

        const value = try self.evaluate(gpa, node.data.rhs);

        // Set a new field or a new value to the target instance's fields_list.
        if (self.fields_list.items.len > 0) {
            const fields = self.getFieldsPtr(instance.fields);
            fields.setForward(set_symbol, value) catch {
                try fields.append(self.allocator, set_symbol, value);
            };
            return value;
        }
        return self.panic(token, error.UninitializedInstance);
    }

    fn evalUnary(self: *Renderer, gpa: Allocator, unary_index: u32) !ast.Object {
        const node = self.tree.getNode(unary_index);

        const operator = self.tree.getToken(node.token);
        const right = try self.evaluate(gpa, node.data.lhs);

        return switch (operator.tag) {
            .bang => .{ .boolean = !isTruthy(right) },
            .minus => {
                if (right.isNumber()) {
                    return .{ .number = -right.number };
                }
                return self.panic(operator, error.InvalidUnaryOperand);
            },
            else => .nil,
        };
    }

    fn evalWhile(self: *Renderer, while_index: u32) !ast.Object {
        var arena_allocator: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena_allocator.deinit();

        const arena = arena_allocator.allocator();
        const node = self.tree.getNode(while_index);

        while (isTruthy(try self.evaluate(arena, node.data.lhs))) {
            _ = try self.evaluate(arena, node.data.rhs);
            _ = arena_allocator.reset(.retain_capacity);
        }
        return .nil;
    }

    fn appendClass(self: *Renderer, class: ast.Class) !u32 {
        const index = self.class_list.items.len;
        try self.class_list.append(self.allocator, class);
        return @intCast(index);
    }

    fn appendFields(self: *Renderer, fields: ast.Store(ast.Object)) !u32 {
        const index = self.fields_list.items.len;
        try self.fields_list.append(self.allocator, fields);
        return @intCast(index);
    }

    fn appendFun(self: *Renderer, fun: ast.Fun) !u32 {
        const index = self.fun_list.items.len;
        try self.fun_list.append(self.allocator, fun);
        return @intCast(index);
    }

    fn appendInstance(self: *Renderer, instance: ast.Instance) !u32 {
        const index = self.instance_list.items.len;
        try self.instance_list.append(self.allocator, instance);
        return @intCast(index);
    }

    fn appendMethods(self: *Renderer, methods: ast.Store(u32)) !u32 {
        const index = self.methods_list.items.len;
        try self.methods_list.append(self.allocator, methods);
        return @intCast(index);
    }

    fn appendString(self: *Renderer, string: ast.String) !u32 {
        // Check the current String existance.
        if (self.string_hash.get(string)) |index| {
            return @intCast(index);
        }

        const index: u32 = @intCast(self.string_pool.entries.len);
        // Append to String pool.
        try self.string_pool.append(self.allocator, index, string);
        // Add String to a hash map with String location (index).
        try self.string_hash.put(string, index);
        return index;
    }

    fn arity(self: *Renderer, object: ast.Object) u8 {
        return switch (object) {
            .fun => |fun_index| self.getFun(fun_index).arity,
            .class => |class_index| {
                const class = self.getClass(class_index);

                const methods = self.getMethodPtr(class.methods);
                for (methods.entries.items(.value)) |fun_index| {
                    const fun = self.getFun(fun_index);
                    if (fun.tag == .init) return fun.arity;
                }
                return 0;
            },
            else => 0,
        };
    }

    fn bind(self: *Renderer, fun_index: u32, this: ast.Object) !ast.Object {
        const fun = self.getFun(fun_index);

        const local_env = try Env.create(self.allocator, fun.closure);
        errdefer local_env.destroy(self.allocator);

        try local_env.define(self.allocator, @intFromEnum(Token.Tag.keyword_this), this);
        try self.env_list.append(self.allocator, local_env);

        // Store the binded fun with instance to interpreter's instance_list.
        const binded_index = try self.appendFun(.{
            .tag = fun.tag,
            .stmt = fun.stmt,
            .arity = fun.arity,
            .closure = local_env,
        });
        return .{ .fun = binded_index };
    }

    fn callClass(
        self: *Renderer,
        gpa: Allocator,
        class_index: u32,
        args: []const ast.Object,
    ) !ast.Object {
        const class = self.getClass(class_index);
        const fields_index = try self.appendFields(.empty);

        const instance_index = try self.appendInstance(.{
            .stmt = class_index,
            .fields = fields_index,
            .methods = class.methods,
        });
        const instance: ast.Object = .{ .instance = instance_index };

        const methods = self.getMethodPtr(class.methods);
        for (methods.entries.items(.value)) |fun_index| {
            const fun = self.getFun(fun_index);
            if (fun.tag == .init) {
                // Bind the initializer method with the instance.
                const binded = try self.bind(fun_index, instance);
                return try self.callFn(gpa, binded.fun, args);
            }
        }
        return instance;
    }

    fn callFn(
        self: *Renderer,
        gpa: Allocator,
        fun_index: u32,
        args: []const ast.Object,
    ) !ast.Object {
        const fun = self.getFun(fun_index);
        const fun_node = self.tree.getNode(fun.stmt);

        const global_env = self.env;
        defer self.env = global_env;

        var fun_env = fun.closure;
        fun_env.enclosing = global_env;
        defer fun_env.enclosing = null;

        // The local_env belongs to global allocator.
        const local_env = try Env.create(self.allocator, fun_env);
        errdefer local_env.destroy(self.allocator);
        self.env = local_env;

        const len = self.tree.getExtra(fun_node.data.lhs);
        const offset = fun_node.data.lhs + 1;

        // Transfer arguments' ownership to local_env.
        for (self.tree.sliceExtra(offset, offset + len), 0..) |param_index, i| {
            const symbol = self.tree.getSymbol(param_index);
            try self.env.define(self.allocator, symbol, args[i]);
        }

        // Evaluate the function body.
        const object = try self.evaluate(gpa, fun_node.data.rhs);

        if (object.isFun()) { // Consider to add Class member.
            // Store the local_env to interpreter's env_list.
            try self.env_list.append(self.allocator, local_env);
        } else {
            local_env.destroy(self.allocator);
        }

        // Return This' instance for a class initializer.
        if (fun.tag == .init) {
            return try fun_env.get(@intFromEnum(Token.Tag.keyword_this));
        }
        return object;
    }

    fn concat(self: *Renderer, left: ast.String, right: ast.String) !ast.String {
        const left_index = try self.appendString(left);
        const right_index = try self.appendString(right);

        return .{
            .concat = .{ .left = left_index, .right = right_index },
        };
    }

    fn dump(self: Renderer, writer: *Io.Writer, object: ast.Object) !void {
        switch (object) {
            .number => |number| try writer.print("{}", .{number}),
            .boolean => |boolean| try writer.print("{}", .{boolean}),
            .nil => try writer.writeAll("nil"),
            .string => |string| try self.dumpString(writer, string),
            .class => |class_index| try self.dumpClass(writer, class_index),
            .fun => |fun_index| try self.dumpFun(writer, fun_index),
            .instance => |instance_index| try self.dumpInstance(writer, instance_index),
        }
    }

    pub fn dumpln(self: Renderer, writer: *Io.Writer, object: ast.Object) !void {
        try self.dump(writer, object);
        try self.ctx.stream.out.writeByte('\n');
    }

    fn dumpClass(self: Renderer, writer: *Io.Writer, class_index: u32) !void {
        const class = self.getClass(class_index);
        const class_node = self.tree.getNode(class.stmt);
        const class_token = self.tree.getToken(class_node.token);
        try writer.print("<class {s}>", .{class_token.lexeme(self.tree.source)});
    }

    fn dumpFun(self: Renderer, writer: *Io.Writer, fun_index: u32) !void {
        const fun = self.getFun(fun_index);
        const fun_node = self.tree.getNode(fun.stmt);
        const fun_token = self.tree.getToken(fun_node.token);
        try writer.print("<fun {s}>", .{fun_token.lexeme(self.tree.source)});
    }

    fn dumpInstance(self: Renderer, writer: *Io.Writer, instance_index: u32) !void {
        const instance = self.getInstance(instance_index);
        const instance_node = self.tree.getNode(instance.stmt);
        const instance_token = self.tree.getToken(instance_node.token);
        try writer.print("<instance {s}>", .{instance_token.lexeme(self.tree.source)});
    }

    fn dumpString(self: Renderer, writer: *Io.Writer, string: ast.String) !void {
        switch (string) {
            .literal => |literal| {
                const token = self.tree.getToken(literal);
                const lexeme = switch (token.tag) {
                    .string => self.tree.source[token.loc.start + 1 .. token.loc.end - 1],
                    else => token.lexeme(self.tree.source),
                };
                try writer.print("{s}", .{lexeme});
            },
            .concat => |value| {
                const left = self.string_pool.getForward(value.left) orelse {
                    return error.NotFoundString;
                };
                try self.dumpString(writer, left);

                const right = self.string_pool.getBackward(value.right) orelse {
                    return error.NotFoundString;
                };
                try self.dumpString(writer, right);
            },
            .number => |number| {
                const real_number: f64 = @bitCast(number);
                try writer.print("{}", .{real_number});
            },
        }
    }

    fn getClass(self: Renderer, class_index: u32) ast.Class {
        return self.class_list.items[@intCast(class_index)];
    }

    fn getFieldsPtr(self: *Renderer, fields_index: u32) *ast.Store(ast.Object) {
        return &self.fields_list.items[@intCast(fields_index)];
    }

    fn getFun(self: Renderer, fun_index: u32) ast.Fun {
        return self.fun_list.items[@intCast(fun_index)];
    }

    fn getInstance(self: Renderer, instance_index: u32) ast.Instance {
        return self.instance_list.items[@intCast(instance_index)];
    }

    fn getMethodPtr(self: *Renderer, methods_index: u32) *ast.Store(FunIndex) {
        return &self.methods_list.items[@intCast(methods_index)];
    }

    fn isEqual(self: Renderer, a: ast.Object, b: ast.Object) !bool {
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
            return try self.isSameString(a.string, b.string);
        }
        if (a.isBoolean() and b.isBoolean()) {
            return a.boolean == b.boolean;
        }
        // If both side are difference types.
        return false;
    }

    fn isSameString(self: Renderer, a: ast.String, b: ast.String) !bool {
        var buffer: Io.Writer.Allocating = .init(self.allocator);
        defer buffer.deinit();

        try self.dumpString(&buffer.writer, a);
        const offset = buffer.written().len;
        try self.dumpString(&buffer.writer, b);

        const written = buffer.written();
        return mem.eql(u8, written[0..offset], written[offset..]);
    }

    fn isTruthy(object: ast.Object) bool {
        return switch (object) {
            .boolean => |boolean| boolean,
            .nil => false,
            else => true,
        };
    }

    fn lookUp(self: Renderer, node_index: u32, token_index: u32) !ast.Object {
        const symbol = self.tree.getSymbol(token_index);
        if (self.tree.resolved.getForward(node_index)) |distance| {
            return try self.env.lookUp(distance).get(symbol);
        }
        // Look up variable in global Env.
        return self.env_list.items[0].get(symbol);
    }

    fn panic(self: *Renderer, token: Token, err: RendererError) RendererError {
        const message = try getMessage(err);
        // TODO: Need to separate it from tokenizer.
        try tokenizer.panic(self.ctx, self.tree.source, token.loc.start, message);
        return err;
    }

    fn getMessage(err: RendererError) RendererError![]const u8 {
        return switch (err) {
            error.InvalidBinaryOperands => "Invalid Binary Operands",
            error.InvalidUnaryOperand => "Invalid Unary Operands",
            error.InvalidFunctionArity => "Invalid Function Arity",
            error.ExpectedCallable => "Expected A Callable",
            error.ExpectedFunction => "Expected A Function",
            error.ExpectedMethodFunction => "Expected A Method Function",
            error.OnlyInstanceHasProperty => "Only Instance Has Proprety",
            error.NotFoundString => "Not Found String",
            error.UndefinedProperty => "Undefined Property",
            error.UninitializedInstance => "Uninitialized Instance",
            else => return err,
        };
    }
};

test "Renderer" {
    // // Literal Evaluation
    try testInterpreter("10;", "10");
    try testInterpreter("12.34;", "12.34");
    try testInterpreter("false;", "false");
    try testInterpreter(
        \\ "Hello world";
    , "Hello world");
    try testInterpreter("nil;", "nil");

    // Grouping Evaluation
    try testInterpreter("(10);", "10");
    try testInterpreter("(12.34);", "12.34");
    try testInterpreter("(true);", "true");
    try testInterpreter(
        \\ ("Hello World");
    , "Hello World");
    try testInterpreter("(nil);", "nil");

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
    try testInterpreter("var name;", "nil");
    try testInterpreter(
        \\ var name = "John Wick";
    , "John Wick");

    // Print Evaluation
    try testInterpreter(
        \\ print "hello world";
    , "hello world\nnil");

    // Block Evaluation
    try testInterpreter(
        \\ { print "hello world"; }
    , "hello world\nnil");

    // If Evaluation
    try testInterpreter(
        \\ if (true) { print true; } else { print false; }
    , "true\nnil");
    try testInterpreter(
        \\ if (false) { print true; } else { print false; }
    , "false\nnil");
    try testInterpreter(
        \\ if (true) print true; else print false;
    , "true\nnil");
    try testInterpreter(
        \\ if (false) print true; else print false;
    , "false\nnil");
    try testInterpreter(
        \\ if (false) if (true) print true; else print false;
    , "nil");
    try testInterpreter(
        \\ if (true) if (false) print true; else print false;
    , "false\nnil");
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
    , "1hello\nhello\nnil");

    // For Evaluation
    try testInterpreter(
        \\ for(var i = 0; i < 5; i = i + 1) print i;
    , "0\n1\n2\n3\n4\nnil");

    // Fun Evaluation
    try testInterpreter(
        \\ fun count(n) {
        \\   if (n > 1) count(n - 1);
        \\   print n;
        \\ }
        \\ count(3);
    , "nil1\n2\n3\nnil");

    try testInterpreter(
        \\ fun fib(n) {
        \\   if (n < 2) return n;
        \\   return fib(n - 2) + fib(n - 1);
        \\ }
        \\ fib(10);
    , "nil55");

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
    , "nil<fun count>1\nnil2\nnil");

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
    , "globalglobal\nblock\nnil");

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
    , "nil<class Breakfast>\nnil");

    try testInterpreter(
        \\ class Bacon {
        \\   eat() {
        \\     print "Crunch crunch crunch!";
        \\   }
        \\ }
        \\
        \\ Bacon().eat();
    , "nilCrunch crunch crunch!\nnil");

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
    , "nil<instance User>hello, I am John\nnil");
}

fn testInterpreter(
    source: [:0]const u8,
    print_out: []const u8,
) !void {
    const gpa = testing.allocator;

    var buffer: [1024]u8 = undefined;
    var stream: Io.Writer = .fixed(&buffer);

    var ctx: Ctx = .init(undefined, .{ .out = &stream, .err = &stream });

    var tree = try parser.parse(gpa, &ctx, source);
    defer tree.deinit(gpa);

    tree.symbols = try interner.resolve(gpa, source, tree.tokens);
    defer gpa.free(tree.symbols);

    tree.resolved = try resolver.resolve(gpa, &ctx, tree);
    defer tree.resolved.deinit(gpa);

    var renderer: Renderer = try .init(gpa, &ctx);
    defer renderer.deinit();

    for (tree.roots) |root| {
        const object = try renderer.execute(tree, root);
        try renderer.dump(&stream, object);
    }
    try testing.expectEqualSlices(u8, print_out, stream.buffered());
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

const ast = @import("ast.zig");
const Ctx = @import("Context.zig");
const Env = @import("EnvSoa.zig");
const interner = @import("interner.zig");
const parser = @import("parser.zig");
const resolver = @import("resolver.zig");
const Resolver = resolver.Resolver;
const tokenizer = @import("tokenizer.zig");
const Token = tokenizer.Token;
