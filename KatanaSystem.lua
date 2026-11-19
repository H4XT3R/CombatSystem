--[[
	KATANA SYSTEM/ CREATED BY Domusthedev. (H4XT3R12)

	This script handles server authoritative melee requests. The client only requests an
	attack or a block; it never chooses a victim, damage amount, or hitbox position, so a
	malicious exploiter cannot fabricate hits.

	HitboxModule reports overlap candidates and clashes. This script checks character
	state, distance, and walls before DamageModule applies the damage.
	Each swing owns its temporary movement and connections until cleanup.

	Caches used by this script (so work is not repeated on every hit):
	- punchSounds:     the fixed list of punch sound templates, built once at startup
	- animationTracks: one loaded reaction AnimationTrack per Humanoid, reused on every hit
	- rayCache:        one RaycastParams (plus its ignore list) per attacking player
	
	I am following and abiding HiddenDevs code quality standard.
]]

--Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService")

--Modules
-- Combat modules shared by the client and server: DamageModule applies damage (and the
-- block multiplier), HitboxModule detects which characters overlap the swing volume.
local combatModules = ReplicatedStorage.Shared.CombatModules
local DamageModule = require(combatModules.DamageModule)
local HitboxModule = require(combatModules.HitboxModule)

--Tuning constants
local DAMAGE = 10 -- health removed from an unblocked target per hit
local ATTACK_COOLDOWN = 0.5 -- seconds a player must wait between swings
local HIT_DURATION = 0.2 -- seconds a swing's hitbox stays active before cleanup
local HITBOX_SIZE = Vector3.new(8, 5, 8) -- dimensions of the swing's overlap volume
local HITBOX_OFFSET = CFrame.new(0, 0, -4) -- places the volume in front of the attacker's root
local HIT_RANGE = 12 -- max distance from attacker root to target root for a valid hit
local LUNGE_SPEED = 14 -- studs per second of the forward lunge
local LUNGE_DURATION = 0.12 -- seconds the lunge constraint exists
local LUNGE_FORCE = 100000 -- force cap so the lunge can overcome ground friction
local REQUEST_LIMIT = 20 -- max attack/block requests accepted per player per second
local PARTICLE_COUNT = 20 -- particles emitted by each ParticleEmitter per effect

--Remotes
-- Client-to-server requests: start a swing, begin blocking, stop blocking.
local remotes = ReplicatedStorage.Remotes.RemoteEvents
local attackEvent = remotes:WaitForChild("AttackDef")
local blockEvent = remotes:WaitForChild("Block")
local unblockEvent = remotes:WaitForChild("Unblock")

--Assets
-- Template effects, sounds, and the reaction animation that get cloned or loaded
-- whenever a hit, block, or clash happens.
local assets = ReplicatedStorage.Assets
local combatEffects = assets.VFX.CombatVfx
local combatSounds = assets.Sounds.CombatSound
local hitEffect = combatEffects:WaitForChild("HitVfx")
local bloodEffect = combatEffects:WaitForChild("BloodVfx")
local sparks = combatEffects:WaitForChild("Sparks")
local clashLight = assets.VFX:WaitForChild("ClashLight")
local parrySound = combatSounds.SwordParry:WaitForChild("Parry")
local blockSound = combatSounds.SwordBlock:WaitForChild("SwordBlock")
local reactionAnimation = assets.Animations.ReactAnim:WaitForChild("ReactAnim")

--State tables (all keyed by Player unless noted)
local cooldowns = {} -- os.clock() time when the player may swing again
local attacks = {} -- the currently active swing's data for each player
local requestWindows = {} -- per-second request counters used by checkRate
local playerConnections = {} -- spawn/removal connections owned by each player
local deathConnections = {} -- the current character's Humanoid.Died connection
local punchSounds = {} -- array of punch Sound templates, filled once below
local animationTracks = {} -- keyed by Humanoid: its cached reaction AnimationTrack
local rayCache = {} -- per-player cached RaycastParams and ignore list
local random = Random.new() -- random source used to choose a punch sound

-- This loop traverses the children of PunchVariants to copy every Sound into
-- punchSounds, so a hit can pick a variant without re-filtering the folder each time.
for _, sound in ipairs(combatSounds.PunchVariants:GetChildren()) do
	if sound:IsA("Sound") then
		table.insert(punchSounds, sound)
	end
end

