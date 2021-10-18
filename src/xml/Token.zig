const std = @import("std");

const Token = @This();
tag: Tag,
loc: Loc,

pub fn init(tag: Tag, loc: Loc) Token {
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

pub const Tag = union(enum) {
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
