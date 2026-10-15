const std = @import("std");
const TypeId = std.builtin.TypeId;
const Allocator = std.mem.Allocator;

const deinit_kinds = std.EnumSet(TypeId).initMany(&.{
    .@"struct",
    .@"enum",
    .@"union",
    .@"opaque",
});

fn RcInner(comptime T: type, comptime Context: type) type {
    return struct {
        const Self = @This();

        value: T,
        strong: usize,
        weak: usize,
        ctx: Context,

        pub fn decWeak(self: *Self) void {
            self.weak -= 1;
        }

        pub fn incWeak(self: *Self) void {
            self.weak += 1;
        }

        pub fn decStrong(self: *Self) void {
            self.strong -= 1;
        }

        pub fn incStrong(self: *Self) void {
            self.strong += 1;
        }
    };
}

pub fn AutoWeak(comptime T: type) type {
    return Weak(T, AutoContext(T));
}

pub fn Weak(comptime T: type, comptime Context: type) type {
    return struct {
        const Self = @This();

        const Inner = RcInner(T, Context);

        inner: ?*Inner,
        allocator: Allocator,

        pub fn init(allocator: Allocator) Self {
            return .{ .inner = null, .allocator = allocator };
        }

        pub fn clone(self: Self) Self {
            if (self.inner) |in| {
                in.incWeak();
                return self;
            }
            return self;
        }

        pub fn drop(self: *Self) void {
            if (self.inner) |in| {
                in.decWeak();
                if (in.weak == 0) {
                    self.allocator.destroy(in);
                }
            }
            self.inner = null;
            return;
        }

        pub fn upgrade(self: Self) ?Rc(T, Context) {
            if (self.inner) |in| {
                if (in.strong == 0) {
                    return null;
                }
                in.incStrong();
                return .{
                    .inner = in,
                    .allocator = self.allocator,
                };
            } else {
                return null;
            }
        }

        pub fn weakCount(self: Self) usize {
            if (self.inner) |in| {
                if (in.strong > 0) {
                    return in.weak - 1;
                } else {
                    return 0;
                }
            } else {
                return 0;
            }
        }

        pub fn strongCount(self: Self) usize {
            if (self.inner) |in| {
                return in.strong;
            } else {
                return 0;
            }
        }

        pub fn ptrEql(self: Self, other: Self) bool {
            return self.inner == other.inner;
        }
    };
}

pub fn AutoContext(comptime T: type) type {
    if (deinit_kinds.contains(std.meta.activeTag(@typeInfo(T)))) {
        if (@hasDecl(T, "deinit")) {
            const fn_info = @typeInfo(@TypeOf(@field(T, "deinit"))).@"fn";
            if (fn_info.return_type) |ret_type| {
                if (ret_type != void) {
                    @compileError("Unexpected function signature for T.deinit, use `Rc` and provide a `ctx`.");
                }
            }
            const params = fn_info.params;
            const params_len = params.len;

            if (params_len == 1) {
                if (params[0].type) |param_type| {
                    if (param_type != *T and param_type != T) {
                        @compileError("Expected first parameter of `T.deinit` of type " ++ @typeName(T) ++ " or *" ++ @typeName(T) ++ " got " ++ @typeName(param_type) ++ ". Use Rc with a dedicated context instead.");
                    }
                }
                return struct {
                    pub fn deinit(self: @This(), ptr: *T, allocator: std.mem.Allocator) void {
                        _ = self;
                        _ = allocator;
                        ptr.deinit();
                    }
                };
            } else if (params_len == 2) {
                if (params[0].type) |param_type| {
                    if (param_type != *T and param_type != T) {
                        @compileError("Expected first parameter of `T.deinit` of type " ++ @typeName(T) ++ " or *" ++ @typeName(T) ++ ", got " ++ @typeName(param_type) ++ ". Use Rc with a dedicated context instead.");
                    }
                }
                if (params[1].type) |param_type| {
                    if (param_type != Allocator) {
                        @compileError("Expected second parameter of `T.deinit` of type Allocator, got " ++ @typeName(param_type) ++ ". Use Rc with a dedicated context instead.");
                    }
                }
                return struct {
                    pub fn deinit(self: @This(), ptr: *T, allocator: std.mem.Allocator) void {
                        _ = self;
                        ptr.deinit(allocator);
                    }
                };
            } else {
                @compileError("Unexpected function signature for T.deinit, use `Rc` and provide a `ctx`.");
            }
        }
    }
    return struct {
        pub fn deinit(self: @This(), ptr: *T, allocator: std.mem.Allocator) void {
            _ = self;
            _ = ptr;
            _ = allocator;
        }
    };
}

pub fn AutoRc(comptime T: type) type {
    return Rc(T, AutoContext(T));
}

pub fn Rc(comptime T: type, comptime Context: type) type {
    return struct {
        const Self = @This();

        const Inner = RcInner(T, Context);

        inner: *Inner,
        allocator: Allocator,

        pub fn init(allocator: Allocator, value: T) !Self {
            if (@sizeOf(Context) != 0) {
                @compileError("Context must be specified! Call initContext(allocator, ctx, value) instead.");
            }
            const inner = try allocator.create(Inner);
            inner.* = .{ .value = value, .strong = 1, .weak = 1, .ctx = undefined };
            return .{
                .inner = inner,
                .allocator = allocator,
            };
        }

        pub fn initContext(allocator: Allocator, ctx: Context, value: T) !Self {
            const inner = try allocator.create(Inner);
            inner.* = .{ .value = value, .strong = 1, .weak = 1, .ctx = ctx };
            return .{
                .inner = inner,
                .allocator = allocator,
            };
        }

        pub fn intoInner(self: *Self) ?T {
            if (self.inner.strong == 1) {
                const val = self.inner.value;
                self.inner.decStrong();
                self.dropImplicitWeak();
                self.inner = undefined;
                return val;
            }
            self.drop();
            return null;
        }

        pub fn clone(self: Self) Self {
            self.inner.incStrong();
            return self;
        }

        fn dropImplicitWeak(self: *Self) void {
            var weak = Weak(T, Context){ .inner = self.inner, .allocator = self.allocator };
            weak.drop();
        }

        pub fn drop(self: *Self) void {
            self.inner.decStrong();
            if (self.inner.strong == 0) {
                self.inner.ctx.deinit(self.getPtr(), self.allocator);
                self.dropImplicitWeak();
            }
            self.inner = undefined;
        }

        pub fn ptrEql(self: Self, other: Self) bool {
            return self.inner == other.inner;
        }

        pub fn weakCount(self: Self) usize {
            return self.inner.weak - 1;
        }

        pub fn strongCount(self: Self) usize {
            return self.inner.strong;
        }

        pub fn downgrade(self: Self) Weak(T, Context) {
            self.inner.incWeak();
            return .{ .inner = self.inner, .allocator = self.allocator };
        }

        pub fn getPtr(self: Self) *T {
            return &self.inner.value;
        }

        pub fn getConstPtr(self: Self) *const T {
            return &self.inner.value;
        }
    };
}
