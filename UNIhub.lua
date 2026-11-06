-- UNIhub | SAME code in BOTH: a Script (ServerScriptService) AND a LocalScript (StarterPlayerScripts)
--
-- AUTO GUN ADAPTER: the server half scans whatever Tool a player holds and applies the
-- recoil / fire rate / ammo sliders automatically. No gun script changes needed.
-- (It also publishes Player attributes HubRecoil / HubFireRate / HubInfAmmo if you ever
--  want a custom gun script to read them directly.)

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MODS_NAME = "UNIhubMods"

-----------------------------------------------------------------
-- AUTO GUN ADAPTER
-- Looks inside whatever Tool a player is holding, finds the recoil / fire rate / ammo
-- numbers (Values, Attributes, or a ModuleScript inside the Tool) and applies the
-- player's hub settings. No per-gun setup. Only touches that player's own Tool, so
-- other players are not affected. (A config ModuleScript that lives OUTSIDE the Tool,
-- e.g. in ReplicatedStorage, is shared by everyone, so it is deliberately left alone.)
-----------------------------------------------------------------
local function norm(s) return (string.lower(s):gsub("[%s_%-%.]", "")) end
local function anyIn(n, list)
	for _, w in ipairs(list) do
		if string.find(n, w, 1, true) then return true end
	end
	return false
end

local RECOIL = { "recoil", "spread", "kick", "sway", "shake", "bloom" }
local DELAY = { "firerate", "cooldown", "firedelay", "shootdelay", "delay", "interval", "rpm", "timebetween", "firewait", "shootwait", "refire" }
local AMMO = { "ammo", "clip", "magazine", "bullets", "rounds" }
local AMMO_BAD = { "max", "type", "name", "speed", "velocity", "drop", "damage", "size", "per", "pellet", "gravity", "range", "life", "reload", "spread", "recoil", "image", "ground" }

local function classify(name)
	local n = norm(name)
	if anyIn(n, RECOIL) then return "recoil" end
	if anyIn(n, DELAY) then return "delay" end
	if anyIn(n, AMMO) and not anyIn(n, AMMO_BAD) then return "ammo" end
	return nil
end

local function eget(e)
	if e.mode == "val" then return e.obj.Value
	elseif e.mode == "attr" then return e.obj:GetAttribute(e.key) end
	return e.obj[e.key]
end
local function eset(e, x)
	if e.mode == "val" then e.obj.Value = x
	elseif e.mode == "attr" then e.obj:SetAttribute(e.key, x)
	else e.obj[e.key] = x end
end

-- remembers the ORIGINAL value of every field so rescans never mistake our edits for the real numbers
local origs = setmetatable({}, { __mode = "k" })
local function cell(e, cur)
	local t = origs[e.obj]
	if not t then t = {} origs[e.obj] = t end
	local c = t[e.key]
	if not c then c = { orig = cur, max = cur } t[e.key] = c end
	return c
end

local function scanTable(list, tbl, depth, seen)
	if seen[tbl] or depth > 3 then return end
	seen[tbl] = true
	for k, v in pairs(tbl) do
		if type(k) == "string" then
			if type(v) == "number" then
				local kind = classify(k)
				if kind then table.insert(list, { kind = kind, name = k, mode = "tbl", obj = tbl, key = k }) end
			elseif type(v) == "table" then
				scanTable(list, v, depth + 1, seen)
			end
		end
	end
end

local function scanTool(tool)
	local list, seen = {}, {}
	local objs = tool:GetDescendants()
	table.insert(objs, tool)
	for _, inst in ipairs(objs) do
		if inst:IsA("NumberValue") or inst:IsA("IntValue") then
			local kind = classify(inst.Name)
			if kind then table.insert(list, { kind = kind, name = inst.Name, mode = "val", obj = inst, key = "Value" }) end
		elseif inst:IsA("Vector3Value") then
			if classify(inst.Name) == "recoil" then
				table.insert(list, { kind = "recoil", name = inst.Name, mode = "val", obj = inst, key = "Value" })
			end
		elseif inst:IsA("ModuleScript") then
			pcall(function()
				local m = require(inst)
				if type(m) == "table" then scanTable(list, m, 0, seen) end
			end)
		end
		for k, v in pairs(inst:GetAttributes()) do
			local kind = classify(k)
			if kind then
				local tv = typeof(v)
				if tv == "number" or (kind == "recoil" and (tv == "Vector3" or tv == "Vector2")) then
					table.insert(list, { kind = kind, name = k, mode = "attr", obj = inst, key = k })
				end
			end
		end
	end
	return list
end

local function applyMods(mods, entries)
	local rec, rate, inf = mods.rec, mods.rate, mods.inf
	for _, e in ipairs(entries) do
		local ok, cur = pcall(eget, e)
		if ok and cur ~= nil then
			local c = cell(e, cur)
			local target
			if e.kind == "recoil" then
				target = c.orig * rec
			elseif e.kind == "delay" and type(c.orig) == "number" then
				local n = norm(e.name)
				local isRate = string.find(n, "rpm", 1, true) or (string.find(n, "firerate", 1, true) and c.orig >= 1)
				target = isRate and c.orig * rate or c.orig / rate
			elseif e.kind == "ammo" and type(cur) == "number" then
				if cur > c.max then c.max = cur end
				if inf and cur < c.max then target = c.max end
			end
			if target ~= nil and target ~= cur then pcall(eset, e, target) end
		end
	end
end

local function describe(tool, entries)
	local n = { recoil = 0, delay = 0, ammo = 0 }
	for _, e in ipairs(entries) do n[e.kind] += 1 end
	if n.recoil + n.delay + n.ammo == 0 then
		return "Holding: " .. tool.Name .. "\nNothing editable found (stats not stored in the Tool?)"
	end
	return string.format("Holding: %s\nFound  recoil: %d  |  fire rate: %d  |  ammo: %d", tool.Name, n.recoil, n.delay, n.ammo)
end



---------------------------------------------------------------------
-- SERVER SIDE
---------------------------------------------------------------------
if RunService:IsServer() then
	local modsRemote = ReplicatedStorage:FindFirstChild(MODS_NAME)
	if not modsRemote then
		modsRemote = Instance.new("RemoteEvent")
		modsRemote.Name = MODS_NAME
		modsRemote.Parent = ReplicatedStorage
	end

	local function num(v, default)
		v = tonumber(v)
		if not v or v ~= v then return default end
		return v
	end

	modsRemote.OnServerEvent:Connect(function(player, data)
		if type(data) ~= "table" then return end
		player:SetAttribute("HubRecoil", math.clamp(num(data.recoil, 100), 0, 100) / 100)
		player:SetAttribute("HubFireRate", math.clamp(num(data.fireRate, 1), 1, 10))
		player:SetAttribute("HubInfAmmo", data.infAmmo == true)
	end)

	local tracked = {}
	task.spawn(function()
		while true do
			task.wait(0.2)
			for _, player in ipairs(Players:GetPlayers()) do
				local char = player.Character
				local tool = char and char:FindFirstChildOfClass("Tool")
				local t = tracked[player]
				if not tool then
					if t then
						tracked[player] = nil
						player:SetAttribute("HubGunInfo", "No weapon held. Equip one and it is scanned automatically.")
					end
				else
					if not t or t.tool ~= tool or os.clock() - t.at > 5 then
						local entries = scanTool(tool)
						t = { tool = tool, entries = entries, at = os.clock() }
						tracked[player] = t
						player:SetAttribute("HubGunInfo", describe(tool, entries))
					end
					applyMods({
						rec = player:GetAttribute("HubRecoil") or 1,
						rate = player:GetAttribute("HubFireRate") or 1,
						inf = player:GetAttribute("HubInfAmmo") == true,
					}, t.entries)
				end
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(plr)
		tracked[plr] = nil
	end)

	-- tells each client where the server really has their character (root, head, feet)
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < 1 / 20 then return end
		acc = 0
		for _, player in ipairs(Players:GetPlayers()) do
			local char = player.Character
			local root = char and char:FindFirstChild("HumanoidRootPart")
			if root then
				local head = char:FindFirstChild("Head")
				local lf = char:FindFirstChild("LeftFoot") or char:FindFirstChild("Left Leg")
				local rf = char:FindFirstChild("RightFoot") or char:FindFirstChild("Right Leg")
				player:SetAttribute("HubSrvRoot", root.CFrame)
				if head then player:SetAttribute("HubSrvHead", head.CFrame) end
				if lf and rf then
					player:SetAttribute("HubSrvFeet", CFrame.new((lf.Position + rf.Position) / 2) * root.CFrame.Rotation)
				end
			end
		end
	end)
	print("[UNIhub] server ready")
	return
end

---------------------------------------------------------------------
-- CLIENT SIDE
---------------------------------------------------------------------
local Stats = game:GetService("Stats")

local lp = Players.LocalPlayer
local function cam() return workspace.CurrentCamera end

---------------------------------------------------------------------
-- SETTINGS
---------------------------------------------------------------------
local settings = {
	-- ESP
	EspEnabled = true, EspEnemies = true, EspTeam = true, Box = true, Name = true, Distance = true, Health = true,
	Skeleton = true, Fill = true, FillHue = 0.58,
	Arrows = true, ArrowGap = 22, ArrowSize = 22, ArrowVis = true, ArrowHue = 0.0,
	Tracers = true, TracerHue = 0.33, TracerThick = 2, TracerAll = false,
	-- Crosshair
	CrossOn = false, CrossShape = 1, CrossSize = 12, CrossThick = 2, CrossGap = 4, CrossHue = 0.33, CrossRot = 0, CrossOutline = true,
	-- Aimbot
	AimEnabled = false, AimFov = 120, AimHue = 0.0, AimFilled = false, AimSpeed = 50,
	Part_Head = true, Part_Torso = true, Part_LArm = true, Part_RArm = true, Part_LLeg = true, Part_RLeg = true,
	AimWallCheck = true, AimEnemies = true, AimTeammates = false, AimNpcs = true, EspNpcs = true, TpNpcs = true,
	Prediction = false, PredSpeed = 500,
	-- Gunmod
	RecoilOn = false, RecoilPct = 100, FireRateOn = false, FireRateMult = 1, InfAmmo = false,
	-- World
	CustomTime = false, WorldTime = 0, Fullbright = false,
	-- Player
	Spin = false, SpinRps = 2, ShowServer = false, TpButton = false, TpBtnX = 0.5, TpBtnY = 0.8, TpDist = 4,
	LimbChaos = false, LimbSpeed = 1, Bury = false, BuryPct = 60,
	-- Movement
	SpeedOn = false, WalkSpeed = 32, JumpOn = false, JumpPower = 100, InfJump = false,
	Fly = false, FlySpeed = 60, Noclip = false,
	-- Menu
	AccentHue = 0.47, LockButton = false, FabX = 0.01, FabY = 0.5,
}

