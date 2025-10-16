const std = @import("std");
const runtime = @import("runtime.zig");
const debug = false;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const AstNode = runtime.AstNode;
const DestructError = runtime.DestructError;
const RefMap = runtime.RefMap;
const ScopeDef = runtime.ScopeDef;
const resolvePrimitiveValue = runtime.resolvePrimitiveValue;
const resolveCharsValue = runtime.resolveCharsValue;

pub const StreamStepType = enum { collect, systemOut, exec, filter, eval, skip, first, let, sort };
pub const StreamStep = union(StreamStepType) {
    collect: CollectStep,
    systemOut: SystemOutStep,
    exec: ExecStep,
    filter: FilterStep,
    eval: EvalStep,
    skip: SkipStep,
    first: FirstStep,
    let: LetStep,
    sort: SortStep,
    pub fn accept(self: *StreamStep, line_allocator: Allocator, refMap: []const RefMap, line: [][]const u8) DestructError!bool {
        return switch (self.*) {
            .collect => try self.collect.accept(line),
            .systemOut => try self.systemOut.accept(line),
            .exec => try self.exec.accept(line),
            .filter => try self.filter.accept(line_allocator, refMap, line),
            .eval => try self.eval.accept(line_allocator, refMap, line),
            .skip => try self.skip.accept(line_allocator, refMap, line),
            .first => try self.first.accept(line_allocator, refMap, line),
            .let => try self.let.accept(line_allocator, refMap, line),
            .sort => try self.sort.accept(line_allocator, refMap, line),
        };
    }
    pub fn stop(self: *StreamStep, line_allocator: Allocator) DestructError!void {
        return switch (self.*) {
            .collect => try self.collect.stop(),
            .systemOut => try self.systemOut.stop(),
            .exec => try self.exec.stop(),
            .filter => try self.filter.stop(line_allocator),
            .eval => try self.eval.stop(line_allocator),
            .skip => try self.skip.stop(line_allocator),
            .first => try self.first.stop(line_allocator),
            .let => try self.let.stop(line_allocator),
            .sort => try self.sort.stop(line_allocator),
        };
    }
};

const StreamStepFactory = *const fn () DestructError!*StreamStep;
pub const StreamStepItem = struct {
    name: []const u8,
    factory: StreamStepFactory,
};

const streamSteps = []StreamStepItem{
    StreamStepItem{ .name = "filter", .factory = FilterStep.factory },
};

pub const FilterStep = struct {
    next: *StreamStep,
    predicates: []const AstNode,

    pub fn factory(programAllocator: Allocator, argList: []AstNode, nextStep: *StreamStep) DestructError!*StreamStep {
        const ret = try programAllocator.create(StreamStep);
        ret.* = .{
            .filter = FilterStep{
                .next = nextStep,
                .predicates = argList,
            },
        };
        return ret;
    }

    pub fn accept(self: FilterStep, line_allocator: Allocator, refMap: []const RefMap, line: [][]const u8) DestructError!bool {
        for (self.predicates) |pred| {
            const p = (try resolvePrimitiveValue(line_allocator, refMap, line, pred)).toBool();

            if (!p) {
                return true;
            }
        }

        return try self.next.accept(line_allocator, refMap, line);
    }

    pub fn stop(self: *FilterStep, line_allocator: Allocator) DestructError!void {
        try self.next.stop(line_allocator);
    }
};

pub const SkipStep = struct {
    next: *StreamStep,
    skipCount: i64,

    pub fn factory(programAllocator: Allocator, argList: []AstNode, nextStep: *StreamStep) DestructError!*StreamStep {
        const ret = try programAllocator.create(StreamStep);
        ret.* = .{
            .skip = SkipStep{ .next = nextStep, .skipCount = argList.items[0].int },
        };
        return ret;
    }

    pub fn accept(self: *SkipStep, line_allocator: Allocator, refMap: []const RefMap, line: [][]const u8) DestructError!bool {
        if (self.skipCount > 0) {
            self.skipCount -= 1;
            return true;
        } else {
            return try self.next.accept(line_allocator, refMap, line);
        }
    }
    pub fn stop(self: *SkipStep, line_allocator: Allocator) DestructError!void {
        try self.next.stop(line_allocator);
    }
};

pub const FirstStep = struct {
    next: *StreamStep,
    count: i64,

    pub fn factory(programAllocator: Allocator, argList: []AstNode, nextStep: *StreamStep) DestructError!*StreamStep {
        const ret = try programAllocator.create(StreamStep);
        ret.* = .{
            .first = FirstStep{
                .next = nextStep,
                .count = argList.items[0].int,
            },
        };
        return ret;
    }

    pub fn accept(self: *FirstStep, line_allocator: Allocator, refMap: []const RefMap, line: [][]const u8) DestructError!bool {
        if (self.count > 0) {
            self.count -= 1;
            return try self.next.accept(line_allocator, refMap, line);
        } else {
            return false;
        }
    }

    pub fn stop(self: *FirstStep, line_allocator: Allocator) DestructError!void {
        try self.next.stop(line_allocator);
    }
};

