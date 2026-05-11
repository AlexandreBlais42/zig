const builtin = @import("builtin");
const std = @import("std");
const bt = std.bittorrent;
const Io = std.Io;
const Uri = std.Uri;
const Stream = Io.net.Stream;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const Torrent = struct {
    info_hash: [20]u8,
    peer_id: [20]u8,

    downloaded: usize = 0,
    uploaded: usize = 0,
    left: usize = 0,

    mutex: Io.Mutex = .init,
    group: Io.Group = .init,
    peers: [128]?Peer = @splat(null),
    trackers: [16]?Tracker = @splat(null),

    pub fn deinit(torrent: *Torrent, allocator: std.mem.Allocator, io: Io) void {
        for (&torrent.trackers) |tracker|
            if (tracker != null) tracker.?.deinit(allocator);
        torrent.group.cancel(io);
        torrent.* = undefined;
    }

    pub fn addPeer(torrent: *Torrent, allocator: std.mem.Allocator, io: Io, addr: Io.net.IpAddress, maybe_id: ?[20]u8) !void {
        try torrent.mutex.lock(io);
        defer torrent.mutex.unlock(io);

        const adding_peer: Peer = .{
            .addr = addr,
            .maybe_id = maybe_id,
        };

        for (&torrent.peers) |peer| {
            if (peer != null and peer.?.eql(adding_peer)) {
                return;
            }
        }

        const ptr: *?Peer = find: {
            for (&torrent.peers) |*peer| {
                if (peer.* == null)
                    break :find peer;
            }
            return;
        };

        ptr.* = adding_peer;

        try torrent.group.concurrent(io, peerWorker, .{ allocator, io, torrent, ptr });
    }

    pub fn addTracker(torrent: *Torrent, allocator: std.mem.Allocator, io: Io, uri_str: []const u8) !void {
        try torrent.mutex.lock(io);
        defer torrent.mutex.unlock(io);

        const uri_str_hash = std.hash.Wyhash.hash(0, uri_str);
        for (&torrent.trackers) |tracker| {
            if (tracker != null and tracker.?.uri_str_hash == uri_str_hash) {
                std.log.debug("tried to add duplicate tracker: {s}", .{uri_str});
                return;
            }
        }

        const ptr: *?Tracker = find: {
            for (&torrent.trackers) |*tracker| {
                if (tracker.* == null)
                    break :find tracker;
            }
            return;
        };

        const uri = try Uri.parse(uri_str);

        const uri_str_dupe = try allocator.dupe(u8, uri_str);
        errdefer allocator.free(uri_str_dupe);

        ptr.* = .{
            .uri_str = uri_str_dupe,
            .uri_str_hash = uri_str_hash,
            .uri = uri,
        };

        try torrent.group.concurrent(io, trackerWorker, .{ allocator, io, torrent, ptr });
    }
};

const Peer = struct {
    addr: Io.net.IpAddress,
    /// If `null`, we don't know the peer's ID yet.
    maybe_id: ?[20]u8,

    pub fn eql(this: Peer, other: Peer) bool {
        if (this.addr.eql(&other.addr))
            return true;

        if (this.maybe_id != null and other.maybe_id != null and
            std.mem.eql(u8, &this.maybe_id.?, &other.maybe_id.?))
            return true;

        return false;
    }
};

const Tracker = struct {
    uri_str: []const u8,
    uri_str_hash: u64,
    uri: Uri,

    pub fn deinit(tracker: *const Tracker, allocator: std.mem.Allocator) void {
        allocator.free(tracker.uri_str);
    }
};

const MagnetParseResult = struct {
    btih_info_hash: [20]u8,
    acceptable_sources: []const []const u8,
    tracker_uris: []const []const u8,

    pub fn deinit(result: *MagnetParseResult, allocator: Allocator) void {
        allocator.free(result.acceptable_sources);
        allocator.free(result.tracker_uris);
        result.* = undefined;
    }
};