-- aim zones: lower tier number = higher priority (head > torso > arms > legs)
local ZONES = {
	{ key = "Part_Head",  tier = 1, label = "Head",      names = { "Head" } },
	{ key = "Part_Torso", tier = 2, label = "Torso",     names = { "UpperTorso", "Torso", "LowerTorso" } },
	{ key = "Part_LArm",  tier = 3, label = "Left Arm",  names = { "LeftUpperArm", "LeftLowerArm", "LeftHand", "Left Arm" } },
	{ key = "Part_RArm",  tier = 3, label = "Right Arm", names = { "RightUpperArm", "RightLowerArm", "RightHand", "Right Arm" } },
	{ key = "Part_LLeg",  tier = 4, label = "Left Leg",  names = { "LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "Left Leg" } },
	{ key = "Part_RLeg",  tier = 4, label = "Right Leg", names = { "RightUpperLeg", "RightLowerLeg", "RightFoot", "Right Leg" } },
}

local ACCENT = Color3.fromHSV(settings.AccentHue, 0.85, 1)
local accentFns, refreshers = {}, {}
local function onAccent(fn) table.insert(accentFns, fn) fn() end
local function setAccent(h)
	ACCENT = Color3.fromHSV(h, 0.85, 1)
	for _, f in ipairs(accentFns) do f() end
end
local function hueColor(h) return Color3.fromHSV(h, 1, 1) end

local BG = Color3.fromRGB(9, 9, 14)
local PANEL = Color3.fromRGB(14, 14, 21)
local ROW = Color3.fromRGB(21, 21, 30)
local ROWH = Color3.fromRGB(30, 30, 42)
local TEXT = Color3.fromRGB(228, 228, 240)
local DIM = Color3.fromRGB(120, 120, 140)
local OFF = Color3.fromRGB(40, 40, 55)
local GREEN = Color3.fromRGB(0, 255, 120)
local RED = Color3.fromRGB(255, 50, 80)
local FONT = Enum.Font.GothamMedium
local FONTB = Enum.Font.GothamBold

local function new(class, props)
	local o = Instance.new(class)
	for k, v in pairs(props) do if k ~= "Parent" then o[k] = v end end
	if props.Parent then o.Parent = props.Parent end
	return o
end
local function tw(o, t, p)
	TweenService:Create(o, TweenInfo.new(t, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), p):Play()
end

---------------------------------------------------------------------
-- GUI ROOTS
---------------------------------------------------------------------
local function guiParent()
	local ok, h = pcall(function() return gethui and gethui() end)
	if ok and h then return h end
	return lp:WaitForChild("PlayerGui")
end
local parent = guiParent()
for _, n in ipairs({ "UNIhubMenu", "UNIhubOverlay" }) do
	local old = parent:FindFirstChild(n)
	if old then old:Destroy() end
end

local gui = new("ScreenGui", { Name = "UNIhubMenu", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 100, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, Parent = parent })
local overlay = new("ScreenGui", { Name = "UNIhubOverlay", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = -1, Parent = parent })

---------------------------------------------------------------------
-- NOTIFY
---------------------------------------------------------------------
local toastHolder = new("Frame", { AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -14, 1, -14), Size = UDim2.fromOffset(230, 260), BackgroundTransparency = 1, Parent = gui })
new("UIListLayout", { Padding = UDim.new(0, 6), VerticalAlignment = Enum.VerticalAlignment.Bottom, HorizontalAlignment = Enum.HorizontalAlignment.Right, SortOrder = Enum.SortOrder.LayoutOrder, Parent = toastHolder })
local toastN = 0
local function notify(text, good)
	toastN += 1
	local wrap = new("Frame", { LayoutOrder = toastN, Size = UDim2.new(1, 0, 0, 28), BackgroundTransparency = 1, Parent = toastHolder })
	local card = new("Frame", { Position = UDim2.new(1, 60, 0, 0), Size = UDim2.fromScale(1, 1), BackgroundColor3 = PANEL, BorderSizePixel = 0, Parent = wrap })
	new("UICorner", { CornerRadius = UDim.new(0, 6), Parent = card })
	local st = new("UIStroke", { Thickness = 1, Transparency = 0.4, Color = ACCENT, Parent = card })
	local bar = new("Frame", { Size = UDim2.new(0, 3, 1, 0), BackgroundColor3 = good == false and RED or ACCENT, BorderSizePixel = 0, Parent = card })
	new("UICorner", { CornerRadius = UDim.new(0, 6), Parent = bar })
	new("TextLabel", { Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -16, 1, 0), BackgroundTransparency = 1, Font = FONT, TextSize = 12, TextColor3 = TEXT, TextXAlignment = Enum.TextXAlignment.Left, Text = text, Parent = card })
	tw(card, 0.25, { Position = UDim2.new(0, 0, 0, 0) })
	task.delay(2, function()
		tw(card, 0.25, { Position = UDim2.new(1, 60, 0, 0) })
		task.wait(0.3)
		wrap:Destroy()
	end)
end

---------------------------------------------------------------------
-- WINDOW
---------------------------------------------------------------------
local WW, WH = 580, 390
local window = new("CanvasGroup", { Name = "Window", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(WW, WH), BackgroundColor3 = BG, BorderSizePixel = 0, GroupTransparency = 1, Visible = false, Parent = gui })
new("UICorner", { CornerRadius = UDim.new(0, 10), Parent = window })
local uiScale = new("UIScale", { Scale = 1, Parent = window })
local wStroke = new("UIStroke", { Thickness = 2, Color = Color3.new(1, 1, 1), ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = window })
local wGrad = new("UIGradient", { Parent = wStroke })
onAccent(function()
	wGrad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, ACCENT),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(25, 25, 38)),
		ColorSequenceKeypoint.new(1, ACCENT),
	})
end)

-- VFX: floating particles
local fx = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = 0, Parent = window })
local particles = {}
for i = 1, 22 do
	local s = math.random(2, 4)
	local p = new("Frame", { Size = UDim2.fromOffset(s, s), BackgroundTransparency = math.random(60, 90) / 100, BorderSizePixel = 0, Parent = fx })
	new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = p })
	table.insert(particles, { f = p, x = math.random() * WW, y = math.random() * WH, v = math.random(10, 35), d = math.random() * 6 })
end
onAccent(function() for _, p in ipairs(particles) do p.f.BackgroundColor3 = ACCENT end end)

-- title bar
local titleBar = new("Frame", { Size = UDim2.new(1, 0, 0, 44), BackgroundColor3 = PANEL, BorderSizePixel = 0, Parent = window })
local logoIcon = new("Frame", { Position = UDim2.fromOffset(12, 8), Size = UDim2.fromOffset(28, 28), BorderSizePixel = 0, Parent = titleBar })
new("UICorner", { CornerRadius = UDim.new(0, 7), Parent = logoIcon })
local iconGrad = new("UIGradient", { Rotation = 45, Parent = logoIcon })
new("TextLabel", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Font = FONTB, TextSize = 17, TextColor3 = Color3.new(1, 1, 1), Text = "U", Parent = logoIcon })
local logoText = new("TextLabel", { Position = UDim2.fromOffset(48, 0), Size = UDim2.fromOffset(160, 44), BackgroundTransparency = 1, Font = FONTB, TextSize = 21, RichText = true, TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = TEXT, Text = "", Parent = titleBar })
onAccent(function()
	logoText.Text = string.format('UNI<font color="#%s">hub</font>', ACCENT:ToHex())
	iconGrad.Color = ColorSequence.new(ACCENT, Color3.fromHSV((settings.AccentHue + 0.15) % 1, 0.85, 1))
end)

local statsLbl = new("TextLabel", { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -50, 0, 0), Size = UDim2.fromOffset(160, 44), BackgroundTransparency = 1, Font = FONT, TextSize = 12, TextColor3 = DIM, TextXAlignment = Enum.TextXAlignment.Right, Text = "", Parent = titleBar })
local closeBtn = new("TextButton", { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -4, 0, 4), Size = UDim2.fromOffset(36, 36), BackgroundTransparency = 1, Font = FONTB, TextSize = 15, Text = "X", TextColor3 = DIM, AutoButtonColor = false, Parent = titleBar })
closeBtn.MouseEnter:Connect(function() tw(closeBtn, 0.12, { TextColor3 = RED }) end)
closeBtn.MouseLeave:Connect(function() tw(closeBtn, 0.12, { TextColor3 = DIM }) end)
local line = new("Frame", { Position = UDim2.fromOffset(0, 44), Size = UDim2.new(1, 0, 0, 1), BorderSizePixel = 0, BackgroundTransparency = 0.4, Parent = window })
onAccent(function() line.BackgroundColor3 = ACCENT end)

local sidebar = new("Frame", { Position = UDim2.fromOffset(0, 45), Size = UDim2.new(0, 140, 1, -45), BackgroundColor3 = PANEL, BackgroundTransparency = 0.15, BorderSizePixel = 0, Parent = window })
new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder, Parent = sidebar })
new("UIPadding", { PaddingTop = UDim.new(0, 10), PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8), Parent = sidebar })
local content = new("Frame", { Position = UDim2.fromOffset(140, 45), Size = UDim2.new(1, -140, 1, -45), BackgroundTransparency = 1, Parent = window })

---------------------------------------------------------------------
-- TABS + COMPONENTS
---------------------------------------------------------------------
local tabs, selected, current, order, tabOrder = {}, nil, nil, 0, 0
local function nextOrder() order += 1 return order end

local function selectTab(name)
	selected = name
	for n, t in pairs(tabs) do
		local on = n == name
		t.page.Visible = on
		tw(t.btn, 0.15, { BackgroundTransparency = on and 0.85 or 1, TextColor3 = on and ACCENT or DIM })
		tw(t.ind, 0.2, { Size = UDim2.new(0, 3, 0, on and 18 or 0) })
	end
end

local function addTab(name)
	tabOrder += 1
	order = 0
	local btn = new("TextButton", { LayoutOrder = tabOrder, Size = UDim2.new(1, 0, 0, 34), BackgroundColor3 = ACCENT, BackgroundTransparency = 1, BorderSizePixel = 0, AutoButtonColor = false, Font = FONT, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Left, Text = "    " .. name, TextColor3 = DIM, Parent = sidebar })
	new("UICorner", { CornerRadius = UDim.new(0, 6), Parent = btn })
	local ind = new("Frame", { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 0, 0.5, 0), Size = UDim2.new(0, 3, 0, 0), BorderSizePixel = 0, Parent = btn })
	new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = ind })
	local page = new("ScrollingFrame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 3, Visible = false, Parent = content })
	new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, Parent = page })
	new("UIPadding", { PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 10), PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 14), Parent = page })
	tabs[name] = { btn = btn, ind = ind, page = page }
	onAccent(function()
		ind.BackgroundColor3 = ACCENT
		btn.BackgroundColor3 = ACCENT
		page.ScrollBarImageColor3 = ACCENT
		if selected == name then btn.TextColor3 = ACCENT end
	end)
	btn.MouseEnter:Connect(function() if selected ~= name then tw(btn, 0.12, { TextColor3 = TEXT }) end end)
	btn.MouseLeave:Connect(function() if selected ~= name then tw(btn, 0.12, { TextColor3 = DIM }) end end)
	btn.MouseButton1Click:Connect(function() selectTab(name) end)
	current = page
end

local function makeRow(h)
	local r = new("Frame", { LayoutOrder = nextOrder(), Size = UDim2.new(1, 0, 0, h), BackgroundColor3 = ROW, BorderSizePixel = 0, Parent = current })
	new("UICorner", { CornerRadius = UDim.new(0, 6), Parent = r })
	return r
end
local function hover(row, obj)
	obj.MouseEnter:Connect(function() tw(row, 0.12, { BackgroundColor3 = ROWH }) end)
	obj.MouseLeave:Connect(function() tw(row, 0.12, { BackgroundColor3 = ROW }) end)
end

local function addSection(text)
	local l = new("TextLabel", { LayoutOrder = nextOrder(), Size = UDim2.new(1, 0, 0, 20), BackgroundTransparency = 1, Font = FONTB, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left, Text = string.upper(text), Parent = current })
	onAccent(function() l.TextColor3 = ACCENT end)
end
local function addNote(text)
	return new("TextLabel", { LayoutOrder = nextOrder(), Size = UDim2.new(1, 0, 0, 14), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, Font = FONT, TextSize = 12, TextWrapped = true, TextColor3 = DIM, TextXAlignment = Enum.TextXAlignment.Left, Text = text, Parent = current })
end

