const std = @import("std");
const types = @import("types.zig");
const out = @import("io/out.zig");
const tgx_coder = @import("coder/tgx_coder.zig");
const tile_coder = @import("coder/tile_coder.zig");
const uncompressed_coder = @import("coder/uncompressed_coder.zig");
const blt = @import("coder/blt.zig");
const test_data = @import("test_data.zig");
const config = @import("config");

const Gm1Type = enum(u32) {
    interface = 1, // Interface items and some building animations. Images are stored similar to TGX images.
    animations = 2, // Animations
    tiles_object = 3, // Buildings. Images are stored similar to TGX images but with a Tile object.
    font = 4, // Font. TGX format.
    no_compression_1 = 5,
    tgx_const_size = 6,
    no_compression_2 = 7,
    _,
};

const Gm1Header = extern struct {
    unknown_0x0: u32 align(1),
    unknown_0x4: u32 align(1),
    unknown_0x8: u32 align(1),
    number_of_pictures_in_file: u32 align(1),
    unknown_0x10: u32 align(1),
    gm1_type: Gm1Type align(1),
    unknown_0x18: u32 align(1),
    unknown_0x1c: u32 align(1),
    unknown_0x20: u32 align(1),
    unknown_0x24: u32 align(1),
    unknown_0x28: u32 align(1),
    unknown_0x2c: u32 align(1),
    width: u32 align(1),
    height: u32 align(1),
    unknown_0x38: u32 align(1),
    unknown_0x3c: u32 align(1),
    unknown_0x40: u32 align(1),
    unknown_0x44: u32 align(1),
    origin_x: u32 align(1),
    origin_y: u32 align(1),
    data_size: u32 align(1),
    unknown_0x54: u32 align(1),
};

const Gm1ColorTables = [10][256]types.Argb1555;

const Gm1TileObjectImagePosition = enum(u8) {
    none = 0,
    top = 1,
    upper_left = 2,
    upper_right = 3,
    _,
};

const Gm1ImageFlags = packed struct(u8) {
    unknown_0: bool,
    unknown_1: bool,
    skip_during_game_import: bool, // TODO: needs validation
    unknown_3: bool,
    unknown_4: bool,
    unknown_5: bool,
    unknown_6: bool,
    unknown_7: bool,
};

const Gm1ImageDimensions = extern struct {
    width: u16 align(1),
    height: u16 align(1),
    offset_x: u16 align(1),
    offset_y: u16 align(1),
};

const Gm1ImageInfo = union(enum) {
    general: extern struct {
        relative_data_pos: i16 align(1), // seems to be used to point to data to use instead
        font_related_size: i16 align(1),
        unknown_0x4: u8 align(1),
        unknown_0x5: u8 align(1),
        unknown_0x6: u8 align(1),
        flags: Gm1ImageFlags align(1), // seems to indicate together with game flag if certain animation frames are skipped
    },
    tile_object: extern struct {
        image_part: u8 align(1),
        sub_parts: u8 align(1),
        tile_offset: u16 align(1),
        image_position: Gm1TileObjectImagePosition align(1),
        image_offset_x: i8 align(1),
        image_width: u8 align(1),
        flags: Gm1ImageFlags align(1), // seems to also be flags, not the animation color
    },
};

const Gm1Image = struct {
    dimensions: Gm1ImageDimensions,
    info: Gm1ImageInfo,
    data: union(enum) {
        tgx: types.EncodedTgxStream,
        uncompressed: []const types.Argb1555,
        tile_object: struct {
            image: types.EncodedTgxStream,
            tile: *tile_coder.Gm1Tile,
        },
    },

    pub fn deinit(self: *Gm1Image, allocator: std.mem.Allocator) void {
        switch (self.data) {
            .tgx => |*tgx| tgx.deinit(allocator),
            .uncompressed => |uncompressed| allocator.free(uncompressed),
            .tile_object => |*tile_object| {
                tile_object.image.deinit(allocator);
                allocator.destroy(tile_object.tile);
            },
        }
    }
};

fn BltImageToTarget(value_type: type) type {
    return blt.CopyInstruction(.{
        .value_type = value_type,
        .source_mode = blt.SourceMode.image,
        .position_mode = blt.PositionMode.target,
    });
}

fn BltFilteredImageToTarget(value_type: type) type {
    return blt.CopyInstruction(.{
        .value_type = value_type,
        .source_mode = blt.SourceMode.image,
        .position_mode = blt.PositionMode.target,
        .source_ignore_value = true,
    });
}

fn BltMaskedImageToTarget(value_type: type) type {
    return blt.CopyInstruction(.{
        .value_type = value_type,
        .source_mode = blt.SourceMode.image,
        .position_mode = blt.PositionMode.target,
        .source_bit_mask = true,
    });
}

fn BltMaskedColorToTarget(value_type: type) type {
    return blt.CopyInstruction(.{
        .value_type = value_type,
        .source_mode = blt.SourceMode.color,
        .position_mode = blt.PositionMode.target,
        .source_bit_mask = true,
    });
}

fn BltImageFromSource(value_type: type) type {
    return blt.CopyInstruction(.{
        .value_type = value_type,
        .source_mode = blt.SourceMode.image,
        .position_mode = blt.PositionMode.source,
    });
}

const Gm1ResourceInfo = struct {
    color_size: usize,
    alpha_size: usize,
    canvas_width: usize,
    canvas_height: usize,
};

// do not forget to deallocate if received from json
const Gm1Resource = struct {
    info: Gm1ResourceInfo,
    gm1_header: *const Gm1Header,
    images: []struct { *const Gm1ImageDimensions, *const Gm1ImageInfo },
};

pub const gm1_extension = ".gm1";

