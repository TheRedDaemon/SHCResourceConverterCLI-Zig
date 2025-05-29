const std = @import("std");
const clap = @import("clap");
const config = @import("config");
const types = @import("../types.zig");
const io = @import("../io/out.zig");

const ParsingResult = union(enum) {
    no_action: std.log.Level,
    action: struct { std.log.Level, types.CoderOptions, types.ActionArgs },
};

const semver = std.SemanticVersion.parse(config.version) catch unreachable;

const parsers = .{
    .command = clap.parsers.enumeration(types.ActionCommand),
    .log_level = clap.parsers.enumeration(std.log.Level),
    .u8 = clap.parsers.int(u8, 0),
    .threshold = clap.parsers.int(u5, 0),
    .argb1555 = parseArgb1555Arg,
    .str = clap.parsers.string,
};

fn parseArgb1555Arg(in: []const u8) !types.Argb1555 {
    const number = try std.fmt.parseInt(u16, in, 0);
    return @bitCast(number);
}

fn parsePixelRepeatThreshold(in: []const u8) !u8 {
    const number = try std.fmt.parseInt(u8, in, 0);
    return if (number > 32) error.InvalidPixelRepeatThreshold else @bitCast(number);
}

const main_params = clap.parseParamsComptime(std.fmt.comptimePrint(
    \\-h, --help  Display this help and exit.
    \\-v, --version  Display version information and exit.
    \\--log <log_level>  Set the log level. Possible values: {s} (default: info)
    \\--transparent-pixel-tgx-color <argb1555>  Transparent pixel color used the TGX encoding. Unknown usage. (default: 0b1111100000011111)
    \\--transparent-pixel-raw-color <argb1555>  Transparent pixel color used for alpha in raw data. (default: 0)
    \\--transparent-pixel-fill-index <u8>  Color index used for index images if the pixel is transparent. (default: 0)
    \\--grid-pixel-raw-color <argb1555>  Pixel color used to draw a grid in raw data for certain types. (default: 0b1000000000000000)
    \\--grid-pixel-fill-index <u8>  Color index used for index images to fill a grid for certain types. (default: 0)
    \\--pixel-repeat-threshold <threshold>  Number of repeated pixels required to be considered a repeat. (default: 3)
    \\--padding-alignment <u8>  Byte alignment to use for the padding. (default: 4)
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
                .transparent_pixel_tgx_color = res.args.@"transparent-pixel-tgx-color" orelse types.CoderOptions.default.transparent_pixel_tgx_color,
                .transparent_pixel_raw_color = res.args.@"transparent-pixel-raw-color" orelse types.CoderOptions.default.transparent_pixel_raw_color,
                .transparent_pixel_fill_index = res.args.@"transparent-pixel-fill-index" orelse types.CoderOptions.default.transparent_pixel_fill_index,
                .grid_pixel_raw_color = res.args.@"grid-pixel-raw-color" orelse types.CoderOptions.default.grid_pixel_raw_color,
                .grid_pixel_fill_index = res.args.@"grid-pixel-fill-index" orelse types.CoderOptions.default.grid_pixel_fill_index,
                .pixel_repeat_threshold = res.args.@"pixel-repeat-threshold" orelse types.CoderOptions.default.pixel_repeat_threshold,
                .padding_alignment = res.args.@"padding-alignment" orelse types.CoderOptions.default.padding_alignment,
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

test "call command without complete subcommand" {
    const arg_str = "exe test";
    var arg_iter = std.mem.splitSequence(u8, arg_str, " ");
    const args = try internalParseArgs(std.testing.allocator, &arg_iter);
    switch (args) {
        .no_action => try std.testing.expect(true),
        else => try std.testing.expect(false),
    }
}

test "call command for extract" {
    const expected_action_args: types.ActionArgs = .{
        .extract = .{
            .file_in = "test.tgx",
            .dir_out = "test",
        },
    };

    const action_tag_name = comptime std.enums.tagName(types.ActionCommand, std.meta.activeTag(expected_action_args)).?;
    const arg_str = std.fmt.comptimePrint(
        "exe {s} {s} {s}",
        .{
            action_tag_name,
            @field(expected_action_args, action_tag_name).file_in,
            @field(expected_action_args, action_tag_name).dir_out,
        },
    );
    var arg_iter = std.mem.splitSequence(u8, arg_str, " ");
    const args = try internalParseArgs(std.testing.allocator, &arg_iter);
    switch (args) {
        .action => |*result| {
            const action_args = &result.@"2";
            defer action_args.deinit(std.testing.allocator);
            try std.testing.expectEqualDeep(&expected_action_args, action_args);
        },
        else => try std.testing.expect(false),
    }
}

test "call command for pack" {
    const expected_action_args: types.ActionArgs = .{
        .pack = .{
            .dir_in = "test",
            .file_out = "test.tgx",
        },
    };

    const action_tag_name = comptime std.enums.tagName(types.ActionCommand, std.meta.activeTag(expected_action_args)).?;
    const arg_str = std.fmt.comptimePrint(
        "exe {s} {s} {s}",
        .{
            action_tag_name,
            @field(expected_action_args, action_tag_name).dir_in,
            @field(expected_action_args, action_tag_name).file_out,
        },
    );
    var arg_iter = std.mem.splitSequence(u8, arg_str, " ");
    const args = try internalParseArgs(std.testing.allocator, &arg_iter);
    switch (args) {
        .action => |*result| {
            const action_args = &result.@"2";
            defer action_args.deinit(std.testing.allocator);
            try std.testing.expectEqualDeep(&expected_action_args, action_args);
        },
        else => try std.testing.expect(false),
    }
}

test "call command for test with all parameters" {
    const expected_result: ParsingResult = .{
        .action = .{
            .debug,
            .{
                .transparent_pixel_tgx_color = .{ .a = 1, .r = 31, .g = 31, .b = 0 },
                .transparent_pixel_raw_color = .{ .a = 1, .r = 31, .g = 31, .b = 0 },
                .transparent_pixel_fill_index = 0b11111111,
                .pixel_repeat_threshold = 2,
                .padding_alignment = 2,
            },
            .{
                .@"test" = .{
                    .print_tgx_to_text = true,
                    .file_in = "test.tgx",
                },
            },
        },
    };

    const action_tag_name = comptime std.enums.tagName(types.ActionCommand, std.meta.activeTag(expected_result.action.@"2")).?;
    const arg_str = std.fmt.comptimePrint(
        "exe --log={s} " ++
            "--transparent-pixel-tgx-color 0b{b} " ++
            "--transparent-pixel-raw-color 0b{b} " ++
            "--transparent-pixel-fill-index 0b{b} " ++
            "--pixel-repeat-threshold {d} --padding-alignment {d} " ++
            "{s} --print-tgx-to-text {s}",
        .{
            comptime std.enums.tagName(std.log.Level, expected_result.action.@"0").?,
            @as(u16, @bitCast(expected_result.action.@"1".transparent_pixel_tgx_color)),
            @as(u16, @bitCast(expected_result.action.@"1".transparent_pixel_raw_color)),
            expected_result.action.@"1".transparent_pixel_fill_index,
            expected_result.action.@"1".pixel_repeat_threshold,
            expected_result.action.@"1".padding_alignment,
            action_tag_name,
            @field(expected_result.action.@"2", action_tag_name).file_in,
        },
    );
    var arg_iter = std.mem.splitSequence(u8, arg_str, " ");
    const args = try internalParseArgs(std.testing.allocator, &arg_iter);
    switch (args) {
        .action => |*result| {
            defer result.@"2".deinit(std.testing.allocator);
            try std.testing.expectEqualDeep(&expected_result, &args);
        },
        else => try std.testing.expect(false),
    }
}
