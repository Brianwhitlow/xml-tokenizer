const std = @import("std");

pub const Tokenizer = struct {
    buffer: []const u8,
    index: usize,
    parse_state: TokenizationState,
    
    pub fn init(xml_text: []const u8) @This() {
        return .{ .buffer = xml_text, .index = 0, .parse_state = .start };
    }
    
    pub fn reset(self: *@This(), new_xml_text: ?[]const u8) void {
        self.* = init(new_xml_text orelse self.buffer);
    }
    
    /// Return `self.buffer[tok.start..tok.end].
    pub fn sliceFrom(self: @This(), tok: Token) []const u8 {
        return self.buffer[tok.start..tok.end];
    }
    
    pub fn next(self: *@This()) Token {
        var result: Token = .{
            .start = self.index,
            .end = self.index,
            .id = .eof,
        };
        
        // Legal character range according to XML 1.0 W3C Recommendation 5th Edition:
        // #x9 | #xA | #xD | [#x20-#xD7FF] | [#xE000-#xFFFD] | [#x10000-#x10FFFF]
        
        if (self.index == self.buffer.len and self.parse_state != .seek_next_token) {
            result.id = .invalid;
        }
        
        while (self.index < self.buffer.len) {
            const current_char = self.buffer[self.index];
            switch (self.parse_state) {
                .start
                => switch (current_char) {
                    ' ', '\t', '\r', '\x0B', '\x0C', '\n',
                    => self.index += 1,
                    
                    '<',
                    => {
                        result.start = self.index;
                        self.index += 1;
                        self.parse_state = .{ .angle_bracket_left = .pending };
                    },
                    
                    else
                    => unreachable,
                },
                
                .seek_next_token
                => switch (current_char) {
                    ' ', '\t', '\r', '\x0B', '\x0C', '\n',
                    => self.index += 1,
                    
                    '<',
                    => {
                        result.start = self.index;
                        self.index += 1;
                        self.parse_state = .{ .angle_bracket_left = .pending };
                    },
                    
                    else
                    => {
                        result.end = result.start;
                        result.id = .{ .text = .beg };
                        self.parse_state = .{ .inside_text = .pending };
                        break;
                    },
                },
                
                .angle_bracket_left
                => |*angle_bracket_left| switch (angle_bracket_left.*) {
                    .pending
                    => switch (current_char) {
                        '/',
                        => {
                            result.start = self.index - 1;
                            self.index += 1;
                            result.end = self.index;
                            result.id = .{ .element_close = .beg };
                            
                            angle_bracket_left.* = .{ .element_close_identifier = .{ .first_char = true } };
                            break;
                        },
                        
                        '?',
                        => {
                            self.index += 1;
                            self.parse_state = .{ .inside_processing_instruction = .seek_target_termination };
                            
                            result.end = self.index;
                            result.id = .{ .processing_instruction = .beg };
                            break;
                        },
                        
                        '!',
                        => {
                            self.index += 1;
                            angle_bracket_left.* = .bang;
                        },
                        
                        else
                        => {
                            if (std.ascii.isPunct(current_char) or std.ascii.isDigit(current_char)) {
                                unreachable; // Identifiers cannot begin with digits, and obviously not punctuation characters.
                            }
                            
                            result.end = self.index;
                            result.id = .{ .element_open = .beg };
                            
                            angle_bracket_left.* = .word_character;
                            
                            break;
                        },
                    },
                    
                    .word_character
                    => switch (current_char) {
                        ' ', '\t', '\r', '\x0B', '\x0C', '\n',
                        '/', '>',
                        => {
                            result.end = self.index;
                            result.id = .element_identifier;
                            self.parse_state = .{ .after_element_identifier = .pending };
                            break;
                        },
                        
                        ':',
                        => {
                            result.end = self.index;
                            result.id = .element_namespace;
                            self.index += 1;
                            break;
                        },
                        
                        else
                        => {
                            if (std.ascii.isPunct(current_char)) {
                                unreachable; // Puncuation characters can't be in an identifier name.
                            }
                            
                            self.index += 1;
                        },
                    },
                    
                    .element_close_identifier
                    => |*element_close_identifier| switch (current_char) {
                        ' ', '\t', '\r', '\x0B', '\x0C', '\n',
                        '>',
                        => {
                            result.end = self.index;
                            result.id = .element_identifier;
                            
                            self.parse_state = .{ .after_element_identifier = .in_close_tag };
                            break;
                        },
                        
                        ':',
                        => {
                            if (element_close_identifier.first_char) {
                                unreachable; // Can't name a namespace without at least 1 character
                            }
                            
                            result.end = self.index;
                            result.id = .element_namespace;
                            self.index += 1;
                            break;
                        },
                        
                        else
                        => {
                            if (std.ascii.isPunct(current_char) or (std.ascii.isDigit(current_char) and element_close_identifier.first_char)) {
                                unreachable; // Puncuation characters can't be in an identifier name.
                            }
                            
                            element_close_identifier.first_char = false;
                            self.index += 1;
                        },
                    },
                    
                    .bang
                    => switch (current_char) {
                        '-',
                        => {
                            self.index += 1;
                            angle_bracket_left.* = .bang_dash;
                        },
                        
                        '[',
                        => {
                            self.index += 1;
                            angle_bracket_left.* = .{ .bang_square_bracket = .{ .expected_char_index = 0 } };
                        },
                        
                        else
                        => unreachable,
                    },
                    
                    .bang_dash
                    => switch (current_char) {
                        '-',
                        => {
                            self.index += 1;
                            result.end = self.index;
                            result.id = .{ .comment = .beg };
                            
                            self.parse_state = .{ .inside_comment = .seeking_dash };
                            break;
                        },
                        
                        else
                        => unreachable,
                    },
                    
                    .bang_square_bracket
                    => |*bang_square_bracket| {
                        const expected_chars = "CDATA[";
                        if (expected_chars[bang_square_bracket.expected_char_index] != current_char) {
                            unreachable;
                        }
                        
                        self.index += 1;
                        bang_square_bracket.expected_char_index += 1;
                        
                        if (bang_square_bracket.expected_char_index == expected_chars.len) {
                            result.end = self.index;
                            result.id = .{ .char_data = .beg };
                            self.parse_state = .{ .inside_char_data = .seek_square_bracket };
                            break;
                        }
                    },
                },
                
                .after_element_identifier
                => |*after_element_identifier| switch (after_element_identifier.*) {
                    .pending
                    => switch (current_char) {
                        ' ', '\t', '\r', '\x0B', '\x0C', '\n',
                        => self.index += 1,
                        
                        '>',
                        => {
                            result.start = self.index;
                            self.index += 1;
                            result.end = self.index;
                            result.id = .{ .element_open = .end_parent };
                            self.parse_state = .seek_next_token;
                            break;
                        },
                        
                        '/',
                        => {
                            result.start = self.index;
                            self.index += 1;
                            after_element_identifier.* = .slash;
                        },
                        
                        else
                        => {
                            if (std.ascii.isPunct(current_char) or std.ascii.isDigit(current_char)) {
                                unreachable;
                            }
                            
                            result.start = self.index;
                            self.index += 1;
                            after_element_identifier.* = .found_attribute_identifier;
                        },
                    },
                    
                    .slash
                    => switch (current_char) {
                        '>',
                        => {
                            self.index += 1;
                            result.end = self.index;
                            result.id = .{ .element_open = .end_empty };
                            
                            self.parse_state = .seek_next_token;
                            break;
                        },
                        
                        else
                        => unreachable,
                    },
                    
                    .in_close_tag
                    => switch (current_char) {
                        ' ', '\t', '\r', '\x0B', '\x0C', '\n',
                        => self.index += 1,
                        
                        '>',
                        => {
                            result.start = self.index;
                            self.index += 1;
                            result.end = self.index;
                            result.id = .{ .element_close = .end };
                            
                            self.parse_state = .seek_next_token;
                            break;
                        },
                        
                        else
                        => unreachable,
                    },
                    
                    .found_attribute_identifier
                    => switch (current_char) {
                        ' ', '\t', '\r', '\x0B', '\x0C', '\n',
                        '=',
                        => {
                            result.end = self.index;
                            result.id = .attribute_identifier;
                            after_element_identifier.* = .seek_attribute_eql;
                            break;
                        },
                        
                        else
                        => {
                            if (std.ascii.isPunct(current_char)) {
                                unreachable;
                            }
                            
                            self.index += 1;
                        },
                    },
                    
                    .seek_attribute_eql
                    => switch (current_char) {
                        ' ', '\t', '\r', '\x0B', '\x0C', '\n',
                        => self.index += 1,
                        
                        '=',
                        => {
                            self.index += 1;
                            after_element_identifier.* = .seek_attribute_value;
                        },
                        
                        else
                        => unreachable,
                    },
                    
                    .seek_attribute_value
                    => switch (current_char) {
                        ' ', '\t', '\r', '\x0B', '\x0C', '\n',
                        => self.index += 1,
                        
                        '"', '\'',
                        => {
                            result.start = self.index;
                            self.index += 1;
                            result.end = self.index;
                            result.id = .{ .attribute_value = .beg };
                            
                            after_element_identifier.* = .{ .inside_attribute_value = .{ .enclosing_char = current_char } };
                            break;
                        },
                        
                        else
                        => unreachable,
                    },
                    
                    .inside_attribute_value
                    => |inside_attribute_value| switch (current_char) {
                        '&',
                        => {
                            result.start = self.index;
                            
                            self.index += 1;
                            after_element_identifier.* = .{ .attribute_value_entity_reference = .{
                                .enclosing_char = inside_attribute_value.enclosing_char,
                            } };
                        },
                        
                        else
                        => {
                            if (current_char == inside_attribute_value.enclosing_char) {
                                result.start = self.index;
                                self.index += 1;
                                result.end = self.index;
                                result.id = .{ .attribute_value = .end };
                                
                                after_element_identifier.* = .pending;
                                break;
                            }
                            
                            self.index += 1;
                        },
                    },
                    
                    .attribute_value_entity_reference
                    => |attribute_value_entity_reference| switch (current_char) {
                        ';',
                        => {
                            self.index += 1;
                            result.end = self.index;
                            result.id = .entity_reference;
                            
                            after_element_identifier.* = .{ .inside_attribute_value = .{
                                .enclosing_char = attribute_value_entity_reference.enclosing_char,
                            } };
                            break;
                        },
                        
                        else
                        => self.index += 1,
                    },
                },
                
                .inside_text
                => |*inside_text| switch (inside_text.*) {
                    .pending
                        => switch (current_char) {
                        '<',
                        => {
                            result.start = self.index;
                            result.end = self.index;
                            result.id = .{ .text = .end };
                            
                            self.parse_state = .seek_next_token;
                            break;
                        },
                        
                        '&',
                        => {
                            result.start = self.index;
                            
                            self.index += 1;
                            inside_text.* = .entity_reference;
                        },
                        
                        else
                        => self.index += 1,
                    },
                    
                    .entity_reference
                    => switch (current_char) {
                        ';',
                        => {
                            self.index += 1;
                            result.end = self.index;
                            result.id = .entity_reference;
                            
                            inside_text.* = .pending;
                            break;
                        },
                        
                        else
                        => self.index += 1,
                    },
                },
                
                .inside_comment
                => |*inside_comment| switch (inside_comment.*) {
                    .seeking_dash
                    => switch (current_char) {
                        '-',
                        => {
                            result.start = self.index;
                            self.index += 1;
                            inside_comment.* = .found_dash1;
                        },
                        
                        else
                        => self.index += 1,
                    },
                    
                    .found_dash1
                    => switch (current_char) {
                        '-',
                        => {
                            self.index += 1;
                            inside_comment.* = .found_dash2;
                        },
                        
                        else
                        => {
                            self.index += 1;
                            inside_comment.* = .seeking_dash;
                        }
                    },
                    
                    .found_dash2
                    => switch (current_char) {
                        '>',
                        => {
                            self.index += 1;
                            result.end = self.index;
                            result.id = .{ .comment = .end };
                            
                            self.parse_state = .seek_next_token;
                            break;
                        },
                        
                        else
                        => unreachable,
                    },
                },
                
                .inside_processing_instruction
                => |*inside_processing_instruction| switch (inside_processing_instruction.*) {
                    .seek_target_termination
                    => switch (current_char) {
                        ' ', '\t', '\r', '\x0B', '\x0C', '\n',
                        => {
                            result.end = self.index;
                            result.id = .processing_instruction_target;
                            inside_processing_instruction.* = .seek_instructions_start;
                            break;
                        },
                        
                        else
                        => self.index += 1,
                    },
                    
                    .seek_instructions_start
                    => switch (current_char) {
                        ' ', '\t', '\r', '\x0B', '\x0C', '\n',
                        => self.index += 1,
                        
                        else
                        => {
                            result.start = self.index;
                            inside_processing_instruction.* = .seek_instructions_termination;
                        }
                    },
                    
                    .seek_instructions_termination
                    => switch (current_char) {
                        '?',
                        => {
                            result.end = self.index;
                            self.index += 1;
                            inside_processing_instruction.* = .found_question_mark;
                        },
                        
                        else
                        => self.index += 1,
                    },
                    
                    .found_question_mark
                    => switch (current_char) {
                        '>',
                        => {
                            result.id = .processing_instructions_text;
                            self.index -= 1;
                            inside_processing_instruction.* = .return_instructions_termination;
                            break;
                        },
                        
                        else
                        => inside_processing_instruction.* = .seek_instructions_termination
                    },
                    
                    .return_instructions_termination
                    => {
                        std.debug.assert(current_char == '?');
                        std.debug.assert(self.buffer[self.index + 1] == '>');
                        
                        result.start = self.index;
                        self.index += 2;
                        result.end = self.index;
                        result.id = .{ .processing_instruction = .end };
                        
                        self.parse_state = .seek_next_token;
                        break;
                    }
                    
                },
                
                .inside_char_data
                => |*inside_char_data| switch (inside_char_data.*) {
                    .seek_square_bracket
                    => switch (current_char) {
                        ']',
                        => {
                            result.start = self.index;
                            self.index += 1;
                            inside_char_data.* = .found_square_bracket1;
                        },
                        
                        else
                        => self.index += 1,
                    },
                    
                    .found_square_bracket1
                    => switch (current_char) {
                        ']',
                        => {
                            self.index += 1;
                            inside_char_data.* = .found_square_bracket2;
                        },
                        
                        else
                        => {
                            self.index += 1;
                            inside_char_data.* = .seek_square_bracket;
                        },
                    },
                    
                    .found_square_bracket2
                    => switch (current_char) {
                        '>',
                        => {
                            self.index += 1;
                            result.end = self.index;
                            result.id = .{ .char_data = .end };
                            
                            inside_char_data.* = .found_termination;
                            break;
                        },
                        
                        else
                        => {
                            self.index += 1;
                            inside_char_data.* = .seek_square_bracket;
                        },
                    },
                    
                    .found_termination
                    => self.parse_state = .seek_next_token,
                },
            }
        }
        
        return result;
    }
    
    pub const TokenizationState = union(enum) {
        start,
        seek_next_token,
        
        angle_bracket_left: union(enum) {
            pending,
            word_character,
            element_close_identifier: struct { first_char: bool = true, },
            bang,
            bang_dash,
            bang_square_bracket: struct { expected_char_index: u8 = 0, },
        },
        
        after_element_identifier: union(enum) {
            pending,
            slash,
            in_close_tag,
            found_attribute_identifier,
            seek_attribute_eql,
            seek_attribute_value,
            inside_attribute_value: AttributeValueEnclosingCharCache,
            attribute_value_entity_reference: AttributeValueEnclosingCharCache,
            
            const AttributeValueEnclosingCharCache = struct { enclosing_char: u8, };
        },
        
        inside_text: enum {
            pending,
            entity_reference,
        },
        
        inside_comment: enum {
            seeking_dash,
            found_dash1,
            found_dash2,
        },
        
        inside_processing_instruction: union(enum) {
            seek_target_termination,
            seek_instructions_start,
            seek_instructions_termination,
            found_question_mark,
            return_instructions_termination,
        },
        
        inside_char_data: enum {
            seek_square_bracket,
            found_square_bracket1,
            found_square_bracket2,
            found_termination,
        },
    };
    
    pub const Token = struct {
        start: usize,
        end: usize,
        id: Id,
        
        pub const Id = union(enum) {
            invalid,
            eof,
            
            element_namespace,
            element_open: ElementOpen,
            element_close: Delim,
            
            processing_instruction_target,
            element_identifier,
            attribute_identifier,
            
            processing_instructions_text,
            processing_instruction: Delim,
            attribute_value: Delim,
            text: Delim,
            comment: Delim,
            char_data: Delim,
            
            entity_reference,
            
            
            pub const Delim = enum { beg, end };
            pub const ElementOpen = enum { beg, end_empty, end_parent };
        };
        
        pub fn init () @This() {
            return .{ .start = 0, .end = 0, .id = .invalid, };
        }
        
    };
    
};

