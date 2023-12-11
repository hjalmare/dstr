const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

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
    undefined,
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

    pub fn print(self: AstNode, prefix: *ArrayList(u8)) !void {
        switch (self) {
            .ref => std.debug.print("{s}(ref {s})", .{ prefix.items, self.ref }),
            .chars => std.debug.print("{s}(chars '{s}')", .{ prefix.items, self.chars }),
            .int => std.debug.print("{s}(int {any})", .{ prefix.items, self.int }),
            .fun => try self.fun.print(prefix),
        }
    }
};

pub const BuiltinFn = *const fn (Allocator, []const RefMap, [][]const u8, AstFun) DestructError!PrimitiveValue;

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

    pub fn print(self: AstFun, prefix: *ArrayList(u8)) DestructError!void {
        std.debug.print("{s}(fun {s}\n", .{ prefix.items, self.name });
        try prefix.append('\t');
        for (self.args) |arg| {
            try arg.print(prefix);
            std.debug.print("\n", .{});
        }
        _ = prefix.pop();
        std.debug.print("{s})", .{prefix.items});
    }
};

pub const SegmentType = enum { chars, ref };
pub const SegmentNode = union(SegmentType) {
    chars: []const u8,
    ref: []const u8,
};

pub const InputParserType = enum { positional, segments };
pub const InputParser = union(InputParserType) {
    positional: [][]const u8,
    segments: []const SegmentNode,
};

pub const RefMap = struct {
    name: []const u8,
    offset: i32,
};
// Executor enginge, recursively resolve values
// ====================================================================================

pub fn resolveCharsValue(allocator: Allocator, refMap: []const RefMap, line: [][]const u8, node: AstNode) ![]const u8 {
    var ret = try resolvePrimitiveValue(allocator, refMap, line, node);
    return ret.toChars(allocator);
}

pub fn resolvePrimitiveValue(allocator: Allocator, refMap: []const RefMap, line: [][]const u8, node: AstNode) !PrimitiveValue {
    return switch (node) {
        .chars => PrimitiveValue{ .chars = node.chars },
        .ref => PrimitiveValue{ .chars = try resolveRef(refMap, line, node.ref) },
        .fun => node.fun.impl(allocator, refMap, line, node.fun),
        .int => PrimitiveValue{ .int = node.int },
    };
}

fn resolveRef(refMap: []const RefMap, line: [][]const u8, ref: []const u8) ![]const u8 {
    var offset: ?i32 = null;

    for (refMap) |r| {
        if (std.mem.eql(u8, ref, r.name)) {
            offset = r.offset;
            break;
        }
    }

    if (offset) |o| {
        if (o < 0) {
            const no: i32 = @as(i32, @intCast(line.len)) + o;
            return if (no >= 0) line[@intCast(no)] else DestructError.missing_input;
        } else if (o >= line.len) {
            return DestructError.missing_input;
        } else {
            return line[@intCast(o)];
        }
    } else {
        //We didnt find the ref
        std.debug.print("Unknown ref: {s}\n", .{ref});
        return DestructError.unknown_ref;
    }
}
