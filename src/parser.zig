const std = @import("std");
const Allocator = std.mem.Allocator;
const token_stream = @import("token_stream.zig");

const Index = token_stream.Index;
const Range = token_stream.Range;
const Token = token_stream.Token;
const TokenStream = token_stream.TokenStream;

pub const Node = union(enum) {
    const Self = @This();
    text: []u8,
    char_data: []u8,
    empty_whitespace: []u8,
    element: Element,
    
    pub const Element = struct {
        name: []u8 = &.{},
        namespace: ?[]u8 = null,
        attributes: std.StringArrayHashMapUnmanaged([]u8) = .{},
        children: std.ArrayListUnmanaged(Node) = .{},
    };
    
    pub fn deinit(self: *Self, allocator: *Allocator) void {
        self.deinitTemplate(allocator, true);
    }
    
    pub fn deinitNoUndef(self: *Self, allocator: *Allocator) void {
        self.deinitTemplate(allocator, false);
    }
    
    fn deinitTemplate(self: *Self, allocator: *Allocator, comptime undefine_mem: bool) void {
        defer if (undefine_mem) { self.* = undefined; };
        switch (self.*) {
            .text,
            .char_data,
            .empty_whitespace
            => |bytes| allocator.free(bytes),
            
            .element
            => |*element| {
                if (element.namespace) |ns| allocator.free(ns);
                allocator.free(element.name);
                
                for (element.children.items) |child| child.deinitTemplate(allocator, undefine_mem);
                element.children.deinit(allocator);
                
                element.attributes.deinit(allocator);
            },
        }
    }
};

pub fn parse(_: *Allocator, xml_text: []const u8, p_error_info: ?*?Index) !Node {
    if (p_error_info) |p_err_info| p_err_info.* = null;
    
    var tokenizer: TokenStream = .{ .buffer = xml_text };
    var current: Token = .bof;
    
    while (current != .eof and current != .invalid) : (current = tokenizer.next()) {
        switch (current) {
            else
            => unreachable,
        }
    }
    
    if (current == .invalid) {
        if (p_error_info) |p_err_info| p_err_info.* = current.invalid;
        return error.Invalid;
    }
    
    return Node { .text = &.{} };
}

test "T0" {
    var node = try parse(
        std.testing.allocator,
        \\<my_element is="uninteresting"/>
        , null
    );
    
    _ = node;
}
