const std = @import("std");

const BltError = error{
    DoesNotFitTarget,
    InvalidBitMaskSize,
};

const CopyInstructionFieldName = enum {
    require_contained,
    ignore_value,
    bit_mask,
};

pub fn CopyInstruction(
    require_contained: bool,
    ignore_value: ?type,
    bit_mask: bool,
) type {
    var fields: []const std.builtin.Type.StructField = &.{};
    if (require_contained) {
        fields = fields ++ &[_]std.builtin.Type.StructField{.{
            .name = @tagName(CopyInstructionFieldName.require_contained),
            .type = void,
            .default_value_ptr = &{},
            .is_comptime = false,
            .alignment = 0,
        }};
    }
    if (ignore_value) |value_type| {
        fields = fields ++ &[_]std.builtin.Type.StructField{.{
            .name = @tagName(CopyInstructionFieldName.ignore_value),
            .type = value_type,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = 0,
        }};
    }
    if (bit_mask) {
        fields = fields ++ &[_]std.builtin.Type.StructField{.{
            .name = @tagName(CopyInstructionFieldName.bit_mask),
            .type = []const u1,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = 0,
        }};
    }
    return @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .fields = fields[0..],
            .decls = &[_]std.builtin.Type.Declaration{},
            .is_tuple = false,
        },
    });
}

pub fn blt(
    comptime T: type,
    comptime instruction: anytype,
    source: []const T,
    source_height: usize,
    source_width: usize,
    destination: []T,
    destination_height: usize,
    destination_width: usize,
    position_x: isize,
    position_y: isize,
) BltError!void {
    const InstructionType = if (@typeInfo(@TypeOf(instruction)) == .pointer) std.meta.Child(@TypeOf(instruction)) else @TypeOf(instruction);

    const require_contained = @hasField(InstructionType, @tagName(CopyInstructionFieldName.require_contained));
    const x_start, const x_end, const y_start, const y_end, const x_start_source, const y_start_source = if (require_contained) blk: {
        const intern_x_end = position_x + @as(isize, @intCast(source_width));
        const intern_y_end = position_y + @as(isize, @intCast(source_height));

        if (position_x < 0 or
            position_y < 0 or
            intern_x_end > destination_width or
            intern_y_end > destination_height)
        {
            return BltError.DoesNotFitTarget;
        }
        break :blk .{
            @as(usize, @intCast(position_x)),
            @as(usize, @intCast(intern_x_end)),
            @as(usize, @intCast(position_y)),
            @as(usize, @intCast(intern_y_end)),
            0,
            0,
        };
    } else blk: {
        const intern_x_start_source = if (position_x < 0) @abs(position_x) else 0;
        const intern_y_start_source = if (position_y < 0) @abs(position_y) else 0;

        break :blk .{
            if (intern_x_start_source > 0) 0 else @as(usize, @intCast(position_x)),
            value: {
                const intern_end: isize = position_x + @as(isize, @intCast(source_width));
                break :value if (intern_end > destination_width) destination_width else @as(usize, @intCast(intern_end));
            },
            if (intern_y_start_source > 0) 0 else @as(usize, @intCast(position_y)),
            value: {
                const intern_end: isize = position_x + @as(isize, @intCast(source_height));
                break :value if (intern_end > destination_height) destination_height else @as(usize, @intCast(intern_end));
            },
            intern_x_start_source,
            intern_y_start_source,
        };
    };

    const ignore_value = if (@hasField(InstructionType, @tagName(CopyInstructionFieldName.ignore_value))) instruction.ignore_value;
    const bit_mask = blk: {
        if (!@hasField(InstructionType, @tagName(CopyInstructionFieldName.bit_mask))) {
            break :blk;
        }
        if (instruction.bit_mask.len != source.len) {
            return BltError.InvalidBitMaskSize;
        }
        break :blk instruction.bit_mask;
    };

    if (@typeInfo(@TypeOf(ignore_value)) == .void and @typeInfo(@TypeOf(bit_mask)) == .void) {
        for (y_start..y_end, y_start_source..) |y_target, y_source| {
            const lines_target = y_target * destination_width;
            const lines_source = y_source * source_width;
            @memcpy(
                destination[lines_target + x_start .. lines_target + x_end],
                source[lines_source + x_start_source .. lines_source + x_start_source + x_end - x_start],
            );
        }
        return;
    }

    for (y_start..y_end, y_start_source..) |y_target, y_source| {
        const lines_target = y_target * destination_width;
        const lines_source = y_source * source_width;
        for (x_start..x_end, x_start_source..) |x_target, x_source| {
            const index_target = lines_target + x_target;
            const index_source = lines_source + x_source;

            if (@typeInfo(@TypeOf(ignore_value)) != .void) {
                if (source[index_source] == ignore_value) {
                    continue;
                }
            }

            if (@typeInfo(@TypeOf(bit_mask)) != .void) {
                if (bit_mask[index_source] == 0) {
                    continue;
                }
            }

            destination[index_target] = source[index_source];
        }
    }
}

test "blt" {
    const source_width: usize = 2;
    const source_height: usize = 2;
    const destination_width: usize = 3;
    const destination_height: usize = 3;

    const source = [_]u8{1} ** (source_width * source_height);
    var target = [_]u8{0} ** (destination_width * destination_height);

    const Contained = CopyInstruction(true, null, false);
    const contained_instruction: Contained = .{};

    const contained_error = blt(
        u8,
        &contained_instruction,
        &source,
        source_height,
        source_width,
        &target,
        destination_height,
        destination_width,
        -1,
        -1,
    );
    try std.testing.expectError(BltError.DoesNotFitTarget, contained_error);

    @memset(&target, 0);
    try blt(
        u8,
        &contained_instruction,
        &source,
        source_height,
        source_width,
        &target,
        destination_height,
        destination_width,
        0,
        0,
    );
    try std.testing.expectEqualSlices(u8, &.{ 1, 1, 0, 1, 1, 0, 0, 0, 0 }, &target);

    const Ignored = CopyInstruction(false, u8, false);
    const ignored_instruction: Ignored = .{
        .ignore_value = 1,
    };

    @memset(&target, 0);
    try blt(
        u8,
        &ignored_instruction,
        &source,
        source_height,
        source_width,
        &target,
        destination_height,
        destination_width,
        0,
        0,
    );
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0 }, &target);

    const Masked = CopyInstruction(false, null, true);
    const masked_instruction: Masked = .{
        .bit_mask = &.{ 1, 0, 0, 1 },
    };

    @memset(&target, 0);
    try blt(
        u8,
        &masked_instruction,
        &source,
        source_height,
        source_width,
        &target,
        destination_height,
        destination_width,
        2,
        1,
    );
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 1, 0, 0, 0 }, &target);
}
