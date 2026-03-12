const std = @import("std.zig");

pub const bencode = @import("bittorrent/bencode.zig");

test {
    std.testing.refAllDecls(@This());
}

