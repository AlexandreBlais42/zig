//! Tools for parsing, validating, or emitting a BitTorrent bencoding.
//!
//! See [the BitTorrent specification](https://www.bittorrent.org/beps/bep_0003.html#bencoding) for more information.

const std = @import("../std.zig");
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

pub const SyntaxError = error{
    /// The provided bencoding is malformed.
    SyntaxError,
};

/// Bencode tokenizer
pub const Scanner = struct {
    reader: *Reader,

    pub const Token = union(Tag) {
        list_start,
        dictionary_start,
        /// Ends the latest container (list or dictionary).
        end_container,

        /// User must advance the stream [contained] bytes forward before calling `next` again.
        /// Strings whose lengths exceed `usize` are invalid in this implementation.
        string_start: usize,
        /// User must advance the stream until after an `e` character is found before calling `next` again.
        integer_start,

        pub const Tag = enum {
            list_start,
            dictionary_start,
            end_container,
            string_start,
            integer_start,
        };
    };

    pub const NextError = SyntaxError || Reader.ShortError;

    /// Peeks the next token type from the stream. Asserts that the reader's buffer length is nonzero.
    pub fn peekTag(scanner: *const Scanner) NextError!Token.Tag {
        return switch (scanner.reader.peekByte() catch |err| switch (err) {
            error.EndOfStream => return error.SyntaxError,
            else => |e| return e,
        }) {
            'l' => return .list_start,
            'd' => return .dictionary_start,
            'e' => return .end_container,
            '0'...'9' => return .string_start,
            'i' => return .integer_start,
            else => return error.SyntaxError,
        };
    }

    /// Returns the next token of the stream. Asserts that the reader's buffer length is nonzero.
    ///
    /// When the reader reaches the end, this function returns a `error.SyntaxError`.
    /// That is because the user is expected to track the nesting level and stop calling `next` when the bencoding is complete.
    /// If the bencoding is cut off before it is complete, that is a syntax error.
    pub fn next(scanner: *const Scanner) NextError!Token {
        return switch (try scanner.peekTag()) {
            // For strings, we must parse the length before we can return the token.
            .string_start => {
                // We just peeked the byte, so it must be buffered.
                const d = scanner.reader.takeByte() catch unreachable;

                const max_usize_length = comptime std.math.log10(std.math.maxInt(usize)) + 1;
                var num_buffer: [max_usize_length]u8 = undefined;

                var num_writer: Writer = .fixed(&num_buffer);
                num_writer.writeByte(d) catch unreachable;

                _ = scanner.reader.streamDelimiter(&num_writer, ':') catch |err| switch (err) {
                    error.EndOfStream,
                    error.WriteFailed,
                    => return error.SyntaxError,
                    else => |e| return e,
                };

                scanner.reader.toss(1);

                return .{ .string_start = std.fmt.parseUnsigned(usize, num_writer.buffered(), 10) catch return error.SyntaxError };
            },
            inline else => |tag| {
                scanner.reader.toss(1);
                return tag;
            },
        };
    }

    test next {
        var reader: Reader = .fixed("d3:cow3:moo4:spam4:eggse");
        const scanner: Scanner = .{ .reader = &reader };
        try std.testing.expectEqual(Token.dictionary_start, scanner.next());
        try std.testing.expectEqual(Token{ .string_start = 3 }, scanner.next());
        reader.toss(3);
        try std.testing.expectEqual(Token{ .string_start = 3 }, scanner.next());
        reader.toss(3);
        try std.testing.expectEqual(Token{ .string_start = 4 }, scanner.next());
        reader.toss(4);
        try std.testing.expectEqual(Token{ .string_start = 4 }, scanner.next());
        reader.toss(4);
        try std.testing.expectEqual(Token.end_container, scanner.next());
        try std.testing.expectError(error.SyntaxError, scanner.next());
        try std.testing.expectError(error.SyntaxError, scanner.next());

        reader = .fixed("d4:spaml1:a1:bee");
        try std.testing.expectEqual(Token.dictionary_start, scanner.next());
        try std.testing.expectEqual(Token{ .string_start = 4 }, scanner.next());
        reader.toss(4);
        try std.testing.expectEqual(Token.list_start, scanner.next());
        try std.testing.expectEqual(Token{ .string_start = 1 }, scanner.next());
        reader.toss(1);
        try std.testing.expectEqual(Token{ .string_start = 1 }, scanner.next());
        reader.toss(1);
        try std.testing.expectEqual(Token.end_container, scanner.next());
        try std.testing.expectEqual(Token.end_container, scanner.next());
        try std.testing.expectError(error.SyntaxError, scanner.next());

        reader = .fixed("i123e4:abcd");
        try std.testing.expectEqual(Token.integer_start, scanner.next());
        _ = try reader.discardDelimiterInclusive('e');
        try std.testing.expectEqual(Token{ .string_start = 4 }, scanner.next());
        reader.toss(4);
        try std.testing.expectError(error.SyntaxError, scanner.next());

        // Errors

        // Stream ended
        reader = .fixed("");
        try std.testing.expectError(error.SyntaxError, scanner.next());

        // Missing `:` after string length
        reader = .fixed("123");
        try std.testing.expectError(error.SyntaxError, scanner.next());

        // Invalid character when parsing string length
        reader = .fixed("12#3:");
        try std.testing.expectError(error.SyntaxError, scanner.next());

        // String length that won't fit in a `usize`
        reader = .fixed(std.fmt.comptimePrint("{d}:", .{std.math.maxInt(usize) + 1}));
        try std.testing.expectError(error.SyntaxError, scanner.next());

        // String length with too many digits
        reader = .fixed(std.fmt.comptimePrint("{d}0:", .{std.math.maxInt(usize)}));
        try std.testing.expectError(error.SyntaxError, scanner.next());
    }

    /// Skip an entire bencoded value in a stream.
    ///
    /// This function does not validate some properties of a bencoding, namely:
    /// - It doesn't care if integers are invalid.
    /// - It doesn't care if dictionary keys are not sorted lexicographically.
    /// 
    /// Use `validate` to check if a bencoding is valid.
    ///
    /// If the reader is at the end, or reaches the end while the value is being skipped,
    /// this function will return a `error.SyntaxError`.
    pub fn skipValue(scanner: *const Scanner) NextError!void {
        var nesting_depth: usize = 0;
        while (true) {
            switch (try scanner.next()) {
                .dictionary_start,
                .list_start,
                => {
                    nesting_depth, const overflow = @addWithOverflow(nesting_depth, 1);

                    // Bencodings deeper than `usize` are considered a syntax error.

                    if (overflow == 1)
                        return error.SyntaxError;
                },
                .end_container => {
                    if (nesting_depth == 0)
                        return error.SyntaxError;

                    nesting_depth -= 1;
                },

                .string_start => |length| {
                    scanner.reader.discardAll(length) catch |err| switch (err) {
                        error.EndOfStream => return error.SyntaxError,
                        else => |e| return e,
                    };
                },
                .integer_start => {
                    _ = scanner.reader.discardDelimiterInclusive('e') catch |err| switch (err) {
                        error.EndOfStream => return error.SyntaxError,
                        else => |e| return e,
                    };
                },
            }

            // If we encountered a dictionary or a list, then it means that we nested further in.
            // We have to wait for that container to end.
            // Once it ends, the nesting depth is decremented.

            // If we haven't - there we go. One value skipped.

            if (nesting_depth == 0)
                return;
        }
    }

    test skipValue {
        var reader: Reader = .fixed("d3:cow3:moo4:spam4:eggseli0ei1ei2eei1234e12:blahblahblah");
        //                           \-----------------------\----------\-----\--------------
        const scanner: Scanner = .{ .reader = &reader };
        try std.testing.expectEqual(0, reader.seek);
        try scanner.skipValue();
        try std.testing.expectEqual(24, reader.seek);
        try scanner.skipValue();
        try std.testing.expectEqual(35, reader.seek);
        try scanner.skipValue();
        try std.testing.expectEqual(41, reader.seek);
        try scanner.skipValue();
        try std.testing.expectEqual(56, reader.seek);
        try std.testing.expectError(error.SyntaxError, scanner.skipValue());
    }
};

