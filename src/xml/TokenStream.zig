const std = @import("std");
const mem = std.mem;
const math = std.math;
const meta = std.meta;
const debug = std.debug;
const testing = std.testing;

const xml = @import("../xml.zig");
const utility = @import("utility.zig");

fn todo(comptime fmt: []const u8, args: anytype) noreturn {
    debug.panic("TODO: " ++ fmt, if (@TypeOf(args) == @TypeOf(null)) .{} else args);
}

const Token = xml.Token;

const TokenStream = @This();
src: []const u8,
index: usize,
depth: usize,
state: State,

pub fn init(src: []const u8) TokenStream {
    return .{
        .src = src,
        .index = 0,
        .depth = 0,
        .state = .{ .prologue = .start },
    };
}

pub fn reset(self: *TokenStream, new_src: ?[]const u8) void {
    self.* = TokenStream.init(new_src orelse self.src);
}

pub const NextReturnType = ?Result;
pub const Result = union(enum) {
    const Self = @This();
    token: Token,
    
    fn getToken(self: Self) !Token {
        return switch (self) {
            .token => |token| token,
        };
    }
    
    fn initToken(tag: Token.Tag, loc: Token.Loc) Self {
        return @unionInit(Self, "token", Token.init(tag, loc));
    }
};

pub fn next(ts: *TokenStream) NextReturnType {
    return switch (ts.state) {
        .prologue => |prologue| {
            debug.assert(ts.depth == 0);
            defer {
                const depth_is_0 = (ts.depth == 0);
                const depth_is_not_0 = (!depth_is_0);
                switch (ts.state) {
                    .prologue,
                    .trailing,
                    => debug.assert(depth_is_0),
                    .root => debug.assert(depth_is_not_0),
                }
            }
            
            switch (prologue) {
                .start => {
                    //defer {
                    //    //const bad_State = !switch (ts.state) {
                    //    //    .prologue => |end_prologue_state| end_prologue_state != .start,
                    //    //    else => true,
                    //    //};
                    //    //_ = bad_State;
                    //    //if (bad_State) `std.debug.panic("std.debug.assert(false)` should be here", .{});
                    //}
                    debug.assert(ts.index == 0);
                    const start_index = ts.index;
                    
                    ts.index += xml.whitespaceLength(ts.src, ts.index);
                    if (ts.index != 0) {
                        const loc = Token.Loc { .beg = start_index, .end = ts.index };
                        return ts.returnToken(.prologue, .whitespace, loc);
                    }
                    
                    return switch (utility.getByte(ts.src, ts.index) orelse return ts.returnNullSetTrailingEnd()) {
                        '<' => ts.tokenizeAfterLeftAngleBracket(.prologue),
                        else => todo("Invalid in prologue.", null),
                    };
                },
                .whitespace => {
                    debug.assert(ts.index != 0);
                    const start_index = ts.index;
                    _ = start_index;
                    
                    return switch (utility.getByte(ts.src, ts.index) orelse return ts.returnNullSetTrailingEnd()) {
                        '<' => ts.tokenizeAfterLeftAngleBracket(.prologue),
                        else => todo("Invalid in prologue.", null),
                    };
                },
                
                .pi_target => {
                    switch (utility.getByte(ts.src, ts.index) orelse todo("Error for PI Target followed by eof.", null)) {
                        '?' => {
                            const start_index = ts.index;
                            ts.index += 1;
                            if (utility.getByte(ts.src, ts.index) orelse todo("Error for unclosed PI followed by eof.", null) == '>') {
                                ts.index += 1;
                                return ts.returnToken(.prologue, .pi_end, .{ .beg = start_index, .end = ts.index });
                            }
                            todo("Error for PI Target followed by non-whitespace, invalid token '?{c}'", .{utility.getByte(ts.src, ts.index).?});
                        },
                        else => {
                            const whitespace_len = xml.whitespaceLength(ts.src, ts.index);
                            if (whitespace_len == 0) {
                                todo("Error for PI Target followed by non-whitespace, invalid character '{c}'", .{ utility.getByte(ts.src, ts.index).? });
                            }
                            ts.index += whitespace_len;
                            return ts.tokenizePiTok(.prologue);
                        },
                    }
                },
                .pi_tok_string => {
                    ts.index += xml.whitespaceLength(ts.src, ts.index);
                    return ts.tokenizePiTok(.prologue);
                },
                .pi_tok_other => {
                    ts.index += xml.whitespaceLength(ts.src, ts.index);
                    return ts.tokenizePiTok(.prologue);
                },
                .pi_end => {
                    const start_index = ts.index;
                    const start_byte = utility.getByte(ts.src, start_index) orelse return ts.returnNullSetTrailingEnd();
                    switch (start_byte) {
                        '<' => return ts.tokenizeAfterLeftAngleBracket(.prologue),
                        else => {
                            const whitespace_len = xml.whitespaceLength(ts.src, start_index);
                            if (whitespace_len == 0) {
                                todo("Error for '{c}' in prologue.", .{ start_byte });
                            }
                            ts.index += whitespace_len;
                            return ts.returnToken(.prologue, .whitespace, .{ .beg = start_index, .end = ts.index });
                        },
                    }
                },
                
                .comment => {
                    debug.assert(ts.src[ts.index - 1] == '>');
                    return switch (utility.getByte(ts.src, ts.index) orelse return ts.returnNullSetTrailingEnd()) {
                        '<' => ts.tokenizeAfterLeftAngleBracket(.prologue),
                        else => {
                            const start_index = ts.index;
                            ts.index += xml.whitespaceLength(ts.src, ts.index);
                            if (ts.index != start_index) {
                                const loc = Token.Loc { .beg = start_index, .end = ts.index };
                                return ts.returnToken(.prologue, .whitespace, loc);
                            }
                            
                            todo("Error for invalid '{c}' in prologue.", .{utility.getByte(ts.src, ts.index)});
                        },
                    };
                },
            }
        },
        
        .root => |root| {
            debug.assert(ts.depth != 0);
            defer {
                const depth_is_0 = (ts.depth == 0);
                const state_is_not_root = (ts.state != .root);
                if (depth_is_0 or state_is_not_root)
                    debug.assert(depth_is_0 and state_is_not_root);
            }
            
            return switch (root) {
                .elem_open_tag => todo("", null),
                .elem_close_tag => todo("", null),
            };
        },
        
        .trailing => |trailing| {
            debug.assert(ts.depth == 0);
            defer debug.assert(ts.depth == 0);
            defer debug.assert(ts.depth == 0 and ts.state == .trailing);
            switch (trailing) {
                .end => return @as(NextReturnType, null),
            }
        },
    };
}

