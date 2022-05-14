const std = @import("std");
const expect = @import("std").testing.expect;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

//Set to true for debug output
const debug = true;

const DestructError = error {
  anon_ref, unknown_ref, missing_input, space_in_interpolation
};

const Mode = enum {
  START, ARG_LIST, ARG_NAME,
  EX_LIST, EX_NAME, EX_SQT_STR, EX_SQT_REF, EX_SQT_ESC
};

const AstNodeType = enum {
  string, ref
};

const StringFragmentType = enum {
  chars, ref
};

const ExName = struct {
  name: []const u8, type: AstNodeType
};

const AstNode = union(AstNodeType) {
  ref: []const u8,
  string: ArrayList(AstStringFragment)
};

const AstStringFragment = struct {
  type: StringFragmentType,
  chars: []const u8
};

const Program = struct {
  symbols: ArrayList([]const u8),
  ex: ArrayList(AstNode)
};

fn isWhitespace(c: u8) bool {
  return (c == ' ') or (c == '\t');
}

fn compile(allocator: Allocator, source: [] const u8) !Program {
  var symbols = ArrayList([]const u8).init(allocator);
  var ex = ArrayList(AstNode).init(allocator);
  var stringFragments: ArrayList(AstStringFragment) = undefined;
  //Parser FSM
  var mode = Mode.START;
  var readPos: usize  = 0;

  for (source) |c, i| {
    if(debug) std.debug.print("{d}: {c}  {s}\n", .{i, c, mode});

    switch(mode) {
      Mode.START => {
        if(c == '['){
          mode = Mode.ARG_LIST;
        }
      },
      Mode.ARG_LIST => {
        if(c == ']'){
          mode = Mode.EX_LIST;
        } else if(!isWhitespace(c)){
          mode = Mode.ARG_NAME;
          readPos = i;
        }
      },
      Mode.ARG_NAME => {
        if(c == ']'){
          mode = Mode.EX_LIST;
          const slz = source[readPos..i];
          try symbols.append(slz);

        } else if(isWhitespace(c)){
          mode = Mode.ARG_LIST;
          const slz = source[readPos..i];
          try symbols.append(slz);
        }
      },
      Mode.EX_LIST => {
        if('\'' == c){
          //Enter quoted string mode
          mode = Mode.EX_SQT_STR;
          readPos = i +1; 
          stringFragments = ArrayList(AstStringFragment).init(allocator);
        } else if (!isWhitespace(c)){
          mode = Mode.EX_NAME;
          readPos = i;
        }
      },
      Mode.EX_NAME => {
        if(isWhitespace(c)){
          mode = Mode.EX_LIST;
          const slz = source[readPos..i];
          try ex.append(AstNode{.ref = slz});
          readPos = i;
        }
      },
      Mode.EX_SQT_STR => {
        if(c == '\''){
          mode = Mode.EX_LIST;
          const slz = source[readPos..i];
          try stringFragments.append(AstStringFragment{.type = StringFragmentType.chars, .chars = slz});
          try ex.append(AstNode{.string = stringFragments});
          stringFragments = undefined;
        } else if (c == '{') {
          mode = Mode.EX_SQT_REF;
          const slz = source[readPos..i];
          try stringFragments.append(AstStringFragment{.type = StringFragmentType.chars, .chars = slz});
          readPos = i + 1;
        } else if (c == '\\') {
          mode = Mode.EX_SQT_ESC;
          const slz = source[readPos..i];
          try stringFragments.append(AstStringFragment{.type = StringFragmentType.chars, .chars = slz});
          readPos = i + 1;
        }
      },
      Mode.EX_SQT_REF => {
        if(c == '}') {
          mode = Mode.EX_SQT_STR;
          const slz = source[readPos..i];
          try stringFragments.append(AstStringFragment{.type = StringFragmentType.ref, .chars = slz});
          readPos = i + 1;
        } else if(c == ' ') {
          return DestructError.space_in_interpolation;
        }
      },
      Mode.EX_SQT_ESC => {
        mode = Mode.EX_SQT_STR;
      }
    }
  }
  //Cleanup last token
  if(mode == Mode.EX_NAME){
    const slz = source[readPos..];
    try ex.append(AstNode{.ref = slz});
  } else if (mode == Mode.EX_SQT_STR) {
    //TODO: maybe do something?
  }

  return Program{.symbols = symbols, .ex = ex};
}