/// Helpers to writer Bencode data to a stream.
///
/// To emit valid bencodings, follow this grammar:
/// ```
/// <once> = <value>
/// <value> =
///   | <list>
///   | <dictionary>
///   | <integer>
///   | <string>
/// <list> = beginList ( <value> )* endContainer
/// <dictionary> = beginDictionary ( <string> <value> )* endContainer
/// <integer> =
///   | writeInteger
///   | writeIntegerString
///   | beginInteger ( writer.writeAll )+ endContainer
/// <string> =
///   | writeString
///   | beginString ( writer.writeAll )*
/// ```
pub const Stringify = struct {
    writer: *Writer,

    pub fn beginList(stringify: Stringify) Writer.Error!void {
        try stringify.writer.writeByte('l');
    }

    pub fn beginDictionary(stringify: Stringify) Writer.Error!void {
        try stringify.writer.writeByte('d');
    }

    pub fn endContainer(stringify: Stringify) Writer.Error!void {
        try stringify.writer.writeByte('e');
    }

    pub fn writeInteger(stringify: Stringify, value: anytype) Writer.Error!void {
        if (@TypeOf(value) == comptime_int) {
            try stringify.writer.writeAll(comptime std.fmt.comptimePrint("i{d}e", .{value}));
            return;
        }

        try stringify.writer.writeByte('i');
        try stringify.writer.printInt(value, 10, .lower, .{});
        try stringify.writer.writeByte('e');
    }

    pub fn writeIntegerString(stringify: Stringify, str: []const u8) Writer.Error!void {
        try stringify.writer.writeByte('i');
        try stringify.writer.writeAll(str);
        try stringify.writer.writeByte('e');
    }

    /// User must write the integer to the writer manually, then call `endContainer`.
    pub fn beginInteger(stringify: Stringify) Writer.Error!void {
        try stringify.writer.writeByte('i');
    }

    pub fn writeString(stringify: Stringify, str: []const u8) Writer.Error!void {
        try stringify.beginString(str.len);
        try stringify.writer.writeAll(str);
    }

    /// User must write the content of the string to the writer manually.
    /// Use this when a slice of the entire string is not available, such as when streaming from a `Reader`.
    pub fn beginString(stringify: Stringify, length: usize) Writer.Error!void {
        try stringify.writer.printInt(length, 10, .lower, .{});
        try stringify.writer.writeByte(':');
    }
};

