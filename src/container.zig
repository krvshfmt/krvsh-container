//! krvs container record assembly: codec-AGNOSTIC `cnit` / `kfrm` / `kfrg` / marker
//! boxes and the init resolver (container-spec.md §4-§9).
//!
//! This module knows nothing about any codec. Codec identity, the init-id hash, and the
//! opaque init/frame payloads are passed in by the caller (a codec, e.g. krvsh). The
//! container defines framing, the init-id reference/dependency, and resolution; the
//! codec defines what the bytes mean.
//!
//! Box framing is big-endian (box.zig); the leaf boxes defined here use little-endian
//! for their own scalar fields.

const std = @import("std");
const box = @import("box.zig");

const List = std.array_list.Managed(u8);

// Container box 4CCs.
pub const T_MARKER = "krvs";
pub const T_CNIT = "cnit";
pub const T_KFRM = "kfrm";
pub const T_KFRG = "kfrg";
// Child leaf 4CCs.
pub const T_CDCI = "cdci";
pub const T_INID = "inid";
pub const T_CPAY = "cpay";
pub const T_FREF = "fref";
pub const T_FHDR = "fhdr";
pub const T_FPAY = "fpay";

pub const CONTAINER_MAJOR: u8 = 1;
pub const CONTAINER_MINOR: u32 = 0;

/// Init-id hash algorithm codes (the hash itself is computed by the codec).
pub const HASH_ALGO_SHA256_T16: u8 = 1;
/// Maximum init-id length the container stores inline.
pub const MAX_ID_LEN: usize = 32;

pub const BuildError = std.mem.Allocator.Error;
pub const ParseError = box.BoxError || std.mem.Allocator.Error || error{
    MissingChild,
    BadChild,
    UnsupportedVersion,
    ReservedPrevFrame,
    InitNotResolved,
    IdTooLong,
};

/// A codec identity + an opaque init id, carried by cnit/kfrm. The container treats the
/// id as opaque bytes; the codec defines the hash.
pub const InitId = struct {
    hash_algo: u8 = HASH_ALGO_SHA256_T16,
    bytes: []const u8, // id_len bytes

    pub fn eql(a: InitId, b: InitId) bool {
        return a.hash_algo == b.hash_algo and std.mem.eql(u8, a.bytes, b.bytes);
    }
};

// ---------------------------------------------------------------------------
// marker box
// ---------------------------------------------------------------------------

pub fn writeMarker(out: *List) BuildError!void {
    var payload: [8]u8 = undefined;
    std.mem.writeInt(u32, payload[0..4], CONTAINER_MINOR, .little);
    std.mem.writeInt(u32, payload[4..8], 0, .little); // compatible_brands_count = 0
    try appendBox(out, T_MARKER, CONTAINER_MAJOR, box.FLAG_MANDATORY, &payload);
}

/// Validate a marker box at the start of `buf`; return bytes consumed.
pub fn parseMarker(buf: []const u8) ParseError!usize {
    const b = try box.parse(buf);
    if (!b.typeEql(T_MARKER)) return error.BadChild;
    if (b.version > CONTAINER_MAJOR) return error.UnsupportedVersion;
    return @intCast(b.total_size);
}

// ---------------------------------------------------------------------------
// cnit (codec-init) assembly
// ---------------------------------------------------------------------------

/// Wrap an opaque codec init payload in a `cnit` box with `cdci`, `inid`, `cpay`
/// children. `codec_fourcc`/`codec_version` identify the codec; `init_id` is the codec's
/// content hash of `cpay` (the container does not compute it).
pub fn writeCnit(
    out: *List,
    codec_fourcc: *const [4]u8,
    codec_version: u32,
    init_id: InitId,
    cpay: []const u8,
) BuildError!void {
    var children = List.init(out.allocator);
    defer children.deinit();

    var cdci: [8]u8 = undefined;
    @memcpy(cdci[0..4], codec_fourcc);
    std.mem.writeInt(u32, cdci[4..8], codec_version, .little);
    try appendBox(&children, T_CDCI, 1, box.FLAG_MANDATORY, &cdci);

    try appendIdBox(&children, T_INID, init_id);
    try appendBox(&children, T_CPAY, 1, box.FLAG_MANDATORY, cpay);

    try appendBox(out, T_CNIT, 1, box.FLAG_MANDATORY, children.items);
}

