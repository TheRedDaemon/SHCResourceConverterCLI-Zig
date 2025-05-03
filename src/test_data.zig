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
};

test "test comptime path join" {
    try std.testing.expectEqualStrings(test_data_folder ++ std.fs.path.sep_str ++ "armys10.tgx", tgx.armys10);
}