local function addToggle(key, label, onChange)
	local row = makeRow(34)
	new("TextLabel", { Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -70, 1, 0), BackgroundTransparency = 1, Font = FONT, TextSize = 14, TextColor3 = TEXT, TextXAlignment = Enum.TextXAlignment.Left, Text = label, Parent = row })
	local track = new("Frame", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, 0), Size = UDim2.fromOffset(40, 20), BackgroundColor3 = OFF, BorderSizePixel = 0, Parent = row })
	new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = track })
	local knob = new("Frame", { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 3, 0.5, 0), Size = UDim2.fromOffset(14, 14), BackgroundColor3 = Color3.fromRGB(150, 150, 165), BorderSizePixel = 0, Parent = track })
	new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = knob })
	local btn = new("TextButton", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "", Parent = row })
	local function render(instant)
		local on = settings[key]
		local p1 = { BackgroundColor3 = on and ACCENT or OFF }
		local p2 = { Position = on and UDim2.new(1, -17, 0.5, 0) or UDim2.new(0, 3, 0.5, 0), BackgroundColor3 = on and Color3.new(1, 1, 1) or Color3.fromRGB(150, 150, 165) }
		if instant then
			for k, v in pairs(p1) do track[k] = v end
			for k, v in pairs(p2) do knob[k] = v end
		else
			tw(track, 0.15, p1) tw(knob, 0.15, p2)
		end
	end
	onAccent(function() render(true) end)
	table.insert(refreshers, function() render(true) end)
	btn.MouseButton1Click:Connect(function()
		settings[key] = not settings[key]
		render(false)
		notify(label .. (settings[key] and "  [ON]" or "  [OFF]"), true)
		if onChange then onChange(settings[key]) end
	end)
	hover(row, btn)
end

local function dragBar(bar, onFrac)
	local sliding = false
	local function upd(x) onFrac(math.clamp((x - bar.AbsolutePosition.X) / math.max(bar.AbsoluteSize.X, 1), 0, 1)) end
	bar.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			sliding = true upd(i.Position.X)
		end
	end)
	UIS.InputChanged:Connect(function(i)
		if sliding and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then upd(i.Position.X) end
	end)
	UIS.InputEnded:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then sliding = false end
	end)
end

local function addSlider(key, label, min, max, step, suffix, log)
	suffix = suffix or ""
	local row = makeRow(48)
	new("TextLabel", { Position = UDim2.fromOffset(12, 5), Size = UDim2.new(1, -100, 0, 18), BackgroundTransparency = 1, Font = FONT, TextSize = 14, TextColor3 = TEXT, TextXAlignment = Enum.TextXAlignment.Left, Text = label, Parent = row })
	local val = new("TextLabel", { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 5), Size = UDim2.fromOffset(80, 18), BackgroundTransparency = 1, Font = FONTB, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Right, Parent = row })
	local hit = new("Frame", { Position = UDim2.fromOffset(12, 27), Size = UDim2.new(1, -24, 0, 16), BackgroundTransparency = 1, Parent = row })
	local track = new("Frame", { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 0, 0.5, 0), Size = UDim2.new(1, 0, 0, 4), BackgroundColor3 = OFF, BorderSizePixel = 0, Parent = hit })
	new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = track })
	local fill = new("Frame", { Size = UDim2.new(0, 0, 1, 0), BorderSizePixel = 0, Parent = track })
	new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = fill })
	local knob = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(12, 12), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Parent = fill })
	new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = knob })
	local function render()
		local frac
		if log then
			frac = math.log(math.clamp(settings[key], min, max) / min) / math.log(max / min)
		else
			frac = (settings[key] - min) / (max - min)
		end
		fill.Size = UDim2.new(math.clamp(frac, 0, 1), 0, 1, 0)
		val.Text = string.format("%g", settings[key]) .. suffix
	end
	onAccent(function() fill.BackgroundColor3 = ACCENT val.TextColor3 = ACCENT render() end)
	table.insert(refreshers, render)
	dragBar(hit, function(f)
		local v
		if log then
			-- exponential slider, rounded to 2 significant digits (0.01 ... 100)
			v = min * (max / min) ^ f
			local mag = 10 ^ (math.floor(math.log10(v)) - 1)
			v = math.floor(v / mag + 0.5) * mag
		else
			v = min + f * (max - min)
			v = math.floor((v - min) / step + 0.5) * step + min
		end
		settings[key] = math.clamp(v, min, max)
		render()
	end)
	hover(row, hit)
end

local rainbow = {}
for i = 0, 6 do table.insert(rainbow, ColorSequenceKeypoint.new(i / 6, Color3.fromHSV(i / 6, 1, 1))) end

local function addHue(key, label, onChange)
	local row = makeRow(48)
	new("TextLabel", { Position = UDim2.fromOffset(12, 5), Size = UDim2.new(1, -60, 0, 18), BackgroundTransparency = 1, Font = FONT, TextSize = 14, TextColor3 = TEXT, TextXAlignment = Enum.TextXAlignment.Left, Text = label, Parent = row })
	local sw = new("Frame", { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 7), Size = UDim2.fromOffset(28, 14), BorderSizePixel = 0, Parent = row })
	new("UICorner", { CornerRadius = UDim.new(0, 4), Parent = sw })
	local hit = new("Frame", { Position = UDim2.fromOffset(12, 27), Size = UDim2.new(1, -24, 0, 16), BackgroundTransparency = 1, Parent = row })
	local bar = new("Frame", { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 0, 0.5, 0), Size = UDim2.new(1, 0, 0, 7), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Parent = hit })
	new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = bar })
	new("UIGradient", { Color = ColorSequence.new(rainbow), Parent = bar })
	local knob = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(6, 16), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Parent = bar })
	new("UICorner", { CornerRadius = UDim.new(0, 3), Parent = knob })
	new("UIStroke", { Color = Color3.new(0, 0, 0), Thickness = 1, Parent = knob })
	local function render()
		knob.Position = UDim2.new(settings[key], 0, 0.5, 0)
		sw.BackgroundColor3 = hueColor(settings[key])
	end
	render()
	table.insert(refreshers, render)
	dragBar(hit, function(f)
		settings[key] = f
		render()
		if onChange then onChange(f) end
	end)
	hover(row, hit)
end

local function addButton(label, fn)
	local row = makeRow(34)
	local b = new("TextButton", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Font = FONT, TextSize = 14, TextColor3 = TEXT, Text = label, AutoButtonColor = false, Parent = row })
	hover(row, b)
	b.MouseButton1Click:Connect(fn)
end

-- a grid of buttons; settings[key] holds the index of the selected one
local function addChoice(key, label, options)
	local cols = 4
	local rows = math.ceil(#options / cols)
	local row = makeRow(36 + rows * 32)
	new("TextLabel", { Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -24, 0, 30), BackgroundTransparency = 1, Font = FONT, TextSize = 14, TextColor3 = TEXT, TextXAlignment = Enum.TextXAlignment.Left, Text = label, Parent = row })
	local grid = new("Frame", { Position = UDim2.fromOffset(12, 30), Size = UDim2.new(1, -24, 1, -36), BackgroundTransparency = 1, Parent = row })
	new("UIGridLayout", { CellSize = UDim2.new(1 / cols, -6, 0, 26), CellPadding = UDim2.fromOffset(6, 6), SortOrder = Enum.SortOrder.LayoutOrder, Parent = grid })
	local buttons = {}
	local function render()
		for i, b in ipairs(buttons) do
			local on = settings[key] == i
			b.BackgroundColor3 = on and ACCENT or OFF
			b.TextColor3 = on and Color3.fromRGB(10, 10, 16) or TEXT
		end
	end
	for i, name in ipairs(options) do
		local b = new("TextButton", { LayoutOrder = i, BorderSizePixel = 0, AutoButtonColor = false, Font = FONT, TextSize = 12, Text = name, Parent = grid })
		new("UICorner", { CornerRadius = UDim.new(0, 5), Parent = b })
		buttons[i] = b
		b.MouseButton1Click:Connect(function()
			settings[key] = i
			render()
		end)
	end
	onAccent(render)
	table.insert(refreshers, render)
end

---------------------------------------------------------------------
-- MENU CONTENT
---------------------------------------------------------------------
local function applyFabPos() end -- defined later

addTab("ESP")
addSection("player esp")
addToggle("EspEnabled", "Enable ESP")
addToggle("EspEnemies", "Show Enemies")
addToggle("EspTeam", "Show Teammates")
addToggle("EspNpcs", "Include NPCs / AI")
addNote("If your game has no teams, everyone counts as an enemy")
addToggle("Box", "2D Box")
addToggle("Name", "Name")
addToggle("Distance", "Distance")
addToggle("Health", "Health")
addToggle("Skeleton", "Skeleton")
addNote("Skeleton: green = player can see you / visible, red = hidden behind a wall")
addToggle("Arrows", "Direction Arrows")
addSlider("ArrowGap", "Arrow Distance", 10, 150, 5, " px")
addSlider("ArrowSize", "Arrow Size", 10, 60, 1, " px")
addToggle("ArrowVis", "Arrow Color By Visibility")
addHue("ArrowHue", "Arrow Color")
addNote("Arrows sit on a ring around the FOV circle and point at every player. With Color By Visibility on: green = visible, red = behind cover. Turn it off to use your own color.")
addToggle("Tracers", "Top Lines")
addSlider("TracerThick", "Line Thickness", 1, 8, 1, " px")
addHue("TracerHue", "Line Color")
addToggle("TracerAll", "Lines To Hidden Players Too")
addNote("A line from the very top middle of your screen down to every player on screen. By default only players you can see get one.")
addToggle("Fill", "Fill Glow")
addHue("FillHue", "Fill Color")

addTab("Aimbot")
addSection("fov lock")
addToggle("AimEnabled", "Enable Aimbot")
addNote("Locks onto the closest visible player inside the circle")
addSlider("AimFov", "FOV Size", 20, 2000, 5, " px")
addHue("AimHue", "Circle Color (outline + fill)")
addToggle("AimFilled", "Filled Circle")
addSlider("AimSpeed", "Aim Speed", 1, 100, 1, "%")
addNote("Aim speed: 1% = super slow, 100% = super fast")
addSection("target body part")
do
	local ON_COLOR = Color3.fromRGB(255, 60, 80)
	local OFF_COLOR = Color3.fromRGB(34, 150, 90)
	local row = makeRow(208)

	new("TextLabel", {
		Position = UDim2.fromOffset(12, 40), Size = UDim2.fromOffset(120, 60), BackgroundTransparency = 1,
		Font = FONT, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
		RichText = true, TextColor3 = DIM,
		Text = '<font color="#ff3c50">RED</font> = targeted\n<font color="#22965a">GREEN</font> = off\nclick a part to switch',
		Parent = row,
	})
	new("TextLabel", {
		AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 40), Size = UDim2.fromOffset(110, 80), BackgroundTransparency = 1,
		Font = FONT, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Right, TextYAlignment = Enum.TextYAlignment.Top,
		TextColor3 = DIM, Text = "PRIORITY\n1  Head\n2  Torso\n3  Arms\n4  Legs", Parent = row,
	})

	local figure = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 8),
		Size = UDim2.fromOffset(120, 190), BackgroundTransparency = 1, Parent = row,
	})
	-- antenna
	new("Frame", { Position = UDim2.fromOffset(59, 0), Size = UDim2.fromOffset(2, 8), BackgroundColor3 = DIM, BorderSizePixel = 0, Parent = figure })

	local function render(b, key, instant)
		local c = settings[key] and ON_COLOR or OFF_COLOR
		if instant then b.BackgroundColor3 = c else tw(b, 0.15, { BackgroundColor3 = c }) end
	end

	local function zoneButton(key, tier, label, x, y, w, h, radius)
		local b = new("TextButton", {
			Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(w, h), BorderSizePixel = 0, AutoButtonColor = false,
			Font = FONTB, TextSize = 13, TextColor3 = Color3.new(1, 1, 1), Text = tostring(tier), Parent = figure,
		})
		new("UICorner", { CornerRadius = UDim.new(0, radius), Parent = b })
		new("UIStroke", { Color = Color3.new(0, 0, 0), Thickness = 1, Transparency = 0.5, Parent = b })
		render(b, key, true)
		table.insert(refreshers, function() render(b, key, true) end)
		b.MouseEnter:Connect(function() tw(b, 0.1, { Size = UDim2.fromOffset(w + 2, h + 2), Position = UDim2.fromOffset(x - 1, y - 1) }) end)
		b.MouseLeave:Connect(function() tw(b, 0.1, { Size = UDim2.fromOffset(w, h), Position = UDim2.fromOffset(x, y) }) end)
		b.MouseButton1Click:Connect(function()
			settings[key] = not settings[key]
			render(b, key, false)
			notify(label .. (settings[key] and "  [TARGETED]" or "  [OFF]"), true)
		end)
		return b
	end

	zoneButton("Part_Head",  1, "Head",      42, 8,   36, 36, 10)
	zoneButton("Part_Torso", 2, "Torso",     32, 50,  56, 60, 8)
	zoneButton("Part_LArm",  3, "Left Arm",  8,  50,  20, 56, 8)
	zoneButton("Part_RArm",  3, "Right Arm", 92, 50,  20, 56, 8)
	zoneButton("Part_LLeg",  4, "Left Leg",  32, 114, 26, 74, 8)
	zoneButton("Part_RLeg",  4, "Right Leg", 62, 114, 26, 74, 8)
