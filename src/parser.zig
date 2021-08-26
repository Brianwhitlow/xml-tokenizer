const std = @import("std");
const Allocator = std.mem.Allocator;
const token_stream = @import("token_stream.zig");

const Index = token_stream.Index;
const Range = token_stream.Range;
const Token = token_stream.Token;
const TokenStream = token_stream.TokenStream;

pub const Node = union(enum) {
    const Self = @This();
    invalid,
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
            .invalid
            => {},
            
            .text,
            .char_data,
            .empty_whitespace
            => |bytes| allocator.free(bytes),
            
            .element
            => |*element| {
                if (element.namespace) |ns| {
                    allocator.free(ns);
                }
                
                for (element.children.items) |*child| {
                    child.deinitTemplate(allocator, undefine_mem);
                }
                
                for (element.attributes.entries.items(.value)) |val| {
                    allocator.free(val);
                }
                
                allocator.free(element.name);
                element.children.deinit(allocator);
                element.attributes.deinit(allocator);
            },
        }
    }
};

pub fn parse(allocator: *Allocator, xml_text: []const u8, p_error_info: ?*?Index) !Node {
    if (p_error_info) |p_err_info| p_err_info.* = null;
    
    var tokenizer: TokenStream = .{ .buffer = xml_text };
    var current: Token = .bof;
    
    var result: Node = .{ .element = .{} };
    errdefer result.deinit(allocator);
    
    const closure = struct {
        allocator: *Allocator,
        xml_text: []const u8,
        tokenizer: *TokenStream,
        current: *Token,
        fn parseIntoElement(this: @This(), dst: *Node.Element) error{OutOfMemory, NoMatchingClose, WrongClose}!void {
            
            while (this.current.* != .invalid) {
                switch (this.current.*) {
                    .processing_instructions,
                    .empty_whitespace,
                    .comment,
                    .bof,
                    => this.current.* = this.tokenizer.next(),
                    
                    .element_open
                    => |element_open| {
                        var new_node = Node { .element = .{} };
                        errdefer new_node.deinit(this.allocator);
                        
                        new_node.element.name = try this.allocator.dupe(u8, element_open.name(this.xml_text));
                        if (element_open.namespace(this.xml_text)) |ns| {
                            new_node.element.namespace = try this.allocator.dupe(u8, ns);
                        }
                        
                        
                        this.current.* = this.tokenizer.next();
                        try this.parseIntoElement(&new_node.element);
                        try dst.children.append(this.allocator, new_node);
                    },
                    
                    .attribute
                    => |attribute| {
                        const name = attribute.name.slice(this.xml_text);
                        
                        const value = try this.allocator.dupe(u8, attribute.value(this.xml_text));
                        errdefer this.allocator.free(value);
                        
                        try dst.attributes.put(this.allocator, name, value);
                        this.current.* = this.tokenizer.next();
                    },
                    
                    
                    .element_close
                    => |element_close| {
                        const eql_name = std.mem.eql(u8, element_close.name(this.xml_text), dst.name);
                        const eql_namespace = blk: {
                            const expected_namespace = element_close.namespace(this.xml_text);
                            
                            const both_null = (expected_namespace == null) and (dst.namespace == null);
                            
                            const neither_null = (expected_namespace != null) and (dst.namespace != null);
                            const mem_eql = neither_null and std.mem.eql(u8, expected_namespace.?, dst.namespace.?);
                            
                            break :blk both_null or mem_eql;
                        };
                        
                        if (!eql_name or !eql_namespace) {
                            return error.WrongClose;
                        }
                        
                        this.current.* = this.tokenizer.next();
                        
                        return;
                    },
                    
                    .eof
                    => return,
                    
                    else
                    => unreachable,
                }
            }
            
            return error.NoMatchingClose;
        }
    } {
        .allocator = allocator,
        .xml_text = xml_text,
        .tokenizer = &tokenizer,
        .current = &current,
    };
    
    try closure.parseIntoElement(&result.element);
    return result;
}

test "T0" {
    std.debug.print("\n", .{});
    var node = try parse(std.testing.allocator, \\<my_element is="uninteresting"></my_element>
    , null);
    defer node.deinit(std.testing.allocator);
    
    const root: Node.Element = node.element.children.items[0].element;
    std.debug.print("namespace: {s}\nname: {s}\n", .{root.namespace, root.name});
    
    {
        var iterator = root.attributes.iterator();
        while (iterator.next()) |kv| {
            std.debug.print("\t{s} = {s}\n", .{kv.key_ptr.*, kv.value_ptr.*});
        }
    }
    
    for (root.children.items) |child| {
        std.debug.print("\t{}\n", .{child});
    }
    
    _ = node;
}
