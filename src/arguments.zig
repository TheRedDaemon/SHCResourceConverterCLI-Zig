const std = @import("std");

const clap = @import("clap");
const config = @import("config");

const types = @import("types.zig");

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

const Args = struct {
    log_level: std.log.Level,
    action: types.ActionCommand,
    print_tgx_to_text: bool,
    tgx_coder_transparent_pixel_tgx_color: types.Argb1555,
    tgx_coder_transparent_pixel_raw_color: types.Argb1555,
    tgx_coder_pixel_repeat_threshold: u8,
    tgx_coder_padding_alignment: u8,
};

pub fn parseArgs(allocator: std.mem.Allocator) !Args {
    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, parsers, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        diag.report(.{ .print = printErrorToLog }, err) catch std.log.err("Unable to write failure .", .{});
        return err;
    };
    defer res.deinit();

    // TODO: version and help

    const action = res.positionals[0] orelse .@"test"; // TODO: return error.MissingAction;
    return .{
        .log_level = res.args.log orelse .info,
        .action = action,
        .print_tgx_to_text = res.args.@"print-tgx-to-text" orelse false,
        .tgx_coder_transparent_pixel_tgx_color = res.args.@"tgx-coder-transparent-pixel-tgx-color" orelse types.default_game_transparent_color,
        .tgx_coder_transparent_pixel_raw_color = res.args.@"tgx-coder-transparent-pixel-raw-color" orelse types.default_tgx_file_transparent,
        .tgx_coder_pixel_repeat_threshold = res.args.@"tgx-coder-pixel-repeat-threshold" orelse types.default_tgx_file_pixel_repeat_threshold,
        .tgx_coder_padding_alignment = res.args.@"tgx-coder-padding-alignment" orelse types.default_tgx_file_padding_alignment,
    };
}

fn printErrorToLog(comptime format: []const u8, args: anytype) !void {
    std.log.err(format, args);
}