const resource_file_name = "resource.json";
const color_file_name = "color.data";
const alpha_file_name = "alpha.data";
const palette_file_name_pattern = "{d}.palette";

const gm1_header_size = @sizeOf(Gm1Header);
const gm1_color_tables_size = @sizeOf(Gm1ColorTables);

const Self = @This();

gm1_header: Gm1Header,
color_tables: *Gm1ColorTables,
images: []Gm1Image,

pub fn loadFile(allocator: std.mem.Allocator, file_path: []const u8) !Self {
    std.log.info("Loading file: {s}", .{file_path});
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        std.log.err("Could not open file: {s}", .{@errorName(err)});
        return err;
    };
    defer file.close();

    const size = (try file.stat()).size;
    if (gm1_header_size + gm1_color_tables_size > size) {
        return error.FileTooSmallForGm1;
    }

    const reader = file.reader();
    const gm1_header = try reader.readStructEndian(Gm1Header, .little);

    const color_tables = try allocator.create(Gm1ColorTables);
    errdefer allocator.destroy(color_tables);
    try reader.readNoEof(std.mem.asBytes(color_tables));

    const image_count = gm1_header.number_of_pictures_in_file;
    const data_offset = gm1_header_size + gm1_color_tables_size + image_count * (@sizeOf(u32) * 2 +
        @sizeOf(@FieldType(Gm1Image, "dimensions")) +
        @sizeOf(@FieldType(@FieldType(Gm1Image, "info"), "general")));
    if (size - data_offset != gm1_header.data_size) {
        return error.InvalidFileSize;
    }

    // ignore data offsets, only using sizes
    try file.seekBy(image_count * @sizeOf(u32));

    const data_sizes = try allocator.alloc(u32, image_count);
    defer allocator.free(data_sizes);
    try reader.readNoEof(std.mem.sliceAsBytes(data_sizes));

    var images = try allocator.alloc(Gm1Image, image_count);
    errdefer allocator.free(images);

    // load image meta data
    for (images) |*image| {
        image.dimensions = try reader.readStructEndian(@FieldType(Gm1Image, "dimensions"), .little);
        switch (gm1_header.gm1_type) {
            .tiles_object => {
                image.info = .{
                    .tile_object = try reader.readStructEndian(@FieldType(
                        @FieldType(Gm1Image, "info"),
                        "tile_object",
                    ), .little),
                };
            },
            else => {
                image.info = .{ .general = try reader.readStructEndian(@FieldType(
                    @FieldType(Gm1Image, "info"),
                    "general",
                ), .little) };
            },
        }
    }

    var image_index: usize = 0;
    errdefer for (images[0..image_index]) |*image| {
        image.deinit(allocator);
    };

    // load allocated data
    while (image_index < image_count) : (image_index += 1) {
        const image = &images[image_index];
        image.data = switch (gm1_header.gm1_type) {
            .tiles_object => blk: {
                const tile = try allocator.create(tile_coder.Gm1Tile);
                errdefer allocator.destroy(tile);
                try reader.readNoEof(std.mem.asBytes(tile));

                const data = try allocator.alloc(u8, data_sizes[image_index] - tile_coder.tile_byte_size);
                var encoded_stream = types.EncodedTgxStream.take(data);
                errdefer encoded_stream.deinit(allocator);
                try reader.readNoEof(data);

                break :blk .{ .tile_object = .{ .tile = tile, .image = encoded_stream } };
            },
            .tgx_const_size, .font, .interface, .animations => blk: {
                const data = try allocator.alloc(u8, data_sizes[image_index]);
                var encoded_stream = types.EncodedTgxStream.take(data);
                errdefer encoded_stream.deinit(allocator);
                try reader.readNoEof(data);

                break :blk .{ .tgx = encoded_stream };
            },
            .no_compression_1, .no_compression_2 => blk: {
                const uncompressed = try allocator.alloc(types.Argb1555, data_sizes[image_index] / @sizeOf(types.Argb1555));
                errdefer allocator.free(uncompressed);
                try reader.readNoEof(std.mem.sliceAsBytes(uncompressed));

                break :blk .{ .uncompressed = uncompressed };
            },
            else => return error.UnknownGm1Type,
        };
    }

    std.log.info("Loaded file: {s}", .{file_path});
    return .{
        .gm1_header = gm1_header,
        .color_tables = color_tables,
        .images = images,
    };
}

