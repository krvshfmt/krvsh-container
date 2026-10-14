//! krvs container box framing (codec-agnostic).
//!
//! ISO-BMFF-style boxes. Every box:
//!   size      u32  big-endian; total box size incl header.
//!                  size==1 => real size in `largesize` (u64 follows type)
//!                  size==0 => box extends to end of stream (last box only)
//!   type      [4]u8 4CC
//!   largesize u64  big-endian; present iff size==1
//!   version   u8
//!   flags     u24  big-endian; bit0 = MANDATORY
//!   payload   ...  size - header_len bytes
//!
//! header_len = 8 (+8 if largesize) + 4 (version+flags) = 12 or 20 bytes.
//!
//! See docs/container-spec.md §2, §3.

const std = @import("std");

/// MANDATORY flag: an unknown box with this bit set is a fatal parse error;
/// an unknown box without it is skipped by advancing `size` bytes.
pub const FLAG_MANDATORY: u24 = 0x000001;

/// u32 size sentinels.
pub const SIZE_LARGE: u32 = 1; // real size follows in u64 largesize
pub const SIZE_TO_END: u32 = 0; // box runs to end of stream

pub const BoxError = error{
    ShortBuffer,
    /// A size==0 (to-end) box was found but the stream length is unknown here.
    ToEndUnsupported,
    /// Declared box size is smaller than its own header, or exceeds the buffer.
    BadSize,
    /// An unrecognized box carried the MANDATORY flag.
    UnknownMandatoryBox,
};

/// A parsed box header plus the slice of its payload within the source buffer.
pub const Box = struct {
    fourcc: [4]u8,
    version: u8,
    flags: u24,
    /// Total box size including header. For a size==0 box this is set to the
    /// remaining buffer length by `parse`.
    total_size: u64,
    header_len: u8,
    /// Payload bytes (not owned; a sub-slice of the buffer passed to `parse`).
    payload: []const u8,

    pub fn isMandatory(self: Box) bool {
        return (self.flags & FLAG_MANDATORY) != 0;
    }

    pub fn typeEql(self: Box, fourcc: *const [4]u8) bool {
        return std.mem.eql(u8, &self.fourcc, fourcc);
    }
};

/// Parse one box from the start of `buf`. `buf` must contain the entire box
/// (parse validates that). For a size==0 (to-end) box, the box is taken to span
/// all of `buf`.
pub fn parse(buf: []const u8) BoxError!Box {
    if (buf.len < 8) return error.ShortBuffer;
    const size32 = std.mem.readInt(u32, buf[0..4], .big);
    var fourcc: [4]u8 = undefined;
    @memcpy(&fourcc, buf[4..8]);

    var cursor: usize = 8;
    var total_size: u64 = undefined;

    switch (size32) {
        SIZE_LARGE => {
            if (buf.len < 16) return error.ShortBuffer;
            total_size = std.mem.readInt(u64, buf[8..16], .big);
            cursor = 16;
        },
        SIZE_TO_END => {
            total_size = buf.len; // spans the rest of the buffer/stream
        },
        else => {
            total_size = size32;
        },
    }

    // version(1) + flags(3)
    if (buf.len < cursor + 4) return error.ShortBuffer;
    const version = buf[cursor];
    const flags: u24 = std.mem.readInt(u24, buf[cursor + 1 .. cursor + 4][0..3], .big);
    cursor += 4;

    const header_len: u8 = @intCast(cursor);
    if (total_size < header_len) return error.BadSize;
    if (total_size > buf.len) return error.BadSize;

    return .{
        .fourcc = fourcc,
        .version = version,
        .flags = flags,
        .total_size = total_size,
        .header_len = header_len,
        .payload = buf[header_len..@intCast(total_size)],
    };
}

/// Write a box header + payload into `out`. Chooses the compact (u32 size) form
/// when the total fits in u32 and is not a sentinel; otherwise the largesize form.
/// Returns the number of bytes written. Does not emit size==0 (to-end) boxes.
pub fn write(
    out: []u8,
    fourcc: *const [4]u8,
    version: u8,
    flags: u24,
    payload: []const u8,
) BoxError!usize {
    const compact_total = 12 + payload.len;
    const use_large = compact_total > std.math.maxInt(u32);
    const header_len: usize = if (use_large) 20 else 12;
    const total = header_len + payload.len;
    if (out.len < total) return error.ShortBuffer;

    if (use_large) {
        std.mem.writeInt(u32, out[0..4], SIZE_LARGE, .big);
        @memcpy(out[4..8], fourcc);
        std.mem.writeInt(u64, out[8..16], @intCast(total), .big);
        out[16] = version;
        std.mem.writeInt(u24, out[17..20][0..3], flags, .big);
    } else {
        std.mem.writeInt(u32, out[0..4], @intCast(total), .big);
        @memcpy(out[4..8], fourcc);
        out[8] = version;
        std.mem.writeInt(u24, out[9..12][0..3], flags, .big);
    }
    @memcpy(out[header_len .. header_len + payload.len], payload);
    return total;
}

/// Iterate the child boxes within a container box's payload.
pub const Iterator = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn next(self: *Iterator) BoxError!?Box {
        if (self.pos >= self.buf.len) return null;
        const b = try parse(self.buf[self.pos..]);
        self.pos += @intCast(b.total_size);
        return b;
    }
};

