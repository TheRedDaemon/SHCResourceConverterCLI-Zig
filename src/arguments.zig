const std = @import("std");
const clap = @import("clap");
const config = @import("config");
const types = @import("types.zig");
const io = @import("io.zig");

const ParsingResult = union(enum) {
    no_action: std.log.Level,
    action: struct { std.log.Level, types.CoderOptions, types.ActionArgs },
};

const semver = std.SemanticVersion.parse(config.version) catch unreachable;

const parsers = .{
    .command = clap.parsers.enumeration(types.ActionCommand),
    .log_level = clap.parsers.enumeration(std.log.Level),
    .u8 = clap.parsers.int(u8, 0),
    .argb1555 = parseArgb1555Arg,
    .str = clap.parsers.string,
};

fn parseArgb1555Arg(in: []const u8) !types.Argb1555 {
    const number = try std.fmt.parseInt(u16, in, 0);
    return @bitCast(number);
}

const main_params = clap.parseParamsComptime(std.fmt.comptimePrint(
    \\-h, --help  Display this help and exit.
    \\-v, --version  Display version information and exit.
    \\--log <log_level>  Set the log level. Possible values: {s} (default: info)
    \\--tgx-coder-transparent-pixel-tgx-color <argb1555>  Transparent pixel color used the TGX encoding. Unknown usage. (default: 0b1111100000011111)
    \\--tgx-coder-transparent-pixel-raw-color <argb1555>  Transparent pixel color used for alpha in raw data. (default: 0)
    \\--tgx-coder-pixel-repeat-threshold <u8>  Number of repeated pixels required to be considered a repeat. (default: 3)
    \\--tgx-coder-padding-alignment <u8>  Byte alignment to use for the padding. (default: 4)
    \\<command>  Actual action to perform. Possible values: {s}
    \\
,
    .{ std.meta.fieldNames(std.log.Level), std.meta.fieldNames(types.ActionCommand) },
));

const test_params = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\--print-tgx-to-text  Print a text of the TGX encoding after analysis.
    \\<str> Path to file to analyze.
    \\
);

const extract_params = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\<str> Path to file to extract.
    \\<str> Directory to extract to.
    \\
);

const pack_params = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\<str> Path to directory to pack.
    \\<str> Output path for file.
    \\
);

/// Parses received args.
/// If an action is returned, the ActionArgs need to be deinitialized.
pub fn parseArgs(allocator: std.mem.Allocator) !ParsingResult {
    var iter = try std.process.ArgIterator.initWithAllocator(allocator);
    defer iter.deinit();

    return internalParseArgs(allocator, &iter);
}

fn internalParseArgs(allocator: std.mem.Allocator, arg_iterator_ptr: anytype) !ParsingResult {
    // remove exe name
    _ = arg_iterator_ptr.next();

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(
        clap.Help,
        &main_params,
        parsers,
        arg_iterator_ptr,
        .{
            .diagnostic = &diag,
            .allocator = allocator,
            .terminating_positional = 0,
        },
    ) catch |err| {
        try writeClapDiagnostic(diag, err);
        return err;
    };
    defer res.deinit();

    const log_level = res.args.log orelse .info;
    if (res.args.help != 0) {
        try writeClapHelp(&main_params);
        return .{ .no_action = log_level };
    }

    if (res.args.version != 0) {
        io.stderr(true, "{}\n", .{semver});
        return .{ .no_action = log_level };
    }

    if (res.positionals[0] == null) {
        try writeClapUsage(&main_params);
        return .{ .no_action = log_level };
    }

    const action_args = try switch (res.positionals[0].?) {
        .@"test" => parseTestArgs(allocator, arg_iterator_ptr),
        .extract => parseExtractArgs(allocator, arg_iterator_ptr),
        .pack => parsePackArgs(allocator, arg_iterator_ptr),
    };
    if (action_args == null) {
        return .{ .no_action = log_level };
    }
    errdefer action_args.?.deinit(allocator);

    return .{
        .action = .{
            log_level,
            .{
                .transparent_pixel_tgx_color = res.args.@"tgx-coder-transparent-pixel-tgx-color" orelse types.default_game_transparent_color,
                .transparent_pixel_raw_color = res.args.@"tgx-coder-transparent-pixel-raw-color" orelse types.default_tgx_file_transparent,
                .pixel_repeat_threshold = res.args.@"tgx-coder-pixel-repeat-threshold" orelse types.default_tgx_file_pixel_repeat_threshold,
                .padding_alignment = res.args.@"tgx-coder-padding-alignment" orelse types.default_tgx_file_padding_alignment,
            },
            action_args.?,
        },
    };
}

