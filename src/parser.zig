const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const Allocator = std.mem.Allocator;
const token_stream = @import("token_stream.zig");

const Index = token_stream.Index;
const Range = token_stream.Range;
const Token = token_stream.Token;
const TokenStream = token_stream.TokenStream;

pub const Node = union(enum) {
    const Self = @This();
    empty,
    invalid: Index,
    text: []const u8,
    char_data: []const u8,
    comment: ?[]const u8,
    empty_whitespace: ?[]const u8,
    element: Element,
    processing_instructions: ?ProcessingInstruction,
    
    pub const Element = struct {
        name: []const u8,
        namespace: ?[]const u8,
        attributes: std.StringArrayHashMapUnmanaged([]const u8),
        children: std.ArrayListUnmanaged(Self),
        
        pub fn addChild(self: *Element, allocator: *Allocator, child_node: Node) error {OutOfMemory}!void {
            try self.children.append(allocator, child_node);
        }
        
        pub fn addAttribute(self: *Element, allocator: *Allocator, name: []const u8, value: []const u8) error {OutOfMemory, AttributeAlreadySpecified}!void {
            const gop = try self.attributes.getOrPut(allocator, name);
            if (gop.found_existing) return error.AttributeAlreadySpecified;
            gop.value_ptr.* = value;
        }
        
        pub fn deinit(self: *Element, allocator: *Allocator) void {
            for (self.children.items) |*child| child.deinit(allocator);
            self.attributes.deinit(allocator);
            self.children.deinit(allocator);
        }
    };
    
    pub const ProcessingInstruction = struct {
        target: []const u8,
        instructions: []const u8,
    };
    
    pub fn deinit(self: *Self, allocator: *Allocator) void {
        switch (self.*) {
            .invalid,
            .text,
            .char_data,
            .empty_whitespace,
            .empty,
            .comment,
            .processing_instructions,
            => {},
            
            .element
            => |*element| element.deinit(allocator),
        }
    }
    
};

pub const NodeTree = struct {
    root: Node,
    
    /// Buffer where the actual strings referenced by any attributes, elements, text, etc. exists.
    string_source: []u8,
};

pub const ParseOptions = packed struct {
    store_empty_whitespace: StoreType = .Flag,
    store_comments: StoreType = .Flag,
    store_processing_instructions: StoreType = .Flag,
    
    pub const StoreType = enum(u8) {
        Discard,
        Flag,
        Keep,
    };
};

pub fn parse(
    heap_strategy: struct {
        node_allocator: *Allocator,
        strings: union(enum) {
            /// It is recommended that if a buffer is used, its length be >= that of the provided XML text.
            /// If a buffer is used, it will be stored in the `string_source` member of the returned `NodeTree`.
            buffer: []u8,
            allocator: *Allocator,
        },
    },
    xml_text: []const u8,
    parse_options: ParseOptions,
) !NodeTree {
    _ = parse_options;
    
    var parser = struct {
        const Self = @This();
        string_fixed_buffer_allocator_state: std.heap.FixedBufferAllocator,
        node_allocator: *Allocator,
        tok_stream: TokenStream,
        current: Token,
        
        const Error = Allocator.Error || error { Invalid };
        
        inline fn stringAllocator(state: *Self) *Allocator {
            return &state.string_fixed_buffer_allocator_state.allocator;
        }
        
        inline fn nodeAllocator(state: *Self) *Allocator {
            return state.node_allocator;
        }
        
        fn parse(state: *Self, dst: *Node) !void {
            while (true) : (state.current = state.tok_stream.next()) {
                switch (state.current) {
                    .bof
                    => {},
                    
                    .eof
                    => unreachable,
                    
                    .invalid
                    => |invalid| {
                        dst.deinit(state.nodeAllocator());
                        dst.* = .{ .invalid = invalid };
                        return error.Invalid;
                    },
                    
                    .element_open
                    => |element_open| {
                        _ = element_open;
                    },
                    
                    else
                    => unreachable,
                }
            }
        }
        
    } {
        .string_fixed_buffer_allocator_state = switch (heap_strategy.strings) {
            .buffer => |buffer| std.heap.FixedBufferAllocator.init(buffer),
            .allocator => |allocator| std.heap.FixedBufferAllocator.init(try allocator.allocAdvanced(u8, null, xml_text.len, .at_least)),
        },
        .node_allocator = heap_strategy.node_allocator,
        .tok_stream = .{ .buffer = xml_text },
        .current = .bof,
    };
    
    errdefer switch (heap_strategy.strings) {
        .buffer => {},
        .allocator => |allocator| allocator.free(parser.string_fixed_buffer_allocator_state.buffer),
    };
    
    var output_root: Node = .empty;
    errdefer output_root.deinit(parser.nodeAllocator());
    
    try parser.parse(&output_root);
    return NodeTree {
        .root = output_root,
        .string_source = parser.string_fixed_buffer_allocator_state.buffer,
    };
}

test "T0" {
    var node_tree = try parse(.{ .node_allocator = testing.allocator, .strings = .{ .allocator = testing.allocator } },
        \\<my_element is="not"> very interesting </my_element>
        , .{}
    );
    
    _ = node_tree;
}