test "Basic Tokenization" {
    var tokenizer = Tokenizer.init(
        \\<content attr1= 'value&apos;'>
        \\    (2 &gt; 4 == false)
        \\    <el id="0" />
        \\</content>
    );
    var current = Tokenizer.Token.init();
    var text_start: usize = undefined;
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .{ .element_open = .beg });
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), "<");
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .element_identifier);
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), "content");
    
    
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .attribute_identifier);
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), "attr1");
    
    current = tokenizer.next(); text_start = current.end;
    try std.testing.expectEqual(current.id, .{ .attribute_value = .beg });
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .entity_reference);
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), "&apos;");
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .{ .attribute_value = .end });
    
    try std.testing.expectEqualStrings(tokenizer.buffer[text_start..current.start], "value&apos;");
    
    
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .{ .element_open = .end_parent });
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), ">");
    
    
    
    current = tokenizer.next(); text_start = current.end;
    try std.testing.expectEqual(current.id, .{ .text = .beg });
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .entity_reference);
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), "&gt;");
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .{ .text = .end });
    
    try std.testing.expectEqualStrings(tokenizer.buffer[text_start..current.start], "\n    (2 &gt; 4 == false)\n    ");
    
    
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .{ .element_open = .beg });
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), "<");
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .element_identifier);
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), "el");
    
    
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .attribute_identifier);
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), "id");
    
    current = tokenizer.next(); text_start = current.end;
    try std.testing.expectEqual(current.id, .{ .attribute_value = .beg });
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .{ .attribute_value = .end });
    
    try std.testing.expectEqualStrings(tokenizer.buffer[text_start..current.start], "0");
    
    
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .{ .element_open = .end_empty });
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), "/>");
    
    
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .{ .element_close = .beg });
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), "</");
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .element_identifier);
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), "content");
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .{ .element_close = .end });
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), ">");
    
}