fn tokenizePiTok(ts: *TokenStream, comptime state: meta.Tag(State)) NextReturnType {
    debug.assert(ts.state == state);
    debug.assert(!xml.isSpace(utility.getByte(ts.src, ts.index).?));
    
    const start_index = ts.index;
    const start_byte: u8 = utility.getByte(ts.src, start_index) orelse todo("Error for unclosed PI followed by eof.", null);
    if (start_byte == '?' and (utility.getByte(ts.src, ts.index + 1) orelse 0) == '>') {
        ts.index += 2;
        return ts.returnToken(state, .pi_end, .{ .beg = start_index, .end = ts.index });
    }
    
    if (xml.isStringQuote(start_byte)) {
        ts.index += utility.lenOfUtf8OrNull(start_byte).?;
        while (utility.getUtf8(ts.src, ts.index)) |str_char| : (ts.index += utility.lenOfUtf8OrNull(str_char).?) {
            if (str_char == start_byte) {
                ts.index += 1;
                break;
            }
        } else todo("Error for unclosed unclosed PI string token followed by eof.", null);
        return ts.returnToken(state, .pi_tok_string, .{ .beg = start_index, .end = ts.index });
    }
    
    while (utility.getUtf8(ts.src, ts.index)) |pi_tok_char| : (ts.index += utility.lenOfUtf8OrNull(pi_tok_char).?) {
        const len = utility.lenOfUtf8OrNull(pi_tok_char).?;
        const is_byte = (len == 1);
        
        const is_space = is_byte and xml.isSpace(@intCast(u8, pi_tok_char));
        const is_string_quote = is_byte and xml.isStringQuote(@intCast(u8, pi_tok_char));
        const is_pi_end = (pi_tok_char == '?') and ((utility.getByte(ts.src, ts.index + 1) orelse 0) == '>');
        
        if (is_space or is_string_quote or is_pi_end) break;
    } else todo("Error for unclosed PI other token followed by eof.", null);
    
    return ts.returnToken(state, .pi_tok_other, .{ .beg = start_index, .end = ts.index });
}