end
addNote("Aims at the highest-priority red part it can see: head first, then torso, arms, legs. If the head is hidden it falls back to the next red part.")
addToggle("AimWallCheck", "Wall Check")
addToggle("AimEnemies", "Target Enemies")
addToggle("AimTeammates", "Target Teammates")
addToggle("AimNpcs", "Target NPCs / AI")
addSection("prediction")
addToggle("Prediction", "Prediction (lead moving targets)")
addSlider("PredSpeed", "Projectile Speed", 50, 5000, 10, " studs/s")
addNote("Lead = distance / projectile speed (plus your ping). Lower speed = aims further ahead of moving targets. 5000 is nearly instant.")
addNote("Your ping is added automatically. Raise Lead Time if you still aim behind fast players.")

addTab("Crosshair")
addSection("custom crosshair")
addToggle("CrossOn", "Enable Crosshair")
addChoice("CrossShape", "Shape", { "Plus", "Dot", "Plus+Dot", "Vertical", "Horizontal", "X", "Triangle", "Circle", "Square" })
addSlider("CrossSize", "Size", 3, 80, 1, " px")
addSlider("CrossThick", "Thickness", 1, 10, 1, " px")
addSlider("CrossGap", "Center Gap", 0, 40, 1, " px")
addHue("CrossHue", "Color")
addSlider("CrossRot", "Rotation Speed", -720, 720, 10, " deg/s")
addNote("0 = no spin. Positive spins clockwise, negative spins counter-clockwise.")
addToggle("CrossOutline", "Black Outline")

addTab("Gunmod")
addSection("weapon mods")
local gunInfoLbl = addNote("Equip a weapon and it is scanned automatically.")
local clientGunInfo = ""
local function refreshGunInfo()
	gunInfoLbl.Text = (lp:GetAttribute("HubGunInfo") or "") .. clientGunInfo
end
lp:GetAttributeChangedSignal("HubGunInfo"):Connect(refreshGunInfo)
addToggle("RecoilOn", "Recoil Mod")
addSlider("RecoilPct", "Recoil", 1, 100, 1, "%")
addNote("100% = normal recoil, 1% = almost none")
addToggle("FireRateOn", "Fire Rate Mod")
addSlider("FireRateMult", "Fire Rate", 1, 10, 0.5, "x")
addNote("1x = normal, 10x = ten times faster")
addToggle("InfAmmo", "Infinite Ammo")
addNote("Gun mods need the server half: put this same file in a Script in ServerScriptService.")

addTab("World")
addSection("environment")
addToggle("CustomTime", "Custom Time of Day")
addSlider("WorldTime", "Time", 0, 24, 1, "h")
addToggle("Fullbright", "Fullbright (see at night)")

addTab("Player")
addSection("character")
addToggle("Spin", "Spin Character")
addSlider("SpinRps", "Spin Speed", 0.01, 100, nil, " turns/s", true)
addNote("Full 360 turns. 0.01 = one turn every 100 seconds (slowest), 100 = a hundred turns every second (fastest). Your camera stays where you are looking and movement is not affected.")

addSection("teleport")
addToggle("TpButton", "Show Teleport Button")
addToggle("TpNpcs", "Teleport To NPCs / AI Too")
addSlider("TpDist", "Distance Behind", 2, 20, 1, " studs")
addNote("Turns on a TP button on your screen. Drag it anywhere, then tap it to teleport behind the closest non-teammate without opening the menu.")

addSection("anti-aim")
addToggle("LimbChaos", "Limb Chaos")
addSlider("LimbSpeed", "Limb Speed", 1, 10, 0.5, "x")
addNote("Every joint swings on its own axes at its own random speed.")
addToggle("Bury", "Flip Underground")
addNote("Flips your whole character upside down around your feet: the feet stay put on the ground and everything else (root part, torso, head) ends up underground, so shots hit the floor. You can still walk with WASD. Turns off Fly/Spin while on.")

addSection("server view")
addToggle("ShowServer", "Show Server Position")
addNote("Draws a red ghost where the SERVER thinks your character is (needs the Script half in ServerScriptService). Handy to check whether the server accepts your flip, teleports or fly.")

addSection("movement")
addToggle("SpeedOn", "Walk Speed")
addSlider("WalkSpeed", "Speed", 16, 500, 2)
addToggle("JumpOn", "Jump Power")
addSlider("JumpPower", "Power", 50, 500, 5)
addToggle("InfJump", "Infinite Jump")
addToggle("Fly", "Fly")
addSlider("FlySpeed", "Fly Speed", 10, 500, 5)
addNote("Fly: WASD to move where the camera points, Space = up, Left Ctrl = down.")
addToggle("Noclip", "Noclip")
addNote("Walk through walls and objects. Turning it off puts collisions back.")

addTab("Menusettings")
addSection("interface")
addHue("AccentHue", "Menu Color Theme", function() setAccent(settings.AccentHue) end)
addToggle("LockButton", "Lock Open Button Position")
addButton("Reset Open Button Position", function()
	settings.FabX, settings.FabY = 0.01, 0.5
	applyFabPos()
end)
addSection("configuration (1 slot)")

local CONFIG_FILE = "UNIhub_config.json"
local canFile = type(writefile) == "function" and type(readfile) == "function"
local memoryConfig = nil

addButton("Save Config", function()
	local json = HttpService:JSONEncode(settings)
	if canFile then
		local ok = pcall(writefile, CONFIG_FILE, json)
		notify(ok and "Config saved" or "Save failed", ok)
	else
		memoryConfig = json
		notify("Saved (this session only)", true)
	end
end)
addButton("Load Config", function()
	local json
	if canFile then
		local ok, r = pcall(readfile, CONFIG_FILE)
		if ok then json = r end
	else
		json = memoryConfig
	end
	if not json then notify("No saved config", false) return end
	local ok, data = pcall(function() return HttpService:JSONDecode(json) end)
	if not ok or type(data) ~= "table" then notify("Config corrupted", false) return end
	for k, v in pairs(data) do
		if settings[k] ~= nil and type(settings[k]) == type(v) then settings[k] = v end
	end
	setAccent(settings.AccentHue)
	for _, f in ipairs(refreshers) do f() end
	applyFabPos()
	notify("Config loaded", true)
end)

selectTab("ESP")

---------------------------------------------------------------------
-- OPEN / CLOSE / DRAG + OPEN BUTTON
---------------------------------------------------------------------
local isOpen = false
local function baseScale()
	local vp = cam().ViewportSize
	return math.clamp(math.min(vp.X / (WW + 30), vp.Y / (WH + 30)), 0.5, 1)
end
local function setOpen(state)
	isOpen = state
	if state then
		window.Visible = true
		window.GroupTransparency = 1
		uiScale.Scale = baseScale() * 0.92
		tw(window, 0.22, { GroupTransparency = 0 })
		tw(uiScale, 0.22, { Scale = baseScale() })
	else
		tw(window, 0.15, { GroupTransparency = 1 })
		tw(uiScale, 0.15, { Scale = baseScale() * 0.92 })
		task.delay(0.16, function() if not isOpen then window.Visible = false end end)
	end
end
closeBtn.MouseButton1Click:Connect(function() setOpen(false) end)
UIS.InputBegan:Connect(function(input, gpe)
	if gpe then return end
	if input.KeyCode == Enum.KeyCode.RightShift or input.KeyCode == Enum.KeyCode.Insert then setOpen(not isOpen) end
end)

local fab = new("TextButton", { AnchorPoint = Vector2.new(0, 0.5), Size = UDim2.fromOffset(44, 44), BackgroundColor3 = BG, BorderSizePixel = 0, AutoButtonColor = false, Font = FONTB, TextSize = 13, Text = "UNI", Parent = gui })
new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = fab })
local fabStroke = new("UIStroke", { Thickness = 2, Parent = fab })
onAccent(function() fab.TextColor3 = ACCENT fabStroke.Color = ACCENT end)
function applyFabPos()
	fab.Position = UDim2.fromScale(settings.FabX, settings.FabY)
end
applyFabPos()

-- fab: click = toggle menu, drag = move (unless locked)
local fDown, fMoved, fStart, fOrigin = false, false, nil, nil
fab.InputBegan:Connect(function(i)
	if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
		fDown, fMoved, fStart = true, false, i.Position
		fOrigin = Vector2.new(settings.FabX, settings.FabY)
	end
end)
UIS.InputChanged:Connect(function(i)
	if fDown and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
		local d = i.Position - fStart
		if d.Magnitude > 6 then fMoved = true end
		if fMoved and not settings.LockButton then
			local vp = cam().ViewportSize
			settings.FabX = math.clamp(fOrigin.X + d.X / vp.X, 0, 0.97)
			settings.FabY = math.clamp(fOrigin.Y + d.Y / vp.Y, 0.03, 0.97)
			applyFabPos()
		end
	end
end)
UIS.InputEnded:Connect(function(i)
	if fDown and (i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch) then
		fDown = false
		if not fMoved then setOpen(not isOpen) end
	end
end)

-- window drag
local dragging, dStart, dPos = false, nil, nil
titleBar.InputBegan:Connect(function(i)
	if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
		dragging, dStart, dPos = true, i.Position, window.Position
	end
end)
UIS.InputChanged:Connect(function(i)
	if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
		local d = (i.Position - dStart) / math.max(uiScale.Scale, 0.01)
		window.Position = UDim2.new(dPos.X.Scale, dPos.X.Offset + d.X, dPos.Y.Scale, dPos.Y.Offset + d.Y)
	end
end)
UIS.InputEnded:Connect(function(i)
	if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dragging = false end
end)

---------------------------------------------------------------------
-- MENU ANIMATION (border spin, particles, stats)
---------------------------------------------------------------------
local frames, acc = 0, 0
RunService.RenderStepped:Connect(function(dt)
	frames += 1
	acc += dt
	if window.Visible then
		wGrad.Rotation = (os.clock() * 50) % 360
		for _, p in ipairs(particles) do
			p.y -= p.v * dt
			p.x += math.sin(os.clock() + p.d) * 8 * dt
			if p.y < -6 then p.y = WH + 6 p.x = math.random() * WW end
			p.f.Position = UDim2.fromOffset(p.x, p.y)
		end
	end
	if acc >= 0.5 then
		statsLbl.Text = math.floor(frames / acc + 0.5) .. " FPS"
		frames, acc = 0, 0
	end
end)

---------------------------------------------------------------------
-- WORLD
---------------------------------------------------------------------
local origLight = { Ambient = Lighting.Ambient, Brightness = Lighting.Brightness, OutdoorAmbient = Lighting.OutdoorAmbient, FogEnd = Lighting.FogEnd }
local wasFull = false
RunService.RenderStepped:Connect(function()
	if settings.CustomTime then Lighting.ClockTime = settings.WorldTime end
	if settings.Fullbright then
		wasFull = true
		Lighting.Ambient = Color3.new(1, 1, 1)
		Lighting.OutdoorAmbient = Color3.new(1, 1, 1)
		Lighting.Brightness = 2
		Lighting.FogEnd = 1e6
	elseif wasFull then
		wasFull = false
		for k, v in pairs(origLight) do Lighting[k] = v end
	end
end)

