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

pub const StreamStepType = enum { collect, systemOut, exec };
pub const StreamStep = union(StreamStepType) {
    collect: CollectStep,
    systemOut: SystemOutStep,
    exec: ExecStep,

    pub fn accept(self: StreamStep, line: [][]const u8) !void {
        switch (self) {
            .collect => try self.collect.accept(line),
            .systemOut => try self.systemOut.accept(line),
            .exec => try self.exec.accept(line),
        }
    }
};

pub const FilterStep = struct {
    next: StreamStep,
    predicates: []const AstNode,
};

pub const SystemOutStep = struct {
    writer: std.io.File,

    pub fn accept(self: SystemOutStep, line: [][]const u8) !void {
        for (line, 0..) |o, i| {
            if (i != 0) try self.writer.writer().writeAll(" ");

            try self.writer.writer().writeAll(o);
        }
        try self.writer.writer().writeAll("\n");
    }
};
pub const ExecStep = struct {
    allocator: Allocator,
    cmd: []const u8,

    pub fn accept(self: ExecStep, line: [][]const u8) !void {
        var cmdLine = ArrayList([]const u8).init(self.allocator);
        try cmdLine.append(self.cmd);
        try cmdLine.appendSlice(line);
        var cp = std.ChildProcess.init(cmdLine.items, self.allocator);
        _ = cp.spawnAndWait() catch {
            std.debug.print("Failed to execute '{s}'\n", .{self.cmd});
            std.os.exit(1);
        };
    }
};

pub const CollectStep = struct {
    items: ArrayList([][]const u8),

    pub fn accept(self: CollectStep, line: [][]const u8) !void {
        try self.items.append(line);
    }
};

pub const Program = struct {
    input: InputParser,
    refMap: []const RefMap,
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

const BuiltinFn = *const fn (Allocator, Program, [][]const u8, AstFun) DestructError!PrimitiveValue;
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

pub fn resolveCharsValue(allocator: Allocator, program: Program, line: [][]const u8, node: AstNode) ![]const u8 {
    var ret = try resolvePrimitiveValue(allocator, program, line, node);
    return ret.toChars(allocator);
}

pub fn resolvePrimitiveValue(allocator: Allocator, program: Program, line: [][]const u8, node: AstNode) !PrimitiveValue {
    return switch (node) {
        .chars => PrimitiveValue{ .chars = node.chars },
        .ref => PrimitiveValue{ .chars = try resolveRef(program.refMap, line, node.ref) },
        .fun => node.fun.impl(allocator, program, line, node.fun),
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
            return line[@intCast(no)];
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

fn builtinUpper(allocator: Allocator, program: Program, line: [][]const u8, fun: AstFun) !PrimitiveValue {
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

fn builtinFirst(allocator: Allocator, program: Program, line: [][]const u8, fun: AstFun) !PrimitiveValue {
    var arg1 = fun.args[0];
    var asInt = @as(usize, @intCast(try (try resolvePrimitiveValue(allocator, program, line, fun.args[1])).toInt()));

    var refStr = try resolveCharsValue(allocator, program, line, arg1);
    var result = refStr[0..(asInt)];
    return PrimitiveValue{ .chars = result };
}

fn builtinRPad(allocator: Allocator, program: Program, line: [][]const u8, fun: AstFun) !PrimitiveValue {
    var arg1 = fun.args[0];
    var asInt = @as(usize, @intCast(try (try resolvePrimitiveValue(allocator, program, line, fun.args[1])).toInt()));

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

fn builtinStr(allocator: Allocator, program: Program, line: [][]const u8, fun: AstFun) !PrimitiveValue {
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

fn builtinEq(allocator: Allocator, program: Program, line: [][]const u8, fun: AstFun) !PrimitiveValue {
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

fn builtinStartsWith(allocator: Allocator, program: Program, line: [][]const u8, fun: AstFun) !PrimitiveValue {
    var arg1 = try resolveCharsValue(allocator, program, line, fun.args[0]);
    var arg2 = try resolveCharsValue(allocator, program, line, fun.args[1]);
    return PrimitiveValue{ .bool = std.mem.startsWith(u8, arg1, arg2) };
}

fn builtinEndsWith(allocator: Allocator, program: Program, line: [][]const u8, fun: AstFun) !PrimitiveValue {
    var arg1 = try resolveCharsValue(allocator, program, line, fun.args[0]);
    var arg2 = try resolveCharsValue(allocator, program, line, fun.args[1]);
    return PrimitiveValue{ .bool = std.mem.endsWith(u8, arg1, arg2) };
}

fn builtinIf(allocator: Allocator, program: Program, line: [][]const u8, fun: AstFun) !PrimitiveValue {
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
