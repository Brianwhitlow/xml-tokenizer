const std = @import("std");

pub fn main() !void {
    
    var allocator_general_purpose = std.heap.GeneralPurposeAllocator(.{.verbose_log = false}){};
    defer _ = allocator_general_purpose.deinit();
    
    const allocator_main = &allocator_general_purpose.allocator;
    _ = allocator_main;
    
    var i: u16 = '\u{f8}';
    while (i <= '\u{2ff}') : (i += 1) {
        const shifted = i >> 4 << 4;
        std.debug.print("[{}:{x}] {b} -> [{}:{x}] {b}\n", .{i, i, i, shifted, shifted, shifted});
    }
    
}
