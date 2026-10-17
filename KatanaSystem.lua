--[[
	KATANA SYSTEM
 	
	this script handles server-authoritative melee requests. the client request an attack or
	block; they never choose a victim, damage amount, or hitbox position. It would be vulnerable to malicious exploiters

	HitboxModule reports overlap candidates and clashes. This script checks
	character state, distance, and walls before DamageModule applies the damage.
	Each swing owns its temporary movement and connections until cleanup.
]]

--services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService")

--Modules
local combatModules = ReplicatedStorage.Shared.CombatModules
local DamageModule = require(combatModules.DamageModule)
local HitboxModule = require(combatModules.HitboxModule)

--Easier variable name for you to read.
local DAMAGE = 10
local ATTACK_COOLDOWN = 0.5
local HIT_DURATION = 0.2
local HITBOX_SIZE = Vector3.new(8, 5, 8)
local HITBOX_OFFSET = CFrame.new(0, 0, -4)
local HIT_RANGE = 12
local LUNGE_SPEED = 14
local LUNGE_DURATION = 0.12
local LUNGE_FORCE = 100000
local REQUEST_LIMIT = 20
local PARTICLE_COUNT = 20

--Remotes
local remotes = ReplicatedStorage.Remotes.RemoteEvents
local attackEvent = remotes:WaitForChild("AttackDef")
local blockEvent = remotes:WaitForChild("Block")
local unblockEvent = remotes:WaitForChild("Unblock")

-Assets
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

--tables
local cooldowns = {}
local attacks = {}
local requestWindows = {}
local playerConnections = {}
local random = Random.new()
local deathConnections = {}
local punchSounds = {}

--these templates are fixed assets. cache them once instead of allocating
--and filtering a new sound list for every successful hit
for _, sound in ipairs(combatSounds.PunchVariants:GetChildren()) do
	if sound:IsA("Sound") then
		table.insert(punchSounds, sound)
	end
end

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

local function isDisabled(character: Model): boolean
	if character:GetAttribute("Stunned") == true then
		return true
	end
	if character:GetAttribute("Ragdolled") == true then
		return true
	end
	return false
end

--the request limit protects validation work, the separate attack cooldown
--controls gameplay. block and attack requests share this server budget
local function checkRate(player: Player): boolean
	local now = os.clock()
	local window = requestWindows[player]
	if not window or now - window.started >= 1 then
		window = { started = now, count = 0 }
		requestWindows[player] = window
	end
	window.count += 1
	return window.count <= REQUEST_LIMIT
end

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

local function playSound(template, parent)
	if not template or not template:IsA("Sound") or not parent then
		return
	end
	--each impact owns its sound so simultanoeous hits do not restart a shared
	--template. debris also removes sounds that never finish loading
	local sound = template:Clone()
	sound.Looped = false
	sound.Parent = parent
	Debris:AddItem(sound, math.clamp(sound.TimeLength + 1, 2, 10))
	sound.Ended:Once(function()
		sound:Destroy()
	end)
	sound:Play()
end