pub fn loadFromRaw(allocator: std.mem.Allocator, directory_path: []const u8, options: *const types.CoderOptions) !Self {
    std.log.info("Loading from folder: {s}", .{directory_path});

    var dir = std.fs.cwd().openDir(directory_path, .{}) catch |err| {
        std.log.err("Could not open directory: {s}", .{@errorName(err)});
        return err;
    };
    defer dir.close();

    const gm1_resource_info, var gm1_file = blk: {
        var local_arena_allocator = std.heap.ArenaAllocator.init(allocator);
        defer local_arena_allocator.deinit(); // control entire allocation
        const local_allocator = local_arena_allocator.allocator();

        const resource_file = dir.openFile(resource_file_name, .{}) catch |err| {
            std.log.err("Could not open resource file: {s}", .{@errorName(err)});
            return err;
        };
        defer resource_file.close();
        // taken care by the arena allocator
        var json_reader = std.json.reader(local_allocator, resource_file.reader());
        const resource = try std.json.parseFromTokenSourceLeaky(Gm1Resource, local_allocator, &json_reader, .{});
        if (resource.gm1_header.number_of_pictures_in_file != resource.images.len) {
            return error.ImageNumberMismatch;
        }

        const images = try allocator.alloc(Gm1Image, resource.images.len);
        errdefer allocator.free(images);
        for (images, 0..) |*image, image_index| {
            image.dimensions = resource.images[image_index][0].*;
            image.info = resource.images[image_index][1].*;
            image.data = undefined; // assigned later
        }

        break :blk .{
            resource.info,
            Self{
                .gm1_header = resource.gm1_header.*,
                .color_tables = try allocator.create(Gm1ColorTables),
                .images = images,
            },
        };
    };
    errdefer {
        allocator.destroy(gm1_file.color_tables);
        allocator.free(gm1_file.images);
    }

    const canvas_pixels = gm1_resource_info.canvas_width * gm1_resource_info.canvas_height;
    if (canvas_pixels != gm1_resource_info.color_size / switch (gm1_file.gm1_header.gm1_type) {
        .animations => @as(usize, @sizeOf(types.Gray8)),
        else => @as(usize, @sizeOf(types.Argb1555)),
    } or canvas_pixels != gm1_resource_info.alpha_size) {
        return error.CanvasSizeMismatch;
    }

    for (gm1_file.color_tables, 0..) |*color_table, color_table_index| {
        const palette_file_name = try std.fmt.allocPrint(allocator, palette_file_name_pattern, .{color_table_index});
        defer allocator.free(palette_file_name);

        const file = dir.openFile(palette_file_name, .{}) catch |err| {
            std.log.err("Could not open palette file: {s}", .{@errorName(err)});
            return err;
        };
        const size = (try file.stat()).size;
        if (size != @sizeOf(std.meta.Child(Gm1ColorTables))) {
            return error.PaletteFileHasInvalidSize;
        }
        _ = file.read(std.mem.asBytes(color_table)) catch |err| {
            std.log.err("Failed to read palette file: {s}", .{@errorName(err)});
            return err;
        };
    }

    const canvas_color, const canvas_alpha = blk: {
        const color = dir.readFileAllocOptions(
            allocator,
            color_file_name,
            gm1_resource_info.color_size,
            null,
            @alignOf(types.Argb1555),
            null,
        ) catch |err| {
            std.log.err("Could not read color file: {s}", .{@errorName(err)});
            return err;
        };
        errdefer allocator.free(color);
        if (gm1_resource_info.color_size != color.len) {
            return error.InvalidColorFileSize;
        }

        const alpha = dir.readFileAlloc(allocator, alpha_file_name, gm1_resource_info.alpha_size) catch |err| {
            std.log.err("Could not read alpha file: {s}", .{@errorName(err)});
            return err;
        };
        errdefer allocator.free(alpha);
        if (gm1_resource_info.alpha_size != alpha.len) {
            return error.InvalidAlphaFileSize;
        }

        break :blk .{ color, std.mem.bytesAsSlice(types.Alpha1, alpha) };
    };
    defer {
        allocator.free(canvas_color);
        allocator.free(canvas_alpha);
    }

    var image_index: usize = 0;
    errdefer for (gm1_file.images[0..image_index]) |*image| {
        image.deinit(allocator);
    };

    // load allocated data
    var data_size: usize = 0;
    switch (gm1_file.gm1_header.gm1_type) {
        .tiles_object => {
            while (image_index < gm1_file.gm1_header.number_of_pictures_in_file) : (image_index += 1) {
                const image = &gm1_file.images[image_index];
                // modifies loaded data to allow legacy image encoding
                try readTileObjectToImage(
                    allocator,
                    std.mem.bytesAsSlice(types.Argb1555, canvas_color),
                    canvas_alpha,
                    gm1_resource_info.canvas_width,
                    gm1_resource_info.canvas_height,
                    image,
                    options,
                );
                data_size += @sizeOf(tile_coder.Gm1Tile);
                data_size += image.data.tile_object.image.getEncodedData().len;
            }
        },
        .tgx_const_size, .font, .interface => {
            while (image_index < gm1_file.gm1_header.number_of_pictures_in_file) : (image_index += 1) {
                const image = &gm1_file.images[image_index];
                try readGm1TgxToImage(
                    types.Argb1555,
                    allocator,
                    std.mem.bytesAsSlice(types.Argb1555, canvas_color),
                    canvas_alpha,
                    gm1_resource_info.canvas_width,
                    gm1_resource_info.canvas_height,
                    image,
                    options,
                );
                data_size += image.data.tgx.getEncodedData().len;
            }
        },
        .animations => {
            while (image_index < gm1_file.gm1_header.number_of_pictures_in_file) : (image_index += 1) {
                const image = &gm1_file.images[image_index];
                if (gm1_file.gm1_header.width != image.dimensions.width or gm1_file.gm1_header.height != image.dimensions.height) {
                    return error.AnimationTgxSizeMismatch;
                }
                try readGm1TgxToImage(
                    types.Gray8,
                    allocator,
                    std.mem.bytesAsSlice(types.Gray8, canvas_color),
                    canvas_alpha,
                    gm1_resource_info.canvas_width,
                    gm1_resource_info.canvas_height,
                    image,
                    options,
                );
                data_size += image.data.tgx.getEncodedData().len;
            }
        },
        .no_compression_1, .no_compression_2 => {
            while (image_index < gm1_file.gm1_header.number_of_pictures_in_file) : (image_index += 1) {
                const image = &gm1_file.images[image_index];
                try readUncompressedToImage(
                    allocator,
                    std.mem.bytesAsSlice(types.Argb1555, canvas_color),
                    canvas_alpha,
                    gm1_resource_info.canvas_width,
                    gm1_resource_info.canvas_height,
                    image,
                );
                data_size += image.data.uncompressed.len * @sizeOf(types.Argb1555);
            }
        },
        else => return error.UnknownGm1Type,
    }
    gm1_file.gm1_header.data_size = @intCast(data_size);

    std.log.info("Loaded from folder: {s}", .{directory_path});
    return gm1_file;
}

