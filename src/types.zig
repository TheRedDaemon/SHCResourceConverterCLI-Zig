const std = @import("std");

// arguments

pub const CoderOptions = struct {
    transparent_pixel_tgx_color: Argb1555,
    transparent_pixel_raw_color: Argb1555,
    transparent_pixel_fill_index: Gray8,
    grid_pixel_raw_color: Argb1555,
    grid_pixel_fill_index: Gray8,
    pixel_repeat_threshold: u8,
    padding_alignment: u8,

    pub const default = CoderOptions{
        .transparent_pixel_tgx_color = @bitCast(@as(u16, 0b1111100000011111)), // used by game for some cases (repeating pixels seem excluded?)
        .transparent_pixel_raw_color = @bitCast(@as(u16, 0)), // for placing transparency and identification of it
        .transparent_pixel_fill_index = 0, // for placing an index in the the raw output
        .grid_pixel_raw_color = @bitCast(@as(u16, 0b1000000000000000)), // was likely used to represent a grid for certain types
        .grid_pixel_fill_index = 1, // was likely used to represent a grid
        .pixel_repeat_threshold = 3,
        .padding_alignment = 4,
    };
};

pub const ActionCommand = enum {
    @"test",
    extract,
    pack,
};

/// Contains all possible actions.
/// Needs to be deinited after usage.
pub const ActionArgs = union(ActionCommand) {
    @"test": struct {
        print_tgx_to_text: bool,
        file_in: []const u8,
    },
    extract: struct {
        file_in: []const u8,
        dir_out: []const u8,
    },
    pack: struct {
        dir_in: []const u8,
        file_out: []const u8,
    },

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        switch (self.*) {
            .@"test" => |*@"test"| {
                allocator.free(@"test".file_in);
            },
            .extract => |*extract| {
                allocator.free(extract.file_in);
                allocator.free(extract.dir_out);
            },
            .pack => |*pack| {
                allocator.free(pack.dir_in);
                allocator.free(pack.file_out);
            },
        }
    }
};

// resource elements

pub const Argb1555 = packed struct {
    b: u5,
    g: u5,
    r: u5,
    a: u1,
};

pub const Gray8 = u8;

pub const Alpha1 = u1;

/// Meant to contain the encoded tgx data stream.
///
/// Takes ownership of the memory and needs to be freed after usage if not used further.
/// The user requires access to the allocator used for the contained memory.
pub const EncodedTgxStream = struct {
    data: []const u8,

    /// Takes ownership of the memory and needs to be freed after usage if not used further.
    pub fn take(data: []const u8) EncodedTgxStream {
        return .{ .data = data };
    }

    pub fn deinit(self: *EncodedTgxStream, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }

    pub fn getEncodedData(self: *const EncodedTgxStream) []const u8 {
        return self.data;
    }
};

/// Meant to contain the raw tgx data streams.
///
/// Takes ownership of the memory and needs to be freed after usage if not used further.
/// The user requires access to the allocator used for the contained memory.
pub const RawTgxStream = union(enum) {
    pixel: struct {
        pixels: []const Argb1555,
        transparency: []const Alpha1,
    },
    index: struct {
        indexes: []const Gray8,
        transparency: []const Alpha1,
    },

    /// Takes ownership of the memory and needs to be freed after usage if not used further.
    pub fn take(comptime PixelType: type, pixels: []const PixelType, transparency: []const Alpha1) RawTgxStream {
        return switch (PixelType) {
            Argb1555 => .{
                .pixel = .{
                    .pixels = pixels,
                    .transparency = transparency,
                },
            },
            Gray8 => .{
                .index = .{
                    .indexes = pixels,
                    .transparency = transparency,
                },
            },
            else => @compileError("PixelType must be Argb1555 or Gray8."),
        };
    }

    pub fn deinit(self: *RawTgxStream, allocator: std.mem.Allocator) void {
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

    pub fn getRawData(self: *const RawTgxStream, comptime PixelType: type) error{WrongPixelType}![]const PixelType {
        return switch (PixelType) {
            Argb1555 => switch (self.*) {
                .pixel => |*pixel| pixel.pixels,
                else => error.WrongPixelType,
            },
            Gray8 => switch (self.*) {
                .index => |*index| index.indexes,
                else => error.WrongPixelType,
            },
            else => @compileError("PixelType must match Union."),
        };
    }

    pub fn getRawTransparency(self: *const RawTgxStream) []const Alpha1 {
        return switch (self.*) {
            .pixel => |*pixel| pixel.transparency,
            .index => |*index| index.transparency,
        };
    }
};

// tgx coder analysis

const TgxAnalysisMarker = struct {
    marker_count: usize,
    pixel_count: usize,
};

const TgxAnalysisNewline = struct {
    normal_marker_count: usize,
    newline_without_marker_count: usize,
    unfinished_width_pixel_count: usize,
    padding_marker_count: usize,
};

pub const TgxAnalysis = struct {
    pixel: TgxAnalysisMarker,
    transparent: TgxAnalysisMarker,
    repeating: TgxAnalysisMarker,
    newline: TgxAnalysisNewline,
    color_pixel_with_alpha_zero: usize,

    pub const empty: TgxAnalysis = .{
        .pixel = .{ .marker_count = 0, .pixel_count = 0 },
        .transparent = .{ .marker_count = 0, .pixel_count = 0 },
        .repeating = .{ .marker_count = 0, .pixel_count = 0 },
        .newline = .{
            .normal_marker_count = 0,
            .newline_without_marker_count = 0,
            .unfinished_width_pixel_count = 0,
            .padding_marker_count = 0,
        },
        .color_pixel_with_alpha_zero = 0,
    };
};