pub const LetStep = struct {
    next: *StreamStep,
    scopeDefs: []const ScopeDef,

    pub fn factory(programAllocator: Allocator, argList: []AstNode, nextStep: *StreamStep) DestructError!*StreamStep {
        const ret = try programAllocator.create(StreamStep);
        ret.* = .{ .let = LetStep{
            .next = nextStep,
            .scopeDefs = argList[0].scopeDefs,
        } };
        return ret;
    }

    pub fn accept(self: *LetStep, line_allocator: Allocator, refMap: []const RefMap, line: [][]const u8) DestructError!bool {
        var outLine = try line_allocator.alloc([]const u8, self.scopeDefs.len);
        var outrefs = try line_allocator.alloc(RefMap, self.scopeDefs.len);
        for (self.scopeDefs, 0..) |sd, i| {
            outrefs[i] = RefMap{ .name = sd.sym, .offset = @intCast(i) };
            const p = try resolveCharsValue(line_allocator, refMap, line, sd.node);
            outLine[i] = p;
        }

        return self.next.accept(line_allocator, outrefs, outLine);
    }
    pub fn stop(self: *LetStep, line_allocator: Allocator) DestructError!void {
        try self.next.stop(line_allocator);
    }
};

pub const SortStep = struct {
    next: *StreamStep,
    sortBy: AstNode,
    programAllocator: Allocator,
    bufferedInput: ArrayList(SortStorage),

    const SortStorage = struct {
        refMap: []const RefMap,
        line: [][]const u8,
    };

    const SortRef = struct {
        value: []const u8,
        index: usize,
    };

    pub fn factory(programAllocator: Allocator, argList: []AstNode, nextStep: *StreamStep) DestructError!*StreamStep {
        const ret = try programAllocator.create(StreamStep);
        ret.* = .{ .sort = SortStep{
            .programAllocator = programAllocator,
            .next = nextStep,
            .sortBy = argList[0],
            .bufferedInput = ArrayList(SortStorage).empty,
        } };
        return ret;
    }

    pub fn accept(self: *SortStep, _: Allocator, refMap: []const RefMap, line: [][]const u8) DestructError!bool {
        var lineBuff = try self.programAllocator.alloc([]const u8, line.len);

        for (line, 0..) |itm, i| {
            //Copy lineData to program Arena
            const newItm = try self.programAllocator.alloc(u8, itm.len);
            std.mem.copyForwards(u8, newItm, line[i]);
            lineBuff[i] = newItm;
        }

        const ss = SortStorage{
            .refMap = refMap,
            .line = lineBuff,
        };

        try self.bufferedInput.append(self.programAllocator, ss);

        return true; // self.next.accept(line_allocator, outrefs, outLine);
    }

    fn sortFun(_: void, a: SortRef, b: SortRef) bool {
        return std.mem.lessThan(u8, a.value, b.value);
    }

    pub fn stop(self: *SortStep, line_allocator: Allocator) DestructError!void {
        var sortRefs = try line_allocator.alloc(SortRef, self.bufferedInput.items.len);
        for (self.bufferedInput.items, 0..) |b, i| {
            const sortVal = try resolveCharsValue(line_allocator, b.refMap, b.line, self.sortBy);
            sortRefs[i] = SortRef{
                .value = sortVal,
                .index = i,
            };
        }
        std.sort.block(SortRef, sortRefs, {}, sortFun);
        for (sortRefs) |s| {
            const i = self.bufferedInput.items[s.index];
            if (!try self.next.accept(line_allocator, i.refMap, i.line)) {
                break;
            }
        }
        try self.next.stop(line_allocator);
    }
};

pub const EvalStep = struct {
    next: *StreamStep,
    expressions: []const AstNode,

    pub fn accept(self: EvalStep, line_allocator: Allocator, refMap: []const RefMap, line: [][]const u8) DestructError!bool {
        var ret = ArrayList([]const u8).empty;
        for (self.expressions) |pred| {
            const p = try resolveCharsValue(line_allocator, refMap, line, pred);

            try ret.append(line_allocator, p);
        }

        return try self.next.accept(line_allocator, refMap, ret.items);
    }
    pub fn stop(self: *EvalStep, line_allocator: Allocator) DestructError!void {
        try self.next.stop(line_allocator);
    }
};

pub const SystemOutStep = struct {
    writer: std.fs.File,

    pub fn accept(self: SystemOutStep, line: [][]const u8) DestructError!bool {
        for (line, 0..) |o, i| {
            if (i != 0) {
                _ = self.writer.write(" ") catch |err| {
                    if (err == error.BrokenPipe) {
                        return DestructError.StreamClosed;
                    } else {
                        return DestructError.undefined;
                    }
                };
            }
            _ = self.writer.write(o) catch |err| {
                if (err == error.BrokenPipe) {
                    return DestructError.StreamClosed;
                } else {
                    return DestructError.undefined;
                }
            };
        }
        _ = self.writer.write("\n") catch |err| {
            if (err == error.BrokenPipe) {
                return DestructError.StreamClosed;
            } else {
                return DestructError.undefined;
            }
        };
        return true;
    }
    pub fn stop(_: *SystemOutStep) DestructError!void {}
};

pub const ExecStep = struct {
    allocator: Allocator,
    cmd: []const u8,

    pub fn accept(self: ExecStep, line: [][]const u8) !bool {
        var cmdLine = ArrayList([]const u8).empty;
        try cmdLine.append(self.allocator, self.cmd);
        try cmdLine.appendSlice(self.allocator, line);
        var cp = std.process.Child.init(cmdLine.items, self.allocator);
        _ = cp.spawnAndWait() catch {
            std.debug.print("Failed to execute '{s}'\n", .{self.cmd});
            std.process.exit(1);
        };
        return true;
    }

    pub fn stop(_: *ExecStep) DestructError!void {}
};

pub const CollectStep = struct {
    allocator: Allocator,
    items: ArrayList([][]const u8),

    pub fn accept(self: *CollectStep, line: [][]const u8) !bool {
        try self.items.append(self.allocator, line);
        return true;
    }
    pub fn stop(_: *CollectStep) DestructError!void {}
};