const CsvMode = enum {
  START, WORD
};

fn splitInput(allocator: Allocator, input: []const u8) !ArrayList([]const u8) {
  var ret = ArrayList([]const u8).init(allocator);
  var startPos: usize = 0;
  var mode = CsvMode.START;

  for (input) |c, i| {
    switch(mode) {
      CsvMode.START => {
        if (!isWhitespace(c)) {
          mode = CsvMode.WORD;
          startPos = i;
        }
      },
      CsvMode.WORD => {
        if (isWhitespace(c)) {
          mode = CsvMode.START;
          try ret.append(input[startPos..i]);
        }
      }
    }
  }

  if(mode == CsvMode.WORD){
    try ret.append(input[startPos..]);
  }
  return ret;
}

fn resolveRef(symbols: ArrayList([]const u8), line: ArrayList([]const u8), ref: []const u8) ![]const u8 {
  var offset: i64 = 0;

  const isUnderScore = std.mem.eql(u8, ref, "_");
  if(isUnderScore) {
    //Fail when trying to resolve '_' ref
    return DestructError.anon_ref;
  }

  for(symbols.items) |sym, si| {
    const isSame = std.mem.eql(u8, sym, ref);
    const dotDotDot = std.mem.eql(u8, sym, "...");
    if (debug) std.debug.print("Resolving ref Sym: '{s}' Ref: '{s}' IsSame: '{s}'\n", .{sym, ref, isSame});
    if(dotDotDot){
      //TODO? is line.items.len = 1 a special case?
      const symLeft = @intCast(i64, symbols.items.len) - @intCast(i64, si) - 1;
      offset = @intCast(i64, line.items.len) - symLeft -1 - @intCast(i64, si);
    } else if (isSame){
      const finalOffset = @intCast(i64,si) + offset;
      if((finalOffset >= line.items.len) or (finalOffset < 0) ) {
        return DestructError.missing_input;
      }
      return line.items[@intCast(usize, finalOffset)];
    }
  }
  std.debug.print("\nFailed to resolve ref \"{s}\"\n", .{ref});
  return DestructError.unknown_ref;
}

