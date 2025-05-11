const std = @import("std");

const path_sep = std.fs.path.sep;

const test_data_folder = "test_data";

fn joinComptime(comptime paths: []const []const u8) []const u8 {
    var result: []const u8 = "";
    for (paths) |path| {
        if (result.len > 0) {
            result = result ++ std.fs.path.sep_str;
        }
        result = result ++ path;
    }
    return result;
}

pub const tgx = struct {
    pub const armys10 = joinComptime(&.{ test_data_folder, "armys10.tgx" });
    pub const SHC_back = joinComptime(&.{ test_data_folder, "SHC_back.tgx" });
    pub const chicken_sketch = joinComptime(&.{ test_data_folder, "chicken_sketch.tgx" });
    pub const @"1280r" = joinComptime(&.{ test_data_folder, "1280r.tgx" });
    pub const armourer_sketch = joinComptime(&.{ test_data_folder, "armourer_sketch.tgx" });
};

pub const gm1 = struct {
    pub const font_stronghold_aa = joinComptime(&.{ test_data_folder, "font_stronghold_aa.gm1" });
    pub const anim_armourer = joinComptime(&.{ test_data_folder, "anim_armourer.gm1" });
    pub const interface_icons2 = joinComptime(&.{ test_data_folder, "interface_icons2.gm1" });
    pub const tile_buildings1 = joinComptime(&.{ test_data_folder, "tile_buildings1.gm1" });
    pub const tile_cliffs = joinComptime(&.{ test_data_folder, "tile_cliffs.gm1" });
};

test "test comptime path join" {
    try std.testing.expectEqualStrings(test_data_folder ++ std.fs.path.sep_str ++ "armys10.tgx", tgx.armys10);
}
