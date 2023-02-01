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
};

pub const StringFragmentType = enum { chars, ref };
pub const AstStringFragment = struct { type: StringFragmentType, chars: []const u8 };

pub const AstNodeType = enum { string, ref, fun };
pub const AstNode = union(AstNodeType) {
    ref: []const u8,
    string: ArrayList(AstStringFragment),
    fun: AstFun,
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
