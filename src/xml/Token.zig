const std = @import("std");
const mem = std.mem;
const debug = std.debug;
const testing = std.testing;

const xml = @import("xml.zig");

const Token = @This();
tag: Token.Tag,
loc: Token.Loc,

pub fn init(tag:  Token.Tag, loc: Loc) Token {
    return Token{
        .tag = tag,
        .loc = loc,
    };
}

pub fn slice(self: Token, src: []const u8) []const u8 {
    return self.loc.slice(src);
}

pub fn name(self: Token, src: []const u8) ?[]const u8 {
    const Offset = struct { forwards: usize = 0, backwards: usize = 0, };
    const offset: Offset = switch (self.tag) {
        .pi_target => .{ .forwards = ("<?".len) },
        .elem_open_tag => .{ .forwards = ("<".len) },
        .elem_close_tag => .{ .forwards = ("</").len },
        .attr_val_segment_entity_ref => .{ .forwards = ("&".len), .backwards = (";".len) },
        .content_entity_ref => .{ .forwards = ("&".len), .backwards = (";".len) },
        else => return null,
    };

    const sliced = self.slice(src);
    const beg = offset.forwards;
    const end = sliced.len - offset.backwards;
    return sliced[beg..end];
}

pub fn data(self: Token, src: []const u8) ?[]const u8 {
    const Offset = struct { forwards: usize = 0, backwards: usize = 0 };
    const offset: Offset = switch (self.tag) {
        .pi_tok_string => .{ .forwards = 1, .backwards = 1 },
        .comment => .{ .forwards = ("<!--".len), .backwards = ("-->".len) },
        .content_cdata => .{ .forwards = ("<![CDATA[".len), .backwards = ("]]>".len) },
        else => return null,
    };

    const sliced = self.slice(src);
    const beg = offset.forwards;
    const end = sliced.len - offset.backwards;
    return sliced[beg..end];
}

pub const Tag = enum {
    pi_target,
    pi_tok_string,
    pi_tok_other,
    pi_end,

    whitespace,
    comment,

    elem_open_tag,
    elem_close_tag,
    elem_close_inline,

    attr_name,
    attr_val_empty,
    attr_val_segment_text,
    attr_val_segment_entity_ref,

    content_text,
    content_cdata,
    content_entity_ref,
};

pub const Loc = struct {
    beg: usize,
    end: usize,

    pub fn slice(self: @This(), src: []const u8) []const u8 {
        return src[self.beg..self.end];
    }
};



