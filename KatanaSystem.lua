-- SCRIPTED by H4XT3R12, AKA Domusthedev. In Discord



local players = game:GetService("Players")
local rs = game:GetService("ReplicatedStorage")
local debris = game:GetService("Debris")
local run = game:GetService("RunService")
local shared = rs:WaitForChild("Shared")
local loader = require(shared.Utilities:WaitForChild("ModuleLoader"))
local mods = loader.Load(shared:WaitForChild("CombatModules"))
local remotes = rs.Remotes.RemoteEvents
local attackEvent = remotes:WaitForChild("AttackDef")
local blockEvent = remotes:WaitForChild("Block")
local unblockEvent = remotes:WaitForChild("Unblock")
local assets = rs.Assets
local vfx = assets.VFX.CombatVfx
local sfx = assets.Sounds.CombatSound
local hitfx = vfx:WaitForChild("HitVfx")
local bloodfx = vfx:WaitForChild("BloodVfx")
local sparks = vfx:WaitForChild("Sparks")
local lightfx = assets.VFX:WaitForChild("ClashLight")
local parry = sfx.SwordParry:WaitForChild("Parry")
local blockfx = sfx.SwordBlock:WaitForChild("SwordBlock")
local anim = assets.Animations.ReactAnim:WaitForChild("ReactAnim")
local damageMod = mods.DamageModule
local hitbox = mods.HitboxModule
local damage = 10
local cooldown = 0.5
local duration = 0.2
local size = Vector3.new(8, 5, 8)
local offset = CFrame.new(0, 0, -4)
local range = 12
local cooldowns = {}
local attacks = {}
local rates = {}
local links = {}
local rng = Random.new()
local deaths = {}
local punches = {}

for _, sound in sfx:WaitForChild("PunchVariants"):GetChildren() do
  if sound:IsA("Sound") then
    table.insert(punches, sound)
  end
end

local function getChar(char)
  if not char or not char:IsDescendantOf(workspace) then
    return nil
  end
  local hum = char:FindFirstChildOfClass("Humanoid")
  local root = char:FindFirstChild("HumanoidRootPart")
  if not hum or hum.Health <= 0 then
    return nil
  end
  if not root or not root:IsA("BasePart") then
    return nil
  end
  return hum, root
end

local function isStunned(char)
  if char:GetAttribute("Stunned") == true then
    return true
  end
  if char:GetAttribute("Ragdolled") == true then
    return true
  end
  return false
end

local function checkRate(plr)
  local now = os.clock()
  local window = rates[plr]
  if not window or now - window.started >= 1 then
    window = {started = now, count = 0}
    rates[plr] = window
  end
  window.count += 1
  return window.count <= 20
end

local function setBlock(char, enabled)
  char:SetAttribute("Blocking", enabled)
  local hl = char:FindFirstChild("CombatBlockHighlight")
  if not hl and enabled then
    hl = Instance.new("Highlight")
    hl.Name = "CombatBlockHighlight"
    hl.Adornee = char
    hl.FillTransparency = 0.4
    hl.FillColor = Color3.new(1, 1, 1)
    hl.OutlineTransparency = 1
    hl.DepthMode = Enum.HighlightDepthMode.Occluded
    hl.Parent = char
  end
  if hl and hl:IsA("Highlight") then
    hl.Enabled = enabled
  end
end

local function playSound(src, obj)
  if not src or not src:IsA("Sound") or not obj then
    return
  end
  local sound = src:Clone()
  sound.Looped = false
  sound.Parent = obj
  debris:AddItem(sound, math.clamp(sound.TimeLength + 1, 2, 10))
  sound.Ended:Once(function()
    sound:Destroy()
  end)
  sound:Play()
end

