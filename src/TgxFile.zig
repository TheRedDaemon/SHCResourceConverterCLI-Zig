const std = @import("std");
const types = @import("types.zig");
const out = @import("io/out.zig");
const tgx_coder = @import("coder/tgx_coder.zig");

const TgxHeader = struct {
    width: u32,
    height: u32,
};

const TgxResource = struct {
    color_size: usize,
    alpha_size: usize,
    tgx_header: TgxHeader,
};

pub const tgx_extension = ".tgx";

const resource_file_name = "resource.json";
const color_file_name = "color.data";
const alpha_file_name = "alpha.data";

const tgx_header_size = @sizeOf(u32) * 2;

const Self = @This();

tgx_header: TgxHeader,
encoded_stream: types.EncodedTgxStream,

pub fn loadFile(allocator: std.mem.Allocator, file_path: []const u8) !Self {
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
        .tgx_header = .{
            .width = width,
            .height = height,
        },
        .encoded_stream = encoded_stream,
    };
}

pub fn saveFile(self: *const Self, file_path: []const u8) !void {
    std.log.info("Saving file: {s}", .{file_path});
    if (!std.mem.eql(std.fs.path.extension(file_path), tgx_extension)) {
        return error.InvalidFileExtension;
    }

    const file = std.fs.cwd().createFile(file_path, .{}) catch |err| {
        std.log.err("Could not create file: {s}", .{@errorName(err)});
        return err;
    };
    defer file.close();

    const writer = file.writer();
    try writer.write(u32, self.width, .little);
    try writer.writeInt(u32, self.height, .little);
    try writer.writeAll(self.encoded_stream.getEncodedData());

    std.log.info("Saved file: {s}", .{file_path});
}

pub fn saveAsRaw(self: *const Self, allocator: std.mem.Allocator, directory_path: []const u8, options: *const types.CoderOptions) !void {
    std.log.info("Saving to folder: {s}", .{directory_path});

    var decoding_result = tgx_coder.decode(
        types.Argb1555,
        allocator,
        &self.encoded_stream,
        self.tgx_header.width,
        self.tgx_header.height,
        options,
    ) catch |err| {
        std.log.err("Could not decode: {s}", .{@errorName(err)});
        return err;
    };
    defer decoding_result.deinit(allocator);

    var dir = std.fs.cwd().makeOpenPath(directory_path, .{}) catch |err| {
        std.log.err("Could not create directory: {s}", .{@errorName(err)});
        return err;
    };
    defer dir.close();

    const color = try decoding_result.getRawData(types.Argb1555);
    const alpha = decoding_result.getRawTransparency();

    {
        const resource_file = dir.createFile(resource_file_name, .{}) catch |err| {
            std.log.err("Could not create resource file: {s}", .{@errorName(err)});
            return err;
        };
        defer resource_file.close();
        try std.json.stringify(&TgxResource{
            .tgx_header = self.tgx_header,
            .color_size = color.len * @sizeOf(std.meta.Child(@TypeOf(color))),
            .alpha_size = alpha.len * @sizeOf(std.meta.Child(@TypeOf(alpha))),
        }, .{ .whitespace = .indent_2 }, resource_file.writer());
    }

    {
        const color_file = dir.createFile(color_file_name, .{}) catch |err| {
            std.log.err("Could not create color file: {s}", .{@errorName(err)});
            return err;
        };
        defer color_file.close();
        try color_file.writer().writeAll(std.mem.sliceAsBytes(color));
    }

    {
        const alpha_file = dir.createFile(alpha_file_name, .{}) catch |err| {
            std.log.err("Could not create alpha file: {s}", .{@errorName(err)});
            return err;
        };
        defer alpha_file.close();
        try alpha_file.writer().writeAll(std.mem.sliceAsBytes(alpha));
    }

    std.log.info("Saved to folder: {s}", .{directory_path});
}

pub fn validate(self: *const Self, options: *const types.CoderOptions) !void {
    const writer = out.getStdErr();
    defer out.flushErr();

    try writer.print("Validating...", .{});
    out.flushErr();

    const analysis = tgx_coder.analyze(
        types.Argb1555,
        &self.encoded_stream,
        self.tgx_header.width,
        self.tgx_header.height,
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
        self.tgx_header.width,
        self.tgx_header.height,
        options,
        writer,
    );
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    self.encoded_stream.deinit(allocator);
}