fn tokenizeAfterLeftAngleBracket(ts: *TokenStream, comptime state: meta.Tag(State)) NextReturnType {
    debug.assert(utility.getByte(ts.src, ts.index).? == '<');
    debug.assert(ts.state == state);
    
    const start_index = ts.index;
    ts.index += 1;
    switch (utility.getByte(ts.src, ts.index) orelse todo("", null)) {
        '?' => {
            ts.index += 1;
            const name_len = xml.validUtf8NameLength(ts.src, ts.index);
            if (name_len == 0) {
                todo("Error for lack of pi target name", null);
            }
            ts.index += name_len;
            return ts.returnToken(state, .pi_target, .{ .beg = start_index, .end = ts.index });
        },
        '!' => {
            ts.index += 1;
            return switch (utility.getByte(ts.src, ts.index) orelse todo("Eof after '<!'.", null)) {
                '-' => dash_blk: {
                    ts.index += 1;
                    break :dash_blk switch (utility.getByte(ts.src, ts.index) orelse todo("Error for eof after '<!-'.", null)) {
                        '-' => dash_dash_blk: {
                            ts.index += 1;
                            while (utility.getUtf8(ts.src, ts.index)) |comment_char| : (ts.index += utility.lenOfUtf8OrNull(comment_char).?) {
                                if (comment_char != '-') continue;
                                
                                ts.index += 1;
                                if (utility.getByte(ts.src, ts.index) orelse 0 != '-') continue;
                                
                                ts.index += 1;
                                if (utility.getByte(ts.src, ts.index) orelse 0 != '>') continue;
                                
                                ts.index += 1;
                                break :dash_dash_blk ts.returnToken(state, .comment, .{ .beg = start_index, .end = ts.index });
                            } else break :dash_dash_blk todo("Error for unclosed comment followed by eof or invalid UTF8.", null);
                        },
                        else => todo("Error for '<!-{c}'", .{ utility.getByte(ts.src, ts.index) }),
                    };
                },
                
                '[' => switch (state) {
                    .prologue => todo("Error for '<![' in prologue.", null),
                    .root => todo("", null),
                    .trailing => todo("Error for '<![' in trailing section.", null),
                },
                
                'D' => {
                    ts.index += 1;
                    if (mem.startsWith(u8, ts.src[ts.index..], "OCTYPE")) {
                        switch (state) {
                            .prologue => {
                                ts.index += "OCTYPE".len;
                                todo("Error for unsupported '<!DOCTYPE'.", null);
                            },
                            .root => todo("Error for '<!DOCTYPE' in root.", null),
                            .trailing => todo("Error for '<!DOCTYPE' in trailing section.", null),
                        }
                    } else {
                        const invalid_start = ts.index - 1;
                        ts.index = math.clamp(ts.index + "OCTYPE".len, 0, ts.src.len);
                        todo("Error for invalid '<!{s}'.", .{ ts.src[invalid_start..ts.index] });
                    }
                },
                
                else => todo("Error for '<!{c}'.", .{ utility.getByte(ts.src, ts.index).? }),
            };
        },
        '/' => todo("Invalid close tag start in prologue.", null),
        else => todo("", null),
    }
}

