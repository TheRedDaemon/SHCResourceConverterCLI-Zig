const std = @import("std");

// arguments

pub const CoderOptions = struct {
    transparent_pixel_tgx_color: Argb1555,
    transparent_pixel_raw_color: Argb1555,
    pixel_repeat_threshold: u8,
    padding_alignment: u8,
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
            .@"test" => |@"test"| {
                allocator.free(@"test".file_in);
            },
            .extract => |extract| {
                allocator.free(extract.file_in);
                allocator.free(extract.dir_out);
            },
            .pack => |pack| {
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

// tgx coder

pub const default_game_transparent_color: Argb1555 = @bitCast(@as(u16, 0b1111100000011111)); // used by game for some cases (repeating pixels seem excluded?)
pub const default_tgx_file_transparent: Argb1555 = @bitCast(@as(u16, 0)); // for placing transparency and identification of it
pub const default_tgx_file_pixel_repeat_threshold: u8 = 3;
pub const default_tgx_file_padding_alignment: u8 = 4;