/// A parsed `cnit`: borrows the input buffer.
pub const CnitView = struct {
    codec_fourcc: [4]u8,
    codec_version: u32,
    init_id: InitId,
    cpay: []const u8,
    total_size: usize,
};

pub fn parseCnit(buf: []const u8) ParseError!CnitView {
    const b = try box.parse(buf);
    if (!b.typeEql(T_CNIT)) return error.BadChild;
    if (b.version > 1) return error.UnsupportedVersion;

    var fourcc: ?[4]u8 = null;
    var codec_version: ?u32 = null;
    var id: ?InitId = null;
    var cpay: ?[]const u8 = null;

    var it = box.iterate(b.payload);
    while (try it.next()) |child| {
        if (child.typeEql(T_CDCI)) {
            if (child.payload.len < 8) return error.BadChild;
            var fc: [4]u8 = undefined;
            @memcpy(&fc, child.payload[0..4]);
            fourcc = fc;
            codec_version = std.mem.readInt(u32, child.payload[4..8], .little);
        } else if (child.typeEql(T_INID)) {
            id = try parseIdBox(child.payload);
        } else if (child.typeEql(T_CPAY)) {
            cpay = child.payload;
        } else if (child.isMandatory()) {
            return error.BadChild;
        }
    }

    return .{
        .codec_fourcc = fourcc orelse return error.MissingChild,
        .codec_version = codec_version orelse return error.MissingChild,
        .init_id = id orelse return error.MissingChild,
        .cpay = cpay orelse return error.MissingChild,
        .total_size = @intCast(b.total_size),
    };
}

// ---------------------------------------------------------------------------
// kfrm (frame) assembly
// ---------------------------------------------------------------------------

/// Wrap an opaque codec frame payload in a `kfrm` box with `fref`, `fhdr`, `fpay`.
pub fn writeKfrm(
    out: *List,
    init_id: InitId,
    frame_id: u64,
    prev_frame_id: u64,
    fpay: []const u8,
) BuildError!void {
    var children = List.init(out.allocator);
    defer children.deinit();

    try appendIdBox(&children, T_FREF, init_id);

    var fhdr: [16]u8 = undefined;
    std.mem.writeInt(u64, fhdr[0..8], frame_id, .little);
    std.mem.writeInt(u64, fhdr[8..16], prev_frame_id, .little);
    try appendBox(&children, T_FHDR, 1, box.FLAG_MANDATORY, &fhdr);

    try appendBox(&children, T_FPAY, 1, box.FLAG_MANDATORY, fpay);

    try appendBox(out, T_KFRM, 1, box.FLAG_MANDATORY, children.items);
}

pub const KfrmView = struct {
    init_id: InitId,
    frame_id: u64,
    prev_frame_id: u64,
    fpay: []const u8,
    total_size: usize,
};

