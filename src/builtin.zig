const std = @import("std");
const runtime = @import("runtime.zig");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const AstNode = runtime.AstNode;
const DestructError = runtime.DestructError;
const RefMap = runtime.RefMap;
const resolvePrimitiveValue = runtime.resolvePrimitiveValue;
const resolveCharsValue = runtime.resolveCharsValue;
const AstFun = runtime.AstFun;
const BuiltinFn = runtime.BuiltinFn;
const PrimitiveValue = runtime.PrimitiveValue;
const PrimitiveValueType = runtime.PrimitiveValueType;

const debug = false;

pub const StreamStepType = enum { collect, systemOut, exec, filter, eval, skip, first };
pub const StreamStep = union(StreamStepType) {
    collect: CollectStep,
    systemOut: SystemOutStep,
    exec: ExecStep,
    filter: FilterStep,
    eval: EvalStep,
    skip: SkipStep,
    first: FirstStep,
    pub fn accept(self: *StreamStep, line_allocator: Allocator, line: [][]const u8) DestructError!bool {
        return switch (self.*) {
            .collect => try self.collect.accept(line),
            .systemOut => try self.systemOut.accept(line),
            .exec => try self.exec.accept(line),
            .filter => try self.filter.accept(line_allocator, line),
            .eval => try self.eval.accept(line_allocator, line),
            .skip => try self.skip.accept(line_allocator, line),
            .first => try self.first.accept(line_allocator, line),
        };
    }
};

pub const FilterStep = struct {
    next: *StreamStep,
    predicates: []const AstNode,
    refMap: []const RefMap,

    pub fn accept(self: FilterStep, line_allocator: Allocator, line: [][]const u8) DestructError!bool {
        for (self.predicates) |pred| {
            const p = (try resolvePrimitiveValue(line_allocator, self.refMap, line, pred)).toBool();

            if (!p) {
                return true;
            }
        }

        return try self.next.accept(line_allocator, line);
    }
};

pub const SkipStep = struct {
    next: *StreamStep,
    skipCount: i64,

    pub fn accept(self: *SkipStep, line_allocator: Allocator, line: [][]const u8) DestructError!bool {
        if (self.skipCount > 0) {
            self.skipCount -= 1;
            return true;
        } else {
            return try self.next.accept(line_allocator, line);
        }
    }
};

pub const FirstStep = struct {
    next: *StreamStep,
    count: i64,

    pub fn accept(self: *FirstStep, line_allocator: Allocator, line: [][]const u8) DestructError!bool {
        if (self.count > 0) {
            self.count -= 1;
            return try self.next.accept(line_allocator, line);
        } else {
            return false;
        }
    }
};

pub const EvalStep = struct {
    next: *StreamStep,
    expressions: []const AstNode,
    refMap: []const RefMap,

    pub fn accept(self: EvalStep, line_allocator: Allocator, line: [][]const u8) DestructError!bool {
        var ret = ArrayList([]const u8).init(line_allocator);
        for (self.expressions) |pred| {
            const p = try resolveCharsValue(line_allocator, self.refMap, line, pred);

            try ret.append(p);
        }

        return try self.next.accept(line_allocator, ret.items);
    }
};

pub const SystemOutStep = struct {
    writer: std.fs.File,

    pub fn accept(self: SystemOutStep, line: [][]const u8) DestructError!bool {
        for (line, 0..) |o, i| {
            if (i != 0) self.writer.writer().writeAll(" ") catch {
                return DestructError.undefined;
            };

            self.writer.writer().writeAll(o) catch {
                return DestructError.undefined;
            };
        }
        self.writer.writer().writeAll("\n") catch {
            return DestructError.undefined;
        };
        return true;
    }
};

pub const ExecStep = struct {
    allocator: Allocator,
    cmd: []const u8,

    pub fn accept(self: ExecStep, line: [][]const u8) !bool {
        var cmdLine = ArrayList([]const u8).init(self.allocator);
        try cmdLine.append(self.cmd);
        try cmdLine.appendSlice(line);
        var cp = std.ChildProcess.init(cmdLine.items, self.allocator);
        _ = cp.spawnAndWait() catch {
            std.debug.print("Failed to execute '{s}'\n", .{self.cmd});
            std.os.exit(1);
        };
        return true;
    }
};