test Stringify {
    const allocator = std.testing.allocator;
    var allocating: Writer.Allocating = .init(allocator);
    defer allocating.deinit();
    const stringify: Stringify = .{ .writer = &allocating.writer };

    try stringify.beginDictionary();
    try stringify.writeString("int1");
    try stringify.writeIntegerString("1234");
    try stringify.writeString("int2");
    try stringify.writeInteger(-1234);
    try stringify.writeString("int3");
    try stringify.writeInteger(0);
    try stringify.writeString("list");
    try stringify.beginList();
    try stringify.writeString("aaa");
    try stringify.writeString("bbb");
    try stringify.writeString("ccc");
    try stringify.endContainer();
    try stringify.writeString("rawstring");
    try stringify.beginString(8);
    try stringify.writer.writeAll("helloooo");
    try stringify.endContainer();

    const expected = "d4:int1i1234e4:int2i-1234e4:int3i0e4:listl3:aaa3:bbb3:ccce9:rawstring8:hellooooe";
    try std.testing.expectEqualStrings(expected, allocating.writer.buffered());
}

pub const Dictionary = std.StringArrayHashMapUnmanaged(Value);
pub const List = std.ArrayList(Value);
pub const Value = union(enum) {
    dictionary: Dictionary,
    list: List,
    string: []const u8,
    integer: []const u8,
};

const ParseStackItem = union(enum) {
    dictionary: struct {
        d: Dictionary,
        /// Used to verify that keys are in lexicographical order.
        last_key: ?[]const u8 = null,
        current_key: []const u8,
    },
    list: List,
};
const ParseStack = std.ArrayList(ParseStackItem);

