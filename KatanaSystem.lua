-- SCRIPTED by H4XT3R12, AKA Domusthedev. In Discord


--!nonstrict

local players = game:GetService("Players")
local rs = game:GetService("ReplicatedStorage")
local debris = game:GetService("Debris")
local run = game:GetService("RunService")
local shared = rs:WaitForChild("Shared")
local loader = require(shared.Utilities:WaitForChild("ModuleLoader"))
local mods = loader.Load(shared:WaitForChild("CombatModules"))
local remotes = rs.Remotes.RemoteEvents
local atk = remotes:WaitForChild("AttackDef")
local blk = remotes:WaitForChild("Block")
local unblk = remotes:WaitForChild("Unblock")
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
local dmg = mods.DamageModule
local hb = mods.HitboxModule
local damage = 10
local delay = 0.5
local duration = 0.2
local size = Vector3.new(8, 5, 8)
local offset = CFrame.new(0, 0, -4)
local range = 12
local cooldowns = {}
local attacks = {}
local rates = {}
local links = {}
local rng = Random.new()

local function getChar(c)
  if not c or not c:IsDescendantOf(workspace) then
    return nil
  end
  local h = c:FindFirstChildOfClass("Humanoid")
  local p = c:FindFirstChild("HumanoidRootPart")
  if not h or h.Health <= 0 then
    return nil
  end
  if not p or not p:IsA("BasePart") then
    return nil
  end
  return h, p
end

local function isStunned(c)
  if c:GetAttribute("Stunned") == true then
    return true
  end
  if c:GetAttribute("Ragdolled") == true then
    return true
  end
  return false
end

local function checkRate(plr)
  local now = os.clock()
  local w = rates[plr]
  if not w or now - w.started >= 1 then
    w = {started = now, count = 0}
    rates[plr] = w
  end
  w.count += 1
  return w.count <= 20
end

local function setBlock(c, enabled)
  c:SetAttribute("Blocking", enabled)
  local hl = c:FindFirstChild("CombatBlockHighlight")
  if not hl and enabled then
    hl = Instance.new("Highlight")
    hl.Name = "CombatBlockHighlight"
    hl.Adornee = c
    hl.FillTransparency = 0.4
    hl.FillColor = Color3.new(1, 1, 1)
    hl.OutlineTransparency = 1
    hl.DepthMode = Enum.HighlightDepthMode.Occluded
    hl.Parent = c
  end
  if hl and hl:IsA("Highlight") then
    hl.Enabled = enabled
  end
end

local function playSound(src, obj)
  if not src or not src:IsA("Sound") or not obj then
    return
  end
  local s = src:Clone()
  s.Looped = false
  s.Parent = obj
  debris:AddItem(s, math.clamp(s.TimeLength + 1, 2, 10))
  s.Ended:Once(function()
    s:Destroy()
  end)
  s:Play()
end

