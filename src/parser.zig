const std = @import("std");
const expect = @import("std").testing.expect;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const ascii = std.ascii;
const isWhitespace = std.ascii.isWhitespace;

const builtin = @import("./builtin.zig");
const DestructError = builtin.DestructError;
const AstNodeType = builtin.AstNodeType;
const AstNode = builtin.AstNode;
const AstFun = builtin.AstFun;
const Program = builtin.Program;

//Set to true for debug output
const debug = false;
const debugReader = false;

const Mode = enum { START, ARG_LIST, ARG_NAME, EX_LIST, EX_NAME, EX_SQT_STR, EX_SQT_REF, EX_SQT_ESC };
const ExName = struct { name: []const u8, type: AstNodeType };

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

    pub fn skipWhitespace(self: *StringReader) void {
        while (isWhitespace(self.peek())) {
            if (self.next() == null) {
                break;
            }
        }
    }

    pub fn skipWhitespaceUntil(self: *StringReader, c: u8) !void {
        self.skipWhitespace();
        var n = self.next();
        if (n != c) {
            std.debug.print("Unexpected character '{c}' expected '{c}'", .{ .n, .c });
            return DestructError.unexpected_char;
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

fn readStringRef(allocator: Allocator, it: *StringReader) !AstNode {
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
        if (isWhitespace(c)) {
            return DestructError.space_in_interpolation;
        } else if (c == '.') {
            var ret = try readRefFunc(allocator, it, AstNode{ .ref = it.selection() });
            if (it.peek() == '.') {
                return readRefFunc(allocator, it, ret);
            } else {
                return ret;
            }
        } else if ((c == '}') or (c == ')')) {
            if (debug) {
                std.debug.print("\tAdding Ref: '{s}'\n", .{it.selection()});
            }
            return AstNode{ .ref = it.selection() };
        }
    }

    if (debug) {
        std.debug.print("\tAdding StringRef: '{s}'\n", .{it.selection()});
    }

    return AstNode{
        .ref = it.selection(),
    };
}

fn readStringChars(it: *StringReader, typ: u8) AstNode {
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
    var ret = AstNode{
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
    var fragments = ArrayList(AstNode).init(allocator);
    var escaped = false;

    while (it.next()) |c| {
        if (escaped) {
            //Last char was \
            try fragments.append(readStringChars(it, typ));
            escaped = false;
        } else if (c == typ) {
            break;
        } else if (c == '{') {
            try fragments.append(try readStringRef(allocator, it));
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
    return AstNode{ .fun = AstFun{ .name = "str", .args = fragments } };
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

                var isIgnored = std.mem.eql(u8, "_", sym);
                var isEllipsis = std.mem.eql(u8, "...", sym);
                var leadAlpha = ascii.isAlphabetic(sym[0]);

                if (isIgnored or isEllipsis or leadAlpha) {
                    try symbols.append(sym);
                } else {
                    std.debug.print("Error: invalid symbol: {s}\n", .{sym});
                    return DestructError.ref_non_alpha;
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

//New parser, each read step ends on its terminating character
// so that the following step can peek that char
pub fn wrapRefInFun(allocator: Allocator, refName: []const u8, it: *StringReader): !AstNode {
    //Read funName
    //Read args
    //return wrapped ref
}


pub fn readArgList(allocator: Allocator, it: *StringReader) ![]AstNode {
    var args = ArrayList(AstNode).init(allocator);
    //This should take the arglist as ref so that wrapping can be fast
    //TODO: impl
    return args.items;
}

pub fn readRefOrFun(allocator: Allocator, it: *StringReader) !AstNode {
    it.select();

    while (it.next()) |c| {
        if (c == '.') {
            //RefFollowed by func
        } else if (c == '(') {
            //Fun
            var funName = it.selection();
            var args = readArgList(allocator, it);
            return AstNode{ .fun = AstFun{ .name = funName, .args = args } };
        } else if (isWhitespace(c)) {
            //LoneRef
            var refName = it.selection();
            return AstNode{ .ref = refName };
        }
    }
}

pub fn readEscapedStringCharacter(allocator: Allocator, it: *StringReader) !AstNode {
    var c = it.next();

    if (c != null) {
        var buff = try allocator.alloc(u8, 1);
        buff[0] = switch (c) {
            't' => '\t',
            'n' => '\n',
            else => c,
        };
        return AstNode{ .chars = buff };
    }
    //If were at the end of the string just return an empty token
    return AstNode{ .chars = u8[0] };
}

pub fn readStringExpression2(allocator: Allocator, it: *StringReader) !AstNode {
    var qtType = it.peek();
    var fragments = ArrayList(AstNode).init(allocator);

    if (debug and !((qtType == '\'') or (qtType == '"'))) {
        std.debug.print("Error: invalid start of str block: {s}\n", .{qtType});
        return DestructError.missing_input;
    }
    it.select();
    while (it.next()) |c| {
        if (c == qtType) {
            //return
            break;
        } else if (c == '{') {
            try fragments.append(AstNode{ .chars = it.selection() });
            //go back to readAstNode? can there be a string here
            it.next(); //Skip the leading { when going back to }
            try fragments.append(readAstNode2(allocator, it));
            it.skipWhitespaceUntil('}');
            it.next();
            it.select();
        } else if (c == '\\') {
            //deal with escape here
            try fragments.append(AstNode{ .chars = it.selection() });
            try fragments.append(try readEscapedStringCharacter(allocator, it));
            it.next();
            it.select();
        }
    }

    try fragments.append(AstNode{ .chars = it.selection() });
    return AstNode{ .fun = AstFun{ .name = "str", .args = fragments } };
}

pub fn readAstNode2(allocator: Allocator, it: *StringReader) !AstNode {
    it.skipWhitespace();

    //TODO: skip while here?
    while (it.next()) |c| {
        if ((c == '\'') or (c == '"')) {
            return readStringExpression2(allocator, it);
        } else if (!isWhitespace(c) and (c != ')')) {
            return readRefOrFun(allocator, it);
        }
    }
}
