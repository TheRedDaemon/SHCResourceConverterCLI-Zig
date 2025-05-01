// arguments

pub const ActionCommand = enum {
    @"test",
    extract,
    pack,
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
