# krvs

Codec-agnostic container for compressed intermediate model state (transformer KV cache
and similar). An ISO-BMFF-style box tree carrying one-time codec-init records (`cnit`)
and per-frame records (`kfrm`), with a content-hash init-id dependency so frames can be
shipped and cached independently of their init.

The container knows nothing about any particular codec. A codec (e.g. the `krvsh`
codec) populates the opaque `cpay`/`fpay` payloads and defines the init-id hash; this
library owns the framing, the init dependency, and resolution.

See [docs/container-spec.md](docs/container-spec.md) for the normative byte format.

## Use as a library

Add as a dependency and import the `krvs` module:

```zig
const krvs = @import("krvs");
const c = krvs.container;
// c.writeCnit(out, fourcc, version, init_id, cpay);
// c.writeKfrm(out, init_id, frame_id, prev, fpay);
// c.parseCnit / c.parseKfrm / c.InitResolver
```

## Build

    zig build        # static lib + C-ABI static/shared libs + headers
    zig build test   # unit tests + C smoke test

Requires Zig 0.17.0.

Build output (`zig-out/`):

- `lib/libkrvs.a` — the plain Zig static library
- `lib/libkrvs_c.a` — C-ABI static library (link from C/C++/Rust)
- `lib/libkrvs_c.{dylib,so,dll}` — C-ABI shared library (loaded by the Python bindings)
- `include/krvs.h` — hand-written C header

## C ABI

`include/krvs.h` exposes a flat C surface (`krvs_write_marker` / `krvs_parse_cnit` /
`krvs_write_kfrm` / ...). Conventions: caller-owned buffers, a two-call size/fill
protocol for writes, and parse views that borrow the input buffer. A C smoke test
(`test/capi_smoke.c`) links the static lib under `zig build test` to catch header drift.

## Python bindings

`python/krvs/` is a pure-ctypes wrapper over the shared library — no numpy, no build
step. Build the shared lib with `zig build` (it also copies the lib into the package's
`_libs/` dir), then either install the package or point at it directly:

```sh
zig build                 # builds libkrvs_c.* and syncs it into python/krvs/_libs/
pip install -e .          # editable install -> `import krvs` works anywhere
```

```python
import krvs

marker = krvs.write_marker()
cnit = krvs.write_cnit(b"krvs", 1, init_id=bytes(16), cpay=b"...")
frame = krvs.write_kfrm(init_id=bytes(16), frame_id=0, fpay=b"...")

v = krvs.parse_cnit(cnit)      # -> CnitView(codec_fourcc, cpay, init_id, ...)
f = krvs.parse_kfrm(frame)     # -> KfrmView(frame_id, fpay, ...)
```

The loader finds the library in the package `_libs/` dir (installed), then `zig-out/lib`
(dev); override with `$KRVS_LIB`. Re-run `zig build` after changing the Zig code to
refresh the bundled lib. Round-trip smoke test: `python python/tests/test_smoke.py`.