pub const CollectStep = struct {
    items: ArrayList([][]const u8),

    pub fn accept(self: *CollectStep, line: [][]const u8) !bool {
        try self.items.append(line);
        return true;
    }
};

const BuiltinValidator = *const fn (AstFun, bool) DestructError!void;
pub const Builtin = struct {
    name: []const u8,
    impl: BuiltinFn,
};

const builtins = [_]Builtin{
    Builtin{ .name = "upper", .impl = builtinUpper },
    Builtin{ .name = "first", .impl = builtinFirst },
    Builtin{ .name = "rpad", .impl = builtinRPad },
    Builtin{ .name = "lpad", .impl = builtinLPad },
    Builtin{ .name = "str", .impl = builtinStr },
    Builtin{ .name = "eq", .impl = builtinEq },
    Builtin{ .name = "startsWith", .impl = builtinStartsWith },
    Builtin{ .name = "endsWith", .impl = builtinEndsWith },
    Builtin{ .name = "contains", .impl = builtinContains },
    Builtin{ .name = "gt", .impl = builtinGt },
    Builtin{ .name = "lt", .impl = builtinLt },
    Builtin{ .name = "if", .impl = builtinIf },
    Builtin{ .name = "not", .impl = builtinNot },
    Builtin{ .name = "and", .impl = builtinAnd },
    Builtin{ .name = "or", .impl = builtinOr },
};

// Actual builtins
// ===================================================================================
pub fn resolveBuiltin(name: []const u8) DestructError!BuiltinFn {
    for (builtins) |it| {
        if (std.mem.eql(u8, it.name, name)) {
            return it.impl;
        }
    }
    std.debug.print("Unknown function: '{s}'\n", .{name});
    return DestructError.unknown_function;
}

fn assertArgsEq(name: []const u8, expected: usize, actual: usize) !void {
    if (expected != actual) {
        std.debug.print(
            "Failed to execute '{s}', expects {d} arguments but got {d}\n",
            .{ name, expected, actual },
        );
        return DestructError.exec_arg_error;
    }
}

fn builtinUpper(allocator: Allocator, refMap: []const RefMap, line: [][]const u8, fun: AstFun) !PrimitiveValue {
    try assertArgsEq(fun.name, 1, fun.args.len);
    const arg1 = try resolveCharsValue(allocator, refMap, line, fun.args[0]);

    const refBuf = try allocator.alloc(u8, arg1.len);
    _ = std.ascii.upperString(refBuf, arg1);
    return PrimitiveValue{ .chars = refBuf };
}

fn builtinFirst(allocator: Allocator, refMap: []const RefMap, line: [][]const u8, fun: AstFun) !PrimitiveValue {
    try assertArgsEq(fun.name, 2, fun.args.len);
    const arg1 = fun.args[0];
    const asInt = @as(usize, @intCast(try (try resolvePrimitiveValue(allocator, refMap, line, fun.args[1])).toInt()));

    var refStr = try resolveCharsValue(allocator, refMap, line, arg1);
    const result = refStr[0..(asInt)];
    return PrimitiveValue{ .chars = result };
}

fn builtinRPad(allocator: Allocator, refMap: []const RefMap, line: [][]const u8, fun: AstFun) !PrimitiveValue {
    if ((fun.args.len != 2) and (fun.args.len != 3)) {
        std.debug.print(
            "Failed to execute '{s}', expects 2 or 3 arguments but got {d}\n",
            .{ fun.name, fun.args.len },
        );
        return DestructError.exec_arg_error;
    }
    const arg1 = fun.args[0];
    const asInt = @as(usize, @intCast(try (try resolvePrimitiveValue(allocator, refMap, line, fun.args[1])).toInt()));

    const refStr = try resolveCharsValue(allocator, refMap, line, arg1);
    //Exit early if no padding is nneeded
    if (refStr.len >= asInt) {
        return PrimitiveValue{ .chars = refStr };
    }
    var result = try allocator.alloc(u8, asInt);
    const filler = if (fun.args.len == 3) try resolveCharsValue(allocator, refMap, line, fun.args[2]) else " ";

    for (0..asInt) |i| {
        if (i < refStr.len) {
            result[i] = refStr[i];
        } else {
            const foff = (i - refStr.len) % filler.len;
            result[i] = filler[foff];
        }
    }
    return PrimitiveValue{ .chars = result };
}

