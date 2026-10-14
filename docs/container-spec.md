# krvs container specification

Version: 1. Status: v0, subject to change until first tagged release.

This document defines the **codec-agnostic** container: a box tree that carries
compressed intermediate model state. It knows nothing about any particular codec. A
codec (e.g. [the krvsh codec](krvsh-codec-spec.md)) populates the codec-opaque boxes
defined here. The rationale is in [design.md](design.md).

The design borrows ISO-BMFF (ISO/IEC 14496-12, the MP4 box structure) framing and the
CMAF idea that a stream is an init followed by independently decodable fragments. It
does **not** adopt the MP4 sample tables, timing boxes, or `moof`/`mdat` machinery.

## 1. Conventions

- Byte order: big-endian for box framing fields (`size`, `largesize`), matching
  ISO-BMFF. Codec payloads choose their own endianness (krvsh uses little-endian
  internally; see its spec).
- `uN` = unsigned integer of N bits.
- A 4CC (four-character code) is 4 ASCII bytes, written like `'cnit'`. Trailing spaces
  are significant (`'crc '`).

## 2. Box

Every element in the container is a box:

```
size      u32    total box size in bytes, INCLUDING this header.
                 size == 1  => real size is in `largesize` (payload > ~4 GiB)
                 size == 0  => box extends to end of stream (only valid for the
                               last box in a stream)
type      u32    4CC identifying the box
largesize u64    present IFF size == 1; total box size including header
version   u8     box version (ISO-BMFF FullBox style)
flags     u24    box flags; bit 0 (0x000001) = MANDATORY (see §3)
payload   ...    size - header_len bytes; for container boxes, child boxes
```

`header_len` is 8 (size+type) + 8 if `largesize` present + 4 (version+flags) = 12 or
20 bytes. All boxes are FullBoxes (always carry version+flags); there is no bare-box
variant, which keeps the parser uniform.

A box is either a **container box** (payload is a sequence of child boxes) or a **leaf
box** (payload is type-specific bytes). Nesting is generic and recursive: a parser
walks any box by its `size` without knowing its type.

## 3. Unknown boxes: mandatory vs optional

ISO-BMFF leaves skip-vs-fail behavior loose. krvs makes it explicit via `flags` bit 0:

- A box a decoder does not recognize with the MANDATORY bit **set** is a fatal error.
  It is load-bearing for correct reconstruction; silently skipping it would yield a
  wrong result.
- A box a decoder does not recognize with the MANDATORY bit **clear** is skipped by
  advancing `size` bytes. This is how the format stays forward-compatible: future box
  types (new metadata, signatures, indices, alternate codec payloads) can be added
  without breaking existing decoders, as long as they are not load-bearing.

A decoder MUST implement skip-by-size for optional unknown boxes and MUST fail on
mandatory unknown boxes.

## 4. Magic marker box: `'krvs'`

Every krvs file or stream begins with a marker box:

```
type     'krvs'
version  u8     container major version (= 1)
flags    u24    MANDATORY set
payload:
  u32   minor_version
  u32   compatible_brands_count
  4CC[] compatible_brands    // e.g. 'krv1', hints at what a reader must support
```

Analogous to ISO-BMFF `ftyp`. A reader that does not support the major version MUST
refuse the stream.

## 5. Codec-init box: `'cnit'`

One-time, amortized codec state that many frames reference. Opaque to the container.
This is the ISO-BMFF decoder-config / sample-entry analogue. For the krvsh codec this
carries the PCA basis + model metadata (see krvsh-codec-spec.md); another codec puts
whatever one-time state it needs here.

```
type     'cnit'
version  u8     = 1
flags    u24    MANDATORY set
payload (child boxes):
  'cdci'  codec-id box (leaf)         // which codec this init is for
            4CC   codec_fourcc        // e.g. 'krvs' (the krvsh codec)
            u32   codec_version
  'inid'  init-id box (leaf)          // content hash identifying this init
            u8    hash_algo           // 1 = sha256-truncated-16
            u8    id_len              // = 16
            u8[]  init_id             // id_len bytes
  'cpay'  codec payload box           // codec-opaque init bytes (krvsh: basis+meta)
            u8[]  opaque
  (optional future boxes: 'crc ', signatures, etc. -- skippable if not mandatory)
```

### 5.1 init_id

`init_id` is a content hash computed by the codec over a codec-defined subset of the
init's children (for krvsh: codec params + model metadata + tensor data), **excluding
optional boxes** such as `'crc '` or signatures. Excluding optionals means adding one
later does not change the `init_id`, so content-addressing is stable across
extensions. The container stores and transports the id; the codec defines what bytes
it covers.

## 6. Frame box: `'kfrm'`

A single frame's codec-opaque payload plus its dependency on an init.

```
type     'kfrm'
version  u8     = 1
flags    u24    MANDATORY set
payload (child boxes):
  'fref'  init-reference box (leaf)
            u8    hash_algo
            u8    id_len
            u8[]  init_id             // the init this frame decodes against
  'fhdr'  frame-header box (leaf)
            u64   frame_id            // caller-assigned, monotonic within a session
            u64   prev_frame_id       // 0 = independent; nonzero reserved (temporal)
  'fpay'  codec payload box
            u8[]  opaque              // codec-opaque frame bytes
```

A frame carries its own `init_id` reference (decision: hash id, not a session-local
index). This makes a lone frame file self-describing about its dependency: the init it
needs can live in another file or be pinned at the decoder, resolved by id. A decoder
MUST have resolved the referenced init before decoding `'fpay'`; an unresolved
`init_id` is a clear, reported error, not a guess.

