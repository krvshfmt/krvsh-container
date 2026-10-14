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

    zig build        # static lib
    zig build test   # unit tests

Requires Zig 0.17.0.
