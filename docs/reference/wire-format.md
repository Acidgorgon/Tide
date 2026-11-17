# Wire format

Everything Tide sends is a `buffer`, little-endian. Instances (models) never go inside a buffer: they
travel as a separate remote argument and are referenced by index.

| Remote | Type | Direction | Carries |
|---|---|---|---|
| `TideU` | `UnreliableRemoteEvent` | client → server | uploads (tag 2) |
| `TideU` | `UnreliableRemoteEvent` | server → client | relay frames (tag 1) |
| `TideR` | `RemoteEvent` | both | control messages (tags 10–16, animations 20–24) |

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
| 14 | HELLO | server → client | `u8 version, f64 origin x, y, z, u8 flags (bit 0 lock, bit 1 animations, bit 2 animations owner-local), u8 upload redundancy, u8 kind count`, then per kind: `u8 id, u8 name length, name, f32 rate, u8 flags (bit 0 full, bit 1 animations off), f32 buffer, f32 extrapolate, f32 keepAlive, f32 maxSpeed, f32 maxRise, f32 maxFall`; with animations on, then `u16 folder instance index, u16 folder id count, u32 folder checksum` |
| 15 | READY | client → server | (none) |
| 16 | RESEND | client → server | `u8 count, count × u16 slot` (models that haven't streamed in) |

The protocol version is `3`. A client that sees a different version warns in the output. With
`Config.animations` off, no field or message below is sent and every byte above is as in version 2.

## Animations (`TideR`, reliable)

Only with `Config.animations` on ([guide](/guide/animations)). Events are rare (a few per second per
entity) and must not be lost, so they go on the reliable remote.

| Tag | Name | Direction | Body |
|---|---|---|---|
| 20 | ANIM | client → server | `f64 baseTime, u8 count, count × event` |
| 21 | ANIM | server → client | `f64 baseTime, u16 count, count × event` (one per receiver per frame) |
| 22 | REGISTER | client → server | `u8 length, AnimationId` (length 0: send every id) |
| 23 | ANIMID | server → client | `u16 id, u8 length, AnimationId` |
| 24 | ANIMSNAP | server → client | `u16 slot, f64 baseTime, u8 count, count × state` |

An event:

```
u16  slot
i16  dt               (time - baseTime) in 0.5 ms steps
u8   op
u16  animation id
then by op:
  1 PLAY      u8 fade (10 ms), u8 weight (1/100), i16 speed (1/256), u16 timePos (ms),
              u8 priority, u8 flags (bit 0 looped)
  2 STOP      u8 fade
  3 SPEED     i16 speed
  4 WEIGHT    u8 weight, u8 fade
  5 SEEK      u16 timePos
  6 PRIORITY  u8 priority
```

Priority is an index: 0 Core, 1 Idle, 2 Movement, 3 Action, 4 Action2, 5 Action3, 6 Action4.

A snapshot state (what plays at `baseTime`): `u16 id, u8 weight, i16 speed, f32 timePos (seconds, not
wrapped), u8 priority, u8 flags (bit 0 looped)`, 11 bytes.

| Message | Bytes |
|---|---|
| PLAY event | 15 |
| STOP event | 8 |
| one event relayed alone (tag, header, event) | 26 |
| snapshot of an entity playing 2 animations | 34 |

Ids 1..n come from `Config.animationFolder` on both sides (its `Animation` descendants sorted by full
name, then `AnimationId`); the HELLO's count and checksum (FNV-1a over the ids) let a client check its
copy, and it asks for every id (REGISTER with length 0) when they differ. The server answers ANIMID for
ids it assigns later, to every client.

Byte counts on this page are payload only; Roblox adds its own per-call overhead on top.
