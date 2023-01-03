const std = @import("std");
const expect = @import("std").testing.expect;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

const parser = @import("./parser.zig");
const DestructError = parser.DestructError;
const Program = parser.Program;
const StringFragmentType = parser.StringFragmentType;
const compile = parser.compile;

//Set to true for debug output
const debug = false;

fn isWhitespace(c: u8) bool {
    return (c == ' ') or (c == '\t');
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
            .fun => {
                var funName = ex.fun.name;

                if (std.mem.eql(u8, "upper", funName)) {
                    var arg1 = ex.fun.args.items[0].ref;
                    var refStr = try resolveRef(program.symbols, line, arg1);
                    var refBuf = try allocator.alloc(u8, refStr.len);
                    _ = std.ascii.upperString(refBuf, refStr);
                    try ret.append(refBuf);
                } else if (std.mem.eql(u8, "first", funName)) {
                    var arg1 = ex.fun.args.items[0].ref;
                    var arg2 = ex.fun.args.items[1].ref;
                    var asInt = try std.fmt.parseInt(usize, arg2, 10);

                    var refStr = try resolveRef(program.symbols, line, arg1);
                    var result = refStr[0..asInt];
                    std.debug.print("first: '{s}' \n", .{result});
                    try ret.append(result);
                }
            },
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
        std.debug.print("\tdstr \"[a ... b]  a b \"\n", .{});
        std.debug.print("\tdstr \"[a ... b]  a b \" echo\n", .{});
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

//=========================================================================
// Functions

test "Function upper" {
    const src = "[ one two ] one.upper() two";
    const input = "aa bb";
    const expectedOutput = [_][]const u8{ "AA", "bb" };
    try quickTest(src, input, expectedOutput[0..]);
}

test "Function first" {
    const src = "[ one two ] one.first(2) two";
    const input = "aaaa bb";
    const expectedOutput = [_][]const u8{ "aa", "bb" };
    try quickTest(src, input, expectedOutput[0..]);
}
//==========================================================================
// Fails

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

    const pgm = try compile(allocator, src);
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

    _ = compile(allocator, src) catch |err| {
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
    const pgm = try compile(allocator, src);
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
    const pgm = try compile(allocator, src);
    var ret = try execLine(allocator, pgm, splatInput);
    const expected = [_][]const u8{ "aa", "strings cc" };
    try assertStrSlice(ret.items, expected[0..]);
}

fn quickTest(src: []const u8, input: []const u8, expected: []const []const u8) !void {
    var gpa = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = gpa.allocator();
    defer gpa.deinit();

    const pgm = try compile(allocator, src);
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
