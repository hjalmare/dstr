const std = @import("std");
const expect = @import("std").testing.expect;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const ascii = std.ascii;
const isWhitespace = std.ascii.isWhitespace;
const isDigit = std.ascii.isDigit;

const builtin = @import("./builtin.zig");
const DestructError = builtin.DestructError;
const AstNodeType = builtin.AstNodeType;
const AstNode = builtin.AstNode;
const AstFun = builtin.AstFun;
const Program = builtin.Program;
const InputParser = builtin.InputParser;
const resolveBuiltin = builtin.resolveBuiltin;

//Set to true for debug output
const debug = false;
const debugReader = false;

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
                std.debug.print(
                    "\t\tReader.next offset: {d} selectStart:{d} char:'{c}'\n",
                    .{ self.offset, self.selectStart, ret },
                );
            }
            return ret;
        } else null;
    }

    pub fn peek(self: StringReader) u8 {
        if (debugReader) {
            var ret = self.src[self.offset - 1];
            std.debug.print(
                "\t\tReader.peek offset: {d} selectStart:{d} char:'{c}'\n",
                .{ self.offset, self.selectStart, ret },
            );
        }
        return self.src[self.offset - 1];
    }

    pub fn select(self: *StringReader) void {
        self.selectStart = self.offset - 1;
        if (debugReader) {
            var ret = self.src[self.offset - 1];
            std.debug.print(
                "\t\tReader.select offset: {d} selectStart:{d} char:'{c}'\n",
                .{ self.offset, self.selectStart, ret },
            );
        }
    }

    pub fn selectNext(self: *StringReader) void {
        self.selectStart = self.offset;
        if (debugReader) {
            var ret = self.src[self.offset - 1];
            std.debug.print(
                "\t\tReader.selectNext offset: {d} selectStart:{d} char:'{c}'\n",
                .{ self.offset, self.selectStart, ret },
            );
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
        if (debugReader) {
            std.debug.print("\t\tReader.SkipWhitespaceUntil '{c}'\n", .{c});
        }
        self.skipWhitespace();
        var n = self.peek();
        if (n != c) {
            std.debug.print("Unexpected character '{c}' expected '{c}'\n", .{ n, c });
            return DestructError.unexpected_char;
        }
    }

    pub fn nextNonWhitespace(self: *StringReader) ?u8 {
        if (debugReader) {
            std.debug.print("\t\tReader.nextNonWhitespace \n", .{});
        }
        while (self.next()) |c| {
            if (!isWhitespace(c)) {
                return c;
            }
        }
        return null;
    }
    //Exclusive selection
    //Returns selection from the last select() until the previously
    //read char
    pub fn selection(self: StringReader) []const u8 {
        var off = if (self.offset >= self.src.len) self.src.len - 1 else self.offset - 1;
        var ret = self.src[self.selectStart..off];

        if (debugReader) {
            std.debug.print("\t\tReader.selection offset: {d} selectStart:{d} str:'{s}'\n", .{ self.offset, self.selectStart, ret });
        }
        return ret;
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

pub fn parsePositionalInput(allocator: Allocator, it: *StringReader) !InputParser {
    var symbols = ArrayList([]const u8).init(allocator);
    while (it.next()) |c| {
        if (c == ']') {
            break;
        } else if (!isWhitespace(c)) {
            var sym = readSymbol(it);
            if (sym.len > 0) {
                if (debug) {
                    std.debug.print("\tAdding SymbolBinding: '{s}'\n", .{sym});
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

    return InputParser{ .positional = symbols.items };
}

pub fn compile(allocator: Allocator, source: []const u8) !Program {
    var it = StringReader.init(source);

    //clear leading text
    while (it.next()) |c| {
        if (c == '[') {
            break;
        }
    }

    const input = try parsePositionalInput(allocator, &it);
    //read symbol bindings
    //read expressions
    var ex = ArrayList(AstNode).init(allocator);
    while (it.nextNonWhitespace()) |_| {
        if (debug) {
            std.debug.print("Adding expr\n", .{});
        }
        try ex.append(try readAstNode(allocator, &it));
    }

    return Program{ .input = input, .ex = ex };
}

//New expression parser
//Holy off by one error batman, tokenizing would really help :D

pub fn wrapInFun(allocator: Allocator, argList: *ArrayList(AstNode), it: *StringReader) !AstNode {
    if (debug) {
        std.debug.print("Enter wrapInFun\n", .{});
    }

    _ = it.next(); //Skip leading '.'
    it.select();

    while (it.next()) |c| {
        if (c == '.') {
            return DestructError.unexpected_char;
        } else if (c == '(') {
            //Fun
            var funName = it.selection();
            try readArgList(allocator, it, argList);
            if (debug) {
                std.debug.print("\tProducing fun '{s}'\n", .{funName});
            }
            var ret = AstNode{ .fun = AstFun{ .name = funName, .impl = try resolveBuiltin(funName), .args = argList.items } };
            if (it.next()) |lahead| {
                if (isWhitespace(lahead) or lahead == '}') {
                    return ret;
                } else if (lahead == ')') {
                    it.rewind();
                    return ret;
                } else if (lahead == '.') {
                    var innerArgs = ArrayList(AstNode).init(allocator);
                    try innerArgs.append(ret);
                    return wrapInFun(allocator, &innerArgs, it);
                } else {
                    return DestructError.unexpected_char;
                }
            } else {
                return ret;
            }
        } else if (isWhitespace(c)) {
            //LoneRef
            return DestructError.unexpected_char;
        }
    }

    return DestructError.unexpected_char;
}

pub fn readArgList(allocator: Allocator, it: *StringReader, args: *ArrayList(AstNode)) !void {
    if (debug) {
        std.debug.print("Enter readArgList\n", .{});
    }

    _ = it.next(); //Skip leading '('
    //TODO: handle end of string (syntax error missing ')' )
    it.skipWhitespace();
    while (it.peek() != ')') {
        var arg = try readAstNode(allocator, it);

        try args.append(arg);
        //Dirty hack to handle when the last arg was a str or fun
        switch (arg) {
            AstNodeType.fun, AstNodeType.chars => _ = it.next(),
            else => {},
        }
        it.skipWhitespace();
    }

    return;
}

pub fn readRefOrFun(allocator: Allocator, it: *StringReader) !AstNode {
    if (debug) {
        std.debug.print("Enter readRefOrFun\n", .{});
    }
    it.select();

    while (it.next()) |c| {
        if (c == '.') {
            //RefFollowed by func
            var argList = ArrayList(AstNode).init(allocator);
            try argList.append(AstNode{ .ref = it.selection() });
            return wrapInFun(allocator, &argList, it);
        } else if (c == '(') {
            //Fun
            var funName = it.selection();
            var argList = ArrayList(AstNode).init(allocator);
            try readArgList(allocator, it, &argList);
            var ret = AstNode{ .fun = AstFun{ .name = funName, .impl = try resolveBuiltin(funName), .args = argList.items } };

            if (it.next()) |lahead| {
                if (lahead == '.') {
                    var subArgList = ArrayList(AstNode).init(allocator);
                    try subArgList.append(ret);
                    return wrapInFun(allocator, &subArgList, it);
                } else {
                    it.rewind();
                    return ret;
                }
            } else {
                return ret;
            }
        } else if (isWhitespace(c) or c == '}' or c == ')') {
            //LoneRef
            var refName = it.selection();
            if (debug) {
                std.debug.print("\tProducing ref '{s}'\n", .{refName});
            }
            return AstNode{ .ref = refName };
        }
    }

    //End of input reached
    var refName = it.selectionInc();
    if (debug) {
        std.debug.print("\tProducing ref at eof '{s}'\n", .{refName});
    }
    return AstNode{ .ref = refName };
}

pub fn readEscapedStringCharacter(allocator: Allocator, it: *StringReader) !AstNode {
    if (debug) {
        std.debug.print("Enter readEscapedStringCharacter\n", .{});
    }
    var cn = it.next();

    if (cn) |c| {
        var buff = try allocator.alloc(u8, 1);
        buff[0] = switch (c) {
            't' => '\t',
            'n' => '\n',
            else => c,
        };
        return AstNode{ .chars = buff };
    }
    //If were at the end of the string just return an empty token
    return AstNode{ .chars = try allocator.alloc(u8, 0) };
}

pub fn readStringExpression(allocator: Allocator, it: *StringReader) !AstNode {
    if (debug) {
        std.debug.print("Enter readStringExpression\n", .{});
    }
    var qtType = it.peek();
    var fragments = ArrayList(AstNode).init(allocator);

    if (debug and !((qtType == '\'') or (qtType == '"'))) {
        std.debug.print("Error: invalid start of str block: {c}\n", .{qtType});
        return DestructError.missing_input;
    }

    it.selectNext();
    while (it.next()) |c| {
        if (c == qtType) {
            //return
            break;
        } else if (c == '{') {
            try fragments.append(AstNode{ .chars = it.selection() });
            //go back to readAstNode? can there be a string here
            _ = it.next(); //Skip the leading { when going back to }
            try fragments.append(try readAstNode(allocator, it));
            it.skipWhitespace();
            if (it.peek() == ')') {
                _ = it.next(); //skip ending paren if method call
            }

            try it.skipWhitespaceUntil('}');
            var n = it.next();
            if (n == null or n == qtType) {
                //if we reach the end of string just do an early exit
                return AstNode{ .fun = AstFun{ .name = "str", .impl = try resolveBuiltin("str"), .args = fragments.items } };
            } else {
                it.select();
            }
        } else if (c == '\\') {
            //deal with escape here
            try fragments.append(AstNode{ .chars = it.selection() });
            try fragments.append(try readEscapedStringCharacter(allocator, it));
            if (it.next()) |lahead| {
                if (lahead == qtType) {
                    it.select();
                    break;
                }
            }
            it.select();
        }
    }

    if (debug) {
        std.debug.print("\tFinal String fragment '{s}'\n", .{it.selection()});
    }
    try fragments.append(AstNode{ .chars = it.selection() });
    var ret = AstNode{ .fun = AstFun{ .name = "str", .impl = try resolveBuiltin("str"), .args = fragments.items } };

    if (it.next()) |lahead| {
        if (lahead == '.') {
            var argList = ArrayList(AstNode).init(allocator);
            try argList.append(ret);
            return wrapInFun(allocator, &argList, it);
        }
        it.rewind();
    }
    return ret;
}

pub fn readInteger(it: *StringReader) !AstNode {
    if (debug) {
        std.debug.print("Enter readInteger\n", .{});
    }
    it.select();

    while (it.next()) |c| {
        if (!isDigit(c)) {
            break;
        }
    }

    var intVal = try std.fmt.parseInt(i64, it.selection(), 10);
    if (debug) {
        std.debug.print("Producing integer: {}\n", .{intVal});
    }
    return AstNode{ .int = intVal };
}

pub fn readAstNode(allocator: Allocator, it: *StringReader) !AstNode {
    if (debug) {
        std.debug.print("Enter readAstNode\n", .{});
    }
    it.skipWhitespace();

    //TODO: skip while here?
    //if (it.peek()) |c| {
    var c = it.peek();
    if ((c == '\'') or (c == '"')) {
        return readStringExpression(allocator, it);
    } else if (isDigit(c)) {
        return readInteger(it);
    } else if (!isWhitespace(c) and (c != ')')) {
        return readRefOrFun(allocator, it);
    }
    //}

    return DestructError.unexpected_char;
}
