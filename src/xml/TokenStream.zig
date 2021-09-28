const std = @import("std");



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

pub const Token = struct {
    index: usize,
    info: Info,
    
    pub fn init(index: usize, info: Info) Token {
        return Token {
            .index = index,
            .info = info,
        };
    }
    
    pub fn initTag(index: usize, comptime tag: std.meta.Tag(Info), value: @TypeOf(@field(@unionInit(Info, @tagName(tag), undefined), @tagName(tag)))) Token {
        return Token.init(index, @unionInit(Info, @tagName(tag), value));
    }
    
    fn slice(self: Token, src: []const u8) []const u8 {
        inline for (comptime std.meta.fieldNames(Info)) |field_name| {
            if (@field(Info, field_name) == self.info) {
                return @field(self.info, field_name).slice(self.index, src);
            }
        }
        
        unreachable;
    }
    
    pub fn get(self: Token, comptime field: std.meta.Tag(Info), comptime func_name: []const u8, src: []const u8) GetReturnType(field, func_name) {
        std.debug.assert(std.meta.activeTag(self.info) == field);
        
        const tag_name = @tagName(field);
        const FieldType = @TypeOf(@field(@unionInit(Info, tag_name, undefined), tag_name));
        
        const ObligateReturn = fn(FieldType, usize, []const u8) []const u8;
        const OptionalReturn = fn(FieldType, usize, []const u8) ?[]const u8;
        
        const func = @field(FieldType, func_name);
        comptime std.debug.assert(switch (@TypeOf(func)) {
            ObligateReturn,
            OptionalReturn,
            => true,
            else => false
        });
        return func(@field(self.info, tag_name), self.index, src);
    }
    
    pub const Info = union(enum) {
        element_open: ElementOpen,
        element_close_tag: ElementCloseTag,
        element_close_inline: ElementCloseInline,
        
        processing_instructions: ProcessingInstructions,
        comment: Comment,
        
        // Assert that all info variants have a `slice` method
        comptime {
            inline for (std.meta.fields(@This())) |field_info|
                std.debug.assert(@hasDecl(field_info.field_type, "slice"));
        }
        
        pub const ElementId = struct {
            const TagType = enum { @"<", @"</" };
            fn ElementIdImpl(comptime tag: TagType) type {
                return struct {
                    prefix_len: usize, // slice[prefix_len] == ':' if prefix_len != 0
                    full_len: usize,
                    
                    pub fn slice(self: @This(), index: usize, src: []const u8) []const u8 {
                        const beg = index;
                        const end = index + self.full_len;
                        return src[beg..end];
                    }
                    
                    pub fn prefix(self: @This(), index: usize, src: []const u8) ?[]const u8 {
                        const sliced = self.slice(index, src);
                        const beg = @tagName(tag).len;
                        const end = self.prefix_len;
                        return if (self.prefix_len != 0) sliced[beg..end] else null;
                    }
                    
                    pub fn name(self: @This(), index: usize, src: []const u8) []const u8 {
                        const sliced = self.slice(index, src);
                        const beg = @tagName(tag).len + if (self.prefix_len == 0) 0 else self.prefix_len + 1;
                        const end = sliced.len;
                        return sliced[beg..end];
                    }
                };
            }
        }.ElementIdImpl;
        
        pub const ElementOpen = ElementId(.@"<");
        pub const ElementCloseTag = ElementId(.@"</");
        pub const ElementCloseInline = struct {
            pub fn slice(_: @This(), index: usize, src: []const u8) []const u8 {
                const beg = index;
                const end = beg + ("/>".len);
                return src[beg..end];
            }
        };
        
        pub const ProcessingInstructions = struct {
            target_len: usize,
            full_len: usize,
            
            pub fn slice(self: @This(), index: usize, src: []const u8) []const u8 {
                const beg = index;
                const end = beg + self.full_len;
                return src[beg..end];
            }
            
            pub fn target(self: @This(), index: usize, src: []const u8) []const u8 {
                const sliced = self.slice(index, src);
                const beg = ("<?".len);
                const end = beg + self.target_len;
                return sliced[beg..end];
            }
            
            pub fn instructions(self: @This(), index: usize, src: []const u8) ?[]const u8 {
                const sliced = self.slice(index, src);
                const beg = self.target(index, src).len;
                const end = self.full_len - ("?>".len);
                return sliced[beg..end];
            }
        };
        
        pub const Comment = struct {
            full_len: usize,
            
            pub fn slice(self: @This(), index: usize, src: []const u8) []const u8 {
                const beg = index;
                const end = beg + self.full_len;
                return src[beg..end];
            }
            
            pub fn data(self: @This(), index: usize, src: []const u8) []const u8 {
                const sliced = self.slice(index, src);
                const beg = ("<!--".len);
                const end = sliced.len - ("-->".len);
                return sliced[beg..end];
            }
        };
        
        
    };
    
    
    fn GetReturnType(comptime field: std.meta.Tag(Info), comptime func_name: []const u8) type {
        const tag_name = @tagName(field);
        const FieldType = @TypeOf(@field(@unionInit(Info, tag_name, undefined), tag_name));
        
        const func = @field(FieldType, func_name);
        return @TypeOf(func(std.mem.zeroes(FieldType), 0, ""));
    }
};

pub const Error = error {
    
};

pub fn next(self: *TokenStream) ?(Error!Token) {
    switch (self.state.info) {
        .start => todo(),
    }
}

inline fn todo() noreturn {
    unreachable;
}

const State = struct {
    index: usize = 0,
    info: Info = .start,
    
    const Info = union(enum) {
        start,
        
    };
};

test {
    var src: []const u8 =
        \\</empty>
    ;
    
    var ts = TokenStream.init(src);
    _ = ts;
    
    var token = Token.initTag(0, .element_open, .{ .full_len = 0, .prefix_len = 0 });
    _ = token.get(.element_open, "prefix", src);
    _ = token.slice(src);
    
    //while (ts.next()) |tok_err_union| {
    //    const tok = tok_err_union catch continue;
    //    std.debug.print("{}\n", .{tok});
    //}
}