---------------------------------------------------------------------
-- VISIBILITY
---------------------------------------------------------------------
local rp = RaycastParams.new()
rp.FilterType = Enum.RaycastFilterType.Exclude
rp.IgnoreWater = true
-- ignores invisible / non-collidable parts (triggers, effects) so they don't block the check
local function canSee(char, part, origin)
	origin = origin or cam().CFrame.Position
	local ignore = { char }
	if lp.Character then table.insert(ignore, lp.Character) end
	local dir = part.Position - origin
	for _ = 1, 8 do
		rp.FilterDescendantsInstances = ignore
		local hit = workspace:Raycast(origin, dir, rp)
		if not hit then return true end
		local inst = hit.Instance
		if inst.Transparency >= 0.95 or not inst.CanCollide then
			table.insert(ignore, inst)
		else
			return false
		end
	end
	return false
end

---------------------------------------------------------------------
-- ESP
---------------------------------------------------------------------
local BONES_R15 = {
	{ "Head", "UpperTorso" }, { "UpperTorso", "LowerTorso" },
	{ "UpperTorso", "LeftUpperArm" }, { "LeftUpperArm", "LeftLowerArm" }, { "LeftLowerArm", "LeftHand" },
	{ "UpperTorso", "RightUpperArm" }, { "RightUpperArm", "RightLowerArm" }, { "RightLowerArm", "RightHand" },
	{ "LowerTorso", "LeftUpperLeg" }, { "LeftUpperLeg", "LeftLowerLeg" }, { "LeftLowerLeg", "LeftFoot" },
	{ "LowerTorso", "RightUpperLeg" }, { "RightUpperLeg", "RightLowerLeg" }, { "RightLowerLeg", "RightFoot" },
}
local BONES_R6 = { { "Head", "Torso" }, { "Torso", "Left Arm" }, { "Torso", "Right Arm" }, { "Torso", "Left Leg" }, { "Torso", "Right Leg" } }

local esp = {}
local function destroyEsp(plr)
	local d = esp[plr]
	if not d then return end
	pcall(function()
		d.hl:Destroy() d.box:Destroy() d.name:Destroy() d.info:Destroy() d.arrow:Destroy() d.tracer:Destroy()
		for _, l in ipairs(d.lines) do l:Destroy() end
	end)
	esp[plr] = nil
end

local function createEsp(plr, char)
	local d = { char = char, lines = {}, vis = false, last = 0 }
	d.hl = new("Highlight", { DepthMode = Enum.HighlightDepthMode.AlwaysOnTop, FillTransparency = 0.5, OutlineTransparency = 0, Parent = char })
	d.box = new("Frame", { BackgroundTransparency = 1, BorderSizePixel = 0, Visible = false, Parent = overlay })
	d.boxStroke = new("UIStroke", { Thickness = 1.5, Parent = d.box })
	d.name = new("TextLabel", { AnchorPoint = Vector2.new(0.5, 1), Size = UDim2.fromOffset(160, 14), BackgroundTransparency = 1, Font = FONTB, TextSize = 13, TextStrokeTransparency = 0.3, TextColor3 = Color3.new(1, 1, 1), Visible = false, Parent = overlay })
	d.info = new("TextLabel", { AnchorPoint = Vector2.new(0.5, 0), Size = UDim2.fromOffset(160, 14), BackgroundTransparency = 1, Font = FONT, TextSize = 12, TextStrokeTransparency = 0.3, TextColor3 = Color3.new(1, 1, 1), Visible = false, Parent = overlay })
	for _ = 1, 14 do
		table.insert(d.lines, new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BorderSizePixel = 0, Visible = false, Parent = overlay }))
	end
	-- direction arrow (a chevron plus a stem, built from frames so no image assets are needed)
	d.arrow = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(22, 22), BackgroundTransparency = 1, Visible = false, Parent = overlay })
	d.armL = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(7, 7), Size = UDim2.fromOffset(12, 3), Rotation = -45, BorderSizePixel = 0, Parent = d.arrow })
	d.armR = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(15, 7), Size = UDim2.fromOffset(12, 3), Rotation = 45, BorderSizePixel = 0, Parent = d.arrow })
	d.stem = new("Frame", { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromOffset(11, 4), Size = UDim2.fromOffset(3, 15), BorderSizePixel = 0, Parent = d.arrow })
	d.tracer = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BorderSizePixel = 0, BackgroundTransparency = 0.25, Visible = false, Parent = overlay })
	d.arrowScale = new("UIScale", { Parent = d.arrow })
	esp[plr] = d
	return d
end

local function hideEsp(d)
	d.box.Visible = false d.name.Visible = false d.info.Visible = false
	d.hl.Enabled = false
	d.arrow.Visible = false d.tracer.Visible = false
	for _, l in ipairs(d.lines) do l.Visible = false end
end

Players.PlayerRemoving:Connect(destroyEsp)

local function isTeammate(plr)
	return lp.Team ~= nil and plr.Team == lp.Team
end

-- NPC / AI detection: any model in the world with a Humanoid that is not a player's character.
local npcSet = {}
local function trackHumanoid(h)
	if h:IsA("Humanoid") then
		local m = h.Parent
		if m and m:IsA("Model") then npcSet[m] = true end
	end
end
pcall(function()
	for _, d in ipairs(workspace:GetDescendants()) do trackHumanoid(d) end
end)
workspace.DescendantAdded:Connect(trackHumanoid)
workspace.DescendantRemoving:Connect(function(d)
	if d:IsA("Humanoid") and d.Parent then npcSet[d.Parent] = nil end
end)

local function modelRoot(m)
	return m and (m:FindFirstChild("HumanoidRootPart") or m:FindFirstChild("Torso") or m:FindFirstChild("UpperTorso") or m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart"))
end

-- every player (except you) and, optionally, every NPC. key = what ESP data is stored under
local function entities(includeNpcs)
	local list = {}
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= lp then
			table.insert(list, { key = plr, char = plr.Character, name = plr.DisplayName, mate = isTeammate(plr), npc = false })
		end
	end
	if includeNpcs then
		for m in pairs(npcSet) do
			if m.Parent and m ~= lp.Character and not Players:GetPlayerFromCharacter(m) then
				table.insert(list, { key = m, char = m, name = m.Name, mate = false, npc = true })
			end
		end
	end
	return list
end

RunService.RenderStepped:Connect(function()
	local c = cam()
	local ents = entities(settings.EspNpcs)
	local alive = {}
	for _, e in ipairs(ents) do alive[e.key] = true end
	for k in pairs(esp) do
		if not alive[k] then destroyEsp(k) end
	end
	for _, ent in ipairs(ents) do
		local plr = ent.key
		if plr ~= lp then
			local teamHidden = (ent.mate and not settings.EspTeam)
				or (not ent.mate and not settings.EspEnemies)
			local char = ent.char
			local hrp = char and modelRoot(char)
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			local d = esp[plr]
			if d and d.char ~= char then destroyEsp(plr) d = nil end

			if not settings.EspEnabled or teamHidden or not hrp or not hum or hum.Health <= 0 then
				if d then hideEsp(d) end
			else
				if not d then d = createEsp(plr, char) end
				local head = char:FindFirstChild("Head") or hrp

				d.hl.Enabled = settings.Fill
				d.hl.FillColor = hueColor(settings.FillHue)
				d.hl.OutlineColor = ACCENT

				if os.clock() - d.last > 0.1 then
					d.last = os.clock()
					d.vis = canSee(char, head)
				end

				-- direction arrow on a ring around the FOV circle
				if settings.Arrows then
					local vp = c.ViewportSize
					local rel = c.CFrame:PointToObjectSpace(hrp.Position)
					local dir = Vector2.new(rel.X, -rel.Y)
					if dir.Magnitude < 0.001 then dir = Vector2.new(0, 1) end
					dir = dir.Unit
					local radius = math.clamp(settings.AimFov + settings.ArrowGap, 60, math.max(60, math.min(vp.X, vp.Y) / 2 - 18))
					local ap = vp / 2 + dir * radius
					d.arrow.Position = UDim2.fromOffset(ap.X, ap.Y)
					d.arrow.Rotation = math.deg(math.atan2(dir.Y, dir.X)) + 90
					local acol = settings.ArrowVis and (d.vis and GREEN or RED) or hueColor(settings.ArrowHue)
					d.arrowScale.Scale = settings.ArrowSize / 22
					d.armL.BackgroundColor3 = acol
					d.armR.BackgroundColor3 = acol
					d.stem.BackgroundColor3 = acol
					d.arrow.Visible = true
				else
					d.arrow.Visible = false
				end

				-- line from the top middle of the screen to every player you can see
				local showTracer = false
				if settings.Tracers and (d.vis or settings.TracerAll) then
					local rv, rOn = c:WorldToViewportPoint(hrp.Position)
					if rOn and rv.Z > 0 then
						local a = Vector2.new(c.ViewportSize.X / 2, 0)
						local b = Vector2.new(rv.X, rv.Y)
						local v = b - a
						d.tracer.Size = UDim2.fromOffset(v.Magnitude, settings.TracerThick)
						d.tracer.Position = UDim2.fromOffset((a.X + b.X) / 2, (a.Y + b.Y) / 2)
						d.tracer.Rotation = math.deg(math.atan2(v.Y, v.X))
						d.tracer.BackgroundColor3 = hueColor(settings.TracerHue)
						showTracer = true
					end
				end
				d.tracer.Visible = showTracer

				local topV, topOn = c:WorldToViewportPoint(head.Position + Vector3.new(0, 0.8, 0))
				local botV, botOn = c:WorldToViewportPoint(hrp.Position - Vector3.new(0, 3, 0))
				local onScreen = topOn and botOn and topV.Z > 0 and botV.Z > 0

				if onScreen then
					local h = math.abs(botV.Y - topV.Y)
					local w = h * 0.55
					local cx = (topV.X + botV.X) / 2
					d.box.Visible = settings.Box
					d.box.Position = UDim2.fromOffset(cx - w / 2, topV.Y)
					d.box.Size = UDim2.fromOffset(w, h)
					d.boxStroke.Color = ACCENT

					d.name.Visible = settings.Name
					d.name.Text = ent.name
					d.name.Position = UDim2.fromOffset(cx, topV.Y - 2)

					local parts = {}
					if settings.Health then table.insert(parts, math.floor(hum.Health) .. " HP") end
					if settings.Distance then
						local myRoot = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
						local dist = myRoot and (myRoot.Position - hrp.Position).Magnitude or (c.CFrame.Position - hrp.Position).Magnitude
						table.insert(parts, math.floor(dist) .. " studs")
					end
					d.info.Visible = #parts > 0
					d.info.Text = table.concat(parts, "  |  ")
					d.info.Position = UDim2.fromOffset(cx, botV.Y + 2)
				else
					d.box.Visible = false d.name.Visible = false d.info.Visible = false
				end

				local bones = hum.RigType == Enum.HumanoidRigType.R15 and BONES_R15 or BONES_R6
				local col = d.vis and GREEN or RED
				for i, ln in ipairs(d.lines) do
					local b = bones[i]
					local shown = false
					if settings.Skeleton and b then
						local p1, p2 = char:FindFirstChild(b[1]), char:FindFirstChild(b[2])
						if p1 and p2 then
							local a, onA = c:WorldToViewportPoint(p1.Position)
							local bb, onB = c:WorldToViewportPoint(p2.Position)
							if onA and onB then
								local v = Vector2.new(bb.X - a.X, bb.Y - a.Y)
								ln.Size = UDim2.fromOffset(v.Magnitude, 2)
								ln.Position = UDim2.fromOffset((a.X + bb.X) / 2, (a.Y + bb.Y) / 2)
								ln.Rotation = math.deg(math.atan2(v.Y, v.X))
								ln.BackgroundColor3 = col
								ln.Visible = true
								shown = true
							end
						end
					end
					if not shown then ln.Visible = false end
				end
			end
		end
	end
end)

---------------------------------------------------------------------
-- CROSSHAIR (every shape is built from frames, so no image assets are needed)
---------------------------------------------------------------------
local cross = new("Frame", { Name = "Crosshair", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(300, 300), BackgroundTransparency = 1, Visible = false, ZIndex = 10, Parent = overlay })
local crossBars = {}
for i = 1, 4 do
	local f = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BorderSizePixel = 0, Visible = false, ZIndex = 10, Parent = cross })
	local st = new("UIStroke", { Color = Color3.new(0, 0, 0), Thickness = 1, Parent = f })
	crossBars[i] = { f = f, s = st }
