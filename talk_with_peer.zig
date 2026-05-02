const std = @import("std");
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const bt = std.bittorrent;
const net = std.Io.net;
const builtin = @import("builtin");

const metadata_piece_size = 16384;

var reader_buf: [1024]u8 = undefined;
var writer_buf: [1024]u8 = undefined;

const PeerState = struct {
    ext_metadata_id: u8,
    metadata_size: usize,
    have_bitfield: ?[]u8 = null,

    pub fn deinit(ps: *PeerState, gpa: Allocator) void {
        if (ps.have_bitfield) |have_bitfield|
            gpa.free(have_bitfield);

        ps.* = undefined;
    }
};

pub fn main(init: std.process.Init) !void {
    var arg_iter = try init.minimal.args.iterateAllocator(init.gpa);
    std.debug.assert(arg_iter.skip());
    const peer_ip4_str = arg_iter.next() orelse return std.log.err("expected peer ipv4 address", .{});
    const peer_port_str = arg_iter.next() orelse return std.log.err("expected peer port", .{});
    const info_hash_hex = arg_iter.next() orelse return std.log.err("expected info hash", .{});

    if (info_hash_hex.len != 40) {
        return std.log.err("info hash must be exactly 20 bytes long", .{});
    }
    var info_hash: [20]u8 = undefined;
    for (0..20) |i| {
        info_hash[i] = std.fmt.parseUnsigned(u8, info_hash_hex[i * 2 .. i * 2 + 2], 16) catch {
            return std.log.err("invalid info hash", .{});
        };
    }

    const peer_port = std.fmt.parseUnsigned(u16, peer_port_str, 10) catch |err|
        return std.log.err("invalid peer port ({t})", .{err});

    const peer_ip = net.IpAddress.parseIp4(peer_ip4_str, peer_port) catch |err|
        return std.log.err("invalid peer ipv4 address ({t})", .{err});

    std.log.debug("peer ip: {f}", .{peer_ip});

    const peer_id = make: {
        var peer_id_buf: [6]u8 = undefined;
        init.io.random(&peer_id_buf);
        var peer_id_str: [20]u8 = "-zl0000-".* ++ @as([12]u8, @splat(undefined));

        var peer_id_part: Writer = .fixed(peer_id_str[8..]);
        peer_id_part.print("{x}", .{&peer_id_buf}) catch unreachable;

        break :make peer_id_str;
    };

    std.log.debug("peer id: '{f}'", .{std.zig.fmtString(&peer_id)});

    const stream = peer_ip.connect(init.io, .{ .mode = .stream, .protocol = .tcp }) catch |err|
        return std.log.err("unable to connect to peer ({t})", .{err});
    defer stream.close(init.io);

    var reader = stream.reader(init.io, &reader_buf);
    var writer = stream.writer(init.io, &writer_buf);

    try writer.interface.writeAll("\x13BitTorrent protocol\x00\x00\x00\x00\x00\x10\x00\x00");
    try writer.interface.writeAll(&info_hash);
    try writer.interface.writeAll(&peer_id);
    try writeExtHandshake(&writer.interface, init.gpa, .{
        .your_ip = .{ .ip4 = peer_ip.ip4.bytes },
    });
    try writer.interface.flush();

    var peer_state: PeerState = find: {
        const peer_handshake_length = try reader.interface.takeByte();
        if (peer_handshake_length != 19) {
            return std.log.err("invalid handshake length ({d})", .{peer_handshake_length});
        }
        const peer_handshake_str = try reader.interface.take(19);
        if (!std.mem.eql(u8, peer_handshake_str, "BitTorrent protocol")) {
            return std.log.err("invalid handshake ('{f}')", .{std.zig.fmtString(peer_handshake_str)});
        }

        const peer_extension_bytes = try reader.interface.take(8);
        if (peer_extension_bytes[5] & 0x10 == 0) {
            return std.log.err("peer doesn't support extension protocol", .{});
        }

        const peer_info_hash = try reader.interface.take(20);
        if (!std.mem.eql(u8, peer_info_hash, &info_hash)) {
            return std.log.err("peer sent non-matching info hash ({x})", .{peer_info_hash});
        }

        const peer_peer_id = try reader.interface.take(20);
        std.log.info("other peer id: '{f}'", .{std.zig.fmtString(peer_peer_id)});

        const peer_ext_handshake_length = try reader.interface.takeInt(u32, .big);
        // message id (1) + ext message id (1) + "d1:mdee".len (7) = 9
        if (peer_ext_handshake_length < 9) {
            return std.log.err("invalid ext handshake length ({d})", .{peer_ext_handshake_length});
        }

        var limited_reader_buf: [128]u8 = undefined;
        var limited_reader = reader.interface.limited(.limited(peer_ext_handshake_length), &limited_reader_buf);

        const peer_ext_handshake_message_id = try limited_reader.interface.takeByte();
        if (peer_ext_handshake_message_id != 0x14) {
            return std.log.err("peer's first message is not an ext message (got {d})", .{peer_ext_handshake_message_id});
        }
        const peer_ext_handshake_ext_message_id = try limited_reader.interface.takeByte();
        if (peer_ext_handshake_ext_message_id != 0x00) {
            return std.log.err("peer's first message is not an ext handshake (got {d})", .{peer_ext_handshake_ext_message_id});
        }

        var parsed_arena: std.heap.ArenaAllocator = .init(init.gpa);
        defer parsed_arena.deinit();
        const parsed_ext_handshake = bt.bencode.parseFromReaderLeaky(parsed_arena.allocator(), &limited_reader.interface) catch |err| {
            return std.log.err("peer sent invalid bencoding ({t})", .{err});
        };

        if (parsed_ext_handshake != .dictionary)
            return std.log.err("peer ext handshake is not a dictionary", .{});
        const peer_m = parsed_ext_handshake.dictionary.get("m");
        if (peer_m == null)
            return std.log.err("peer ext handshake does not contain key 'm'", .{});
        if (peer_m.? != .dictionary)
            return std.log.err("peer ext handshake key 'm' is not a dictionary", .{});
        const peer_m_ut_metadata = peer_m.?.dictionary.get("ut_metadata");
        if (peer_m_ut_metadata == null)
            return std.log.err("peer does not support 'ut_metadata'", .{});
        if (peer_m_ut_metadata.? != .integer)
            return std.log.err("peer's supported extension 'ut_metadata' is not an integer", .{});
        const ext_metadata_id = std.fmt.parseUnsigned(u8, peer_m_ut_metadata.?.integer, 10) catch |err| {
            return std.log.err("peer's supported extension 'ut_metadata' contains invalid integer ({t})", .{err});
        };

        const peer_metadata_size = parsed_ext_handshake.dictionary.get("metadata_size");
        if (peer_metadata_size == null)
            return std.log.err("peer didn't include the metadata size", .{});
        if (peer_metadata_size.? != .integer)
            return std.log.err("peer's metadata size is not an integer", .{});
        const metadata_size = std.fmt.parseUnsigned(usize, peer_metadata_size.?.integer, 10) catch |err|
            return std.log.err("peer's metadata size is invalid ({t})", .{err});
        if (metadata_size == 0)
            return std.log.err("peer's metadata size is 0", .{});

        std.log.info("metadata size: {d} ({0Bi:.2}) ({d} pieces)", .{ metadata_size, (metadata_size - 1) / metadata_piece_size + 1 });

        const peer_v = parsed_ext_handshake.dictionary.get("v");
        if (peer_v != null) {
            if (peer_v.? != .string)
                return std.log.err("peer version is not a string", .{});
            std.log.info("peer version: '{f}'", .{std.zig.fmtString(peer_v.?.string)});
        }

        break :find .{
            .ext_metadata_id = ext_metadata_id,
            .metadata_size = metadata_size,
        };
    };
    defer peer_state.deinit(init.gpa);

    const num_metadata_pieces: usize = (peer_state.metadata_size - 1) / metadata_piece_size + 1;
    var metadata_have_bitset: std.bit_set.DynamicBitSetUnmanaged = try .initEmpty(init.gpa, num_metadata_pieces);
    defer metadata_have_bitset.deinit(init.gpa);
    var has_all_metadata: bool = false;
    const metadata_str = try init.gpa.alloc(u8, peer_state.metadata_size);
    defer init.gpa.free(metadata_str);

    // Request each piece

    // "d8:msg_typei0e5:piecei0ee".len (smallest case) = 25
    var request_allocating: Writer.Allocating = try .initCapacity(init.gpa, 25);
    defer request_allocating.deinit();
    for (0..num_metadata_pieces) |i| {
        const str: bt.bencode.Stringify = .{ .writer = &request_allocating.writer };
        try str.beginDictionary();
        try str.writeString("msg_type");
        try str.writeInteger(0);
        try str.writeString("piece");
        try str.writeInteger(i);
        try str.endContainer();

        const written = request_allocating.written();
        try writer.interface.writeInt(u32, 1 + 1 + @as(u32, @intCast(written.len)), .big);
        try writer.interface.writeAll(&.{ 0x14, peer_state.ext_metadata_id });
        try writer.interface.writeAll(written);
        _ = request_allocating.writer.consumeAll();
    }
    try writer.interface.flush();

    while (true) {
        const message_length = try reader.interface.takeInt(u32, .big);

        var limited_reader_buf: [128]u8 = undefined;
        var limited_reader = reader.interface.limited(.limited(message_length), &limited_reader_buf);

        if (message_length == 0)
            continue; // Keepalive

        const message_id = try limited_reader.interface.takeByte();

        switch (message_id) {
            // Choke
            0x00 => {
                std.log.info("choked", .{});
            },
            // Unchoke
            0x01 => {
                std.log.info("unchoked", .{});
            },
            // Have
            0x04 => {
                if (message_length != 5)
                    return std.log.err("have message has incorrect size", .{});
                
                if (peer_state.have_bitfield == null)
                    return std.log.err("got have message but we never got a bitfield message", .{});

                const have = try limited_reader.interface.takeInt(u32, .big);
                std.log.info("peer have: 0x{x}", .{have});

                if (have / 8 >= peer_state.have_bitfield.?.len)
                    return std.log.err("have index is out of bounds", .{});

                peer_state.have_bitfield.?[have / 8] = @as(u8, 0b10000000) >> @intCast(have % 8);
            },
            // Bitfield
            0x05 => {
                if (message_length == 1)
                    return std.log.err("bitfield message is too short", .{});

                std.log.info("bitfield (length: {d})", .{message_length - 1});

                peer_state.have_bitfield = try init.gpa.alloc(u8, message_length - 1);
                try limited_reader.interface.readSliceAll(peer_state.have_bitfield.?);
            },
            // Extension
            0x14 => {
                if (message_length == 1)
                    return std.log.err("extension message is too short", .{});

                const ext_message_id = try limited_reader.interface.takeByte();
                
                // These IDs aren't in the spec - they're configured by us when we specify the extension 'm' dictionary in the handshake.
                switch (ext_message_id) {
                    // ut_metadata
                    0x01 => {
                        if (message_length == 2)
                            return std.log.err("ut_metadata message is too short", .{});

                        var parsed_arena: std.heap.ArenaAllocator = .init(init.gpa);
                        defer parsed_arena.deinit();
                        const parsed = bt.bencode.parseFromReaderLeaky(parsed_arena.allocator(), &limited_reader.interface) catch |err| {
                            return std.log.err("peer sent invalid bencoding ({t})", .{err});
                        };

                        if (parsed != .dictionary)
                            return std.log.err("ut_metadata message is not a dictionary", .{});

                        const msg_type = parsed.dictionary.get("msg_type");
                        if (msg_type == null)
                            return std.log.err("ut_metadata message is missing 'msg_type'", .{});
                        if (msg_type.? != .integer)
                            return std.log.err("ut_metadata message's 'msg_type' is not an integer", .{});

                        const msg_type_int = std.fmt.parseUnsigned(u8, msg_type.?.integer, 10) catch |err|
                            return std.log.err("ut_metadata 'msg_type' is an invalid integer ({t})", .{err});

                        switch (msg_type_int) {
                            0 => {
                                // We always respond with a reject message because we're awesomesauce like that

                                const piece = parsed.dictionary.get("piece");
                                if (piece == null)
                                    return std.log.err("ut_metadata message is missing 'piece'", .{});
                                if (piece.? != .integer)
                                    return std.log.err("ut_metadata message's 'piece' is not an integer", .{});
                                const piece_int = std.fmt.parseUnsigned(usize, piece.?.integer, 10) catch |err|
                                    return std.log.err("ut_metadata 'piece' is an invalid integer ({t})", .{err});
                                
                                // "d8:msg_typei2e5:piecei0ee".len (smallest case) = 25
                                var allocating: Writer.Allocating = try .initCapacity(init.gpa, 25);
                                defer allocating.deinit();

                                const str: bt.bencode.Stringify = .{ .writer = &allocating.writer };
                                try str.beginDictionary();
                                try str.writeString("msg_type");
                                try str.writeInteger(2);
                                try str.writeString("piece");
                                try str.writeInteger(piece_int);
                                try str.endContainer();

                                const written = allocating.written();
                                try writer.interface.writeInt(u32, 1 + 1 + @as(u32, @intCast(written.len)), .big);
                                try writer.interface.writeAll(&.{ 0x14, peer_state.ext_metadata_id });
                                try writer.interface.writeAll(written);
                            },
                            1 => {
                                const piece = parsed.dictionary.get("piece");
                                if (piece == null)
                                    return std.log.err("ut_metadata message is missing 'piece'", .{});
                                if (piece.? != .integer)
                                    return std.log.err("ut_metadata message's 'piece' is not an integer", .{});
                                const piece_int = std.fmt.parseUnsigned(usize, piece.?.integer, 10) catch |err|
                                    return std.log.err("ut_metadata 'piece' is an invalid integer ({t})", .{err});

                                if (piece_int >= num_metadata_pieces)
                                    return std.log.err("ut_metadata 'piece' is too big ({d})", .{piece_int});

                                const total_size = parsed.dictionary.get("total_size");
                                if (total_size == null)
                                    return std.log.err("ut_metadata message is missing 'total_size'", .{});
                                if (total_size.? != .integer)
                                    return std.log.err("ut_metadata message's 'total_size' is not an integer", .{});
                                const total_size_int = std.fmt.parseUnsigned(usize, total_size.?.integer, 10) catch |err|
                                    return std.log.err("ut_metadata 'total_size' is an invalid integer ({t})", .{err});
                                if (total_size_int != peer_state.metadata_size)
                                    return std.log.err("ut_metadata 'total_size' ({d}) doesn't match up with advertised metadata size ({d})", .{total_size_int, peer_state.metadata_size});

                                const piece_size = @intFromEnum(limited_reader.remaining) + limited_reader_buf.len - limited_reader.interface.seek;

                                std.log.info("metadata piece 0x{x} with size {d} ({1Bi:.2}) (message length {d})", .{piece_int, piece_size, message_length});

                                if (piece_size > metadata_piece_size)
                                    return std.log.err("ut_metadata piece size is greater than the largest metadata piece size ({d})", .{metadata_piece_size})
                                else if (piece_size < metadata_piece_size and peer_state.metadata_size % metadata_piece_size != piece_size)
                                    return std.log.err("ut_metadata piece size of the last piece is an invalid integer ({d})", .{piece_size});

                                try limited_reader.interface.readSliceAll(metadata_str[piece_int * metadata_piece_size..][0..piece_size]);

                                metadata_have_bitset.set(piece_int);
                                const all_set = determine: {
                                    var iter = metadata_have_bitset.iterator(.{.kind = .unset, .direction = .reverse});
                                    break :determine iter.next() == null;
                                };

                                if (!all_set)
                                    continue;

                                has_all_metadata = true;
                                std.log.info("metadata complete!", .{});

                                var resulting_hash: [20]u8 = undefined;
                                std.crypto.hash.Sha1.hash(metadata_str, &resulting_hash, .{});

                                if (!std.mem.eql(u8, &info_hash, &resulting_hash))
                                    return std.log.err("resulting metadata hash '{x}' is not equal to the info hash", .{resulting_hash});
                                
                                var metadata_arena: std.heap.ArenaAllocator = .init(init.gpa);
                                defer metadata_arena.deinit();
                                const parsed_metadata = bt.bencode.parseFromSliceLeaky(metadata_arena.allocator(), metadata_str) catch |err|
                                    return std.log.err("invalid metadata ({t})", .{err});

                                if (parsed_metadata != .dictionary)
                                    return std.log.err("metadata isn't a dictionary", .{});

                                const metadata_name = parsed_metadata.dictionary.get("name");
                                if (metadata_name) |actually_metadata_name| {
                                    if (actually_metadata_name != .string)
                                        return std.log.err("metadata name isn't a string", .{});
                                    std.log.info("name: '{f}'", .{std.zig.fmtString(actually_metadata_name.string)});
                                }
                            },
                            else => return std.log.err("unknown ut_metadata 'msg_type' {d}", .{msg_type_int}),
                        }
                    },
                    else => {
                        return std.log.err("unknown ext message id: 0x{x:02}", .{ext_message_id});
                    },
                }
            },
            else => {
                return std.log.err("unknown message id: 0x{x:02}", .{message_id});
            },
        }
    }
}

