const std = @import("std");

var stdout_writer: ?std.fs.File.Writer = null;
pub fn getStdOut() std.fs.File.Writer {
    if (stdout_writer) |writer| {
        return writer;
    } else {
        stdout_writer = std.io.getStdOut().writer();
        return stdout_writer.?;
    }
}

pub fn stdout(comptime format: []const u8, args: anytype) void {
    getStdOut().print(format, args) catch std.log.err("Unable to write to stdout.", .{});
}

var stderr_writer: ?std.fs.File.Writer = null;
pub fn getStdErr() std.fs.File.Writer {
    if (stderr_writer) |writer| {
        return writer;
    } else {
        stderr_writer = std.io.getStdErr().writer();
        return stderr_writer.?;
    }
}

pub fn stderr(comptime format: []const u8, args: anytype) void {
    getStdErr().print(format, args) catch std.log.err("Unable to write to stderr.", .{});
}