fn parseMagnetUri(allocator: Allocator, uri_str: []const u8) !MagnetParseResult {
    const uri = Uri.parse(uri_str) catch return error.UriSyntaxError;

    if (!std.mem.eql(u8, uri.scheme, "magnet"))
        return error.NotMagnetUri;

    if (uri.query == null)
        return error.NoQueryParams;

    var info_hash: ?[20]u8 = null;
    var acceptable_sources: ArrayList([]const u8) = .empty;
    errdefer acceptable_sources.deinit(allocator);
    var tracker_uris: ArrayList([]const u8) = .empty;
    errdefer tracker_uris.deinit(allocator);

    var query = uri.query.?.percent_encoded;
    while (if (query.len == 0) null else query[0 .. std.mem.findScalar(u8, query, '&') orelse query.len]) |param| : (query = query[@min(param.len + 1, query.len)..]) {
        const key = param[0 .. std.mem.findScalar(u8, param, '=') orelse param.len];
        const value = param[@min(key.len + 1, param.len)..];

        if (std.mem.eql(u8, key, "xt")) {
            const first_colon = std.mem.findScalar(u8, value, ':') orelse return error.ExactTopicSyntaxError;

            if (!std.mem.eql(u8, value[0..first_colon], "urn"))
                return error.ExactTopicNotUrn;

            const second_colon = std.mem.findScalar(u8, value[first_colon + 1 ..], ':') orelse return error.ExactTopicSyntaxError;

            const nid = value[first_colon + 1 ..][0..second_colon];
            const nss = value[first_colon + 1 ..][second_colon + 1 ..];

            if (std.mem.eql(u8, nid, "btih")) {
                if (nss.len != 40)
                    return error.InvalidInfoHash;

                var info_hash_buf: [20]u8 = undefined;
                _ = std.fmt.hexToBytes(&info_hash_buf, nss) catch return error.InvalidInfoHash;
                info_hash = info_hash_buf;
            }
        } else if (std.mem.eql(u8, key, "as")) {
            try acceptable_sources.append(allocator, value);
        } else if (std.mem.eql(u8, key, "tr")) {
            try tracker_uris.append(allocator, value);
        }
    }

    return .{
        .btih_info_hash = if (info_hash) |actual_info_hash| actual_info_hash else return error.NoInfoHash,
        .acceptable_sources = try acceptable_sources.toOwnedSlice(allocator),
        .tracker_uris = try tracker_uris.toOwnedSlice(allocator),
    };
}

fn generatePeerId(io: Io) [20]u8 {
    // Zig v0
    var peer_id: [20]u8 = "-Zg0000-".* ++ @as([12]u8, @splat(undefined));

    var id: [6]u8 = undefined;
    io.random(&id);
    const id_hex = std.fmt.bytesToHex(&id, .lower);
    @memcpy(peer_id[8..], &id_hex);

    return peer_id;
}

pub fn main(init: std.process.Init) !void {
    var arg_iter = try init.minimal.args.iterateAllocator(init.gpa);
    std.debug.assert(arg_iter.skip());
    const magnet_uri_str = arg_iter.next() orelse return std.log.err("expected magnet uri", .{});

    var parsed_magnet = try parseMagnetUri(init.arena.allocator(), magnet_uri_str);

    std.log.info("magnet info", .{});
    std.log.info("  info hash: {x}", .{&parsed_magnet.btih_info_hash});
    std.log.info("  acceptable sources ({d})", .{parsed_magnet.acceptable_sources.len});
    for (parsed_magnet.acceptable_sources) |source|
        std.log.info("   - {s}", .{source});
    std.log.info("  trackers ({d})", .{parsed_magnet.tracker_uris.len});
    for (parsed_magnet.tracker_uris) |tracker|
        std.log.info("   - {s}", .{tracker});

    const peer_id = generatePeerId(init.io);
    std.log.debug("generated peer id: '{s}'", .{peer_id});

    var torrent: Torrent = .{
        .info_hash = parsed_magnet.btih_info_hash,
        .peer_id = peer_id,
    };
    defer torrent.deinit(init.gpa, init.io);

    for (parsed_magnet.tracker_uris) |tracker|
        try torrent.addTracker(init.gpa, init.io, tracker);

    torrent.group.await(init.io) catch {};
}

fn trackerWorker(allocator: Allocator, io: Io, torrent: *Torrent, tracker_ptr: *?Tracker) Io.Cancelable!void {
    defer {
        torrent.mutex.lockUncancelable(io);
        defer torrent.mutex.unlock(io);
        tracker_ptr.* = null;
    }

    const tracker = &tracker_ptr.*.?;

    trackerWorkerInner(allocator, io, torrent, tracker) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.OutOfMemory => @panic("OOM"),
        error.ConcurrencyUnavailable => @panic("concurrency unavailable"),
        error.HttpError => std.log.err("HTTP error", .{}),
        error.ParseError => std.log.err("parse error", .{}),
    };
}

