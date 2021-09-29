const std = @import("std");
const unicode = std.unicode;
const xml = @import("../xml.zig");
const Token = @import("Token.zig");


const TokenStream = @This();
buffer: []const u8,
state: State,

pub fn init(src: []const u8) TokenStream {
    return TokenStream {
        .buffer = src,
        .state = .{},
    };
}

pub fn reset(self: *TokenStream, new_src: ?[]const u8) void {
    self.* = TokenStream.init(new_src orelse self.buffer);
}

pub const Error = error {
    PrematureEof,
    ContentNotAllowedInPrologue,
    InvalidUtf8Codepoint,
    InvalidUtf8CodepointNameStartChar,
    ExpectedClosingTag,
    InvalidNameChar,
};

/// The return type of TokenStream.next().
pub const NextRet = ?(Error!Token);

/// Returns null if there are no more tokens to parse.
pub fn next(self: *TokenStream) NextRet {
    errdefer std.debug.assert(self.state.info == .err);
    switch (self.state.info) {
        .err => return null,
        .start => {
            std.debug.assert(self.getIndex() == 0);
            switch (self.getByte() orelse return self.returnError(Error.PrematureEof)) {
                ' ',
                '\t',
                '\n',
                '\r',
                => todo(),
                
                '<' => {
                    const start_index = self.getIndex();
                    _ = start_index;
                    
                    self.incrByByte();
                    switch (self.getUtf8() orelse return self.returnError(Error.InvalidUtf8Codepoint)) {
                        '/' => todo(),
                        '?' => todo(),
                        '!' => todo(),
                        else => {
                            if (!xml.isValidUtf8NameStartChar(self.getUtf8().?)) {
                                return self.returnError(Error.InvalidUtf8CodepointNameStartChar);
                            }
                            
                            self.incrByUtf8Len();
                            while (self.getUtf8()) |char| : (self.incrByUtf8Len()) switch (char) {
                                ' ',
                                '\t',
                                '\n',
                                '\r',
                                => break,
                                '/' => break,
                                '>' => break,
                                else => if (!xml.isValidUtf8NameChar(char)) return self.returnError(Error.InvalidNameChar),
                            } else return self.returnError(Error.ExpectedClosingTag);
                            
                            const len = self.getIndex() - start_index;
                            _ = len;
                            switch (self.getUtf8().?) {
                                ' ',
                                '\t',
                                '\n',
                                '\r',
                                => todo(),
                                '/' => todo(),
                                '>' => todo(),
                                else => unreachable
                            }
                        }
                    }
                },
                
                else => return self.returnError(Error.ContentNotAllowedInPrologue)
            }
        },
    }
}

inline fn todo() noreturn {
    unreachable;
}

fn returnError(self: *TokenStream, err: Error) NextRet {
    self.state.info = .{ .err = err };
    return @as(NextRet, err);
}


/// Expects and asserts that the current UTF8 codepoint is valid.
fn incrByUtf8Len(self: *TokenStream) void {
    const codepoint = self.getUtf8().?;
    self.state.index += unicode.utf8CodepointSequenceLength(codepoint) catch unreachable;
}

/// Asserts that the current utf8 codepoint is exactly one byte long,
/// thus ensuring that subsequent traversal will be valid.
fn incrByByte(self: *TokenStream) void {
    self.state.index += requirements: {
        const codepoint = self.getUtf8() orelse std.debug.panic("Invalid UTF8 codepoint or EOF encountered when trying to increment by a single byte.", .{});
        const codepoint_len = unicode.utf8CodepointSequenceLength(codepoint) catch unreachable;
        std.debug.assert(codepoint_len == 1);
        break :requirements 1;
    };
}

fn getUtf8(self: TokenStream) ?u21 {
    const start_byte = self.getByte() orelse return null;
    const sequence_len = unicode.utf8ByteSequenceLength(start_byte) catch return null;
    
    const beg = self.state.index;
    const end = beg + sequence_len;
    if (end >= self.buffer.len) return null;
    
    return unicode.utf8Decode(self.buffer[beg..end]) catch null;
}

fn getByte(self: TokenStream) ?u8 {
    const index = self.state.index;
    const buffer = self.buffer;
    const in_range = (index < buffer.len);
    return if (in_range) buffer[index] else null;
}

fn getIndex(self: TokenStream) usize {
    return self.state.index;
}



const State = struct {
    index: usize = 0,
    info: Info = .start,
    
    const Info = union(enum) {
        err: Error,
        start,
        
    };
};

test {
    var ts = TokenStream.init(
        \\<empty/>
    );
    
    _ = try ts.next() orelse error.IsNull;
}
