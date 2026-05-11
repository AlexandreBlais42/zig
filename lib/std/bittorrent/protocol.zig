//! Tools for exchanging messages using the BitTorrent peer protocol.
//!
//! Currently supports the following [BEPs](https://www.bittorrent.org/beps/bep_0000.html):
//! - [BEP 0003](https://www.bittorrent.org/beps/bep_0003.html) The BitTorrent Protocol Specification
//! - [BEP 0010](https://www.bittorrent.org/beps/bep_0010.html) Extension Protocol
//!
//! See [the BitTorrent specification](https://www.bittorrent.org/beps/bep_0003.html#peer-protocol) for more information.

const std = @import("../std.zig");
const Writer = std.Io.Writer;

pub const MessageWriter = struct {
    writer: *Writer,

    /// Write a handshake.
    pub fn writeHandshake(mw: MessageWriter, reserved_bytes: *const [8]u8, info_hash: *const [20]u8, peer_id: *const [20]u8) Writer.Error!void {
        try mw.writer.writeAll("\x13BitTorrent protocol");
        try mw.writer.writeAll(reserved_bytes);
        try mw.writer.writeAll(info_hash);
        try mw.writer.writeAll(peer_id);
    }

    /// Write a Choke (0x00) message.
    pub fn writeChoke(mw: MessageWriter) Writer.Error!void {
        try mw.writer.writeAll("\x00\x00\x00\x01\x00");
    }

    /// Write an Unchoke (0x01) message.
    pub fn writeUnchoke(mw: MessageWriter) Writer.Error!void {
        try mw.writer.writeAll("\x00\x00\x00\x01\x01");
    }

    /// Write an Interested (0x02) message.
    pub fn writeInterested(mw: MessageWriter) Writer.Error!void {
        try mw.writer.writeAll("\x00\x00\x00\x01\x02");
    }

    /// Write a Not Interested (0x03) message.
    pub fn writeNotInterested(mw: MessageWriter) Writer.Error!void {
        try mw.writer.writeAll("\x00\x00\x00\x01\x03");
    }

    /// Write a Have (0x04) message.
    pub fn writeHave(mw: MessageWriter, index: u32) Writer.Error!void {
        try mw.writer.writeAll("\x00\x00\x00\x05\x04");
        try mw.writer.writeInt(u32, index, .big);
    }

    /// Write a Bitfield (0x05) message.
    pub fn writeBitfield(mw: MessageWriter, bitfield: []const u8) Writer.Error!void {
        try mw.writer.writeInt(u32, @intCast(1 + bitfield.len), .big);
        try mw.writer.writeByte(0x05);
        try mw.writer.writeAll(bitfield);
    }

    /// Write a Request (0x06) message.
    pub fn writeRequest(mw: MessageWriter, index: u32, begin: u32, length: u32) Writer.Error!void {
        try mw.writer.writeAll("\x00\x00\x00\x0d\x06");
        try mw.writer.writeInt(u32, index, .big);
        try mw.writer.writeInt(u32, begin, .big);
        try mw.writer.writeInt(u32, length, .big);
    }

    /// Write the header of a Piece (0x07) message.
    /// The user must write `data_length` bytes to the writer after calling this function.
    pub fn writePiece(mw: MessageWriter, index: u32, begin: u32, data_length: u32) Writer.Error!void {
        try mw.writer.writeInt(u32, 1 + 4 + 4 + data_length, .big);
        try mw.writer.writeByte(0x07);
        try mw.writer.writeInt(u32, index, .big);
        try mw.writer.writeInt(u32, begin, .big);
    }

    /// Write a Cancel (0x08) message.
    pub fn writeCancel(mw: MessageWriter, index: u32, begin: u32, length: u32) Writer.Error!void {
        try mw.writer.writeAll("\x00\x00\x00\x0d\x08");
        try mw.writer.writeInt(u32, index, .big);
        try mw.writer.writeInt(u32, begin, .big);
        try mw.writer.writeInt(u32, length, .big);
    }

    /// Write the header of an Extended (0x14) message.
    /// The user must write `data_length` bytes to the writer after calling this function.
    pub fn writeExtendedHeader(mw: MessageWriter, message_id: u8, data_length: u32) Writer.Error!void {
        try mw.writer.writeInt(u32, 1 + 1 + data_length, .big);
        try mw.writer.writeAll(&.{ 0x14, message_id });
    }
};

test {
    std.testing.refAllDecls(@This());
}
