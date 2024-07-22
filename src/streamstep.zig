const std = @import("std");
const runtime = @import("runtime.zig");
const debug = false;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const AstNode = runtime.AstNode;
const DestructError = runtime.DestructError;
const RefMap = runtime.RefMap;
const resolvePrimitiveValue = runtime.resolvePrimitiveValue;
const resolveCharsValue = runtime.resolveCharsValue;

pub const StreamStepType = enum { collect, systemOut, exec, filter, eval, skip, first };
pub const StreamStep = union(StreamStepType) {
    collect: CollectStep,
    systemOut: SystemOutStep,
    exec: ExecStep,
    filter: FilterStep,
    eval: EvalStep,
    skip: SkipStep,
    first: FirstStep,
    pub fn accept(self: *StreamStep, line_allocator: Allocator, line: [][]const u8) DestructError!bool {
        return switch (self.*) {
            .collect => try self.collect.accept(line),
            .systemOut => try self.systemOut.accept(line),
            .exec => try self.exec.accept(line),
            .filter => try self.filter.accept(line_allocator, line),
            .eval => try self.eval.accept(line_allocator, line),
            .skip => try self.skip.accept(line_allocator, line),
            .first => try self.first.accept(line_allocator, line),
        };
    }
};

pub const FilterStep = struct {
    next: *StreamStep,
    predicates: []const AstNode,
    refMap: []const RefMap,

    pub fn accept(self: FilterStep, line_allocator: Allocator, line: [][]const u8) DestructError!bool {
        for (self.predicates) |pred| {
            const p = (try resolvePrimitiveValue(line_allocator, self.refMap, line, pred)).toBool();

            if (!p) {
                return true;
            }
        }

        return try self.next.accept(line_allocator, line);
    }
};

pub const SkipStep = struct {
    next: *StreamStep,
    skipCount: i64,

    pub fn accept(self: *SkipStep, line_allocator: Allocator, line: [][]const u8) DestructError!bool {
        if (self.skipCount > 0) {
            self.skipCount -= 1;
            return true;
        } else {
            return try self.next.accept(line_allocator, line);
        }
    }
};

pub const FirstStep = struct {
    next: *StreamStep,
    count: i64,

    pub fn accept(self: *FirstStep, line_allocator: Allocator, line: [][]const u8) DestructError!bool {
        if (self.count > 0) {
            self.count -= 1;
            return try self.next.accept(line_allocator, line);
        } else {
            return false;
        }
    }
};

pub const EvalStep = struct {
    next: *StreamStep,
    expressions: []const AstNode,
    refMap: []const RefMap,

    pub fn accept(self: EvalStep, line_allocator: Allocator, line: [][]const u8) DestructError!bool {
        var ret = ArrayList([]const u8).init(line_allocator);
        for (self.expressions) |pred| {
            const p = try resolveCharsValue(line_allocator, self.refMap, line, pred);

            try ret.append(p);
        }

        return try self.next.accept(line_allocator, ret.items);
    }
};

pub const SystemOutStep = struct {
    writer: std.fs.File,

    pub fn accept(self: SystemOutStep, line: [][]const u8) DestructError!bool {
        for (line, 0..) |o, i| {
            if (i != 0) self.writer.writer().writeAll(" ") catch |err| {
                if (err == error.BrokenPipe) {
                    return DestructError.StreamClosed;
                } else {
                    return DestructError.undefined;
                }
            };

            self.writer.writer().writeAll(o) catch |err| {
                if (err == error.BrokenPipe) {
                    return DestructError.StreamClosed;
                } else {
                    return DestructError.undefined;
                }
            };
        }
        self.writer.writer().writeAll("\n") catch |err| {
            if (err == error.BrokenPipe) {
                return DestructError.StreamClosed;
            } else {
                return DestructError.undefined;
            }
        };
        return true;
    }
};

pub const ExecStep = struct {
    allocator: Allocator,
    cmd: []const u8,

    pub fn accept(self: ExecStep, line: [][]const u8) !bool {
        var cmdLine = ArrayList([]const u8).init(self.allocator);
        try cmdLine.append(self.cmd);
        try cmdLine.appendSlice(line);
        var cp = std.process.Child.init(cmdLine.items, self.allocator);
        _ = cp.spawnAndWait() catch {
            std.debug.print("Failed to execute '{s}'\n", .{self.cmd});
            std.process.exit(1);
        };
        return true;
    }
};

pub const CollectStep = struct {
    items: ArrayList([][]const u8),

    pub fn accept(self: *CollectStep, line: [][]const u8) !bool {
        try self.items.append(line);
        return true;
    }
};
