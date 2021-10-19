const std = @import("std");
const meta = std.meta;
const debug = std.debug;

const xml = @import("../xml.zig");
const utility = @import("utility.zig");

fn todo(comptime fmt: []const u8, args: anytype) noreturn {
    debug.panic("TODO: " ++ fmt, if (@TypeOf(args) == null) .{} else args);
}

const Token = xml.Token;

const TokenStream = @This();
index: usize,
depth: usize,
state: State,

pub const NextReturnType = ?TokenExt;
pub const TokenExt = union(enum) {
    const Self = @This();
    token: Token,
    invalid: Invalid,
    
    fn initToken(tag: Token.Tag, loc: Token.Loc) Self {
        return @unionInit(Self, "token", Token.init(tag, loc));
    }
    
    fn initInvalid(tag: Invalid) Self {
        return @unionInit(Self, "invalid", tag);
    }
    
    pub const Invalid = union(enum) {
        left_angle_bracket_eof,
        left_angle_bracket_invalid,
        left_angle_bracket_fwdslash_in_prologue,
        invalid_in_prologue,
    };
};

pub fn next(self: *TokenStream, src: []const u8) NextReturnType {
    return switch (self.state) {
        .prologue => |prologue| switch (prologue) {
            .start => start_blk: {
                debug.assert(self.index == 0);
                self.index += xml.whitespaceLength(src, self.index);
                if (self.index == 0) {
                    switch (utility.getByte(src, self.index) orelse {
                        self.state = .{ .trailing = .end };
                        break :start_blk null;
                    }) {
                        '<' => {
                            const start_index = self.index;
                            
                            self.index += 1;
                            switch (utility.getByte(src, self.index) orelse {
                                self.state = .{ .trailing = .end };
                                break :start_blk TokenExt.initInvalid(.left_angle_bracket_eof);
                            }) {
                                '?' => todo("", null),
                                '!' => {
                                    self.index += 1;
                                },
                                
                                '/' => {
                                    self.state = .{ .trailing = .end };
                                    return TokenExt.initInvalid(.left_angle_bracket_fwdslash_in_prologue,);
                                },
                                
                                else => {
                                    const name_len = xml.validUtf8NameLength(src, self.index);
                                    self.index += name_len;
                                    self.state = if (name_len == 0) .{ .trailing = .end } else .{ .root = .elem_open_tag };
                                    const result = if (name_len == 0)
                                        TokenExt.initInvalid(.left_angle_bracket_invalid)
                                    else
                                        TokenExt.initToken(.elem_open_tag, .{ .beg = start_index, .end = self.index });
                                    break :start_blk result;
                                },
                            }
                        },
                        
                        else => {
                            self.state = .{ .trailing = .end };
                            return TokenExt.initInvalid(.invalid_in_prologue);
                        },
                    }
                }
            }
        },
        
        .root => |root| switch (root) {
            .elem_open_tag => todo("", null),
        },
        
        .trailing => |trailing| switch (trailing) {
            .end => return @as(NextReturnType, null),
        },
    };
}

const State = union(enum) {
    prologue: Prologue,
    root: Root,
    trailing: Trailing,
    
    const Prologue = union(enum) {
        start,
    };
    
    const Root = union(enum) {
        elem_open_tag,
        elem_close_tag,
    };
    
    const Trailing = union(enum) {
        end,
    };
};
