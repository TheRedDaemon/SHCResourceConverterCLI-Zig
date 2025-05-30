const std = @import("std");
const types = @import("../types.zig");

const EncoderError = error{AlphaOnTile};

pub const tile_size = 256;
pub const Gm1Tile = [tile_size]types.Argb1555;

pub const tile_byte_size = @sizeOf(Gm1Tile);
pub const tile_width = 30;
pub const tile_height = 16;
pub const tile_image_height_offset = 7; // basically the height the image is "sunk" into the tile, and it seems to be a constant in the game

pub const raw_tile_size = tile_width * tile_height;

const tile_mask = blk: {
    @setEvalBranchQuota(2000);

    const half_tile_width = tile_width / 2;
    const quarter_tile_width = half_tile_width / 2;
    const half_tile_height = tile_height / 2;

    var mask = std.bit_set.ArrayBitSet(usize, raw_tile_size).initEmpty();

    var index: usize = 0;
    var y: isize = -half_tile_height;
    while (y <= half_tile_height) : (y += 1) {
        if (y == 0) {
            continue;
        }
        const y_abs = @abs(y);
        var x: isize = -quarter_tile_width;
        while (x <= quarter_tile_width) : (x += 1) {
            const x_abs = @abs(x);
            if (x_abs + y_abs <= half_tile_height) {
                // for every computed point, set two pixels
                mask.set(index);
                mask.set(index + 1);
            }
            index += 2;
        }
    }
    break :blk mask;
};

/// Returns number of pixels that have an alpha value of 0
pub fn analyze(source: *const Gm1Tile) usize {
    var count: usize = 0;
    for (0..tile_size) |i| {
        if (source[i].a == 0) {
            count += 1;
        }
    }
    return count;
}

pub fn decode(
    source: *const Gm1Tile,
    color_receiver: *[raw_tile_size]types.Argb1555,
    alpha_receiver: *[raw_tile_size]types.Alpha1,
    options: *const types.CoderOptions,
) void {
    var source_index: usize = 0;
    for (0..raw_tile_size) |i| {
        if (tile_mask.isSet(i)) {
            color_receiver[i] = source[source_index];
            alpha_receiver[i] = 1;
            source_index += 1;
        } else {
            color_receiver[i] = options.transparent_pixel_raw_color;
            alpha_receiver[i] = 0;
        }
    }
}

pub fn encode(
    color: *const [raw_tile_size]types.Argb1555,
    alpha: *const [raw_tile_size]types.Alpha1,
    target_receiver: *Gm1Tile,
) EncoderError!void {
    var target_index: usize = 0;

    var iter = tile_mask.iterator(.{});
    while (iter.next()) |i| {
        if (alpha[i] == 0) {
            return EncoderError.AlphaOnTile;
        }
        target_receiver[target_index] = color[i];
        target_index += 1;
    }
}

test "tile coder" {
    const tile = [_]types.Argb1555{
        .{ .r = 1, .g = 2, .b = 3, .a = 1 },
        .{ .r = 5, .g = 6, .b = 7, .a = 0 },
    } ** (tile_size / 2);

    const alpha_pixels_in_tile = analyze(&tile);
    try std.testing.expectEqual(tile_size / 2, alpha_pixels_in_tile);

    var color: [raw_tile_size]types.Argb1555 = undefined;
    var alpha: [raw_tile_size]types.Alpha1 = undefined;
    decode(
        &tile,
        &color,
        &alpha,
        &types.CoderOptions.default,
    );

    var rebuild_tile: Gm1Tile = undefined;
    try encode(&color, &alpha, &rebuild_tile);

    try std.testing.expectEqualSlices(types.Argb1555, &tile, &rebuild_tile);
}
