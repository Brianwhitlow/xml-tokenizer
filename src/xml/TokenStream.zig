const std = @import("std");
const testing = std.testing;
const unicode = std.unicode;

const xml = @import("../xml.zig");
const Token = xml.Token;

const TokenStream = @This();
index: usize,
buffer: []const u8,
state: ParseState,

pub fn init(buffer: []const u8) TokenStream {
    return TokenStream {
        .index = 0,
        .buffer = buffer,
        .state = ParseState {},
    };
}

pub fn reset(self: *TokenStream, new_buffer: ?[]const u8) void {
    self.* = TokenStream.init(new_buffer orelse self.buffer);
}

pub fn next(self: *TokenStream) ?Token {
    while (true) : (self.index += 1) {
        if (self.index >= self.buffer.len) break;
        defer self.index += 1;
        
        const char = self.buffer[self.index];
        switch (self.state) {
            .invalid => break,
            
            .start => switch (char) {
                ' ', '\t', '\n', '\r',  => self.state = .start_whitespace,
                '<',                    => self.state = .@"<",
                else                    => {
                    self.state = .invalid;
                    return Token.init(self.index, .invalid);
                }
            },
            
            .start_whitespace => switch (char) {
                ' ', '\t', '\n', '\r',
                => continue,
                
                '<', => {
                    self.state = .@"<";
                    return Token.init(0, .{ .empty_whitespace = .{ .len = self.index } });
                },
                
                else => {
                    self.state = .invalid;
                    return Token.init(self.index, .invalid);
                }
            },
            
            .@"<" => switch (char) {
                '?', => self.state = .@"<?",
                '!', => self.state = .@"<!",
                '[', => self.state = .@"<[",
                '/', => self.state = .@"</",
                else => if (!xml.isValidNameStartCharUtf8At(self.index, self.buffer)) {
                    self.state = .invalid;
                    return Token.init(self.index, .invalid);
                } else {
                    self.state = .{ .@"<{name_start_char}" = .{ .index = self.index} };
                },
            },
            
            .@"<?" => unreachable,
            .@"<!" => unreachable,
            .@"<[" => unreachable,
            .@"</" => unreachable,
            
            .@"<{name_start_char}" => |info| switch (char) {
                ' ', '\t', '\n', '\r',
                => {
                    const result = Token.init(info.index, .{ .element_open = .{ .colon_offset = null, .len = (self.index - info.index) } });
                    self.state = .{ .@"<{element_id}" = .{ .index = info.index, .element_id = result.info.element_open } };
                    return result;
                },
                
                ':',
                => self.state = .{ .@"<{ns}:" = .{ .index = info.index, .colon_offset = (self.index - info.index) } },
                
                else
                => if (!xml.isValidNameCharUtf8At(self.index, self.buffer)) {
                    self.state = .invalid;
                    return Token.init(self.index, .invalid);
                }
            },
            
            .@"<{ns}:" => |info| switch (char) {
                ' ', '\t', '\n', '\r',
                => {
                    const result = Token.init(info.index, .{ .element_open = .{ .colon_offset = info.colon_offset, .len = (self.index - info.index) } });
                    self.state = .{ .@"<{element_id}" = .{ .index = info.index, .element_id = result.info.element_open } };
                    return result;
                },
                
                else
                => if (!xml.isValidNameCharUtf8At(self.index, self.buffer)) {
                    self.state = .invalid;
                    return Token.init(self.index, .invalid);
                }
            },
            
            .@"<{element_id}" => |elem_id_with_index| switch (char) {
                ' ', '\t', '\n', '\r',  => continue,
                '/',                    => self.state = .{ .@"<{element_id}/" = elem_id_with_index },
                '>',                    => self.state = .{ .@">" = .{ .index = self.index } },
                else                    => if (!xml.isValidNameStartCharUtf8At(self.index, self.buffer)) {
                    self.state = .invalid;
                    return Token.init(self.index, .invalid);
                } else {
                    self.state = .{ .@"{attr_name_start_char}" = .{
                        .index = self.index,
                        .elem_id_with_index = elem_id_with_index,
                    } };
                }
            },
            
            .@"<{element_id}/" => |elem_id_with_index| switch (char) {
                '>',
                => {
                    self.state = .{ .@">" = .{ .index = self.index } };
                    return Token.init(elem_id_with_index.index, .{ .element_close = elem_id_with_index.element_id });
                },
                
                else
                => return Token.init(self.index, .invalid)
            },
            
            .@">" => |begin| switch (char) {
                ' ', '\t', '\n', '\r',  => self.state = .{ .@">{whitespace}" = begin },
                '<',                    => self.state = .@"<",
                else                    => self.state = .{ .@">{text}" = begin }
            },
            
            .@">{whitespace}" => |begin| switch (char) {
                '<', => {
                    self.state = .@"<";
                    return Token.init(begin.index + 1, .{ .empty_whitespace = .{ .len = self.index - (begin.index + 1) } });
                },
                
                ' ', '\t', '\n', '\r',
                => continue,
                
                else
                => self.state = .{ .@">{text}" = begin }
            },
            
            .@">{text}" => |begin| switch (char) {
                '<', => {
                    self.state = .@"<";
                    return Token.init(begin.index + 1, .{ .text = .{ .len = self.index - (begin.index + 1) } });
                },
                
                else
                => continue,
            },
            
            .@"{attr_name_start_char}" => |at| switch (char) {
                ' ', '\t', '\n', '\r',
                '=',
                => {
                    const attr_name_info: ParseState.AttrNameInfo = .{
                        .elem_id_with_index = at.elem_id_with_index,
                        .index = at.index,
                        .colon_offset = null,
                        .prefixed_name_len = (self.index - at.index),
                    };
                    
                    self.state = switch (char) {
                        '=', => .{ .@"{attr_name}=" = attr_name_info },
                        else => .{ .@"{attr_name}" = attr_name_info },
                    };
                },
                
                ':',
                => self.state = .{ .@"{attr_pre}:" = .{
                    .elem_id_with_index = at.elem_id_with_index,
                    .index = at.index,
                    .colon_offset = (self.index - at.index),
                } },
                
                else => if (!xml.isValidNameCharUtf8At(self.index, self.buffer)) {
                    self.state = .invalid;
                    return Token.init(self.index, .invalid);
                }
            },
            
            // TODO: Look into whether the character after a colon has to be a valid name start character, or if any valid name character is fine.
            .@"{attr_pre}:" => |info| if (!xml.isValidNameCharUtf8At(self.index, self.buffer)) {
                self.state = .invalid;
                return Token.init(self.index, .invalid);
            } else {
                self.state = .{ .@"{attr_pre}:{start_char}" = info };
            },
            
            .@"{attr_pre}:{start_char}" => |info| switch (char) {
                ' ', '\t', '\n', '\r',
                '=',
                => {
                    const attr_name_info: ParseState.AttrNameInfo = .{
                        .elem_id_with_index = info.elem_id_with_index,
                        .index = info.index,
                        .colon_offset = info.colon_offset,
                        .prefixed_name_len = (self.index - info.index),
                    };
                    
                    self.state = switch (char) {
                        '=', => .{ .@"{attr_name}=" = attr_name_info },
                        else => .{ .@"{attr_name}" = attr_name_info },
                    };
                },
                
                else
                => if (!xml.isValidNameCharUtf8At(self.index, self.buffer)) {
                    self.state = .invalid;
                    return Token.init(self.index, .invalid);
                },
            },
            
            .@"{attr_name}" => |info| switch (char) {
                ' ', '\t', '\n', '\r',  => continue,
                '=',                    => self.state = .{ .@"{attr_name}=" = info },
                else                    => {
                    self.state = .invalid;
                    return Token.init(self.index, .invalid);
                },
            },
            
            .@"{attr_name}=" => |info| switch (char) {
                ' ', '\t', '\n', '\r',
                => continue,
                
                '"', '\'',
                => {
                    const attr_name_eql_info: ParseState.AttrNameEqlInfo = .{
                        .elem_id_with_index = info.elem_id_with_index,
                        .index = info.index,
                        .colon_offset = info.colon_offset,
                        .prefixed_name_len = info.prefixed_name_len,
                        .sep = (self.index - (info.index + info.prefixed_name_len)),
                    };
                    
                    self.state = switch (char) {
                        '"',  => .{ .@"{attr_name}=\"" = attr_name_eql_info, },
                        '\'', => .{ .@"{attr_name}='" = attr_name_eql_info, },
                        else  => unreachable,
                    };
                },
                
                else
                => {
                    self.state = .invalid;
                    return Token.init(self.index, .invalid);
                },
            },
            
            .@"{attr_name}=\"",
            .@"{attr_name}='", => |info| switch (char) {
                '"', '\''
                => {
                    switch (self.state) {
                        .@"{attr_name}=\"" => switch (char) { '"' => {}, else => continue },
                        .@"{attr_name}='" => switch (char) { '\'' => {}, else => continue },
                        else => unreachable,
                    }
                    
                    self.state = .{ .@"<{element_id}" = info.elem_id_with_index };
                    return Token.init(info.index, .{ .attribute = .{
                        .colon_offset = info.colon_offset,
                        .prefixed_name_len = info.prefixed_name_len,
                        .separation = info.sep,
                        .value_len = ((self.index + 1) - (info.index + info.prefixed_name_len + info.sep)),
                    } });
                },
                
                else
                => continue,
            },
        }
    }
    
    return null;
}

