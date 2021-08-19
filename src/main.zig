const std = @import("std");
const xml = @import("xml.zig");

pub fn main() anyerror!void {
    
    var allocator_general_purpose = std.heap.GeneralPurposeAllocator(.{.verbose_log = false}){};
    defer _ = allocator_general_purpose.deinit();
    
    const allocator_main = &allocator_general_purpose.allocator;
    _ = allocator_main;
    
}
