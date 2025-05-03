const std = @import("std");
const types = @import("../types.zig");
const io = @import("../io/out.zig");
const test_data = @import("../test_data.zig");
const config = @import("config");

const Marker = enum(u3) {
    pixel = 0b000,
    transparent = 0b001,
    repeating = 0b010,
    newline = 0b100,
    _,
};

const MarkerByte = packed struct {
    pixel_index_count: u5,
    marker: Marker,
};

const DecoderError = error{
    OutOfMemory,
    UnknownMarker,
    WidthTooBig,
    HeightTooBig,
    InvalidDataSize,
    NotEnoughPixels,
};

/// Result of decoding
///
/// The memory is owned by this struct and needs to be freed.
const DecoderResult = union(enum) {
    pixel: struct {
        pixels: []const types.Argb1555,
        transparency: []const types.Alpha1,
    },
    index: struct {
        indexes: []const types.Gray8,
        transparency: []const types.Alpha1,
    },
    valid,

    pub fn deinit(self: *DecoderResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .pixel => |*pixel| {
                allocator.free(pixel.pixels);
                allocator.free(pixel.transparency);
            },
            .index => |*index| {
                allocator.free(index.indexes);
                allocator.free(index.transparency);
            },
        }
    }
};

const max_pixel_per_marker = 32;

pub fn analyze(
    comptime PixelType: type,
    data: []const u8,
    width: u32,
    height: u32,
    options: *const types.CoderOptions,
    writer: anytype,
) (if (@typeInfo(@TypeOf(writer)) == .null) DecoderError else anyerror)!types.TgxAnalysis {
    var analysis = types.TgxAnalysis.empty;
    return switch (if (@typeInfo(@TypeOf(writer)) == .null) blk: {
        break :blk try internalDecode(
            PixelType,
            .{ .analysis = &analysis },
            data,
            width,
            height,
            options,
        );
    } else blk: {
        break :blk try internalDecode(
            PixelType,
            .{ .analysis = &analysis, .writer = writer },
            data,
            width,
            height,
            options,
        );
    }) {
        .valid => analysis,
        else => @panic("Decoder performed unexpected action."),
    };
}

pub fn decode(
    comptime PixelType: type,
    allocator: std.mem.Allocator,
    data: []const u8,
    width: u32,
    height: u32,
    options: *const types.CoderOptions,
) DecoderError!DecoderResult {
    return internalDecode(
        PixelType,
        .{ .allocator = allocator },
        data,
        width,
        height,
        options,
    );
}

