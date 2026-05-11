const std = @import("std.zig");

pub const bencode = @import("bittorrent/bencode.zig");
pub const protocol = @import("bittorrent/protocol.zig");

test {
    std.testing.refAllDecls(@This());
}

