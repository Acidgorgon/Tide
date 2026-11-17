# Wire format

Everything Tide sends is a `buffer`, little-endian. Instances (models) never go inside a buffer: they
travel as a separate remote argument and are referenced by index.

| Remote | Type | Direction | Carries |
|---|---|---|---|
| `TideU` | `UnreliableRemoteEvent` | client → server | uploads (tag 2) |
| `TideU` | `UnreliableRemoteEvent` | server → client | relay frames (tag 1) |
| `TideR` | `RemoteEvent` | both | control messages (tags 10–16) |

## Sample

The core of every sample is 8 bytes, written as two `u32`:

```
lo = x:17 | y (low 15 bits):15
hi = y (high 2 bits):2 | z:17 | yaw:10 | flags:3
```

| Field | Encoding | Resolution |
|---|---|---|
| `x`, `y`, `z` | `round((p - origin) × 64) + 65536`, 17 bits each | 1/64 stud, ±1024 studs around `Config.origin` |
| `yaw` | `round(yaw × 1024 / 2π) mod 1024` | 0.35° |
| `flags` | bit 0 teleport, bit 1 full rotation, bit 2 absolute position | |

Extras follow the core, in this order:

- **Full rotation** (bit 1): 4 bytes, a smallest-three quaternion (2 bits for the largest component's
  index, 3 × 10 bits for the others).
- **Absolute position** (bit 2): when a position is outside ±1024 studs (or not finite), the core's
  xyz bits are zero and 3 × `f32` (12 bytes) follow.

| Sample | Bytes |
|---|---|
| yaw only, near the origin | 8 |
| full rotation | 12 |
| yaw only, absolute position | 20 |
| full rotation, absolute position | 24 |

## Relay frame (server → client)

One per receiver per server frame, split at `Config.MaxPacket` (900 B).

```
u8   tag = 1
u8   flags            bit 0: wide slots (more than 255 slots in use)
f64  frameTime        server time, on a 0.5 ms grid
records until the end of the buffer:
  slot  u8 (u16 if wide)
  dt    u8            (frameTime - sampleTime) in 0.5 ms steps, 0..254
                      255 = extended: a u16 in 0.5 ms steps follows
  sample              8 B core (+ extras)
```

| Record | Bytes |
|---|---|
| typical (u8 slot, dt under 127 ms, yaw only) | **10** |
| with full rotation | 14 |
| wide slot | +1 |
| sample older than 127 ms (extended dt) | +2 |

Header: 10 bytes per packet. Each record is encoded once per frame and copied as-is into every
receiver's packet. An entity's several samples in one frame are several records.

## Upload (client → server)

```
u8   tag = 2
u8   count            1..MaxUploadCount (16)
count ×:
  slot   u16
  stamp  f64          server time when sampled
  sample              8 B core (+ extras)
```

A typical upload of one character sample is 2 + 18 = **20 bytes**. With `UploadRedundancy = 2`, each
upload also carries the previous sample (38 bytes).

## Control (`TideR`, reliable)

A control buffer holds one or more messages back to back. The second remote argument is the array of
instances referenced by index (1-based; 0 = none).

| Tag | Name | Direction | Body |
|---|---|---|---|
| 10 | ADD | server → client | `u16 slot, u8 kind id, u16 instance index, f64 owner userId (0 = server)` |
| 11 | REMOVE | server → client | `u16 slot` |
| 12 | OWNER | server → client | `u16 slot, f64 owner userId` |
| 13 | TELEPORT | server → owner | `u16 slot, f32 x, y, z, qx, qy, qz, qw, u8 has velocity, [f32 vx, vy, vz]` |
| 14 | HELLO | server → client | `u8 version, f64 origin x, y, z, u8 lock, u8 upload redundancy, u8 kind count`, then per kind: `u8 id, u8 name length, name, f32 rate, u8 flags (bit 0 full), f32 buffer, f32 extrapolate, f32 keepAlive, f32 maxSpeed, f32 maxRise, f32 maxFall` |
| 15 | READY | client → server | (none) |
| 16 | RESEND | client → server | `u8 count, count × u16 slot` (models that haven't streamed in) |

The protocol version is `2`. A client that sees a different version warns in the output.

Byte counts on this page are payload only; Roblox adds its own per-call overhead on top.
