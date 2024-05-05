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

const BuiltinValidator = *const fn (AstFun, bool) DestructError!void;
pub const Builtin = struct {
    name: []const u8,
    impl: BuiltinFn,
};

const builtins = [_]Builtin{
    Builtin{ .name = "cmd", .impl = builtinCmd },
    Builtin{ .name = "pipe", .impl = builtinPipeCmd },
    Builtin{ .name = "upper", .impl = builtinUpper },
    Builtin{ .name = "lower", .impl = builtinLower },
    Builtin{ .name = "first", .impl = builtinFirst },
    Builtin{ .name = "rpad", .impl = builtinRPad },
    Builtin{ .name = "lpad", .impl = builtinLPad },
    Builtin{ .name = "replace", .impl = builtinReplace },
    Builtin{ .name = "trim", .impl = builtinTrim },
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

fn builtinLower(allocator: Allocator, refMap: []const RefMap, line: [][]const u8, fun: AstFun) !PrimitiveValue {
    try assertArgsEq(fun.name, 1, fun.args.len);
    const arg1 = try resolveCharsValue(allocator, refMap, line, fun.args[0]);

    const refBuf = try allocator.alloc(u8, arg1.len);
    _ = std.ascii.lowerString(refBuf, arg1);
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

fn builtinReplace(allocator: Allocator, refMap: []const RefMap, line: [][]const u8, fun: AstFun) !PrimitiveValue {
    if ((fun.args.len % 2) != 1) {
        std.debug.print(
            "Failed to execute '{s}', expects a odd number of arguments arguments but got {d}\n",
            .{ fun.name, fun.args.len },
        );
        return DestructError.exec_arg_error;
    }

    var ret = try resolveCharsValue(allocator, refMap, line, fun.args[0]);

    for (0..((fun.args.len - 1) / 2)) |i| {
        const start = i * 2 + 1;
        const needle = try resolveCharsValue(allocator, refMap, line, fun.args[start]);
        const replacement = try resolveCharsValue(allocator, refMap, line, fun.args[start + 1]);

        ret = try std.mem.replaceOwned(u8, allocator, ret, needle, replacement);
    }

    return PrimitiveValue{ .chars = ret };
}

fn builtinTrim(allocator: Allocator, refMap: []const RefMap, line: [][]const u8, fun: AstFun) !PrimitiveValue {
    if ((fun.args.len != 1) and (fun.args.len != 2)) {
        std.debug.print(
            "Failed to execute '{s}', expects 2 or 3 arguments but got {d}\n",
            .{ fun.name, fun.args.len },
        );
        return DestructError.exec_arg_error;
    }

    const v = try resolveCharsValue(allocator, refMap, line, fun.args[0]);
    const trimChars = if (fun.args.len == 2) try resolveCharsValue(allocator, refMap, line, fun.args[1]) else " \t\n";

    const trimmed = std.mem.trim(u8, v, trimChars);

    return PrimitiveValue{ .chars = trimmed };
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

fn builtinCmd(allocator: Allocator, refMap: []const RefMap, line: [][]const u8, fun: AstFun) !PrimitiveValue {
    if (fun.args.len == 0) {
        std.debug.print(
            "Failed to execute '{s}', expects atleast 1 arguments but got {d}\n",
            .{ fun.name, fun.args.len },
        );
        return DestructError.exec_arg_error;
    }

    var argbuff = std.ArrayList([]const u8).init(allocator);

    for (fun.args) |a| {
        try argbuff.append(try resolveCharsValue(allocator, refMap, line, a));
    }

    const cp = std.ChildProcess.run(.{ .argv = argbuff.items, .allocator = allocator }) catch {
        std.debug.print("Failed to execute '{s}'\n", .{argbuff.items[0]});

        return DestructError.invocation_error;
    };

    var outStr: []u8 = undefined;
    const out = cp.stdout;
    if ((out.len > 0) and (std.ascii.isWhitespace(out[out.len - 1]))) {
        outStr = out[0 .. out.len - 1];
    } else {
        outStr = out;
    }
    return PrimitiveValue{ .chars = outStr };
}

fn builtinPipeCmd(allocator: Allocator, refMap: []const RefMap, line: [][]const u8, fun: AstFun) !PrimitiveValue {
    if (fun.args.len <= 1) {
        std.debug.print(
            "Failed to execute '{s}', expects atleast 2 arguments but got {d}\n",
            .{ fun.name, fun.args.len },
        );
        return DestructError.exec_arg_error;
    }

    const cmd = try resolveCharsValue(allocator, refMap, line, fun.args[1]);
    const data = try resolveCharsValue(allocator, refMap, line, fun.args[0]);

    var argbuff = std.ArrayList([]const u8).init(allocator);

    try argbuff.append(cmd);
    for (fun.args[2..]) |a| {
        try argbuff.append(try resolveCharsValue(allocator, refMap, line, a));
    }

    var process = std.ChildProcess.init(argbuff.items, allocator);
    process.stdin_behavior = .Pipe;
    process.stdout_behavior = .Pipe;
    process.stderr_behavior = .Pipe;
    process.spawn() catch {
        return DestructError.invocation_error;
    };

    process.stdin.?.writeAll(data) catch {
        return DestructError.invocation_error;
    };

    process.stdin.?.close();
    process.stdin = null;

    var out = std.ArrayList(u8).init(allocator);
    var err = std.ArrayList(u8).init(allocator);
    process.collectOutput(&out, &err, std.math.maxInt(usize)) catch {
        return DestructError.invocation_error;
    };

    _ = process.wait() catch {
        std.debug.print("Failed to execute '{s}'\n", .{argbuff.items[0]});

        return DestructError.invocation_error;
    };

    var outStr: []u8 = undefined;
    if ((out.items.len > 0) and (std.ascii.isWhitespace(out.items[out.items.len - 1]))) {
        outStr = out.items[0 .. out.items.len - 1];
    } else {
        outStr = out.items;
    }
    return PrimitiveValue{ .chars = outStr };
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
