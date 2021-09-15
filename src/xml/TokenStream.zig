const std = @import("std");
const mem = std.mem;
const meta = std.meta;
const debug = std.debug;
const testing = std.testing;
const unicode = std.unicode;

const xml = @import("../xml.zig");
const Token = xml.Token;

const TokenStream = @This();
index: usize,
buffer: []const u8,
state: ParseState,

pub fn init(src: []const u8) TokenStream {
    return TokenStream{
        .index = 0,
        .buffer = src,
        .state = .{},
    };
}

pub fn reset(self: *TokenStream, new_src: ?[]const u8) void {
    self.* = TokenStream.init(new_src orelse self.buffer);
}

pub fn next(self: *TokenStream) ?Token {
    while (true) {
        switch (self.state.specific) {
            .end => return null,
            
            .eof => {
                debug.assert(self.index + 1 == self.buffer.len);
                self.state.specific = .end;
                return Token.init(self.index, .eof);
            },
            
            .invalid => {
                self.state.specific = .end;
                return Token.init(self.index, .invalid);
            },
            
            .start => {
                debug.assert(self.index == 0);
                return switch (self.buffer[self.index]) {
                    ' ',
                    '\t',
                    '\n',
                    '\r',
                    => blk: {
                        debug.assert(self.index == 0);
                        var whitespace_len: usize = 0;
                        self.state.specific = new_specific: for (self.buffer[self.index..]) |c| switch (c) {
                            ' ',
                            '\t',
                            '\n',
                            '\r',
                            => whitespace_len += 1,
                            
                            '<' => break :new_specific .@"<",
                            else => break :new_specific .invalid,
                        } else .eof;
                        
                        self.index += whitespace_len;
                        break :blk Token.initTag(0, .empty_whitespace, .{ .len = whitespace_len });
                    },
                    
                    '<' => self.onTagOpen(),
                    else => self.returnInvalid(),
                };
            },
            
            .@"<" => return self.onTagOpen(),
            
            .@"<{name}" => unreachable,
            .@">" => unreachable,
            
            .@"<{name}/>" => |tok| {
                self.index += 1;
                debug.assert(self.buffer[(self.index - 1)] == '/');
                debug.assert(self.buffer[self.index] == '>');
                debug.assert(self.index < self.buffer.len);
                self.state.specific = .@"</>";
                return tok;
            },
            
            .@"</>" => {
                if (self.index + 1 == self.buffer.len) {
                    self.state.specific = .end;
                    return Token.init(self.index, .eof);
                }
                self.index += 1;
                debug.assert(self.index < self.buffer.len); // Definitely want to enforce this invariant.
                
                const start_idx = self.index;
                for (self.buffer[self.index..]) |char, idx| {
                    switch (char) {
                        
                    }
                }
                
            },
        }
    }
}

/// Should be invoked after a tag closes to parse content.
fn onBetweenTags(self: *TokenStream, comptime only_accept_whitespace: bool) Token {
    _ = self;
    _ = only_accept_whitespace;
}

/// Should be invoked when a tag opens (e.g, after some text content, when a '<' is encountered).
/// Asserts that the current index has not changed since the left angle bracket was encountered (by asserting that buffer[index] == '<')
fn onTagOpen(self: *TokenStream) Token {
    
    const on_entry = self.*;
    defer debug.assert(!std.meta.eql(self.state.specific, on_entry.state.specific));
    
    debug.assert(self.buffer[self.index] == '<');
    self.index += 1;
    switch (self.buffer[self.index]) {
        '?' => unreachable,
        '!' => unreachable,
        '/' => unreachable,
        else => {
            if (!xml.isValidUtf8NameStartCharAt(self.index, self.buffer)) return self.returnInvalid();
            
            var tok = Token.initTag(self.index, .element_open, .{ .len = 1, .colon_offset = null });
            const element_open = &tok.info.element_open;
            
            self.state.specific = blk: for (self.buffer[self.index + 1..]) |char| {
                switch (char) {
                    ' ',
                    '\t',
                    '\n',
                    '\r',
                    => break :blk .@"<{name}",
                    
                    ':' => if (element_open.colon_offset == null) {
                        element_open.colon_offset = element_open.len;
                    } else break :blk .invalid,
                    
                    '/' => break :blk self.checkIfValidInlineCloseGetState(tok.index, element_open.*),
                    '>' => break :blk .@">",
                    else => if (!xml.isValidUtf8NameCharAt(self.index + element_open.len, self.buffer))
                        break :blk .invalid
                }
                
                element_open.len += 1;
            } else .invalid;
            
            self.index += element_open.len;
            return tok;
        },
    }
    
}

/// Returns the specific state pertaining to whether the character following '/' is '>',
/// and whether the file ends before a '>' could exist in the first place.
fn checkIfValidInlineCloseGetState(self: *TokenStream, start_index: usize, element: Token.Info.ElementId) ParseState.Specific {
    const next_idx = self.index + element.len + 1;
    const valid_close = (next_idx < self.buffer.len) and (self.buffer[next_idx] == '>');
    return if (valid_close)
        ParseState.Specific { .@"<{name}/>" = Token.initTag(start_index, .element_close, element) }
    else
        .invalid;
}

/// Should be invoked when an invalid character is encountered, and there is no tokenized information to return.
fn returnInvalid(self: *TokenStream) Token {
    self.state.specific = .end;
    return Token.init(self.index, .invalid);
}

const ParseState = struct {
    specific: Specific = .start,
    const Specific = union(enum) {
        end,
        eof,
        invalid,
        start,
        @"<",
        @"<{name}",
        @">",
        @"<{name}/>": Token,
        @"</>",
    };
};

comptime {
    _ = TokenStream.next;
}

test "Valid Empty Tags" {
    inline for (.{"<empty/>"}) |src| {
        var ts = TokenStream.init(src);
        var current: Token = undefined;
        
        current = ts.next().?;
        try testing.expectEqual(std.meta.activeTag(current.info), .element_open);
        try testing.expectEqualStrings("empty", current.slice(src));
        
        current = ts.next().?;
        try testing.expectEqual(std.meta.activeTag(current.info), .element_close);
        try testing.expectEqualStrings("empty", current.slice(src));
        
        current = ts.next().?;
        try testing.expectEqual(std.meta.activeTag(current.info), .eof);
        try testing.expectEqualStrings("", current.slice(src));
        
        try testing.expectEqual(ts.next(), null);
    }
}
