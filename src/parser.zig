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
    comment: ?[]const u8,
    empty_whitespace: ?[]const u8,
    element: Element,
    processing_instructions: ?ProcessingInstruction,
    
    pub const Element = struct {
        name: []const u8,
        namespace: ?[]const u8,
        attributes: std.StringArrayHashMapUnmanaged([]const u8),
        children: std.ArrayListUnmanaged(Self),
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
            => |*element| {
                for (element.children.items) |*child| child.deinit(allocator);
                element.attributes.deinit(allocator);
                element.children.deinit(allocator);
            },
        }
    }
    
};

pub const NodeTree = struct {
    source_buffer: []const u8,
    root: Node,
};

pub const ParseOptions = packed struct {
    store_empty_whitespace: StoreType = .Discard,
    store_comments: StoreType = .Discard,
    store_processing_instructions: StoreType = .Discard,
    
    pub const StoreType = enum(u2) {
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
    var tok_stream: TokenStream = .{ .buffer = xml_text };
    var current: Token = .bof;
    
    var source_buffer_array = try std.ArrayList(u8).initCapacity(allocator, xml_text.len);
    errdefer source_buffer_array.deinit();
    
    var output: NodeTree = .{
        .source_buffer = undefined,
        .root = .{ .element = .{
            .name = &.{},
            .namespace = null,
            .attributes = .{},
            .children = .{},
        } },
    };
    errdefer output.root.deinit(allocator);
    
    const state = struct {
        allocator: *Allocator,
        xml_text: []const u8,
        p_tok_stream: *TokenStream,
        p_current: *Token,
        parse_options: ParseOptions,
        p_source_buffer_array: *@TypeOf(source_buffer_array),
        
        const Error = Allocator.Error || error {
            Invalid,
            EofMaybeTooEarly,
            MaybeEofTooEarly,
            EofTooEarly,
            WrongClose,
            AttributeAlreadySpecified,
        };
        
        fn assignNodeProperties(state: *const @This(), dst:* Node.Element) Error!void {
            const sba_items = &state.p_source_buffer_array.items;
            
            while (true) : (state.p_current.* = state.p_tok_stream.next()) {
                switch (state.p_current.*) {
                    .bof
                    => |bof| unreachable,
                    
                    .eof
                    => |eof| return error.MaybeEofTooEarly,
                    
                    .invalid
                    => |invalid| return error.Invalid,
                    
                    .element_open
                    => |element_open| {
                        const name = element_open.name(state.xml_text);
                        const namespace = element_open.namespace(state.xml_text);
                        
                        const name_range = Range.init(state.p_source_buffer_array.items.len, name.len);
                        state.p_source_buffer_array.appendSliceAssumeCapacity(name);
                        
                        const namespace_range: ?Range = if (namespace) |ns| blk: {
                            const blk_out = Range.init(state.p_source_buffer_array.items.len, ns.len);
                            state.p_source_buffer_array.appendSliceAssumeCapacity(ns);
                            break :blk blk_out;
                        } else null;
                        
                        var new_node: Node = .{ .element = .{
                            .name = name_range.slice(state.p_source_buffer_array.items),
                            .namespace = if (namespace_range) |nsr| nsr.slice(state.p_source_buffer_array.items) else null,
                            .attributes = .{},
                            .children = .{},
                        } };
                        errdefer new_node.deinit(state.allocator);
                        
                        state.p_current.* = state.p_tok_stream.next();
                        state.assignNodeProperties(&new_node.element) catch |err| switch (err) {
                            error.MaybeEofTooEarly
                            => return error.EofTooEarly,
                            
                            else
                            => return err,
                        };
                        try dst.children.append(state.allocator, new_node);
                    },
                    
                    .element_close
                    => |element_close| {
                        
                        const is_eql = blk_is_eql: {
                            const expect_name = dst.name;
                            const expect_namespace = dst.namespace;
                            
                            const got_name = element_close.name(state.xml_text);
                            const got_namespace = element_close.namespace(state.xml_text);
                            
                            const eql_name = mem.eql(u8, expect_name, got_name);
                            const eql_namespace = blk_eql_ns: {
                                const both_null = (expect_namespace == null) and (got_namespace == null);
                                const none_null = (expect_namespace != null) and (got_namespace != null);
                                
                                const mem_eql = none_null and mem.eql(u8, expect_namespace.?, got_namespace.?);
                                break :blk_eql_ns both_null or mem_eql;
                            };
                            
                            break :blk_is_eql eql_name and eql_namespace;
                        };
                        
                        if (!is_eql) {
                            return error.WrongClose;
                        }
                        
                        return;
                    },
                    
                    .attribute
                    => |attribute| {
                        const name = attribute.name.slice(state.xml_text);
                        const value = attribute.value(state.xml_text);
                        
                        const name_range = Range.init(sba_items.len, sba_items.len + name.len);
                        state.p_source_buffer_array.appendSliceAssumeCapacity(name);
                        
                        const value_range = Range.init(sba_items.len, sba_items.len + value.len);
                        state.p_source_buffer_array.appendSliceAssumeCapacity(value);
                        
                        const gop = try dst.attributes.getOrPut(state.allocator, name_range.slice(state.p_source_buffer_array.items));
                        if (gop.found_existing) return error.AttributeAlreadySpecified;
                        gop.value_ptr.* = value_range.slice(state.p_source_buffer_array.items);
                    },
                    
                    .empty_whitespace
                    => |empty_whitespace| switch (state.parse_options.store_empty_whitespace) {
                        .Keep
                        => {
                            const ws = empty_whitespace.slice(state.xml_text);
                            const ws_range = Range.init(state.p_source_buffer_array.items.len, ws.len);
                            state.p_source_buffer_array.appendSliceAssumeCapacity(ws);
                            try dst.children.append(state.allocator, .{ .empty_whitespace = ws_range.slice(state.p_source_buffer_array.items) });
                        },
                        
                        .Flag
                        => try dst.children.append(state.allocator, .{ .empty_whitespace = null }),
                        
                        .Discard
                        => {},
                    },
                    
                    .text
                    => |text| {
                        const text_string = text.slice(state.xml_text);
                        const text_range = Range.init(sba_items.len, sba_items.len + text_string.len);
                        state.p_source_buffer_array.appendSliceAssumeCapacity(text_string);
                        try dst.children.append(state.allocator, .{ .text = text_range.slice(state.p_source_buffer_array.items) });
                    },
                    
                    .char_data
                    => |char_data| {
                        const text_string = char_data.data(state.xml_text);
                        const text_range = Range.init(state.p_source_buffer_array.items.len, text_string.len);
                        state.p_source_buffer_array.appendSliceAssumeCapacity(text_string);
                        try dst.children.append(state.allocator, .{ .char_data = text_range.slice(state.p_source_buffer_array.items) });
                    },
                    
                    .comment
                    => |comment| switch (state.parse_options.store_comments) {
                        .Keep
                        => {
                            const comment_str = comment.data(state.xml_text);
                            const comment_range = Range.init(state.p_source_buffer_array.items.len, comment_str.len);
                            state.p_source_buffer_array.appendSliceAssumeCapacity(comment_str);
                            try dst.children.append(state.allocator, .{ .comment = comment_range.slice(state.p_source_buffer_array.items) });
                        },
                        
                        .Flag
                        => try dst.children.append(state.allocator, .{ .comment = null }),
                        
                        .Discard
                        => {},
                    },
                    
                    .processing_instructions
                    => |processing_instructions| switch (state.parse_options.store_comments) {
                        .Keep
                        => {
                            const target = processing_instructions.target.slice(state.xml_text);
                            const instructions = processing_instructions.instructions.slice(state.xml_text);
                            
                            const target_range = Range.init(state.p_source_buffer_array.items.len, target.len);
                            state.p_source_buffer_array.appendSliceAssumeCapacity(target);
                            
                            const instructions_range = Range.init(state.p_source_buffer_array.items.len, instructions.len);
                            state.p_source_buffer_array.appendSliceAssumeCapacity(instructions);
                            
                            try dst.children.append(state.allocator, .{ .processing_instructions = .{
                                .target = target_range.slice(state.p_source_buffer_array.items),
                                .instructions = instructions_range.slice(state.p_source_buffer_array.items),
                            } });
                        },
                        
                        .Flag
                        => try dst.children.append(state.allocator, .{ .processing_instructions = null }),
                        
                        .Discard
                        => {},
                    },
                }
            }
        }
        
    } {
        .allocator = allocator,
        .xml_text = xml_text,
        .p_tok_stream = &tok_stream,
        .p_current = &current,
        .p_source_buffer_array = &source_buffer_array,
        .parse_options = parse_options,
    };
    
    current = tok_stream.next();
    state.assignNodeProperties(&output.root.element) catch |err| switch (err) {
        error.MaybeEofTooEarly
        => {},
        
        error.Invalid
        => {
            output.root.deinit(allocator);
            source_buffer_array.deinit();
            source_buffer_array.items.len = 0;
            output.root = .{ .invalid = current.invalid };
        },
        
        else
        => return err,
    };
    
    output.source_buffer = source_buffer_array.toOwnedSlice();
    
    return output;
}

test "T0" {
    std.debug.print("\n", .{});
    const xml_text =
        \\<my_element is="quite"> boring </my_element>
    ;
    
    var parsed = try parse(std.testing.allocator, xml_text, .{},);
    defer {
        parsed.root.deinit(std.testing.allocator);
        std.testing.allocator.free(parsed.source_buffer);
    }
    
    const real_root = parsed.root.element.children.items[0];
    
    std.debug.print("{s}:", .{real_root.element.namespace});
    std.debug.print("{s}\n", .{real_root.element.name});
    {
        const slice = real_root.element.attributes.entries.slice();
        const keys = slice.items(.key);
        const value = slice.items(.value);
        for (keys) |k, idx| std.debug.print("\t{s} = {s}\n", .{k, value[idx]});
    }
    std.debug.print("\n", .{});
    
}
