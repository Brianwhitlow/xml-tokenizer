const std = @import("std");
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
    
}

const ParseState = struct {
    
};
