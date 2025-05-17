const std = @import("std");
const types = @import("../types.zig");

const DecoderError = error{
    InvalidDataSize,
    OutOfMemory,
};

const EncoderError = error{
    InvalidDataSize,
    OutOfMemory,
};

/// Returns number of pixels that have an alpha value of 0
pub fn analyze(
    source: []const types.Argb1555,
    width: u32,
    height: u32,
) error{InvalidDataSize}!usize {
    const raw_size = width * height;
    if (source.len > raw_size or source.len % width != 0) {
        return DecoderError.InvalidDataSize;
    }

    var count: usize = 0;
    for (source) |pixel| {
        if (pixel.a == 0) {
            count += 1;
        }
    }
    return count;
}

/// Returns decoded raw data. Must be freed by caller.
pub fn decode(
    allocator: std.mem.Allocator,
    source: []const types.Argb1555,
    width: u32,
    height: u32,
    options: *const types.CoderOptions,
) DecoderError!struct { []const types.Argb1555, []const types.Alpha1 } {
    const raw_size = width * height;
    if (source.len > raw_size or source.len % width != 0) {
        return DecoderError.InvalidDataSize;
    }

    var color = try allocator.alloc(types.Argb1555, raw_size);
    errdefer allocator.free(color);
    var alpha = try allocator.alloc(types.Alpha1, raw_size);
    errdefer allocator.free(alpha);

    // pixels
    @memcpy(color[0..source.len], source[0..]);
    @memset(alpha[0..source.len], 1);
    // remaining alpha
    @memset(color[source.len..], options.transparent_pixel_raw_color);
    @memset(alpha[source.len..], 0);

    return .{ color, alpha };
}

/// Returns decoded raw data. Must be freed by caller.
pub fn encode(
    allocator: std.mem.Allocator,
    source_color: []const types.Argb1555,
    source_alpha: []const types.Alpha1,
    width: u32,
    height: u32,
) EncoderError![]const types.Argb1555 {
    const raw_size = width * height;
    if (raw_size != source_color.len or raw_size != source_alpha.len) {
        return DecoderError.InvalidDataSize;
    }

    const color_pixels = std.mem.indexOfScalar(types.Alpha1, source_alpha, 0) orelse source_alpha.len;
    if (color_pixels % width != 0) {
        return DecoderError.InvalidDataSize;
    }

    var uncompressed = try allocator.alloc(types.Argb1555, color_pixels);
    errdefer allocator.free(uncompressed);
    @memcpy(uncompressed[0..], source_color[0..color_pixels]);

    return uncompressed;
}

test "uncompressed coder" {
    const width = 10;
    const height = 8;
    const fill_height = 5;

    var uncompressed: [width * fill_height]types.Argb1555 = undefined;
    for (0..fill_height) |y| {
        @memset(uncompressed[y * width .. (y + 1) * width], .{ .r = @truncate(y), .g = 2, .b = 3, .a = 1 });
    }

    const raw_color, const raw_alpha = try decode(
        std.testing.allocator,
        &uncompressed,
        width,
        height,
        &types.CoderOptions.default,
    );
    defer std.testing.allocator.free(raw_color);
    defer std.testing.allocator.free(raw_alpha);

    const encoded = try encode(
        std.testing.allocator,
        raw_color,
        raw_alpha,
        width,
        height,
    );
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqualSlices(types.Argb1555, &uncompressed, encoded);
}