fn trackerWorkerInner(allocator: Allocator, io: Io, torrent: *Torrent, tracker: *Tracker) !void {
    var query_allocating: Io.Writer.Allocating = try .initCapacity(allocator, 64);
    defer query_allocating.deinit();
    var response_allocating: Io.Writer.Allocating = try .initCapacity(allocator, 1024);
    defer response_allocating.deinit();

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    query_allocating.writer.writeAll("info_hash=") catch return error.OutOfMemory;
    Uri.Component.percentEncode(&query_allocating.writer, &torrent.info_hash, isQueryParamChar) catch return error.OutOfMemory;
    query_allocating.writer.print("&peer_id={s}&port=6881&uploaded=0&downloaded=0&left=0&event=started&compact=1", .{&torrent.peer_id}) catch return error.OutOfMemory;

    tracker.uri.query = .{ .percent_encoded = query_allocating.written() };

    while (true) {
        _ = client.fetch(.{
            .location = .{ .uri = tracker.uri },
            .response_writer = &response_allocating.writer,
        }) catch return error.HttpError;

        const tracker_response = parseTrackerResponse(allocator, response_allocating.written()) catch |err| switch (err) {
            error.ParseError => {
                std.log.err("parse error: '{f}'", .{std.zig.fmtString(response_allocating.written())});
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpErrorReturnTrace(trace);
                }
                return error.ParseError;
            },
            else => |e| return e,
        };

        if (tracker_response == .failure) {
            std.log.err("{s} returned failure: '{f}'", .{ tracker.uri_str, std.zig.fmtString(tracker_response.failure) });
            return;
        }

        std.log.info("{s} returned {d} peers", .{ tracker.uri_str, tracker_response.success.peers.len });

        for (tracker_response.success.peers) |peer| {
            try torrent.addPeer(allocator, io, peer.address, peer.maybe_peer_id);
        }

        try io.sleep(.fromSeconds(60), .awake);
    }
}

const TrackerResponse = union(enum) {
    failure: []const u8,
    success: Success,

    const Success = struct {
        interval: u32,
        peers: []const AvailablePeer,

        const AvailablePeer = struct {
            address: Io.net.IpAddress,
            maybe_peer_id: ?[20]u8,
        };
    };

    pub fn deinit(response: TrackerResponse, allocator: Allocator) void {
        switch (response) {
            .failure => |reason| allocator.free(reason),
            .success => |success| allocator.free(success.peers),
        }
    }
};

fn parseTrackerResponse(allocator: Allocator, response_str: []const u8) !TrackerResponse {
    var parse_arena: std.heap.ArenaAllocator = .init(allocator);
    defer parse_arena.deinit();

    const parsed = bt.bencode.parseFromSliceLeaky(parse_arena.allocator(), response_str) catch |err| switch (err) {
        error.SyntaxError => return error.ParseError,
        else => |e| return e,
    };

    if (parsed != .dictionary)
        return error.ParseError;

    if (parsed.dictionary.get("failure reason")) |reason| {
        if (reason != .string)
            return error.ParseError;

        return .{ .failure = try allocator.dupe(u8, reason.string) };
    }

    const interval_value = parsed.dictionary.get("interval") orelse return error.ParseError;

    if (interval_value != .integer)
        return error.ParseError;

    const interval = std.fmt.parseInt(u32, interval_value.integer, 10) catch return error.ParseError;

    var peers: ArrayList(TrackerResponse.Success.AvailablePeer) = .empty;
    errdefer peers.deinit(allocator);

    const peers_value = parsed.dictionary.get("peers") orelse return error.ParseError;
    switch (peers_value) {
        .list => |peers_list| for (peers_list.items) |peer_value| {
            if (peer_value != .dictionary)
                continue;

            const peer_id_value = peer_value.dictionary.get("peer id") orelse continue;
            const ip_value = peer_value.dictionary.get("ip") orelse continue;
            const port_value = peer_value.dictionary.get("port") orelse continue;

            if (peer_id_value != .string or
                peer_id_value.string.len != 20 or
                ip_value != .string or
                port_value != .integer)
            {
                continue;
            }

            const port = std.fmt.parseInt(u16, port_value.integer, 10) catch return error.ParseError;

            var peer: TrackerResponse.Success.AvailablePeer = .{
                .address = Io.net.IpAddress.parse(ip_value.string, port) catch return error.ParseError,
                .maybe_peer_id = @as([20]u8, undefined),
            };
            @memcpy(&peer.maybe_peer_id.?, peer_id_value.string);

            try peers.append(allocator, peer);
        },
        .string => |peers_str| {
            // Must be a multiple of 6 - IPv4 (4) + Port (2)
            if (peers_str.len % 6 != 0)
                return error.ParseError;

            const num_peers = peers_str.len / 6;

            for (0..num_peers) |i| {
                const peer: TrackerResponse.Success.AvailablePeer = .{
                    .address = .{ .ip4 = .{
                        .bytes = peers_str[i * 6 ..][0..4].*,
                        .port = std.mem.bigToNative(u16, @bitCast(peers_str[i * 6 + 4 ..][0..2].*)),
                    } },
                    .maybe_peer_id = null,
                };
                try peers.append(allocator, peer);
            }
        },
        else => return error.ParseError,
    }

    // Check for compact IPv6 peers - BEP 0007

    const peers6_value = parsed.dictionary.get("peers6");
    if (peers6_value != null and peers6_value.? == .string) {
        const peers6_str = peers6_value.?.string;

        // Must be a multiple of 18 - IPv6 (16) + Port (2)
        if (peers6_str.len % 18 != 0)
            return error.ParseError;

        const num_peers = peers6_str.len / 18;

        for (0..num_peers) |i| {
            const peer: TrackerResponse.Success.AvailablePeer = .{
                .address = .{ .ip6 = .{
                    .bytes = peers6_str[i * 18 ..][0..16].*,
                    .port = std.mem.bigToNative(u16, @bitCast(peers6_str[i * 18 + 16 ..][0..2].*)),
                } },
                .maybe_peer_id = null,
            };
            try peers.append(allocator, peer);
        }
    }

    return .{ .success = .{
        .interval = interval,
        .peers = try peers.toOwnedSlice(allocator),
    } };
}