fn returnNullSetTrailingEnd(self: *TokenStream) NextReturnType {
    self.state = .{ .trailing = .end };
    return null;
}

fn returnToken(ts: *TokenStream, comptime set_state: meta.Tag(State), tag: Token.Tag, loc: Token.Loc) Result {
    ts.state = @unionInit(
        State,
        @tagName(set_state),
        meta.stringToEnum(
            meta.TagPayload(State, set_state),
            @tagName(tag),
        ) orelse debug.panic("'{s}' has no field '{s}'.", .{@typeName(meta.TagPayload(State, set_state)), @tagName(tag)}),
    );
    return Result.initToken(tag, loc);
}

const State = union(enum) {
    prologue: Prologue,
    root: Root,
    trailing: Trailing,
    
    fn assertSimilarToTokenTag(comptime T: type, comptime exceptions: []const T) void {
        const diff = utility.fieldNamesDiff(Token.Tag, T);
        outerloop: inline for (diff.b) |actual| {
            inline for (exceptions) |exempted| {
                if (mem.eql(u8, actual, @tagName(exempted))) {
                    continue :outerloop;
                }
            }
            @compileError(std.fmt.comptimePrint("Field '{s}' in '{s}' has not been exempted.", .{actual, @typeName(T)}));
        }
    }
    
    const Prologue = enum {
        start,
        whitespace,
        pi_target,
        pi_tok_string,
        pi_tok_other,
        pi_end,
        comment,
        
        comptime {
            @setEvalBranchQuota(2000);
            assertSimilarToTokenTag(@This(), &.{ .start });
        }
    };
    
    const Root = enum {
        elem_open_tag,
        elem_close_tag,
        
        comptime {
            assertSimilarToTokenTag(@This(), &.{});
        }
    };
    
    const Trailing = enum {
        end,
        
        comptime {
            assertSimilarToTokenTag(@This(), &.{ .end });
        }
    };
};




pub const tests = struct {
    fn unwrapNext(result: NextReturnType) error{ NullToken }!Token {
        const unwrapped: Result = try (result orelse error.NullToken);
        return try unwrapped.getToken();
    }
    
    pub fn expectPiTarget(ts: *TokenStream, expected_name: []const u8) !void {
        try Token.tests.expectPiTarget(ts.src, try unwrapNext(ts.next()), expected_name);
    }
    
    pub fn expectPiTokOther(ts: *TokenStream, expected_slice: []const u8) !void {
        try Token.tests.expectPiTokOther(ts.src, try unwrapNext(ts.next()), expected_slice);
    }
    
    pub fn expectPiTokString(ts: *TokenStream, expected_data: []const u8, quote_type: xml.StringQuote) !void {
        try Token.tests.expectPiTokString(ts.src, try unwrapNext(ts.next()), expected_data, quote_type);
    }
    
    pub fn expectPiEnd(ts: *TokenStream) !void {
        try Token.tests.expectPiEnd(ts.src, try unwrapNext(ts.next()));
    }
    
    pub fn expectWhitespace(ts: *TokenStream, expected_slice: []const u8) !void {
        try Token.tests.expectWhitespace(ts.src, try unwrapNext(ts.next()), expected_slice);
    }
    
    pub fn expectComment(ts: *TokenStream, expected_data: []const u8) !void {
        try Token.tests.expectComment(ts.src, try unwrapNext(ts.next()), expected_data);
    }
    
    pub fn expectElemOpenTag(ts: *TokenStream, expected_name: []const u8) !void {
        try Token.tests.expectElemOpenTag(ts.src, try unwrapNext(ts.next()), expected_name);
    }
    
    pub fn expectElemCloseTag(ts: *TokenStream, expected_name: []const u8) !void {
        try Token.tests.expectElemCloseTag(ts.src, try unwrapNext(ts.next()), expected_name);
    }
    
    pub fn expectElemCloseInline(ts: *TokenStream) !void {
        try Token.tests.expectElemCloseInline(ts.src, try unwrapNext(ts.next()));
    }
    
    pub fn expectAttrName(ts: *TokenStream, expected_slice: []const u8) !void {
        try Token.tests.expectAttrName(ts.src, try unwrapNext(ts.next()), expected_slice);
    }
    
    pub fn expectAttrValEmpty(ts: *TokenStream) !void {
        try Token.tests.expectAttrValEmpty(ts.src, try unwrapNext(ts.next()));
    }
    
    pub fn expectAttrValSegmentText(ts: *TokenStream, expected_slice: []const u8) !void {
        try Token.tests.expectAttrValSegmentText(ts.src, try unwrapNext(ts.next()), expected_slice);
    }
    
    pub fn expectAttrValSegmentEntityRef(ts: *TokenStream, expected_name: []const u8) !void {
        try Token.tests.expectAttrValSegmentEntityRef(ts.src, try unwrapNext(ts.next()), expected_name);
    }
    
    pub fn expectContentText(ts: *TokenStream, expected_slice: []const u8) !void {
        try Token.tests.expectContentText(ts.src, try unwrapNext(ts.next()), expected_slice);
    }
    
    pub fn expectContentCData(ts: *TokenStream, expected_data: []const u8) !void {
        try Token.tests.expectContentCData(ts.src, try unwrapNext(ts.next()), expected_data);
    }
    
    pub fn expectContentEntityRef(ts: *TokenStream, expected_name: []const u8) !void {
        try Token.tests.expectContentEntityRef(ts.src, try unwrapNext(ts.next()), expected_name);
    }
    
    pub fn expectNull(ts: *TokenStream) !void {
        try testing.expectEqual(@as(NextReturnType, null), ts.next());
    }
};