pub fn iterate(payload: []const u8) Iterator {
    return .{ .buf = payload };
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const t = std.testing;

test "compact box roundtrip" {
    var buf: [64]u8 = undefined;
    const payload = "hello box payload";
    const n = try write(&buf, "cnit", 1, FLAG_MANDATORY, payload);
    try t.expectEqual(@as(usize, 12 + payload.len), n);

    const b = try parse(buf[0..n]);
    try t.expect(b.typeEql("cnit"));
    try t.expectEqual(@as(u8, 1), b.version);
    try t.expect(b.isMandatory());
    try t.expectEqual(@as(u8, 12), b.header_len);
    try t.expectEqual(@as(u64, n), b.total_size);
    try t.expectEqualStrings(payload, b.payload);
}

test "optional flag parses as non-mandatory" {
    var buf: [32]u8 = undefined;
    const n = try write(&buf, "crc ", 0, 0, &[_]u8{ 1, 2, 3, 4 });
    const b = try parse(buf[0..n]);
    try t.expect(!b.isMandatory());
    try t.expect(b.typeEql("crc "));
}

test "parse rejects short buffer" {
    try t.expectError(error.ShortBuffer, parse(&[_]u8{ 0, 0, 0 }));
}

test "parse rejects size smaller than header" {
    // size=4 (< 12) with a valid-looking type; header can't fit.
    var buf: [12]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 4, .big);
    @memcpy(buf[4..8], "kfrm");
    buf[8] = 0;
    std.mem.writeInt(u24, buf[9..12][0..3], 0, .big);
    try t.expectError(error.BadSize, parse(&buf));
}

test "parse rejects size exceeding buffer" {
    var buf: [12]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 999, .big); // claims 999 bytes, buffer is 12
    @memcpy(buf[4..8], "kfrm");
    buf[8] = 0;
    std.mem.writeInt(u24, buf[9..12][0..3], 0, .big);
    try t.expectError(error.BadSize, parse(&buf));
}

test "size==0 box spans the rest of the buffer" {
    var buf: [20]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], SIZE_TO_END, .big);
    @memcpy(buf[4..8], "mdat");
    buf[8] = 0;
    std.mem.writeInt(u24, buf[9..12][0..3], 0, .big);
    // remaining 8 bytes are payload
    @memset(buf[12..20], 0xAB);
    const b = try parse(&buf);
    try t.expectEqual(@as(u64, 20), b.total_size);
    try t.expectEqual(@as(usize, 8), b.payload.len);
}

test "iterate walks sibling boxes and skips an optional unknown one" {
    // Build a container payload: [cdci mandatory][xxxx optional unknown][inid mandatory]
    var buf: [128]u8 = undefined;
    var pos: usize = 0;
    pos += try write(buf[pos..], "cdci", 1, FLAG_MANDATORY, "AAAA");
    pos += try write(buf[pos..], "zzzz", 0, 0, "optional-unknown");
    pos += try write(buf[pos..], "inid", 1, FLAG_MANDATORY, "BBBBBBBB");

    var it = iterate(buf[0..pos]);
    var seen_cdci = false;
    var seen_inid = false;
    var skipped_unknown = false;
    const known = [_][4]u8{ .{ 'c', 'd', 'c', 'i' }, .{ 'i', 'n', 'i', 'd' } };

    while (try it.next()) |b| {
        var is_known = false;
        for (known) |k| {
            if (b.typeEql(&k)) is_known = true;
        }
        if (!is_known) {
            // unknown: mandatory => fatal, optional => skip (we just drop it)
            if (b.isMandatory()) return error.UnknownMandatoryBox;
            skipped_unknown = true;
            continue;
        }
        if (b.typeEql("cdci")) seen_cdci = true;
        if (b.typeEql("inid")) seen_inid = true;
    }
    try t.expect(seen_cdci and seen_inid and skipped_unknown);
}

test "iterate surfaces a mandatory unknown box to the caller" {
    var buf: [64]u8 = undefined;
    const n = try write(&buf, "zzzz", 0, FLAG_MANDATORY, "load-bearing");
    var it = iterate(buf[0..n]);
    const b = (try it.next()).?;
    try t.expect(!b.typeEql("cnit"));
    try t.expect(b.isMandatory()); // caller must treat unknown+mandatory as fatal
}

test "largesize form is used when payload is huge (header shape only)" {
    // We can't allocate >4GiB here; verify the writer selects the compact form
    // for small payloads and that the parser reads a hand-built largesize header.
    var buf: [24]u8 = undefined;
    // hand-build a largesize box: size32=1, type, largesize=20, v/flags, 4 payload
    std.mem.writeInt(u32, buf[0..4], SIZE_LARGE, .big);
    @memcpy(buf[4..8], "cpay");
    std.mem.writeInt(u64, buf[8..16], 24, .big);
    buf[16] = 1;
    std.mem.writeInt(u24, buf[17..20][0..3], FLAG_MANDATORY, .big);
    @memset(buf[20..24], 0x7);
    const b = try parse(&buf);
    try t.expect(b.typeEql("cpay"));
    try t.expectEqual(@as(u8, 20), b.header_len);
    try t.expectEqual(@as(u64, 24), b.total_size);
    try t.expectEqual(@as(usize, 4), b.payload.len);
}
