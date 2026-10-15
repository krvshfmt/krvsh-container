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

// The C ABI (src/c_api.zig, include/krvs.h) is NOT exposed here: it uses the C
// allocator and would force a libc dependency onto pure-Zig consumers of this module.
// It is built as a separate artifact rooted at src/c_root.zig (which links libc) and
// exercised by the C smoke test.

pub const CONTAINER_VERSION = container.CONTAINER_MAJOR;

test {
    std.testing.refAllDecls(@This());
    _ = box;
    _ = container;
}