const ParseState = union(enum) {
    invalid,
    start,
    start_whitespace,
    @"<",
    @"</",
    @"<?",
    @"<!",
    @"<[",
    @"<{name_start_char}": Index,
    @"<{ns}:": struct { index: usize, colon_offset: usize },
    @"<{element_id}": ElemIdWithIndex,
    @"<{element_id}/": ElemIdWithIndex,
    @">": Index,
    @">{whitespace}": Index,
    @">{text}": Index,
    
    @"{attr_name_start_char}":  struct { elem_id_with_index: ElemIdWithIndex, index: usize },
    @"{attr_pre}:":             AttrPrefixInfo,
    @"{attr_pre}:{start_char}": AttrPrefixInfo,
    @"{attr_name}":             AttrNameInfo,
    @"{attr_name}=":            AttrNameInfo,
    @"{attr_name}=\"":          AttrNameEqlInfo,
    @"{attr_name}='":           AttrNameEqlInfo,
    //@"{attr_name}='{content}'": struct { elem_id_with_index: ElemIdWithIndex, index: usize, colon_offset: ?usize, prefixed_name_len: usize, sep: usize, value_len: usize, },
    
    
    pub const Index = struct { index: usize };
    pub const ElemIdWithIndex = struct { element_id: Token.Info.ElementId, index: usize };
    pub const AttrPrefixInfo  = struct { elem_id_with_index: ElemIdWithIndex, index: usize, colon_offset: usize };
    pub const AttrNameInfo    = struct { elem_id_with_index: ElemIdWithIndex, index: usize, colon_offset: ?usize, prefixed_name_len: usize };
    pub const AttrNameEqlInfo = struct { elem_id_with_index: ElemIdWithIndex, index: usize, colon_offset: ?usize, prefixed_name_len: usize, sep: usize };
};

comptime {
    _ = TokenStream.next;
}
