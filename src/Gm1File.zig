const std = @import("std");
const types = @import("types.zig");

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

const Gm1Tile = [256]types.Argb1555;

const Gm1TileObjectImagePosition = enum(u8) {
    none = 0,
    top = 1,
    upper_left = 2,
    upper_right = 3,
    _,
};

const Gm1Image = struct {
    dimensions: extern struct {
        width: u16 align(1),
        height: u16 align(1),
        offset_x: u16 align(1),
        offset_y: u16 align(1),
    },
    info: union(enum) {
        general: extern struct {
            relative_data_pos: i16 align(1), // seems to be used to point to data to use instead
            font_related_size: i16 align(1),
            unknown_0x4: u8 align(1),
            unknown_0x5: u8 align(1),
            unknown_0x6: u8 align(1),
            flags: u8 align(1), // seems to indicate together with game flag if certain animation frames are skipped
        },
        tile_object: extern struct {
            imagePart: u8 align(1),
            subParts: u8 align(1),
            tileOffset: u16 align(1),
            imagePosition: Gm1TileObjectImagePosition align(1),
            imageOffsetX: i8 align(1),
            imageWidth: u8 align(1),
            flags: u8 align(1), // seems to also be flags, not the animation color
        },
    },
    data: union(enum) {
        tgx: types.EncodedTgxStream,
        uncompressed: []const types.Argb1555,
        tile_object: struct {
            image: types.EncodedTgxStream,
            tile: *Gm1Tile,
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

pub const gm1_extension = ".gm1";

const resource_file_name = "resource.json";
const color_file_name = "color.data";
const alpha_file_name = "alpha.data";

const tile_byte_size = @sizeOf(Gm1Tile);
const tile_width = 30;
const tile_height = 16;

const gm1_header_size = @sizeOf(Gm1Header);
const gm1_color_tables_size = @sizeOf(Gm1ColorTables);

const Self = @This();

gm1_header: Gm1Header,
color_tables: *const Gm1ColorTables,
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
                const tile = try allocator.create(Gm1Tile);
                errdefer allocator.destroy(tile);
                try reader.readNoEof(std.mem.asBytes(tile));

                const data = try allocator.alloc(u8, data_sizes[image_index] - tile_byte_size);
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

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    allocator.destroy(self.color_tables);
    for (self.images) |*image| {
        image.deinit(allocator);
    }
    allocator.free(self.images);
}
