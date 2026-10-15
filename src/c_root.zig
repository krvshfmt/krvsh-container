//! Root for the C-ABI library artifact only. Keeps the C exports and links libc
//! (c_api uses std.heap.c_allocator). The plain Zig library (root.zig) stays libc-free.

const c_api = @import("c_api.zig");

comptime {
    _ = c_api;
}