fn readGm1TgxToImage(
    comptime T: type,
    allocator: std.mem.Allocator,
    color_canvas: []const T,
    alpha_canvas: []const types.Alpha1,
    canvas_width: usize,
    canvas_height: usize,
    image: *Gm1Image,
    options: *const types.CoderOptions,
) !void {
    image.data = .{
        .tgx = try tgx_coder.encode(
            T,
            allocator,
            &types.RawTgxStream.take(T, color_canvas, alpha_canvas),
            canvas_width,
            canvas_height,
            image.dimensions.width,
            image.dimensions.height,
            image.dimensions.offset_x,
            image.dimensions.offset_y,
            options,
            null,
        ),
    };
}

fn readUncompressedToImage(
    allocator: std.mem.Allocator,
    color_canvas: []const types.Argb1555,
    alpha_canvas: []const types.Alpha1,
    canvas_width: usize,
    canvas_height: usize,
    image: *Gm1Image,
) !void {
    const color = try allocator.alloc(types.Argb1555, @as(usize, image.dimensions.width) * image.dimensions.height);
    defer allocator.free(color);
    const alpha = try allocator.alloc(types.Alpha1, @as(usize, image.dimensions.width) * image.dimensions.height);
    defer allocator.free(alpha);

    try blt.blt(
        BltImageFromSource(types.Argb1555){
            .source_image = color_canvas,
            .source_width = canvas_width,
            .source_height = canvas_height,
            .target = color,
            .target_width = image.dimensions.width,
            .target_height = image.dimensions.height,
            .position_x = image.dimensions.offset_x,
            .position_y = image.dimensions.offset_y,
        },
    );
    try blt.blt(
        BltImageFromSource(types.Alpha1){
            .source_image = alpha_canvas,
            .source_width = canvas_width,
            .source_height = canvas_height,
            .target = alpha,
            .target_width = image.dimensions.width,
            .target_height = image.dimensions.height,
            .position_x = image.dimensions.offset_x,
            .position_y = image.dimensions.offset_y,
        },
    );

    image.data = .{
        .uncompressed = try uncompressed_coder.encode(
            allocator,
            color,
            alpha,
            image.dimensions.width,
            image.dimensions.height,
        ),
    };
}

fn readTileObjectToImage(
    allocator: std.mem.Allocator,
    color_canvas: []types.Argb1555,
    alpha_canvas: []types.Alpha1,
    canvas_width: usize,
    canvas_height: usize,
    image: *Gm1Image,
    options: *const types.CoderOptions,
) !void {
    var tile_color: [tile_coder.raw_tile_size]types.Argb1555 = undefined;
    var tile_alpha: [tile_coder.raw_tile_size]types.Alpha1 = undefined;

    const x_position_tile = if (image.info.tile_object.image_offset_x < 0) @as(isize, image.dimensions.offset_x) - image.info.tile_object.image_offset_x else @as(isize, image.dimensions.offset_x);
    const y_position_tile = @as(isize, image.dimensions.offset_y) + image.dimensions.height - tile_coder.tile_height;
    try blt.blt(
        BltImageFromSource(types.Argb1555){
            .source_image = color_canvas,
            .source_width = canvas_width,
            .source_height = canvas_height,
            .target = &tile_color,
            .target_width = tile_coder.tile_width,
            .target_height = tile_coder.tile_height,
            .position_x = x_position_tile,
            .position_y = y_position_tile,
        },
    );
    try blt.blt(
        BltImageFromSource(types.Alpha1){
            .source_image = alpha_canvas,
            .source_width = canvas_width,
            .source_height = canvas_height,
            .target = &tile_alpha,
            .target_width = tile_coder.tile_width,
            .target_height = tile_coder.tile_height,
            .position_x = x_position_tile,
            .position_y = y_position_tile,
        },
    );

    const gm_tile = try allocator.create(tile_coder.Gm1Tile);
    errdefer allocator.destroy(gm_tile);
    try tile_coder.encode(&tile_color, &tile_alpha, gm_tile);

    image.data = .{
        .tile_object = .{
            .tile = gm_tile,
            .image = undefined,
        },
    };

    if (image.info.tile_object.image_position == Gm1TileObjectImagePosition.none) {
        image.data.tile_object.image = types.EncodedTgxStream.take(&.{});
        return;
    }
    // decode again to get a tile cutter for the image
    // overhead, but ok for here
    var tile_cutter: [tile_coder.raw_tile_size]types.Alpha1 = undefined;
    tile_coder.decode(gm_tile, &tile_color, &tile_cutter, options);

    // remove tile if overlapping, modifies canvas_alpha
    try blt.blt(
        BltMaskedColorToTarget(types.Alpha1){
            .source_color = 0,
            .source_width = tile_coder.tile_width,
            .source_height = tile_coder.tile_height,
            .target = alpha_canvas,
            .target_width = canvas_width,
            .target_height = canvas_height,
            .position_x = x_position_tile,
            .position_y = y_position_tile,
            .source_bit_mask = &tile_cutter,
        },
    );

    const image_width = image.info.tile_object.image_width;
    const image_height = image.info.tile_object.tile_offset + tile_coder.tile_image_height_offset;
    const x_position_image = if (image.info.tile_object.image_offset_x > 0) @as(usize, @intCast(@as(isize, image.dimensions.offset_x) + image.info.tile_object.image_offset_x)) else image.dimensions.offset_x;
    const y_position_image = image.dimensions.offset_y;

    image.data.tile_object.image = try tgx_coder.encode(
        types.Argb1555,
        allocator,
        &types.RawTgxStream.take(types.Argb1555, color_canvas, alpha_canvas),
        canvas_width,
        canvas_height,
        image_width,
        image_height,
        x_position_image,
        y_position_image,
        options,
        null,
    );

    // re-add alpha tile
    try blt.blt(
        BltFilteredImageToTarget(types.Alpha1){
            .source_image = &tile_alpha,
            .source_width = tile_coder.tile_width,
            .source_height = tile_coder.tile_height,
            .target = alpha_canvas,
            .target_width = canvas_width,
            .target_height = canvas_height,
            .position_x = x_position_tile,
            .position_y = y_position_tile,
            .source_ignore_value = 0,
        },
    );
}

