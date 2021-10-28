const xml = @import("xml/xml.zig");
pub const Token = xml.Token;
pub const TokenStream = xml.TokenStream;

comptime {
    _ = xml;
    _ = Token;
    _ = TokenStream;
}