`prev_frame_id != 0` is reserved for inter-frame prediction; a v0 decoder MUST reject
it rather than treat the frame as independent.

## 7. Fragment box: `'kfrg'`

Groups one or more frames that share an init. Defined in v0 because retrofitting frame
grouping later would be a breaking change to how frames are addressed in a multiplexed
file.

```
type     'kfrg'
version  u8     = 1
flags    u24    MANDATORY set
payload (child boxes):
  'fref'  init-reference box (leaf)   // the init shared by all frames in this fragment
  'kfrm'  frame box                   // one or more
  'kfrm'  frame box
  ...
```

A `'kfrm'` inside a `'kfrg'` MAY omit its own `'fref'` and inherit the fragment's. A
`'kfrm'` at the top level MUST carry its own `'fref'`.

## 8. Carriage modes

The same boxes support three modes with one concept (the CMAF init+fragment idea,
without CMAF's segment/index machinery):

1. **Independent frame file.** `[krvs marker][kfrm with fref]`. The referenced init is
   NOT in the file; the decoder resolves `init_id` out-of-band (another file, a pinned
   cache). Smallest unit of shippable work.

2. **Multiplexed / self-contained file.** `[krvs marker][cnit][kfrg[kfrm, kfrm, ...]]`
   possibly with multiple `cnit` and `kfrg` boxes. Everything needed is in one file.

3. **Streamed.** The same boxes arriving over time; a decoder consumes boxes as they
   land, buffering the `cnit` and decoding each `kfrm`/`kfrg` as it arrives.

The container does not define transport. It defines bytes; moving them is the caller's
job.

## 9. Calibration reuse and the init cache

A `cnit` is a standalone, content-addressed, cacheable artifact. The whole economic
argument for the format is that calibration is done ONCE and referenced by many frames,
many files, and many sessions. For the measured Fast-WAM case the init is ~378 MB and
the break-even is ~8,400 frames (see design.md §3.4), so sharing one pinned init across
sessions is not an optimization, it is the thing that makes the per-frame numbers real.
A decoder that re-fetches the init per session loses the amortization.

### 9.1 Content addressing

A frame references its init by `init_id` (a content hash, krvsh-codec-spec.md §4), not
by file offset or a session-local index. The reference is therefore location- and
file-independent: a `kfrm` says "I need init `a3f2...`", never "the init at byte N of
this file". Because `init_id` is computed over the init payload EXCLUDING optional boxes
(`crc `, signatures), the same calibration always hashes to the same id, which makes the
id a stable long-lived cache key.

### 9.2 Standalone init file and file-type conventions

A `cnit` MAY be written as its own file: `[krvs marker][cnit]`. Recommended extensions:

| extension | contents |
|-----------|----------|
| `.krvi`   | init only: `[krvs marker][cnit]` (one calibration, cache-ready) |
| `.krvf`   | frame(s) only: `[krvs marker][kfrm ...]` or `[krvs marker][kfrg ...]`, init resolved out-of-band |
| `.krvs`   | multiplexed: `[krvs marker][cnit][kfrg[...]]`, self-contained |

A content-addressed init cache is naturally laid out as `by-id/<init_id>.krvi`.

### 9.3 Init resolution order

To decode a `kfrm`/`kfrg`, a decoder MUST resolve the referenced `init_id` to a `cnit`.
The defined lookup order:

1. **In-stream.** A `cnit` with that `init_id` seen earlier in the current stream/file.
2. **Local init cache.** A caller-configured cache (e.g. a directory of `.krvi` files
   keyed by `init_id`). This is the persistent, cross-session store that enables reuse.
3. **Caller-provided fetch hook.** An optional callback the caller supplies to obtain a
   `cnit` by `init_id` from wherever it lives. The container defines the lookup by id;
   it does NOT define transport.

If none resolve the id, the decoder MUST fail with a clear "unknown calibration" error
naming the `init_id`. It MUST NOT guess or fall back to a different init.

### 9.4 Two-way integrity across the cache boundary

Because the frame carries `init_id` AND the init carries `model_fingerprint`
(krvsh-codec-spec.md §3.1), a decoder pulling an init from a shared cache can verify
both ends independently:

- The resolved init's recomputed `init_id` MUST equal the id the frame requested. This
  guarantees the frame is bound to exactly the calibration bytes it was encoded against,
  even across files and sessions.
- The caller SHOULD compare the init's `model_fingerprint` to the model it is about to
  run and refuse on mismatch.

Together these mean cross-session, cross-file init sharing cannot silently bind a frame
to the wrong calibration or a calibration to the wrong model.

## 10. Integrity

Integrity is an optional `'crc '` leaf box (CRC-32, IEEE) that a producer MAY place as
a child of any box to cover that box's other children. It is NOT mandatory, is excluded
from `init_id`, and a decoder that does not check it skips it. For `cnit`, the
`init_id` content hash is the primary integrity mechanism; `'crc '` is a cheap extra,
most useful on `kfrm` payloads, which have no content hash of their own.

```
type     'crc '
version  u8     = 0
flags    u24    optional (MANDATORY clear)
payload:
  u32    crc32  // over the concatenated bytes of the sibling boxes it protects,
                // in document order, excluding this 'crc ' box itself
```

## 11. Forward compatibility rules

- New top-level box types may be added; decoders skip unknown optional ones and fail
  on unknown mandatory ones (§3).
- New codecs register a `codec_fourcc` and define their own `'cpay'`/`'fpay'` contents.
  The container is unchanged.
- A change to box framing (the §2 header) requires a container major-version bump; the
  `'krvs'` marker gates it.
- Codec payload evolution is the codec's concern, versioned by `codec_version` in
  `'cdci'`, independent of the container version.