local function playPunch(p)
  local f = sfx:FindFirstChild("PunchVariants")
  if not f then
    return
  end
  local list = {}
  for i, v in ipairs(f:GetChildren()) do
    if v:IsA("Sound") then
      table.insert(list, v)
    end
  end
  if #list == 0 then
    return
  end
  playSound(list[rng:NextInteger(1, #list)], p)
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

local function flashLight(p)
  local l = lightfx:Clone()
  l.Parent = p
  if l:IsA("Light") then
    l.Enabled = true
  end
  debris:AddItem(l, 0.2)
end

local function swordFx(c, s)
  local h, p = getChar(c)
  if not h then
    return
  end
  local tool = c:FindFirstChild("Katana")
  local grip = tool and tool:FindFirstChild("Handle")
  local obj = grip and grip:IsA("BasePart") and grip or p
  playSound(s, p)
  emitFx(sparks, obj, 20)
  flashLight(p)
end

local function onBlock(c)
  swordFx(c, blockfx)
end

local function onClash(c)
  if not c:FindFirstChild("Katana") then
    return
  end
  swordFx(c, parry)
end

local function react(h)
  local a = h:FindFirstChildOfClass("Animator")
  if not a then
    return
  end
  local ok, track = pcall(function()
    return a:LoadAnimation(anim)
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

local function canHit(c, t, from, to)
  local ray = RaycastParams.new()
  ray.FilterType = Enum.RaycastFilterType.Exclude
  local ignore = {c, t}
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

local function startLunge(p)
  local look = p.CFrame.LookVector
  local dir = Vector3.new(look.X, 0, look.Z)
  if dir.Magnitude < 0.001 then
    return nil
  end
  local lunge = Instance.new("BodyVelocity")
  lunge.Name = "M1Lunge"
  lunge.MaxForce = Vector3.new(100000, 0, 100000)
  lunge.P = 12500
  lunge.Velocity = dir.Unit * 14
  lunge.Parent = p
  debris:AddItem(lunge, 0.12)
  return lunge
end

local function startAttack(plr)
  if not checkRate(plr) then
    return
  end
  local c = plr.Character
  local h, p = getChar(c)
  if not h or p.Anchored or isStunned(c) then
    return
  end
  if c:GetAttribute("Blocking") then
    return
  end
  local now = os.clock()
  if now < (cooldowns[plr] or 0) or attacks[plr] then
    return
  end
  cooldowns[plr] = now + delay
  local data = {character = c, hit = {}, closed = false}
  attacks[plr] = data
  local function onHit(t)
    if data.closed or data.hit[t] then
      return
    end
    if not getChar(c) or isStunned(c) then
      return
    end
    local th, tp = getChar(t)
    if not th or t == c then
      return
    end
    if t:FindFirstChildOfClass("ForceField") then
      return
    end
    if (tp.Position - p.Position).Magnitude > range then
      return
    end
    if not canHit(c, t, p.Position, tp.Position) then
      return
    end
    data.hit[t] = true
    local blocking = t:GetAttribute("Blocking") == true
    dmg.Deal(t, damage, onBlock)
    if blocking then
      return
    end
    react(th)
    playPunch(tp)
    emitFx(hitfx, tp, 20)
    emitFx(bloodfx, tp, 20)
  end

  local ok, err = xpcall(function()
    data.lunge = startLunge(p)
    data.hitbox = hb.new(p.CFrame * offset, c, {size = size})
    data.follow = run.Heartbeat:Connect(function()
      if plr.Character ~= c or not getChar(c) then
        stopAttack(plr)
        return
      end
      if p.Anchored or isStunned(c) then
        stopAttack(plr)
        return
      end
      data.hitbox:Update(p.CFrame * offset)
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

local function reset(plr, c)
  stopAttack(plr)
  cooldowns[plr] = nil
  if c and c.Parent then
    setBlock(c, false)
  end
end

local function setup(plr)
  local conns = {}
  links[plr] = conns
  local death
  local function onSpawn(c)
    reset(plr, c)
    if death then
      death:Disconnect()
    end
    local h = c:WaitForChild("Humanoid", 10)
    if not h or plr.Character ~= c or not plr.Parent then
      return
    end
    death = h.Died:Connect(function()
      reset(plr, c)
    end)
  end
  table.insert(conns, plr.CharacterAdded:Connect(onSpawn))
  table.insert(conns, plr.CharacterRemoving:Connect(function(c)
    reset(plr, c)
    if death then
      death:Disconnect()
      death = nil
    end
  end))
  if plr.Character then
    task.spawn(onSpawn, plr.Character)
  end
end

atk.OnServerEvent:Connect(startAttack)
blk.OnServerEvent:Connect(function(plr)
  if not checkRate(plr) then
    return
  end
  local c = plr.Character
  if not getChar(c) or isStunned(c) then
    return
  end
  if attacks[plr] then
    return
  end
  setBlock(c, true)
end)
unblk.OnServerEvent:Connect(function(plr)
  local c = plr.Character
  if c and c:GetAttribute("Blocking") then
    setBlock(c, false)
  end
end)
players.PlayerAdded:Connect(setup)
players.PlayerRemoving:Connect(function(plr)
  reset(plr, plr.Character)
  rates[plr] = nil
  for i, conn in ipairs(links[plr] or {}) do
    conn:Disconnect()
  end
  links[plr] = nil
end)
for i, plr in ipairs(players:GetPlayers()) do
  setup(plr)
end
