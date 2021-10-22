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
                    //    //if (bad_State) debug.panic("fuck", .{});
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

fn tokenizeAfterLeftAngleBracket(ts: *TokenStream, comptime state: meta.Tag(State)) NextReturnType {
    debug.assert(utility.getByte(ts.src, ts.index).? == '<');
    debug.assert(ts.state == state);
    
    const start_index = ts.index;
    ts.index += 1;
    return switch (utility.getByte(ts.src, ts.index) orelse todo("", null)) {
        '?' => todo("", null),
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
    };
}

fn returnNullSetTrailingEnd(self: *TokenStream) NextReturnType {
    self.state = .{ .trailing = .end };
    return null;
}

fn returnToken(self: *TokenStream, comptime set_state: meta.Tag(State), tag: Token.Tag, loc: Token.Loc) Result {
    self.state = @unionInit(
        State,
        @tagName(set_state),
        meta.stringToEnum(
            meta.TagPayload(State, set_state),
            @tagName(tag),
        ) orelse debug.panic("'{s}' has no field '{s}'.", .{@typeName(State), @tagName(tag)}),
    );
    return Result.initToken(tag, loc);
}

const State = union(enum) {
    prologue: Prologue,
    root: Root,
    trailing: Trailing,
    
    fn assertSimilarToTokenTag(comptime T: type, comptime exceptions: []const T) void {
        comptime {
            for (exceptions) |field_tag| {
                const field_name = @tagName(field_tag);
                if (meta.trait.hasField(field_name)(Token.Tag)) {
                    @compileError("'exceptions' parameter contains '" ++ field_name ++ "' tag, which is present in " ++ @typeName(Token.Tag));
                }
            }
            
            const field_names = meta.fieldNames(T);
            for (field_names) |field_name| {
                @setEvalBranchQuota(1000 * field_names.len * field_name.len);
                if (mem.count(T, exceptions, &.{ @field(T, field_name) }) > 1) {
                    @compileError("'exceptions' parameter contains multiple instances of '" ++ field_name ++ "'.");
                }
            }
            
            mainloop: for (field_names) |field_name| {
                @setEvalBranchQuota(1000 * field_names.len * field_name.len);
                for (exceptions) |exempted_field_tag| {
                    if (mem.eql(u8, field_name, @tagName(exempted_field_tag))) {
                        continue :mainloop;
                    }
                    const TokTag = Token.Tag;
                    const hasField = meta.trait.hasField(field_name);
                    const tok_tag_name = @typeName(TokTag);
                    if (!hasField(TokTag)) {
                        @compileError("'" ++ tok_tag_name ++ "' has no field '" ++ field_name ++ "', which has also not been exempted.");
                    }
                }
            }
        }
    }
    
    const Prologue = enum {
        start,
        whitespace,
        comment,
        
        comptime {
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
    
    pub fn expectProcessingInstructions(
        ts: *TokenStream,
        expected_name: []const u8,
        pi_tokens: []const union(enum) {
            string: struct {
                data: []const u8,
                quote: xml.StringQuote,
            },
            other: struct {
                slice: []const u8,
            },
        },
    ) !void {
        try Token.tests.expectPiTarget(ts.src, try unwrapNext(ts.next()), expected_name);
        for (pi_tokens) |pi_tok| {
            const actual_tok = try unwrapNext(ts.next());
            try switch (pi_tok) {
                .string => |string| Token.tests.expectPiTokString(ts.src, actual_tok, string.data, string.quote),
                .other => |other| Token.tests.expectPiTokOther(ts.src, actual_tok, other.slice),
            };
        }
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
    
    pub fn expectAttribute(
        ts: *TokenStream,
        expected_name: []const u8,
        expected_value: ?[]const union(enum) {
            text: struct { slice: []const u8 },
            entity_ref: struct { name: []const u8 },
        },
    ) !void {
        try Token.tests.expectAttrName(ts.src, try unwrapNext(ts.next()), expected_name);
        if (expected_value) |expected_segments| {
            for (expected_segments) |segment| {
                const actual_tok = try unwrapNext(ts.next());
                try switch (segment) {
                    .text => |text| Token.tests.expectAttrValSegmentText(ts.src, actual_tok, text.slice),
                    .entity_ref => |entity_ref| Token.tests.expectAttrValSegmentEntityRef(ts.src, actual_tok, entity_ref.name),
                };
            }
        } else {
            const actual_tok = try unwrapNext(ts.next());
            try Token.tests.expectAttrValEmpty(ts.src, actual_tok);
        }
    }
    
    pub fn expectContent(
        ts: *TokenStream,
        expected_content: []const union(enum) {
            whitespace: struct { slice: []const u8 },
            text: struct { slice: []const u8 },
            cdata: struct { data: []const u8 },
            entity_ref: struct { name: []const u8 },
        },
    ) !void {
        debug.assert(expected_content.len > 0);
        for (expected_content) |content| {
            const actual_tok = try unwrapNext(ts.next());
            try switch (content) {
                .whitespace => |whitespace| Token.tests.expectWhitespace(ts.src, actual_tok, whitespace.slice),
                .text => |text| Token.tests.expectContentText(ts.src, actual_tok, text.slice),
                .cdata => |cdata| Token.tests.expectContentCData(ts.src, actual_tok, cdata.data),
                .entity_ref => |entity_ref| Token.tests.expectContentEntityRef(ts.src, actual_tok, entity_ref.name),
            };
        }
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