pub fn saveFile(self: *const Self, file_path: []const u8) !void {
    std.log.info("Saving file: {s}", .{file_path});
    if (!std.mem.eql(u8, std.fs.path.extension(file_path), gm1_extension)) {
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
    try writer.writeStructEndian(self.gm1_header, .little);
    try writer.writeAll(std.mem.asBytes(self.color_tables));

    switch (self.gm1_header.gm1_type) {
        .tiles_object => {
            var current_offset: usize = 0;
            for (self.images) |*image| {
                try writer.writeInt(u32, @intCast(current_offset), .little);
                current_offset += @sizeOf(tile_coder.Gm1Tile);
                current_offset += image.data.tile_object.image.getEncodedData().len;
            }
            for (self.images) |*image| {
                try writer.writeInt(u32, @intCast(@sizeOf(tile_coder.Gm1Tile) + image.data.tile_object.image.getEncodedData().len), .little);
            }
            for (self.images) |*image| {
                try writer.writeStructEndian(image.dimensions, .little);
                try writer.writeStructEndian(image.info.tile_object, .little);
            }
            for (self.images) |*image| {
                try writer.writeAll(std.mem.asBytes(image.data.tile_object.tile));
                try writer.writeAll(image.data.tile_object.image.getEncodedData());
            }
        },
        .tgx_const_size, .font, .interface, .animations => {
            var current_offset: usize = 0;
            for (self.images) |*image| {
                try writer.writeInt(u32, @intCast(current_offset), .little);
                current_offset += image.data.tgx.getEncodedData().len;
            }
            for (self.images) |*image| {
                try writer.writeInt(u32, @intCast(image.data.tgx.getEncodedData().len), .little);
            }
            for (self.images) |*image| {
                try writer.writeStructEndian(image.dimensions, .little);
                try writer.writeStructEndian(image.info.general, .little);
            }
            for (self.images) |*image| {
                try writer.writeAll(image.data.tgx.getEncodedData());
            }
        },
        .no_compression_1, .no_compression_2 => {
            var current_offset: usize = 0;
            for (self.images) |*image| {
                try writer.writeInt(u32, @intCast(current_offset), .little);
                current_offset += image.data.uncompressed.len * @sizeOf(types.Argb1555);
            }
            for (self.images) |*image| {
                try writer.writeInt(u32, @intCast(image.data.uncompressed.len * @sizeOf(types.Argb1555)), .little);
            }
            for (self.images) |*image| {
                try writer.writeStructEndian(image.dimensions, .little);
                try writer.writeStructEndian(image.info.general, .little);
            }
            for (self.images) |*image| {
                try writer.writeAll(std.mem.sliceAsBytes(image.data.uncompressed));
            }
        },
        else => return error.UnknownGm1Type,
    }

    std.log.info("Saved file: {s}", .{file_path});
}

pub fn saveAsRaw(self: *const Self, allocator: std.mem.Allocator, directory_path: []const u8, options: *const types.CoderOptions) !void {
    std.log.info("Saving to folder: {s}", .{directory_path});

    var dir = std.fs.cwd().makeOpenPath(directory_path, .{}) catch |err| {
        std.log.err("Could not create directory: {s}", .{@errorName(err)});
        return err;
    };
    defer dir.close();

    const canvas_width, const canvas_height = self.determineCanvasSize();

    const canvas_alpha = try allocator.alloc(types.Alpha1, canvas_width * canvas_height);
    defer allocator.free(canvas_alpha);
    @memset(canvas_alpha, 0);

    const canvas_color = try allocator.allocWithOptions(
        u8,
        canvas_alpha.len * switch (self.gm1_header.gm1_type) {
            .animations => @as(usize, @sizeOf(types.Gray8)),
            else => @as(usize, @sizeOf(types.Argb1555)),
        },
        @alignOf(types.Argb1555),
        null,
    );
    defer allocator.free(canvas_color);
    switch (self.gm1_header.gm1_type) {
        .animations => @memset(canvas_color, options.transparent_pixel_fill_index),
        else => @memset(std.mem.bytesAsSlice(types.Argb1555, canvas_color), options.transparent_pixel_raw_color),
    }

    switch (self.gm1_header.gm1_type) {
        .tiles_object => {
            for (self.images) |*image| {
                try self.addTileObjectToCanvas(
                    allocator,
                    image,
                    std.mem.bytesAsSlice(types.Argb1555, canvas_color),
                    canvas_alpha,
                    canvas_width,
                    canvas_height,
                    options,
                );
            }
        },
        .tgx_const_size, .font, .interface => {
            for (self.images) |*image| {
                try self.addGm1TgxToCanvas(
                    types.Argb1555,
                    allocator,
                    image,
                    std.mem.bytesAsSlice(types.Argb1555, canvas_color),
                    canvas_alpha,
                    canvas_width,
                    canvas_height,
                    options,
                );
            }
        },
        .animations => {
            for (self.images) |*image| {
                try self.addGm1TgxToCanvas(
                    types.Gray8,
                    allocator,
                    image,
                    std.mem.bytesAsSlice(types.Gray8, canvas_color),
                    canvas_alpha,
                    canvas_width,
                    canvas_height,
                    options,
                );
            }
        },
        .no_compression_1, .no_compression_2 => {
            for (self.images) |*image| {
                try self.addUncompressedToCanvas(
                    allocator,
                    image,
                    std.mem.bytesAsSlice(types.Argb1555, canvas_color),
                    canvas_alpha,
                    canvas_width,
                    canvas_height,
                    options,
                );
            }
        },
        else => return error.UnknownGm1Type,
    }

    {
        const resource_file = dir.createFile(resource_file_name, .{}) catch |err| {
            std.log.err("Could not create resource file: {s}", .{@errorName(err)});
            return err;
        };
        defer resource_file.close();

        const images_info = try allocator.alloc(std.meta.Child(@FieldType(Gm1Resource, "images")), self.images.len);
        defer allocator.free(images_info);

        for (self.images, 0..) |*image, image_index| {
            images_info[image_index] = .{ &image.dimensions, &image.info };
        }

        try std.json.stringify(&Gm1Resource{
            .info = .{
                .color_size = canvas_color.len * @sizeOf(std.meta.Child(@TypeOf(canvas_color))),
                .alpha_size = canvas_alpha.len * @sizeOf(std.meta.Child(@TypeOf(canvas_alpha))),
                .canvas_width = canvas_width,
                .canvas_height = canvas_height,
            },
            .gm1_header = &self.gm1_header,
            .images = images_info,
        }, .{ .whitespace = .indent_2 }, resource_file.writer());
    }

    dir.writeFile(.{
        .sub_path = color_file_name,
        .data = std.mem.sliceAsBytes(canvas_color),
    }) catch |err| {
        std.log.err("Could not create color file: {s}", .{@errorName(err)});
        return err;
    };

    dir.writeFile(.{
        .sub_path = alpha_file_name,
        .data = std.mem.sliceAsBytes(canvas_alpha),
    }) catch |err| {
        std.log.err("Could not create alpha file: {s}", .{@errorName(err)});
        return err;
    };

    for (self.color_tables, 0..) |*color_table, color_table_index| {
        const palette_file_name = try std.fmt.allocPrint(allocator, palette_file_name_pattern, .{color_table_index});
        defer allocator.free(palette_file_name);
        dir.writeFile(.{
            .sub_path = palette_file_name,
            .data = std.mem.sliceAsBytes(color_table),
        }) catch |err| {
            std.log.err("Could not create palette file: {s}", .{@errorName(err)});
            return err;
        };
    }

    std.log.info("Saved to folder: {s}", .{directory_path});
}

fn determineCanvasSize(self: *const Self) struct { usize, usize } {
    var canvas_width: usize = 0;
    var canvas_height: usize = 0;
    for (self.images) |*image| {
        canvas_width = @max(canvas_width, image.dimensions.offset_x + image.dimensions.width);
        canvas_height = @max(canvas_height, image.dimensions.offset_y + image.dimensions.height);
    }
    return .{ canvas_width, canvas_height };
}

fn addGm1TgxToCanvas(
    self: *const Self,
    comptime T: type,
    allocator: std.mem.Allocator,
    image: *const Gm1Image,
    color_canvas: []T,
    alpha_canvas: []types.Alpha1,
    canvas_width: usize,
    canvas_height: usize,
    options: *const types.CoderOptions,
) !void {
    _ = self;

    var decoding_result = tgx_coder.decode(
        T,
        allocator,
        &image.data.tgx,
        image.dimensions.width,
        image.dimensions.height,
        options,
    ) catch |err| {
        std.log.err("Could not decode image: {s}", .{@errorName(err)});
        return err;
    };
    defer decoding_result.deinit(allocator);

    try blt.blt(
        BltImageToTarget(T){
            .source_image = try decoding_result.getRawData(T),
            .source_width = image.dimensions.width,
            .source_height = image.dimensions.height,
            .target = color_canvas,
            .target_width = canvas_width,
            .target_height = canvas_height,
            .position_x = image.dimensions.offset_x,
            .position_y = image.dimensions.offset_y,
        },
    );
    try blt.blt(
        BltImageToTarget(types.Alpha1){
            .source_image = decoding_result.getRawTransparency(),
            .source_width = image.dimensions.width,
            .source_height = image.dimensions.height,
            .target = alpha_canvas,
            .target_width = canvas_width,
            .target_height = canvas_height,
            .position_x = image.dimensions.offset_x,
            .position_y = image.dimensions.offset_y,
        },
    );
}

fn addUncompressedToCanvas(
    self: *const Self,
    allocator: std.mem.Allocator,
    image: *const Gm1Image,
    color_canvas: []types.Argb1555,
    alpha_canvas: []types.Alpha1,
    canvas_width: usize,
    canvas_height: usize,
    options: *const types.CoderOptions,
) !void {
    _ = self;

    const color, const alpha = try uncompressed_coder.decode(
        allocator,
        image.data.uncompressed,
        image.dimensions.width,
        image.dimensions.height,
        options,
    );
    defer {
        allocator.free(color);
        allocator.free(alpha);
    }

    try blt.blt(
        BltImageToTarget(types.Argb1555){
            .source_image = color,
            .source_width = image.dimensions.width,
            .source_height = image.dimensions.height,
            .target = color_canvas,
            .target_width = canvas_width,
            .target_height = canvas_height,
            .position_x = image.dimensions.offset_x,
            .position_y = image.dimensions.offset_y,
        },
    );
    try blt.blt(
        BltImageToTarget(types.Alpha1){
            .source_image = alpha,
            .source_width = image.dimensions.width,
            .source_height = image.dimensions.height,
            .target = alpha_canvas,
            .target_width = canvas_width,
            .target_height = canvas_height,
            .position_x = image.dimensions.offset_x,
            .position_y = image.dimensions.offset_y,
        },
    );
}

fn addTileObjectToCanvas(
    self: *const Self,
    allocator: std.mem.Allocator,
    image: *const Gm1Image,
    color_canvas: []types.Argb1555,
    alpha_canvas: []types.Alpha1,
    canvas_width: usize,
    canvas_height: usize,
    options: *const types.CoderOptions,
) !void {
    _ = self;

    var tile_color: [tile_coder.raw_tile_size]types.Argb1555 = undefined;
    var tile_alpha: [tile_coder.raw_tile_size]types.Alpha1 = undefined;
    tile_coder.decode(
        image.data.tile_object.tile,
        &tile_color,
        &tile_alpha,
        options,
    );

    const x_position_tile = if (image.info.tile_object.image_offset_x < 0) @as(isize, image.dimensions.offset_x) - image.info.tile_object.image_offset_x else @as(isize, image.dimensions.offset_x);
    const y_position_tile = @as(isize, image.dimensions.offset_y) + image.dimensions.height - tile_coder.tile_height;
    try blt.blt(
        BltMaskedImageToTarget(types.Argb1555){
            .source_image = &tile_color,
            .source_width = tile_coder.tile_width,
            .source_height = tile_coder.tile_height,
            .target = color_canvas,
            .target_width = canvas_width,
            .target_height = canvas_height,
            .position_x = x_position_tile,
            .position_y = y_position_tile,
            .source_bit_mask = &tile_alpha,
        },
    );
    try blt.blt(
        BltFilteredImageToTarget(types.Alpha1){
            .source_image = &tile_alpha,
            .source_width = tile_coder.tile_width,
            .source_height = tile_coder.tile_height,
            .target = alpha_canvas,
            .target_width = canvas_width,
            .target_height = canvas_height,
            .position_x = x_position_tile,
            .position_y = y_position_tile,
            .source_ignore_value = 0,
        },
    );
    if (image.info.tile_object.image_position == Gm1TileObjectImagePosition.none) {
        return;
    }

    const image_width = image.info.tile_object.image_width;
    const image_height = image.info.tile_object.tile_offset + tile_coder.tile_image_height_offset;
    var decoding_result = tgx_coder.decode(
        types.Argb1555,
        allocator,
        &image.data.tile_object.image,
        image_width,
        image_height,
        options,
    ) catch |err| {
        std.log.err("Could not decode tile image: {s}", .{@errorName(err)});
        return err;
    };
    defer decoding_result.deinit(allocator);

    const x_position_image = if (image.info.tile_object.image_offset_x > 0) @as(isize, image.dimensions.offset_x) + image.info.tile_object.image_offset_x else @as(isize, image.dimensions.offset_x);
    const y_position_image = image.dimensions.offset_y;
    try blt.blt(
        BltMaskedImageToTarget(types.Argb1555){
            .source_image = try decoding_result.getRawData(types.Argb1555),
            .source_width = image_width,
            .source_height = image_height,
            .target = color_canvas,
            .target_width = canvas_width,
            .target_height = canvas_height,
            .position_x = x_position_image,
            .position_y = y_position_image,
            .source_bit_mask = decoding_result.getRawTransparency(),
        },
    );
    try blt.blt(
        BltFilteredImageToTarget(types.Alpha1){
            .source_image = decoding_result.getRawTransparency(),
            .source_width = image_width,
            .source_height = image_height,
            .target = alpha_canvas,
            .target_width = canvas_width,
            .target_height = canvas_height,
            .position_x = x_position_image,
            .position_y = y_position_image,
            .source_ignore_value = 0,
        },
    );
}

pub fn validate(self: *const Self, options: *const types.CoderOptions) !void {
    const writer = out.getStdErr();
    try std.json.stringify(&self.gm1_header, .{ .whitespace = .indent_2 }, writer);
    try writer.print("\n", .{});
    out.flushErr();

    switch (self.gm1_header.gm1_type) {
        .tiles_object => {
            for (self.images) |*image| {
                try self.validateTilesObject(image, options);
            }
        },
        .tgx_const_size, .font, .interface, .animations => {
            for (self.images) |*image| {
                try self.validateGm1Tgx(image, options);
            }
        },
        .no_compression_1, .no_compression_2 => {
            for (self.images) |*image| {
                try self.validateUncompressed(image);
            }
        },
        else => return error.UnknownGm1Type,
    }
}

fn validateGm1Tgx(self: *const Self, image: *const Gm1Image, options: *const types.CoderOptions) !void {
    const writer = out.getStdErr();
    defer out.flushErr();

    try writer.print("Validating...", .{});
    out.flushErr();

    const analysis = blk: {
        if (self.gm1_header.gm1_type != Gm1Type.animations) {
            break :blk tgx_coder.analyze(
                types.Argb1555,
                &image.data.tgx,
                image.dimensions.width,
                image.dimensions.height,
                options,
                null,
            );
        }

        // animations use the origin from the header, so to make sense, all of them need to have the same image size
        if (self.gm1_header.width != image.dimensions.width or self.gm1_header.height != image.dimensions.height) {
            break :blk error.AnimationTgxSizeMismatch;
        }
        break :blk tgx_coder.analyze(
            types.Gray8,
            &image.data.tgx,
            self.gm1_header.width,
            self.gm1_header.height,
            options,
            null,
        );
    } catch |err| {
        try writer.print("FAILED: {s}\n", .{@errorName(err)});
        return;
    };
    try writer.print("SUCCESS\n", .{});
    out.flushErr();

    try std.json.stringify(
        .{
            .dimensions = &image.dimensions,
            .info = &image.info.general,
            .analysis = &analysis,
        },
        .{ .whitespace = .indent_2 },
        writer,
    );
    try writer.print("\n", .{});
}

fn validateUncompressed(self: *const Self, image: *const Gm1Image) !void {
    _ = self;

    const writer = out.getStdErr();
    defer out.flushErr();

    try writer.print("Validating...", .{});
    out.flushErr();

    const alpha_pixels_in_uncompressed = uncompressed_coder.analyze(
        image.data.uncompressed,
        image.dimensions.width,
        image.dimensions.height,
    ) catch |err| {
        try writer.print("FAILED: {s}\n", .{@errorName(err)});
        return;
    };
    try writer.print("SUCCESS\n", .{});
    out.flushErr();

    try std.json.stringify(
        .{
            .dimensions = &image.dimensions,
            .info = &image.info.general,
            .alpha_pixels_in_uncompressed = alpha_pixels_in_uncompressed,
        },
        .{ .whitespace = .indent_2 },
        writer,
    );
    try writer.print("\n", .{});
}

fn validateTilesObject(self: *const Self, image: *const Gm1Image, options: *const types.CoderOptions) !void {
    _ = self;

    const writer = out.getStdErr();
    defer out.flushErr();

    try writer.print("Validating...", .{});
    out.flushErr();

    const alpha_pixels_in_tile = tile_coder.analyze(image.data.tile_object.tile);
    var image_analysis: ?types.TgxAnalysis = null;
    if (image.info.tile_object.image_position != Gm1TileObjectImagePosition.none) {
        image_analysis = tgx_coder.analyze(
            types.Argb1555,
            &image.data.tile_object.image,
            image.info.tile_object.image_width,
            image.info.tile_object.tile_offset + tile_coder.tile_image_height_offset,
            options,
            null,
        ) catch |err| {
            try writer.print("FAILED: {s}\n", .{@errorName(err)});
            return;
        };
    }
    try writer.print("SUCCESS\n", .{});
    out.flushErr();

    try std.json.stringify(
        .{
            .dimensions = &image.dimensions,
            .info = &image.info.tile_object,
            .alpha_pixels_in_tile = alpha_pixels_in_tile,
            .analysis = &image_analysis,
        },
        .{ .whitespace = .indent_2 },
        writer,
    );
    try writer.print("\n", .{});
}

pub fn writeEncodedToText(self: *const Self, options: *const types.CoderOptions, writer: anytype) anyerror!void {
    switch (self.gm1_header.gm1_type) {
        .tiles_object => {
            for (self.images) |*image| {
                if (image.info.tile_object.image_position == Gm1TileObjectImagePosition.none) {
                    continue;
                }

                _ = try tgx_coder.analyze(
                    types.Argb1555,
                    &image.data.tile_object.image,
                    image.info.tile_object.image_width,
                    image.info.tile_object.tile_offset + tile_coder.tile_image_height_offset,
                    options,
                    writer,
                );
                try writer.print("\n", .{});
            }
        },
        .tgx_const_size, .font, .interface => {
            for (self.images) |*image| {
                _ = try tgx_coder.analyze(
                    types.Argb1555,
                    &image.data.tgx,
                    image.dimensions.width,
                    image.dimensions.height,
                    options,
                    writer,
                );
                try writer.print("\n", .{});
            }
        },
        .animations => {
            for (self.images) |*image| {
                _ = try tgx_coder.analyze(
                    types.Gray8,
                    &image.data.tgx,
                    self.gm1_header.width,
                    self.gm1_header.height,
                    options,
                    writer,
                );
                try writer.print("\n", .{});
            }
        },
        .no_compression_1, .no_compression_2 => {
            std.log.warn("No tgx text for uncompressed image type: {s}", .{@tagName(self.gm1_header.gm1_type)});
        },
        else => return error.UnknownGm1Type,
    }
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    allocator.destroy(self.color_tables);
    for (self.images) |*image| {
        image.deinit(allocator);
    }
    allocator.free(self.images);
}

test "extract and pack gm1" {
    if (!config.test_data_present) return error.SkipZigTest;

    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    // uses tmp base dir hardcoded, since absolute paths are deprecated mostly and I found to way to get the proper paths
    const dir_name = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &temp_dir.sub_path, "extract" });
    defer std.testing.allocator.free(dir_name);
    const file_name = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &temp_dir.sub_path, "pack", "test.gm1" });
    defer std.testing.allocator.free(file_name);

    try testExtractAndPack(test_data.gm1.tile_cliffs, dir_name, file_name);
    try testExtractAndPack(test_data.gm1.interface_icons2, dir_name, file_name);
    try testExtractAndPack(test_data.gm1.font_stronghold_aa, dir_name, file_name);
    try testExtractAndPack(test_data.gm1.anim_armourer, dir_name, file_name);
    try testExtractAndPack(test_data.gm1.tile_buildings1, dir_name, file_name);
}
fn testExtractAndPack(test_file: []const u8, test_out_dir: []const u8, test_in_file: []const u8) !void {
    const sha_original = try test_data.generateSha256FromFile(test_file);

    {
        var gm1 = try loadFile(std.testing.allocator, test_file);
        defer gm1.deinit(std.testing.allocator);
        try gm1.saveAsRaw(std.testing.allocator, test_out_dir, &.default);
    }

    {
        var gm1 = try loadFromRaw(std.testing.allocator, test_out_dir, &.default);
        defer gm1.deinit(std.testing.allocator);
        try gm1.saveFile(test_in_file);
    }

    const sha_packed = try test_data.generateSha256FromFile(test_in_file);

    try std.testing.expectEqualSlices(u8, &sha_original, &sha_packed);
}
