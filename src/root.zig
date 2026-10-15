//! krvs — codec-agnostic container for compressed intermediate model state.
//!
//! An ISO-BMFF-style box tree that carries one-time codec-init records (`cnit`) and
//! per-frame records (`kfrm`), with a content-hash init-id dependency so frames can be
//! shipped and cached independently of their init. Knows nothing about any codec; a
//! codec (e.g. krvsh) populates the opaque payloads. See docs/container-spec.md.

const std = @import("std");

/// Box framing (size/type/version/flags, nesting, mandatory-skip).
pub const box = @import("box.zig");

/// Record assembly: marker / cnit / kfrm / kfrg + init resolver.
pub const container = @import("container.zig");

/// C ABI exports (see include/krvs.h). Referenced so `export fn`s are compiled into
/// the C-ABI library artifact.
pub const c_api = @import("c_api.zig");

// Force the C ABI exports to be kept in the library artifact (not dead-stripped).
comptime {
    _ = c_api;
}

pub const CONTAINER_VERSION = container.CONTAINER_MAJOR;

test {
    std.testing.refAllDecls(@This());
    _ = box;
    _ = container;
    _ = c_api;
}
