const std = @import("std");
const types = @import("../types.zig");

pub const tile_size = 256;
pub const Gm1Tile = [tile_size]types.Argb1555;

pub const tile_byte_size = @sizeOf(Gm1Tile);
pub const tile_width = 30;
pub const tile_height = 16;
pub const tile_image_height_offset = 7; // basically the height the image is "sunk" into the tile, and it seems to be a constant in the game

pub const raw_tile_size = tile_width * tile_height;

const tile_mask = blk: {
    const half_tile_width = tile_width / 2;
    const quarter_tile_width = half_tile_width / 2;
    const half_tile_height = tile_height / 2;

    var mask = std.bit_set.ArrayBitSet(usize, raw_tile_size).initEmpty();

    var index: usize = 0;
    for (-half_tile_height..half_tile_height + 1) |y| {
        if (y == 0) {
            continue;
        }
        const y_abs = @abs(y);
        for (-quarter_tile_width..quarter_tile_width + 1) |x| {
            const x_abs = @abs(x);
            if (x_abs + y_abs <= half_tile_height) {
                mask.set(index);
            }
            index += 1;
        }
    }
    break :blk mask;
};

/// Returns number of pixels that have an alpha value of 0
pub fn analyze(source: *const Gm1Tile) usize {
    var count: usize = 0;
    for (0..tile_size) |i| {
        if (source[i].alpha == 0) {
            count += 1;
        }
    }
    return count;
}

pub fn decode(
    source: *const Gm1Tile,
    color_receiver: *[raw_tile_size]types.Argb1555,
    alpha_receiver: *[raw_tile_size]types.Alpha1,
    transparent_pixel_raw_color: types.Argb1555,
) void {
    var source_index: usize = 0;
    for (0..raw_tile_size) |i| {
        if (tile_mask.isSet(i)) {
            color_receiver[i] = source[source_index];
            alpha_receiver[i] = 1;
            source_index += 1;
        } else {
            color_receiver[i] = transparent_pixel_raw_color;
            alpha_receiver[i] = 0;
        }
    }
}

pub fn encode(
    color: *const [raw_tile_size]types.Argb1555,
    alpha: *const [raw_tile_size]types.Alpha1,
    target_receiver: *Gm1Tile,
) !void {
    var target_index: usize = 0;

    const iter = tile_mask.iterator(.{});
    while (iter.next()) |i| {
        if (alpha[i] == 0) {
            return error.AlphaOnTile;
        }
        target_receiver[target_index] = color[i];
        target_index += 1;
    }
}