const ExtHandshakeOptions = struct {
    your_ip: ?YourIp = null,

    const YourIp = union(enum) {
        ip4: [4]u8,
        ip6: [6]u8,
    };
};

fn writeExtHandshake(writer: *Writer, gpa: Allocator, options: ExtHandshakeOptions) (Allocator.Error || Writer.Error)!void {
    var ext_allocating: Writer.Allocating = try .initCapacity(gpa, 128);
    defer ext_allocating.deinit();
    const ext_str = make: {
        const ext_str: bt.bencode.Stringify = .{ .writer = &ext_allocating.writer };
        try ext_str.beginDictionary();

        try ext_str.writeString("m");
        try ext_str.beginDictionary();
        try ext_str.writeString("ut_metadata");
        try ext_str.writeInteger(1);
        try ext_str.endContainer();

        try ext_str.writeString("reqq");
        try ext_str.writeInteger(64);

        try ext_str.writeString("v");
        try ext_str.writeString("Zig/" ++ builtin.zig_version_string);

        if (options.your_ip) |your_ip| {
            try ext_str.writeString("yourip");
            switch (your_ip) {
                inline else => |bytes| {
                    try ext_str.beginString(bytes.len);
                    try ext_allocating.writer.writeAll(&bytes);
                },
            }
        }

        try ext_str.endContainer();
        break :make ext_allocating.written();
    };

    try writer.writeInt(u32, 2 + @as(u32, @intCast(ext_str.len)), .big);
    try writer.writeAll(&.{ 0x14, 0x00 });
    try writer.writeAll(ext_str);
}
