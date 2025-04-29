const std = @import("std");
const clap = @import("clap");
const config = @import("config");
const types = @import("types.zig");
const io = @import("io.zig");

const ParsingResult = union(enum) {
    no_action: std.log.Level,
    action: struct { std.log.Level, Args },
};

const Args = struct {
    action: types.ActionCommand,
    print_tgx_to_text: bool,
    tgx_coder_transparent_pixel_tgx_color: types.Argb1555,
    tgx_coder_transparent_pixel_raw_color: types.Argb1555,
    tgx_coder_pixel_repeat_threshold: u8,
    tgx_coder_padding_alignment: u8,
};

const semver = std.SemanticVersion.parse(config.version) catch unreachable;

const params = clap.parseParamsComptime(std.fmt.comptimePrint(
    \\-h, --help  Display this help and exit.
    \\-v, --version  Display version information and exit.
    \\--log <log_level>  Set the log level. Possible values: {s} (default: info)
    \\<command>  Actual action to perform. Possible values: {s}
    \\--print-tgx-to-text <bool>  Print a text of the TGX encoding after analysis. (default: false)
    \\--tgx-coder-transparent-pixel-tgx-color <argb1555>  Transparent pixel color used the TGX encoding. Unknown usage. (default: 0b1111100000011111)
    \\--tgx-coder-transparent-pixel-raw-color <argb1555>  Transparent pixel color used for alpha in raw data. (default: 0)
    \\--tgx-coder-pixel-repeat-threshold <u8>  Number of repeated pixels required to be considered a repeat. (default: 3)
    \\--tgx-coder-padding-alignment <u8>  Byte alignment to use for the padding. (default: 4)
    \\
,
    .{ std.meta.fieldNames(std.log.Level), std.meta.fieldNames(types.ActionCommand) },
));

const parsers = .{
    .command = clap.parsers.enumeration(types.ActionCommand),
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

pub fn parseArgs(allocator: std.mem.Allocator) !ParsingResult {
    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, parsers, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        diag.report(io.getStdErr(), err) catch std.log.err("Unable to write failure .", .{});
        return err;
    };
    defer res.deinit();

    const log_level = res.args.log orelse .info;
    if (res.args.help != 0) {
        try clap.help(io.getStdErr(), clap.Help, &params, .{});
        return .{ .no_action = log_level };
    }

    if (res.args.version != 0) {
        io.stderr("{}", .{semver});
        return .{ .no_action = log_level };
    }

    if (res.positionals[0] == null) {
        try clap.usage(io.getStdErr(), clap.Help, &params);
        return .{ .no_action = log_level };
    }

    return .{
        .action = .{
            log_level,
            .{
                .action = res.positionals[0].?,
                .print_tgx_to_text = res.args.@"print-tgx-to-text" orelse false,
                .tgx_coder_transparent_pixel_tgx_color = res.args.@"tgx-coder-transparent-pixel-tgx-color" orelse types.default_game_transparent_color,
                .tgx_coder_transparent_pixel_raw_color = res.args.@"tgx-coder-transparent-pixel-raw-color" orelse types.default_tgx_file_transparent,
                .tgx_coder_pixel_repeat_threshold = res.args.@"tgx-coder-pixel-repeat-threshold" orelse types.default_tgx_file_pixel_repeat_threshold,
                .tgx_coder_padding_alignment = res.args.@"tgx-coder-padding-alignment" orelse types.default_tgx_file_padding_alignment,
            },
        },
    };
}

// TODO: parsing test
