const std = @import("std");
const Uri = std.Uri;

pub fn main(init: std.process.Init) !void {
    var iter = try init.minimal.args.iterateAllocator(init.gpa);
    std.debug.assert(iter.skip());
    const uri_str = iter.next() orelse "magnet:?xt=urn:btih:da39a3ee5e6b4b0d3255bfef95601890afd80709&xt=urn:btmh:1220e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

    const uri: Uri = try .parse(uri_str);

    if (!std.mem.eql(u8, uri.scheme, "magnet")) {
        std.log.err("not a magnet link - quitting", .{});
        return;
    }

    std.log.debug("fmt: {f}", .{uri});

    if (uri.query == null) {
        std.log.err("no query params - quitting", .{});
        return;
    }

    var query = uri.query.?.percent_encoded;
    while (next: {
        break :next if (query.len == 0)
            null
        else
            query[0 .. std.mem.findScalar(u8, query, '&') orelse query.len];
    }) |param| : (query = query[@min(param.len + 1, query.len)..]) {
        const key = param[0..std.mem.findScalar(u8, param, '=') orelse continue];
        const value = param[key.len + 1..];

        if (std.mem.eql(u8, key, "xt")) {
            std.log.info("exact topic: {s}", .{value});

            const xt_uri = Uri.parse(value) catch |err| {
                std.log.warn("malformed topic uri ({t}) - skipping", .{err});
                continue;
            };
            if (!std.mem.eql(u8, xt_uri.scheme, "urn")) {
                std.log.warn("topic is not a urn ('{s}') - skipping", .{xt_uri.scheme});
                continue;
            }

            const topic_path = xt_uri.path.percent_encoded;
            const topic_nid = topic_path[0..std.mem.findScalar(u8, topic_path, ':') orelse topic_path.len];

            if (std.mem.eql(u8, topic_nid, "btih")) {
                const btih = topic_path[@min(topic_nid.len + 1, topic_path.len)..];
                std.log.info("bittorrent info hash: {s}", .{btih});
            } else {
                std.log.warn("unrecognized topic nid ('{s}') - skipping", .{topic_nid});
                return;
            }
        } else if (std.mem.eql(u8, key, "as")) {
            std.log.info("acceptable source: {s}", .{value});
        } else if (std.mem.eql(u8, key, "tr")) {
            std.log.info("tracker url: {s}", .{value});
        } else {
            std.log.warn("unrecognized param ('{s}') - skipping", .{param});
            continue;
        }
    }
}