pub const ParseFromSliceError = SyntaxError || Allocator.Error;

/// Parse a bencoding from a string. The returned strings point into `slice`.
///
/// This function leaks when it returns an error, and the returned value is not trivial to free.
/// It is recommended to use an `std.heap.ArenaAllocator`.
pub fn parseFromSliceLeaky(arena: Allocator, slice: []const u8) ParseFromSliceError!Value {
    var reader: Reader = .fixed(slice);
    const scanner: Scanner = .{ .reader = &reader };

    return innerParse(arena, scanner, false) catch |err| switch (err) {
        error.ReadFailed,
        => unreachable,
        error.StreamTooLong,
        error.EndOfStream,
        => return error.SyntaxError,
        else => |e| return e,
    };
}

pub const ParseFromReaderError = SyntaxError || Reader.Error || Allocator.Error;

/// Parse a bencoding from a reader. The returned strings are allocated.
///
/// This function leaks when it returns an error, and the returned value is not trivial to free.
/// It is recommended to use an `std.heap.ArenaAllocator`.
pub fn parseFromReaderLeaky(arena: Allocator, reader: *Reader) ParseFromReaderError!Value {
    const scanner: Scanner = .{ .reader = reader };

    return innerParse(arena, scanner, true) catch |err| switch (err) {
        error.StreamTooLong => unreachable,
        else => |e| return e,
    };
}

fn innerParse(arena: Allocator, scanner: Scanner, alloc_slices: bool) !Value {
    var stack: ParseStack = .empty;
    defer stack.deinit(arena);

    while (true) switch (try scanner.next()) {
        .list_start => try stack.append(arena, .{ .list = .empty }),
        .dictionary_start => {
            const first_key: []const u8 = switch (try scanner.next()) {
                .string_start => |length| if (alloc_slices)
                    try scanner.reader.readAlloc(arena, length)
                else
                    try scanner.reader.take(length),
                .end_container => return try handleCompleteValue(&stack, arena, .{ .dictionary = .empty }, scanner, alloc_slices) orelse continue,
                else => return error.SyntaxError,
            };

            try stack.append(arena, .{ .dictionary = .{ .d = .empty, .current_key = first_key } });
        },
        .end_container => {
            if (stack.items.len == 0 or stack.items[stack.items.len - 1] == .dictionary)
                return error.SyntaxError;

            return try handleCompleteValue(&stack, arena, .{ .list = stack.pop().?.list }, scanner, alloc_slices) orelse continue;
        },
        .string_start => |length| {
            const string = if (alloc_slices)
                    try scanner.reader.readAlloc(arena, length)
                else
                    try scanner.reader.take(length);

            return try handleCompleteValue(&stack, arena, .{ .string = string }, scanner, alloc_slices) orelse continue;
        },
        .integer_start => {
            const integer = if (alloc_slices) alloc: {
                var allocating: Writer.Allocating = .init(arena);
                _ = scanner.reader.streamDelimiter(&allocating.writer, 'e') catch |err| switch (err) {
                    error.WriteFailed => return error.OutOfMemory,
                    else => |e| return e,
                };
                try scanner.reader.discardAll(1);

                // Using toOwnedSlice here is extra work for not much benefit.
                //
                // Even if the allocated slice is bigger than what's written,
                // everything will be freed anyway (since we're expecting the user to pass an arena).

                break :alloc allocating.written();
            } else take: {
                const taken = try scanner.reader.takeDelimiterExclusive('e');
                try scanner.reader.discardAll(1);
                break :take taken;
            };

            // Validate the integer

            if (integer.len == 0)
                return error.SyntaxError;

            var sign = false;
            var leading_zero = false;
            for (integer, 0..) |c, i| switch (c) {
                '-' => {
                    if (i != 0) {
                        return error.SyntaxError;
                    }

                    sign = true;
                },
                '0' => {
                    if (leading_zero) {
                        return error.SyntaxError;
                    }

                    if (i == 0 or (sign and i == 1)) {
                        leading_zero = true;
                    }
                },
                '1'...'9' => continue,
                else => return error.SyntaxError,
            };

            return try handleCompleteValue(&stack, arena, .{ .integer = integer }, scanner, alloc_slices) orelse continue;
        },
    };
}

