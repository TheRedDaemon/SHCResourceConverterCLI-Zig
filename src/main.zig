//! A simple CLI to support analysis of SHC files.

const std = @import("std");
const builtin = @import("builtin");
const arguments = @import("io/arguments.zig");
const logging = @import("io/logging.zig");
const types = @import("types.zig");
const out = @import("io/out.zig");

const TgxFile = @import("TgxFile.zig");
const Gm1File = @import("Gm1File.zig");

const FileType = enum { tgx, gm1 };

pub const std_options = logging.std_options;

// external to easier set log level
pub fn main() void {
    runWithAllocator(anyerror!void, internalMain) catch |err| std.log.err("Unhandled error: {s}", .{@errorName(err)});
}

/// Run a param less function with an allocator depending on the build type.
/// The allocator might be de-initialized after the function returns,
/// however, all allocations and frees need to be handled by the user.
fn runWithAllocator(comptime R: type, comptime func: fn (allocator: std.mem.Allocator) R) R {
    var allocator_handle = switch (builtin.mode) {
        .Debug => std.heap.DebugAllocator(.{}).init,
        else => std.heap.ArenaAllocator.init(std.heap.page_allocator),
    };
    defer switch (builtin.mode) {
        .Debug => if (allocator_handle.deinit() != .ok) @panic("Memory leak detected!"),
        else => allocator_handle.deinit(),
    };
    return switch (@typeInfo(R)) {
        .error_union => try func(allocator_handle.allocator()),
        else => func(allocator_handle.allocator()),
    };
}

fn internalMain(allocator: std.mem.Allocator) !void {
    const result = arguments.parseArgs(allocator) catch |err| {
        std.log.err("Failed to parse arguments: {s}", .{@errorName(err)});
        return;
    };
    const log_level, const coder_options, const action_args = switch (result) {
        .no_action => |level| {
            logging.setLogLevel(level);
            std.log.debug("Requested actionless print actions. Ending process.", .{});
            return;
        },
        .action => result.action,
    };
    defer action_args.deinit(allocator);
    logging.setLogLevel(log_level);

    if (logging.logEnabled(.debug)) {
        logging.logAsJson(.debug, allocator, .{
            .log_level = log_level,
            .coder_options = coder_options,
            .action_args = action_args,
        });
    }

    switch (action_args) {
        .@"test" => |*args| validateFile(
            allocator,
            args.file_in,
            args.print_tgx_to_text,
            &coder_options,
        ) catch |err| {
            std.log.err("Failed to validate file {s}: {s}", .{ args.file_in, @errorName(err) });
        },
        .extract => |*args| extractFile(
            allocator,
            args.file_in,
            args.dir_out,
            &coder_options,
        ) catch |err| {
            std.log.err("Failed to extract file {s} to {s}: {s}", .{ args.file_in, args.dir_out, @errorName(err) });
        },
        .pack => |*args| packFile(
            allocator,
            args.dir_in,
            args.file_out,
            &coder_options,
        ) catch |err| {
            std.log.err("Failed to pack {s} to file {s}: {s}", .{ args.dir_in, args.file_out, @errorName(err) });
        },
    }
}

fn validateFile(
    allocator: std.mem.Allocator,
    file_in: []const u8,
    print_tgx_to_text: bool,
    options: *const types.CoderOptions,
) !void {
    const file_type = try determineFileType(file_in);
    switch (file_type) {
        .tgx => {
            var tgx = try TgxFile.loadFile(allocator, file_in);
            defer tgx.deinit(allocator);
            try tgx.validate(options);
            if (print_tgx_to_text) {
                try tgx.writeEncodedToText(options, out.getStdOut());
                out.flushOut();
            }
        },
        .gm1 => {
            var gm1 = try Gm1File.loadFile(allocator, file_in);
            defer gm1.deinit(allocator);
            try gm1.validate(options);
            if (print_tgx_to_text) {
                try gm1.writeEncodedToText(options, out.getStdOut());
                out.flushOut();
            }
        },
    }
}

fn extractFile(
    allocator: std.mem.Allocator,
    file_in: []const u8,
    dir_out: []const u8,
    options: *const types.CoderOptions,
) !void {
    const file_type = try determineFileType(file_in);
    switch (file_type) {
        .tgx => {
            var tgx = try TgxFile.loadFile(allocator, file_in);
            defer tgx.deinit(allocator);
            try tgx.saveAsRaw(allocator, dir_out, options);
        },
        .gm1 => {
            var gm1 = try Gm1File.loadFile(allocator, file_in);
            defer gm1.deinit(allocator);
            try gm1.saveAsRaw(allocator, dir_out, options);
        },
    }
}

fn packFile(
    allocator: std.mem.Allocator,
    dir_in: []const u8,
    file_out: []const u8,
    options: *const types.CoderOptions,
) !void {
    const file_type = try determineFileType(file_out);
    switch (file_type) {
        .tgx => {
            var tgx = try TgxFile.loadFromRaw(allocator, dir_in, options);
            defer tgx.deinit(allocator);
            try tgx.saveFile(file_out);
        },
        .gm1 => {
            var gm1 = try Gm1File.loadFromRaw(allocator, dir_in, options);
            defer gm1.deinit(allocator);
            //try gm1.saveFile(file_out);
        },
    }
}

fn determineFileType(filename: []const u8) !FileType {
    const extension = std.fs.path.extension(filename);
    if (std.mem.eql(u8, extension, ".tgx")) {
        return .tgx;
    } else if (std.mem.eql(u8, extension, ".gm1")) {
        return .gm1;
    } else {
        return error.UnknownFileExtension;
    }
}

// currently required to run tests in all imported files
// see: https://github.com/ziglang/zig/issues/16349
test {
    std.testing.refAllDecls(@This());
}