pub fn parseKfrm(buf: []const u8) ParseError!KfrmView {
    const b = try box.parse(buf);
    if (!b.typeEql(T_KFRM)) return error.BadChild;
    if (b.version > 1) return error.UnsupportedVersion;

    var id: ?InitId = null;
    var frame_id: u64 = 0;
    var prev: u64 = 0;
    var fpay: ?[]const u8 = null;
    var saw_fhdr = false;

    var it = box.iterate(b.payload);
    while (try it.next()) |child| {
        if (child.typeEql(T_FREF)) {
            id = try parseIdBox(child.payload);
        } else if (child.typeEql(T_FHDR)) {
            if (child.payload.len < 16) return error.BadChild;
            frame_id = std.mem.readInt(u64, child.payload[0..8], .little);
            prev = std.mem.readInt(u64, child.payload[8..16], .little);
            saw_fhdr = true;
        } else if (child.typeEql(T_FPAY)) {
            fpay = child.payload;
        } else if (child.isMandatory()) {
            return error.BadChild;
        }
    }

    if (prev != 0) return error.ReservedPrevFrame; // v0: temporal delta not supported
    if (!saw_fhdr) return error.MissingChild;
    return .{
        .init_id = id orelse return error.MissingChild,
        .frame_id = frame_id,
        .prev_frame_id = prev,
        .fpay = fpay orelse return error.MissingChild,
        .total_size = @intCast(b.total_size),
    };
}

// ---------------------------------------------------------------------------
// init resolver (container-spec.md §9)
// ---------------------------------------------------------------------------

/// Resolves a frame's `init_id` to the init's `cpay` bytes. Codec-agnostic: it stores
/// by the id's bytes and does NOT recompute the hash (that is the codec's job -- the
/// codec should verify cpay against init_id before registering, per §9.4). v0 provides
/// the in-stream cache; a caller may seed it from a local cache or fetch hook.
/// Keys (id bytes) and values (cpay) are borrowed; the caller owns their lifetimes.
pub const InitResolver = struct {
    const Key = struct { algo: u8, bytes: []const u8 };
    const Entry = struct { key: Key, cpay: []const u8 };
    map: std.array_list.Managed(Entry),

    pub fn init(alloc: std.mem.Allocator) InitResolver {
        return .{ .map = std.array_list.Managed(Entry).init(alloc) };
    }
    pub fn deinit(self: *InitResolver) void {
        self.map.deinit();
    }

    /// Register an init's cpay under the given id. The caller (codec) is responsible for
    /// having verified cpay hashes to `id` (§9.4) before calling this.
    pub fn put(self: *InitResolver, id: InitId, cpay: []const u8) BuildError!void {
        try self.map.append(.{ .key = .{ .algo = id.hash_algo, .bytes = id.bytes }, .cpay = cpay });
    }

    /// Resolve an init_id to cpay, or error if unknown.
    pub fn resolve(self: *const InitResolver, id: InitId) ParseError![]const u8 {
        for (self.map.items) |e| {
            if (e.key.algo == id.hash_algo and std.mem.eql(u8, e.key.bytes, id.bytes)) return e.cpay;
        }
        return error.InitNotResolved;
    }
};

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

fn appendBox(out: *List, fourcc: *const [4]u8, version: u8, flags: u24, payload: []const u8) BuildError!void {
    const header_len: usize = if (12 + payload.len > std.math.maxInt(u32)) 20 else 12;
    const old = out.items.len;
    try out.resize(old + header_len + payload.len);
    _ = box.write(out.items[old..], fourcc, version, flags, payload) catch unreachable;
}

/// An id leaf box: hash_algo(u8) + id_len(u8) + id bytes.
fn appendIdBox(out: *List, fourcc: *const [4]u8, id: InitId) BuildError!void {
    std.debug.assert(id.bytes.len <= MAX_ID_LEN);
    var buf: [2 + MAX_ID_LEN]u8 = undefined;
    buf[0] = id.hash_algo;
    buf[1] = @intCast(id.bytes.len);
    @memcpy(buf[2 .. 2 + id.bytes.len], id.bytes);
    try appendBox(out, fourcc, 1, box.FLAG_MANDATORY, buf[0 .. 2 + id.bytes.len]);
}

/// Parse an id leaf box payload. The returned `bytes` slice borrows `payload`.
fn parseIdBox(payload: []const u8) ParseError!InitId {
    if (payload.len < 2) return error.BadChild;
    const algo = payload[0];
    const id_len = payload[1];
    if (id_len > MAX_ID_LEN) return error.IdTooLong;
    if (payload.len < 2 + @as(usize, id_len)) return error.BadChild;
    return .{ .hash_algo = algo, .bytes = payload[2 .. 2 + id_len] };
}