fn builtinLPad(allocator: Allocator, refMap: []const RefMap, line: [][]const u8, fun: AstFun) !PrimitiveValue {
    if ((fun.args.len != 2) and (fun.args.len != 3)) {
        std.debug.print(
            "Failed to execute '{s}', expects 2 or 3 arguments but got {d}\n",
            .{ fun.name, fun.args.len },
        );
        return DestructError.exec_arg_error;
    }
    const arg1 = fun.args[0];
    const asInt = @as(usize, @intCast(try (try resolvePrimitiveValue(allocator, refMap, line, fun.args[1])).toInt()));

    const refStr = try resolveCharsValue(allocator, refMap, line, arg1);
    var result = try allocator.alloc(u8, asInt);

    if (refStr.len >= asInt) {
        return PrimitiveValue{ .chars = refStr };
    }

    const filler = if (fun.args.len == 3) try resolveCharsValue(allocator, refMap, line, fun.args[2]) else " ";

    const refOffset = asInt - refStr.len;

    for (0..asInt) |i| {
        if (i >= refOffset) {
            result[i] = refStr[i - refOffset];
        } else {
            const foff = i % filler.len;
            result[i] = filler[foff];
        }
    }
    return PrimitiveValue{ .chars = result };
}

fn builtinStr(allocator: Allocator, refMap: []const RefMap, line: [][]const u8, fun: AstFun) !PrimitiveValue {
    var strBuf = std.ArrayList(u8).init(allocator);
    for (fun.args) |a| {
        try strBuf.appendSlice(try resolveCharsValue(allocator, refMap, line, a));
    }
    return PrimitiveValue{ .chars = strBuf.items };
}

//Comparisons
fn primBool(b: bool) PrimitiveValue {
    return PrimitiveValue{ .bool = b };
}

fn builtinEq(allocator: Allocator, refMap: []const RefMap, line: [][]const u8, fun: AstFun) !PrimitiveValue {
    try assertArgsEq(fun.name, 2, fun.args.len);
    if (debug) {
        std.debug.print("builtinEq \n", .{});
    }

    var arg1 = try resolvePrimitiveValue(allocator, refMap, line, fun.args[0]);
    var arg2 = try resolvePrimitiveValue(allocator, refMap, line, fun.args[1]);

    if (@as(PrimitiveValueType, arg1) == @as(PrimitiveValueType, arg2)) {
        return switch (arg1) {
            .chars => primBool(std.mem.eql(u8, arg1.chars, arg2.chars)),
            .int => primBool(arg1.int == arg2.int),
            .bool => primBool(arg1.bool == arg2.bool),
        };
    } else {
        //convert both to str and compare
        return primBool(std.mem.eql(u8, try arg1.toChars(allocator), try arg2.toChars(allocator)));
    }
}

fn builtinStartsWith(allocator: Allocator, refMap: []const RefMap, line: [][]const u8, fun: AstFun) !PrimitiveValue {
    try assertArgsEq(fun.name, 2, fun.args.len);
    const arg1 = try resolveCharsValue(allocator, refMap, line, fun.args[0]);
    const arg2 = try resolveCharsValue(allocator, refMap, line, fun.args[1]);
    const ret = std.mem.startsWith(u8, arg1, arg2);
    if (debug) {
        std.debug.print("startsWith {s} {s} {any}\n", .{ arg1, arg2, ret });
    }
    return PrimitiveValue{ .bool = ret };
}

fn builtinEndsWith(allocator: Allocator, refMap: []const RefMap, line: [][]const u8, fun: AstFun) !PrimitiveValue {
    try assertArgsEq(fun.name, 2, fun.args.len);
    const arg1 = try resolveCharsValue(allocator, refMap, line, fun.args[0]);
    const arg2 = try resolveCharsValue(allocator, refMap, line, fun.args[1]);
    return PrimitiveValue{ .bool = std.mem.endsWith(u8, arg1, arg2) };
}

