--[[
  V — PixelWar: Tactical FPS | aimbot (força ajustável) + wallhack/ESP
  UI      : Rayfield (SiriusSoftwareLtd/Rayfield, interface build UU2NX)
  runtime : Roblox client via Madium 2.0.0
  place   : 71253393019945

  COMO PEGA NO JOGO (levantado por decompile, não inventado):
    * o jogo dirige a câmera em RunService:BindToRenderStep("HopUpCamera",
      RenderPriority.Camera+1) e reconstrói CurrentCamera.CFrame a partir de
      CameraController.yaw / .pitch (radianos, pitch clampado em +-1.5533430342749532).
    * este script escreve yaw/pitch do próprio CameraController em RenderPriority.Camera
      (=200), antes do update do jogo (201) -> o pipeline do jogo consome a rotação.
      Sem briga de CFrame, sem flicker, e o Remotes.AimPitch (unreliable, que o servidor
      acompanha) continua coerente.
    * conversão verificada em runtime (erro < 0.02 grau):
        yaw = atan2(-d.X, -d.Z)   pitch = asin(clamp(d.Y,-1,1))   d = camera.LookVector
    * LOS por raycast no collision group "Shot" do próprio jogo (o mesmo do disparo).
    * tiro = mouse1press/mouse1release (input sintetizado real) -> munição, spread,
      recoil e cooldown do jogo rodam normais. Remoto observado para extensão:
        Remotes.FireShot:FireServer(origem, dirsTabela, seedAmmo, hitsPrevistos, GetServerTimeNow())

  UI: abas Aimbot / Wallhack / Config. Tecla do menu: RightShift (muda em Rayfield > Settings).
  Toda config salva em disco pela própria Rayfield (Rayfield/Configurations/).
]]

-- ============================================================================
-- 0. serviços / refs
-- ============================================================================
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local VIM = game:GetService("VirtualInputManager")
local RS = game:GetService("ReplicatedStorage")

local lp = Players.LocalPlayer
local cam = workspace.CurrentCamera

-- re-execução limpa: se uma instância anterior está viva, ela morre antes desta subir
if getgenv().VW and type(getgenv().VW.unload) == "function" then
	pcall(getgenv().VW.unload)
	task.wait(0.1)
end

local function tryRequire(parent, name)
	local inst = parent and parent:FindFirstChild(name)
	if not inst then return nil end
	local ok, mod = pcall(require, inst)
	if ok then return mod end
	return nil
end

local Controllers = lp:WaitForChild("PlayerScripts"):WaitForChild("Controllers")
local CamCtrl = tryRequire(Controllers, "CameraController")                              -- yaw / pitch / aimCFrame() / aimCf
local WepCtrl = tryRequire(Controllers, "WeaponController")                              -- aimRecoil (recuo somado na mira)
local CollisionGroups = tryRequire(RS:WaitForChild("Modules", 10), "CollisionGroups")    -- SHOT
local SHOT_GROUP = CollisionGroups and CollisionGroups.SHOT or "Shot"

local PITCH_LIMIT = 1.5533430342749532

-- API pública (declarada cedo: botões da UI fecham sobre ela)
local V = {}
local unloaded = false

-- ============================================================================
-- 1. config
-- ============================================================================
local CFG = {
	aim = {
		enabled = false,
		key = "Mouse2",       -- Mouse1 | Mouse2 | nome de KeyCode (LeftAlt, E, Q...)
		hold = true,          -- segura para mirar | toggle
		fov = 90,             -- cone de busca, graus
		strength = 100,       -- % de força: quanto do ângulo restante é puxado por frame
		smooth = 55,          -- % de suavização: 100 = snap, 0 = cola lenta
		part = "Head",        -- Head | Nearest | Torso
		mode = "crosshair",   -- crosshair = mais perto da mira | distance = mais perto
		visibleOnly = false,
		predict = 0.0,        -- lead de movimento, segundos
		maxDist = 600,
		showFov = true,
		autoAds = false,
		teamCheck = true,     -- ignora quem está no mesmo time que você
		compensate = true,    -- desconta recuo/sway/punch somados pelo jogo por cima de yaw/pitch
		noRecoil = false,     -- zera o recuo na origem (câmera não sobe, tiro não sobe)
		trigger = false,
		triggerFov = 3,
		triggerDelay = 0.10,
	},
	wh = {
		enabled = true,
		teamCheck = true,
		box = true,
		name = true,
		dist = true,
		hp = true,
		tracer = false,
		skel = false,
		chams = true,
		chamsFill = 0.55,
		colEnemy = Color3.fromRGB(255, 72, 72),
		colVis = Color3.fromRGB(255, 220, 90),
		targets = true,       -- bonecos do Workspace.Targets
		maxDist = 1200,
	},
	ui = { theme = "Amethyst" },
}

local ACCENT = Color3.fromRGB(0, 230, 170)

-- ============================================================================
-- 2. utilidades
-- ============================================================================
local function clamp(v, a, b) if v < a then return a elseif v > b then return b else return v end end
local TAU = math.pi * 2
local function wrapAngle(a) return (a + math.pi) % TAU - math.pi end