end
local crossDot = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), BorderSizePixel = 0, Visible = false, ZIndex = 10, Parent = cross })
new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = crossDot })
local dotStroke = new("UIStroke", { Color = Color3.new(0, 0, 0), Thickness = 1, Parent = crossDot })
local crossRing = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), BackgroundTransparency = 1, BorderSizePixel = 0, Visible = false, ZIndex = 10, Parent = cross })
new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = crossRing })
local ringStroke = new("UIStroke", { Parent = crossRing })

-- draws one line from (ax, ay) to (bx, by), measured from the centre of the screen
local function putBar(i, ax, ay, bx, by, ext, t, col)
	local b = crossBars[i].f
	local dx, dy = bx - ax, by - ay
	b.Size = UDim2.fromOffset(math.sqrt(dx * dx + dy * dy) + ext, t)
	b.Position = UDim2.new(0.5, (ax + bx) / 2, 0.5, (ay + by) / 2)
	b.Rotation = math.deg(math.atan2(dy, dx))
	b.BackgroundColor3 = col
	b.Visible = true
end

local crossAngle = 0
RunService.RenderStepped:Connect(function(dt)
	if not settings.CrossOn then
		cross.Visible = false
		return
	end
	cross.Visible = true

	local col = hueColor(settings.CrossHue)
	local R, g, t = settings.CrossSize, settings.CrossGap, settings.CrossThick
	local shape = settings.CrossShape

	if settings.CrossRot ~= 0 then
		crossAngle = (crossAngle + settings.CrossRot * dt) % 360
	else
		crossAngle = 0
	end
	cross.Rotation = crossAngle

	for _, b in ipairs(crossBars) do
		b.f.Visible = false
		b.s.Enabled = settings.CrossOutline
	end
	crossDot.Visible = false
	crossRing.Visible = false

	if shape == 1 or shape == 3 then -- plus
		putBar(1, 0, -g, 0, -(g + R), 0, t, col)
		putBar(2, 0, g, 0, g + R, 0, t, col)
		putBar(3, -g, 0, -(g + R), 0, 0, t, col)
		putBar(4, g, 0, g + R, 0, 0, t, col)
	end
	if shape == 2 or shape == 3 then -- dot
		local d = (shape == 2) and math.max(4, R * 0.5) or math.max(3, t * 2)
		crossDot.Size = UDim2.fromOffset(d, d)
		crossDot.BackgroundColor3 = col
		dotStroke.Enabled = settings.CrossOutline
		crossDot.Visible = true
	elseif shape == 4 then -- two vertical lines
		local o = g + t / 2
		putBar(1, -o, -R, -o, R, 0, t, col)
		putBar(2, o, -R, o, R, 0, t, col)
	elseif shape == 5 then -- two horizontal lines
		local o = g + t / 2
		putBar(1, -R, -o, R, -o, 0, t, col)
		putBar(2, -R, o, R, o, 0, t, col)
	elseif shape == 6 then -- X
		local k = 0.7071
		putBar(1, -k * g, -k * g, -k * (g + R), -k * (g + R), 0, t, col)
		putBar(2, k * g, -k * g, k * (g + R), -k * (g + R), 0, t, col)
		putBar(3, -k * g, k * g, -k * (g + R), k * (g + R), 0, t, col)
		putBar(4, k * g, k * g, k * (g + R), k * (g + R), 0, t, col)
	elseif shape == 7 then -- triangle pointing up
		local bx, by = R * 0.866, R * 0.5
		putBar(1, 0, -R, bx, by, t, t, col)
		putBar(2, bx, by, -bx, by, t, t, col)
		putBar(3, -bx, by, 0, -R, t, t, col)
	elseif shape == 8 then -- circle
		crossRing.Size = UDim2.fromOffset(R * 2, R * 2)
		ringStroke.Thickness = t
		ringStroke.Color = col
		crossRing.Visible = true
	elseif shape == 9 then -- square
		putBar(1, -R, -R, R, -R, t, t, col)
		putBar(2, R, -R, R, R, t, t, col)
		putBar(3, R, R, -R, R, t, t, col)
		putBar(4, -R, R, -R, -R, t, t, col)
	end
end)

---------------------------------------------------------------------
-- AIMBOT + PREDICTION
---------------------------------------------------------------------
local circle = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BackgroundTransparency = 1, BorderSizePixel = 0, Visible = false, Parent = overlay })
new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = circle })
local circleStroke = new("UIStroke", { Thickness = 2, Parent = circle })

-- Priority: tier 1 (head) beats tier 2 (torso) beats tier 3 (arms) beats tier 4 (legs).
-- Inside one tier the part closest to the crosshair wins.
local function getTarget()
	local c = cam()
	local center = c.ViewportSize / 2

	local candidates, npcChars = {}, {}
	for _, ent in ipairs(entities(settings.AimNpcs)) do
		local char = ent.char
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		local skip = (ent.mate and not settings.AimTeammates) or (not ent.mate and not settings.AimEnemies)
		if hum and hum.Health > 0 and not skip then
			table.insert(candidates, char)
			if ent.npc then npcChars[char] = true end
		end
	end

	for tier = 1, 4 do
		local best, bestChar, bestD = nil, nil, math.huge
		for _, char in ipairs(candidates) do
			for _, z in ipairs(ZONES) do
				if z.tier == tier and settings[z.key] then
					for _, name in ipairs(z.names) do
						local part = char:FindFirstChild(name)
						if part and part:IsA("BasePart") then
							local v, on = c:WorldToViewportPoint(part.Position)
							if on and v.Z > 0 then
								local dist = (Vector2.new(v.X, v.Y) - center).Magnitude
								if dist <= settings.AimFov and dist < bestD then
									if not settings.AimWallCheck or canSee(char, part) then
										best, bestChar, bestD = part, char, dist
									end
								end
							end
						end
					end
				end
			end
		end
		if best then return best, bestChar end
	end

	-- NPCs with an unusual rig (no standard limb names): aim at their main part
	local best, bestChar, bestD = nil, nil, math.huge
	for char in pairs(npcChars) do
		local part = modelRoot(char)
		if part then
			local v, on = c:WorldToViewportPoint(part.Position)
			if on and v.Z > 0 then
				local dist = (Vector2.new(v.X, v.Y) - center).Magnitude
				if dist <= settings.AimFov and dist < bestD and (not settings.AimWallCheck or canSee(char, part)) then
					best, bestChar, bestD = part, char, dist
				end
			end
		end
	end
	return best, bestChar
end

local function pingSeconds()
	local ok, v = pcall(function() return Stats.Network.ServerStatsItem["Data Ping"]:GetValue() end)
	return ok and v / 1000 or 0
end

-- hitscan has no bullet travel time, so prediction only covers ping + your lead time
local function predict(part, char)
	local pos = part.Position
	if not settings.Prediction then return pos end
	local root = char:FindFirstChild("HumanoidRootPart") or part
	local hum = char:FindFirstChildOfClass("Humanoid")
	local vel = root.AssemblyLinearVelocity
	if hum and hum.FloorMaterial ~= Enum.Material.Air then
		vel = Vector3.new(vel.X, 0, vel.Z) -- walking: ignore small vertical jitter
	end
	local travel = (pos - cam().CFrame.Position).Magnitude / math.max(settings.PredSpeed, 1)
	return pos + vel * (pingSeconds() + travel)
end

RunService:BindToRenderStep("UNIhubAim", Enum.RenderPriority.Last.Value, function(dt)
	local c = cam()
	local center = c.ViewportSize / 2
	local col = hueColor(settings.AimHue)
	circle.Visible = settings.AimEnabled
	circle.Position = UDim2.fromOffset(center.X, center.Y)
	circle.Size = UDim2.fromOffset(settings.AimFov * 2, settings.AimFov * 2)
	circle.BackgroundColor3 = col
	circle.BackgroundTransparency = settings.AimFilled and 0.65 or 1
	circleStroke.Color = col

	if settings.AimEnabled then
		local part, char = getTarget()
		if part then
			local aimPos = predict(part, char)
			local a = 1
			if settings.AimSpeed < 100 then
				local s = settings.AimSpeed / 100
				local base = 0.004 + s * s * 0.9
				a = 1 - (1 - base) ^ (dt * 60)
			end
			c.CFrame = c.CFrame:Lerp(CFrame.lookAt(c.CFrame.Position, aimPos), math.clamp(a, 0, 1))
		end
	end
end)

---------------------------------------------------------------------
-- HELPERS
---------------------------------------------------------------------
local function heldTool()
	local c = lp.Character
	return c and c:FindFirstChildOfClass("Tool")
end

-- one-shot teleport behind the nearest non-teammate
local function rootOf(ch)
	return ch and (ch:FindFirstChild("HumanoidRootPart") or ch:FindFirstChild("Torso") or ch:FindFirstChild("UpperTorso") or ch.PrimaryPart)
end

local function nearestEnemyRoot()
	local myRoot = rootOf(lp.Character)
	if not myRoot then return nil end
	local best, bestD
	for _, ent in ipairs(entities(settings.TpNpcs)) do
		local ch = ent.char
		local r = rootOf(ch)
		local h = ch and ch:FindFirstChildOfClass("Humanoid")
		if r and h and h.Health > 0 and not ent.mate then
			local d = (r.Position - myRoot.Position).Magnitude
			if not bestD or d < bestD then best, bestD = r, d end
		end
	end
	return best
end

local tping = false
local function tpBehindNearest()
	if tping then return "busy" end
	local ch = lp.Character
	local myRoot = rootOf(ch)
	local hum = ch and ch:FindFirstChildOfClass("Humanoid")
	if not myRoot or not hum or hum.Health <= 0 then return "You are not alive" end
	local target = nearestEnemyRoot()
	if not target then return "No enemy found" end

	tping = true
	task.spawn(function()
		if hum.SeatPart then hum.Sit = false end
		-- re-apply for a moment: other scripts / the server can snap you back for a frame or two
		for _ = 1, 8 do
			local t = nearestEnemyRoot() or target
			target = t
			local look = t.CFrame.LookVector
			local flat = Vector3.new(look.X, 0, look.Z)
			flat = flat.Magnitude > 0.01 and flat.Unit or Vector3.new(0, 0, -1)
			-- behind = opposite the direction they face
			local pos = t.Position - flat * settings.TpDist
			local goal = CFrame.lookAt(pos, Vector3.new(t.Position.X, pos.Y, t.Position.Z))
			pcall(function() ch:PivotTo(goal) end)
			pcall(function() myRoot.CFrame = goal end)
			pcall(function()
				myRoot.AssemblyLinearVelocity = Vector3.zero
				myRoot.AssemblyAngularVelocity = Vector3.zero
			end)
			task.wait(0.05)
		end
		tping = false
	end)
	return true
end

-- on-screen teleport button: drag to move, tap to teleport
local tpBtn = new("TextButton", { Name = "TpButton", AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(64, 64), BackgroundColor3 = BG, BorderSizePixel = 0, AutoButtonColor = false, Font = FONTB, TextSize = 14, Text = "TP", Visible = false, Parent = gui })
new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = tpBtn })
local tpStroke = new("UIStroke", { Thickness = 2, Parent = tpBtn })
onAccent(function() tpBtn.TextColor3 = ACCENT tpStroke.Color = ACCENT end)
tpBtn.Position = UDim2.fromScale(settings.TpBtnX, settings.TpBtnY)

