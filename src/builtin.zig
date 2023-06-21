const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

const debug = false;

pub const DestructError = error{
    anon_ref,
    unknown_ref,
    unknown_function,
    coercion_failed,
    missing_input,
    space_in_interpolation,
    ref_non_alpha,
    exec_arg_error,
    invocation_error,
    unexpected_char,
    OutOfMemory,
    InvalidCharacter,
    Overflow,
};
pub const PrimitiveValueType = enum { chars, int, bool };
pub const PrimitiveValue = union(PrimitiveValueType) {
    chars: []const u8,
    int: i64,
    bool: bool,

    pub fn toInt(self: PrimitiveValue) !i64 {
        return switch (self) {
            .chars => try std.fmt.parseInt(i64, self.chars, 10),
            .int => self.int,
            .bool => DestructError.coercion_failed,
        };
    }

    pub fn toChars(self: PrimitiveValue, allocator: Allocator) ![]const u8 {
        return switch (self) {
            .chars => self.chars,
            .int => try std.fmt.allocPrint(allocator, "{d}", .{self.int}),
            .bool => if (self.bool) "true" else "false",
        };
    }
    pub fn toBool(self: PrimitiveValue) bool {
        return switch (self) {
            .chars => self.chars.len > 0,
            .int => self.int > 0,
            .bool => self.bool,
        };
    }
};

pub const AstNodeType = enum { ref, fun, chars, int };
pub const AstNode = union(AstNodeType) {
    ref: []const u8,
    fun: AstFun,
    chars: []const u8,
    int: i64,
};

pub const FunType = enum {};
pub const AstFun = struct {
    name: []const u8,
    args: []const AstNode,
    impl: BuiltinFn,

    pub fn assertArgsSize(self: AstFun, expected: usize) !void {
        if (self.args.len != expected) {
            std.debug.print("Failed to execute '{s}' expected {i} arguments but got {i}", .{ self.name, expected, self.args.len });
            return DestructError.invocation_error;
        }
    }
};

pub const Program = struct {
    input: InputParser,
    ex: ArrayList(AstNode), //Todo: rename to ast?
};

pub const RefMap = struct {
    name: []const u8,
    offset: i32,
};

pub const InputParserType = enum { positional, segments };
pub const InputParser = union(InputParserType) {
    positional: [][]const u8,
    segments: []const SegmentNode,
};

pub const SegmentType = enum { chars, ref };
pub const SegmentNode = union(SegmentType) {
    chars: []const u8,
    ref: []const u8,
};

const BuiltinFn = *const fn (Allocator, Program, ArrayList([]const u8), AstFun) DestructError!PrimitiveValue;
const BuiltinValidator = *const fn (AstFun, bool) DestructError!void;
pub const Builtin = struct {
    name: []const u8,
    impl: BuiltinFn,
};

const builtins = [_]Builtin{
    Builtin{ .name = "upper", .impl = builtinUpper },
    Builtin{ .name = "first", .impl = builtinFirst },
    Builtin{ .name = "rpad", .impl = builtinRPad },
    Builtin{ .name = "str", .impl = builtinStr },
    Builtin{ .name = "eq", .impl = builtinEq },
    Builtin{ .name = "startsWith", .impl = builtinStartsWith },
    Builtin{ .name = "endsWith", .impl = builtinEndsWith },
    Builtin{ .name = "if", .impl = builtinIf },
};

// Executor enginge, recursively resolve values
// ====================================================================================

pub fn resolveCharsValue(allocator: Allocator, program: Program, line: ArrayList([]const u8), node: AstNode) ![]const u8 {
    var ret = try resolvePrimitiveValue(allocator, program, line, node);
    return ret.toChars(allocator);
}

pub fn resolvePrimitiveValue(allocator: Allocator, program: Program, line: ArrayList([]const u8), node: AstNode) !PrimitiveValue {
    return switch (node) {
        .chars => PrimitiveValue{ .chars = node.chars },
        .ref => PrimitiveValue{ .chars = try resolveRef(program.input.positional, line, node.ref) },
        .fun => node.fun.impl(allocator, program, line, node.fun),
        .int => PrimitiveValue{ .int = node.int },
    };
}

fn resolveRef(symbols: [][]const u8, line: ArrayList([]const u8), ref: []const u8) ![]const u8 {
    var offset: i64 = 0;

    const isUnderScore = std.mem.eql(u8, ref, "_");
    if (isUnderScore) {
        //Fail when trying to resolve '_' ref
        std.debug.print("References to _ is not permitted.\n", .{});
        return DestructError.anon_ref;
    }

    for (symbols, 0..) |sym, si| {
        const isSame = std.mem.eql(u8, sym, ref);
        const dotDotDot = std.mem.eql(u8, sym, "...");
        if (debug) std.debug.print("\tResolving ref Sym: '{s}' Ref: '{s}' IsSame: '{any}'\n", .{ sym, ref, isSame });
        if (dotDotDot) {
            const symLeft = @intCast(i64, symbols.len) - @intCast(i64, si) - 1;
            offset = @intCast(i64, line.items.len) - symLeft - 1 - @intCast(i64, si);
        } else if (isSame) {
            const finalOffset = @intCast(i64, si) + offset;
            if ((finalOffset >= line.items.len) or (finalOffset < 0)) {
                std.debug.print("Input is to short.\n", .{});
                return DestructError.missing_input;
            }
            return line.items[@intCast(usize, finalOffset)];
        }
    }
    std.debug.print("\nFailed to resolve ref \"{s}\"\n", .{ref});
    return DestructError.unknown_ref;
}

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

