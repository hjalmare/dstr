const std = @import("std");
const expect = @import("std").testing.expect;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

//Set to true for debug output
const debug = true;
const debugReader = true;

const DestructError = error{ anon_ref, unknown_ref, missing_input, space_in_interpolation };

const Mode = enum { START, ARG_LIST, ARG_NAME, EX_LIST, EX_NAME, EX_SQT_STR, EX_SQT_REF, EX_SQT_ESC };

const AstNodeType = enum { string, ref, fun };

const StringFragmentType = enum { chars, ref };

const ExName = struct { name: []const u8, type: AstNodeType };

const AstNode = union(AstNodeType) { ref: []const u8, string: ArrayList(AstStringFragment), fun: AstFun };

const AstStringFragment = struct { type: StringFragmentType, chars: []const u8 };

const AstFun = struct { name: []const u8, args: ArrayList(AstNode) };

const Program = struct { symbols: ArrayList([]const u8), ex: ArrayList(AstNode) };

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

fn isWhitespace(c: u8) bool {
    return (c == ' ') or (c == '\t');
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

    std.debug.print("\tString Exit {c}\n", .{it.peek()});
    return AstNode{ .string = fragments };
}

fn readRefExpression(it: *StringReader) AstNode {
    if (debug) {
        std.debug.print("\tEnter readRefExpression\n", .{});
    }
    it.select();

    while (it.next()) |c| {
        if (isWhitespace(c)) {
            if (debug) {
                std.debug.print("\tAdding Ref: '{s}'\n", .{it.selection()});
            }
            return AstNode{ .ref = it.selection() };
        }
    }

    if (debug) {
        std.debug.print("\tAdding RefInc: '{s}''\n", .{it.selectionInc()});
    }
    return AstNode{ .ref = it.selectionInc() };
}

fn readSymbol(it: *StringReader) []const u8 {
    if (debug) {
        std.debug.print("\tEnter readSymbol", .{});
    }
    it.select();
    while (it.next()) |c| {
        if (isWhitespace(c) or (c == ']')) {
            break;
        }
    }
    return it.selection();
}

fn compile2(allocator: Allocator, source: []const u8) !Program {
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
                    std.debug.print("\tAdding SymbolBinding: '{s}'\n", .{sym});
                }
                try symbols.append(sym);
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
        } else if (!isWhitespace(c)) {
            try ex.append(readRefExpression(&it));
        }
    }

    return Program{ .symbols = symbols, .ex = ex };
}

