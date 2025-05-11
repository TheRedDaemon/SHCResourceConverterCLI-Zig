const std = @import("std");
const types = @import("types.zig");
const out = @import("io/out.zig");
const tgx_coder = @import("coder/tgx_coder.zig");
const test_data = @import("test_data.zig");
const config = @import("config");

const TgxHeader = extern struct {
    width: u32 align(1),
    height: u32 align(1),
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

const tgx_header_size = @sizeOf(TgxHeader);

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
    const tgx_header = try reader.readStructEndian(TgxHeader, .little);

    const size_of_data = size - tgx_header_size;
    const data = try allocator.alloc(u8, size_of_data);
    var encoded_stream = types.EncodedTgxStream.take(data);
    errdefer encoded_stream.deinit(allocator);

    _ = try reader.read(data);

    std.log.info("Loaded file: {s}", .{file_path});
    return .{
        .tgx_header = tgx_header,
        .encoded_stream = encoded_stream,
    };
}

pub fn loadFromRaw(allocator: std.mem.Allocator, directory_path: []const u8, options: *const types.CoderOptions) !Self {
    std.log.info("Loading from folder: {s}", .{directory_path});

    var dir = std.fs.cwd().openDir(directory_path, .{}) catch |err| {
        std.log.err("Could not open directory: {s}", .{@errorName(err)});
        return err;
    };
    defer dir.close();

    const resource = blk: {
        var local_arena_allocator = std.heap.ArenaAllocator.init(allocator);
        defer local_arena_allocator.deinit(); // control entire allocation
        const local_allocator = local_arena_allocator.allocator();

        const resource_file = dir.openFile(resource_file_name, .{}) catch |err| {
            std.log.err("Could not open resource file: {s}", .{@errorName(err)});
            return err;
        };
        defer resource_file.close();
        var json_reader = std.json.reader(local_allocator, resource_file.reader());
        // struct should be copied, so the deallocation should be fine
        break :blk try std.json.parseFromTokenSourceLeaky(TgxResource, local_allocator, &json_reader, .{});
    };

    var raw_tgx_stream = blk: {
        const color = dir.readFileAllocOptions(
            allocator,
            color_file_name,
            resource.color_size,
            null,
            @alignOf(types.Argb1555),
            null,
        ) catch |err| {
            std.log.err("Could not read color file: {s}", .{@errorName(err)});
            return err;
        };
        errdefer allocator.free(color);
        if (resource.color_size != color.len) {
            return error.InvalidColorFileSize;
        }

        const alpha = dir.readFileAlloc(allocator, alpha_file_name, resource.alpha_size) catch |err| {
            std.log.err("Could not read alpha file: {s}", .{@errorName(err)});
            return err;
        };
        errdefer allocator.free(alpha);
        if (resource.alpha_size != alpha.len) {
            return error.InvalidAlphaFileSize;
        }

        break :blk types.RawTgxStream.take(
            types.Argb1555,
            std.mem.bytesAsSlice(types.Argb1555, color),
            std.mem.bytesAsSlice(types.Alpha1, alpha),
        );
    };
    defer raw_tgx_stream.deinit(allocator);

    const encoded_stream = try tgx_coder.encode(
        types.Argb1555,
        allocator,
        &raw_tgx_stream,
        resource.tgx_header.width,
        resource.tgx_header.height,
        options,
        null,
    );

    std.log.info("Loaded from folder: {s}", .{directory_path});
    return .{
        .tgx_header = resource.tgx_header,
        .encoded_stream = encoded_stream,
    };
}

pub fn saveFile(self: *const Self, file_path: []const u8) !void {
    std.log.info("Saving file: {s}", .{file_path});
    if (!std.mem.eql(u8, std.fs.path.extension(file_path), tgx_extension)) {
        return error.InvalidFileExtension;
    }

    var dir = std.fs.cwd().makeOpenPath(std.fs.path.dirname(file_path) orelse ".", .{}) catch |err| {
        std.log.err("Could not create directory: {s}", .{@errorName(err)});
        return err;
    };
    defer dir.close();

    const file = dir.createFile(std.fs.path.basename(file_path), .{}) catch |err| {
        std.log.err("Could not create file: {s}", .{@errorName(err)});
        return err;
    };
    defer file.close();

    const writer = file.writer();
    try writer.writeStructEndian(self.tgx_header, .little);
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

    dir.writeFile(.{
        .sub_path = color_file_name,
        .data = std.mem.sliceAsBytes(color),
    }) catch |err| {
        std.log.err("Could not create color file: {s}", .{@errorName(err)});
        return err;
    };

    dir.writeFile(.{
        .sub_path = alpha_file_name,
        .data = std.mem.sliceAsBytes(alpha),
    }) catch |err| {
        std.log.err("Could not create alpha file: {s}", .{@errorName(err)});
        return err;
    };

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
    try writer.print("\n", .{});
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

test "extract and pack tgx" {
    if (!config.test_data_present) return error.SkipZigTest;

    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    // uses tmp base dir hardcoded, since absolute paths are deprecated mostly and I found to way to get the proper paths
    const dir_name = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &temp_dir.sub_path, "extract" });
    defer std.testing.allocator.free(dir_name);
    const file_name = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &temp_dir.sub_path, "pack", "test.tgx" });
    defer std.testing.allocator.free(file_name);

    const analysis_original = blk: {
        var tgx = try loadFile(std.testing.allocator, test_data.tgx.chicken_sketch);
        defer tgx.deinit(std.testing.allocator);
        try tgx.saveAsRaw(std.testing.allocator, dir_name, &.default);
        break :blk try tgx_coder.analyze(
            types.Argb1555,
            &tgx.encoded_stream,
            tgx.tgx_header.width,
            tgx.tgx_header.height,
            &.default,
            null,
        );
    };

    {
        var tgx = try loadFromRaw(std.testing.allocator, dir_name, &.default);
        defer tgx.deinit(std.testing.allocator);
        try tgx.saveFile(file_name);
    }

    const analysis_packed = blk: {
        var tgx = try loadFile(std.testing.allocator, file_name);
        defer tgx.deinit(std.testing.allocator);
        break :blk try tgx_coder.analyze(
            types.Argb1555,
            &tgx.encoded_stream,
            tgx.tgx_header.width,
            tgx.tgx_header.height,
            &.default,
            null,
        );
    };

    try std.testing.expectEqualDeep(analysis_original, analysis_packed);
}
