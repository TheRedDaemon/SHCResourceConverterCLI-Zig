const std = @import("std");
const types = @import("types.zig");
const out = @import("io/out.zig");
const tgx_coder = @import("coder/tgx_coder.zig");

pub const tgx_extension = ".tgx";

const tgx_header_size = @sizeOf(u32) * 2;

const Self = @This();

width: u32,
height: u32,
encoded_stream: types.EncodedTgxStream,

pub fn init(allocator: std.mem.Allocator, file_path: []const u8) !Self {
    std.log.info("Loading file: {s}", .{file_path});
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        std.log.err("Could not open file: {s}", .{@errorName(err)});
        return err;
    };
    defer file.close();

    const size = (try file.stat()).size;
    if (tgx_header_size > size) {
        return error.FileTooSmallForTgx;
    }

    const reader = file.reader();
    const width = try reader.readInt(u32, .little);
    const height: u32 = try reader.readInt(u32, .little);

    const size_of_data = size - tgx_header_size;
    const data = try allocator.alloc(u8, size_of_data);
    var encoded_stream = types.EncodedTgxStream.take(data);
    errdefer encoded_stream.deinit(allocator);

    _ = try reader.read(data);

    std.log.info("Loaded file: {s}", .{file_path});
    return .{
        .width = width,
        .height = height,
        .encoded_stream = encoded_stream,
    };
}

pub fn validate(self: *const Self, options: *const types.CoderOptions) !void {
    const writer = out.getStdErr();
    defer out.flushErr();

    try writer.print("Validating...", .{});
    out.flushErr();

    const analysis = tgx_coder.analyze(
        types.Argb1555,
        &self.encoded_stream,
        self.width,
        self.height,
        options,
        null,
    ) catch |err| {
        try writer.print("FAILED: {s}\n", .{@errorName(err)});
        return;
    };
    try writer.print("SUCCESS\n", .{});
    out.flushErr();

    try std.json.stringify(&analysis, .{ .whitespace = .indent_2 }, writer);
}

pub fn writeEncodedToText(self: *const Self, options: *const types.CoderOptions, writer: anytype) anyerror!void {
    _ = try tgx_coder.analyze(
        types.Argb1555,
        &self.encoded_stream,
        self.width,
        self.height,
        options,
        writer,
    );
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    self.encoded_stream.deinit(allocator);
}
