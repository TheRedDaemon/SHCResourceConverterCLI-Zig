const std = @import("std");

const clap = @import("clap");
const config = @import("config");

const types = @import("types.zig");

// log handling placed here, to allow directly setting the log level
// source: https://ziggit.dev/t/set-debug-level-at-runtime/6196/4

pub const std_options: std.Options = .{
    .logFn = LogSupport.logFn,
    .log_level = .debug,
};

const LogSupport = struct {
    var log_level = std.log.default_level;

    fn logFn(
        comptime message_level: std.log.Level,
        comptime scope: @TypeOf(.enum_literal),
        comptime format: []const u8,
        args: anytype,
    ) void {
        if (@intFromEnum(message_level) <= @intFromEnum(log_level)) {
            std.log.defaultLog(message_level, scope, format, args);
        }
    }
};

// start of actual argument handling

const ActionCommand = enum {
    @"test",
    extract,
    pack,
};

const parsers = .{
    .command = clap.parsers.enumeration(ActionCommand),
    .log_level = clap.parsers.enumeration(std.log.Level),
    .u8 = clap.parsers.int(u8, 0),
    .bool = parseBoolArg,
    .argb1555 = parseArgb1555Arg,
};

fn parseBoolArg(in: []const u8) !bool {
    if (std.mem.eql(u8, in, "true")) {
        return true;
    } else if (std.mem.eql(u8, in, "false")) {
        return false;
    } else {
        return error.InvalidBool;
    }
}

fn parseArgb1555Arg(in: []const u8) !types.Argb1555 {
    const number = try std.fmt.parseInt(u16, in, 0);
    return @bitCast(number);
}

const params = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\-v, --version  Display version information and exit.
    \\--log <log_level>  Set the log level.
    \\<command>
    \\--print-tgx-to-text <bool>  Print a text of the TGX encoding after analysis.
    \\--tgx-coder-transparent-pixel-tgx-color <argb1555>  
    \\--tgx-coder-transparent-pixel-raw-color <argb1555> 
    \\--tgx-coder-pixel-repeat-threshold <u8>  Number of repeated pixels required to be considered a repeat.
    \\--tgx-coder-padding-alignment <u8>  Alignment to use for the padding.
    \\
);

pub const Args = struct {
    action: ActionCommand,
};

pub fn parseArgs(allocator: std.mem.Allocator) !?Args {
    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, parsers, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        diag.report(.{ .print = printErrorToLog }, err) catch std.log.err("Unable to write failure .", .{});
        return err;
    };
    defer res.deinit();

    // if (res.args.help != 0)
    //     std.debug.print("--help\n", .{});
    // if (res.args.number) |n|
    //     std.debug.print("--number = {}\n", .{n});
    // if (res.args.answer) |a|
    //     std.debug.print("--answer = {s}\n", .{@tagName(a)});
    // for (res.args.string) |s|
    //     std.debug.print("--string = {s}\n", .{s});
    // for (res.positionals[0]) |pos|
    //     std.debug.print("{s}\n", .{pos});

    return null;
}

fn printErrorToLog(comptime format: []const u8, args: anytype) !void {
    std.log.err(format, args);
}