test "Comments" {
    var tokenizer = Tokenizer.init(
        \\<content>
        \\    <!--Hello Comments!-->
        \\    <!--- -->
        \\    <!-- - -->
        \\    <!---->
        \\</content>
    );
    var current = Tokenizer.Token.init();
    var text_start: usize = undefined;
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .{ .element_open = .beg });
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), "<");
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .element_identifier);
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), "content");
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .{ .element_open = .end_parent });
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), ">");
    
    
    
    current = tokenizer.next(); text_start = current.end;
    try std.testing.expectEqual(current.id, .{ .comment = .beg });
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), "<!--");
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .{ .comment = .end });
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), "-->");
    
    try std.testing.expectEqualStrings(tokenizer.buffer[text_start..current.start], "Hello Comments!");
    
    
    
    current = tokenizer.next(); text_start = current.end;
    try std.testing.expectEqual(current.id, .{ .comment = .beg });
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), "<!--");
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .{ .comment = .end });
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), "-->");
    
    try std.testing.expectEqualStrings(tokenizer.buffer[text_start..current.start], "- ");
    
    
    
    current = tokenizer.next(); text_start = current.end;
    try std.testing.expectEqual(current.id, .{ .comment = .beg });
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), "<!--");
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .{ .comment = .end });
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), "-->");
    
    try std.testing.expectEqualStrings(tokenizer.buffer[text_start..current.start], " - ");
    
    
    
    current = tokenizer.next(); text_start = current.end;
    try std.testing.expectEqual(current.id, .{ .comment = .beg });
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), "<!--");
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .{ .comment = .end });
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), "-->");
    
    try std.testing.expectEqualStrings(tokenizer.buffer[text_start..current.start], "");
    
    
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .{ .element_close = .beg });
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), "</");
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .element_identifier);
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), "content");
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .{ .element_close = .end });
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), ">");
    
    
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .eof);
    
}

