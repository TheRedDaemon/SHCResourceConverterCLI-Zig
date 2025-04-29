//! A simple CLI to support analysis of SHC files.

const std = @import("std");
const builtin = @import("builtin");
const arguments = @import("arguments.zig");
const logging = @import("logging.zig");

pub const std_options = logging.std_options;

// external to easier set log level
pub fn main() void {
    runWithAllocator(void, internalMain);
}

/// Run a param less function with an allocator depending on the build type.
/// The allocator might be de-initialized after the function returns,
/// however, all allocations and frees need to be handled by the user.
fn runWithAllocator(comptime R: type, comptime func: fn (allocator: std.mem.Allocator) R) R {
    var allocator_handle = switch (builtin.mode) {
        .Debug => std.heap.DebugAllocator(.{}).init,
        else => std.heap.ArenaAllocator.init(std.heap.page_allocator),
    };
    defer switch (builtin.mode) {
        .Debug => if (allocator_handle.deinit() != .ok) @panic("Memory leak detected!"),
        else => allocator_handle.deinit(),
    };
    return switch (@typeInfo(R)) {
        .error_union => try func(allocator_handle.allocator()),
        else => func(allocator_handle.allocator()),
    };
}

fn internalMain(allocator: std.mem.Allocator) void {
    const result = arguments.parseArgs(allocator) catch |err| {
        std.log.err("Failed to parse arguments: {s}", .{@errorName(err)});
        return;
    };
    const log_level, const args = switch (result) {
        .no_action => |level| {
            logging.setLogLevel(level);
            std.log.debug("Requested actionless print actions. Ending process.", .{});
            return;
        },
        .action => result.action,
    };
    logging.setLogLevel(log_level);
    std.log.debug("{}", .{args});
}
