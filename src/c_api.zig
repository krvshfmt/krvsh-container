//! C ABI for the krvs container (see include/krvs.h).
//!
//! Flat C surface over container.zig for C/C++/Rust consumers. Conventions:
//!   - All buffers are caller-owned. Nothing allocated here crosses the boundary.
//!   - Write functions use a two-call size/fill protocol: pass out=null (or too-small
//!     cap) to get the required size in *written and status KRVS_BUFFER_TOO_SMALL, then
//!     call again with a buffer of that size.
//!   - Parse functions return views (pointers INTO the caller's input buffer) via an
//!     out-struct; they borrow, they do not copy.
//!   - Status codes mirror the Zig error sets.
//!
//! Thread-safety: functions are reentrant; a transient heap buffer (c_allocator) is
//! used to serialize a record, then copied into the caller buffer. No shared state.

const std = @import("std");
const container = @import("container.zig");

const List = std.array_list.Managed(u8);

pub const Status = enum(c_int) {
    ok = 0,
    buffer_too_small = 1,
    short_buffer = 2,
    bad_box = 3,
    bad_child = 4,
    missing_child = 5,
    unsupported_version = 6,
    reserved_prev_frame = 7,
    init_not_resolved = 8,
    id_too_long = 9,
    bad_size = 10,
    internal = 255,
};

fn mapErr(e: anyerror) Status {
    return switch (e) {
        error.ShortBuffer => .short_buffer,
        error.BadSize => .bad_size,
        error.ToEndUnsupported, error.UnknownMandatoryBox => .bad_box,
        error.BadChild => .bad_child,
        error.MissingChild => .missing_child,
        error.UnsupportedVersion => .unsupported_version,
        error.ReservedPrevFrame => .reserved_prev_frame,
        error.InitNotResolved => .init_not_resolved,
        error.IdTooLong => .id_too_long,
        else => .internal,
    };
}

/// Copy a serialized record into the caller buffer with the two-call size protocol.
fn finish(list: *const List, out: ?[*]u8, out_cap: usize, written: *usize) Status {
    written.* = list.items.len;
    if (out == null or out_cap < list.items.len) return .buffer_too_small;
    @memcpy(out.?[0..list.items.len], list.items);
    return .ok;
}

// ---------------------------------------------------------------------------
// marker
// ---------------------------------------------------------------------------

export fn krvs_write_marker(out: ?[*]u8, out_cap: usize, written: *usize) Status {
    var list = List.init(std.heap.c_allocator);
    defer list.deinit();
    container.writeMarker(&list) catch |e| return mapErr(e);
    return finish(&list, out, out_cap, written);
}

/// Validate a marker at the start of buf; set *consumed to its byte length.
export fn krvs_parse_marker(buf: [*]const u8, len: usize, consumed: *usize) Status {
    const n = container.parseMarker(buf[0..len]) catch |e| return mapErr(e);
    consumed.* = n;
    return .ok;
}

// ---------------------------------------------------------------------------
// cnit
// ---------------------------------------------------------------------------

export fn krvs_write_cnit(
    codec_fourcc: [*]const u8, // 4 bytes
    codec_version: u32,
    hash_algo: u8,
    init_id: [*]const u8,
    id_len: usize,
    cpay: [*]const u8,
    cpay_len: usize,
    out: ?[*]u8,
    out_cap: usize,
    written: *usize,
) Status {
    if (id_len > container.MAX_ID_LEN) return .id_too_long;
    var fourcc: [4]u8 = undefined;
    @memcpy(fourcc[0..4], codec_fourcc[0..4]);
    const id: container.InitId = .{ .hash_algo = hash_algo, .bytes = init_id[0..id_len] };

    var list = List.init(std.heap.c_allocator);
    defer list.deinit();
    container.writeCnit(&list, &fourcc, codec_version, id, cpay[0..cpay_len]) catch |e| return mapErr(e);
    return finish(&list, out, out_cap, written);
}

/// Parsed cnit view: pointers borrow the input buffer.
pub const CnitView = extern struct {
    codec_fourcc: [4]u8,
    codec_version: u32,
    hash_algo: u8,
    init_id: [*]const u8,
    id_len: usize,
    cpay: [*]const u8,
    cpay_len: usize,
    total_size: usize,
};

export fn krvs_parse_cnit(buf: [*]const u8, len: usize, view: *CnitView) Status {
    const v = container.parseCnit(buf[0..len]) catch |e| return mapErr(e);
    view.* = .{
        .codec_fourcc = v.codec_fourcc,
        .codec_version = v.codec_version,
        .hash_algo = v.init_id.hash_algo,
        .init_id = v.init_id.bytes.ptr,
        .id_len = v.init_id.bytes.len,
        .cpay = v.cpay.ptr,
        .cpay_len = v.cpay.len,
        .total_size = v.total_size,
    };
    return .ok;
}

// ---------------------------------------------------------------------------
// kfrm
// ---------------------------------------------------------------------------

export fn krvs_write_kfrm(
    hash_algo: u8,
    init_id: [*]const u8,
    id_len: usize,
    frame_id: u64,
    prev_frame_id: u64,
    fpay: [*]const u8,
    fpay_len: usize,
    out: ?[*]u8,
    out_cap: usize,
    written: *usize,
) Status {
    if (id_len > container.MAX_ID_LEN) return .id_too_long;
    const id: container.InitId = .{ .hash_algo = hash_algo, .bytes = init_id[0..id_len] };
    var list = List.init(std.heap.c_allocator);
    defer list.deinit();
    container.writeKfrm(&list, id, frame_id, prev_frame_id, fpay[0..fpay_len]) catch |e| return mapErr(e);
    return finish(&list, out, out_cap, written);
}

pub const KfrmView = extern struct {
    hash_algo: u8,
    init_id: [*]const u8,
    id_len: usize,
    frame_id: u64,
    prev_frame_id: u64,
    fpay: [*]const u8,
    fpay_len: usize,
    total_size: usize,
};

export fn krvs_parse_kfrm(buf: [*]const u8, len: usize, view: *KfrmView) Status {
    const v = container.parseKfrm(buf[0..len]) catch |e| return mapErr(e);
    view.* = .{
        .hash_algo = v.init_id.hash_algo,
        .init_id = v.init_id.bytes.ptr,
        .id_len = v.init_id.bytes.len,
        .frame_id = v.frame_id,
        .prev_frame_id = v.prev_frame_id,
        .fpay = v.fpay.ptr,
        .fpay_len = v.fpay.len,
        .total_size = v.total_size,
    };
    return .ok;
}

/// Container major version (the `krvs` marker box version).
export fn krvs_container_version() u8 {
    return container.CONTAINER_MAJOR;
}

test {
    // ensure the C API compiles with the library module
    std.testing.refAllDecls(@This());
}
