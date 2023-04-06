const std = @import("std");
const ArrayList = std.ArrayList;

pub const DestructError = error{
    anon_ref,
    unknown_ref,
    unknown_function,
    missing_input,
    space_in_interpolation,
    ref_non_alpha,
    exec_arg_error,
    unexpected_char,
};

pub const AstNodeType = enum { ref, fun, chars };
pub const AstNode = union(AstNodeType) {
    ref: []const u8,
    fun: AstFun,
    chars: []const u8,
};

pub const AstFun = struct {
    name: []const u8,
    args: ArrayList(AstNode),
};

pub const Program = struct {
    symbols: ArrayList([]const u8),
    ex: ArrayList(AstNode),
};

pub const Builtin = struct {
    name: []const u8,
    produces: AstNodeType,
    args: []const AstNodeType,
    impl: fn (AstFun) []const u8,
};
