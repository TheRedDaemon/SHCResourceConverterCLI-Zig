const std = @import("std");

// arguments

pub const CoderOptions = struct {
    transparent_pixel_tgx_color: Argb1555,
    transparent_pixel_raw_color: Argb1555,
    transparent_pixel_fill_index: Gray8,
    pixel_repeat_threshold: u8,
    padding_alignment: u8,

    pub const default = CoderOptions{
        .transparent_pixel_tgx_color = @bitCast(@as(u16, 0b1111100000011111)), // used by game for some cases (repeating pixels seem excluded?)
        .transparent_pixel_raw_color = @bitCast(@as(u16, 0)), // for placing transparency and identification of it
        .transparent_pixel_fill_index = 0, // for placing an index in the the raw output
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