local function playPunch(root)
  if #punches == 0 then
    return
  end
  playSound(punches[rng:NextInteger(1, #punches)], root)
end

local function emitFx(src, obj, count)
  if not obj or not obj.Parent then
    return
  end
  local fx = src:Clone()
  fx.Parent = obj
  local life = 2
  local function emit(e)
    e.Enabled = false
    e:Emit(count)
    life = math.max(life, e.Lifetime.Max + 0.2)
  end
  if fx:IsA("ParticleEmitter") then
    emit(fx)
  end
  for i, v in ipairs(fx:GetDescendants()) do
    if v:IsA("ParticleEmitter") then
      emit(v)
    end
  end
  debris:AddItem(fx, life)
end

local function flashLight(root)
  local light = lightfx:Clone()
  light.Parent = root
  if light:IsA("Light") then
    light.Enabled = true
  end
  debris:AddItem(light, 0.2)
end

local function swordFx(char, sound)
  local hum, root = getChar(char)
  if not hum then
    return
  end
  local tool = char:FindFirstChild("Katana")
  local grip = tool and tool:FindFirstChild("Handle")
  local obj = grip and grip:IsA("BasePart") and grip or root
  playSound(sound, root)
  emitFx(sparks, obj, 20)
  flashLight(root)
end

local function onBlock(char)
  swordFx(char, blockfx)
end

local function onClash(char)
  if not char:FindFirstChild("Katana") then
    return
  end
  swordFx(char, parry)
end

local function react(hum)
  local animator = hum:FindFirstChildOfClass("Animator")
  if not animator then
    return
  end
  local ok, track = pcall(function()
    return animator:LoadAnimation(anim)
  end)
  if not ok then
    return
  end
  track.Looped = false
  track.Stopped:Once(function()
    track:Destroy()
  end)
  debris:AddItem(track, 5)
  track:Play()
end

local function canHit(char, target, from, to)
  local ray = RaycastParams.new()
  ray.FilterType = Enum.RaycastFilterType.Exclude
  local ignore = {char, target}
  for i, data in pairs(attacks) do
    if data.hitbox and data.hitbox.Part then
      table.insert(ignore, data.hitbox.Part)
    end
  end
  ray.FilterDescendantsInstances = ignore
  ray.RespectCanCollide = true
  return workspace:Raycast(from, to - from, ray) == nil
end

local function stopAttack(plr)
  local data = attacks[plr]
  if not data then
    return
  end
  attacks[plr] = nil
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

local function startLunge(root)
  local look = root.CFrame.LookVector
  local dir = Vector3.new(look.X, 0, look.Z)
  if dir.Magnitude < 0.001 then
    return nil
  end

  local attachment = Instance.new("Attachment")
  attachment.Name = "M1Attachment"
  attachment.Parent = root

  -- Constrain only the ground plane so gravity and jumping still work.
  local lunge = Instance.new("LinearVelocity")
  lunge.Name = "M1Lunge"
  lunge.Attachment0 = attachment
  lunge.RelativeTo = Enum.ActuatorRelativeTo.World
  lunge.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
  lunge.PrimaryTangentAxis = Vector3.xAxis
  lunge.SecondaryTangentAxis = Vector3.zAxis
  lunge.PlaneVelocity = Vector2.new(dir.Unit.X, dir.Unit.Z) * 14
  lunge.ForceLimitsEnabled = true
  lunge.ForceLimitMode = Enum.ForceLimitMode.PerAxis
  lunge.MaxPlanarAxesForce = Vector2.new(100000, 100000)
  lunge.Parent = attachment
  debris:AddItem(attachment, 0.12)
  return attachment
end

local function startAttack(plr)
  if not checkRate(plr) then
    return
  end
  local char = plr.Character
  local hum, root = getChar(char)
  if not hum or root.Anchored or isStunned(char) then
    return
  end
  if char:GetAttribute("Blocking") then
    return
  end
  local now = os.clock()
  if now < (cooldowns[plr] or 0) or attacks[plr] then
    return
  end
  cooldowns[plr] = now + cooldown
  local data = {hit = {}, closed = false}
  attacks[plr] = data
  local function onHit(target)
    if data.closed or data.hit[target] then
      return
    end
    if not getChar(char) or isStunned(char) then
      return
    end
    local targetHum, targetRoot = getChar(target)
    if not targetHum or target == char then
      return
    end
    if target:FindFirstChildOfClass("ForceField") then
      return
    end
    if (targetRoot.Position - root.Position).Magnitude > range then
      return
    end
    if not canHit(char, target, root.Position, targetRoot.Position) then
      return
    end
    data.hit[target] = true
    local blocking = target:GetAttribute("Blocking") == true
    damageMod.Deal(target, damage, onBlock)
    if blocking then
      return
    end
    react(targetHum)
    playPunch(targetRoot)
    emitFx(hitfx, targetRoot, 20)
    emitFx(bloodfx, targetRoot, 20)
  end

  local ok, err = xpcall(function()
    data.lunge = startLunge(root)
    data.hitbox = hitbox.new(root.CFrame * offset, char, {size = size})
    data.follow = run.Heartbeat:Connect(function()
      if plr.Character ~= char or not getChar(char) then
        stopAttack(plr)
        return
      end
      if root.Anchored or isStunned(char) then
        stopAttack(plr)
        return
      end
      data.hitbox:Update(root.CFrame * offset)
    end)
    data.hitbox:Start(onHit, onClash)
  end, debug.traceback)
  if not ok then
    stopAttack(plr)
    warn("[CombatScriptDef] Attack failed: " .. tostring(err))
    return
  end
  task.delay(duration, function()
    if attacks[plr] == data then
      stopAttack(plr)
    end
  end)
end

local function reset(plr, char)
  stopAttack(plr)
  cooldowns[plr] = nil
  if char and char.Parent then
    setBlock(char, false)
  end
end

local function setup(plr)
  if links[plr] then
    return
  end
  local conns = {}
  links[plr] = conns
  local function onSpawn(char)
    if plr.Character ~= char or not plr.Parent then
      return
    end
    reset(plr, char)
    if deaths[plr] then
      deaths[plr]:Disconnect()
    end
    local hum = char:WaitForChild("Humanoid", 10)
    if not hum or plr.Character ~= char or not plr.Parent then
      return
    end
    if deaths[plr] then
      deaths[plr]:Disconnect()
    end
    deaths[plr] = hum.Died:Connect(function()
      reset(plr, char)
    end)
  end
  table.insert(conns, plr.CharacterAdded:Connect(onSpawn))
  table.insert(conns, plr.CharacterRemoving:Connect(function(char)
    reset(plr, char)
    if deaths[plr] then
      deaths[plr]:Disconnect()
      deaths[plr] = nil
    end
  end))
  if plr.Character then
    task.spawn(onSpawn, plr.Character)
  end
end

attackEvent.OnServerEvent:Connect(startAttack)
blockEvent.OnServerEvent:Connect(function(plr)
  if not checkRate(plr) then
    return
  end
  local char = plr.Character
  if not getChar(char) or isStunned(char) then
    return
  end
  if attacks[plr] then
    return
  end
  setBlock(char, true)
end)
unblockEvent.OnServerEvent:Connect(function(plr)
  local char = plr.Character
  if char and char:GetAttribute("Blocking") then
    setBlock(char, false)
  end
end)
players.PlayerAdded:Connect(setup)
players.PlayerRemoving:Connect(function(plr)
  reset(plr, plr.Character)
  rates[plr] = nil
  if deaths[plr] then
    deaths[plr]:Disconnect()
    deaths[plr] = nil
  end
  for i, conn in ipairs(links[plr] or {}) do
    conn:Disconnect()
  end
  links[plr] = nil
end)
for i, plr in ipairs(players:GetPlayers()) do
  setup(plr)
end
