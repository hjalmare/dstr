const std = @import("std");
const expect = @import("std").testing.expect;
const runtime = @import("runtime.zig");

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const ascii = std.ascii;
const isWhitespace = std.ascii.isWhitespace;
const isDigit = std.ascii.isDigit;

const builtin = @import("./builtin.zig");
const streamstep = @import("./streamstep.zig");
const DestructError = runtime.DestructError;
const AstNodeType = runtime.AstNodeType;
const AstNode = runtime.AstNode;
const AstFun = runtime.AstFun;
const InputParser = runtime.InputParser;
const resolveBuiltin = builtin.resolveBuiltin;
const RefMap = runtime.RefMap;
const StreamStep = streamstep.StreamStep;

//Set to true for debug output
const debug = false;
const debugReader = false;

// ======================================================================
// This file is pretty much all dragons
// ======================================================================

pub const Program = struct {
    input: InputParser,
    refMap: []const RefMap,
    ex: ArrayList(AstNode), //Todo: rename to ast?
    stream: *StreamStep,
};

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
            const ret = self.src[self.offset];
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
            const ret = self.src[self.offset - 1];
            std.debug.print(
                "\t\tReader.peek offset: {d} selectStart:{d} char:'{c}'\n",
                .{ self.offset, self.selectStart, ret },
            );
        }
        return self.src[self.offset - 1];
    }

    pub fn eof(self: StringReader) bool {
        return self.offset >= self.src.len;
    }

    pub fn select(self: *StringReader) void {
        self.selectStart = self.offset - 1;
        if (debugReader) {
            const ret = self.src[self.offset - 1];
            std.debug.print(
                "\t\tReader.select offset: {d} selectStart:{d} char:'{c}'\n",
                .{ self.offset, self.selectStart, ret },
            );
        }
    }

    pub fn selectNext(self: *StringReader) void {
        self.selectStart = self.offset;
        if (debugReader) {
            const ret = self.src[self.offset - 1];
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
        const n = self.peek();
        if (n != c) {
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
        const off = if (self.offset >= self.src.len) self.src.len - 1 else self.offset - 1;
        const ret = self.src[self.selectStart..off];

        if (debugReader) {
            std.debug.print("\t\tReader.selection offset: {d} selectStart:{d} str:'{s}'\n", .{ self.offset, self.selectStart, ret });
        }
        return ret;
    }

    pub fn selectionInc(self: StringReader) []const u8 {
        const off = if (self.offset >= self.src.len) self.src.len - 1 else self.offset;
        if (debugReader) {
            const ret = self.src[off];
            std.debug.print("\t\tReader.selectionInc offset: {d} selectStart:{d} char:'{c}'\n", .{ self.offset, self.selectStart, ret });
        }
        return self.src[self.selectStart..(off + 1)];
    }

    pub fn rewind(self: *StringReader) void {
        self.offset = self.offset - 1;
        if (debugReader) {
            const ret = self.src[self.offset];
            std.debug.print("\t\tReader.rewind offset: {d} selectStart:{d} char:'{c}'\n", .{ self.offset, self.selectStart, ret });
        }
    }

    pub fn printUnexpectedCharError(self: *StringReader, allocator: Allocator) !void {
        var ln = try allocator.alloc(u8, self.offset);
        defer allocator.free(ln);

        for (ln, 0..) |_, i| {
            ln[i] = '-';
        }
        ln[ln.len - 1] = '^';

        std.debug.print("{s}\n{s}\nUnexpected character: '{c}'\n", .{ .src = self.src, .pt = ln, .char = self.peek() });
    }

    pub fn printUnexpectedtEofError(self: *StringReader, allocator: Allocator) !void {
        var ln = try allocator.alloc(u8, self.offset);
        defer allocator.free(ln);

        for (ln, 0..) |_, i| {
            ln[i] = '-';
        }
        ln[ln.len - 1] = '^';

        std.debug.print("{s}\n{s}\nUnexpected end of string\n", .{ .src = self.src, .pt = ln });
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

const InputParserResult = struct {
    parser: InputParser,
    refs: []const RefMap,
};

//TODO: Only works with single quotes atm
//TODO: Dirty as hell but it mostly works, cleanup later :D
const pssState = enum { chars, ref };
pub fn parseSegmentInput(allocator: Allocator, it: *StringReader) !InputParserResult {
    var nodes = ArrayList(runtime.SegmentNode).init(allocator);
    var refMap = ArrayList(RefMap).init(allocator);
    _ = it.next(); //Skipp leading quote
    it.select();

    var state = pssState.chars;
    if (it.peek() == '{') {
        state = pssState.ref;
        _ = it.next();
        it.select();
    }

    var charBuffer = ArrayList(u8).init(allocator);

    while (it.next()) |c| {
        switch (state) {
            .chars => {
                if (c == '{') {
                    if (it.selection().len > 0) {
                        if (debug) {
                            std.debug.print("\tAdding CharsSegment: '{s}' \n", .{it.selection()});
                        }
                        try charBuffer.appendSlice(it.selection());

                        try nodes.append(.{ .chars = charBuffer.items });
                        //Reset char buffer
                        charBuffer = ArrayList(u8).init(allocator);
                    }
                    state = pssState.ref;
                    _ = it.next(); //skip leading {}
                    it.skipWhitespace();
                    it.select();
                } else if (c == '\'') {
                    if (debug) {
                        std.debug.print("\tBreaking with selection: '{s}' \n", .{it.selection()});
                    }
                    //it.select();
                    break;
                } else if (c == '\\') {
                    if (debug) {
                        std.debug.print("\tAppending chars: '{s}' \n", .{it.selection()});
                    }
                    try charBuffer.appendSlice(it.selection());
                    if (it.next()) |e| {
                        if (debug) {
                            std.debug.print("\tAppending char: '{c}' \n", .{e});
                        }

                        const app = switch (e) {
                            'n' => '\n',
                            't' => '\t',
                            else => e,
                        };
                        try charBuffer.append(app);

                        it.selectNext();
                    }
                }
            },
            .ref => {
                if (c == '\'') {
                    try it.printUnexpectedCharError(allocator);
                    return DestructError.unexpected_char;
                } else if (isWhitespace(c)) {
                    if (debug) {
                        std.debug.print("\tAdding RefMap WS: '{s}' \n", .{it.selection()});
                    }
                    try nodes.append(.{ .ref = it.selection() });
                    try refMap.append(RefMap{ .name = it.selection(), .offset = @intCast(refMap.items.len) });
                    it.skipWhitespaceUntil('}') catch {
                        try it.printUnexpectedCharError(allocator);
                        return DestructError.unexpected_char;
                    };
                    state = pssState.chars;
                    _ = it.next(); //Skip trailing }
                    if (it.peek() == '\'') {
                        if (debug) {
                            std.debug.print("\tBreaking with selection: '{s}' \n", .{it.selection()});
                        }
                        it.select();
                        break;
                    }
                    it.select();
                } else if (c == '}') {
                    if (debug) {
                        std.debug.print("\tAdding RefMap: '{s}' \n", .{it.selection()});
                    }
                    try nodes.append(.{ .ref = it.selection() });
                    try refMap.append(RefMap{ .name = it.selection(), .offset = @intCast(refMap.items.len) });
                    state = pssState.chars;
                    _ = it.next(); //Skip trailing }
                    it.select();
                    if (it.peek() == '\'') {
                        if (debug) {
                            std.debug.print("\tBreaking with selection: '{s}' \n", .{it.selection()});
                        }
                        it.select();
                        break;
                    }
                }
            },
        }
    }

    if (it.selection().len > 0) {
        if (debug) {
            std.debug.print("\tAdding trailing CharsSegment: '{s}' \n", .{it.selection()});
        }
        try charBuffer.appendSlice(it.selection());
        try nodes.append(.{ .chars = charBuffer.items });
    }

    return InputParserResult{ .parser = .{ .segments = nodes.items }, .refs = refMap.items };
}

pub fn createPositionalRefMap(allocator: Allocator, symbols: [][]const u8) ![]RefMap {
    var ret = ArrayList(RefMap).init(allocator);

    var afterEllipse = false;

    for (symbols, 0..) |sym, si| {
        const dotDotDot = std.mem.eql(u8, sym, "...");
        const isUnderScore = std.mem.eql(u8, sym, "_");
        if (dotDotDot) {
            afterEllipse = true;
        } else if (!isUnderScore) {
            var offset: i32 = 0;
            if (afterEllipse) {
                if (debug) {
                    std.debug.print("\tAfter ellipse: offset:{any} index:{any} len:{any}\n", .{ offset, si, sym.len });
                }
                offset = @as(i32, @intCast(si)) - @as(i32, @intCast(symbols.len));
            } else {
                offset = @as(i32, @intCast(si));
            }
            if (debug) {
                std.debug.print("\tAdding RefMap: '{s}' '{any}' Ellipse: '{any}'\n", .{ sym, offset, afterEllipse });
            }
            try ret.append(RefMap{ .name = sym, .offset = offset });
        }
    }

    return ret.items;
}

pub fn parsePositionalInput(allocator: Allocator, it: *StringReader) !InputParserResult {
    var symbols = ArrayList([]const u8).init(allocator);

    while (it.next()) |c| {
        if (c == ']') {
            break;
        } else if (!isWhitespace(c)) {
            const sym = readSymbol(it);
            if (sym.len > 0) {
                if (debug) {
                    std.debug.print("\tAdding SymbolBinding: '{s}'\n", .{sym});
                }

                const isIgnored = std.mem.eql(u8, "_", sym);
                const isEllipsis = std.mem.eql(u8, "...", sym);
                const leadAlpha = ascii.isAlphabetic(sym[0]);

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
    const refMap = try createPositionalRefMap(allocator, symbols.items);

    return InputParserResult{ .parser = .{ .positional = symbols.items }, .refs = refMap };
}

pub fn compile(allocator: Allocator, source: []const u8, terminalStream: *streamstep.StreamStep) !Program {
    var it = StringReader.init(source);

    const firstChar = if (it.nextNonWhitespace()) |c| c else return DestructError.InvalidCharacter;
    const input = try switch (firstChar) {
        '[' => parsePositionalInput(allocator, &it),
        '\'' => parseSegmentInput(allocator, &it),
        else => return DestructError.InvalidCharacter,
    };

    const evalStep = try allocator.create(StreamStep);

    var stream: *StreamStep = undefined;
    if (it.next() == '.') {
        stream = parseStreamFun(allocator, input.refs, evalStep, &it) catch |err| {
            switch (err) {
                DestructError.unexpected_char => {
                    try it.printUnexpectedCharError(allocator);
                },
                else => {
                    std.debug.print("Compilation error {any}\n", .{ .err = err });
                },
            }
            return err;
        };
    } else {
        stream = evalStep;
    }

    //read symbol bindings
    //read expressions
    var ex = ArrayList(AstNode).init(allocator);
    while (it.nextNonWhitespace()) |_| {
        if (debug) {
            std.debug.print("Adding expr\n", .{});
        }
        try ex.append(readAstNode(allocator, &it) catch |err| {
            switch (err) {
                DestructError.unexpected_char => {
                    try it.printUnexpectedCharError(allocator);
                },
                else => {
                    std.debug.print("Compilation error {any}\n", .{ .err = err });
                },
            }
            return err;
        });
    }

    if (debug) {
        var prefix = ArrayList(u8).init(allocator);
        for (ex.items) |i| {
            try i.print(&prefix);
        }
        prefix.deinit();
    }
    evalStep.* = StreamStep{ .eval = streamstep.EvalStep{ .next = terminalStream, .refMap = input.refs, .expressions = ex.items } };
    return Program{ .input = input.parser, .refMap = input.refs, .ex = ex, .stream = stream };
}

//Stream parser
// ==============================================================00

pub fn parseStreamFun(allocator: Allocator, refMap: []const RefMap, endStep: *StreamStep, it: *StringReader) !*StreamStep {
    if (debug) {
        std.debug.print("Enter parseStreamFun\n", .{});
    }

    if (it.next()) |c| {
        if (!ascii.isAlphanumeric(c)) {
            return DestructError.unexpected_char;
        }
    } else {
        return DestructError.unexpected_char;
    }

    it.select();

    while (it.next()) |c| {
        if (c == '.') {
            return DestructError.unexpected_char;
        } else if (c == '(') {
            //Fun
            const stepName = it.selection();
            var argList = ArrayList(AstNode).init(allocator);
            try readArgList(allocator, it, &argList);
            if (debug) {
                std.debug.print("\tProducing StreamStep '{s}'\n", .{stepName});
            }

            var nextStep: *StreamStep = undefined;

            if (it.next()) |lahead| {
                if (isWhitespace(lahead) or lahead == '}') {
                    nextStep = endStep;
                } else if (lahead == ')') {
                    it.rewind();
                    nextStep = endStep;
                } else if (lahead == '.') {
                    nextStep = try parseStreamFun(allocator, refMap, endStep, it); //wrapInFun(allocator, &innerArgs, it);
                } else {
                    return DestructError.unexpected_char;
                }
            } else {
                //Just fail here?
                //nextStep = endStep;
                return DestructError.unexpected_char;
            }

            //TODO: Break this out like builtins
            const ret = try allocator.create(StreamStep);
            if (std.mem.eql(u8, stepName, "filter")) {
                ret.* = .{ .filter = streamstep.FilterStep{ .next = nextStep, .predicates = argList.items, .refMap = refMap } };
            } else if (std.mem.eql(u8, stepName, "skip")) {
                if ((argList.items.len == 1) and (argList.items[0] == AstNodeType.int)) {
                    ret.* = .{ .skip = streamstep.SkipStep{ .next = nextStep, .skipCount = argList.items[0].int } };
                } else {
                    std.debug.print("Skip step requires one integer param\n", .{});
                    return DestructError.unexpected_char;
                }
            } else if (std.mem.eql(u8, stepName, "first")) {
                if ((argList.items.len == 1) and (argList.items[0] == AstNodeType.int)) {
                    ret.* = .{ .first = streamstep.FirstStep{ .next = nextStep, .count = argList.items[0].int } };
                } else {
                    std.debug.print("First step requires one integer param\n", .{});
                    return DestructError.unexpected_char;
                }
            } else {
                std.debug.print("Unknown stream step: {s}\n", .{stepName});
                return DestructError.unexpected_char;
            }

            return ret;
        } else if (isWhitespace(c)) {
            //LoneRef
            return DestructError.unexpected_char;
        }
    }

    return DestructError.unexpected_char;
}

//New expression parser
// =======================================================================
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
            const funName = it.selection();
            try readArgList(allocator, it, argList);
            if (debug) {
                std.debug.print("\tProducing fun '{s}'\n", .{funName});
            }
            const ret = AstNode{ .fun = AstFun{ .name = funName, .impl = try resolveBuiltin(funName), .args = argList.items } };
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
        const arg = try readAstNode(allocator, it);

        try args.append(arg);
        if (it.eof()) {
            //When we reach end of program before seeing the closing paren
            return DestructError.unexpected_char;
        }
        _ = it.next();
        it.skipWhitespace();
    }

    if (debug) {
        std.debug.print("Exit readArgList\n", .{});
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
            const funName = it.selection();
            var argList = ArrayList(AstNode).init(allocator);
            try readArgList(allocator, it, &argList);
            const ret = AstNode{ .fun = AstFun{ .name = funName, .impl = try resolveBuiltin(funName), .args = argList.items } };

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
            const refName = it.selection();
            if (debug) {
                std.debug.print("\tProducing ref '{s}'\n", .{refName});
            }
            it.rewind();
            return AstNode{ .ref = refName };
        }
    }

    //End of input reached
    const refName = it.selectionInc();
    if (debug) {
        std.debug.print("\tProducing ref at eof '{s}'\n", .{refName});
    }
    return AstNode{ .ref = refName };
}

pub fn readEscapedStringCharacter(allocator: Allocator, it: *StringReader) !AstNode {
    if (debug) {
        std.debug.print("Enter readEscapedStringCharacter\n", .{});
    }
    const cn = it.next();

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
    const qtType = it.peek();
    var fragments = ArrayList(AstNode).init(allocator);

    if (debug and !((qtType == '\'') or (qtType == '"'))) {
        std.debug.print("Error: invalid start of str block: {c}\n", .{qtType});
        return DestructError.missing_input;
    }

    it.selectNext();
    while (it.next()) |c| {
        if (c == qtType) {
            //return
            if (debug) {
                std.debug.print("\tFinal String fragment '{s}'\n", .{it.selection()});
            }
            try fragments.append(AstNode{ .chars = it.selection() });
            const ret = AstNode{ .fun = AstFun{ .name = "str", .impl = try resolveBuiltin("str"), .args = fragments.items } };

            if (it.next()) |lahead| {
                if (lahead == '.') {
                    var argList = ArrayList(AstNode).init(allocator);
                    try argList.append(ret);
                    return wrapInFun(allocator, &argList, it);
                }
                it.rewind();
            }
            return ret;
        } else if (c == '{') {
            if (debug) {
                std.debug.print("\tString interpolation\n", .{});
            }
            try fragments.append(AstNode{ .chars = it.selection() });
            //go back to readAstNode? can there be a string here
            _ = it.next(); //Skip the leading { when going back to }
            try fragments.append(try readAstNode(allocator, it));

            if (it.peek() != '}') {
                _ = it.next(); //skip ending paren if method call
            }

            it.skipWhitespaceUntil('}') catch {
                return DestructError.unexpected_char;
            };

            it.selectNext();
        } else if (c == '\\') {
            //deal with escape here
            try fragments.append(AstNode{ .chars = it.selection() });

            try fragments.append(try readEscapedStringCharacter(allocator, it));
            if (it.next()) |qlahead| {
                if (qlahead == qtType) {
                    if (debug) {
                        std.debug.print("\tFinal string after escape String fragment '{s}'\n", .{it.selection()});
                    }

                    const ret = AstNode{ .fun = AstFun{ .name = "str", .impl = try resolveBuiltin("str"), .args = fragments.items } };

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
            }
            it.select();
            it.rewind();
        }
    }

    return DestructError.unexpected_char;
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

    const intVal = try std.fmt.parseInt(i64, it.selection(), 10);
    if (debug) {
        std.debug.print("Producing integer: {}\n", .{intVal});
    }
    it.rewind();
    return AstNode{ .int = intVal };
}

pub fn readAstNode(allocator: Allocator, it: *StringReader) DestructError!AstNode {
    if (debug) {
        std.debug.print("Enter readAstNode\n", .{});
    }
    it.skipWhitespace();

    //TODO: skip while here?
    const c = it.peek();
    if ((c == '\'') or (c == '"')) {
        return readStringExpression(allocator, it);
    } else if (isDigit(c)) {
        return readInteger(it);
    } else if (std.ascii.isAlphanumeric(c) and !isWhitespace(c) and (c != ')')) {
        const ret = readRefOrFun(allocator, it);
        return ret;
    } else if (c == ' ') {
        //if we still point to a whitespace after skipWhitespace we are at eof
        return DestructError.unexpected_char;
    }

    if (debug) {
        std.debug.print("Exit readAstNode\n", .{});
    }
    return DestructError.unexpected_char;
}