fn parseTestArgs(allocator: std.mem.Allocator, arg_iterator_ptr: anytype) !?types.ActionArgs {
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(
        clap.Help,
        &test_params,
        parsers,
        arg_iterator_ptr,
        .{
            .diagnostic = &diag,
            .allocator = allocator,
        },
    ) catch |err| {
        try writeClapDiagnostic(diag, err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try writeClapHelp(&test_params);
        return null;
    }

    if (res.positionals[0] == null) {
        try writeClapUsage(&test_params);
        return null;
    }

    const file_in = try allocator.dupe(u8, res.positionals[0].?);
    errdefer allocator.free(file_in);

    return .{
        .@"test" = .{
            .print_tgx_to_text = res.args.@"print-tgx-to-text" != 0,
            .file_in = file_in,
        },
    };
}

fn parseExtractArgs(allocator: std.mem.Allocator, arg_iterator_ptr: anytype) !?types.ActionArgs {
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(
        clap.Help,
        &extract_params,
        parsers,
        arg_iterator_ptr,
        .{
            .diagnostic = &diag,
            .allocator = allocator,
        },
    ) catch |err| {
        try writeClapDiagnostic(diag, err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try writeClapHelp(&extract_params);
        return null;
    }

    if (res.positionals[0] == null or res.positionals[1] == null) {
        try writeClapUsage(&extract_params);
        return null;
    }

    const file_in = try allocator.dupe(u8, res.positionals[0].?);
    errdefer allocator.free(file_in);
    const dir_out = try allocator.dupe(u8, res.positionals[1].?);
    errdefer allocator.free(dir_out);

    return .{
        .extract = .{
            .file_in = file_in,
            .dir_out = dir_out,
        },
    };
}

fn parsePackArgs(allocator: std.mem.Allocator, arg_iterator_ptr: anytype) !?types.ActionArgs {
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(
        clap.Help,
        &pack_params,
        parsers,
        arg_iterator_ptr,
        .{
            .diagnostic = &diag,
            .allocator = allocator,
        },
    ) catch |err| {
        try writeClapDiagnostic(diag, err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try writeClapHelp(&pack_params);
        return null;
    }

    if (res.positionals[0] == null or res.positionals[1] == null) {
        try writeClapUsage(&pack_params);
        return null;
    }

    const dir_in = try allocator.dupe(u8, res.positionals[0].?);
    errdefer allocator.free(dir_in);
    const file_out = try allocator.dupe(u8, res.positionals[1].?);
    errdefer allocator.free(file_out);

    return .{
        .pack = .{
            .dir_in = dir_in,
            .file_out = file_out,
        },
    };
}

fn writeClapDiagnostic(diag: clap.Diagnostic, err: anyerror) !void {
    diag.report(io.getStdErr(), err) catch std.log.err("Unable to write failure .", .{});
    io.flushErr();
}

fn writeClapHelp(params: []const clap.Param(clap.Help)) !void {
    try clap.help(io.getStdErr(), clap.Help, params, .{});
    io.stderr(true, "\n", .{});
}

fn writeClapUsage(params: []const clap.Param(clap.Help)) !void {
    try clap.usage(io.getStdErr(), clap.Help, params);
    io.stderr(true, "\n", .{});
}

// TODO: fix tests

test "fail argument parsing" {
    const arg_str = "exe tet"; // misspelled command
    var arg_iter = std.mem.splitSequence(u8, arg_str, " ");
    const args = internalParseArgs(std.testing.allocator, &arg_iter);
    const has_error = if (args) |_| false else |_| true;
    try std.testing.expect(has_error);
}

test "call without command" {
    const arg_str = "exe --version";
    var arg_iter = std.mem.splitSequence(u8, arg_str, " ");
    const args = try internalParseArgs(std.testing.allocator, &arg_iter);
    switch (args) {
        .no_action => try std.testing.expect(true),
        else => try std.testing.expect(false),
    }
}

test "call with all command" {
    const test_result: ParsingResult = .{
        .action = .{
            .debug,
            .{
                .action = .@"test",
                .print_tgx_to_text = true,
                .tgx_coder_transparent_pixel_tgx_color = .{ .a = 1, .r = 31, .g = 31, .b = 0 },
                .tgx_coder_transparent_pixel_raw_color = .{ .a = 1, .r = 31, .g = 31, .b = 0 },
                .tgx_coder_pixel_repeat_threshold = 2,
                .tgx_coder_padding_alignment = 2,
            },
        },
    };

    const arg_str = std.fmt.comptimePrint(
        "exe " ++
            "--log={s} {s} --print-tgx-to-text " ++
            "--tgx-coder-transparent-pixel-tgx-color 0b{b} " ++
            "--tgx-coder-transparent-pixel-raw-color 0b{b}" ++
            " --tgx-coder-pixel-repeat-threshold {d} --tgx-coder-padding-alignment {d}",
        .{
            comptime std.enums.tagName(std.log.Level, test_result.action.@"0").?,
            comptime std.enums.tagName(types.ActionCommand, test_result.action.@"1".action).?,
            @as(u16, @bitCast(test_result.action.@"1".tgx_coder_transparent_pixel_tgx_color)),
            @as(u16, @bitCast(test_result.action.@"1".tgx_coder_transparent_pixel_raw_color)),
            test_result.action.@"1".tgx_coder_pixel_repeat_threshold,
            test_result.action.@"1".tgx_coder_padding_alignment,
        },
    );
    var arg_iter = std.mem.splitSequence(u8, arg_str, " ");
    const args = try internalParseArgs(std.testing.allocator, &arg_iter);
    switch (args) {
        .action => try std.testing.expectEqualDeep(test_result, args),
        else => try std.testing.expect(false),
    }
}