local tDown, tMoved, tStart, tOrigin = false, false, nil, nil
tpBtn.InputBegan:Connect(function(i)
	if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
		tDown, tMoved, tStart = true, false, i.Position
		tOrigin = Vector2.new(settings.TpBtnX, settings.TpBtnY)
	end
end)
UIS.InputChanged:Connect(function(i)
	if tDown and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
		local d = i.Position - tStart
		if d.Magnitude > 6 then tMoved = true end
		if tMoved then
			local vp = cam().ViewportSize
			settings.TpBtnX = math.clamp(tOrigin.X + d.X / vp.X, 0.03, 0.97)
			settings.TpBtnY = math.clamp(tOrigin.Y + d.Y / vp.Y, 0.03, 0.97)
			tpBtn.Position = UDim2.fromScale(settings.TpBtnX, settings.TpBtnY)
		end
	end
end)
UIS.InputEnded:Connect(function(i)
	if tDown and (i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch) then
		tDown = false
		if not tMoved then
			local res = tpBehindNearest()
			if res == true then
				tw(tpBtn, 0.1, { BackgroundColor3 = ACCENT })
				task.delay(0.15, function() tw(tpBtn, 0.2, { BackgroundColor3 = BG }) end)
			elseif res ~= "busy" then
				notify(res, false)
			end
		end
	end
end)
RunService.Heartbeat:Connect(function()
	tpBtn.Visible = settings.TpButton
end)

---------------------------------------------------------------------
-- GUNMOD SYNC (tells the server your slider values -> Player attributes)
---------------------------------------------------------------------
task.spawn(function()
	local modsRemote = ReplicatedStorage:WaitForChild(MODS_NAME, 20)
	if not modsRemote then
		warn("[UNIhub] server half not found. Put this same code in a Script in ServerScriptService.")
		return
	end
	local lastSent, lastTime = "", 0
	while true do
		local data = {
			recoil = settings.RecoilOn and settings.RecoilPct or 100,
			fireRate = settings.FireRateOn and settings.FireRateMult or 1,
			infAmmo = settings.InfAmmo,
		}
		local key = HttpService:JSONEncode(data)
		if key ~= lastSent or os.clock() - lastTime > 5 then
			lastSent, lastTime = key, os.clock()
			modsRemote:FireServer(data)
		end
		task.wait(0.25)
	end
end)

---------------------------------------------------------------------
-- CLIENT GUN ADAPTER
-- Guns driven by LocalScripts read their own client copy of any ModuleScript config,
-- which the server cannot change. Values/Attributes replicate from the server, so only
-- module tables are handled here (no double-applying).
---------------------------------------------------------------------
task.spawn(function()
	local tool, entries, at = nil, {}, 0
	while true do
		task.wait(0.1)
		local t = heldTool()
		if not t then
			if tool then
				tool = nil
				clientGunInfo = ""
				refreshGunInfo()
			end
		else
			if t ~= tool or os.clock() - at > 3 then
				tool, at = t, os.clock()
				entries = {}
				for _, e in ipairs(scanTool(t)) do
					if e.mode == "tbl" then table.insert(entries, e) end
				end
				clientGunInfo = "\nLocal gun modules found: " .. #entries
				refreshGunInfo()
			end
			applyMods({
				rec = settings.RecoilOn and settings.RecoilPct / 100 or 1,
				rate = settings.FireRateOn and settings.FireRateMult or 1,
				inf = settings.InfAmmo,
			}, entries)
		end
	end
end)

---------------------------------------------------------------------
-- START
---------------------------------------------------------------------
---------------------------------------------------------------------
-- SPIN CHARACTER (camera is untouched, only the character turns)
---------------------------------------------------------------------
local wasSpinning = false
RunService.RenderStepped:Connect(function(dt)
	local char = lp.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if settings.Spin and not settings.Bury and hum and hrp and hum.Health > 0 then
		wasSpinning = true
		hum.AutoRotate = false -- otherwise the humanoid fights the spin while you walk
		local turns = math.clamp(settings.SpinRps, 0.01, 100)
		hrp.CFrame = hrp.CFrame * CFrame.Angles(0, math.pi * 2 * turns * dt, 0)
	elseif wasSpinning then
		wasSpinning = false
		if hum then hum.AutoRotate = true end
	end
end)

