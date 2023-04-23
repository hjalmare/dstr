const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

pub const DestructError = error{
    anon_ref,
    unknown_ref,
    unknown_function,
    missing_input,
    space_in_interpolation,
    ref_non_alpha,
    exec_arg_error,
    unexpected_char,
    OutOfMemory,
    InvalidCharacter,
    Overflow,
};
pub const PrimitiveValueType = enum { chars, int };
pub const PrimitiveValue = union(PrimitiveValueType) {
    chars: []const u8,
    int: i64,

    pub fn toInt(self: PrimitiveValue) !i64 {
        return switch (self) {
            .chars => try std.fmt.parseInt(i64, self.chars, 10),
            .int => self.int,
        };
    }

    pub fn toChars(self: PrimitiveValue, allocator: Allocator) ![]const u8 {
        return switch (self) {
            .chars => self.chars,
            .int => try std.fmt.allocPrint(allocator, "{d}", .{self.int}),
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
};

pub const Program = struct {
    symbols: ArrayList([]const u8),
    ex: ArrayList(AstNode), //Todo: rename to ast?
};

pub const Builtin = struct {
    name: []const u8,
    produces: AstNodeType,
    args: []const AstNodeType,
    impl: fn (AstFun) []const u8,
};

const debug = false;
const BuiltinFn = *const fn (Allocator, Program, ArrayList([]const u8), AstFun) DestructError!PrimitiveValue;

pub fn resolveCharsValue(allocator: Allocator, program: Program, line: ArrayList([]const u8), node: AstNode) ![]const u8 {
    var ret = try resolvePrimitiveValue(allocator, program, line, node);
    return ret.toChars(allocator);
}

pub fn resolvePrimitiveValue(allocator: Allocator, program: Program, line: ArrayList([]const u8), node: AstNode) !PrimitiveValue {
    return switch (node) {
        .chars => PrimitiveValue{ .chars = node.chars },
        .ref => PrimitiveValue{ .chars = try resolveRef(program.symbols, line, node.ref) },
        .fun => node.fun.impl(allocator, program, line, node.fun),
        .int => PrimitiveValue{ .int = node.int },
    };
}

fn resolveRef(symbols: ArrayList([]const u8), line: ArrayList([]const u8), ref: []const u8) ![]const u8 {
    var offset: i64 = 0;

    const isUnderScore = std.mem.eql(u8, ref, "_");
    if (isUnderScore) {
        //Fail when trying to resolve '_' ref
        std.debug.print("References to _ is not permitted.\n", .{});
        return DestructError.anon_ref;
    }

    for (symbols.items) |sym, si| {
        const isSame = std.mem.eql(u8, sym, ref);
        const dotDotDot = std.mem.eql(u8, sym, "...");
        if (debug) std.debug.print("\tResolving ref Sym: '{s}' Ref: '{s}' IsSame: '{any}'\n", .{ sym, ref, isSame });
        if (dotDotDot) {
            const symLeft = @intCast(i64, symbols.items.len) - @intCast(i64, si) - 1;
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
    if (std.mem.eql(u8, "upper", name)) {
        return builtinUpper;
    } else if (std.mem.eql(u8, "first", name)) {
        return builtinFirst;
    } else if (std.mem.eql(u8, "str", name)) {
        return builtinStr;
    }

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
    var result = refStr[0..asInt];
    return PrimitiveValue{ .chars = result };
}

fn builtinStr(allocator: Allocator, program: Program, line: ArrayList([]const u8), fun: AstFun) !PrimitiveValue {
    var strBuf = std.ArrayList(u8).init(allocator);
    for (fun.args) |arg| {
        try strBuf.appendSlice(try resolveCharsValue(allocator, program, line, arg));
    }
    return PrimitiveValue{ .chars = strBuf.items };
}