fn handleCompleteValue(stack: *ParseStack, arena: Allocator, value: Value, scanner: Scanner, alloc_slices: bool) !?Value {
    if (stack.items.len == 0) return value;

    var current_value = value;
    loop: while (true) switch (stack.items[stack.items.len - 1]) {
        .dictionary => {
            const info = &stack.items[stack.items.len - 1].dictionary;

            const gop = try info.d.getOrPut(arena, info.current_key);
            if (gop.found_existing)
                return error.SyntaxError;
            gop.value_ptr.* = current_value;

            // Find the next key of the dictionary, or end it.

            switch (try scanner.next()) {
                .string_start => |length| {
                    const current_key = if (alloc_slices)
                        try scanner.reader.readAlloc(arena, length)
                    else
                        try scanner.reader.take(length);

                    info.last_key = info.current_key;
                    info.current_key = current_key;

                    // Maintain that sequential keys are in lexicographical order.
                    if (info.last_key != null and std.mem.order(u8, info.current_key, info.last_key.?) != .gt)
                        return error.SyntaxError;

                    return null;
                },
                .end_container => {
                    current_value = .{ .dictionary = stack.pop().?.dictionary.d };

                    if (stack.items.len == 0)
                        return current_value;

                    continue :loop;
                },
                else => return error.SyntaxError,
            }

            unreachable;
        },
        .list => {
            const list = &stack.items[stack.items.len - 1].list;
            try list.append(arena, current_value);
            return null;
        },
    };
}

