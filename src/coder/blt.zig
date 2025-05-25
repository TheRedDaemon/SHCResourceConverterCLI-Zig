const std = @import("std");

const BltError = error{
    InvalidDataSize,
    InvalidBitMaskSize,
};

const CopyInstructionFieldName = enum {
    value_type,
    source_mode,
    source_image,
    source_width,
    source_height,
    source_color,
    position_mode,
    source_ignore_value,
    source_bit_mask,
    target_ignore_value,
    target_bit_mask,
    target,
    target_width,
    target_height,
    position_x,
    position_y,
};

pub const PositionMode = enum {
    source,
    target,
};

pub const SourceMode = enum {
    image,
    color,
};

pub const CopyInstructionSettings = struct {
    value_type: type,
    source_mode: SourceMode,
    position_mode: PositionMode,
    source_ignore_value: bool = false,
    source_bit_mask: bool = false,
    target_ignore_value: bool = false,
    target_bit_mask: bool = false,
};

fn createSimpleStructField(field_name: CopyInstructionFieldName, field_type: type) std.builtin.Type.StructField {
    return .{
        .name = @tagName(field_name),
        .type = field_type,
        .default_value_ptr = null,
        .is_comptime = false,
        .alignment = 0,
    };
}

pub fn CopyInstruction(settings: CopyInstructionSettings) type {
    var fields: []const std.builtin.Type.StructField = &.{};
    const value_type = settings.value_type;
    const source_mode = settings.source_mode;
    const position_mode = settings.position_mode;

    fields = fields ++ &[_]std.builtin.Type.StructField{.{
        .name = @tagName(CopyInstructionFieldName.value_type),
        .type = type,
        .default_value_ptr = &value_type,
        .is_comptime = true,
        .alignment = 0,
    }};
    fields = fields ++ &[_]std.builtin.Type.StructField{.{
        .name = @tagName(CopyInstructionFieldName.source_mode),
        .type = SourceMode,
        .default_value_ptr = &source_mode,
        .is_comptime = true,
        .alignment = 0,
    }};
    fields = fields ++ &[_]std.builtin.Type.StructField{.{
        .name = @tagName(CopyInstructionFieldName.position_mode),
        .type = PositionMode,
        .default_value_ptr = &position_mode,
        .is_comptime = true,
        .alignment = 0,
    }};

    fields = switch (settings.source_mode) {
        .image => fields ++ .{createSimpleStructField(CopyInstructionFieldName.source_image, []const value_type)},
        .color => fields ++ .{createSimpleStructField(CopyInstructionFieldName.source_color, value_type)},
    };
    fields = fields ++ .{createSimpleStructField(CopyInstructionFieldName.source_width, usize)};
    fields = fields ++ .{createSimpleStructField(CopyInstructionFieldName.source_height, usize)};
    if (settings.source_ignore_value) {
        fields = fields ++ .{createSimpleStructField(CopyInstructionFieldName.source_ignore_value, value_type)};
    }
    if (settings.source_bit_mask) {
        fields = fields ++ .{createSimpleStructField(CopyInstructionFieldName.source_bit_mask, []const u1)};
    }
    fields = fields ++ .{createSimpleStructField(CopyInstructionFieldName.target, []value_type)};
    fields = fields ++ .{createSimpleStructField(CopyInstructionFieldName.target_width, usize)};
    fields = fields ++ .{createSimpleStructField(CopyInstructionFieldName.target_height, usize)};
    if (settings.target_ignore_value) {
        fields = fields ++ .{createSimpleStructField(CopyInstructionFieldName.target_ignore_value, value_type)};
    }
    if (settings.target_bit_mask) {
        fields = fields ++ .{createSimpleStructField(CopyInstructionFieldName.target_bit_mask, []const u1)};
    }
    fields = fields ++ .{createSimpleStructField(CopyInstructionFieldName.position_x, isize)};
    fields = fields ++ .{createSimpleStructField(CopyInstructionFieldName.position_y, isize)};

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
    instruction: anytype,
) BltError!void {
    const InstructionType = if (@typeInfo(@TypeOf(instruction)) == .pointer) std.meta.Child(@TypeOf(instruction)) else @TypeOf(instruction);

    const source_image = if (instruction.source_mode == .image) instruction.source_image;
    const source_color = if (instruction.source_mode == .color) instruction.source_color;
    const source_width = instruction.source_width;
    const source_height = instruction.source_height;
    const source_ignore_value = if (@hasField(InstructionType, @tagName(CopyInstructionFieldName.source_ignore_value))) instruction.source_ignore_value;
    const source_bit_mask = blk: {
        if (!@hasField(InstructionType, @tagName(CopyInstructionFieldName.source_bit_mask))) {
            break :blk;
        }
        if (instruction.source_bit_mask.len != source_width * source_height) {
            return BltError.InvalidBitMaskSize;
        }
        break :blk instruction.source_bit_mask;
    };
    const target = instruction.target;
    const target_width = instruction.target_width;
    const target_height = instruction.target_height;
    const target_ignore_value = if (@hasField(InstructionType, @tagName(CopyInstructionFieldName.target_ignore_value))) instruction.target_ignore_value;
    const target_bit_mask = blk: {
        if (!@hasField(InstructionType, @tagName(CopyInstructionFieldName.target_bit_mask))) {
            break :blk;
        }
        if (instruction.target_bit_mask.len != target_width * target_height) {
            return BltError.InvalidBitMaskSize;
        }
        break :blk instruction.target_bit_mask;
    };
    const source_position_x, const source_position_y = switch (instruction.position_mode) {
        .source => .{ -instruction.position_x, -instruction.position_y },
        .target => .{ instruction.position_x, instruction.position_y },
    };
    if ((instruction.source_mode == .image and source_image.len != source_width * source_height) or target.len != target_width * target_height) {
        return BltError.InvalidDataSize;
    }

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

    if (@typeInfo(@TypeOf(source_ignore_value)) == .void and
        @typeInfo(@TypeOf(target_ignore_value)) == .void and
        @typeInfo(@TypeOf(source_bit_mask)) == .void and
        @typeInfo(@TypeOf(target_bit_mask)) == .void)
    {
        for (y_start_target..y_end_target, y_start_source..) |y_target, y_source| {
            const lines_target = y_target * target_width;
            switch (instruction.source_mode) {
                .image => {
                    const lines_source = y_source * source_width;
                    @memcpy(
                        target[lines_target + x_start_target .. lines_target + x_end_target],
                        source_image[lines_source + x_start_source .. lines_source + x_start_source + x_end_target - x_start_target],
                    );
                },
                .color => {
                    @memset(
                        target[lines_target + x_start_target .. lines_target + x_end_target],
                        source_color,
                    );
                },
            }
        }
        return;
    }

    for (y_start_target..y_end_target, y_start_source..) |y_target, y_source| {
        const lines_target = y_target * target_width;
        const lines_source = y_source * source_width;
        for (x_start_target..x_end_target, x_start_source..) |x_target, x_source| {
            const index_source = lines_source + x_source;
            const index_target = lines_target + x_target;

            if (@typeInfo(@TypeOf(source_ignore_value)) != .void) {
                switch (instruction.source_mode) {
                    .image => if (source_image[index_source] == source_ignore_value) continue,
                    .color => if (source_color == source_ignore_value) continue,
                }
            }

            if (@typeInfo(@TypeOf(source_bit_mask)) != .void) {
                if (source_bit_mask[index_source] == 0) continue;
            }

            if (@typeInfo(@TypeOf(target_ignore_value)) != .void) {
                if (target[index_target] == target_ignore_value) continue;
            }

            if (@typeInfo(@TypeOf(target_bit_mask)) != .void) {
                if (target_bit_mask[index_target] == 0) continue;
            }

            target[index_target] = switch (instruction.source_mode) {
                .image => source_image[index_source],
                .color => source_color,
            };
        }
    }
}

