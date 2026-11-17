--!strict
-- Reliable control channel (RemoteEvent "TideR") message writer.
-- Messages are concatenated in one buffer per send; instances travel as a dense
-- array in the second remote argument and are referenced by 1-based index.
--
-- server -> client
--   10 ADD      u16 slot, u8 kind, u16 instance index, f64 owner userId (0 = server)
--   11 REMOVE   u16 slot
--   12 OWNER    u16 slot, f64 owner userId
--   13 TELEPORT u16 slot, f32 x, y, z, qx, qy, qz, qw, u8 has velocity, [f32 vx, vy, vz]
--               (to the owner: move there, flag uploads for Config.TeleportAckTime)
--   14 HELLO    u8 version, f64 origin x, y, z, u8 flags (bit0 lock, bit1 animations, bit2 animations
--               owner-local), u8 upload redundancy, u8 kind count,
--               per kind: u8 id, u8 name length, name, f32 rate, u8 flags (bit0 full, bit1 animations
--               off for this kind, bit2 state-only: motion = false), f32 buffer, f32 extrapolate, f32 keepAlive, f32 maxSpeed, f32 maxRise,
--               f32 maxFall,
--               only with animations: u16 animation folder instance index, u16 folder id count,
--               u32 folder checksum
--   21 ANIM     f64 baseTime, u16 count, count x event (see Shared/AnimCodec)
--   23 ANIMID   u16 id, u8 length, AnimationId string
--   24 ANIMSNAP u16 slot, f64 baseTime, u8 count, count x state (see Shared/AnimCodec)
--   30 STATE    f64 baseTime, u16 groups, groups x (u16 slot, i16 dt (0.5 ms vs baseTime), u8 n,
--               n x (u8 field id [bit7: the field's default, no value], value)) (see Shared/StateSchema)
--   31 STATESNAP u16 slot, f64 t0, u8 n, n x (u8 field [bit7], value): values in effect at t0;
--               u16 m, m x (u16 dt (0.5 ms after t0), u8 field [bit7], value): changes after t0
--   32 SCHEMA   u8 kinds, kinds x schema (see Shared/StateSchema)
-- client -> server
--   15 READY
--   16 RESEND   u8 count, count x u16 slot   (models that did not arrive, e.g. streaming)
--   20 ANIM     f64 baseTime, u8 count, count x event
--   22 REGISTER u8 length, AnimationId string (length 0: send me every id)
--   (30-32 are server -> client only: a client sending them is counted (stateRejected) and dropped)

local Control = {}

Control.ADD = 10
Control.REMOVE = 11
Control.OWNER = 12
Control.TELEPORT = 13
Control.HELLO = 14
Control.READY = 15
Control.RESEND = 16
Control.ANIM_UP = 20
Control.ANIM = 21
Control.REGISTER = 22
Control.ANIMID = 23
Control.ANIMSNAP = 24
Control.STATE = 30
Control.STATESNAP = 31
Control.SCHEMA = 32
Control.VERSION = 4 -- 2: TELEPORT velocity, HELLO keepAlive; 3: animation channel; 4: timeline state

export type Writer = {
	b: buffer,
	pos: number,
	insts: { any },
}

function Control.writer(size: number?): Writer
	return { b = buffer.create(size or 256), pos = 0, insts = {} }
end

local function ensure(w: Writer, n: number)
	local need = w.pos + n
	local len = buffer.len(w.b)
	if need > len then
		while len < need do
			len *= 2
		end
		local nb = buffer.create(len)
		buffer.copy(nb, 0, w.b, 0, w.pos)
		w.b = nb
	end
end

Control.ensure = ensure

-- Appends len bytes of src (from offset).
function Control.bytes(w: Writer, src: buffer, offset: number, len: number)
	ensure(w, len)
	buffer.copy(w.b, w.pos, src, offset, len)
	w.pos += len
end

function Control.u8(w: Writer, v: number)
	ensure(w, 1)
	buffer.writeu8(w.b, w.pos, v)
	w.pos += 1
end

function Control.u16(w: Writer, v: number)
	ensure(w, 2)
	buffer.writeu16(w.b, w.pos, v)
	w.pos += 2
end

function Control.i16(w: Writer, v: number)
	ensure(w, 2)
	buffer.writei16(w.b, w.pos, v)
	w.pos += 2
end

function Control.u32(w: Writer, v: number)
	ensure(w, 4)
	buffer.writeu32(w.b, w.pos, v)
	w.pos += 4
end

function Control.f32(w: Writer, v: number)
	ensure(w, 4)
	buffer.writef32(w.b, w.pos, v)
	w.pos += 4
end

function Control.f64(w: Writer, v: number)
	ensure(w, 8)
	buffer.writef64(w.b, w.pos, v)
	w.pos += 8
end

function Control.str(w: Writer, s: string)
	local n = math.min(#s, 255)
	ensure(w, n + 1)
	buffer.writeu8(w.b, w.pos, n)
	buffer.writestring(w.b, w.pos + 1, s, n)
	w.pos += n + 1
end

-- Adds an instance to the argument array; returns its index (0 for nil).
function Control.inst(w: Writer, inst: any): number
	if inst == nil then
		return 0
	end
	local insts = w.insts
	local n = #insts + 1
	insts[n] = inst
	return n
end

-- Copies the written bytes into a buffer of exact size.
function Control.take(w: Writer): buffer
	local out = buffer.create(w.pos)
	buffer.copy(out, 0, w.b, 0, w.pos)
	return out
end

-- Hands out the instance array (a fresh one replaces it) and empties the writer.
function Control.takeAll(w: Writer): (buffer, { any })
	local b = Control.take(w)
	local insts = w.insts
	w.insts = {}
	w.pos = 0
	return b, insts
end

function Control.reset(w: Writer)
	w.pos = 0
	w.insts = {}
end

return Control