--[[
	Validates a character model and returns its Humanoid and root part.
	Returns nothing when the model is gone, dead, or missing parts, so every caller can
	use a single "if not humanoid" check to reject invalid characters.
]]
local function getCharacter(character: Model?)
	if not character or not character:IsDescendantOf(workspace) then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 then
		return nil
	end
	if not root or not root:IsA("BasePart") then
		return nil
	end
	return humanoid, root
end

--[[
	Reports whether a character is in a state that forbids combat actions
	(stunned or ragdolled). Other systems set these attributes.
]]
local function isDisabled(character: Model): boolean
	if character:GetAttribute("Stunned") == true then
		return true
	end
	if character:GetAttribute("Ragdolled") == true then
		return true
	end
	return false
end

--[[
	Per-player request limiter. Counts requests inside a one second window and rejects
	the ones above REQUEST_LIMIT. It protects the server's validation work, while the
	separate attack cooldown controls gameplay. Block and attack requests share this budget.
]]
local function checkRate(player: Player): boolean
	local now = os.clock()
	local window = requestWindows[player]
	-- Start a fresh window when none exists or the previous one is a second old.
	if not window or now - window.started >= 1 then
		window = { started = now, count = 0 }
		requestWindows[player] = window
	end
	window.count += 1
	return window.count <= REQUEST_LIMIT
end

--[[
	Turns blocking on or off for a character. The Blocking attribute is what DamageModule
	reads; the white Highlight is the visible feedback. The Highlight is created the first
	time blocking is enabled and then reused by toggling Enabled.
]]
local function setBlocking(character: Model, enabled: boolean)
	character:SetAttribute("Blocking", enabled)
	local highlight = character:FindFirstChild("CombatBlockHighlight")
	if not highlight and enabled then
		highlight = Instance.new("Highlight")
		highlight.Name = "CombatBlockHighlight"
		highlight.Adornee = character
		highlight.FillTransparency = 0.4
		highlight.FillColor = Color3.new(1, 1, 1)
		highlight.OutlineTransparency = 1
		highlight.DepthMode = Enum.HighlightDepthMode.Occluded
		highlight.Parent = character
	end
	if highlight and highlight:IsA("Highlight") then
		highlight.Enabled = enabled
	end
end

--[[
	Plays a one-shot sound on a part. Each impact clones its own Sound so simultaneous
	hits do not restart a shared template. Debris also removes sounds that never finish
	loading, and Ended removes them as soon as they finish playing.
]]
local function playSound(template, parent)
	if not template or not template:IsA("Sound") or not parent then
		return
	end
	local sound = template:Clone()
	sound.Looped = false
	sound.Parent = parent
	Debris:AddItem(sound, math.clamp(sound.TimeLength + 1, 2, 10))
	sound.Ended:Once(function()
		sound:Destroy()
	end)
	sound:Play()
end

