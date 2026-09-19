-- SCRIPTED BY domusthedev. in discord/H4XT3R12 in Roblox!

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")
local runserv = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ModuleLoader = require(Shared.Utilities:WaitForChild("ModuleLoader"))
local Modules = ModuleLoader.Load(Shared:WaitForChild("CombatModules"))
local REM = ReplicatedStorage.Remotes.RemoteEvents:WaitForChild("AttackDef")
local Vfx = ReplicatedStorage.Assets.VFX.CombatVfx:WaitForChild("HitVfx")
local clashLight = ReplicatedStorage.Assets.VFX:WaitForChild("ClashLight")
local parrySound = ReplicatedStorage.Assets.Sounds.CombatSound.SwordParry:WaitForChild("Parry")
local cooldowns: {[Player]: boolean} = {}
local reactAnim = ReplicatedStorage.Assets.Animations.ReactAnim:WaitForChild("ReactAnim")
local blooxvfx = ReplicatedStorage.Assets.VFX.CombatVfx:WaitForChild("BloodVfx")


local BlockSound = ReplicatedStorage.Assets.Sounds.CombatSound.SwordBlock:WaitForChild("SwordBlock")

local Blocking = ReplicatedStorage.Remotes.RemoteEvents:WaitForChild("Block")
local Unblocking = ReplicatedStorage.Remotes.RemoteEvents:WaitForChild("Unblock")

local DamageMod = Modules.DamageModule
local HitboxMod = Modules.HitboxModule

local function randomPunchSound()
	local sounds = ReplicatedStorage.Assets.Sounds.CombatSound.PunchVariants:GetChildren()
	local randomSound = sounds[math.random(1, #sounds)]
	randomSound:Play()
end

--Blocking

local function HighLight(char, mode : boolean)
	local highlight = char:FindFirstChild("Highlight")
	
	if not highlight then
		highlight = Instance.new("Highlight")
		highlight.Parent = char
		highlight.FillTransparency = 0.4
		highlight.FillColor = Color3.new(1, 1, 1)
		highlight.OutlineTransparency = 1
		highlight.OutlineColor = Color3.new(1, 1, 1)
		highlight.DepthMode = Enum.HighlightDepthMode.Occluded
		highlight.Enabled = mode
	end
	highlight.Enabled = mode
end

Blocking.OnServerEvent:Connect(function(plr)
	local char = plr.Character
	
	if not char then 
		return
	end
	
	HighLight(char, true)
	char:SetAttribute("Blocking", true)
	print("blocking")
	
end)

local function onBlock(otherCharacter)
	local rootPart = otherCharacter:FindFirstChild("HumanoidRootPart")

	if not rootPart then
		return
	end

	local sparks = ReplicatedStorage.Assets.VFX.CombatVfx:WaitForChild("Sparks")
	local tool = otherCharacter:FindFirstChild("Katana")
	local handle = tool and tool:FindFirstChild("Handle")

	local sound = BlockSound:Clone()
	local sparkers = sparks:Clone()
	local light = clashLight:Clone()

	sound.Parent = rootPart
	light.Parent = rootPart
	sparkers.Parent = handle or rootPart

	sound:Play()
	light.Enabled = true
	sparkers:Emit(20)

	Debris:AddItem(sound, 1)
	Debris:AddItem(light, 0.2)
	Debris:AddItem(sparkers, 2)
end

Unblocking.OnServerEvent:Connect(function(plr)
	local char = plr.Character

	if not char then 
		return
	end

	HighLight(char, false)
	char:SetAttribute("Blocking", false)
	print("unblocking")

end)



--Main Combat

local function onClash(otherCharacter)
	local rootPart = otherCharacter:FindFirstChild("HumanoidRootPart")
	local sparks = ReplicatedStorage.Assets.VFX.CombatVfx:WaitForChild("Sparks")
	local tool = otherCharacter:FindFirstChild("Katana") 
	
	if not rootPart then
		return
	end
	
	if not tool then
		return
	end

	local sound = parrySound:Clone()
	local sparkers = sparks:Clone()
	sparkers.Parent = tool:WaitForChild("Handle")
	sound.Parent = rootPart
	sound:Play()
	Debris:AddItem(sound, 1)
	local light = clashLight:Clone()
	light.Parent = rootPart
	light.Enabled = true
	sparkers:Emit(20)
	Debris:AddItem(light, 0.2)
end



REM.OnServerEvent:Connect(function(plr)
	local char = plr.Character
	
	if not char then
		return
	end
	
	local rootPart = char:FindFirstChild("HumanoidRootPart")
	
	if not rootPart then
		return
	end
	
	if cooldowns[plr] then
		return
	end
	
	cooldowns[plr] = true
	task.delay(0.5, function()
		cooldowns[plr] = nil
	end)
	
	local lookVector = rootPart.CFrame.LookVector
	local direction = Vector3.new(lookVector.X, 0, lookVector.Z)

	if direction.Magnitude > 0 then
		local lunge = Instance.new("BodyVelocity")
		lunge.Name = "M1Lunge"
		lunge.MaxForce = Vector3.new(100000, 0, 100000)
		lunge.P = 12500
		lunge.Velocity = direction.Unit * 14
		lunge.Parent = rootPart

		Debris:AddItem(lunge, 0.12)
	end

	local attackCFrame = rootPart.CFrame * CFrame.new(0, 0, -4)
	local hitbox = HitboxMod.new(attackCFrame, char, {
		size = Vector3.new(8, 5, 8),
	})

	local followConnection = runserv.Heartbeat:Connect(function()
		if rootPart.Parent then
			hitbox:Update(rootPart.CFrame * CFrame.new(0, 0, -4))
		end
	end)
	local damage = 10
	local function onHit(hitCharacter)
		
		
		local animator = hitCharacter:FindFirstChildOfClass("Humanoid"):FindFirstChildOfClass("Animator")
		if animator then
			local animTrack = animator:LoadAnimation(reactAnim)
			animTrack:Play()
		end
		DamageMod.Deal(hitCharacter, damage, onBlock)
		randomPunchSound()
		local hitvfx = Vfx:Clone()
		local bloodvfx = blooxvfx:Clone()
		hitvfx.Parent = hitCharacter:FindFirstChild("HumanoidRootPart")
		bloodvfx.Parent = hitCharacter:FindFirstChild("HumanoidRootPart")
		bloodvfx:Emit(20)
		hitvfx:Emit(20)
		
		
	end
	hitbox:Start(onHit, onClash)
	task.wait(0.2)
	followConnection:Disconnect()
	hitbox:Destroy()
end)
