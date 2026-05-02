const std = @import("std");
const bt = std.bittorrent;
const Uri = std.Uri;
const http = std.http;
const Writer = std.Io.Writer;

fn isQueryParamChar(c: u8) bool {
    return switch (c) {
        'A'...'Z',
        'a'...'z',
        '0'...'9',
        '-',
        '_',
        => true,
        else => false,
    };
}

pub fn main(init: std.process.Init) !void {
    var iter = try init.minimal.args.iterateAllocator(init.gpa);
    std.debug.assert(iter.skip());
    const tracker_uri_str = iter.next() orelse return std.log.err("expected tracker url", .{});
    const info_hash_hex = iter.next() orelse return std.log.err("expected info hash", .{});

    if (info_hash_hex.len != 40) {
        return std.log.err("info hash must be exactly 20 bytes long", .{});
    }
    var info_hash: [20]u8 = undefined;
    for (0..20) |i| {
        info_hash[i] = std.fmt.parseUnsigned(u8, info_hash_hex[i * 2 .. i * 2 + 2], 16) catch {
            return std.log.err("invalid info hash", .{});
        };
    }

    var tracker_uri = Uri.parse(tracker_uri_str) catch |err| {
        return std.log.err("provided tracker url is invalid ({t})", .{err});
    };

    var peer_id_buf: [6]u8 = undefined;
    init.io.random(&peer_id_buf);

    var query_allocating: Writer.Allocating = try .initCapacity(init.gpa, 64);
    defer query_allocating.deinit();

    try query_allocating.writer.writeAll("info_hash=");
    try Uri.Component.percentEncode(&query_allocating.writer, &info_hash, isQueryParamChar);
    // zl = ziglang
    try query_allocating.writer.print("&peer_id=-zl0000-{x}&port=6881&uploaded=0&downloaded=0&left=0&event=started&compact=0", .{peer_id_buf});

    tracker_uri.query = .{ .percent_encoded = query_allocating.written() };

    std.log.info("sending request to {f}", .{tracker_uri});

    var client: http.Client = .{ .allocator = init.gpa, .io = init.io };
    defer client.deinit();

    var response_allocating: Writer.Allocating = try .initCapacity(init.gpa, 1024);
    defer response_allocating.deinit();

    const result = try client.fetch(.{
        .location = .{ .uri = tracker_uri },
        .response_writer = &response_allocating.writer,
    });

    std.log.info("response status: {d}", .{@intFromEnum(result.status)});
    std.log.info("received response: '{f}'", .{std.zig.fmtString(response_allocating.written())});

    var parse_arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer parse_arena.deinit();

    const parsed = bt.bencode.parseFromSliceLeaky(parse_arena.allocator(), response_allocating.written()) catch |err| {
        return std.log.warn("response is not a valid bencoding ({t}) - quitting", .{err});
    };

    if (parsed != .dictionary)
        return std.log.warn("response is not a dictionary - quitting", .{});

    if (parsed.dictionary.get("failure reason")) |reason| {
        if (reason != .string)
            return std.log.warn("response failure reason is not a string - quitting", .{});
        return std.log.warn("failure reason: {s}", .{reason.string});
    }

    const interval_value = parsed.dictionary.get("interval") orelse return std.log.warn("response has no interval key - quitting", .{});
    const peers_value = parsed.dictionary.get("peers") orelse return std.log.warn("response has not peers key - quitting", .{});

    if (interval_value != .integer)
        return std.log.warn("response interval is not an integer - quitting", .{});

    std.log.info("interval: {s}", .{interval_value.integer});

    if (peers_value == .list) {
        std.log.info("list peers ({d}):", .{peers_value.list.items.len});
        for (peers_value.list.items, 0..) |peer_value, i| {
            if (peer_value != .dictionary) {
                std.log.warn("peer #{d} is not a dictionary (got {t}) - skipping it", .{i + 1, peer_value});
                continue;
            }

            const peer_id_value = peer_value.dictionary.get("peer id");
            const ip_value = peer_value.dictionary.get("ip");
            const port_value = peer_value.dictionary.get("port");

            if (peer_id_value == null or
                ip_value == null or
                port_value == null or
                peer_id_value.? != .string or
                ip_value.? != .string or
                port_value.? != .integer) {
                std.log.warn("peer #{d} has invalid keys - skipping it", .{i + 1});
                continue;
            }

            std.log.info(" - peer: (id: '{f}') {s}:{s}", .{std.zig.fmtString(peer_id_value.?.string), ip_value.?.string, port_value.?.integer});
        }
    } else if (peers_value == .string) {
        if (peers_value.string.len % 6 != 0)
            return std.log.warn("response peers string length isn't a multiple of 6 - quitting", .{});

        const num_peers = peers_value.string.len / 6;

        std.log.info("compact peers ({d}):", .{num_peers});
        for (0..num_peers) |i| {
            const addr: std.Io.net.Ip4Address = .{
                .bytes = @bitCast(peers_value.string[i * 6..][0..4].*),
                .port = std.mem.bigToNative(u16, @bitCast(peers_value.string[i * 6 + 4..][0..2].*)),
            };

            std.log.info(" - peer: {f}", .{addr});
        }
    } else {
        return std.log.warn("response peers has invalid type - quitting", .{});
    }
}
