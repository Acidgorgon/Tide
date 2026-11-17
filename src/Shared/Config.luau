--!strict
-- Tide configuration. Edit fields before Tide.start() (or pass them in the
-- start options table, which copies matching keys over these defaults).

local Config = {
	-- Wire
	origin = Vector3.new(0, 0, 0), -- quantization centre; packed positions cover +-1024 studs per axis
	MaxPacket = 900, -- bytes per unreliable relay packet (Roblox drops > 1000)
	UploadRedundancy = 1, -- 2 = each upload also resends the previous sample (server setting, sent to clients)

	-- Server receive
	MaxBackdate = 1.0, -- seconds a client stamp may lie in the past of its arrival
	MaxAhead = 0.005, -- seconds a client stamp may lie in the future of its arrival
	PlayerBytesPerSecond = 8192, -- upload byte cap per player (token bucket)
	PlayerBytesPerFrame = 1024, -- upload byte cap per player per server frame
	MaxUploadCount = 16, -- records per upload packet
	TeleportGrantRadius = 4.0, -- studs: after a server teleport, owner uploads farther than this from the target are dropped until acked
	TeleportRetry = 1.0, -- seconds before an unacknowledged teleport command is sent again
	TeleportTries = 3, -- sends before onSuspicious(player, "teleportIgnored") (the server copy keeps holding the target)
	teleportOnWrite = true, -- server writes to a client-owned root's CFrame (CFrame =, PivotTo) become teleports
	teleportOnWriteVelocity = "zero", -- "zero": those teleports stop the character; "keep": the owner keeps its velocity
	SpeedResync = 1.0, -- seconds of continuous speed rejections before the owner is teleported back to the server's pose (0 = never)

	-- Server history / relay
	HistorySize = 128, -- samples kept per entity on the server (1 s at ~100 Hz)
	ReceiverBytesPerSecond = 40960, -- relay byte budget per receiver; far records dropped first
	InterestEvery = 0.1, -- seconds between distance tier recomputes
	Hysteresis = 4, -- studs of hysteresis around near/far/cull boundaries
	SlotQuarantine = 2.0, -- seconds before a freed slot is reused

	-- Lock (players)
	lockPlayers = true, -- stop native position replication of client-owned entities (see Server/Lock)
	lockMode = "root", -- "root": non-replicated locker inside the root part; "anchored": anchored locker in the server Camera
	lockHumanoidStates = false, -- or a list of Enum.HumanoidStateType disabled on the server Humanoid while locked

	-- Client
	ClientRing = 64, -- samples kept per entity on the client
	MaxBuffer = 0.5, -- max interpolation delay (seconds)
	BufferMargin = 0.002, -- added to p95 of measured need
	NeedGapMax = 0.25, -- sample gaps above this are idle/keep-alive gaps: not counted as need
	SnapGap = 1.0, -- sample gaps above this are treated as teleports (no sweep across)
	DelaySnap = 0.1, -- delay changes larger than this snap; smaller ones ease
	CorrectionTime = 0.1, -- seconds to blend away a correction
	SnapDistance = 16, -- corrections larger than this (studs) snap instead of blending
	ClientAnchor = true, -- anchor roots of remotely-driven entities on the client (BulkMoveTo path)
	ModelRetry = 1.0, -- seconds between asks for models that did not arrive (streaming)
	TeleportAckTime = 0.3, -- seconds after a server teleport during which the owner flags its uploads
	startTimeout = 30, -- client Tide.start(): seconds to wait for the server's remotes before warning and returning false

	-- Animations (v0.2; see Shared/AnimWatch, Server/Anim, Client/AnimPlay)
	animations = false, -- replay Animator play/stop/adjust events at each receiver's render time (server setting, sent)
	animationsOwnerLocal = true, -- the owner client swaps in a client-created Animator so Roblox stops replicating its tracks (sent)
	animationFolder = nil :: Instance?, -- Animation instances pre-registered on both sides (no bytes), e.g. ReplicatedStorage.Assets.Animations
	animationFade = 0.1, -- seconds: fade used when the watcher cannot estimate one
	MaxAnimIds = 1024, -- registered animation ids in total (folder + runtime)
	AnimEventsPerSecond = 60, -- animation events per player per second (token bucket, burst 30)
	AnimApplyPerFrame = 64, -- client: animation events applied per frame at most

	-- Timeline state (v0.3; see Shared/StateSchema, Server/StateLog, Client/StateApply). On when a
	-- kind has a schema (Tide.state); without one nothing changes.
	StateHistory = 32, -- server: changes kept per entity per field for Tide.stateAt (field option `history` overrides)
	StateReplay = 1.0, -- server: a snapshot carries the values in effect this many seconds ago plus the changes since
	StateApplyPerFrame = 128, -- client: state changes applied per frame at most
}

return Config