fn internalDecode(
    comptime PixelType: type,
    request: anytype,
    data: []const u8,
    width: u32,
    height: u32,
    options: *const types.CoderOptions,
) !DecoderResult {
    if (PixelType != types.Argb1555 and PixelType != types.Gray8) {
        @compileError("PixelType must be Argb1555 or Gray8.");
    }

    const should_decode = comptime @hasField(@TypeOf(request), "allocator");
    const should_analyze = comptime @hasField(@TypeOf(request), "analysis");
    const should_write_text = comptime @hasField(@TypeOf(request), "writer");

    const pixel_size = comptime @sizeOf(PixelType);

    const allocator, const pixels, const transparency = if (should_decode) blk: {
        const local_allocator: std.mem.Allocator = @field(&request, "allocator");
        const local_pixels = try local_allocator.alloc(PixelType, width * height);
        const local_transparency = try local_allocator.alloc(types.Alpha1, width * height);

        // initialize with transparency indicator
        const fill_color = if (PixelType == types.Argb1555) options.transparent_pixel_raw_color else options.transparent_pixel_fill_index;
        @memset(local_pixels, fill_color);
        @memset(local_transparency, 0);

        break :blk .{
            local_allocator,
            local_pixels,
            local_transparency,
        };
    } else blk: {
        break :blk .{ void, void, void };
    };
    errdefer if (should_decode) {
        allocator.free(pixels);
        allocator.free(transparency);
    };

    const analysis = if (should_analyze) @field(&request, "analysis");
    const writer = if (should_write_text) @field(&request, "writer");

    var current_width: usize = 0;
    var current_height: usize = 0;

    var source_index: usize = 0;
    var target_index = if (should_decode) @as(usize, 0);
    while (source_index < data.len) {
        const marker_byte: MarkerByte = @bitCast(data[source_index]);
        const marker = marker_byte.marker;
        const pixel_number = @as(u8, marker_byte.pixel_index_count) + 1; // 0 means one pixel
        source_index += 1;

        if (marker == .newline) {
            if (should_write_text) {
                try writer.print("NEWLINE {d}\n", .{pixel_number});
            }

            if (current_width <= 0 and current_height == height) // handle padding at end
            {
                if (should_analyze) analysis.newline.padding_marker_count += 1;
                continue;
            }

            if (should_analyze) {
                analysis.newline.normal_marker_count += 1;
            }

            if (current_width < width) {
                if (should_analyze) analysis.newline.unfinished_width_pixel_count += 1;
                if (should_decode) target_index += width - current_width;
            }

            current_width = 0;
            current_height += 1;
            if (current_height > height) {
                return DecoderError.HeightTooBig;
            }

            continue;
        }

        if (current_width == width) {
            if (should_analyze) analysis.newline.newline_without_marker_count += 1;
            current_width = 0;
            current_height += 1;
            if (current_height > height) {
                return DecoderError.HeightTooBig;
            }
        }

        switch (marker) {
            .pixel => {
                if (should_write_text) {
                    try writer.print("STREAM_PIXEL {d}", .{pixel_number});
                    for (std.mem.bytesAsSlice(PixelType, data[source_index .. source_index + pixel_number * pixel_size])) |pixel| {
                        try writer.print(
                            " 0x{x:0>" ++ std.fmt.comptimePrint("{d}", .{pixel_size * 2}) ++ "}",
                            .{if (PixelType == types.Argb1555) @as(u16, @bitCast(pixel)) else pixel},
                        );
                    }
                    try writer.print("\n", .{});
                }
                if (should_analyze) {
                    analysis.pixel.marker_count += 1;
                    analysis.pixel.pixel_count += pixel_number;
                    if (PixelType == types.Argb1555) {
                        for (std.mem.bytesAsSlice(PixelType, data[source_index .. source_index + pixel_number * pixel_size])) |pixel| {
                            if (pixel.a == 0) analysis.color_pixel_with_alpha_zero += 1;
                        }
                    }
                }
                if (should_decode) {
                    @memcpy(pixels[target_index .. target_index + pixel_number], data[source_index .. source_index + pixel_number * pixel_size]);
                    @memset(transparency[target_index .. target_index + pixel_number], 1);
                    target_index += pixel_number;
                }
                source_index += pixel_number * pixel_size;
            },
            .transparent => {
                if (should_write_text) {
                    try writer.print("TRANSPARENT_PIXEL {d}\n", .{pixel_number});
                }
                if (should_analyze) {
                    analysis.transparent.marker_count += 1;
                    analysis.transparent.pixel_count += pixel_number;
                }
                if (should_decode) {
                    // already prefilled with transparency indicator
                    target_index += pixel_number;
                }
            },
            .repeating => { // there might be a special case for magenta pixels
                const fill_color = std.mem.bytesAsValue(PixelType, data[source_index .. source_index + pixel_size]).*;
                if (should_write_text) {
                    try writer.print(
                        "REPEAT_PIXEL {d} 0x{x:0>" ++ std.fmt.comptimePrint("{d}", .{pixel_size * 2}) ++ "}\n",
                        .{ pixel_number, if (PixelType == types.Argb1555) @as(u16, @bitCast(fill_color)) else fill_color },
                    );
                }
                if (should_analyze) {
                    analysis.repeating.marker_count += 1;
                    analysis.repeating.pixel_count += pixel_number;
                    if (PixelType == types.Argb1555) {
                        if (fill_color.a == 0) analysis.color_pixel_with_alpha_zero += 1;
                    }
                }
                if (should_decode) {
                    @memset(pixels[target_index .. target_index + pixel_number], fill_color);
                    @memset(transparency[target_index .. target_index + pixel_number], 1);
                    target_index += pixel_number;
                }
                source_index += pixel_size;
            },
            else => return DecoderError.UnknownMarker,
        }

        current_width += pixel_number;
        if (current_width > width) {
            return DecoderError.WidthTooBig;
        }
    }

    if (source_index != data.len) {
        return DecoderError.InvalidDataSize;
    }

    if (current_height < height) {
        return DecoderError.NotEnoughPixels;
    }

    if (!should_decode) {
        return .valid;
    } else if (PixelType == types.Argb1555) {
        return .{
            .pixel = .{
                .pixels = pixels,
                .transparency = transparency,
            },
        };
    } else {
        return .{
            .index = .{
                .indexes = pixels,
                .transparency = transparency,
            },
        };
    }
}

test "test tgx analysis" {
    if (!config.test_data_present) return error.SkipZigTest;

    const file = try std.fs.cwd().openFile(test_data.tgx.armys10, .{});
    defer file.close();

    const size = (try file.stat()).size;

    const reader = file.reader();

    const width = try reader.readInt(u32, .little);
    const height: u32 = try reader.readInt(u32, .little);

    const size_of_data = size - @sizeOf(u32) * 2;
    const data = try std.testing.allocator.alloc(u8, size_of_data);
    defer std.testing.allocator.free(data);

    const read_bytes = try reader.read(data);
    try std.testing.expect(read_bytes == size_of_data);

    // zig build test can not handle stdout, since it uses it for communication
    const result = try analyze(
        types.Argb1555,
        data,
        width,
        height,
        &types.CoderOptions.default,
        null,
        //io.getStdErr(),
    );
    //io.flushErr();

    try std.testing.expectEqual(46, width);
    try std.testing.expectEqual(80, height);
    try std.testing.expectEqualDeep(
        types.TgxAnalysis{
            .pixel = .{ .marker_count = 122, .pixel_count = 1270 },
            .transparent = .{ .marker_count = 210, .pixel_count = 2397 },
            .repeating = .{ .marker_count = 4, .pixel_count = 13 },
            .newline = .{
                .normal_marker_count = 80,
                .newline_without_marker_count = 0,
                .unfinished_width_pixel_count = 0,
                .padding_marker_count = 0,
            },
            .color_pixel_with_alpha_zero = 0,
        },
        result,
    );
}

// TODO: test decoding