fn execLine(allocator: Allocator, program: Program, line: ArrayList([]const u8)) !ArrayList([] const u8) {
  var ret = ArrayList([] const u8).init(allocator);

  for(program.ex.items) |ex| {
    switch(ex){
      .string => {
        var strBuf = std.ArrayList(u8).init(allocator);
        for(ex.string.items) |fragment| {
          switch(fragment.type) {
            StringFragmentType.chars => {
              //std.debug.print("{s}\n", .{fragment.chars});
              try strBuf.appendSlice(fragment.chars);
            },
            StringFragmentType.ref => {
              //Resolve str ref
              var refStr = try resolveRef(program.symbols, line, fragment.chars);
              //std.debug.print("{s}\n", .{refStr});
              try strBuf.appendSlice(refStr);
            }
          }
        }
        try ret.append(strBuf.items);
      },
      .ref => {
          var refStr = try resolveRef(program.symbols, line, ex.ref);
          //std.debug.print("{s}\n", .{refStr});
          try ret.append(refStr);
        }
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
  var lineArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
  var lineAllocator = lineArena.allocator();
  defer lineArena.deinit();

  //Process args
  var args = try std.process.argsAlloc(allocator);
  defer std.process.argsFree(allocator, args);
  if(debug) {
    for (args) |a| {
      std.debug.print("arg: {s}\n", .{a});
    }
  }

  if((args.len < 2) or (args.len > 3)) {
    std.debug.print("Please invoke using: \n", .{});
    std.debug.print("\t./dstr [expression]\n", .{});
    std.debug.print("\t./dstr [expression] [executable] or\n\n", .{});
    std.debug.print("Example:\n", .{});
    std.debug.print("\tdstr \"[a .. b]  a b \"\n", .{});
    std.debug.print("\tdstr \"[a .. b]  a b \" echo\n", .{});
    std.os.exit(1);
  }


  const src = args[1];
  const pgm = try compile(allocator, src);

  //Read system in
  const stdin = std.io.getStdIn().reader();
  var input: ?[]u8  = try stdin.readUntilDelimiterOrEofAlloc(lineAllocator, '\n', 4096);


  const stdout = std.io.getStdOut();

  while(input) |in|{
    const splatInput = try splitInput(lineAllocator, in);
    var ret = try execLine(lineAllocator, pgm, splatInput);
    //std.debug.print("Woha: {s}\n", .{ret});

    if(args.len == 2) {
      //Echo mode
      for (ret.items) |o| {
        try stdout.writer().writeAll(o);
      }    
      try stdout.writer().writeAll("\n");
    } else {
      //Exec mode
      var cmdLine = ArrayList([] const u8).init(lineAllocator);
      try cmdLine.append(args[2]);
      try cmdLine.appendSlice(ret.items);
      const cp = try std.ChildProcess.init(cmdLine.items, lineAllocator);
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
  const src = "[ one ... two ]   two ' ' 'says {one} aswell' ";
  const input = "hello a b c malte";
  const expectedOutput = [_][]const u8{"malte", " ", "says hello aswell"};
  try quickTest(src, input, expectedOutput[0..]);
}

test "Ellipsis and string interpolation2" {
  const src = "[ one ... two ] two ' says {one} aswell' ";
  const input = "hello a b c malte";
  const expectedOutput = [_][]const u8{"malte", " says hello aswell"};
  try quickTest(src, input, expectedOutput[0..]);
}

test "Ellipsis 2 args" {
  const src = "[ one ... two ] one two";
  const input = "AA BB";
  const expectedOutput = [_][]const u8{"AA", "BB"};
  try quickTest(src, input, expectedOutput[0..]);
}

test "Ellipsis 4 args" {
  const src = "[ one two ... three four ] one two three four";
  const input = "AA BB xx CC DD";
  const expectedOutput = [_][]const u8{"AA", "BB", "CC", "DD"};
  try quickTest(src, input, expectedOutput[0..]);
}

test "Leading Ellipsis" {
  const src = "[ ... one two ] one two";
  const input = "AA BB";
  const expectedOutput = [_][]const u8{"AA", "BB"};
  try quickTest(src, input, expectedOutput[0..]);
}


test "Param skipping" {
  const src = "[ one ... _ two ]   one two";
  const input = "hello a b c malte";
  const expectedOutput = [_][]const u8{"hello", "malte"};
  try quickTest(src, input, expectedOutput[0..]);
}

test "Param skipping 2" {
  const src = "[ one _  _ two ] one two";
  const input = "aa bb cc dd";
  const expectedOutput = [_][]const u8{"aa", "dd"};
  try quickTest(src, input, expectedOutput[0..]);
}

test "Escaping characters" {
  const src = "[ one _  _ ] one 'look \\'at\\' me'";
  const input = "aa bb cc";
  const expectedOutput = [_][]const u8{"aa", "look 'at' me"};
  try quickTest(src, input, expectedOutput[0..]);
}

test "Escaping characters2" {
  const src = "[ one _  _ ] one 'look \\'at\\' me'";
  const input = "aa bb cc";
  const expectedOutput = [_][]const u8{"aa", "look 'at' me"};
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

fn quickTest(src: []const u8, input: []const u8, expected: [] const [] const u8) !void{

  var gpa = std.heap.ArenaAllocator.init(std.heap.page_allocator);
  const allocator = gpa.allocator();
  defer gpa.deinit();

  const pgm = try compile(allocator, src);
  const splatInput = try splitInput(allocator, input);
  var ret = try execLine(allocator, pgm, splatInput);
  //std.debug.print("{s}", .{ret});
  try assertStrSlice(ret.items, expected[0..]);
}

fn assertStrSlice(a: [][]const u8, b: []const []const u8) error{NotSame}!void {
  if(cmpStrSlice(a,b)){
    return;
  } else {
    return error.NotSame;
  }
}

//TODO: use some test method here
fn cmpStrSlice(a: [][]const u8, b: []const []const u8) bool {
  if(a.len != b.len) {
    return false;
  }

  for(a) |_, i| {
    if(!std.mem.eql(u8, a[i], b[i])){
      return false;
    }
  }

  return true;
}