test "blt" {
    const source_width: usize = 2;
    const source_height: usize = 2;
    const target_width: usize = 3;
    const target_height: usize = 4;

    const source: []u8 = try std.testing.allocator.alloc(u8, source_width * source_height);
    defer std.testing.allocator.free(source);
    @memset(source, 1);
    const target: []u8 = try std.testing.allocator.alloc(u8, target_width * target_height);
    defer std.testing.allocator.free(target);
    @memset(target, 0);

    const Simple = CopyInstruction(.{
        .value_type = u8,
        .source_mode = SourceMode.image,
        .position_mode = PositionMode.target,
    });

    @memset(target, 0);
    try blt(
        Simple{
            .source_image = source,
            .source_height = source_height,
            .source_width = source_width,
            .target = target,
            .target_height = target_height,
            .target_width = target_width,
            .position_x = 0,
            .position_y = 0,
        },
    );
    try std.testing.expectEqualSlices(u8, &.{ 1, 1, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0 }, target);

    const Ignored = CopyInstruction(.{
        .value_type = u8,
        .source_mode = SourceMode.image,
        .position_mode = PositionMode.target,
        .source_ignore_value = true,
    });
    const ignored_instruction: Ignored = .{
        .source_image = source,
        .source_height = source_height,
        .source_width = source_width,
        .target = target,
        .target_height = target_height,
        .target_width = target_width,
        .position_x = 0,
        .position_y = 0,
        .source_ignore_value = 1,
    };

    @memset(target, 0);
    try blt(&ignored_instruction);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, target);

    const Masked = CopyInstruction(.{
        .value_type = u8,
        .source_mode = SourceMode.image,
        .position_mode = PositionMode.target,
        .source_bit_mask = true,
    });

    var bit_mask: []u1 = try std.testing.allocator.alloc(u1, source_width * source_height);
    defer std.testing.allocator.free(bit_mask);
    bit_mask[0] = 1;
    bit_mask[1] = 0;
    bit_mask[2] = 0;
    bit_mask[3] = 1;

    const masked_instruction: Masked = .{
        .source_image = source,
        .source_height = source_height,
        .source_width = source_width,
        .target = target,
        .target_height = target_height,
        .target_width = target_width,
        .position_x = 2,
        .position_y = 1,
        .source_bit_mask = bit_mask,
    };

    @memset(target, 0);
    try blt(&masked_instruction);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0 }, target);

    const copy_source_width: usize = target_width;
    const copy_source_height: usize = target_height;
    const copy_target_width: usize = source_width;
    const copy_target_height: usize = source_height;

    const copy_source = target;
    const copy_target = source;

    const SimpleCopy = CopyInstruction(.{
        .value_type = u8,
        .source_mode = SourceMode.image,
        .position_mode = PositionMode.source,
    });

    @memset(copy_source, 1);
    @memset(copy_target, 0);
    try blt(
        SimpleCopy{
            .source_image = copy_source,
            .source_width = copy_source_width,
            .source_height = copy_source_height,
            .target = copy_target,
            .target_width = copy_target_width,
            .target_height = copy_target_height,
            .position_x = 2,
            .position_y = -1,
        },
    );
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 1, 0 }, copy_target);

    const IgnoreTarget = CopyInstruction(.{
        .value_type = u8,
        .source_mode = SourceMode.image,
        .position_mode = PositionMode.source,
        .target_ignore_value = true,
    });

    @memset(copy_source, 1);
    @memset(copy_target, 0);
    try blt(
        IgnoreTarget{
            .source_image = copy_source,
            .source_width = copy_source_width,
            .source_height = copy_source_height,
            .target = copy_target,
            .target_width = copy_target_width,
            .target_height = copy_target_height,
            .position_x = 0,
            .position_y = 0,
            .target_ignore_value = 0,
        },
    );
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, copy_target);

    const ColorToTarget = CopyInstruction(.{
        .value_type = u8,
        .source_mode = SourceMode.color,
        .position_mode = PositionMode.target,
    });

    @memset(target, 0);
    try blt(
        ColorToTarget{
            .source_color = 2,
            .source_width = source_width,
            .source_height = source_height,
            .target = target,
            .target_width = target_width,
            .target_height = target_height,
            .position_x = 1,
            .position_y = 1,
        },
    );
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 2, 2, 0, 2, 2, 0, 0, 0 }, target);
}