pub const tests = struct {
    fn expectEqualOptionalSlices(comptime T: type, a: ?[]const T, b: ?[]const T) !void {
        const null_str: ?[]const T = null;
        if (a) |unwrapped_a| {
            if (b) |unwrapped_b| {
                try testing.expectEqualSlices(T, unwrapped_a, unwrapped_b);
            } else {
                try testing.expectEqual(null_str, unwrapped_a);
            }
        } else {
            try testing.expectEqual(a, b);
        }
    }
    
    fn expectToken(
        src: []const u8,
        tok: Token,
        expected: struct {
            tag: Token.Tag,
            slice: []const u8,
            name: ?[]const u8,
            data: ?[]const u8,
        },
    ) !void {
        try testing.expectEqual(expected.tag, tok.tag);
        
        debug.assert(expected.slice.len == 0 or mem.containsAtLeast(u8, src, 1, expected.slice));
        try testing.expectEqualStrings(expected.slice, tok.slice(src));
        
        try expectEqualOptionalSlices(u8, expected.name, tok.name(src));
        try expectEqualOptionalSlices(u8, expected.data, tok.data(src));
    }
    
    pub fn expectPiTarget(src: []const u8, tok: Token, expected_name: []const u8) !void {
        const expected_slice = try mem.concat(testing.allocator, u8, &.{ "<?", expected_name });
        defer testing.allocator.free(expected_slice);
        try expectToken(src, tok, .{
            .tag = .pi_target,
            .slice = expected_slice,
            .name = expected_name,
            .data = null,
        });
    }
    
    pub fn expectPiTokString(src: []const u8, tok: Token, expected_data: []const u8, quote_type: xml.StringQuote) !void {
        const expected_slice = try mem.concat(testing.allocator, u8, &[_][]const u8{ &[_]u8{ quote_type.value() }, expected_data, &[_]u8{ quote_type.value() } });
        defer testing.allocator.free(expected_slice);
        try expectToken(src, tok, .{
            .tag = .pi_tok_string,
            .slice = expected_slice,
            .name = null,
            .data = expected_data,
        });
    }
    
    pub fn expectPiTokOther(src: []const u8, tok: Token, expected_slice: []const u8) !void {
        try expectToken(src, tok, .{
            .tag = .pi_tok_other,
            .slice = expected_slice,
            .name = null,
            .data = null,
        });
    }
    
    pub fn expectPiEnd(src: []const u8, tok: Token) !void {
        try expectToken(src, tok, .{
            .tag = .pi_end,
            .slice = "?>",
            .name = null,
            .data = null,
        });
    }
    
    pub fn expectWhitespace(src: []const u8, tok: Token, expected_slice: []const u8) !void {
        try expectToken(src, tok, .{
            .tag = .whitespace,
            .slice = expected_slice,
            .name = null,
            .data = null,
        });
    }
    
    pub fn expectComment(src: []const u8, tok: Token, expected_data: []const u8) !void {
        const expected_slice = try mem.concat(testing.allocator, u8, &.{ "<!--", expected_data, "-->" });
        defer testing.allocator.free(expected_slice);
        try expectToken(src, tok, .{
            .tag = .comment,
            .slice = expected_slice,
            .name = null,
            .data = expected_data,
        });
    }
    
    pub fn expectElemOpenTag(src: []const u8, tok: Token, expected_name: []const u8) !void {
        const expected_slice = try mem.concat(testing.allocator, u8, &.{ "<", expected_name });
        defer testing.allocator.free(expected_slice);
        try expectToken(src, tok, .{
            .tag = .elem_open_tag,
            .slice = expected_slice,
            .name = expected_name,
            .data = null,
        });
    }
    
    pub fn expectElemCloseTag(src: []const u8, tok: Token, expected_name: []const u8) !void {
        const expected_slice = try mem.concat(testing.allocator, u8, &.{ "</", expected_name });
        defer testing.allocator.free(expected_slice);
        try expectToken(src, tok, .{
            .tag = .elem_close_tag,
            .slice = expected_slice,
            .name = expected_name,
            .data = null,
        });
    }
    
    pub fn expectElemCloseInline(src: []const u8, tok: Token) !void {
        try expectToken(src, tok, .{
            .tag = .elem_close_inline,
            .slice = "/>",
            .name = null,
            .data = null,
        });
    }
    
    pub fn expectAttrName(src: []const u8, tok: Token, expected_slice: []const u8) !void {
        try expectToken(src, tok, .{
            .tag = .attr_name,
            .slice = expected_slice,
            .name = null,
            .data = null,
        });
    }
    
    pub fn expectAttrValEmpty(src: []const u8, tok: Token) !void {
        try expectToken(src, tok, .{
            .tag = .attr_val_empty,
            .slice = "",
            .name = null,
            .data = null,
        });
    }
    
    pub fn expectAttrValSegmentText(src: []const u8, tok: Token, expected_slice: []const u8) !void {
        try expectToken(src, tok, .{
            .tag = .attr_val_segment_text,
            .slice = expected_slice,
            .name = null,
            .data = null,
        });
    }
    
    pub fn expectAttrValSegmentEntityRef(src: []const u8, tok: Token, expected_name: []const u8) !void {
        const expected_slice = try mem.concat(testing.allocator, u8, &.{ "&", expected_name, ";" });
        defer testing.allocator.free(expected_slice);
        try expectToken(src, tok, .{
            .tag = .attr_val_segment_entity_ref,
            .slice = expected_slice,
            .name = expected_name,
            .data = null,
        });
    }
    
    pub fn expectContentText(src: []const u8, tok: Token, expected_slice: []const u8) !void {
        try expectToken(src, tok, .{
            .tag = .content_text,
            .slice = expected_slice,
            .name = null,
            .data = null,
        });
    }
    
    pub fn expectContentCData(src: []const u8, tok: Token, expected_data: []const u8) !void {
        const expected_slice = try mem.concat(testing.allocator, u8, &.{ "<![CDATA[", expected_data, "]]>" });
        defer testing.allocator.free(expected_slice);
        try expectToken(src, tok, .{
            .tag = .content_cdata,
            .slice = expected_slice,
            .name = null,
            .data = expected_data,
        });
    }
    
    pub fn expectContentEntityRef(src: []const u8, tok: Token, expected_name: []const u8) !void {
        const expected_slice = try mem.concat(testing.allocator, u8, &.{ "&", expected_name, ";" });
        defer testing.allocator.free(expected_slice);
        try expectToken(src, tok, .{
            .tag = .content_entity_ref,
            .slice = expected_slice,
            .name = expected_name,
            .data = null,
        });
    }
};