---------------------------------------------------------------------
-- LIMB CHAOS (drives the character's Motor6D joints from the client)
-- Parts are replicated from your client, so other players see the result.
---------------------------------------------------------------------
local jointRng = Random.new()
local rig = nil -- { char = Model, joints = { {m, c0, c1, sp, ph, amp} } }
local jointsModded = false
local origMassless = {} -- [part] = original Massless
local collideOrig = setmetatable({}, { __mode = "k" }) -- [part] = original CanCollide

local function noCollide(part)
	if collideOrig[part] == nil then collideOrig[part] = part.CanCollide end
	part.CanCollide = false
end

local function restoreCollide()
	for part, v in pairs(collideOrig) do
		if part.Parent then part.CanCollide = v end
		collideOrig[part] = nil
	end
end

local function buildRig(char)
	local list = {}
	for _, m in ipairs(char:GetDescendants()) do
		if m:IsA("Motor6D") and m.Name ~= "RightGrip" and m.Name ~= "RootJoint" and m.Part0 and m.Part1
			and m.Part0:IsDescendantOf(char) and m.Part1:IsDescendantOf(char) then
			table.insert(list, {
				m = m, c0 = m.C0, c1 = m.C1,
				sp = Vector3.new(jointRng:NextNumber(2, 11), jointRng:NextNumber(2, 11), jointRng:NextNumber(2, 11)),
				ph = Vector3.new(jointRng:NextNumber(0, 6.28), jointRng:NextNumber(0, 6.28), jointRng:NextNumber(0, 6.28)),
				amp = jointRng:NextNumber(0.6, 1.4),
			})
		end
	end
	rig = { char = char, joints = list }
end

local function restoreJoints()
	if rig then
		for _, j in ipairs(rig.joints) do
			if j.m.Parent then
				j.m.C0, j.m.C1 = j.c0, j.c1
			end
		end
	end
	for part, v in pairs(origMassless) do
		if part.Parent then part.Massless = v end
	end
	origMassless = {}
	jointsModded = false
end

RunService.Stepped:Connect(function()
	local char = lp.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	local active = settings.LimbChaos and hum and hrp and hum.Health > 0
	if not active then
		if jointsModded then restoreJoints() end
		return
	end
	if not rig or rig.char ~= char then buildRig(char) end
	jointsModded = true

	-- Moving limbs around changes the character's centre of mass, which shoves the
	-- physics around. Massless limbs leave only the root part in the physics.
	for _, part in ipairs(char:GetDescendants()) do
		if part:IsA("BasePart") and part ~= hrp then
			if origMassless[part] == nil then origMassless[part] = part.Massless end
			part.Massless = true
		end
	end

	local now = os.clock()
	local speed = settings.LimbSpeed
	for _, j in ipairs(rig.joints) do
		local m = j.m
		if m.Parent then
			local amp = j.amp
			m.C0 = j.c0 * CFrame.Angles(
				math.sin(now * j.sp.X * speed + j.ph.X) * amp,
				math.sin(now * j.sp.Y * speed + j.ph.Y) * amp,
				math.sin(now * j.sp.Z * speed + j.ph.Z) * amp
			)
			m.C1 = j.c1
		end
	end
end)

---------------------------------------------------------------------
-- FLIP UNDERGROUND
-- The root part is rotated 180 degrees around an axis through your feet. The feet stay on
-- the ground, everything else swings down under the floor. All parts keep their joints, so
-- the whole body is simply upside down. A hidden part is used as the camera target so the
-- camera stays above ground, and WASD still moves the feet along the floor.
---------------------------------------------------------------------
local flip = nil -- { char, P = feet pivot, yaw, off = root offset from pivot (upright, yaw-free), floorOff }
local camPart = nil
local FLIP_ROT = CFrame.Angles(math.pi, 0, 0)

local function floorHeight(origin, char)
	local ignore = { char }
	for _ = 1, 6 do
		rp.FilterDescendantsInstances = ignore
		local hit = workspace:Raycast(origin, Vector3.new(0, -16, 0), rp)
		if not hit then return nil end
		if hit.Instance.CanCollide and hit.Instance.Transparency < 0.95 then return hit.Position.Y end
		table.insert(ignore, hit.Instance)
	end
	return nil
end

local function feetPoint(char)
	local l, r = char:FindFirstChild("LeftFoot"), char:FindFirstChild("RightFoot")
	if l and r then return (l.Position + r.Position) / 2 end
	l, r = char:FindFirstChild("Left Leg"), char:FindFirstChild("Right Leg")
	if l and r then -- R6: no foot part, use the sole of the legs (a little above it)
		return (l.Position + r.Position) / 2 - Vector3.new(0, l.Size.Y / 2 - 0.3, 0)
	end
	return nil
end

local function flipRoot(f)
	return CFrame.new(f.P) * CFrame.Angles(0, f.yaw, 0) * FLIP_ROT * CFrame.new(f.off)
end

local function flipStart(char, hrp)
	local P = feetPoint(char)
	if not P then return nil end
	local look = hrp.CFrame.LookVector
	local yaw = math.atan2(-look.X, -look.Z)
	local off = CFrame.Angles(0, -yaw, 0) * (hrp.Position - P)
	local fl = floorHeight(P + Vector3.new(0, 3, 0), char)
	return { char = char, P = P, yaw = yaw, off = off, floorOff = fl and (P.Y - fl) or 0.3 }
end

local function flipEnd(hum, hrp)
	if flip and hrp and hrp.Parent then
		hrp.CFrame = CFrame.new(flip.P + Vector3.new(0, 0.6, 0)) * CFrame.Angles(0, flip.yaw, 0) * CFrame.new(flip.off)
		hrp.AssemblyLinearVelocity = Vector3.zero
	end
	if hum then
		hum.PlatformStand = false
		hum.AutoRotate = true
		hum:ChangeState(Enum.HumanoidStateType.GettingUp)
		if cam().CameraSubject == camPart then cam().CameraSubject = hum end
	end
	flip = nil
end

local function flipPlace(hum, hrp)
	hrp.CFrame = flipRoot(flip)
	hrp.AssemblyLinearVelocity = Vector3.zero
	hrp.AssemblyAngularVelocity = Vector3.zero
	if not camPart or not camPart.Parent then
		camPart = Instance.new("Part")
		camPart.Name = "UNIhubCam"
		camPart.Anchored, camPart.CanCollide, camPart.CanQuery, camPart.CanTouch = true, false, false, false
		camPart.Transparency = 1
		camPart.Size = Vector3.new(1, 1, 1)
		camPart.Parent = workspace
	end
	camPart.Position = flip.P + Vector3.new(0, 2.5, 0)
	if cam().CameraSubject ~= camPart then cam().CameraSubject = camPart end
end

local function flipActive()
	local char = lp.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if hum and hrp and hum.Health > 0 then return char, hum, hrp end
end

RunService.Stepped:Connect(function(_, dt)
	if not settings.Bury then
		if flip then
			local _, hum, hrp = flipActive()
			flipEnd(hum, hrp)
		end
		return
	end
	local char, hum, hrp = flipActive()
	if not char then flip = nil return end
	if flip and flip.char ~= char then flip = nil end
	if not flip then
		flip = flipStart(char, hrp)
		if not flip then return end
	end

	hum.PlatformStand = true
	hum.AutoRotate = false
	for _, part in ipairs(char:GetDescendants()) do
		if part:IsA("BasePart") then noCollide(part) end
	end

	-- WASD moves the feet along the floor
	local c = cam().CFrame
	local fwd = Vector3.new(c.LookVector.X, 0, c.LookVector.Z)
	local right = Vector3.new(c.RightVector.X, 0, c.RightVector.Z)
	fwd = fwd.Magnitude > 0.01 and fwd.Unit or Vector3.new(0, 0, -1)
	right = right.Magnitude > 0.01 and right.Unit or Vector3.new(1, 0, 0)
	local dir = Vector3.zero
	if UIS:IsKeyDown(Enum.KeyCode.W) then dir += fwd end
	if UIS:IsKeyDown(Enum.KeyCode.S) then dir -= fwd end
	if UIS:IsKeyDown(Enum.KeyCode.D) then dir += right end
	if UIS:IsKeyDown(Enum.KeyCode.A) then dir -= right end
	if dir.Magnitude < 0.01 and hum.MoveDirection.Magnitude > 0 then dir = hum.MoveDirection end -- thumbstick
	if dir.Magnitude > 1 then dir = dir.Unit end

	if dir.Magnitude > 0.05 then
		local P = flip.P + Vector3.new(dir.X, 0, dir.Z) * hum.WalkSpeed * dt
		local fl = floorHeight(P + Vector3.new(0, 4, 0), char)
		flip.P = fl and Vector3.new(P.X, fl + flip.floorOff, P.Z) or P
		local target = math.atan2(-dir.X, -dir.Z)
		local diff = (target - flip.yaw + math.pi) % (2 * math.pi) - math.pi
		flip.yaw += diff * math.min(1, dt * 10)
	else
		local fl = floorHeight(flip.P + Vector3.new(0, 4, 0), char)
		if fl then flip.P = Vector3.new(flip.P.X, fl + flip.floorOff, flip.P.Z) end
	end

	flipPlace(hum, hrp)
end)

-- placed again after physics so the replicated position is always the flipped one
RunService.Heartbeat:Connect(function()
	if not settings.Bury or not flip then return end
	local char, hum, hrp = flipActive()
	if char and flip.char == char then flipPlace(hum, hrp) end
end)

---------------------------------------------------------------------
-- SERVER VIEW (ghost drawn where the server has your character)
---------------------------------------------------------------------
local ghost = nil
local ghostCF = {}
local warnedNoServer = false

local function makeGhost()
	local m = Instance.new("Model")
	m.Name = "UNIhubServerGhost"
	local function part(name, size, shape)
		local p = Instance.new("Part")
		p.Name = name
		p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch = true, false, false, false
		p.Material = Enum.Material.SmoothPlastic
		p.Color = Color3.fromRGB(255, 40, 70)
		p.Transparency = 0.45
		p.Size = size
		if shape then p.Shape = shape end
		p.Parent = m
		return p
	end
	part("Root", Vector3.new(2, 2, 1))
	part("Head", Vector3.new(1.2, 1.2, 1.2), Enum.PartType.Ball)
	part("Feet", Vector3.new(2, 0.6, 1.4))
	local hl = Instance.new("Highlight")
	hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	hl.FillColor = Color3.fromRGB(255, 40, 70)
	hl.OutlineColor = Color3.new(1, 1, 1)
	hl.FillTransparency = 0.6
	hl.Parent = m
	local bb = Instance.new("BillboardGui")
	bb.AlwaysOnTop = true
	bb.Size = UDim2.fromOffset(150, 22)
	bb.StudsOffset = Vector3.new(0, 2.5, 0)
	bb.Adornee = m.Root
	bb.Parent = m.Root
	local lbl = Instance.new("TextLabel")
	lbl.Name = "Lbl"
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.BackgroundTransparency = 1
	lbl.Font = Enum.Font.GothamBold
	lbl.TextSize = 14
	lbl.TextColor3 = Color3.new(1, 1, 1)
	lbl.TextStrokeTransparency = 0.3
	lbl.Parent = bb
	m.Parent = workspace
	return m
end

RunService.RenderStepped:Connect(function()
	if not settings.ShowServer then
		if ghost then ghost:Destroy() ghost = nil ghostCF = {} end
		return
	end
	local rootCF = lp:GetAttribute("HubSrvRoot")
	if typeof(rootCF) ~= "CFrame" then
		if not warnedNoServer then
			warnedNoServer = true
			notify("No server data. Put this same code in a Script in ServerScriptService.", false)
		end
		if ghost then ghost.Parent = nil end
		return
	end
	if not ghost or not ghost.Parent then
		ghost = ghost or makeGhost()
		ghost.Parent = workspace
	end
	local targets = { Root = rootCF, Head = lp:GetAttribute("HubSrvHead"), Feet = lp:GetAttribute("HubSrvFeet") }
	for name, cf in pairs(targets) do
		local p = ghost:FindFirstChild(name)
		if p and typeof(cf) == "CFrame" then
			ghostCF[name] = ghostCF[name] and ghostCF[name]:Lerp(cf, 0.5) or cf
			p.CFrame = ghostCF[name]
		elseif p then
			p.Transparency = 1
		end
	end
	local myRoot = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
	local lbl = ghost.Root:FindFirstChild("BillboardGui") and ghost.Root.BillboardGui:FindFirstChild("Lbl")
	if lbl then
		local d = myRoot and (myRoot.Position - rootCF.Position).Magnitude or 0
		lbl.Text = string.format("SERVER  (off by %.1f studs)", d)
	end
end)

---------------------------------------------------------------------
-- MOVEMENT (walk speed, jump power, infinite jump, fly, noclip)
---------------------------------------------------------------------
local moved = { speed = false, jump = false, fly = false }
local orig = { speed = 16, jumpPower = 50, useJump = false }

-- Fly uses physics constraints (a LinearVelocity that cancels gravity and moves you,
-- plus an AlignOrientation that keeps you upright and facing the camera).
local fly = { att = nil, lv = nil, ao = nil, vel = Vector3.zero }

local function flyDestroy()
	for _, k in ipairs({ "lv", "ao", "att" }) do
		if fly[k] then
			fly[k]:Destroy()
			fly[k] = nil
		end
	end
	fly.vel = Vector3.zero
end

local function flyStop(hum)
	flyDestroy()
	hum.PlatformStand = false
	hum:ChangeState(Enum.HumanoidStateType.GettingUp)
end

local function flyStep(hum, hrp, dt)
	if not fly.att or fly.att.Parent ~= hrp then
		flyDestroy()
		fly.att = Instance.new("Attachment")
		fly.att.Name = "UNIhubFly"
		fly.att.Parent = hrp

		fly.lv = Instance.new("LinearVelocity")
		fly.lv.Attachment0 = fly.att
		fly.lv.RelativeTo = Enum.ActuatorRelativeTo.World
		fly.lv.MaxForce = math.huge
		fly.lv.VectorVelocity = Vector3.zero
		fly.lv.Parent = hrp

		fly.ao = Instance.new("AlignOrientation")
		fly.ao.Mode = Enum.OrientationAlignmentMode.OneAttachment
		fly.ao.Attachment0 = fly.att
		fly.ao.MaxTorque = math.huge
		fly.ao.Responsiveness = 60
		fly.ao.Parent = hrp
	end

	hum.PlatformStand = true

	local cf = cam().CFrame
	local dir = Vector3.zero
	if UIS:IsKeyDown(Enum.KeyCode.W) then dir += cf.LookVector end
	if UIS:IsKeyDown(Enum.KeyCode.S) then dir -= cf.LookVector end
	if UIS:IsKeyDown(Enum.KeyCode.D) then dir += cf.RightVector end
	if UIS:IsKeyDown(Enum.KeyCode.A) then dir -= cf.RightVector end
	if UIS:IsKeyDown(Enum.KeyCode.Space) then dir += Vector3.yAxis end
	if UIS:IsKeyDown(Enum.KeyCode.LeftControl) then dir -= Vector3.yAxis end
	if dir.Magnitude < 0.01 and hum.MoveDirection.Magnitude > 0 then
		dir = hum.MoveDirection -- thumbstick / mobile
	end
	if dir.Magnitude > 1 then dir = dir.Unit end

	fly.vel = fly.vel:Lerp(dir * settings.FlySpeed, math.clamp(dt * 12, 0, 1))
	fly.lv.VectorVelocity = fly.vel

	local look = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
	if settings.Spin or look.Magnitude < 0.01 then
		fly.ao.Enabled = false
	else
		fly.ao.Enabled = true
		fly.ao.CFrame = CFrame.lookAt(Vector3.zero, look)
	end
end

-- Walk speed / jump power are re-applied every frame AND the moment a game script changes them.
local function applyStats(hum)
	if settings.SpeedOn then
		if not moved.speed then
			moved.speed = true
			orig.speed = hum.WalkSpeed
		end
		if hum.WalkSpeed ~= settings.WalkSpeed then hum.WalkSpeed = settings.WalkSpeed end
	elseif moved.speed then
		moved.speed = false
		hum.WalkSpeed = orig.speed
	end

	if settings.JumpOn then
		if not moved.jump then
			moved.jump = true
			orig.jumpPower, orig.useJump = hum.JumpPower, hum.UseJumpPower
		end
		if not hum.UseJumpPower then hum.UseJumpPower = true end
		if hum.JumpPower ~= settings.JumpPower then hum.JumpPower = settings.JumpPower end
	elseif moved.jump then
		moved.jump = false
		hum.UseJumpPower = orig.useJump
		hum.JumpPower = orig.jumpPower
	end
end

local lockConns = {}
local hookedHum = nil
local function hookHumanoid(hum)
	for _, conn in ipairs(lockConns) do conn:Disconnect() end
	lockConns = {}
	table.insert(lockConns, hum:GetPropertyChangedSignal("WalkSpeed"):Connect(function()
		if settings.SpeedOn and hum.WalkSpeed ~= settings.WalkSpeed then hum.WalkSpeed = settings.WalkSpeed end
	end))
	table.insert(lockConns, hum:GetPropertyChangedSignal("JumpPower"):Connect(function()
		if settings.JumpOn and hum.JumpPower ~= settings.JumpPower then hum.JumpPower = settings.JumpPower end
	end))
	table.insert(lockConns, hum:GetPropertyChangedSignal("UseJumpPower"):Connect(function()
		if settings.JumpOn and not hum.UseJumpPower then hum.UseJumpPower = true end
	end))
end

RunService.Stepped:Connect(function(_, dt)
	if not settings.Noclip and not settings.Bury and next(collideOrig) ~= nil then
		restoreCollide()
	end

	local char = lp.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hum or not hrp or hum.Health <= 0 then return end

	if hum ~= hookedHum then
		hookedHum = hum
		hookHumanoid(hum)
	end
	applyStats(hum)

	if settings.Fly and not settings.Bury then
		moved.fly = true
		flyStep(hum, hrp, dt)
	elseif moved.fly then
		moved.fly = false
		flyStop(hum)
	end

	if settings.Noclip then
		for _, part in ipairs(char:GetDescendants()) do
			if part:IsA("BasePart") then noCollide(part) end
		end
	end
end)

RunService.Heartbeat:Connect(function()
	local hum = lp.Character and lp.Character:FindFirstChildOfClass("Humanoid")
	if hum and hum.Health > 0 then applyStats(hum) end
end)

-- Infinite jump: while airborne, every jump press gives a fresh jump impulse.
UIS.JumpRequest:Connect(function()
	if not settings.InfJump or settings.Fly then return end
	local char = lp.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hum or not hrp or hum.Health <= 0 then return end
	if hum.FloorMaterial == Enum.Material.Air then
		local power = hum.UseJumpPower and hum.JumpPower or math.sqrt(2 * workspace.Gravity * hum.JumpHeight)
		local v = hrp.AssemblyLinearVelocity
		hrp.AssemblyLinearVelocity = Vector3.new(v.X, math.max(power, 1), v.Z)
		hum:ChangeState(Enum.HumanoidStateType.Jumping)
	end
end)

setOpen(true)
notify("UNIhub loaded", true)