fn isQueryParamChar(c: u8) bool {
    return switch (c) {
        'A'...'Z',
        'a'...'z',
        '0'...'9',
        '~',
        '-',
        '_',
        '.',
        => true,
        else => false,
    };
}

fn peerWorker(allocator: Allocator, io: Io, torrent: *Torrent, peer_ptr: *?Peer) Io.Cancelable!void {
    defer {
        torrent.mutex.lockUncancelable(io);
        defer torrent.mutex.unlock(io);
        peer_ptr.* = null;
    }

    const peer = &peer_ptr.*.?;

    const stream = peer.addr.connect(io, .{ .mode = .stream, .protocol = .tcp }) catch |err| {
        std.log.err("unable to connect to peer: {t}", .{err});
        return;
    };

    var read_buf: [0x2000]u8 = undefined;
    var send_buf: [0x2000]u8 = undefined;

    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &send_buf);

    peerWorkerInner(allocator, io, torrent, peer, &reader, &writer) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.ProtocolError => {
            return std.log.err("peer protocol error, terminating peer", .{});
        },
        error.ReadFailed => {
            std.log.err("unable to read from peer: {t}", .{reader.err.?});
        },
        error.WriteFailed => {
            std.log.err("unable to write to peer: {t}", .{writer.err.?});
        },
        error.EndOfStream => std.log.err("unexpected end of stream", .{}),
        error.OutOfMemory => @panic("OOM"),
    };
}

