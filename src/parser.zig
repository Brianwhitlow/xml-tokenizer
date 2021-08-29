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
    /// Buffer where the actual strings referenced by any attributes, elements, text, etc. exists.
    string_source: []u8,
    root: Node,
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
    allocator: *Allocator,
    xml_text: []const u8,
    parse_options: ParseOptions,
) !NodeTree {
    var output: NodeTree = .{
        .string_source = try allocator.allocAdvanced(u8, null, xml_text.len, .at_least),
        .root = .empty,
    }; errdefer allocator.free(string_fba_state.buffer);
    
    var tokenizer = TokenStream.init(xml_text);
    var current = tokenizer.next();
    
    var string_fba_state = std.heap.FixedBufferAllocator.init();
    const string_allocator: *Allocator = &string_fba_state.allocator;
    
    var dst_stack = try std.ArrayList(*Node.Element).initCapacity(allocator, blk_precalculate: {
        defer current = tokenizer.reset();
        
        var open_tag_count: usize = 0;
        var close_tag_count: usize = 0;
        
        while (true) : (current = tokenizer.next()) switch (current) {
            .bof
            => |_| {},
            
            .eof
            => |_| break,
            
            // Note the early return point
            .invalid
            => |invalid| {
                output.string_source = undefined;
                allocator.free(string_fba_state.buffer);
                
                output.root.deinit(allocator);
                output.root = .{ .invalid = invalid };
                
                return output;
            },
            
            .element_open => |_| open_tag_count += 1,
            .element_close => |_| close_tag_count += 1,
            
            .attribute,
            .empty_whitespace,
            .text,
            .char_data,
            .comment,
            .processing_instructions,
            => {},
        };
        
        if (open_tag_count != close_tag_count) {
            output.string_source = undefined;
            allocator.free(string_fba_state.buffer);
            
            output.root.deinit(allocator);
            output.root = .{ .invalid = invalid };
            
            return output;
        }
        
        break :blk_precalculate open_tag_count * @sizeOf(Node.Element);
    }); defer dst_stack.deinit();
    
    const closure = struct {
        p_dst_stack: *@TypeOf(dst_stack),
        fn currentDst(closure: @This()) *Node.Element {
            const index = closure.p_dst_stack.items.len - 1;
            const items = closure.p_dst_stack.items;
            return &items[index];
        }
    } { .p_dst_stack = &dst_stack };
    
    while (true) : (current = tokenizer.next()) switch (current) {
            .bof
            => |bof| {
                _ = bof;
            },
            
            .eof
            => |eof| {
                _ = eof;
            },
            
            .invalid
            => |invalid| {
                _ = invalid;
            },
            
            .element_open
            => |element_open| {
                _ = element_open;
            },
            
            .element_close
            => |element_close| {
                _ = element_close;
            },
            
            .attribute
            => |attribute| {
                _ = attribute;
            },
            
            .empty_whitespace
            => |empty_whitespace| {
                _ = empty_whitespace;
            },
            
            .text
            => |text| {
                _ = text;
            },
            
            .char_data
            => |char_data| {
                _ = char_data;
            },
            
            .comment
            => |comment| {
                _ = comment;
            },
            
            .processing_instructions
            => |processing_instructions| {
                _ = processing_instructions;
            },
    };
    
    return output;
}

test "T0" {
    var node_tree = try parse(.{ .node_allocator = testing.allocator, .strings = .{ .allocator = testing.allocator } },
        \\<my_element is="not"> very interesting </my_element>
        , .{}
    );
    
    _ = node_tree;
}
