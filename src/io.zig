const std = @import("std");

// found not other way but explicitly set type
const BufferedWriter = std.io.BufferedWriter(4096, std.fs.File.Writer);

var stdout_buffered_writer: ?BufferedWriter = null;
pub fn getStdOut() BufferedWriter.Writer {
    if (stdout_buffered_writer) |*buffered_writer| {
        return buffered_writer.writer();
    } else {
        stdout_buffered_writer = std.io.bufferedWriter(std.io.getStdOut().writer());
        return stdout_buffered_writer.?.writer();
    }
}

pub fn stdout(comptime flush: bool, comptime format: []const u8, args: anytype) void {
    getStdOut().print(format, args) catch @panic("Unable to write to stdout.");
    if (flush) {
        flushOut();
    }
}

pub fn flushOut() void {
    if (stdout_buffered_writer) |*buffered_writer| {
        buffered_writer.flush() catch @panic("Unable to flush stdout.");
    }
}

var stderr_buffered_writer: ?BufferedWriter = null;
pub fn getStdErr() BufferedWriter.Writer {
    if (stderr_buffered_writer) |*buffered_writer| {
        return buffered_writer.writer();
    } else {
        stderr_buffered_writer = std.io.bufferedWriter(std.io.getStdErr().writer());
        return stderr_buffered_writer.?.writer();
    }
}

pub fn stderr(comptime flush: bool, comptime format: []const u8, args: anytype) void {
    getStdErr().print(format, args) catch @panic("Unable to write to stderr.");
    if (flush) {
        flushErr();
    }
}

pub fn flushErr() void {
    if (stderr_buffered_writer) |*buffered_writer| {
        buffered_writer.flush() catch @panic("Unable to flush stderr.");
    }
}