test parseFromSliceLeaky {
    const allocator = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();

    {
        const root = try parseFromSliceLeaky(arena_state.allocator(), "li-1234e2::3e");
        try std.testing.expectEqual(.list, std.meta.activeTag(root));
        try std.testing.expectEqual(2, root.list.items.len);
        try std.testing.expectEqual(.integer, std.meta.activeTag(root.list.items[0]));
        try std.testing.expectEqualStrings("-1234", root.list.items[0].integer);
        try std.testing.expectEqual(.string, std.meta.activeTag(root.list.items[1]));
        try std.testing.expectEqualStrings(":3", root.list.items[1].string);
    }
    {
        const root = try parseFromSliceLeaky(arena_state.allocator(), "d1:ai123e1:bi456ee");
        try std.testing.expectEqual(.dictionary, std.meta.activeTag(root));
        try std.testing.expectEqual(2, root.dictionary.entries.len);
        try std.testing.expect(root.dictionary.get("a") != null);
        try std.testing.expectEqual(.integer, std.meta.activeTag(root.dictionary.get("a").?));
        try std.testing.expectEqualStrings("123", root.dictionary.get("a").?.integer);
        try std.testing.expect(root.dictionary.get("b") != null);
        try std.testing.expectEqual(.integer, std.meta.activeTag(root.dictionary.get("b").?));
        try std.testing.expectEqualStrings("456", root.dictionary.get("b").?.integer);
    }
    {
        const root = try parseFromSliceLeaky(arena_state.allocator(), "d4:int1i1234e4:int2i-1234e4:int3i0e4:listl3:aaa3:bbb3:ccce6:string8:hellooooe");
        try std.testing.expectEqual(.dictionary, std.meta.activeTag(root));
        try std.testing.expectEqual(5, root.dictionary.entries.len);
        try std.testing.expect(root.dictionary.get("int1") != null);
        try std.testing.expectEqual(.integer, std.meta.activeTag(root.dictionary.get("int1").?));
        try std.testing.expectEqualStrings("1234", root.dictionary.get("int1").?.integer);
        try std.testing.expect(root.dictionary.get("int2") != null);
        try std.testing.expectEqual(.integer, std.meta.activeTag(root.dictionary.get("int2").?));
        try std.testing.expectEqualStrings("-1234", root.dictionary.get("int2").?.integer);
        try std.testing.expect(root.dictionary.get("int3") != null);
        try std.testing.expectEqual(.integer, std.meta.activeTag(root.dictionary.get("int3").?));
        try std.testing.expectEqualStrings("0", root.dictionary.get("int3").?.integer);
        try std.testing.expect(root.dictionary.get("list") != null);
        try std.testing.expectEqual(.list, std.meta.activeTag(root.dictionary.get("list").?));
        try std.testing.expectEqual(3, root.dictionary.get("list").?.list.items.len);
        try std.testing.expectEqual(.string, std.meta.activeTag(root.dictionary.get("list").?.list.items[0]));
        try std.testing.expectEqualStrings("aaa", root.dictionary.get("list").?.list.items[0].string);
        try std.testing.expectEqual(.string, std.meta.activeTag(root.dictionary.get("list").?.list.items[1]));
        try std.testing.expectEqualStrings("bbb", root.dictionary.get("list").?.list.items[1].string);
        try std.testing.expectEqual(.string, std.meta.activeTag(root.dictionary.get("list").?.list.items[2]));
        try std.testing.expectEqualStrings("ccc", root.dictionary.get("list").?.list.items[2].string);
        try std.testing.expect(root.dictionary.get("string") != null);
        try std.testing.expectEqual(.string, std.meta.activeTag(root.dictionary.get("string").?));
        try std.testing.expectEqualStrings("helloooo", root.dictionary.get("string").?.string);
    }

    // Error cases

    // bad integer
    try std.testing.expectError(error.SyntaxError, parseFromSliceLeaky(arena_state.allocator(), "i123#e"));
    // bad integer
    try std.testing.expectError(error.SyntaxError, parseFromSliceLeaky(arena_state.allocator(), "i--123e"));
    // bad integer
    try std.testing.expectError(error.SyntaxError, parseFromSliceLeaky(arena_state.allocator(), "ie"));
    // .end_container without a container to end
    try std.testing.expectError(error.SyntaxError, parseFromSliceLeaky(arena_state.allocator(), "e"));
    // .end_container when a value is expected
    try std.testing.expectError(error.SyntaxError, parseFromSliceLeaky(arena_state.allocator(), "d1:aee"));
    // bad key
    try std.testing.expectError(error.SyntaxError, parseFromSliceLeaky(arena_state.allocator(), "di123ei1234ee"));
    // unterminated container
    try std.testing.expectError(error.SyntaxError, parseFromSliceLeaky(arena_state.allocator(), "d"));
    // unterminated integer
    try std.testing.expectError(error.SyntaxError, parseFromSliceLeaky(arena_state.allocator(), "i1234"));
}

pub const PathNode = union(enum) {
    key: []const u8,
    index: usize,
};

/// Traverse a bencoding using the `path` and return a substring.
///
/// Ideally the bencoding should be validated beforehand using `validate`.
/// This function doesn't eagerly check for syntax errors.
pub fn findSpan(bencoding: []const u8, path: []const PathNode) SyntaxError!?[]const u8 {
    var current = bencoding;
    path_iter: for (path) |node| {
        var reader: Reader = .fixed(current);
        const scanner: Scanner = .{ .reader = &reader };

        switch (node) {
            .key => {
                const value_type = scanner.next() catch |err| switch (err) {
                    error.ReadFailed => unreachable,
                    else => |e| return e,
                };

                if (value_type != .dictionary_start)
                    return null;

                while (true) {
                    const key_type = scanner.next() catch |err| switch (err) {
                        error.ReadFailed => unreachable,
                        else => |e| return e,
                    };

                    if (key_type == .end_container)
                        return null;

                    if (key_type != .string_start)
                        return error.SyntaxError;

                    const key_str = reader.take(key_type.string_start) catch |err| switch (err) {
                        error.ReadFailed => unreachable,
                        error.EndOfStream => return error.SyntaxError,
                    };

                    if (std.mem.eql(u8, key_str, node.key))
                        break;

                    scanner.skipValue() catch |err| switch (err) {
                        error.ReadFailed => unreachable,
                        else => |e| return e,
                    };
                }

                const start = reader.seek;
                scanner.skipValue() catch |err| switch (err) {
                    error.ReadFailed => unreachable,
                    else => |e| return e,
                };
                const end = reader.seek;

                current = current[start..end];
                continue :path_iter;
            },
            .index => {
                const value_type = scanner.next() catch |err| switch (err) {
                    error.ReadFailed => unreachable,
                    else => |e| return e,
                };

                if (value_type != .list_start)
                    return null;

                for (0..node.index + 1) |i| {
                    const item_tag = scanner.peekTag() catch |err| switch (err) {
                        error.ReadFailed => unreachable,
                        else => |e| return e,
                    };

                    if (item_tag == .end_container)
                        return null;

                    if (i == node.index)
                        break;

                    scanner.skipValue() catch |err| switch (err) {
                        error.ReadFailed => unreachable,
                        else => |e| return e,
                    };
                }

                const start = reader.seek;
                scanner.skipValue() catch |err| switch (err) {
                    error.ReadFailed => unreachable,
                    else => |e| return e,
                };
                const end = reader.seek;

                current = current[start..end];
                continue :path_iter;
            },
        }
    }
    return current;
}

