const std = @import("std");
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
    empty_whitespace: []const u8,
    comment: []const u8,
    element: Element,
    processing_instructions: ProcessingInstruction,
    
    pub const Element = struct {
        name: []const u8 = &.{},
        namespace: ?[]const u8 = null,
        attributes: std.StringArrayHashMapUnmanaged([]const u8) = .{},
        children: std.ArrayListUnmanaged(Self) = .{},
    };
    
    pub const ProcessingInstruction = struct {
        target: []const u8 = &.{},
        instructions: []const u8 = &.{},
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
            => |*element| {
                for (element.children.items) |*child| {
                    child.deinit(allocator);
                }
                
                element.children.deinit(allocator);
                element.attributes.deinit(allocator);
            },
        }
    }
    
};

pub const NodeTree = struct {
    source_buffer: []const u8,
    root: Node,
};

const ParseOptions = packed struct {
    keep_empty_whitespace: bool = false,
    keep_comments: bool = false,
    keep_processing_instructions: bool = false,
};

pub fn parse(
    allocator: *Allocator,
    xml_text: []const u8,
    copy_text: bool,
    parse_options: ParseOptions,
) !NodeTree {
    var output: NodeTree = .{
        .source_buffer = if (copy_text) try allocator.dupe(u8, xml_text) else xml_text,
        .root = .{ .element = .{} },
    }; errdefer if (copy_text) allocator.free(output.source_buffer);
    
    var tok_stream: TokenStream = .{ .buffer = output.source_buffer };
    var current: Token = .bof;
    
    const internal_parser = struct {
        allocator: *Allocator,
        xml_source: []const u8,
        parse_options: ParseOptions,
        
        p_tok_stream: *TokenStream,
        p_current: *Token,
        p_node_tree: *NodeTree,
        
        fn parse(state: *const @This(), dst: *Node.Element) (error { Invalid, AttributeNameAlreadySpecified } || Allocator.Error)!void {
            errdefer state.p_node_tree.root.deinit(state.allocator);
            
            while (true) {
                switch (state.p_current.*) {
                    .bof => state.p_current.* = state.p_tok_stream.next(),
                    .eof => return,
                    .invalid => return error.Invalid,
                    
                    .element_open
                    => |element_open| {
                        var new_child: Node = .{ .element = .{
                            .name = element_open.name(state.xml_source),
                            .namespace = element_open.namespace(state.xml_source),
                        } };
                        
                        state.p_current.* = state.p_tok_stream.next();
                        try state.parse(&new_child.element);
                        try dst.children.append(state.allocator, new_child);
                    },
                    
                    .element_close
                    => |element_close| {
                        if (switch(std.builtin.mode) {
                            .ReleaseFast, .ReleaseSmall
                            => true,
                            
                            else
                            => false,
                        }) return;
                        
                        if (blk: {
                            const eql_name = blk_eql_name: {
                                const got_name = element_close.name(state.xml_source);
                                const expect_name = dst.name;
                                break :blk_eql_name mem.eql(u8, expect_name, got_name);
                            };
                            
                            const eql_namespace = blk_eql_ns: {
                                const got_ns = element_close.namespace(state.xml_source);
                                const expect_ns = dst.namespace;
                                
                                const all_null = (got_ns == null) and (expect_ns == null);
                                const no_null  = (got_ns != null) and (expect_ns != null);
                                
                                const all_eql = no_null and mem.eql(u8, expect_ns.?, got_ns.?);
                                break :blk_eql_ns all_null or all_eql;
                            };
                            
                            break :blk !eql_name or !eql_namespace;
                        }) return error.Invalid;
                        
                        state.p_current.* = state.p_tok_stream.next();
                        return;
                    },
                    
                    .attribute
                    => |attribute| {
                        const name = attribute.name.slice(state.xml_source);
                        const value = attribute.value(state.xml_source);
                        
                        const gop: std.StringArrayHashMapUnmanaged([]const u8).GetOrPutResult = try dst.attributes.getOrPut(state.allocator, name);
                        if (gop.found_existing) {
                            return error.AttributeNameAlreadySpecified;
                        }
                        
                        gop.value_ptr.* = value;
                        state.p_current.* = state.p_tok_stream.next();
                    },
                    
                    .empty_whitespace => |empty_whitespace| {
                        if (state.parse_options.keep_empty_whitespace) {
                            try dst.children.append(state.allocator, .{ .empty_whitespace = empty_whitespace.slice(state.xml_source) });
                        }
                        
                        state.p_current.* = state.p_tok_stream.next();
                    },
                    
                    .text => |text| {
                        try dst.children.append(state.allocator, .{ .text = text.slice(state.xml_source) });
                        state.p_current.* = state.p_tok_stream.next();
                    },
                    
                    .char_data => |char_data| {
                        try dst.children.append(state.allocator, .{ .char_data = char_data.data(state.xml_source) });
                        state.p_current.* = state.p_tok_stream.next();
                    },
                    
                    .comment => |comment| {
                        if (state.parse_options.keep_comments) {
                            try dst.children.append(state.allocator, .{ .comment = comment.data(state.xml_source) });
                        }
                        
                        state.p_current.* = state.p_tok_stream.next();
                    },
                    
                    .processing_instructions => |processing_instructions| {
                        if (state.parse_options.keep_processing_instructions) {
                            try dst.children.append(state.allocator, .{ .processing_instructions = .{
                                .target = processing_instructions.target.slice(state.xml_source),
                                .instructions = processing_instructions.instructions.slice(state.xml_source),
                            } });
                        }
                        
                        state.p_current.* = state.p_tok_stream.next();
                    },
                }
            }
        }
    } {
        .allocator = allocator,
        .xml_source = output.source_buffer,
        .parse_options = parse_options,
        .p_tok_stream = &tok_stream,
        .p_current = &current,
        .p_node_tree = &output,
    };
    
    try internal_parser.parse(&output.root.element);
    return output;
}

test "T0" {
    var node_tree = try parse(
        std.testing.allocator,
        \\<root faf1="">
        \\    <mem>
        \\        damns
        \\    </mem>
        \\</root>
        , false,
        .{}
    );
    defer node_tree.root.deinit(std.testing.allocator);
    
    std.debug.print("\n{}\n", .{node_tree.root});
    
}