test "With Processing Instructions" {
    var tokenizer = Tokenizer.init(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<content>
        \\</content>
    );
    var current = Tokenizer.Token.init();
    //var text_start: usize = undefined;
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .{ .processing_instruction = .beg });
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), "<?");
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .processing_instruction_target);
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), "xml");
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .processing_instructions_text);
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), "version=\"1.0\" encoding=\"UTF-8\"");
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .{ .processing_instruction = .end });
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), "?>");
    
    
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .{ .element_open = .beg });
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), "<");
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .element_identifier);
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), "content");
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .{ .element_open = .end_parent });
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), ">");
    
    
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .{ .element_close = .beg });
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), "</");
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .element_identifier);
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), "content");
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .{ .element_close = .end });
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), ">");
    
    
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .eof);
    
}

test "Namespace Tokenizing" {
    var tokenizer = Tokenizer.init(
        \\<namespace:content>
        \\</namespace:content>
    );
    var current = Tokenizer.Token.init();
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .{ .element_open = .beg });
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), "<");
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .element_namespace);
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), "namespace");
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .element_identifier);
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), "content");
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .{ .element_open = .end_parent });
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), ">");
    
    
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .{ .element_close = .beg });
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), "</");
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .element_namespace);
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), "namespace");
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .element_identifier);
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), "content");
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .{ .element_close = .end });
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), ">");
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .eof);
    
}