fn builtinUpper(allocator: Allocator, program: Program, line: ArrayList([]const u8), fun: AstFun) !PrimitiveValue {
    if (fun.args.len != 1) {
        std.debug.print(
            "Failed to execute 'upper', expects 0 arguments but got {d}\n",
            .{fun.args.len - 1},
        );
        return DestructError.exec_arg_error;
    }
    var arg1 = try resolveCharsValue(allocator, program, line, fun.args[0]);

    var refBuf = try allocator.alloc(u8, arg1.len);
    _ = std.ascii.upperString(refBuf, arg1);
    return PrimitiveValue{ .chars = refBuf };
}

fn builtinFirst(allocator: Allocator, program: Program, line: ArrayList([]const u8), fun: AstFun) !PrimitiveValue {
    var arg1 = fun.args[0];
    var asInt = @intCast(usize, try (try resolvePrimitiveValue(allocator, program, line, fun.args[1])).toInt());

    var refStr = try resolveCharsValue(allocator, program, line, arg1);
    var result = refStr[0..(asInt)];
    return PrimitiveValue{ .chars = result };
}

fn builtinRPad(allocator: Allocator, program: Program, line: ArrayList([]const u8), fun: AstFun) !PrimitiveValue {
    var arg1 = fun.args[0];
    var asInt = @intCast(usize, try (try resolvePrimitiveValue(allocator, program, line, fun.args[1])).toInt());

    var refStr = try resolveCharsValue(allocator, program, line, arg1);
    var result = try allocator.alloc(u8, asInt);
    var filler = if (fun.args.len == 3) try resolveCharsValue(allocator, program, line, fun.args[2]) else " ";

    for (0..asInt) |i| {
        if (i < refStr.len) {
            result[i] = refStr[i];
        } else {
            var foff = (i - refStr.len) % filler.len;
            result[i] = filler[foff];
        }
    }
    return PrimitiveValue{ .chars = result };
}

fn builtinStr(allocator: Allocator, program: Program, line: ArrayList([]const u8), fun: AstFun) !PrimitiveValue {
    var strBuf = std.ArrayList(u8).init(allocator);
    for (fun.args) |arg| {
        try strBuf.appendSlice(try resolveCharsValue(allocator, program, line, arg));
    }
    return PrimitiveValue{ .chars = strBuf.items };
}

//Comparisons
fn primBool(b: bool) PrimitiveValue {
    return PrimitiveValue{ .bool = b };
}

fn builtinEq(allocator: Allocator, program: Program, line: ArrayList([]const u8), fun: AstFun) !PrimitiveValue {
    if (debug) {
        std.debug.print("builtinEq \n", .{});
    }

    var arg1 = try resolvePrimitiveValue(allocator, program, line, fun.args[0]);
    var arg2 = try resolvePrimitiveValue(allocator, program, line, fun.args[1]);

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

fn builtinStartsWith(allocator: Allocator, program: Program, line: ArrayList([]const u8), fun: AstFun) !PrimitiveValue {
    var arg1 = try resolveCharsValue(allocator, program, line, fun.args[0]);
    var arg2 = try resolveCharsValue(allocator, program, line, fun.args[1]);
    return PrimitiveValue{ .bool = std.mem.startsWith(u8, arg1, arg2) };
}

fn builtinEndsWith(allocator: Allocator, program: Program, line: ArrayList([]const u8), fun: AstFun) !PrimitiveValue {
    var arg1 = try resolveCharsValue(allocator, program, line, fun.args[0]);
    var arg2 = try resolveCharsValue(allocator, program, line, fun.args[1]);
    return PrimitiveValue{ .bool = std.mem.endsWith(u8, arg1, arg2) };
}

fn builtinIf(allocator: Allocator, program: Program, line: ArrayList([]const u8), fun: AstFun) !PrimitiveValue {
    if (debug) {
        std.debug.print("builtinIf \n", .{});
    }
    var arg1 = try resolvePrimitiveValue(allocator, program, line, fun.args[0]);

    if (arg1.toBool()) {
        return try resolvePrimitiveValue(allocator, program, line, fun.args[1]);
    } else {
        return resolvePrimitiveValue(allocator, program, line, fun.args[2]);
    }
}