local JOINTS = {
	{ "Head", "UpperTorso" },
	{ "UpperTorso", "LowerTorso" },
	{ "UpperTorso", "LeftUpperArm" }, { "LeftUpperArm", "LeftLowerArm" }, { "LeftLowerArm", "LeftHand" },
	{ "UpperTorso", "RightUpperArm" }, { "RightUpperArm", "RightLowerArm" }, { "RightLowerArm", "RightHand" },
	{ "LowerTorso", "LeftUpperLeg" }, { "LeftUpperLeg", "LeftLowerLeg" }, { "LeftLowerLeg", "LeftFoot" },
	{ "LowerTorso", "RightUpperLeg" }, { "RightUpperLeg", "RightLowerLeg" }, { "RightLowerLeg", "RightFoot" },
}
local AIM_PARTS = {
	"Head", "UpperTorso", "LowerTorso", "HumanoidRootPart",
	"LeftUpperArm", "LeftLowerArm", "RightUpperArm", "RightLowerArm",
	"LeftUpperLeg", "LeftLowerLeg", "RightUpperLeg", "RightLowerLeg",
}

-- team check: com os dois times definidos, quem é do mesmo time sai da lista
local function sameTeam(plr)
	if plr == lp then return true end
	local a, b = plr.Team, lp.Team
	return a ~= nil and b ~= nil and a == b
end

local function isEnemy(plr, teamCheck)
	if plr == lp then return false end
	if teamCheck and sameTeam(plr) then return false end
	return true -- FFA / sem time (confirmado: Team = nil neste jogo): todo mundo é alvo
end

-- input como string: clique chega com KeyCode.Unknown em InputBegan
local function inputId(i)
	if i.UserInputType == Enum.UserInputType.MouseButton1 then return "Mouse1" end
	if i.UserInputType == Enum.UserInputType.MouseButton2 then return "Mouse2" end
	if i.UserInputType == Enum.UserInputType.MouseButton3 then return "Mouse3" end
	if i.UserInputType == Enum.UserInputType.Keyboard and i.KeyCode ~= Enum.KeyCode.Unknown then return i.KeyCode.Name end
	return nil
end
local function inputMatches(id, i) return id ~= nil and id == inputId(i) end

-- modelo com corpo presente: o jogo tem StreamingEnabled (raio 1024), então um
-- personagem pode existir como Model+Humanoid sem nenhuma parte. Sem parte não há
-- o que mirar nem desenhar, então é filtrado aqui.
local function modelHumanoid(m)
	if not m or not m.Parent then return nil end
	if not m:IsDescendantOf(workspace) then return nil end
	local h = m:FindFirstChildOfClass("Humanoid")
	if not h or h.Health <= 0 then return nil end
	local root = h.RootPart or m:FindFirstChild("HumanoidRootPart") or m:FindFirstChild("Head")
	if not root then return nil end
	return h, root
end

