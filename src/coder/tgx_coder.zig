const std = @import("std");
const types = @import("../types.zig");
const out = @import("../io/out.zig");
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

const EncoderError = error{
    OutOfMemory,
    InvalidDataSize,
    WrongPixelType,
};

/// Result of decoding
///
/// In case it contains raw data, the data needs to be freed.
const DecoderResult = union(enum) {
    raw: types.RawTgxStream,
    valid,
};

/// Result of decoding
///
/// In case it contains the encoded data, the data needs to be freed.
const EncoderResult = union(enum) {
    encoded: types.EncodedTgxStream,
    size: usize,
};

const max_pixel_per_marker = 32;

pub fn analyze(
    comptime PixelType: type,
    encoded_stream: *const types.EncodedTgxStream,
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
            encoded_stream,
            width,
            height,
            options,
        );
    } else blk: {
        break :blk try internalDecode(
            PixelType,
            .{ .analysis = &analysis, .writer = writer },
            encoded_stream,
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
    encoded_stream: *const types.EncodedTgxStream,
    width: u32,
    height: u32,
    options: *const types.CoderOptions,
) DecoderError!types.RawTgxStream {
    return switch (try internalDecode(
        PixelType,
        .{ .allocator = allocator },
        encoded_stream,
        width,
        height,
        options,
    )) {
        .raw => |*raw| raw.*,
        else => @panic("Decoder performed unexpected action."),
    };
}

fn internalDecode(
    comptime PixelType: type,
    request: anytype,
    encoded_stream: *const types.EncodedTgxStream,
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
        errdefer local_allocator.free(local_pixels);
        const local_transparency = try local_allocator.alloc(types.Alpha1, width * height);
        errdefer local_allocator.free(local_transparency);

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

    const data = encoded_stream.data;

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
                if (should_analyze) analysis.newline.unfinished_width_pixel_count += width - current_width;
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
                    @memcpy(
                        pixels[target_index .. target_index + pixel_number],
                        std.mem.bytesAsSlice(PixelType, data[source_index .. source_index + pixel_number * pixel_size]),
                    );
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

    return if (!should_decode) .valid else .{ .raw = types.RawTgxStream.take(PixelType, pixels, transparency) };
}

pub fn determineEncodedSize(
    comptime PixelType: type,
    raw_tgx_stream: *const types.RawTgxStream,
    width: u32,
    height: u32,
    options: *const types.CoderOptions,
) EncoderError!usize {
    return switch (try internalEncode(
        PixelType,
        .{},
        raw_tgx_stream,
        width,
        height,
        options,
    )) {
        .size => |size| size,
        else => @panic("Encoder performed unexpected action."),
    };
}

pub fn encode(
    comptime PixelType: type,
    allocator: std.mem.Allocator,
    raw_tgx_stream: *const types.RawTgxStream,
    width: u32,
    height: u32,
    options: *const types.CoderOptions,
    result_size: ?usize,
) EncoderError!types.EncodedTgxStream {
    const size = result_size orelse try determineEncodedSize(
        PixelType,
        raw_tgx_stream,
        width,
        height,
        options,
    );

    return switch (try internalEncode(
        PixelType,
        .{
            .allocator = allocator,
            .size = size,
        },
        raw_tgx_stream,
        width,
        height,
        options,
    )) {
        .encoded => |*data| data.*,
        else => @panic("Encoder performed unexpected action."),
    };
}

// TODO: the encoding for gm1 tgx formats seems to be different than for tgx files
// the repeat line jump count seems to not be present

// TODO: the tile images contain strange repeat pixels located at the end of a line without
// even a pixel on the next line to complete it
// it seems that it might have actually used the following pixel of the canvas, which might either indicate
// that the changed approach prevents a switch to this approach, or that the real result might be lost, due to
// missing data in the result

fn internalEncode(
    comptime PixelType: type,
    request: anytype,
    raw_tgx_stream: *const types.RawTgxStream,
    width: u32,
    height: u32,
    options: *const types.CoderOptions,
) EncoderError!EncoderResult {
    if (PixelType != types.Argb1555 and PixelType != types.Gray8) {
        @compileError("PixelType must be Argb1555 or Gray8.");
    }

    const should_encode = comptime @hasField(@TypeOf(request), "allocator") and @hasField(@TypeOf(request), "size");

    const allocator, const data = if (should_encode) blk: {
        const local_allocator: std.mem.Allocator = @field(&request, "allocator");
        const local_size: usize = @field(&request, "size");
        const local_data = try local_allocator.alloc(u8, local_size);
        errdefer local_allocator.free(local_data);

        break :blk .{
            local_allocator,
            local_data,
        };
    } else blk: {
        break :blk .{ void, void };
    };
    errdefer if (should_encode) {
        allocator.free(data);
    };

    const raw_data = try raw_tgx_stream.getRawData(PixelType);
    const raw_transparency = raw_tgx_stream.getRawTransparency();

    var source_index: usize = 0;
    var target_index: usize = 0;
    for (0..height) |_| {
        var x_index: usize = 0;
        while (x_index < width) {
            var transparent_pixel_count: usize = 0;
            while (x_index < width and raw_transparency[source_index] == 0) // consume all transparency
            {
                transparent_pixel_count += 1;
                x_index += 1;
                source_index += 1;
            }

            // if indexed and end of the line, short circuit to newline
            if (PixelType == types.Argb1555 or x_index < width) {
                while (transparent_pixel_count > max_pixel_per_marker) : (transparent_pixel_count -= max_pixel_per_marker) {
                    target_index += try writeEncodedTransparency(target_index, max_pixel_per_marker, data);
                } else if (transparent_pixel_count > 0) {
                    target_index += try writeEncodedTransparency(target_index, transparent_pixel_count, data);
                }
            }

            // TODO?: is there a special handling for the magenta transparent-marker color pixel, since the RGB transform ignores it, but only for stream pixels?
            var pixel_buffer = if (should_encode) @as([max_pixel_per_marker]PixelType, undefined);
            var count: usize = 0;
            var repeating_pixel_count: usize = 0;
            var repeating_pixel: PixelType = undefined;
            while (x_index < width and count < max_pixel_per_marker) {
                if (raw_transparency[source_index] == 0) {
                    break;
                }
                const next_pixel = raw_data[source_index];

                // count all repeating pixels that can be considered this line, but check pixels of next lines for this decision
                // TODO?: Is there a better approach to this? This loop always starts for every single pixel, even if it is not needed
                var repeating_count: usize = 0;
                for (raw_data[source_index..]) |current_pixel| {
                    if (current_pixel != next_pixel or (repeating_count + x_index >= width and repeating_count % max_pixel_per_marker >= options.pixel_repeat_threshold)) {
                        // if the next pixel is different or we reach next line and the threshold is reached, we can stop, since the next line starts new
                        break;
                    }
                    repeating_count += 1;
                }

                // if more then one batch, remove last batch if remaining pixel count does not reach threshold
                if (repeating_count > max_pixel_per_marker) {
                    const pixel_of_last_batch = repeating_count % max_pixel_per_marker;
                    repeating_pixel_count = repeating_count - if (pixel_of_last_batch < options.pixel_repeat_threshold) pixel_of_last_batch else 0;
                } else {
                    repeating_pixel_count = repeating_count;
                }

                // always fix number of pixels extend over line, since the number is used to know how many repeated pixels to write
                const remaining_pixel_count = width - x_index;
                repeating_pixel_count = if (remaining_pixel_count < repeating_pixel_count) remaining_pixel_count else repeating_pixel_count;

                // currently based if enough repeating pixels after each other are found, but only write till the end of the line
                if (repeating_count >= options.pixel_repeat_threshold) {
                    repeating_pixel = next_pixel;
                    x_index += repeating_pixel_count;
                    source_index += repeating_pixel_count;
                    break;
                }

                // fix if repeating pixel not long enough for stream
                var adjust_pixel_count = count + repeating_pixel_count;
                if (adjust_pixel_count > max_pixel_per_marker) {
                    adjust_pixel_count = max_pixel_per_marker;
                }

                if (should_encode) {
                    @memset(pixel_buffer[count..adjust_pixel_count], next_pixel);
                }
                const index_adjust = adjust_pixel_count - count;
                source_index += index_adjust;
                x_index += index_adjust;
                count += index_adjust;
                repeating_pixel_count = 0;
            }

            if (count > 0) {
                target_index += try writeEncodedPixels(PixelType, target_index, count, data, pixel_buffer);
            }

            while (repeating_pixel_count > max_pixel_per_marker) : (repeating_pixel_count -= max_pixel_per_marker) {
                target_index += try writeEncodedRepeating(PixelType, target_index, max_pixel_per_marker, data, repeating_pixel);
            } else if (repeating_pixel_count > 0) {
                target_index += try writeEncodedRepeating(PixelType, target_index, repeating_pixel_count, data, repeating_pixel);
            }
        }
        // line end
        target_index += try writeEncodedNewline(target_index, 1, data);
    }

    const reminder = target_index % options.padding_alignment;
    if (reminder > 0) {
        const required_padding = options.padding_alignment - reminder;
        target_index += try writeEncodedNewline(target_index, required_padding, data);
    }

    return if (should_encode) .{
        .encoded = types.EncodedTgxStream.take(data),
    } else .{
        .size = target_index,
    };
}

fn writeEncodedTransparency(
    target_index: usize,
    count: usize,
    target: anytype,
) error{InvalidDataSize}!usize {
    const size_to_add = 1;
    if (@TypeOf(target) == type) {
        return size_to_add;
    }
    try validateEncodingSize(target_index, size_to_add, target.len);
    target[target_index] = @bitCast(MarkerByte{ .pixel_index_count = @truncate(count - 1), .marker = Marker.transparent });
    return size_to_add;
}

fn writeEncodedPixels(
    comptime PixelType: type,
    target_index: usize,
    count: usize,
    target: anytype,
    pixels: anytype,
) error{InvalidDataSize}!usize {
    const size_in_target = @sizeOf(PixelType) * count;
    const size_to_add = 1 + size_in_target;
    if (@TypeOf(target) == type) {
        return size_to_add;
    }
    try validateEncodingSize(target_index, size_to_add, target.len);
    var index = target_index;
    target[index] = @bitCast(MarkerByte{ .pixel_index_count = @truncate(count - 1), .marker = Marker.pixel });
    index += 1;
    @memcpy(std.mem.bytesAsSlice(PixelType, target[index .. index + size_in_target]), pixels[0..count]);
    return size_to_add;
}

fn writeEncodedRepeating(
    comptime PixelType: type,
    target_index: usize,
    count: usize,
    target: anytype,
    repeating_pixel: anytype,
) error{InvalidDataSize}!usize {
    const pixel_size = @sizeOf(PixelType);
    const size_to_add = 1 + pixel_size;
    if (@TypeOf(target) == type) {
        return size_to_add;
    }
    try validateEncodingSize(target_index, size_to_add, target.len);
    var index = target_index;
    target[index] = @bitCast(MarkerByte{ .pixel_index_count = @truncate(count - 1), .marker = Marker.repeating });
    index += 1;
    std.mem.bytesAsValue(PixelType, target[index .. index + pixel_size]).* = repeating_pixel;
    return size_to_add;
}

fn writeEncodedNewline(
    target_index: usize,
    repeating: usize,
    target: anytype,
) error{InvalidDataSize}!usize {
    if (@TypeOf(target) == type) {
        return repeating;
    }
    try validateEncodingSize(target_index, repeating, target.len);
    @memset(
        target[target_index .. target_index + repeating],
        @bitCast(MarkerByte{ .pixel_index_count = 0, .marker = Marker.newline }),
    );
    return repeating;
}

fn validateEncodingSize(
    current_size: usize,
    number_to_add: usize,
    data_size: usize,
) error{InvalidDataSize}!void {
    if (current_size + number_to_add > data_size) {
        return error.InvalidDataSize;
    }
}

test "test tgx analysis" {
    if (!config.test_data_present) return error.SkipZigTest;

    const file = try std.fs.cwd().openFile(test_data.tgx.armys10, .{});
    defer file.close();

    const reader = file.reader();
    const size = (try file.stat()).size;

    const size_of_data = size - @sizeOf(u32) * 2;
    const width = try reader.readInt(u32, .little);
    const height: u32 = try reader.readInt(u32, .little);

    const data = try std.testing.allocator.alloc(u8, size_of_data);
    var encoded_stream = types.EncodedTgxStream.take(data);
    defer encoded_stream.deinit(std.testing.allocator);

    const read_bytes = try reader.read(data);
    try std.testing.expect(read_bytes == size_of_data);

    // zig build test can not handle stdout, since it uses it for communication
    const result = try analyze(
        types.Argb1555,
        &encoded_stream,
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

test "test tgx decode and encode" {
    if (!config.test_data_present) return error.SkipZigTest;

    const file = try std.fs.cwd().openFile(test_data.tgx.@"1280r", .{});
    defer file.close();

    const reader = file.reader();
    const size = (try file.stat()).size;
    const size_of_data = size - @sizeOf(u32) * 2;

    const width = try reader.readInt(u32, .little);
    const height: u32 = try reader.readInt(u32, .little);

    const data = try std.testing.allocator.alloc(u8, size_of_data);
    var encoded_stream = types.EncodedTgxStream.take(data);
    defer encoded_stream.deinit(std.testing.allocator);

    const read_bytes = try reader.read(data);
    try std.testing.expect(read_bytes == size_of_data);

    var decoding_result = try decode(
        types.Argb1555,
        std.testing.allocator,
        &encoded_stream,
        width,
        height,
        &types.CoderOptions.default,
    );
    defer decoding_result.deinit(std.testing.allocator);

    var encoding_result = try encode(
        types.Argb1555,
        std.testing.allocator,
        &decoding_result,
        width,
        height,
        &types.CoderOptions.default,
        null,
    );
    defer encoding_result.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, data, encoding_result.getEncodedData());
}