test findSpan {
    var s: []const u8 = undefined;

    s = "i1234e";
    //   ^-----
    try std.testing.expectEqual(s[0..6], findSpan(s, &.{}));
    s = "li1234ei5678ee";
    //   ^      ^-----
    try std.testing.expectEqual(s[7..13], findSpan(s, &.{.{ .index = 1 }}));
    s = "d1:ai1234e1:bi5678ee";
    //   ^            ^-----
    try std.testing.expectEqual(s[13..19], findSpan(s, &.{.{ .key = "b" }}));
    s = "li1234ed1:ai0e1:bi1eei5678ee";
    //   ^                    ^-----
    try std.testing.expectEqual(s[21..27], findSpan(s, &.{.{ .index = 2 }}));
    s = "li1234ed3:abc7:string13:def7:string23:ghi7:string3ee";
    //   ^      ^                   ^--------
    try std.testing.expectEqual(s[27..36], findSpan(s, &.{ .{ .index = 1 }, .{ .key = "def" } }));

    s = "i1234e";
    try std.testing.expectEqual(null, findSpan(s, &.{.{ .key = "b" }}));
    s = "d1:ai1234ee";
    try std.testing.expectEqual(null, findSpan(s, &.{.{ .key = "b" }}));
    s = "li1234ei5678ee";
    try std.testing.expectEqual(null, findSpan(s, &.{.{ .key = "b" }}));
    s = "d1:ai1234e1:bli0ei1ei2eee";
    try std.testing.expectEqual(null, findSpan(s, &.{ .{ .key = "b" }, .{ .index = 3 } }));

    // Error cases

    // Non-string key
    s = "di123ei456e";
    try std.testing.expectError(error.SyntaxError, findSpan(s, &.{.{ .key = "b" }}));
    // Missing .end_container
    s = "li123ei567e";
    try std.testing.expectError(error.SyntaxError, findSpan(s, &.{.{ .index = 3 }}));
}

const ValidateStackItem = union(enum) {
    list,
    /// Last dictionary key, used for verifying that keys are ordered correctly.
    dictionary: ?[]const u8,
};

pub const ValidateError = SyntaxError || Allocator.Error;

