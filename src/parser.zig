const std = @import("std");
const expect = @import("std").testing.expect;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const ascii = std.ascii;
const isWhitespace = std.ascii.isWhitespace;

//Set to true for debug output
const debug = false;
const debugReader = false;

pub const DestructError = error{
    anon_ref,
    unknown_ref,
    unknown_function,
    missing_input,
    space_in_interpolation,
    ref_non_alpha,
    exec_arg_error,
};

const Mode = enum { START, ARG_LIST, ARG_NAME, EX_LIST, EX_NAME, EX_SQT_STR, EX_SQT_REF, EX_SQT_ESC };

const AstNodeType = enum { string, ref, fun };

pub const StringFragmentType = enum { chars, ref };

const ExName = struct { name: []const u8, type: AstNodeType };

pub const AstNode = union(AstNodeType) { ref: []const u8, string: ArrayList(AstStringFragment), fun: AstFun };

const AstStringFragment = struct { type: StringFragmentType, chars: []const u8 };

pub const AstFun = struct { name: []const u8, args: ArrayList(AstNode) };

pub const Program = struct { symbols: ArrayList([]const u8), ex: ArrayList(AstNode) };

const StringReader = struct {
    src: []const u8,
    offset: usize = 0,
    selectStart: usize = 0,

    pub fn init(s: []const u8) StringReader {
        return StringReader{
            .src = s,
            .offset = 0,
            .selectStart = 0,
        };
    }

    pub fn next(self: *StringReader) ?u8 {
        return if (self.offset < self.src.len) {
            var ret = self.src[self.offset];
            self.offset = self.offset + 1;
            if (debugReader) {
                std.debug.print("\t\tReader.next offset: {d} selectStart:{d} char:'{c}'\n", .{ self.offset, self.selectStart, ret });
            }
            return ret;
        } else null;
    }

    pub fn peek(self: StringReader) u8 {
        if (debugReader) {
            var ret = self.src[self.offset - 1];
            std.debug.print("\t\tReader.peek offset: {d} selectStart:{d} char:'{c}'\n", .{ self.offset, self.selectStart, ret });
        }
        return self.src[self.offset - 1];
    }

    pub fn select(self: *StringReader) void {
        self.selectStart = self.offset - 1;
        if (debugReader) {
            var ret = self.src[self.offset - 1];
            std.debug.print("\t\tReader.select offset: {d} selectStart:{d} char:'{c}'\n", .{ self.offset, self.selectStart, ret });
        }
    }

    //Exclusive selection
    //Returns selection from the last select() until the previously
    //read char
    pub fn selection(self: StringReader) []const u8 {
        var off = if (self.offset >= self.src.len) self.src.len - 1 else self.offset - 1;
        if (debugReader) {
            var ret = self.src[off];
            std.debug.print("\t\tReader.selection offset: {d} selectStart:{d} char:'{c}'\n", .{ self.offset, self.selectStart, ret });
        }

        return self.src[self.selectStart..off];
    }

    pub fn selectionInc(self: StringReader) []const u8 {
        var off = if (self.offset >= self.src.len) self.src.len - 1 else self.offset;
        if (debugReader) {
            var ret = self.src[off];
            std.debug.print("\t\tReader.selectionInc offset: {d} selectStart:{d} char:'{c}'\n", .{ self.offset, self.selectStart, ret });
        }
        return self.src[self.selectStart..(off + 1)];
    }

    pub fn rewind(self: *StringReader) void {
        self.offset = self.offset - 1;
        if (debugReader) {
            var ret = self.src[self.offset];
            std.debug.print("\t\tReader.rewind offset: {d} selectStart:{d} char:'{c}'\n", .{ self.offset, self.selectStart, ret });
        }
    }
};

fn readRefFuncArgs(allocator: Allocator, it: *StringReader, arglist: *ArrayList(AstNode)) std.mem.Allocator.Error!void {
    if (debug) {
        std.debug.print("Enter redRefFuncArgs\n", .{});
    }

    while (it.next()) |c| {
        if (c == ')') {
            break;
        } else {
            var r = try readRefExpression(allocator, it);
            try arglist.append(r);
            if (it.peek() == ')') {
                break;
            }
        }
    }
}

fn readRefFunc(allocator: Allocator, it: *StringReader, parent: AstNode) !AstNode {
    if (debug) {
        std.debug.print("Enter readRefFunc\n", .{});
    }

    _ = it.next(); // skip leading .
    it.select();

    var args = ArrayList(AstNode).init(allocator);
    try args.append(parent);

    while (it.next()) |c| {
        if (c == '(') {
            //parse arglist
            var name = it.selection();
            try readRefFuncArgs(allocator, it, &args);
            if (debug) {
                std.debug.print("\tAdding AstFun: '{s}'\n", .{name});
            }
            //it.rewind();
            _ = it.next();
            return AstNode{ .fun = AstFun{ .name = name, .args = args } };
        } else if (c == '}') {
            break;
        }
    }
    if (debug) {
        std.debug.print("\tAdding AstFun Late: '{s}'\n", .{it.selection()});
    }
    return AstNode{ .fun = AstFun{ .name = it.selection(), .args = args } };
}