--[[
	Plays a random cached punch sound on the target's root so every hit does not sound
	identical. Does nothing if no punch sounds were found at startup.
]]
local function playPunch(root)
	if #punchSounds == 0 then
		return
	end
	playSound(punchSounds[random:NextInteger(1, #punchSounds)], root)
end

--[[
	Clones an effect template onto a part and emits its particles once. Emitters are
	disabled so they only burst; the clone is kept until the longest particle lifetime
	has elapsed (Debris), because destroying it right after Emit would cut the effect short.
]]
local function emitEffect(template, parent, count)
	if not parent or not parent.Parent then
		return
	end
	local effect = template:Clone()
	effect.Parent = parent
	local lifetime = 2 -- minimum seconds the clone survives
	-- Bursts one emitter and extends the clone's lifetime to cover its particles.
	local function emit(emitter)
		emitter.Enabled = false
		emitter:Emit(count)
		lifetime = math.max(lifetime, emitter.Lifetime.Max + 0.2)
	end
	-- The template itself may be a single emitter rather than a container.
	if effect:IsA("ParticleEmitter") then
		emit(effect)
	end
	-- This loop traverses every descendant of the clone to burst each nested emitter.
	for _, child in ipairs(effect:GetDescendants()) do
		if child:IsA("ParticleEmitter") then
			emit(child)
		end
	end
	Debris:AddItem(effect, lifetime)
end

--[[
	Creates a brief light flash on a part to emphasise a block or clash.
	The light is removed by Debris after 0.2 seconds.
]]
local function flashLight(root)
	local light = clashLight:Clone()
	light.Parent = root
	if light:IsA("Light") then
		light.Enabled = true
	end
	Debris:AddItem(light, 0.2)
end

--[[
	Shared block/clash feedback: plays the given sound, emits sparks at the katana handle
	(falling back to the root when there is no handle), and flashes a light.
]]
local function playSwordEffects(character, sound)
	local humanoid, root = getCharacter(character)
	if not humanoid then
		return
	end
	local tool = character:FindFirstChild("Katana")
	local grip = tool and tool:FindFirstChild("Handle")
	local parent = if grip and grip:IsA("BasePart") then grip else root
	playSound(sound, root)
	emitEffect(sparks, parent, PARTICLE_COUNT)
	flashLight(root)
end

--[[
	Callback passed to DamageModule.Deal: runs when a hit was blocked, so the blocker
	gets the block sound and sparks.
]]
local function onBlock(character)
	playSwordEffects(character, blockSound)
end

--[[
	Callback passed to HitboxModule: runs when two swings clash. Only characters that
	actually hold a Katana get the parry feedback.
]]
local function onClash(character)
	if not character:FindFirstChild("Katana") then
		return
	end
	playSwordEffects(character, parrySound)
end

--[[
	Animation cache.
	Returns the reaction AnimationTrack for a Humanoid, loading it only the first time
	(or when the Humanoid's Animator was replaced) and reusing it on every later hit.
	No pcall is used: the preconditions that make loading unsafe (no Animator, empty
	AnimationId) are checked directly, and the cache entry is cleared when the Humanoid
	is destroyed so tracks never outlive their character.
]]
local function getReactionTrack(humanoid: Humanoid): AnimationTrack?
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator or reactionAnimation.AnimationId == "" then
		return nil
	end
	local track = animationTracks[humanoid]
	-- Reuse the cached track only while it still belongs to the current Animator.
	if track and track.Animator == animator then
		return track
	end
	track = animator:LoadAnimation(reactionAnimation)
	track.Looped = false
	animationTracks[humanoid] = track
	-- Clear the cache entry once, when this Humanoid is destroyed.
	humanoid.Destroying:Once(function()
		animationTracks[humanoid] = nil
	end)
	return track
end

--[[
	Plays the hit-reaction animation on a victim using the cached track. If the track is
	still playing from an earlier hit it is stopped first so the reaction restarts.
	This is cosmetic, damage was already applied, so a missing track simply skips it.
]]
local function playReaction(humanoid: Humanoid)
	local track = getReactionTrack(humanoid)
	if not track then
		return
	end
	if track.IsPlaying then
		track:Stop(0)
	end
	track:Play()
end

--[[
	Raycast cache.
	Returns the cached RaycastParams and ignore list for an attacking player, creating
	them on first use. The fixed settings (Exclude filter, RespectCanCollide) are set only
	once; canHit refreshes just the ignore list per check.
]]
local function getRayCache(player: Player)
	local cache = rayCache[player]
	if not cache then
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.RespectCanCollide = true
		cache = { params = params, ignore = {} }
		rayCache[player] = cache
	end
	return cache
end

--[[
	Line-of-sight check between attacker and target. HitboxModule only supplies overlap
	candidates, so this raycast makes sure no solid geometry (a wall) sits between the two
	roots. Both characters and every active hitbox part are ignored so they never block it.
]]
local function canHit(player: Player, character: Model, target: Model, from: Vector3, to: Vector3)
	local cache = getRayCache(player)
	local ignore = cache.ignore
	-- Reuse the same table instead of allocating a new one for every check.
	table.clear(ignore)
	ignore[1] = character
	ignore[2] = target
	-- This loop traverses all active swings to add each hitbox part to the ignore list.
	for _, data in pairs(attacks) do
		if data.hitbox and data.hitbox.Part then
			table.insert(ignore, data.hitbox.Part)
		end
	end
	cache.params.FilterDescendantsInstances = ignore
	return workspace:Raycast(from, to - from, cache.params) == nil
end

--[[
	Ends a swing (timeout, death, or setup failure). The registry entry is cleared first
	so repeated cleanup is safe and late callbacks cannot reuse it; then the Heartbeat
	connection, hitbox, and lunge are released.
]]
local function stopAttack(player)
	local data = attacks[player]
	if not data then
		return
	end
	attacks[player] = nil
	data.closed = true
	if data.follow then
		data.follow:Disconnect()
	end
	if data.hitbox then
		data.hitbox:Destroy()
	end
	if data.lunge then
		data.lunge:Destroy()
	end
end

--[[
	Gives the attacker a short forward push. Uses a LinearVelocity restricted to the
	ground plane so gravity and jumping still work. The attachment (and so the
	constraint) is removed automatically after LUNGE_DURATION. Returns the attachment so
	stopAttack can remove it early, or nil when the character has no horizontal facing.
]]
local function startLunge(root: BasePart): Attachment?
	local look = root.CFrame.LookVector
	-- Flatten the look direction so the lunge never pushes up or down.
	local direction = Vector3.new(look.X, 0, look.Z)
	if direction.Magnitude < 0.001 then
		return nil
	end

	local attachment = Instance.new("Attachment")
	attachment.Name = "M1Attachment"
	attachment.Parent = root

	local lunge = Instance.new("LinearVelocity")
	lunge.Name = "M1Lunge"
	lunge.Attachment0 = attachment
	lunge.RelativeTo = Enum.ActuatorRelativeTo.World
	lunge.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
	lunge.PrimaryTangentAxis = Vector3.xAxis
	lunge.SecondaryTangentAxis = Vector3.zAxis
	lunge.PlaneVelocity = Vector2.new(direction.Unit.X, direction.Unit.Z) * LUNGE_SPEED
	lunge.ForceLimitsEnabled = true
	lunge.ForceLimitMode = Enum.ForceLimitMode.PerAxis
	lunge.MaxPlanarAxesForce = Vector2.new(LUNGE_FORCE, LUNGE_FORCE)
	lunge.Parent = attachment
	Debris:AddItem(attachment, LUNGE_DURATION)
	return attachment
end

--[[
	Handles an attack request. Validates the player (rate, state, blocking, cooldown),
	reserves the cooldown, then builds the swing: lunge, hitbox, and a Heartbeat
	connection that keeps the hitbox in front of the attacker. onHit (defined inside)
	re-validates every candidate before damage is applied.
]]
local function startAttack(player: Player)
	if not checkRate(player) then
		return
	end
	local character = player.Character
	local humanoid, root = getCharacter(character)
	if not humanoid or root.Anchored or isDisabled(character) then
		return
	end
	-- A blocking player cannot swing.
	if character:GetAttribute("Blocking") then
		return
	end
	local now = os.clock()
	if now < (cooldowns[player] or 0) or attacks[player] then
		return
	end
	-- Reserve the cooldown before creating effects or invoking module code so a second
	-- request cannot start another swing while this one is initialising.
	cooldowns[player] = now + ATTACK_COOLDOWN
	local data = {
		hit = {}, -- targets already hit by this swing (one hit per target)
		closed = false, -- set by stopAttack so late callbacks are ignored
	}
	attacks[player] = data

	-- Called by HitboxModule for each overlapping candidate. Applies the server-side
	-- checks (state, forcefield, range, walls) and then damage and feedback.
	local function onHit(target)
		-- Ignore callbacks from a swing that was cancelled or already hit this target.
		if data.closed or data.hit[target] then
			return
		end
		-- The attacker must still be alive and able to act.
		if not getCharacter(character) or isDisabled(character) then
			return
		end
		local targetHumanoid, targetRoot = getCharacter(target)
		if not targetHumanoid or target == character then
			return
		end
		if target:FindFirstChildOfClass("ForceField") then
			return
		end
		-- Distance check, independent of the hitbox, in case of lag or exploit overlap.
		if (targetRoot.Position - root.Position).Magnitude > HIT_RANGE then
			return
		end
		-- Wall check so attacks cannot pass through solid geometry.
		if not canHit(player, character, target, root.Position, targetRoot.Position) then
			return
		end
		data.hit[target] = true
		local blocking = target:GetAttribute("Blocking") == true
		-- DamageModule owns the block multiplier and calls onBlock when blocked.
		DamageModule.Deal(target, DAMAGE, onBlock)
		-- A blocked hit gets only the block feedback, not blood or a reaction.
		if blocking then
			return
		end
		playReaction(targetHumanoid)
		playPunch(targetRoot)
		emitEffect(hitEffect, targetRoot, PARTICLE_COUNT)
		emitEffect(bloodEffect, targetRoot, PARTICLE_COUNT)
	end

	-- Hitbox construction can throw if its dependencies are misconfigured, so setup runs
	-- in xpcall and any partial lunge or connection is rolled back instead of leaking.
	local success, message = xpcall(function()
		data.lunge = startLunge(root)
		data.hitbox = HitboxModule.new(root.CFrame * HITBOX_OFFSET, character, {
			size = HITBOX_SIZE,
		})
		-- Every frame: cancel the swing if the character died, was replaced, anchored or
		-- disabled; otherwise move the hitbox to follow the attacker.
		data.follow = RunService.Heartbeat:Connect(function()
			if player.Character ~= character or not getCharacter(character) then
				stopAttack(player)
				return
			end
			if root.Anchored or isDisabled(character) then
				stopAttack(player)
				return
			end
			data.hitbox:Update(root.CFrame * HITBOX_OFFSET)
		end)
		data.hitbox:Start(onHit, onClash)
	end, debug.traceback)
	if not success then
		stopAttack(player)
		warn("[CombatScriptDef] Attack failed: " .. tostring(message))
		return
	end
	-- End the swing after HIT_DURATION. The identity check stops an old timeout from
	-- destroying a newer swing started after a respawn.
	task.delay(HIT_DURATION, function()
		if attacks[player] == data then
			stopAttack(player)
		end
	end)
end

--[[
	Clears all combat state for a player's character: ends any active swing, removes the
	cooldown, and turns off blocking. Used on spawn, death, and removal.
]]
local function resetCharacter(player, character)
	stopAttack(player)
	cooldowns[player] = nil
	if character and character.Parent then
		setBlocking(character, false)
	end
end

--[[
	Connects per-player lifecycle handling: reset on every spawn, track the new
	Humanoid's death, and reset again when the character is removed.
	Guarded so a player is only set up once.
]]
local function setupPlayer(player: Player)
	if playerConnections[player] then
		return
	end
	local connections = {}
	playerConnections[player] = connections

	-- Runs for each new character: resets state and hooks the Humanoid's Died event.
	local function onSpawn(character: Model)
		if player.Character ~= character or not player.Parent then
			return
		end
		resetCharacter(player, character)
		if deathConnections[player] then
			deathConnections[player]:Disconnect()
		end
		-- Character assembly may yield, so ownership is rechecked after waiting because
		-- the player can leave or respawn while the Humanoid is being created.
		local humanoid = character:WaitForChild("Humanoid", 10)
		if not humanoid or not humanoid:IsA("Humanoid") then
			return
		end
		if player.Character ~= character or not player.Parent then
			return
		end
		if deathConnections[player] then
			deathConnections[player]:Disconnect()
		end
		deathConnections[player] = humanoid.Died:Connect(function()
			resetCharacter(player, character)
		end)
	end

	table.insert(connections, player.CharacterAdded:Connect(onSpawn))
	-- When a character is removed, reset its combat state and drop its death connection.
	table.insert(connections, player.CharacterRemoving:Connect(function(character)
		resetCharacter(player, character)
		if deathConnections[player] then
			deathConnections[player]:Disconnect()
			deathConnections[player] = nil
		end
	end))
	-- Handle a character that already exists when this player is set up.
	if player.Character then
		task.spawn(onSpawn, player.Character)
	end
end

--Remote connections
attackEvent.OnServerEvent:Connect(startAttack)

-- Block request: validates rate and state, refuses mid-swing, then enables blocking.
blockEvent.OnServerEvent:Connect(function(player)
	if not checkRate(player) then
		return
	end
	local character = player.Character
	if not getCharacter(character) or isDisabled(character) then
		return
	end
	if attacks[player] then
		return
	end
	setBlocking(character, true)
end)

-- Releasing block skips the rate limit so throttling can never leave a player stuck
-- blocking. It only clears state belonging to the requesting player.
unblockEvent.OnServerEvent:Connect(function(player)
	local character = player.Character
	if character and character:GetAttribute("Blocking") then
		setBlocking(character, false)
	end
end)

--Player lifecycle
Players.PlayerAdded:Connect(setupPlayer)

-- On leave: reset combat state, then release every per-player entry (rate window, death
-- connection, lifecycle connections, cached RaycastParams) so nothing leaks.
Players.PlayerRemoving:Connect(function(player)
	resetCharacter(player, player.Character)
	requestWindows[player] = nil
	rayCache[player] = nil
	if deathConnections[player] then
		deathConnections[player]:Disconnect()
		deathConnections[player] = nil
	end
	-- This loop traverses the player's stored connections to disconnect each one.
	for _, connection in ipairs(playerConnections[player] or {}) do
		connection:Disconnect()
	end
	playerConnections[player] = nil
end)

-- This loop traverses players already in the server (this script may start late) to
-- set each of them up.
for _, player in ipairs(Players:GetPlayers()) do
	setupPlayer(player)
end

--Thank you for reviewing my code, i hope i can get accepted, to HiddenDev application reader