fn builtinContains(allocator: Allocator, refMap: []const RefMap, line: [][]const u8, fun: AstFun) !PrimitiveValue {
    try assertArgsEq(fun.name, 2, fun.args.len);
    const arg1 = try resolveCharsValue(allocator, refMap, line, fun.args[0]);
    const arg2 = try resolveCharsValue(allocator, refMap, line, fun.args[1]);
    return PrimitiveValue{ .bool = std.mem.indexOf(u8, arg1, arg2) != null };
}

fn builtinGt(allocator: Allocator, refMap: []const RefMap, line: [][]const u8, fun: AstFun) !PrimitiveValue {
    try assertArgsEq(fun.name, 2, fun.args.len);
    var arg1 = try resolvePrimitiveValue(allocator, refMap, line, fun.args[0]);
    var arg2 = try resolvePrimitiveValue(allocator, refMap, line, fun.args[1]);

    if ((arg1 == PrimitiveValueType.int) or (arg2 == PrimitiveValueType.int)) {
        const int1 = arg1.toInt() catch null;
        const int2 = arg2.toInt() catch null;
        if (int1) |in1| {
            if (int2) |in2| {
                return PrimitiveValue{ .bool = in1 > in2 };
            }
        }
    }
    const char1 = try arg1.toChars(allocator);
    const char2 = try arg2.toChars(allocator);
    const cmp = std.mem.order(u8, char1, char2);
    return PrimitiveValue{ .bool = cmp == std.math.Order.gt };
}

fn builtinLt(allocator: Allocator, refMap: []const RefMap, line: [][]const u8, fun: AstFun) !PrimitiveValue {
    try assertArgsEq(fun.name, 2, fun.args.len);
    var arg1 = try resolvePrimitiveValue(allocator, refMap, line, fun.args[0]);
    var arg2 = try resolvePrimitiveValue(allocator, refMap, line, fun.args[1]);

    if ((arg1 == PrimitiveValueType.int) or (arg2 == PrimitiveValueType.int)) {
        const int1 = arg1.toInt() catch null;
        const int2 = arg2.toInt() catch null;
        if (int1) |in1| {
            if (int2) |in2| {
                return PrimitiveValue{ .bool = in1 < in2 };
            }
        }
    }
    const char1 = try arg1.toChars(allocator);
    const char2 = try arg2.toChars(allocator);
    const cmp = std.mem.order(u8, char1, char2);
    return PrimitiveValue{ .bool = cmp == std.math.Order.lt };
}

fn builtinIf(allocator: Allocator, refMap: []const RefMap, line: [][]const u8, fun: AstFun) !PrimitiveValue {
    try assertArgsEq(fun.name, 3, fun.args.len);
    var arg1 = try resolvePrimitiveValue(allocator, refMap, line, fun.args[0]);

    if (debug) {
        std.debug.print("builtinIf {any} \n", .{arg1.toBool()});
    }

    if (arg1.toBool()) {
        return try resolvePrimitiveValue(allocator, refMap, line, fun.args[1]);
    } else {
        return resolvePrimitiveValue(allocator, refMap, line, fun.args[2]);
    }
}

fn builtinNot(allocator: Allocator, refMap: []const RefMap, line: [][]const u8, fun: AstFun) !PrimitiveValue {
    try assertArgsEq(fun.name, 1, fun.args.len);
    var arg1 = try resolvePrimitiveValue(allocator, refMap, line, fun.args[0]);

    return PrimitiveValue{ .bool = !arg1.toBool() };
}

fn builtinAnd(allocator: Allocator, refMap: []const RefMap, line: [][]const u8, fun: AstFun) !PrimitiveValue {
    for (fun.args) |arg| {
        var v = try resolvePrimitiveValue(allocator, refMap, line, arg);
        if (!v.toBool()) {
            return PrimitiveValue{ .bool = false };
        }
    }
    return PrimitiveValue{ .bool = true };
}

fn builtinOr(allocator: Allocator, refMap: []const RefMap, line: [][]const u8, fun: AstFun) !PrimitiveValue {
    for (fun.args) |arg| {
        var v = try resolvePrimitiveValue(allocator, refMap, line, arg);
        if (v.toBool()) {
            return PrimitiveValue{ .bool = true };
        }
    }
    return PrimitiveValue{ .bool = false };
}