fn compile(allocator: Allocator, source: []const u8) !Program {
    var symbols = ArrayList([]const u8).init(allocator);
    var ex = ArrayList(AstNode).init(allocator);
    var stringFragments: ArrayList(AstStringFragment) = undefined;
    //Parser FSM
    var mode = Mode.START;
    var readPos: usize = 0;

    for (source) |c, i| {
        if (debug) std.debug.print("{d}: {c}  {any}\n", .{ i, c, mode });

        switch (mode) {
            Mode.START => {
                if (c == '[') {
                    mode = Mode.ARG_LIST;
                }
            },
            Mode.ARG_LIST => {
                if (c == ']') {
                    mode = Mode.EX_LIST;
                } else if (!isWhitespace(c)) {
                    mode = Mode.ARG_NAME;
                    readPos = i;
                }
            },
            Mode.ARG_NAME => {
                if (c == ']') {
                    mode = Mode.EX_LIST;
                    const slz = source[readPos..i];
                    try symbols.append(slz);
                } else if (isWhitespace(c)) {
                    mode = Mode.ARG_LIST;
                    const slz = source[readPos..i];
                    try symbols.append(slz);
                }
            },
            Mode.EX_LIST => {
                if ('\'' == c) {
                    //Enter quoted string mode
                    mode = Mode.EX_SQT_STR;
                    readPos = i + 1;
                    stringFragments = ArrayList(AstStringFragment).init(allocator);
                } else if (!isWhitespace(c)) {
                    mode = Mode.EX_NAME;
                    readPos = i;
                }
            },
            Mode.EX_NAME => {
                if (isWhitespace(c)) {
                    mode = Mode.EX_LIST;
                    const slz = source[readPos..i];
                    try ex.append(AstNode{ .ref = slz });
                    readPos = i;
                }
            },
            Mode.EX_SQT_STR => {
                if (c == '\'') {
                    mode = Mode.EX_LIST;
                    const slz = source[readPos..i];
                    try stringFragments.append(AstStringFragment{ .type = StringFragmentType.chars, .chars = slz });
                    try ex.append(AstNode{ .string = stringFragments });
                    stringFragments = undefined;
                } else if (c == '{') {
                    mode = Mode.EX_SQT_REF;
                    const slz = source[readPos..i];
                    try stringFragments.append(AstStringFragment{ .type = StringFragmentType.chars, .chars = slz });
                    readPos = i + 1;
                } else if (c == '\\') {
                    mode = Mode.EX_SQT_ESC;
                    const slz = source[readPos..i];
                    try stringFragments.append(AstStringFragment{ .type = StringFragmentType.chars, .chars = slz });
                    readPos = i + 1;
                }
            },
            Mode.EX_SQT_REF => {
                if (c == '}') {
                    mode = Mode.EX_SQT_STR;
                    const slz = source[readPos..i];
                    try stringFragments.append(AstStringFragment{ .type = StringFragmentType.ref, .chars = slz });
                    readPos = i + 1;
                } else if (isWhitespace(c)) {
                    std.debug.print("Whitespace is not allowed in string interpolation.\n", .{});
                    return DestructError.space_in_interpolation;
                }
            },
            Mode.EX_SQT_ESC => {
                mode = Mode.EX_SQT_STR;
            },
        }
    }
    //Cleanup last token
    if (mode == Mode.EX_NAME) {
        const slz = source[readPos..];
        try ex.append(AstNode{ .ref = slz });
    } else if (mode == Mode.EX_SQT_STR) {
        //TODO: maybe do something?
    }

    return Program{ .symbols = symbols, .ex = ex };
}

//Space Separated String
const SssMode = enum { START, WORD };

