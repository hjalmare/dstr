const std = @import("std");
const expect = @import("std").testing.expect;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

const builtin = @import("./builtin.zig");
const DestructError = builtin.DestructError;
const Program = builtin.Program;
const AstFun = builtin.AstFun;
const AstNode = builtin.AstNode;
const resolveCharsValue = builtin.resolveCharsValue;

const parser = @import("./parser.zig");
const compile = parser.compile;

//Set to true for debug output
const debug = false;
const VERSION = @embedFile("VERSION.txt");

fn isWhitespace(c: u8) bool {
    return (c == ' ') or (c == '\t');
}

//Space Separated String
const SssMode = enum { START, WORD };

fn splitInput(allocator: Allocator, input: []const u8) ![][]const u8 {
    var ret = ArrayList([]const u8).init(allocator);
    var startPos: usize = 0;
    var mode = SssMode.START;

    for (input, 0..) |c, i| {
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
    return ret.items;
}

fn splitSegments(allocator: Allocator, segments: []const builtin.SegmentNode, input: []const u8) ![][]const u8 {
    var ret = ArrayList([]const u8).init(allocator);
    var start: usize = 0;

    var wasRef = false;

    for (segments) |seg| {
        switch (seg) {
            .chars => {
                if (debug) {
                    std.debug.print("Entry: '{any}' Chars '{s}'\n", .{ start, seg.chars });
                }
                const cIndex = std.mem.indexOf(u8, input[start..], seg.chars) orelse return DestructError.missing_input;
                const inSlice = input[start..(start + cIndex)];
                if (wasRef and !std.mem.eql(u8, "_", inSlice)) {
                    try ret.append(inSlice);
                    if (debug) {
                        std.debug.print("Was Ref:{any} {any} {s}\n", .{ start, cIndex, input[start..(start + cIndex)] });
                    }
                }
                start = start + cIndex + seg.chars.len;
                if (debug) {
                    std.debug.print("Chars Start:{any} {s}\n", .{ start, seg.chars });
                }
                wasRef = false;
            },
            .ref => {
                wasRef = true;
            },
        }
    }

    const inSlice = input[start..];
    if (wasRef and !std.mem.eql(u8, "_", inSlice)) {
        try ret.append(inSlice);
        if (debug) {
            std.debug.print("Trailing ref Ref: {any} {s}\n", .{ start, inSlice });
        }
    }

    return ret.items;
}

fn execLine(allocator: Allocator, program: Program, line: [][]const u8) !ArrayList([]const u8) {
    var ret = ArrayList([]const u8).init(allocator);

    for (program.ex.items) |ex| {
        try ret.append(try resolveCharsValue(allocator, program.refMap, line, ex));
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
        std.debug.print("dstr version: {s}\n", .{VERSION});

        std.debug.print("Please invoke using: \n", .{});
        std.debug.print("\t./dstr [expression]\n", .{});
        std.debug.print("\t./dstr [expression] [executable]\n", .{});
        std.debug.print("\nExample:\n", .{});
        std.debug.print("\tdstr \"[a ... b]  a b \"\n", .{});
        std.debug.print("\tdstr \"[a ... b]  a b \" echo\n", .{});

        std.debug.print("\nReference:\n", .{});
        std.debug.print("\t\"[\" binding+ \"]\" output+\n", .{});
        std.debug.print("\tbinding       = varname | elipsis | ignore\n", .{});
        std.debug.print("\tvarname       = \\w+\n", .{});
        std.debug.print("\tellipsis      = \"...\"\n", .{});
        std.debug.print("\tignore        = \"_\"\n", .{});
        std.debug.print("\toutput        = ref | string\n", .{});
        std.debug.print("\tref           = \\w+\n", .{});
        std.debug.print("\tstring        = \"'\" {{text | interpolation}}* \"'\"\n", .{});
        std.debug.print("\tinterpolation = {{ref}}\n", .{});

        std.os.exit(1);
    }

    const src = args[1];
    //Read system in
    var stdinBuff = std.io.bufferedReader(std.io.getStdIn().reader());
    var stdin = stdinBuff.reader();
    //TODO; This method of reading stdin seems very slow
    var input: ?[]u8 = try stdin.readUntilDelimiterOrEofAlloc(lineAllocator, '\n', 4096);

    const stdout = std.io.getStdOut();

    const stream: builtin.StreamStep = if (args.len == 2) builtin.StreamStep{ .systemOut = builtin.SystemOutStep{ .writer = stdout } } else builtin.StreamStep{ .exec = builtin.ExecStep{ .allocator = lineAllocator, .cmd = args[2] } };

    const pgm = compile(allocator, src, &stream) catch {
        std.os.exit(1);
    };

    while (input) |in| {
        const splatInput = switch (pgm.input) {
            .positional => try splitInput(lineAllocator, in),
            .segments => try splitSegments(allocator, pgm.input.segments, in),
        };

        var ret = execLine(lineAllocator, pgm, splatInput) catch {
            std.os.exit(1);
        };

        try stream.accept(ret.items);
        //Reset allocator and read a new line of input
        _ = lineArena.reset(std.heap.ArenaAllocator.ResetMode.retain_capacity);

        input = try stdin.readUntilDelimiterOrEofAlloc(lineAllocator, '\n', 4096);
    }
}

test "segment.input.single.mid" {
    const input = "0123456789";
    const src = "'01{a}456789' a";
    const expectedOutput = [_][]const u8{"23"};
    try quickTest(src, input, expectedOutput[0..]);
}

test "segment.input.single.start" {
    const input = "0123456789";
    const src = "'{a}23456789' a";
    const expectedOutput = [_][]const u8{"01"};
    try quickTest(src, input, expectedOutput[0..]);
}

test "segment.input.single.end" {
    const input = "0123456789";
    const src = "'01234567{a}' a";
    const expectedOutput = [_][]const u8{"89"};
    try quickTest(src, input, expectedOutput[0..]);
}

test "segment.input.single.all" {
    const input = "0123456789";
    const src = "'{a}' a";
    const expectedOutput = [_][]const u8{"0123456789"};
    try quickTest(src, input, expectedOutput[0..]);
}

test "segment.input.double.all" {
    const input = "0123456789";
    const src = "'{a}3456{b}9' a b";
    const expectedOutput = [_][]const u8{ "012", "78" };
    try quickTest(src, input, expectedOutput[0..]);
}

test "segment.input.double.skip" {
    const input = "0123456789";
    const src = "'{_}3456{a}9' a";
    const expectedOutput = [_][]const u8{"78"};
    try quickTest(src, input, expectedOutput[0..]);
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

test "Escaping characters3" {
    const src = "[_] str('\\t' 't')";
    const input = "aa bb cc";
    const expectedOutput = [_][]const u8{"\tt"};
    try quickTest(src, input, expectedOutput[0..]);
}

test "String interpolation" {
    const src = "[ one _  _ ] '{one}-{one}'";
    const input = "aa bb cc";
    const expectedOutput = [_][]const u8{"aa-aa"};
    try quickTest(src, input, expectedOutput[0..]);
}

test "String interpolation last" {
    const src = "[ one ] '{one}' one";
    const input = "aa";
    const expectedOutput = [_][]const u8{ "aa", "aa" };
    try quickTest(src, input, expectedOutput[0..]);
}

test "String nested interpolation" {
    const src = "[ one ] upper('{one}')";
    const input = "aa";
    const expectedOutput = [_][]const u8{"AA"};
    try quickTest(src, input, expectedOutput[0..]);
}

test "String nested interpolation2" {
    const src = "[ one ] upper('{upper(one)}')";
    const input = "aa";
    const expectedOutput = [_][]const u8{"AA"};
    try quickTest(src, input, expectedOutput[0..]);
}

test "String nested interpolation3" {
    const src = "[ one ] upper('{ upper( one ) }')";
    const input = "aa";
    const expectedOutput = [_][]const u8{"AA"};
    try quickTest(src, input, expectedOutput[0..]);
}

test "String interpolation with spaces" {
    const src = "[ one _  _ ] '{ one}-{one }'";
    const input = "aa bb cc";
    const expectedOutput = [_][]const u8{"aa-aa"};
    try quickTest(src, input, expectedOutput[0..]);
}

//=========================================================================
// Streams

test "stream.filter.match" {
    const src = "[a].filter(a.startsWith('a')) a";
    const input = "aa";

    const expectedOutput = [_][]const u8{"aa"};
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

test "Function chaining" {
    const src = "[ one two ] one.first(2).upper() two";
    const input = "aaaa bb";
    const expectedOutput = [_][]const u8{ "AA", "bb" };
    try quickTest(src, input, expectedOutput[0..]);
}

test "Function chaining 3x" {
    const src = "[ one two ] first(one 2).upper().upper()";
    const input = "aaaa bb";
    const expectedOutput = [_][]const u8{"AA"};
    try quickTest(src, input, expectedOutput[0..]);
}

test "Function chaining 4x" {
    const src = "[ one two ] one.first(2).rpad(4 two.first(2))";
    const input = "aaaa bb";
    const expectedOutput = [_][]const u8{"aabb"};
    try quickTest(src, input, expectedOutput[0..]);
}

test "Function nested" {
    const src = "[ one two ] first(upper(one) 2) two";
    const input = "aaaa bb";
    const expectedOutput = [_][]const u8{ "AA", "bb" };
    try quickTest(src, input, expectedOutput[0..]);
}

test "Function nested 2" {
    const src = "[ one two ] if(one.startsWith('b') '' first(one 2)).upper()";
    const input = "aaaa bb";
    const expectedOutput = [_][]const u8{"AA"};
    try quickTest(src, input, expectedOutput[0..]);
}

test "Function in string" {
    const src = "[ one two ] 'a{one.upper()}a' two";
    const input = "aa bb";
    const expectedOutput = [_][]const u8{ "aAAa", "bb" };
    try quickTest(src, input, expectedOutput[0..]);
}

test "Function string as arg" {
    const src = "[ _ two ] upper('a') two";
    const input = "aa bb";
    const expectedOutput = [_][]const u8{ "A", "bb" };
    try quickTest(src, input, expectedOutput[0..]);
}

test "Function string as arg spaces" {
    const src = "[ _ two ] upper( 'a' ) two";
    const input = "aa bb";
    const expectedOutput = [_][]const u8{ "A", "bb" };
    try quickTest(src, input, expectedOutput[0..]);
}
//==========================================================================
// Fails

test "Fail on missing input" {
    const src = "[ one two three] one two three";
    const input = "aa bb";
    try failTest(src, input, DestructError.missing_input);
}

test "Fail on non alpha ref" {
    const src = "[ one two 3hree] one two three";
    try failCompile(src, DestructError.ref_non_alpha);
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
    try failTest(src, input, DestructError.unexpected_char);
}

fn soutStream() builtin.StreamStep {
    const stdout = std.io.getStdOut();
    return builtin.StreamStep{ .systemOut = builtin.SystemOutStep{ .writer = stdout } };
}

fn failTest(src: []const u8, input: []const u8, expected_error: DestructError) !void {
    var gpa = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = gpa.allocator();
    defer gpa.deinit();

    const pgm = compile(allocator, src, &soutStream()) catch |err| {
        try expect(err == expected_error);
        return;
    };
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

    _ = compile(allocator, src, &soutStream()) catch |err| {
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
    const pgm = try compile(allocator, src, &soutStream());
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
    const pgm = try compile(allocator, src, &soutStream());
    var ret = try execLine(allocator, pgm, splatInput);
    const expected = [_][]const u8{ "aa", "strings cc" };
    try assertStrSlice(ret.items, expected[0..]);
}

fn quickTest(src: []const u8, input: []const u8, expected: []const []const u8) !void {
    var gpa = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = gpa.allocator();
    defer gpa.deinit();

    const pgm = try compile(allocator, src, &soutStream());
    const splatInput = switch (pgm.input) {
        .positional => try splitInput(allocator, input),
        .segments => try splitSegments(allocator, pgm.input.segments, input),
    };
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
        std.debug.print("These ar not the same len  {any} {any}\n", .{ a.len, b.len });
        return false;
    }

    for (a, 0..) |_, i| {
        if (!std.mem.eql(u8, a[i], b[i])) {
            std.debug.print("These are not eq: '{s}' '{s}' \n", .{ a[i], b[i] });
            return false;
        }
    }

    return true;
}