// ---------------------------------------------------------------------------
// tests (container-only: synthetic codec id + opaque payloads)
// ---------------------------------------------------------------------------

const ztest = std.testing;

const TEST_FOURCC = "tst0";
fn tid(bytes: []const u8) InitId {
    return .{ .hash_algo = HASH_ALGO_SHA256_T16, .bytes = bytes };
}

test "marker roundtrip" {
    var out = List.init(ztest.allocator);
    defer out.deinit();
    try writeMarker(&out);
    const n = try parseMarker(out.items);
    try ztest.expectEqual(out.items.len, n);
}

test "cnit assemble/parse with opaque payload" {
    var out = List.init(ztest.allocator);
    defer out.deinit();
    const id_bytes: [16]u8 = @splat(0xAB);
    const cpay = "opaque-codec-init-bytes";
    try writeCnit(&out, TEST_FOURCC, 7, tid(&id_bytes), cpay);

    const v = try parseCnit(out.items);
    try ztest.expectEqualSlices(u8, TEST_FOURCC, &v.codec_fourcc);
    try ztest.expectEqual(@as(u32, 7), v.codec_version);
    try ztest.expectEqualSlices(u8, &id_bytes, v.init_id.bytes);
    try ztest.expectEqualStrings(cpay, v.cpay);
    try ztest.expectEqual(out.items.len, v.total_size);
}

test "kfrm assemble/parse" {
    var out = List.init(ztest.allocator);
    defer out.deinit();
    const id_bytes: [16]u8 = @splat(0xCD);
    try writeKfrm(&out, tid(&id_bytes), 42, 0, "opaque-frame");

    const v = try parseKfrm(out.items);
    try ztest.expectEqualSlices(u8, &id_bytes, v.init_id.bytes);
    try ztest.expectEqual(@as(u64, 42), v.frame_id);
    try ztest.expectEqualStrings("opaque-frame", v.fpay);
}

test "kfrm rejects reserved prev_frame_id" {
    var out = List.init(ztest.allocator);
    defer out.deinit();
    const id_bytes: [16]u8 = @splat(1);
    try writeKfrm(&out, tid(&id_bytes), 1, 7, "x");
    try ztest.expectError(error.ReservedPrevFrame, parseKfrm(out.items));
}

test "resolver put/resolve + unknown id" {
    var r = InitResolver.init(ztest.allocator);
    defer r.deinit();
    const id_bytes: [16]u8 = @splat(0x11);
    const cpay = "the-init-bytes";
    try r.put(tid(&id_bytes), cpay);
    try ztest.expectEqualSlices(u8, cpay, try r.resolve(tid(&id_bytes)));
    const bogus: [16]u8 = @splat(0xEE);
    try ztest.expectError(error.InitNotResolved, r.resolve(tid(&bogus)));
}

test "marker then cnit then kfrm walk as a stream" {
    var stream = List.init(ztest.allocator);
    defer stream.deinit();
    const id_bytes: [16]u8 = @splat(0x33);
    try writeMarker(&stream);
    try writeCnit(&stream, TEST_FOURCC, 1, tid(&id_bytes), "cpay");
    try writeKfrm(&stream, tid(&id_bytes), 1, 0, "fpay");

    var pos: usize = try parseMarker(stream.items);
    const cnit = try parseCnit(stream.items[pos..]);
    pos += cnit.total_size;
    const kfrm = try parseKfrm(stream.items[pos..]);
    pos += kfrm.total_size;
    try ztest.expectEqual(stream.items.len, pos);
    try ztest.expectEqualSlices(u8, cnit.init_id.bytes, kfrm.init_id.bytes);
}
