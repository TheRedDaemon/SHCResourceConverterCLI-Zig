const std = @import("std");

const BltError = error{
    InvalidDataSize,
    InvalidBitMaskSize,
};

const CopyInstructionFieldName = enum {
    position_mode,
    source_ignore_value,
    source_bit_mask,
    target_ignore_value,
    target_bit_mask,
};

const DefaultValues = struct {
    pub const @"true" = true;
    pub const @"false" = false;
};

pub const PositionMode = enum {
    source,
    target,
};

pub fn CopyInstruction(
    position_mode: PositionMode,
    source_ignore_value: ?type,
    source_bit_mask: bool,
    target_ignore_value: ?type,
    target_bit_mask: bool,
) type {
    var fields: []const std.builtin.Type.StructField = &.{};
    fields = fields ++ &[_]std.builtin.Type.StructField{.{
        .name = @tagName(CopyInstructionFieldName.position_mode),
        .type = PositionMode,
        .default_value_ptr = switch (position_mode) {
            .source => &PositionMode.source,
            .target => &PositionMode.target,
        },
        .is_comptime = true,
        .alignment = 0,
    }};
    if (source_ignore_value) |value_type| {
        fields = fields ++ &[_]std.builtin.Type.StructField{.{
            .name = @tagName(CopyInstructionFieldName.source_ignore_value),
            .type = value_type,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = 0,
        }};
    }
    if (target_ignore_value) |value_type| {
        fields = fields ++ &[_]std.builtin.Type.StructField{.{
            .name = @tagName(CopyInstructionFieldName.target_ignore_value),
            .type = value_type,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = 0,
        }};
    }
    if (source_bit_mask) {
        fields = fields ++ &[_]std.builtin.Type.StructField{.{
            .name = @tagName(CopyInstructionFieldName.source_bit_mask),
            .type = []const u1,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = 0,
        }};
    }
    if (target_bit_mask) {
        fields = fields ++ &[_]std.builtin.Type.StructField{.{
            .name = @tagName(CopyInstructionFieldName.target_bit_mask),
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
    instruction: anytype,
    source: []const T,
    source_width: usize,
    source_height: usize,
    target: []T,
    target_width: usize,
    target_height: usize,
    position_x: isize,
    position_y: isize,
) BltError!void {
    if (source.len != source_width * source_height or target.len != target_width * target_height) {
        return BltError.InvalidDataSize;
    }

    const InstructionType = if (@typeInfo(@TypeOf(instruction)) == .pointer) std.meta.Child(@TypeOf(instruction)) else @TypeOf(instruction);

    const source_position_x, const source_position_y = switch (instruction.position_mode) {
        .source => .{ -position_x, -position_y },
        .target => .{ position_x, position_y },
    };

    const x_start_target, const x_end_target, const y_start_target, const y_end_target, const x_start_source, const y_start_source = blk: {
        const intern_x_start_source = if (source_position_x < 0) @abs(source_position_x) else 0;
        const intern_y_start_source = if (source_position_y < 0) @abs(source_position_y) else 0;

        break :blk .{
            if (intern_x_start_source > 0) 0 else @as(usize, @intCast(source_position_x)),
            value: {
                const intern_end: isize = source_position_x + @as(isize, @intCast(source_width));
                break :value if (intern_end > target_width) target_width else @as(usize, @intCast(intern_end));
            },
            if (intern_y_start_source > 0) 0 else @as(usize, @intCast(source_position_y)),
            value: {
                const intern_end: isize = source_position_y + @as(isize, @intCast(source_height));
                break :value if (intern_end > target_height) target_height else @as(usize, @intCast(intern_end));
            },
            intern_x_start_source,
            intern_y_start_source,
        };
    };

    const source_ignore_value = if (@hasField(InstructionType, @tagName(CopyInstructionFieldName.source_ignore_value))) instruction.source_ignore_value;
    const source_bit_mask = blk: {
        if (!@hasField(InstructionType, @tagName(CopyInstructionFieldName.source_bit_mask))) {
            break :blk;
        }
        if (instruction.source_bit_mask.len != source.len) {
            return BltError.InvalidBitMaskSize;
        }
        break :blk instruction.source_bit_mask;
    };
    const target_ignore_value = if (@hasField(InstructionType, @tagName(CopyInstructionFieldName.target_ignore_value))) instruction.target_ignore_value;
    const target_bit_mask = blk: {
        if (!@hasField(InstructionType, @tagName(CopyInstructionFieldName.target_bit_mask))) {
            break :blk;
        }
        if (instruction.target_bit_mask.len != target.len) {
            return BltError.InvalidBitMaskSize;
        }
        break :blk instruction.target_bit_mask;
    };

    if (@typeInfo(@TypeOf(source_ignore_value)) == .void and
        @typeInfo(@TypeOf(target_ignore_value)) == .void and
        @typeInfo(@TypeOf(source_bit_mask)) == .void and
        @typeInfo(@TypeOf(target_bit_mask)) == .void)
    {
        for (y_start_target..y_end_target, y_start_source..) |y_target, y_source| {
            const lines_target = y_target * target_width;
            const lines_source = y_source * source_width;
            @memcpy(
                target[lines_target + x_start_target .. lines_target + x_end_target],
                source[lines_source + x_start_source .. lines_source + x_start_source + x_end_target - x_start_target],
            );
        }
        return;
    }

    for (y_start_target..y_end_target, y_start_source..) |y_target, y_source| {
        const lines_target = y_target * target_width;
        const lines_source = y_source * source_width;
        for (x_start_target..x_end_target, x_start_source..) |x_target, x_source| {
            const index_target = lines_target + x_target;
            const index_source = lines_source + x_source;

            if (@typeInfo(@TypeOf(source_ignore_value)) != .void) {
                if (source[index_source] == source_ignore_value) {
                    continue;
                }
            }

            if (@typeInfo(@TypeOf(source_bit_mask)) != .void) {
                if (source_bit_mask[index_source] == 0) {
                    continue;
                }
            }

            if (@typeInfo(@TypeOf(target_ignore_value)) != .void) {
                if (target[index_target] == target_ignore_value) {
                    continue;
                }
            }

            if (@typeInfo(@TypeOf(target_bit_mask)) != .void) {
                if (target_bit_mask[index_target] == 0) {
                    continue;
                }
            }

            target[index_target] = source[index_source];
        }
    }
}

test "blt" {
    const source_width: usize = 2;
    const source_height: usize = 2;
    const target_width: usize = 3;
    const target_height: usize = 3;

    const source: []u8 = try std.testing.allocator.alloc(u8, source_width * source_height);
    defer std.testing.allocator.free(source);
    @memset(source, 1);
    const target: []u8 = try std.testing.allocator.alloc(u8, target_width * target_height);
    defer std.testing.allocator.free(target);
    @memset(target, 0);

    const Simple = CopyInstruction(PositionMode.target, null, false, null, false);

    @memset(target, 0);
    try blt(
        u8,
        Simple{},
        source,
        source_height,
        source_width,
        target,
        target_height,
        target_width,
        0,
        0,
    );
    try std.testing.expectEqualSlices(u8, &.{ 1, 1, 0, 1, 1, 0, 0, 0, 0 }, target);

    const Ignored = CopyInstruction(PositionMode.target, u8, false, null, false);
    const ignored_instruction: Ignored = .{
        .source_ignore_value = 1,
    };

    @memset(target, 0);
    try blt(
        u8,
        &ignored_instruction,
        source,
        source_height,
        source_width,
        target,
        target_height,
        target_width,
        0,
        0,
    );
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0 }, target);

    const Masked = CopyInstruction(PositionMode.target, null, true, null, false);

    var bit_mask: []u1 = try std.testing.allocator.alloc(u1, source_width * source_height);
    defer std.testing.allocator.free(bit_mask);
    bit_mask[0] = 1;
    bit_mask[1] = 0;
    bit_mask[2] = 0;
    bit_mask[3] = 1;

    const masked_instruction: Masked = .{
        .source_bit_mask = bit_mask,
    };

    @memset(target, 0);
    try blt(
        u8,
        &masked_instruction,
        source,
        source_height,
        source_width,
        target,
        target_height,
        target_width,
        2,
        1,
    );
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 1, 0, 0, 0 }, target);

    const copy_source_width: usize = target_width;
    const copy_source_height: usize = target_height;
    const copy_target_width: usize = source_width;
    const copy_target_height: usize = source_height;

    const copy_source = target;
    const copy_target = source;

    const SimpleCopy = CopyInstruction(PositionMode.source, null, false, null, false);

    @memset(copy_source, 1);
    @memset(copy_target, 0);
    try blt(
        u8,
        SimpleCopy{},
        copy_source,
        copy_source_width,
        copy_source_height,
        copy_target,
        copy_target_width,
        copy_target_height,
        2,
        -1,
    );
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 1, 0 }, copy_target);

    const IgnoreTarget = CopyInstruction(PositionMode.source, null, false, u8, false);

    @memset(copy_source, 1);
    @memset(copy_target, 0);
    try blt(
        u8,
        IgnoreTarget{ .target_ignore_value = 0 },
        copy_source,
        copy_source_width,
        copy_source_height,
        copy_target,
        copy_target_width,
        copy_target_height,
        0,
        0,
    );
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, copy_target);
}