test "TokenStream empty source" {
    var ts = TokenStream.init("");
    try tests.expectNull(&ts);
}

test "TokenStream whitespace only" {
    const whitespace = " \t\n\r";
    var ts = TokenStream.init(whitespace);
    try tests.expectWhitespace(&ts, whitespace);
    try tests.expectNull(&ts);
}

test "TokenStream prologue comment" {
    var ts: TokenStream = undefined;
    const data_samples = .{ (""), ("- "), (" foo bar baz") };
    const whitespace_samples = .{ (""), (" \t\n\r") };
    inline for (data_samples) |data| {
        ts.reset("<!--" ++ data ++ "-->");
        try tests.expectComment(&ts, data);
        try tests.expectNull(&ts);
        
        inline for (whitespace_samples) |whitespace_a| {
            inline for (whitespace_samples) |whitespace_b| {
                ts.reset(whitespace_a ++ "<!--" ++ data ++ "-->" ++ whitespace_b);
                if (whitespace_a.len != 0) try tests.expectWhitespace(&ts, whitespace_a);
                try tests.expectComment(&ts, data);
                if (whitespace_b.len != 0) try tests.expectWhitespace(&ts, whitespace_b);
                try tests.expectNull(&ts);
                
                
                inline for (whitespace_samples) |whitespace_c| {
                    inline for (data_samples) |data2| {
                        const comment1 = "<!--" ++ data ++ "-->";
                        const comment2 = "<!--" ++ data2 ++ "-->";
                        ts.reset(whitespace_a ++ comment1 ++ whitespace_b ++ comment2 ++ whitespace_c);
                        if (whitespace_a.len != 0) try tests.expectWhitespace(&ts, whitespace_a);
                        try tests.expectComment(&ts, data);
                        if (whitespace_b.len != 0) try tests.expectWhitespace(&ts, whitespace_b);
                        try tests.expectComment(&ts, data2);
                        if (whitespace_c.len != 0) try tests.expectWhitespace(&ts, whitespace_c);
                        try tests.expectNull(&ts);
                    }
                }
            }
        }
    }
}