fn splitInput(allocator: Allocator, input: []const u8) !ArrayList([]const u8) {
    var ret = ArrayList([]const u8).init(allocator);
    var startPos: usize = 0;
    var mode = SssMode.START;

    for (input) |c, i| {
        switch (mode) {
            SssMode.START => {
                if (!isWhitespace(c)) {
                    mode = SssMode.WORD;
                    startPos = i;
                }
            },
            SssMode.WORD => {
                if (isWhitespace(c)) {
                    mode = SssMode.START;
                    try ret.append(input[startPos..i]);
                }
            },
        }
    }

    if (mode == SssMode.WORD) {
        try ret.append(input[startPos..]);
    }
    return ret;
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

fn execLine(allocator: Allocator, program: Program, line: ArrayList([]const u8)) !ArrayList([]const u8) {
    var ret = ArrayList([]const u8).init(allocator);

    for (program.ex.items) |ex| {
        switch (ex) {
            .string => {
                var strBuf = std.ArrayList(u8).init(allocator);
                for (ex.string.items) |fragment| {
                    switch (fragment.type) {
                        StringFragmentType.chars => {
                            try strBuf.appendSlice(fragment.chars);
                        },
                        StringFragmentType.ref => {
                            //Resolve str ref
                            var refStr = try resolveRef(program.symbols, line, fragment.chars);
                            try strBuf.appendSlice(refStr);
                        },
                    }
                }
                try ret.append(strBuf.items);
            },
            .ref => {
                var refStr = try resolveRef(program.symbols, line, ex.ref);
                try ret.append(refStr);
            },
            .fun => {},
        }
    }

    return ret;
}

pub fn main() !void {
    //Allocator used for the duration of the main program
    var gpa = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = gpa.allocator();
    defer gpa.deinit();

    //Allocator used for each line of input
    //TODO: use some resettable allocator here
    var lineArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var lineAllocator = lineArena.allocator();
    defer lineArena.deinit();

    //Process args
    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (debug) {
        for (args) |a| {
            std.debug.print("arg: {s}\n", .{a});
        }
    }

    if ((args.len < 2) or (args.len > 3)) {
        std.debug.print("Please invoke using: \n", .{});
        std.debug.print("\t./dstr [expression]\n", .{});
        std.debug.print("\t./dstr [expression] [executable] or\n\n", .{});
        std.debug.print("Example:\n", .{});
        std.debug.print("\tdstr \"[a .. b]  a b \"\n", .{});
        std.debug.print("\tdstr \"[a .. b]  a b \" echo\n", .{});
        std.os.exit(1);
    }

    const src = args[1];
    const pgm = compile(allocator, src) catch {
        std.os.exit(1);
    };

    //Read system in
    const stdin = std.io.getStdIn().reader();
    var input: ?[]u8 = try stdin.readUntilDelimiterOrEofAlloc(lineAllocator, '\n', 4096);

    const stdout = std.io.getStdOut();

    while (input) |in| {
        const splatInput = try splitInput(lineAllocator, in);
        var ret = execLine(lineAllocator, pgm, splatInput) catch {
            std.os.exit(1);
        };

        if (args.len == 2) {
            //Echo mode
            for (ret.items) |o, i| {
                if (i != 0) try stdout.writer().writeAll(" ");

                try stdout.writer().writeAll(o);
            }
            try stdout.writer().writeAll("\n");
        } else {
            //Exec mode
            var cmdLine = ArrayList([]const u8).init(lineAllocator);
            try cmdLine.append(args[2]);
            try cmdLine.appendSlice(ret.items);
            var cp = std.ChildProcess.init(cmdLine.items, lineAllocator);
            _ = try cp.spawnAndWait();
        }

        //Reset allocator and read a new line of input
        lineArena.deinit();
        lineArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        lineAllocator = lineArena.allocator();

        input = try stdin.readUntilDelimiterOrEofAlloc(lineAllocator, '\n', 4096);
    }
}

test "Ellipsis and string interpolation" {
    const src = "[ one ... two ]   two ' '  'says {one} aswell' ";
    const input = "hello a b c malte";
    const expectedOutput = [_][]const u8{ "malte", " ", "says hello aswell" };
    try quickTest(src, input, expectedOutput[0..]);
}

test "Ellipsis and string interpolation2" {
    const src = "[ one ... two ] two ' says {one} aswell' ";
    const input = "hello a b c malte";
    const expectedOutput = [_][]const u8{ "malte", " says hello aswell" };
    try quickTest(src, input, expectedOutput[0..]);
}

test "Ellipsis 2 args" {
    const src = "[ one ... two ] one two";
    const input = "AA BB";
    const expectedOutput = [_][]const u8{ "AA", "BB" };
    try quickTest(src, input, expectedOutput[0..]);
}

test "Ellipsis 4 args" {
    const src = "[ one two ... three four ] one two three four";
    const input = "AA BB xx CC DD";
    const expectedOutput = [_][]const u8{ "AA", "BB", "CC", "DD" };
    try quickTest(src, input, expectedOutput[0..]);
}

test "Leading Ellipsis" {
    const src = "[ ... one two ] one two";
    const input = "AA BB";
    const expectedOutput = [_][]const u8{ "AA", "BB" };
    try quickTest(src, input, expectedOutput[0..]);
}

test "Param skipping" {
    const src = "[ one ... _ two ]   one two";
    const input = "hello a b c malte";
    const expectedOutput = [_][]const u8{ "hello", "malte" };
    try quickTest(src, input, expectedOutput[0..]);
}

test "Param skipping 2" {
    const src = "[ one _  _ two ] one two";
    const input = "aa bb cc dd";
    const expectedOutput = [_][]const u8{ "aa", "dd" };
    try quickTest(src, input, expectedOutput[0..]);
}

test "Escaping characters" {
    const src = "[ one _  _ ] one 'look \\'at\\' me'";
    const input = "aa bb cc";
    const expectedOutput = [_][]const u8{ "aa", "look 'at' me" };
    try quickTest(src, input, expectedOutput[0..]);
}

test "Escaping characters2" {
    const src = "[ one _  _ ] one 'look \\'at\\' me'";
    const input = "aa bb cc";
    const expectedOutput = [_][]const u8{ "aa", "look 'at' me" };
    try quickTest(src, input, expectedOutput[0..]);
}

test "String interpolation" {
    const src = "[ one _  _ ] '{one}-{one}'";
    const input = "aa bb cc";
    const expectedOutput = [_][]const u8{"aa-aa"};
    try quickTest(src, input, expectedOutput[0..]);
}

test "Fail on leading space in interpolation" {
    const src = "[ one ] '{ one}'";
    try failCompile(src, DestructError.space_in_interpolation);
}

test "Fail on trailing space in interpolation" {
    const src = "[ one ] '{one }'";
    try failCompile(src, DestructError.space_in_interpolation);
}

test "Fail on missing input" {
    const src = "[ one two three] one two three";
    const input = "aa bb";
    try failTest(src, input, DestructError.missing_input);
}

//In this case aa can be seen as both the first and last element
//So this program is correct in a way :D
//test "Fail on missing input with elipse" {
//  const src = "[ one ... two] one two";
//  const input = "aa";
//  try failTest(src, input, DestructError.missing_input);
//}

test "Fail on underscore ref" {
    const src = "[ one _ two ] one _";
    const input = "aa bb cc";
    try failTest(src, input, DestructError.anon_ref);
}

fn failTest(src: []const u8, input: []const u8, expected_error: DestructError) !void {
    var gpa = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = gpa.allocator();
    defer gpa.deinit();

    const pgm = try compile2(allocator, src);
    const splatInput = try splitInput(allocator, input);

    _ = execLine(allocator, pgm, splatInput) catch |err| {
        try expect(err == expected_error);
        return;
    };

    return error.NotSame; //TODO: Change this error
}

fn failCompile(src: []const u8, expected_error: DestructError) !void {
    var gpa = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = gpa.allocator();
    defer gpa.deinit();

    _ = compile2(allocator, src) catch |err| {
        try expect(err == expected_error);
        return;
    };

    return error.NotSame; //TODO: Change this error
}

test "comp2 test" {
    var gpa = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = gpa.allocator();
    defer gpa.deinit();
    const src = "[ one _ two ] 'strings baby' one two";

    const input = "aa bb cc";
    const splatInput = try splitInput(allocator, input);
    const pgm = try compile2(allocator, src);
    var ret = try execLine(allocator, pgm, splatInput);
    const expected = [_][]const u8{ "strings baby", "aa", "cc" };
    try assertStrSlice(ret.items, expected[0..]);
}

test "comp3 test" {
    var gpa = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = gpa.allocator();
    defer gpa.deinit();
    const src = "[one _ two ] one 'strings {two}'";

    const input = "aa bb cc";
    const splatInput = try splitInput(allocator, input);
    const pgm = try compile2(allocator, src);
    var ret = try execLine(allocator, pgm, splatInput);
    const expected = [_][]const u8{ "aa", "strings cc" };
    try assertStrSlice(ret.items, expected[0..]);
}

fn quickTest(src: []const u8, input: []const u8, expected: []const []const u8) !void {
    var gpa = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = gpa.allocator();
    defer gpa.deinit();

    const pgm = try compile2(allocator, src);
    const splatInput = try splitInput(allocator, input);
    var ret = try execLine(allocator, pgm, splatInput);
    try assertStrSlice(ret.items, expected[0..]);
}

fn assertStrSlice(a: [][]const u8, b: []const []const u8) error{NotSame}!void {
    if (cmpStrSlice(a, b)) {
        return;
    } else {
        return error.NotSame;
    }
}

//TODO: use some test method here
fn cmpStrSlice(a: [][]const u8, b: []const []const u8) bool {
    if (a.len != b.len) {
        return false;
    }

    for (a) |_, i| {
        if (!std.mem.eql(u8, a[i], b[i])) {
            return false;
        }
    }

    return true;
}