fn peerWorkerInner(
    allocator: Allocator,
    io: Io,
    torrent: *Torrent,
    peer: *Peer,
    reader: *Io.net.Stream.Reader,
    writer: *Io.net.Stream.Writer,
) !void {
    // It's handshake o'clock

    const mw: bt.protocol.MessageWriter = .{ .writer = &writer.interface };
    try mw.writeHandshake(
        // Signal extension protocol ([BEP 0010](https://www.bittorrent.org/beps/bep_0010.html))
        &.{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00 },
        &torrent.info_hash,
        &torrent.peer_id,
    );
    try writeExtHandshake(mw, allocator, .{ .your_ip = peer.addr });
    try writer.interface.flush();

    const peer_handshake_length = try reader.interface.takeByte();
    if (peer_handshake_length != 19) return error.ProtocolError;
    const peer_handshake_str = try reader.interface.take(19);
    if (!std.mem.eql(u8, peer_handshake_str, "BitTorrent protocol")) return error.ProtocolError;
    const peer_extension_bytes = try reader.interface.take(8);
    if (peer_extension_bytes[5] & 0x10 == 0) return error.ProtocolError;
    const peer_advertised_info_hash = try reader.interface.take(20);
    if (!std.mem.eql(u8, &torrent.info_hash, peer_advertised_info_hash)) return error.ProtocolError;
    const peer_advertised_id = try reader.interface.takeArray(20);
    if (peer.maybe_id) |*peer_expected_id| {
        if (!std.mem.eql(u8, peer_expected_id, peer_advertised_id)) return error.ProtocolError;
    } else {
        peer.maybe_id = peer_advertised_id.*;
    }

    std.log.info("shook hands with {f}", .{peer.addr});

    // We negotiated the extension protocol, so we now expect the extension handshake

    const peer_ext_handshake_length = try reader.interface.takeInt(u32, .big);
    if (peer_ext_handshake_length < 9) return error.ProtocolError; // Shortest possible valid handshake: message ID (1) + ext message ID (1) + "d1:mdee".len (7) = 9

    var limited_reader_buf: [8]u8 = undefined;
    var limited_reader = reader.interface.limited(.limited64(peer_ext_handshake_length), &limited_reader_buf);

    const peer_ext_handshake_message_id = try limited_reader.interface.takeByte();
    if (peer_ext_handshake_message_id != 0x14) return error.ProtocolError; // This BitTorrent message is not an ext message.
    const peer_ext_handshake_ext_message_id = try limited_reader.interface.takeByte();
    if (peer_ext_handshake_ext_message_id != 0x00) return error.ProtocolError; // This ext message is not a handshake.

    var ext_handshake_parse_arena: std.heap.ArenaAllocator = .init(allocator);
    defer ext_handshake_parse_arena.deinit();
    const parsed_ext_handshake = bt.bencode.parseFromReaderLeaky(ext_handshake_parse_arena.allocator(), &limited_reader.interface) catch |err| switch (err) {
        error.SyntaxError => return error.ProtocolError,
        else => |e| return e,
    };

    if (parsed_ext_handshake != .dictionary) return error.ProtocolError;
    const peer_m = parsed_ext_handshake.dictionary.get("m") orelse return error.ProtocolError;
    if (peer_m != .dictionary) return error.ProtocolError;
    const peer_m_ut_metadata = peer_m.dictionary.get("ut_metadata") orelse return error.ProtocolError;
    if (peer_m_ut_metadata != .integer) return error.ProtocolError;
    const ext_metadata_id = std.fmt.parseUnsigned(u8, peer_m_ut_metadata.integer, 10) catch return error.ProtocolError;

    const peer_metadata_size = parsed_ext_handshake.dictionary.get("metadata_size") orelse return error.ProtocolError;
    if (peer_metadata_size != .integer) return error.ProtocolError;
    const metadata_size = std.fmt.parseUnsigned(usize, peer_metadata_size.integer, 10) catch return error.ProtocolError;
    if (metadata_size == 0) return error.ProtocolError;

    std.log.info("metadata size is {d} ({0Bi:.2})", .{metadata_size});

    const maybe_peer_v = parsed_ext_handshake.dictionary.get("v");
    if (maybe_peer_v) |peer_v| {
        if (peer_v != .string) return error.ProtocolError;
        std.log.info("peer {f} is running {f}", .{ peer.addr, std.zig.fmtString(peer_v.string) });
    }

    _ = ext_metadata_id;

    while (true) {
        std.log.debug("{f} {?f}: woo im doing peer stuff", .{ peer.addr, if (peer.maybe_id) |*id| std.zig.fmtString(id) else null });
        try io.sleep(.fromSeconds(5), .awake);
    }
}

const ExtHandshakeOptions = struct {
    your_ip: ?Io.net.IpAddress = null,
};

fn writeExtHandshake(mw: bt.protocol.MessageWriter, gpa: Allocator, options: ExtHandshakeOptions) (Allocator.Error || Io.Writer.Error)!void {
    var ext_allocating: Io.Writer.Allocating = try .initCapacity(gpa, 128);
    defer ext_allocating.deinit();
    const ext_str = make: {
        const ext_str: bt.bencode.Stringify = .{ .writer = &ext_allocating.writer };
        try ext_str.beginDictionary();

        try ext_str.writeString("m");
        try ext_str.beginDictionary();
        // We hardcode the ut_metadata ID to 1 to not worry about storing it
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
                inline else => |ip| {
                    try ext_str.beginString(ip.bytes.len);
                    try ext_allocating.writer.writeAll(&ip.bytes);
                },
            }
        }

        try ext_str.endContainer();
        break :make ext_allocating.written();
    };

    try mw.writeExtendedHeader(0x00, @as(u32, @intCast(ext_str.len)));
    try mw.writer.writeAll(ext_str);
}
