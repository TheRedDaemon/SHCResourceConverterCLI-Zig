const std = @import("std");
const io = @import("io.zig");

pub const std_options: std.Options = .{
    .logFn = logFn,
    .log_level = .debug,
};

var log_level = std.log.default_level;
pub fn setLogLevel(level: std.log.Level) void {
    log_level = level;
}

fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(message_level) > @intFromEnum(log_level)) {
        return;
    }

    // taken from structure of std.log.log_default
    const level_txt = comptime blk: {
        const text = message_level.asText();
        var buf: [text.len]u8 = undefined;
        break :blk std.ascii.upperString(&buf, text);
    };

    const scope_txt = comptime if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ";
    io.stderr(true, level_txt ++ " | " ++ scope_txt ++ format ++ "\n", args);
}

pub fn logAsJson(comptime message_level: std.log.Level, allocator: std.mem.Allocator, value: anytype) void {
    if (@intFromEnum(message_level) > @intFromEnum(log_level)) {
        return;
    }
    const json = std.json.stringifyAlloc(
        allocator,
        value,
        .{ .whitespace = .indent_2 },
    ) catch |err| {
        std.log.err("Failed to log json: {s}", .{@errorName(err)});
        return;
    };
    defer allocator.free(json);
    logFn(message_level, .default, "{s}:\n{s}", .{ @typeName(@TypeOf(value)), json });
}