local function playPunch(root)
	if #punchSounds == 0 then
		return
	end
	playSound(punchSounds[random:NextInteger(1, #punchSounds)], root)
end

local function emitEffect(template, parent, count)
	if not parent or not parent.Parent then
		return
	end
	local effect = template:Clone()
	effect.Parent = parent
	--keep the clone alive until its longest particle lifetime has elapse,
	--destroying it immediately after emit would cut the visible effect short
	local lifetime = 2
	local function emit(emitter)
		emitter.Enabled = false
		emitter:Emit(count)
		lifetime = math.max(lifetime, emitter.Lifetime.Max + 0.2)
	end
	if effect:IsA("ParticleEmitter") then
		emit(effect)
	end
	for _, child in ipairs(effect:GetDescendants()) do
		if child:IsA("ParticleEmitter") then
			emit(child)
		end
	end
	Debris:AddItem(effect, lifetime)
end

local function flashLight(root)
	local light = clashLight:Clone()
	light.Parent = root
	if light:IsA("Light") then
		light.Enabled = true
	end
	Debris:AddItem(light, 0.2)
end

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

local function onBlock(character)
	playSwordEffects(character, blockSound)
end

local function onClash(character)
	if not character:FindFirstChild("Katana") then
		return
	end
	playSwordEffects(character, parrySound)
end

local function playReaction(humanoid: Humanoid)
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		return
	end
	--the loading can fail for an unavailable animation asset or any other occasions. damage has already
	-- been applied, so a cosmetic failure must not cancel the attack
	local success, track = pcall(function()
		return animator:LoadAnimation(reactionAnimation)
	end)
	if not success then
		return
	end
	track.Looped = false
	track.Stopped:Once(function()
		track:Destroy()
	end)
	Debris:AddItem(track, 5)
	track:Play()
end

local function canHit(character: Model, target: Model, from: Vector3, to: Vector3)
	local ray = RaycastParams.new()
	ray.FilterType = Enum.RaycastFilterType.Exclude
	--the overlap module supplies candidates, not a proof of an unknown
	--hit. Ignore characters and attack volumes while testing solid geometry
	local ignore = { character, target }
	for _, data in pairs(attacks) do
		if data.hitbox and data.hitbox.Part then
			table.insert(ignore, data.hitbox.Part)
		end
	end
	ray.FilterDescendantsInstances = ignore
	ray.RespectCanCollide = true
	return workspace:Raycast(from, to - from, ray) == nil
end

--[[
	it ends a swing on timeout, death, or loading  failure. clearing the registry
	first makes repeated cleanup safe and prevents callbacks reusing it
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

local function startLunge(root: BasePart): Attachment?
	local look = root.CFrame.LookVector
	local direction = Vector3.new(look.X, 0, look.Z)
	if direction.Magnitude < 0.001 then
		return nil
	end

	local attachment = Instance.new("Attachment")
	attachment.Name = "M1Attachment"
	attachment.Parent = root

	--constrain only the ground so gravity and jumping can still work.
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

local function startAttack(player: Player)
	if not checkRate(player) then
		return
	end
	local character = player.Character
	local humanoid, root = getCharacter(character)
	if not humanoid or root.Anchored or isDisabled(character) then
		return
	end
	if character:GetAttribute("Blocking") then
		return
	end
	local now = os.clock()
	if now < (cooldowns[player] or 0) or attacks[player] then
		return
	end
	-- Reserve the cooldown before creating effects or invoking module code.
	-- A second request must not start another swing during initialization.
	cooldowns[player] = now + ATTACK_COOLDOWN
	local data = {
		hit = {},
		closed = false,
	}
	attacks[player] = data
	local function onHit(target)
		--the module deduplicat overlaps, this guard also declines and reject callbacks
		--from a swing that was canceled by death or character replacement
		if data.closed or data.hit[target] then
			return
		end
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
		if (targetRoot.Position - root.Position).Magnitude > HIT_RANGE then
			return
		end
		if not canHit(character, target, root.Position, targetRoot.Position) then
			return
		end
		data.hit[target] = true
		local blocking = target:GetAttribute("Blocking") == true
		--DamageModule owns the 1/3 block multiplier and block callback
		--return afterward so a blocked hit does not also play blood or reactions
		DamageModule.Deal(target, DAMAGE, onBlock)
		if blocking then
			return
		end
		playReaction(targetHumanoid)
		playPunch(targetRoot)
		emitEffect(hitEffect, targetRoot, PARTICLE_COUNT)
		emitEffect(bloodEffect, targetRoot, PARTICLE_COUNT)
	end

	--hitbox construction can throw if its dependencies are misconfigured.
	--Roll back any partial lunge or connection instead of leaking the swing
	local success, message = xpcall(function()
		data.lunge = startLunge(root)
		data.hitbox = HitboxModule.new(root.CFrame * HITBOX_OFFSET, character, {
			size = HITBOX_SIZE,
		})
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
	task.delay(HIT_DURATION, function()
		-- An old timeout must not destroy a newer swing after a respawn
		if attacks[player] == data then
			stopAttack(player)
		end
	end)
end

local function resetCharacter(player, character)
	stopAttack(player)
	cooldowns[player] = nil
	if character and character.Parent then
		setBlocking(character, false)
	end
end

local function setupPlayer(player: Player)
	if playerConnections[player] then
		return
	end
	local connections = {}
	playerConnections[player] = connections
	local function onSpawn(character: Model)
		if player.Character ~= character or not player.Parent then
			return
		end
		resetCharacter(player, character)
		if deathConnections[player] then
			deathConnections[player]:Disconnect()
		end
		--Character assembly may yield. Recheck ownership afterward because
		--the player can leave or respawn while the Humanoid is being created.
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
	table.insert(connections, player.CharacterRemoving:Connect(function(character)
		resetCharacter(player, character)
		if deathConnections[player] then
			deathConnections[player]:Disconnect()
			deathConnections[player] = nil
		end
	end))
	if player.Character then
		task.spawn(onSpawn, player.Character)
	end
end

attackEvent.OnServerEvent:Connect(startAttack)
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
--releasing block bypasses the rate limit so throttling cannot leave a
--player stuck blocking. It only clears state belonging to that player.
unblockEvent.OnServerEvent:Connect(function(player)
	local character = player.Character
	if character and character:GetAttribute("Blocking") then
		setBlocking(character, false)
	end
end)
Players.PlayerAdded:Connect(setupPlayer)
Players.PlayerRemoving:Connect(function(player)
	resetCharacter(player, player.Character)
	requestWindows[player] = nil
	if deathConnections[player] then
		deathConnections[player]:Disconnect()
		deathConnections[player] = nil
	end
	for _, connection in ipairs(playerConnections[player] or {}) do
		connection:Disconnect()
	end
	playerConnections[player] = nil
end)
for _, player in ipairs(Players:GetPlayers()) do
	setupPlayer(player)
end