local function aliveModels(teamCheck)
	local list = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if isEnemy(p, teamCheck) and p.Character then
			local h, root = modelHumanoid(p.Character)
			if h then list[#list + 1] = { model = p.Character, hum = h, root = root, plr = p } end
		end
	end
	local folder = workspace:FindFirstChild("Targets")
	if folder and CFG.wh.targets then
		for _, m in ipairs(folder:GetChildren()) do
			local h, root = modelHumanoid(m)
			if h then list[#list + 1] = { model = m, hum = h, root = root, plr = nil } end
		end
	end
	return list
end

local losParams = RaycastParams.new()
losParams.FilterType = Enum.RaycastFilterType.Exclude
losParams.CollisionGroup = SHOT_GROUP
losParams.IgnoreWater = true

local function hasLOS(targetModel, toPos)
	local char = lp.Character
	local ignore = {}
	if char then ignore[#ignore + 1] = char end
	ignore[#ignore + 1] = targetModel
	losParams.FilterDescendantsInstances = ignore
	local from = cam.CFrame.Position
	local dir = toPos - from
	local hit = workspace:Raycast(from, dir, losParams)
	if not hit then return true, dir.Magnitude end
	return hit.Distance >= dir.Magnitude - 1.5, hit.Distance
end

local function aimPointFor(entry)
	local m, want = entry.model, CFG.aim.part
	if want == "Torso" then
		return m:FindFirstChild("UpperTorso") or m:FindFirstChild("HumanoidRootPart") or entry.root
	end
	return m:FindFirstChild("Head") or m:FindFirstChild("HumanoidRootPart") or entry.root
end

-- melhor ponto de mira da entrada (respeita Head / Torso / Nearest)
local function evalEntry(entry, look, eye)
	local parts = {}
	if CFG.aim.part == "Nearest" then
		for _, name in ipairs(AIM_PARTS) do
			local p = entry.model:FindFirstChild(name)
			if p and p:IsA("BasePart") then parts[#parts + 1] = p end
		end
	else
		local p = aimPointFor(entry)
		if p and p:IsA("BasePart") then parts[1] = p end
	end

	local best = nil
	for _, p in ipairs(parts) do
		local pos = p.Position
		if CFG.aim.predict > 0 then pos = pos + p.AssemblyLinearVelocity * CFG.aim.predict end
		local delta = pos - eye
		local dist = delta.Magnitude
		if dist <= CFG.aim.maxDist and dist > 1 then
			local angle = math.acos(clamp(look.Unit:Dot(delta.Unit), -1, 1))
			if not best or angle < best.angle then
				best = { part = p, pos = pos, angle = angle, dist = dist }
			end
		end
	end
	return best
end

-- ============================================================================
-- 3. wallhack / ESP (Drawing + Highlight)
-- ============================================================================
local D = {}
local DBG = { records = 0, drawings = 0, visible = 0, highlights = 0 }
local Draw_C = Drawing.new("Circle")
Draw_C.Visible = false
Draw_C.Thickness = 1
Draw_C.Filled = false
Draw_C.NumSides = 72
Draw_C.Color = ACCENT

local function newLine(list)
	local l = Drawing.new("Line")
	l.Thickness = 1
	l.Transparency = 1
	l.Visible = false
	list[#list + 1] = l
	return l
end
local function newText(list)
	local t = Drawing.new("Text")
	t.Size = 13
	t.Center = false
	t.Outline = true
	t.Font = Drawing.Fonts.UI
	t.Visible = false
	list[#list + 1] = t
	return t
end

local function ensureRec(model)
	local rec = D[model]
	if rec then return rec end
	rec = { model = model, lines = {}, texts = {}, skel = {}, hl = nil }
	rec.box = { newLine(rec.lines), newLine(rec.lines), newLine(rec.lines), newLine(rec.lines) }
	rec.hpBg = newLine(rec.lines)
	rec.hpFill = newLine(rec.lines)
	rec.tracer = newLine(rec.lines)
	rec.name = newText(rec.texts)
	rec.dist = newText(rec.texts)
	for i = 1, #JOINTS do rec.skel[i] = newLine(rec.lines) end
	D[model] = rec
	return rec
end

local function hideRec(rec)
	for _, l in ipairs(rec.lines) do l.Visible = false end
	for _, t in ipairs(rec.texts) do t.Visible = false end
	if rec.hl then rec.hl.Enabled = false end
end

local function destroyRec(rec)
	for _, l in ipairs(rec.lines) do l:Remove() end
	for _, t in ipairs(rec.texts) do t:Remove() end
	if rec.hl then rec.hl:Destroy() end
	D[rec.model] = nil
end

local function updateHighlight(rec, on)
	if not CFG.wh.chams then on = false end
	if on then
		if not rec.hl then
			local hl = Instance.new("Highlight")
			hl.Name = "V_WH"
			hl.FillColor = CFG.wh.colEnemy
			hl.FillTransparency = CFG.wh.chamsFill
			hl.OutlineColor = Color3.fromRGB(255, 255, 255)
			hl.OutlineTransparency = 0.15
			hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
			hl.Adornee = rec.model
			hl.Parent = rec.model
			rec.hl = hl
		end
		rec.hl.Enabled = true
		rec.hl.FillTransparency = CFG.wh.chamsFill
		rec.hl.FillColor = CFG.wh.colEnemy
	elseif rec.hl then
		rec.hl.Enabled = false
	end
end

local function partPos(model, name)
	local p = model:FindFirstChild(name)
	if p and p:IsA("BasePart") then return p.Position end
	return nil
end

local function drawESP()
	local seen = {}
	for _, entry in ipairs(aliveModels(CFG.wh.teamCheck)) do
		local model, hum = entry.model, entry.hum
		seen[model] = true
		local rec = ensureRec(model)
		local head = model:FindFirstChild("Head") or model:FindFirstChild("HumanoidRootPart") or entry.root
		local vis = false
		if head then
			if (head.Position - cam.CFrame.Position).Magnitude > CFG.wh.maxDist then
				hideRec(rec)
				continue
			end
			vis = select(1, hasLOS(model, head.Position))
		end

		local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
		local any = false
		for _, name in ipairs(AIM_PARTS) do
			local p = model:FindFirstChild(name)
			if p and p:IsA("BasePart") then
				local sp, onScreen = cam:WorldToViewportPoint(p.Position)
				if onScreen or sp.Z > 0 then
					minX, minY = math.min(minX, sp.X), math.min(minY, sp.Y)
					maxX, maxY = math.max(maxX, sp.X), math.max(maxY, sp.Y)
					any = true
				end
			end
		end

		if not any then
			hideRec(rec)
		else
			local col = vis and CFG.wh.colVis or CFG.wh.colEnemy
			local pad = 3
			minX, minY, maxX, maxY = minX - pad, minY - pad, maxX + pad, maxY + pad
			local tl, tr = Vector2.new(minX, minY), Vector2.new(maxX, minY)
			local bl, br = Vector2.new(minX, maxY), Vector2.new(maxX, maxY)
			local corners = { { tl, tr }, { tr, br }, { br, bl }, { bl, tl } }
			for i = 1, 4 do
				local l = rec.box[i]
				l.Visible = CFG.wh.box
				l.From, l.To, l.Color = corners[i][1], corners[i][2], col
			end

			if CFG.wh.hp then
				local bg, fill = rec.hpBg, rec.hpFill
				bg.Visible, fill.Visible = true, true
				bg.Thickness, fill.Thickness = 3, 3
				bg.Color = Color3.fromRGB(25, 25, 25)
				fill.Color = Color3.fromRGB(70, 230, 110)
				local frac = clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)
				local h = maxY - minY
				local x = minX - 6
				bg.From, bg.To = Vector2.new(x, minY), Vector2.new(x, maxY)
				fill.From = Vector2.new(x, maxY - h * frac)
				fill.To = Vector2.new(x, maxY)
			else
				rec.hpBg.Visible, rec.hpFill.Visible = false, false
			end

			rec.name.Visible = CFG.wh.name
			if CFG.wh.name then
				rec.name.Text = entry.plr and entry.plr.Name or ("[" .. model.Name .. "]")
				rec.name.Position = Vector2.new(minX, minY - 16)
				rec.name.Color = col
			end
			rec.dist.Visible = CFG.wh.dist
			if CFG.wh.dist then
				local d = head and (head.Position - cam.CFrame.Position).Magnitude or 0
				rec.dist.Text = string.format("%d m | %d hp", math.floor(d / 3.571), math.floor(hum.Health))
				rec.dist.Position = Vector2.new(minX, maxY + 2)
				rec.dist.Color = col
			end

			rec.tracer.Visible = CFG.wh.tracer
			if CFG.wh.tracer then
				rec.tracer.Color = col
				rec.tracer.From = Vector2.new(cam.ViewportSize.X / 2, cam.ViewportSize.Y)
				rec.tracer.To = Vector2.new((minX + maxX) / 2, minY)
			end

			for i, j in ipairs(JOINTS) do
				local l = rec.skel[i]
				if CFG.wh.skel then
					local a, b = partPos(model, j[1]), partPos(model, j[2])
					if a and b then
						local sa, sb = cam:WorldToViewportPoint(a), cam:WorldToViewportPoint(b)
						l.Visible = true
						l.Color = col
						l.From, l.To = Vector2.new(sa.X, sa.Y), Vector2.new(sb.X, sb.Y)
					else
						l.Visible = false
					end
				else
					l.Visible = false
				end
			end

			updateHighlight(rec, true)
		end
	end

	for model, rec in pairs(D) do
		if not seen[model] then hideRec(rec) end
		if model.Parent == nil then destroyRec(rec) end
	end

	local vis, tot, nrec, hln = 0, 0, 0, 0
	for _, rec in pairs(D) do
		nrec = nrec + 1
		if rec.hl and rec.hl.Enabled then hln = hln + 1 end
		for _, l in ipairs(rec.lines) do tot = tot + 1 if l.Visible then vis = vis + 1 end end
		for _, t in ipairs(rec.texts) do tot = tot + 1 if t.Visible then vis = vis + 1 end end
	end
	DBG.records, DBG.drawings, DBG.visible, DBG.highlights = nrec, tot, vis, hln
end

-- ============================================================================
-- 4. aimbot
-- ============================================================================
local aimHeld = false
local lastShot = 0
local currentTarget = nil
local adsDown = false

local function pickTarget()
	local best, bestScore = nil, math.huge
	local look, eye = cam.CFrame.LookVector, cam.CFrame.Position
	local halfFov = math.rad(CFG.aim.fov) * 0.5

	for _, entry in ipairs(aliveModels(CFG.aim.teamCheck)) do
		local cand = evalEntry(entry, look, eye)
		if cand and cand.angle <= halfFov then
			local ok = true
			if CFG.aim.visibleOnly then ok = select(1, hasLOS(entry.model, cand.pos)) end
			if ok then
				local score = CFG.aim.mode == "distance" and cand.dist or cand.angle
				if score < bestScore then
					bestScore = score
					best = { entry = entry, part = cand.part, pos = cand.pos, angle = cand.angle }
				end
			end
		end
	end
	return best
end

-- ângulos (yaw/pitch) de um vetor, na convenção do jogo: base = Ry(yaw) * Rx(pitch)
local function anglesOf(v)
	return math.atan2(-v.X, -v.Z), math.asin(clamp(v.Y, -1, 1))
end

-- O jogo soma desvios por cima de yaw/pitch antes de montar o frame de mira:
--   aimCf = base(t.yaw, t.pitch + rad(aimRecoil.X + punch.X + sway))
-- aimCf é esse frame final e fica exposto no módulo, então medir aimCf contra yaw/pitch
-- crus devolve o desvio exato em graus. É ele que sobe a mira durante o spray.
local function aimOffsets()
	if not (CFG.aim.compensate and CamCtrl and CamCtrl.aimCf) then return 0, 0 end
	local ay, ap = anglesOf(CamCtrl.aimCf.LookVector)
	local yw, pt = CamCtrl.yaw, CamCtrl.pitch
	if type(yw) ~= "number" or type(pt) ~= "number" then return 0, 0 end
	return wrapAngle(ay - yw), ap - pt
end

local function applyAim(dt, tgt)
	if not (CamCtrl and tgt) then return end
	local d = tgt.pos - cam.CFrame.Position
	if d.Magnitude < 0.05 then return end
	d = d.Unit

	-- desconta o desvio que o jogo vai somar: o frame efetivo (e o tiro) cai no corpo
	local offYaw, offPitch = aimOffsets()
	local wantYaw = math.atan2(-d.X, -d.Z) - offYaw
	local wantPitch = clamp(math.asin(clamp(d.Y, -1, 1)) - offPitch, -PITCH_LIMIT, PITCH_LIMIT)

	local strength = clamp(CFG.aim.strength / 100, 0.01, 1)
	local rate = 1 + (clamp(CFG.aim.smooth, 0, 100) / 100) * 39 -- 1..40 por segundo
	local alpha = (1 - math.exp(-dt * rate)) * strength

	local curYaw, curPitch = CamCtrl.yaw, CamCtrl.pitch
	if type(curYaw) ~= "number" or type(curPitch) ~= "number" then return end
	DBG.off = { yaw = math.deg(offYaw), pitch = math.deg(offPitch) }
	DBG.pull = { cur = curYaw, want = wantYaw, alpha = alpha, alvo = tostring(tgt.part) }
	CamCtrl.yaw = curYaw + wrapAngle(wantYaw - curYaw) * alpha
	CamCtrl.pitch = clamp(curPitch + (wantPitch - curPitch) * alpha, -PITCH_LIMIT, PITCH_LIMIT)
	DBG.pull.set = CamCtrl.yaw
end

local function fireShot()
	if os.clock() - lastShot < CFG.aim.triggerDelay then return end
	lastShot = os.clock()
	local ok = pcall(function() mouse1press() end)
	task.delay(0.03, function() pcall(function() mouse1release() end) end)
	if not ok then
		pcall(function() VIM:SendMouseButtonEvent(0, 0, 0, true, game, 1) end)
		task.delay(0.03, function() pcall(function() VIM:SendMouseButtonEvent(0, 0, 0, false, game, 1) end) end)
	end
end

local function setAds(on)
	if not CFG.aim.autoAds then on = false end
	if on == adsDown then return end
	adsDown = on
	pcall(function() if on then mouse2press() else mouse2release() end end)
end

-- ============================================================================
-- 4b. sem recuo — corta o kick na origem e zera o acúmulo da mira
-- ============================================================================
-- Decompilado do CameraController (build em RenderPriority.Camera+1):
--   v232 = clamp(t.pitch + math.rad(aimRecoil.X + v235 + punch.X), +-1.5533430342749532)
--   v200 = t.yaw + math.rad(aimRecoil.Y + v243 + punch.Y)
--   aimCf = CFrame.new(eye) * Angles(0, v200, 0) * Angles(v232, 0, 0)
-- ou seja: aimRecoil (graus, escrito pelo WeaponController a cada disparo) e punch (mola
-- alimentada por addKick/addShake) entram somados em cima de yaw/pitch. Neutralizar essas
-- entradas deixa a câmera parada e a mira sem subida, sem tocar no tiro em si.
local CC_ORIG = {
	addKick = CamCtrl and CamCtrl.addKick,
	addShake = CamCtrl and CamCtrl.addShake,
	addWorldShake = CamCtrl and CamCtrl.addWorldShake,
	addFlinch = CamCtrl and CamCtrl.addFlinch,
	hitJolt = CamCtrl and CamCtrl.hitJolt,
}
local noRecoilAtivo = false

local function aplicarSemRecuo(on)
	if not CamCtrl then return end
	on = on and true or false
	if noRecoilAtivo == on then return end
	noRecoilAtivo = on
	if on then
		CamCtrl.addKick = function() end
		CamCtrl.addShake = function() end
		CamCtrl.addWorldShake = function() end
		CamCtrl.addFlinch = function() end
		CamCtrl.hitJolt = function() end
	else
		for nome, fn in pairs(CC_ORIG) do
			if fn then CamCtrl[nome] = fn end
		end
	end
	if WepCtrl then WepCtrl.aimRecoil = Vector2.zero end
end

-- roda antes do build da câmera (Camera+0) e depois (Camera+2): o acúmulo do tiro nunca
-- chega no frame seguinte com valor vivo
local function manterSemRecuo()
	if CFG.aim.noRecoil and WepCtrl then
		WepCtrl.aimRecoil = Vector2.zero
	end
end

local function aimStep(dt)
	manterSemRecuo()
	local tgt = nil
	if CFG.aim.enabled and aimHeld then
		tgt = pickTarget()
		if tgt then applyAim(dt, tgt) end
	end
	currentTarget = tgt

	if CFG.aim.trigger and tgt then
		local tol = math.rad(CFG.aim.triggerFov) * 0.5
		local vis = select(1, hasLOS(tgt.entry.model, tgt.part.Position))
		if tgt.angle <= tol and (vis or not CFG.aim.visibleOnly) then fireShot() end
	end
	setAds(tgt ~= nil)

	if CFG.aim.showFov and CFG.aim.enabled and aimHeld then
		local half = math.rad(CFG.aim.fov) * 0.5
		local h = cam.ViewportSize.Y
		Draw_C.Radius = (h * 0.5) * math.tan(half) / math.tan(math.rad(cam.FieldOfView) * 0.5)
		Draw_C.Position = Vector2.new(cam.ViewportSize.X / 2, h / 2)
		Draw_C.Color = currentTarget and CFG.wh.colVis or ACCENT
		Draw_C.Visible = true
	else
		Draw_C.Visible = false
	end
end

-- ============================================================================
-- 5. UI — Rayfield (carrega de Rayfield.lua em cache, senão do loader oficial)
-- ============================================================================
getgenv().RAYFIELD_ANALYTICS = false -- sem telemetria da lib

local function loadRayfield()
	if isfile and isfile("Rayfield.lua") then
		local ok, lib = pcall(function() return loadstring(readfile("Rayfield.lua"))() end)
		if ok and type(lib) == "table" and lib.CreateWindow then return lib end
	end
	local src = game:HttpGet("https://sirius.menu/rayfield")
	if writefile then pcall(writefile, "Rayfield.lua", src) end
	return loadstring(src)()
end

local Rayfield = loadRayfield()

local Window = Rayfield:CreateWindow({
	Name = "V | PixelWar",
	LoadingTitle = "V carrier",
	LoadingSubtitle = "aimbot + wallhack",
	Theme = CFG.ui.theme,
	ConfigurationSaving = { Enabled = true, FolderName = "V-PixelWar", FileName = "vw" },
	KeySystem = false,
	ToggleUIKeybind = Enum.KeyCode.RightShift, -- a lib upper() a string e quebra nomes compostos, então vai o EnumItem
	DisableRayfieldPrompts = true,
})

local function notify(title, content)
	Rayfield:Notify({ Title = title, Content = content, Duration = 4 })
end

-- acesso pela consola: VW.rayfield / VW.window
V.rayfield = Rayfield
V.window = Window

-- flags -> CFG (sincroniza o que a config salva restaurou)
local FLAG_SYNC = {}

local TabAim = Window:CreateTab("Aimbot", 0)
TabAim:CreateSection("Mira")

local function flag(name, fn) FLAG_SYNC[name] = fn end

TabAim:CreateToggle({
	Name = "Aimbot ativado",
	CurrentValue = CFG.aim.enabled,
	Flag = "aim_enabled",
	Callback = function(v) CFG.aim.enabled = v end,
})
flag("aim_enabled", function(v) CFG.aim.enabled = v end)

TabAim:CreateDropdown({
	Name = "Tecla de mira",
	Options = { "Mouse1", "Mouse2", "LeftAlt", "LeftControl", "E", "Q", "C", "X", "F", "V" },
	CurrentOption = { CFG.aim.key },
	MultipleOptions = false,
	Flag = "aim_key",
	Callback = function(o) CFG.aim.key = o[1] end,
})
flag("aim_key", function(o) CFG.aim.key = type(o) == "table" and o[1] or o end)

TabAim:CreateToggle({
	Name = "Segurar (hold) — desligado = alterna",
	CurrentValue = CFG.aim.hold,
	Flag = "aim_hold",
	Callback = function(v) CFG.aim.hold = v end,
})
flag("aim_hold", function(v) CFG.aim.hold = v end)

TabAim:CreateDropdown({
	Name = "Ponto de mira",
	Options = { "Head", "Nearest", "Torso" },
	CurrentOption = { CFG.aim.part },
	MultipleOptions = false,
	Flag = "aim_part",
	Callback = function(o) CFG.aim.part = o[1] end,
})
flag("aim_part", function(o) CFG.aim.part = type(o) == "table" and o[1] or o end)

TabAim:CreateDropdown({
	Name = "Escolha de alvo",
	Options = { "crosshair", "distance" },
	CurrentOption = { CFG.aim.mode },
	MultipleOptions = false,
	Flag = "aim_mode",
	Callback = function(o) CFG.aim.mode = o[1] end,
})
flag("aim_mode", function(o) CFG.aim.mode = type(o) == "table" and o[1] or o end)

TabAim:CreateToggle({
	Name = "Ignorar aliados (team check)",
	CurrentValue = CFG.aim.teamCheck,
	Flag = "aim_teamcheck",
	Callback = function(v) CFG.aim.teamCheck = v end,
})
flag("aim_teamcheck", function(v) CFG.aim.teamCheck = v end)

TabAim:CreateSection("Recuo")

TabAim:CreateToggle({
	Name = "Compensar recuo na mira (não sai do corpo)",
	CurrentValue = CFG.aim.compensate,
	Flag = "aim_compensate",
	Callback = function(v) CFG.aim.compensate = v end,
})
flag("aim_compensate", function(v) CFG.aim.compensate = v end)

TabAim:CreateToggle({
	Name = "Sem recuo (câmera e tiro parados)",
	CurrentValue = CFG.aim.noRecoil,
	Flag = "aim_norecoil",
	Callback = function(v)
		CFG.aim.noRecoil = v
		aplicarSemRecuo(v)
	end,
})
flag("aim_norecoil", function(v)
	CFG.aim.noRecoil = v
	aplicarSemRecuo(v)
end)

TabAim:CreateSection("Ajuste")

TabAim:CreateSlider({
	Name = "FOV",
	Range = { 5, 360 },
	Increment = 1,
	Suffix = "graus",
	CurrentValue = CFG.aim.fov,
	Flag = "aim_fov",
	Callback = function(v) CFG.aim.fov = v end,
})
flag("aim_fov", function(v) CFG.aim.fov = v end)

TabAim:CreateSlider({
	Name = "Força (quanto puxa por frame)",
	Range = { 1, 100 },
	Increment = 1,
	Suffix = "%",
	CurrentValue = CFG.aim.strength,
	Flag = "aim_strength",
	Callback = function(v) CFG.aim.strength = v end,
})
flag("aim_strength", function(v) CFG.aim.strength = v end)

TabAim:CreateSlider({
	Name = "Suavização (100 = snap)",
	Range = { 0, 100 },
	Increment = 1,
	Suffix = "%",
	CurrentValue = CFG.aim.smooth,
	Flag = "aim_smooth",
	Callback = function(v) CFG.aim.smooth = v end,
})
flag("aim_smooth", function(v) CFG.aim.smooth = v end)

TabAim:CreateSlider({
	Name = "Lead de movimento",
	Range = { 0, 0.3 },
	Increment = 0.01,
	Suffix = "s",
	CurrentValue = CFG.aim.predict,
	Flag = "aim_predict",
	Callback = function(v) CFG.aim.predict = v end,
})
flag("aim_predict", function(v) CFG.aim.predict = v end)

TabAim:CreateSlider({
	Name = "Distância máxima",
	Range = { 50, 2000 },
	Increment = 10,
	Suffix = "studs",
	CurrentValue = CFG.aim.maxDist,
	Flag = "aim_maxdist",
	Callback = function(v) CFG.aim.maxDist = v end,
})
flag("aim_maxdist", function(v) CFG.aim.maxDist = v end)

TabAim:CreateSection("Extras")

TabAim:CreateToggle({
	Name = "Só mirar com linha de visão",
	CurrentValue = CFG.aim.visibleOnly,
	Flag = "aim_los",
	Callback = function(v) CFG.aim.visibleOnly = v end,
})
flag("aim_los", function(v) CFG.aim.visibleOnly = v end)

TabAim:CreateToggle({
	Name = "ADS automático (segura o direito)",
	CurrentValue = CFG.aim.autoAds,
	Flag = "aim_ads",
	Callback = function(v) CFG.aim.autoAds = v end,
})
flag("aim_ads", function(v) CFG.aim.autoAds = v end)

TabAim:CreateToggle({
	Name = "Desenhar círculo do FOV",
	CurrentValue = CFG.aim.showFov,
	Flag = "aim_showfov",
	Callback = function(v) CFG.aim.showFov = v end,
})
flag("aim_showfov", function(v) CFG.aim.showFov = v end)

TabAim:CreateSection("Triggerbot")

TabAim:CreateToggle({
	Name = "Triggerbot ativado",
	CurrentValue = CFG.aim.trigger,
	Flag = "trig_on",
	Callback = function(v) CFG.aim.trigger = v end,
})
flag("trig_on", function(v) CFG.aim.trigger = v end)

TabAim:CreateSlider({
	Name = "Tolerância do gatilho",
	Range = { 0.5, 15 },
	Increment = 0.5,
	Suffix = "graus",
	CurrentValue = CFG.aim.triggerFov,
	Flag = "trig_fov",
	Callback = function(v) CFG.aim.triggerFov = v end,
})
flag("trig_fov", function(v) CFG.aim.triggerFov = v end)

TabAim:CreateSlider({
	Name = "Delay entre disparos",
	Range = { 0.02, 0.5 },
	Increment = 0.01,
	Suffix = "s",
	CurrentValue = CFG.aim.triggerDelay,
	Flag = "trig_delay",
	Callback = function(v) CFG.aim.triggerDelay = v end,
})
flag("trig_delay", function(v) CFG.aim.triggerDelay = v end)

-- ---- WALLHACK
local TabWH = Window:CreateTab("Wallhack", 0)
TabWH:CreateSection("Ativo")

TabWH:CreateToggle({
	Name = "ESP ativado",
	CurrentValue = CFG.wh.enabled,
	Flag = "wh_enabled",
	Callback = function(v) CFG.wh.enabled = v end,
})
flag("wh_enabled", function(v) CFG.wh.enabled = v end)

TabWH:CreateToggle({
	Name = "Ignorar aliados (team check)",
	CurrentValue = CFG.wh.teamCheck,
	Flag = "wh_teamcheck",
	Callback = function(v) CFG.wh.teamCheck = v end,
})
flag("wh_teamcheck", function(v) CFG.wh.teamCheck = v end)

TabWH:CreateToggle({
	Name = "Caixa",
	CurrentValue = CFG.wh.box,
	Flag = "wh_box",
	Callback = function(v) CFG.wh.box = v end,
})
flag("wh_box", function(v) CFG.wh.box = v end)

TabWH:CreateToggle({
	Name = "Nome",
	CurrentValue = CFG.wh.name,
	Flag = "wh_name",
	Callback = function(v) CFG.wh.name = v end,
})
flag("wh_name", function(v) CFG.wh.name = v end)

TabWH:CreateToggle({
	Name = "Distância / vida",
	CurrentValue = CFG.wh.dist,
	Flag = "wh_dist",
	Callback = function(v) CFG.wh.dist = v end,
})
flag("wh_dist", function(v) CFG.wh.dist = v end)

TabWH:CreateToggle({
	Name = "Barra de vida",
	CurrentValue = CFG.wh.hp,
	Flag = "wh_hp",
	Callback = function(v) CFG.wh.hp = v end,
})
flag("wh_hp", function(v) CFG.wh.hp = v end)

TabWH:CreateToggle({
	Name = "Tracejante",
	CurrentValue = CFG.wh.tracer,
	Flag = "wh_tracer",
	Callback = function(v) CFG.wh.tracer = v end,
})
flag("wh_tracer", function(v) CFG.wh.tracer = v end)

TabWH:CreateToggle({
	Name = "Esqueleto (R15)",
	CurrentValue = CFG.wh.skel,
	Flag = "wh_skel",
	Callback = function(v) CFG.wh.skel = v end,
})
flag("wh_skel", function(v) CFG.wh.skel = v end)

TabWH:CreateSection("Chams")

TabWH:CreateToggle({
	Name = "Chams (highlight atravessa parede)",
	CurrentValue = CFG.wh.chams,
	Flag = "wh_chams",
	Callback = function(v) CFG.wh.chams = v end,
})
flag("wh_chams", function(v) CFG.wh.chams = v end)

TabWH:CreateSlider({
	Name = "Opacidade do chams",
	Range = { 0, 0.95 },
	Increment = 0.05,
	Suffix = "alpha",
	CurrentValue = CFG.wh.chamsFill,
	Flag = "wh_chamsfill",
	Callback = function(v) CFG.wh.chamsFill = v end,
})
flag("wh_chamsfill", function(v) CFG.wh.chamsFill = v end)

TabWH:CreateSection("Alcance e cor")

TabWH:CreateSlider({
	Name = "Distância máxima do ESP",
	Range = { 100, 2000 },
	Increment = 25,
	Suffix = "studs",
	CurrentValue = CFG.wh.maxDist,
	Flag = "wh_maxdist",
	Callback = function(v) CFG.wh.maxDist = v end,
})
flag("wh_maxdist", function(v) CFG.wh.maxDist = v end)

TabWH:CreateToggle({
	Name = "Incluir bonecos do range",
	CurrentValue = CFG.wh.targets,
	Flag = "wh_targets",
	Callback = function(v) CFG.wh.targets = v end,
})
flag("wh_targets", function(v) CFG.wh.targets = v end)

TabWH:CreateColorPicker({
	Name = "Cor quando tem parede",
	Color = CFG.wh.colEnemy,
	Flag = "wh_colenemy",
	Callback = function(c) CFG.wh.colEnemy = c end,
})
flag("wh_colenemy", function(c) CFG.wh.colEnemy = c end)

TabWH:CreateColorPicker({
	Name = "Cor quando está visível",
	Color = CFG.wh.colVis,
	Flag = "wh_colvis",
	Callback = function(c) CFG.wh.colVis = c end,
})
flag("wh_colvis", function(c) CFG.wh.colVis = c end)

-- ---- CONFIG
local TabCfg = Window:CreateTab("Config", 0)
TabCfg:CreateSection("Interface")

local themes = {}
for name in pairs(Rayfield.Theme) do themes[#themes + 1] = name end
table.sort(themes)
TabCfg:CreateDropdown({
	Name = "Tema",
	Options = themes,
	CurrentOption = { CFG.ui.theme },
	MultipleOptions = false,
	Flag = "ui_theme",
	Callback = function(o)
		CFG.ui.theme = o[1]
		Window.ModifyTheme(o[1])
	end,
})
flag("ui_theme", function(o)
	local name = type(o) == "table" and o[1] or o
	if Rayfield.Theme[name] then CFG.ui.theme = name end
end)

TabCfg:CreateParagraph({
	Title = "Tecla do menu",
	Content = "RightShift abre/fecha esta janela. Pode trocar em Rayfield > Settings (coluna da esquerda, engrenagem).",
})

TabCfg:CreateSection("Estado")

TabCfg:CreateButton({
	Name = "Imprimir estado no console (F8)",
	Callback = function()
		local g = V.get()
		print(string.format("[V] registros=%d drawings=%d visiveis=%d highlights=%d | alvo=%s ang=%.2f | yaw=%.4f pitch=%.4f | recuo compensado yaw=%.2f pitch=%.2f | semRecuo=%s",
			g.debug.records, g.debug.drawings, g.debug.visible, g.debug.highlights,
			tostring(g.target), g.angle or -1, g.camera.yaw or 0, g.camera.pitch or 0,
			g.debug.off and g.debug.off.yaw or 0, g.debug.off and g.debug.off.pitch or 0, tostring(g.cfg.aim.noRecoil)))
	end,
})

TabCfg:CreateButton({
	Name = "Unload",
	Callback = function() V.unload() end,
})

-- ============================================================================
-- 6. loop / input / unload
-- ============================================================================
local RS_CONN = RunService.RenderStepped:Connect(function()
	if CFG.wh.enabled then
		drawESP()
	else
		for _, rec in pairs(D) do hideRec(rec) end
		Draw_C.Visible = false
	end
end)

-- pull dentro do RenderStep na prioridade da câmera (200) -> antes do update do jogo (201)
RunService:BindToRenderStep("V_Pull", Enum.RenderPriority.Camera.Value, function(dt)
	aimStep(dt)
end)

-- e depois do build da câmera (201), para o recuo não sobreviver até o frame seguinte
RunService:BindToRenderStep("V_NoRecoil", Enum.RenderPriority.Camera.Value + 2, manterSemRecuo)

local function setAimHeld(on)
	if CFG.aim.hold then
		aimHeld = on
	elseif on then
		aimHeld = not aimHeld
	end
end

local inputConn = UIS.InputBegan:Connect(function(i, gpe)
	if gpe then return end
	if CFG.aim.enabled and inputMatches(CFG.aim.key, i) then
		setAimHeld(true)
	end
end)

local releaseConn = UIS.InputEnded:Connect(function(i)
	if CFG.aim.hold and inputMatches(CFG.aim.key, i) then
		aimHeld = false
	end
end)

function V.get()	return {
		cfg = CFG,
		debug = DBG,
		target = currentTarget and (currentTarget.entry.plr and currentTarget.entry.plr.Name or currentTarget.entry.model.Name) or nil,
		angle = currentTarget and math.deg(currentTarget.angle) or nil,
		held = aimHeld,
		records = DBG.records,
		camera = { yaw = CamCtrl and CamCtrl.yaw, pitch = CamCtrl and CamCtrl.pitch },
	}
end

function V.setHeld(on) aimHeld = on and true or false end

-- leitura pura: candidatos ordenados por ângulo, sem tocar na câmera
function V.peek()
	local list = {}
	local look, eye = cam.CFrame.LookVector, cam.CFrame.Position
	local models = aliveModels(false)   -- diagnóstico: mostra todos, sem filtro de time
	DBG.alive = #models
	DBG.semPonto = 0
	for _, e in ipairs(models) do
		local cand = evalEntry(e, look, eye)
		if cand then
			list[#list + 1] = {
				name = e.plr and e.plr.Name or ("[" .. e.model.Name .. "]"),
				angle = math.deg(cand.angle),
				dist = cand.dist,
				hp = e.hum.Health,
				visible = select(1, hasLOS(e.model, cand.pos)),
			}
		else
			DBG.semPonto = DBG.semPonto + 1
		end
	end
	table.sort(list, function(a, b) return a.angle < b.angle end)
	return list
end

-- diagnóstico: expõe a varredura crua
function V.scan(teamCheck) return aliveModels(teamCheck) end

function V.unload()
	if unloaded then return end
	unloaded = true
	pcall(function() RunService:UnbindFromRenderStep("V_Pull") end)
	pcall(function() RunService:UnbindFromRenderStep("V_NoRecoil") end)
	pcall(function() aplicarSemRecuo(false) end)
	pcall(function() RS_CONN:Disconnect() end)
	pcall(function() inputConn:Disconnect() end)
	pcall(function() releaseConn:Disconnect() end)
	pcall(function() setAds(false) end)
	Draw_C.Visible = false
	for _, rec in pairs(D) do destroyRec(rec) end
	pcall(function() Draw_C:Remove() end)
	pcall(function() Rayfield:Destroy() end)
	_G.VW = nil
	getgenv().VW = nil
end

_G.VW = V
getgenv().VW = V

-- aplica o que a config salva restaurou (Rayfield carrega o arquivo depois dos elementos)
task.delay(0.6, function()
	for name, fn in pairs(FLAG_SYNC) do
		local el = Rayfield.Flags[name]
		if el then
			local v = el.CurrentValue
			if v == nil then v = el.CurrentOption end
			if v == nil then v = el.Color end
			if v ~= nil then pcall(fn, v) end
		end
	end
end)

notify("V carregado", "RightShift abre o menu | alvos vivos: " .. #aliveModels(false))

return string.format(
	"V aimbot+wallhack (Rayfield) | CameraController=%s | SHOT=%s | alvos=%d",
	tostring(CamCtrl ~= nil), tostring(SHOT_GROUP), #aliveModels(false)
)