/// Validates a bencoding. `gpa` is used only for internal state, which is freed before the function returns.
pub fn validate(gpa: Allocator, bencoding: []const u8) ValidateError!void {
    var stack: std.ArrayList(ValidateStackItem) = .empty;
    var expecting_key: bool = false;
    defer stack.deinit(gpa);

    var reader: Reader = .fixed(bencoding);
    const scanner: Scanner = .{ .reader = &reader };

    while (true) {
        switch (scanner.next() catch |err| switch (err) {
            error.ReadFailed => unreachable,
            error.SyntaxError => return error.SyntaxError,
        }) {
            .dictionary_start => {
                if (expecting_key) {
                    return error.SyntaxError;
                }

                try stack.append(gpa, .{ .dictionary = null });
                expecting_key = true;
            },
            .list_start => {
                if (expecting_key) {
                    return error.SyntaxError;
                }

                try stack.append(gpa, .list);
                expecting_key = false;
            },
            .end_container => {
                if (stack.items.len == 0) {
                    return error.SyntaxError;
                }

                if (stack.items[stack.items.len - 1] == .dictionary and !expecting_key)
                    return error.SyntaxError;

                _ = stack.pop();

                if (stack.items.len == 0)
                    return;

                expecting_key = stack.items[stack.items.len - 1] == .dictionary;
            },
            .string_start => |length| {
                if (expecting_key) {
                    const last_key = &stack.items[stack.items.len - 1].dictionary;

                    const key = reader.take(length) catch |err| switch (err) {
                        error.EndOfStream => return error.SyntaxError,
                        error.ReadFailed => unreachable,
                    };

                    if (last_key.* != null and std.mem.order(u8, key, last_key.*.?) != .gt)
                        return error.SyntaxError;

                    last_key.* = key;

                    expecting_key = false;
                    continue;
                }

                reader.discardAll(length) catch |err| switch (err) {
                    error.EndOfStream => return error.SyntaxError,
                    error.ReadFailed => unreachable,
                };

                if (stack.items.len == 0) {
                    return;
                }

                if (stack.items[stack.items.len - 1] == .dictionary) {
                    expecting_key = true;
                }
            },
            .integer_start => {
                if (expecting_key) {
                    return error.SyntaxError;
                }

                const integer = reader.takeDelimiterInclusive('e') catch |err| switch (err) {
                    error.EndOfStream,
                    error.StreamTooLong,
                    => return error.SyntaxError,
                    error.ReadFailed => unreachable,
                };

                if (integer.len - 1 == 0)
                    return error.SyntaxError;

                var sign = false;
                var leading_zero = false;
                for (integer[0 .. integer.len - 1], 0..) |c, i| switch (c) {
                    '-' => {
                        if (i != 0) {
                            return error.SyntaxError;
                        }

                        sign = true;
                    },
                    '0' => {
                        if (leading_zero) {
                            return error.SyntaxError;
                        }

                        if (i == 0 or (sign and i == 1)) {
                            leading_zero = true;
                        }
                    },
                    '1'...'9' => continue,
                    else => return error.SyntaxError,
                };

                if (stack.items.len == 0) {
                    return;
                }

                if (stack.items[stack.items.len - 1] == .dictionary) {
                    expecting_key = true;
                }
            },
        }
    }
}

test validate {
    const gpa = std.testing.allocator;

    try validate(gpa, "2:hi");
    try validate(gpa, "i1234e");
    try validate(gpa, "d1:ai1234e1:bli0ei1ei2eee");
    try validate(gpa, "li1234ed1:ai0e1:bi1eei5678ee");
    try validate(gpa, "li1234ed3:abc7:string13:def7:string23:ghi7:string3ee");
    try validate(gpa, "d4:int1i1234e4:int2i-1234e4:int3i0e4:listl3:aaa3:bbb3:ccce6:string8:hellooooe");

    // Error cases

    // bad integer
    try std.testing.expectError(error.SyntaxError, validate(gpa, "i123#e"));
    // bad integer
    try std.testing.expectError(error.SyntaxError, validate(gpa, "i--123e"));
    // bad integer
    try std.testing.expectError(error.SyntaxError, validate(gpa, "ie"));
    // .end_container without a container to end
    try std.testing.expectError(error.SyntaxError, validate(gpa, "e"));
    // .end_container when a value is expected
    try std.testing.expectError(error.SyntaxError, validate(gpa, "d1:aee"));
    // bad key
    try std.testing.expectError(error.SyntaxError, validate(gpa, "di123ei1234ee"));
    // unterminated container
    try std.testing.expectError(error.SyntaxError, validate(gpa, "d"));
    // unterminated integer
    try std.testing.expectError(error.SyntaxError, validate(gpa, "i1234"));
}

test {
    std.testing.refAllDecls(@This());
}