test "CDATA Section" {
    var tokenizer = Tokenizer.init(
        \\<content >
        \\<![CDATA[]]>
        \\<![CDATA[ &><; ]]>
        \\</content >
        \\
    );
    var current = Tokenizer.Token.init();
    var text_start: usize = undefined;
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .{ .element_open = .beg });
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), "<");
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .element_identifier);
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), "content");
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .{ .element_open = .end_parent });
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), ">");
    
    current = tokenizer.next(); text_start = current.end;
    try std.testing.expectEqual(current.id, .{ .char_data = .beg });
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), "<![CDATA[");
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .{ .char_data = .end });
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), "]]>");
    
    try std.testing.expectEqualStrings(tokenizer.buffer[text_start..current.start], "");
    
    
    
    current = tokenizer.next(); text_start = current.end;
    try std.testing.expectEqual(current.id, .{ .char_data = .beg });
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), "<![CDATA[");
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .{ .char_data = .end });
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), "]]>");
    
    try std.testing.expectEqualStrings(tokenizer.buffer[text_start..current.start], " &><; ");
    
    
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .{ .element_close = .beg });
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), "</");
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .element_identifier);
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), "content");
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .{ .element_close = .end });
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), ">");
    
    
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .eof);
    
}

test "Invalid CDATA Ending" {
    var tokenizer = Tokenizer.init(
        \\<![CDATA[]]>
    );
    var current = Tokenizer.Token.init();
    var text_start: usize = undefined;
    
    current = tokenizer.next(); text_start = current.end;
    try std.testing.expectEqual(current.id, .{ .char_data = .beg });
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), "<![CDATA[");
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .{ .char_data = .end });
    try std.testing.expectEqualStrings(tokenizer.sliceFrom(current), "]]>");
    
    try std.testing.expectEqualStrings(tokenizer.buffer[text_start..current.start], "");
    
    current = tokenizer.next();
    try std.testing.expectEqual(current.id, .invalid);
    
}
