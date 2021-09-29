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
    
    pub fn get(self: Token, comptime field: std.meta.Tag(Info), comptime func_name: []const u8, src: []const u8) blk_type: {
        const tag_name = @tagName(field);
        const FieldType = @TypeOf(@field(@unionInit(Info, tag_name, undefined), tag_name));
        const func = @field(FieldType, func_name);
        break :blk_type @TypeOf(func(std.mem.zeroes(FieldType), 0, ""));
    } {
        std.debug.assert(std.meta.activeTag(self.info) == field);
        
        const tag_name = @tagName(field);
        const FieldType = @TypeOf(@field(@unionInit(Info, tag_name, undefined), tag_name));
        
        const func = @field(FieldType, func_name);
        comptime std.debug.assert(switch (@TypeOf(func)) {
            fn(FieldType, usize, []const u8) []const u8,
            fn(FieldType, usize, []const u8) ?[]const u8,
            => true,
            else => false
        });
        
        return func(@field(self.info, tag_name), self.index, src);
    }
    
    fn allVariantsHaveSliceFunc(comptime Union: type) bool {
        inline for (std.meta.fields(Union)) |field_info| {
            const FieldType = field_info.field_type;
            return @hasDecl(FieldType, "slice") and switch (@TypeOf(@field(FieldType, "slice"))) {
                fn (FieldType, usize, []const u8) []const u8,
                fn (FieldType, usize, []const u8) ?[]const u8,
                => true,
                else => false,
            };
        }
    }
    
    pub const Info = union(enum) {
        element_open: ElementOpen,
        element_close_tag: ElementCloseTag,
        element_close_inline: ElementCloseInline,
        
        comment: Comment,
        cdata: CharDataSection,
        
        pi_target: ProcessingInstructionsTarget,
        pi_token: ProcessingInstructionsToken,
        
        // Assert that all info variants have a `slice` method
        comptime {
            std.debug.assert(allVariantsHaveSliceFunc(@This()));
            //inline for (std.meta.fields(@This())) |field_info| {
            //    const FieldType = field_info.field_type;
            //    std.debug.assert(@hasDecl(FieldType, "slice"));
                
            //    const FuncType = @TypeOf(@field(FieldType, "slice"));
                
            //    std.debug.assert(switch (FuncType) {
            //        fn(FieldType, usize, []const u8) []const u8,
            //        fn(FieldType, usize, []const u8) ?[]const u8,
            //        => true,
            //        else => false,
            //    });
            //}
            
        }
        
        pub const Length = struct {
            len: usize,
            
            pub fn slice(self: @This(), index: usize, src: []const u8) []const u8 {
                const beg = index;
                const end = index + self.len;
                return src[beg..end];
            }
        };
        
        const ElementId = struct {
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
        
        fn DataSection(comptime start_tag: []const u8, comptime end_tag: []const u8) type {
            return struct {
                full_len: usize,
                
                pub fn slice(self: @This(), index: usize, src: []const u8) []const u8 {
                    const beg = index;
                    const end = beg + self.full_len;
                    return src[beg..end];
                }
                
                pub fn data(self: @This(), index: usize, src: []const u8) []const u8 {
                    const sliced = self.slice(index, src);
                    const beg = start_tag.len;
                    const end = sliced.len - end_tag.len;
                    return sliced[beg..end];
                }
            };
        }
        
        pub const ElementOpen = ElementId(.@"<");
        pub const ElementCloseTag = ElementId(.@"</");
        pub const ElementCloseInline = struct {
            pub fn slice(_: @This(), index: usize, src: []const u8) []const u8 {
                const beg = index;
                const end = beg + ("/>".len);
                return src[beg..end];
            }
        };
        
        pub const Comment = DataSection("<!--", "-->");
        pub const CharDataSection = DataSection("<![CDATA[", "]]>");
        
        pub const ProcessingInstructionsTarget = struct {
            target_len: usize,
            
            pub fn slice(self: @This(), index: usize, src: []const u8) []const u8 {
                const beg = index;
                const end = beg + ("<?".len) + self.target_len;
                return src[beg..end];
            }
            
            pub fn name(self: @This(), index: usize, src: []const u8) []const u8 {
                const sliced = self.slice(index, src);
                const beg = ("<?".len);
                const end = beg + self.target_len;
                return sliced[beg..end];
            }
        };
        
        pub const ProcessingInstructionsToken = union(enum) {
            name: Length,
            eql: Eql,
            string: QuotedString,
            end_tag: EndTag,
            
            // Assert that all info variants have a `slice` method
            comptime {
                std.debug.assert(allVariantsHaveSliceFunc(@This()));
                //inline for (std.meta.fields(@This())) |field_info| {
                //    const FieldType = field_info.field_type;
                    
                //    std.debug.assert(@hasDecl(FieldType, "slice"));
                //    const FuncType = @TypeOf(@field(FieldType, "slice"));
                    
                //    std.debug.assert(switch (FuncType) {
                //        fn(FieldType, usize, []const u8) []const u8,
                //        fn(FieldType, usize, []const u8) ?[]const u8,
                //        => true,
                //        else => false,
                //    });
                //}
            }
            
            pub const Eql = struct {
                pub fn slice(_: @This(), index: usize, src: []const u8) []const u8 {
                    const beg = index;
                    const end = beg + ("=".len);
                    return src[beg..end];
                }
            };
            
            pub const QuotedString = struct {
                content_len: usize,
                
                pub fn slice(self: @This(), index: usize, src: []const u8) []const u8 {
                    const beg = index;
                    const end = beg + ("'".len) + self.content_len + ("'".len);
                    return src[beg..end];
                }
                
                pub fn data(self: @This(), index: usize, src: []const u8) []const u8 {
                    const sliced = self.slice(index, src);
                    const beg = ("'".len);
                    const end = beg + self.content_len;
                    return sliced[beg..end];
                }
            };
            
            pub const EndTag = struct {
                pub fn slice(_: @This(), index: usize, src: []const u8) []const u8 {
                    const beg = index;
                    const end = beg + ("?>".len);
                    return src[beg..end];
                }
            };
            
            pub fn slice(self: @This(), index: usize, src: []const u8) []const u8 {
                inline for (comptime std.meta.fieldNames(@This())) |name| {
                    if (@field(@This(), name) == self)
                        return @field(self, name).slice(index, src);
                }
                
                unreachable;
                //return switch (self) {
                //    .name => |name| name.slice(index, src),
                //    .eql => |eql| eql.slice(index, src),
                //    .string => |string| string.slice(index, src),
                //    .end_Tag => |end_tag| end_tag.slice(index, src),
                //};
            }
        };
    };
};

pub const Error = error {
    
};

pub fn next(self: *TokenStream) ?(Error!Token) {
    switch (self.state.info) {
        .start => {
            std.debug.assert(self.state.index == 0);
            
        },
    }
}

inline fn todo() noreturn {
    unreachable;
}

inline fn getUtf8(self: TokenStream) ?u21 {
    
}

inline fn getByte(self: TokenStream) ?u8 {
    const index = self.state.index;
    const buffer = self.buffer;
    const in_range = (index < buffer.len);
    return if (in_range) buffer[index] else null;
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
    
    while (ts.next()) |tok_err_union| {
        const tok = tok_err_union catch continue;
        std.debug.print("{}\n", .{tok});
    }
}
