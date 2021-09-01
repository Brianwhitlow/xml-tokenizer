const std = @import("std");
const mem = std.mem;
const testing = std.testing;
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
        
        pub fn addChild(self: *Element, allocator: *Allocator, child_node: Node) Allocator.Error!void {
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
    _ = parse_options;
    
    var output: NodeTree = .{
        .string_source = try allocator.allocAdvanced(u8, null, xml_text.len, .at_least),
        .root = .{ .element = .{
            .name = &.{},
            .namespace = null,
            .attributes = .{},
            .children = .{},
        } },
    };
    errdefer output.root.deinit(allocator);
    errdefer allocator.free(output.string_source);
    
    var tokenizer = TokenStream.init(xml_text);
    var current = tokenizer.next();
    
    var string_fba_state = std.heap.FixedBufferAllocator.init(output.string_source);
    const string_allocator: *Allocator = &string_fba_state.allocator;
    
    var dst_stack = try std.ArrayList(*Node.Element).initCapacity(allocator, 1 + blk_precalculate: {
        defer current = tokenizer.reset(null);
        
        var max_open_tags: usize = 0;
        var tags_in_scope: usize = 0;
        
        while (true) : ({
            max_open_tags = std.math.max(max_open_tags, tags_in_scope);
            current = tokenizer.next();
        }) switch (current) {
            .bof => continue,
            .eof => break,
            
            // Note the early return point
            .invalid
            => |invalid| {
                output.string_source = undefined;
                allocator.free(string_fba_state.buffer);
                
                output.root.deinit(allocator);
                output.root = .{ .invalid = invalid };
                
                return output;
            },
            
            .element_open => |_| tags_in_scope += 1,
            .element_close => |element_close| {
                if (tags_in_scope == 0) {
                    output.string_source = undefined;
                    allocator.free(string_fba_state.buffer);
                    
                    output.root.deinit(allocator);
                    output.root = .{ .invalid = .{ .index = element_close.identifier.beg } };
                    
                    return output;
                }
                tags_in_scope -= 1;
            },
            
            .attribute,
            .empty_whitespace,
            .text,
            .char_data,
            .comment,
            .processing_instructions,
            => continue,
        };
        
        break :blk_precalculate max_open_tags * @sizeOf(*Node.Element);
        
    });
    defer dst_stack.deinit();
    
    const closure = struct {
        p_dst_stack: *@TypeOf(dst_stack),
        fn currentDst(closure: @This()) *Node.Element {
            const index = closure.p_dst_stack.items.len - 1;
            const items = closure.p_dst_stack.items;
            return items[index];
        }
    } { .p_dst_stack = &dst_stack };
    
    try dst_stack.append(&output.root.element);
    
    while (true) : (current = tokenizer.next()) switch (current) {
        .bof
        => |_| continue,
        
        .eof
        => |_| break,
        
        .invalid
        => |invalid| {
            output.string_source = undefined;
            allocator.free(string_fba_state.buffer);
            
            output.root.deinit(allocator);
            output.root = .{ .invalid = invalid };
            
            return output;
        },
        
        .element_open
        => |element_open| {
            const src_name = element_open.name(xml_text);
            const src_namespace = element_open.namespace(xml_text);
            
            try closure.currentDst().addChild(allocator, .{ .element = .{
                .name = try string_allocator.dupe(u8, src_name),
                .namespace = if (src_namespace) |ns| try string_allocator.dupe(u8, ns) else null,
                .attributes = .{},
                .children = .{},
            } });
            
            const newest_dst_ptr: *Node.Element = blk: {
                const items = closure.currentDst().children.items;
                const index = items.len - 1;
                break :blk &items[index].element;
            };
            
            try dst_stack.append(newest_dst_ptr);
        },
        
        .element_close
        => |element_close| {
            const matching_close_tag = blk_match: {
                const expect_name = closure.currentDst().name;
                const expect_namespace = closure.currentDst().namespace;
                
                const got_name = element_close.name(xml_text);
                const got_namespace = element_close.namespace(xml_text);
                
                const eql_names = mem.eql(u8, expect_name, got_name);
                const eql_ns = blk_ns_match: {
                    const both_null = (expect_namespace == null) and (got_namespace == null);
                    const none_null = (expect_namespace != null) and (got_namespace != null);
                    const mem_eql = none_null and mem.eql(u8, expect_namespace.?, got_namespace.?);
                    break :blk_ns_match mem_eql or both_null;
                };
                
                break :blk_match eql_names and eql_ns;
            };
            
            _ = if (matching_close_tag) dst_stack.pop()
            else return error.WrongClose;
        },
        
        .attribute
        => |attribute| {
            const src_name = attribute.name.slice(xml_text);
            const src_value = attribute.value(xml_text);
            
            const cpy_name = try string_allocator.dupe(u8, src_name);
            errdefer string_allocator.free(cpy_name);
            
            const cpy_value = try string_allocator.dupe(u8, src_value);
            errdefer string_allocator.free(cpy_value);
            
            try closure.currentDst().addAttribute(allocator, cpy_name, cpy_value);
        },
        
        .empty_whitespace
        => |empty_whitespace| switch (parse_options.store_empty_whitespace) {
            .Discard => {},
            .Flag => try closure.currentDst().addChild(allocator, .{ .empty_whitespace = null }),
            .Keep => {
                const data_copy = try string_allocator.dupe(u8, empty_whitespace.slice(xml_text));
                errdefer string_allocator.free(data_copy);
                
                try closure.currentDst().addChild(allocator, .{ .empty_whitespace = data_copy });
            },
        },
        
        .text
        => |text| {
            const src_data = text.slice(xml_text);
            
            const cpy_data = try string_allocator.dupe(u8, src_data);
            errdefer string_allocator.free(cpy_data);
            
            try closure.currentDst().addChild(allocator, .{ .text = cpy_data });
        },
        
        .char_data
        => |char_data| {
            const src_data = char_data.data(xml_text);
            
            const cpy_data = try string_allocator.dupe(u8, src_data);
            errdefer string_allocator.free(cpy_data);
            
            try closure.currentDst().addChild(allocator, .{ .char_data = cpy_data });
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

pub const StringifyOptions = struct {
    newline: []const u8 = "\n",
    incrementing_indentation: []const u8 = "\t",
};

pub fn internalStringify(
    value: Node,
    options: StringifyOptions,
    out_stream: anytype, // std.io.Writer(),
    indentation_level: usize,
    is_last_child: bool,
) @TypeOf(out_stream).Error!void {
    switch (value) {
        .empty,
        .invalid => {},
        
        .text
        => |data| try out_stream.writeAll(data),
        
        .char_data
        => |char_data| try out_stream.print("<![CDATA[{s}]]>", .{char_data}),
        
        .comment => |comment|
        if (comment) |comment_data|
            try out_stream.print("<!--{s}-->", .{comment_data}),
        
        .empty_whitespace => |empty_whitespace|
        if (empty_whitespace) |ew_data|
            try out_stream.writeAll(ew_data)
        else {
            try out_stream.writeAll(options.newline);
            
            {
                var idx: usize = 0;
                while (idx < indentation_level - @boolToInt(is_last_child)) : (idx += 1)
                    try out_stream.writeAll(options.incrementing_indentation);
            }
        },
        
        .element => |element| {
            try out_stream.writeByte('<');
            if (element.namespace) |ns| try out_stream.print("{s}:", .{ns});
            try out_stream.writeAll(element.name);
            {
                const keys = element.attributes.keys();
                const vals = element.attributes.values();
                for (keys) |k, idx| {
                    const v = vals[idx];
                    try out_stream.print(" {s} = \"{s}\"", .{k, v});
                }
            }
            
            if (element.children.items.len == 0) {
                return out_stream.writeAll("/>");
            }
            
            try out_stream.writeByte('>');
            
            for (element.children.items) |child, idx|  {
                try internalStringify(child, options, out_stream, indentation_level + 1, idx + 1 == element.children.items.len);
            }
            
            try out_stream.writeAll("</");
            if (element.namespace) |ns| try out_stream.print("{s}:", .{ns});
            try out_stream.print("{s}>", .{element.name});
        },
        
        .processing_instructions => |processing_instructions|
        if (processing_instructions) |pi|
            try out_stream.print("<?{s} {s}?>", .{pi.target, pi.instructions}),
        
    }
}

test "T0" {
    std.debug.print("\n", .{});
    std.debug.print("\n", .{});
    var node_tree = try parse(testing.allocator,
    \\<my_element is="not"> <word>very</word> <word>interesting</word> </my_element>
    , .{
        .store_empty_whitespace = .Keep,
        .store_comments = .Flag,
        .store_processing_instructions = .Flag,
    });
    defer node_tree.root.deinit(testing.allocator);
    defer testing.allocator.free(node_tree.string_source);
    
    //const real_root: Node.Element = node_tree.root.element.children.items[0].element;
    
    try internalStringify(node_tree.root.element.children.items[0], .{}, std.io.getStdOut().writer(), 0, true);
    std.debug.print("\n", .{});
}