test "TokenStream prologue processing instructions" {
    var ts: TokenStream = undefined;
    _ = ts;
    const target_samples = [_][]const u8 { ("foo"), ("A") };
    const whitespace_samples = [_][]const u8 { (""), (" "), (" \t\n\r") };
    const non_name_token_samples = [_][]const u8 { ("?"), ("&;") };
    const string_quotes = comptime string_quotes: {
        var blk_out: [xml.string_quotes.len]*const [1]u8 = undefined;
        for (xml.string_quotes) |string_quote, idx|
            blk_out[idx] = &[_] u8 { string_quote };
        break :string_quotes blk_out;
    };
    
    inline for (target_samples) |target| {
        inline for (whitespace_samples) |whitespace_ignored| {
            ts.reset("<?" ++ target ++ whitespace_ignored ++ "?>");
            try tests.expectPiTarget(&ts, target);
            try tests.expectPiEnd(&ts);
            try tests.expectNull(&ts);
        }
        
        inline for (whitespace_samples) |whitespace_a| {
            inline for (whitespace_samples) |whitespace_ignored| {
                inline for (whitespace_samples) |whitespace_c| {
                    ts.reset(whitespace_a ++ "<?" ++ target ++ whitespace_ignored ++ "?>" ++ whitespace_c);
                    if (whitespace_a.len != 0) try tests.expectWhitespace(&ts, whitespace_a);
                    try tests.expectPiTarget(&ts, target);
                    try tests.expectPiEnd(&ts);
                    if (whitespace_c.len != 0) try tests.expectWhitespace(&ts, whitespace_c);
                    try tests.expectNull(&ts);
                }
            }
        }
        
        inline for (whitespace_samples[1..]) |whitespace_obligatory| { // must exclude first element, which is an empty string; here, we require a whitespace always.
            inline for (whitespace_samples) |whitespace_ignored| {
                inline for (non_name_token_samples) |non_name_token| {
                    ts.reset("<?" ++ target ++ whitespace_obligatory ++ non_name_token ++ whitespace_ignored ++ "?>");
                    try tests.expectPiTarget(&ts, target);
                    try tests.expectPiTokOther(&ts, non_name_token);
                    try tests.expectPiEnd(&ts);
                    try tests.expectNull(&ts);
                    
                    inline for (string_quotes) |string_quote| {
                        const quote_type = comptime xml.StringQuote.from(string_quote[0]);
                        inline for (string_quotes) |other_string_quote| {
                            const other_quote_type = comptime xml.StringQuote.from(other_string_quote[0]);
                            comptime if (quote_type == other_quote_type) continue;
                            inline for (
                                non_name_token_samples ++ [_][]const u8 {
                                    (other_string_quote ++ "bar" ++ other_string_quote),
                                    (other_string_quote ** 2),
                                    (other_string_quote),
                                    ("foo"),
                                    (""),
                                }
                            ) |data| {
                                @setEvalBranchQuota(2000);
                                ts.reset("<?" ++ target ++ whitespace_obligatory ++ string_quote ++ data ++ string_quote ++ whitespace_ignored ++ "?>");
                                try tests.expectPiTarget(&ts, target);
                                try tests.expectPiTokString(&ts, data, quote_type);
                                try tests.expectPiEnd(&ts);
                                try tests.expectNull(&ts);
                            }
                        }
                    }
                }
                
                inline for (string_quotes) |string_quote| {
                    const quote_type = comptime xml.StringQuote.from(string_quote[0]);
                    ts.reset(
                        "<?"
                        ++ target
                        ++ whitespace_obligatory ++ "foo"
                        ++ whitespace_obligatory ++ "="
                        ++ whitespace_ignored ++ string_quote ++ "bar" ++ string_quote
                        ++ whitespace_ignored
                        ++ "?>"
                    );
                    try tests.expectPiTarget(&ts, target);
                    try tests.expectPiTokOther(&ts, "foo");
                    try tests.expectPiTokOther(&ts, "=");
                    try tests.expectPiTokString(&ts, "bar", quote_type);
                    try tests.expectPiEnd(&ts);
                    try tests.expectNull(&ts);
                }
            }
        }
        
    }
}