fn readRefExpression(allocator: Allocator, it: *StringReader) std.mem.Allocator.Error!AstNode {
    if (debug) {
        std.debug.print("\tEnter readRefExpression\n", .{});
    }
    it.select();

    while (it.next()) |c| {
        if (c == '.') {
            var ret = try readRefFunc(allocator, it, AstNode{ .ref = it.selection() });
            std.debug.print("\tCompleted###\n", .{});
            if (it.peek() == '.') {
                return readRefFunc(allocator, it, ret);
            } else {
                return ret;
            }
        } else if (isWhitespace(c) or (c == ')')) {
            if (debug) {
                std.debug.print("\tAdding Ref: '{s}'\n", .{it.selection()});
            }
            return AstNode{ .ref = it.selection() };
        }
    }

    if (debug) {
        std.debug.print("\tAdding RefInc: '{s}'\n", .{it.selectionInc()});
    }
    return AstNode{ .ref = it.selectionInc() };
}

fn readStringRef(it: *StringReader) !AstStringFragment {
    if (debug) {
        std.debug.print("\tEnter readStringRef\n", .{});
    }

    _ = it.next(); // skip leading {
    it.select();

    //Fail on leading space
    if (isWhitespace(it.peek())) {
        return DestructError.space_in_interpolation;
    }

    while (it.next()) |c| {
        if (c == '}') {
            break;
        }
        if (isWhitespace(c)) {
            return DestructError.space_in_interpolation;
        }
    }
    if (debug) {
        std.debug.print("\tAdding StringRef: '{s}'\n", .{it.selection()});
    }

    return AstStringFragment{
        .type = StringFragmentType.ref,
        .chars = it.selection(),
    };
}

fn readStringChars(it: *StringReader, typ: u8) AstStringFragment {
    if (debug) {
        std.debug.print("\tEnter readStringChars\n", .{});
    }
    it.select();

    while (it.next()) |c| {
        if ((c == typ) or (c == '{') or (c == '\\')) {
            break;
        }
    }
    if (debug) {
        std.debug.print("\tAdding StringFragment: '{s}'\n", .{it.selection()});
    }
    var ret = AstStringFragment{
        .type = StringFragmentType.chars,
        .chars = it.selection(),
    };

    if ((it.peek() == '{') or (it.peek() == '\\')) {
        //Ugly hack but it works, this way readStringExpression
        //sees the { token
        it.rewind();
    }
    return ret;
}

fn readStringExpression(allocator: Allocator, it: *StringReader, typ: u8) !AstNode {
    if (debug) {
        std.debug.print("\tEnter readStringExpression\n", .{});
    }
    // std.debug.print("{p} {p}", .{allocator, it});
    var fragments = ArrayList(AstStringFragment).init(allocator);
    var escaped = false;

    while (it.next()) |c| {
        if (escaped) {
            //Last char was \
            try fragments.append(readStringChars(it, typ));
            escaped = false;
        } else if (c == typ) {
            break;
        } else if (c == '{') {
            try fragments.append(try readStringRef(it));
        } else if (c == '\\') {
            escaped = true;
        } else {
            try fragments.append(readStringChars(it, typ));
        }

        if (it.peek() == typ) {
            break;
        }
    }

    if (debug) {
        std.debug.print("\tString Exit {c}\n", .{it.peek()});
    }
    return AstNode{ .string = fragments };
}

fn readSymbol(it: *StringReader) []const u8 {
    if (debug) {
        std.debug.print("\tEnter readSymbol\n", .{});
    }
    it.select();
    while (it.next()) |c| {
        if (isWhitespace(c) or (c == ']')) {
            break;
        }
    }
    return it.selection();
}

pub fn compile(allocator: Allocator, source: []const u8) !Program {
    var it = StringReader.init(source);

    //clear leading text
    while (it.next()) |c| {
        if (c == '[') {
            break;
        }
    }

    //read symbol bindings
    var symbols = ArrayList([]const u8).init(allocator);
    while (it.next()) |c| {
        if (c == ']') {
            break;
        } else if (!isWhitespace(c)) {
            var sym = readSymbol(&it);
            if (sym.len > 0) {
                if (debug) {
                    std.debug.print("\tAdding SymbolBinding: '{c}'\n", .{sym[0]});
                }

                if (ascii.isDigit(sym[0])) {
                    std.debug.print("Error: symbols must start with a letter", .{});
                    return DestructError.ref_non_alpha;
                } else {
                    try symbols.append(sym);
                }
            }
        }

        if (it.peek() == ']') {
            break;
        }
    }

    //read expressions
    var ex = ArrayList(AstNode).init(allocator);
    while (it.next()) |c| {
        if ((c == '\'') or (c == '"')) {
            try ex.append(try readStringExpression(allocator, &it, c));
        } else if (!isWhitespace(c) and (c != ')')) {
            try ex.append(try readRefExpression(allocator, &it));
        }
    }

    return Program{ .symbols = symbols, .ex = ex };
}
