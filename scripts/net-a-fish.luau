--[[
    Net a Fish! Automation Script
    UI: custom built-in dashboard (no external library)
    Features:
      - Auto Throw Net & Reel In
      - Auto Dismiss Catch (Event-driven, no spam)
      - Auto Equip Best Showcase Setup
      - Auto Buy Upgrades & Net Tiers
      - Auto Rebirth (With CanRebirth validation)
      - Anti-AFK & Crash Prevention:
          * Neutralizes game's 16-minute auto-reconnect teleport (root cause of crashes)
          * Prevents Roblox 20-minute idle kick via VirtualInputManager & Idled bypass
          * Keeps 3D rendering enabled (prevents GPU driver crashes)
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local VirtualUser = game:GetService("VirtualUser")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local FishingShared: any = require(ReplicatedStorage:WaitForChild("FishingShared") :: ModuleScript)

local ThrowNetRemote = Remotes:WaitForChild("ThrowNet")
local ReelInRemote = Remotes:WaitForChild("ReelIn")
local ResolveCatchRemote = Remotes:WaitForChild("ResolveCatch")
local CatchReadyRemote = Remotes:WaitForChild("CatchReady")
local BestSetupRemote = Remotes:WaitForChild("BestSetup")
local BuyItemRemote = Remotes:WaitForChild("BuyItem")
local RebirthRequestRemote = Remotes:WaitForChild("RebirthRequest")
local GetDataRemote = Remotes:WaitForChild("GetData")
local GoHomeRemote = Remotes:WaitForChild("GoHome")
local CollectPadReqRemote = Remotes:WaitForChild("CollectPadReq")
local SetSettingRemote = Remotes:WaitForChild("SetSetting")

-- Configuration
local Config = {
    AutoThrow = false,
    AutoReel = false,
    ReelWhenFull = true,
    ReelDelay = 0, -- 0 = wait for full
    AutoResolveCatch = true,
    AutoCollectCash = false,
    CollectCashInterval = 2,
    AutoEquipBest = false,
    EquipBestInterval = 10,
    AutoUpgradeStats = false,
    AutoUpgradeNets = false,
    UpgradeInterval = 3,
    AutoRebirth = false,
    RebirthInterval = 5,
    AntiAfk = true,
}

-- Connection tracking for clean teardown
local STATE: any = nil
pcall(function()
    STATE = (getfenv() :: any).STATE
end)
local isLiveReload = (typeof(STATE) == "table")
local running = true
local trackedConnections = {}

local function trackConn(conn)
    if conn then
        table.insert(trackedConnections, conn)
    end
    return conn
end

local function isAlive()
    if isLiveReload and STATE.alive then
        return STATE.alive()
    end
    return running
end

-- Helper: Check if cooler has any fish stronger than the weakest unlocked showcase fish
local function hasBetterShowcaseFish(data)
    if not data or not data.Showcase or not data.Cooler then
        return false
    end

    local openSlots = FishingShared.OpenSlots and FishingShared.OpenSlots(data)
    if not openSlots or #openSlots == 0 then
        return false
    end

    local minShowcaseIncome = math.huge
    local hasEmptySlot = false

    for _, slot in ipairs(openSlots) do
        local fish = data.Showcase[tostring(slot)]
        if not fish then
            hasEmptySlot = true
            break
        elseif not fish.locked then
            local inc = FishingShared.ShowcaseIncome(data, fish) or (fish.v or 0)
            if inc < minShowcaseIncome then
                minShowcaseIncome = inc
            end
        end
    end

    -- If there is an empty slot and at least one fish in cooler, equip it
    if hasEmptySlot then
        for _, stack in pairs(data.Cooler) do
            if (stack.n or 0) > 0 then
                return true
            end
        end
        return false
    end

    -- If all open slots are locked, no changes can be made
    if minShowcaseIncome == math.huge then
        return false
    end

    -- Check if any fish in cooler gives higher income than the weakest unlocked showcase fish
    for _, stack in pairs(data.Cooler) do
        if (stack.n or 0) > 0 then
            local fish = FishingShared.CoolerBest and FishingShared.CoolerBest(stack)
            if fish then
                local inc = FishingShared.ShowcaseIncome(data, fish) or (fish.v or 0)
                if inc > minShowcaseIncome then
                    return true
                end
            end
        end
    end

    return false
end

-- Helper: Locate player base in workspace
local function getMyBase()
    local mapFolder = workspace:FindFirstChild("Map")
    local bases = mapFolder and mapFolder:FindFirstChild("Bases")
    if not bases then return nil end
    for _, b in ipairs(bases:GetChildren()) do
        if b:GetAttribute("OwnerUserId") == LocalPlayer.UserId then
            return b
        end
    end
    return nil
end

-- Clean up any previous UI instances
pcall(function()
    local containers = {}
    local hui = gethui and gethui()
    if hui then table.insert(containers, hui) end
    if LocalPlayer:FindFirstChild("PlayerGui") then table.insert(containers, LocalPlayer.PlayerGui) end
    for _, parent in ipairs(containers) do
        for _, c in ipairs(parent:GetChildren()) do
            if c.Name:find("WindUI") or c.Name == "NetAFishTogglePill" or c.Name == "NetAFishUI" then
                pcall(function() c:Destroy() end)
            end
        end
    end
end)

-- ============================================================
-- Branding images (Hayes Hub GitHub): logo.png for the menu icon, banner.png for the pill
-- ============================================================
local RAW = "https://raw.githubusercontent.com/clydenalvarez29-sys/Hayes-Hub/main/"
local LOGO_URLS = { RAW .. "logo/logo.png", RAW .. "logo.png" }
local BANNER_URLS = { RAW .. "logo/banner.png" }

-- Downloads a PNG once per run, saves it to the executor workspace and returns
-- a rbxasset:// path (nil if the executor lacks file/asset functions or the download fails).
local function fetchImage(fileName, urls)
    if not (writefile and getcustomasset and isfile) then return nil, nil end
    pcall(function()
        if makefolder and not isfolder("NetAFish") then makefolder("NetAFish") end
    end)
    local path = "NetAFish/" .. fileName
    local usedUrl = nil
    for _, url in ipairs(urls) do
        local ok, data = pcall(function() return game:HttpGet(url) end)
        -- PNG files start with the bytes 137 'P' 'N' 'G' (guards against saving a 404 page)
        if ok and type(data) == "string" and data:sub(2, 4) == "PNG" then
            if pcall(writefile, path, data) then
                usedUrl = url
                break
            end
        end
    end
    if not isfile(path) then return nil, nil end -- nothing downloaded now or earlier
    local ok, asset = pcall(getcustomasset, path)
    if ok and type(asset) == "string" and asset ~= "" then
        return asset, usedUrl
    end
    return nil, nil
end

local bannerAsset = fetchImage("banner.png", BANNER_URLS)
local logoAsset = fetchImage("logo.png", LOGO_URLS)

-- ============================================================
-- Anti-AFK & Anti-Crash Subsystem
-- ============================================================
-- Root Cause:
-- 1. Net a Fish's AFKKeepClient has a 16-minute idle timer that calls
--    AFKRejoin:FireServer(), triggering a server reconnect teleport.
--    Teleporting while running an executor with active UI almost always crashes Roblox.
-- 2. Setting Set_StayAFK attribute to false permanently disables AFKKeepClient's teleport.
-- 3. VirtualInputManager F15 key taps keep UserInputService and Roblox engine active
--    without interfering with gameplay.
-- 4. Disabling Idled connections prevents Roblox's built-in 20-minute disconnect dialog.

local function applyAntiCrashSettings()
    -- Disable game's auto-reconnect teleport
    pcall(function()
        LocalPlayer:SetAttribute("Set_StayAFK", false)
    end)
    -- Enable game's built-in AutoCollect pass if owned
    pcall(function()
        if LocalPlayer:GetAttribute("Pass_AutoCollect") == true then
            SetSettingRemote:FireServer("AutoCollect", true)
            LocalPlayer:SetAttribute("Set_AutoCollect", true)
        end
    end)
    -- Ensure 3D rendering stays alive
    pcall(function()
        RunService:Set3dRenderingEnabled(true)
    end)
end

applyAntiCrashSettings()

-- Keep Set_StayAFK locked to false
trackConn(LocalPlayer:GetAttributeChangedSignal("Set_StayAFK"):Connect(function()
    if Config.AntiAfk and LocalPlayer:GetAttribute("Set_StayAFK") ~= false then
        LocalPlayer:SetAttribute("Set_StayAFK", false)
    end
end))

-- Disable default Idled connections
if getconnections then
    pcall(function()
        for _, conn in ipairs(getconnections(LocalPlayer.Idled)) do
            if conn.Disable then
                conn:Disable()
            elseif conn.Disconnect then
                conn:Disconnect()
            end
        end
    end)
end

-- Fallback Idled handler
trackConn(LocalPlayer.Idled:Connect(function()
    if Config.AntiAfk then
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.zero)
        end)
    end
end))

-- Fast Catch Resolution listener (Event-driven, no spam)
trackConn(CatchReadyRemote.OnClientEvent:Connect(function()
    if Config.AutoResolveCatch then
        task.defer(function()
            ResolveCatchRemote:FireServer({})
            -- Dismiss catch GUI if present
            local catchUI = LocalPlayer.PlayerGui:FindFirstChild("CatchUI")
            if catchUI and catchUI.Enabled then
                catchUI.Enabled = false
            end
        end)
    end
end))

-- ============================================================
-- Custom UI (no external library): dashboard + feature pages
-- ============================================================
local TweenService = game:GetService("TweenService")

local PALETTE = {
    bg0      = Color3.fromRGB(10, 6, 22),
    bg1      = Color3.fromRGB(30, 16, 56),
    card     = Color3.fromRGB(34, 20, 62),
    card2    = Color3.fromRGB(52, 32, 92),
    outline  = Color3.fromRGB(104, 66, 190),
    green    = Color3.fromRGB(57, 255, 150),
    greenDim = Color3.fromRGB(20, 78, 62),
    purple   = Color3.fromRGB(168, 85, 247),
    text     = Color3.fromRGB(242, 238, 255),
    muted    = Color3.fromRGB(158, 144, 196),
    off      = Color3.fromRGB(70, 52, 112),
    danger   = Color3.fromRGB(255, 92, 124),
}

-- forward declarations (assigned further down)
local cleanup
local notify
local refreshStatus

-- ---------- tiny helpers ----------
local function new(class, props, parent)
    local inst = Instance.new(class)
    if props then
        for k, v in pairs(props) do inst[k] = v end
    end
    if parent then inst.Parent = parent end
    return inst
end

local function corner(inst, radius)
    return new("UICorner", { CornerRadius = UDim.new(0, radius) }, inst)
end

local function stroke(inst, color, thickness, transparency)
    return new("UIStroke", {
        Color = color,
        Thickness = thickness or 1,
        Transparency = transparency or 0,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    }, inst)
end

local function tween(inst, props, duration)
    pcall(function()
        TweenService:Create(inst, TweenInfo.new(duration or 0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props):Play()
    end)
end

local function label(parent, text, size, color, font, props)
    local l = new("TextLabel", {
        BackgroundTransparency = 1,
        Text = text,
        TextSize = size,
        TextColor3 = color or PALETTE.text,
        Font = font or Enum.Font.Gotham,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
        BorderSizePixel = 0,
    })
    if props then
        for k, v in pairs(props) do l[k] = v end
    end
    l.Parent = parent
    return l
end

local layoutCounter = 0
local function nextOrder()
    layoutCounter += 1
    return layoutCounter
end

local function click(btn, fn)
    trackConn(btn.MouseButton1Click:Connect(fn))
end

-- number formatting with the game's big-number suffixes (Sp = 1e24, Oc = 1e27)
local SUFFIXES = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }
local function fmtNum(n)
    if type(n) ~= "number" or n ~= n then return "—" end
    local neg = n < 0
    n = math.abs(n)
    local i = 1
    while n >= 1000 and i < #SUFFIXES do
        n = n / 1000
        i += 1
    end
    local s
    if i == 1 then
        s = string.format("%d", math.floor(n + 0.5))
    else
        s = string.format("%.2f", n) .. SUFFIXES[i]
    end
    return (neg and "-" or "") .. s
end

local function fmtTime(sec)
    sec = math.max(0, math.floor(sec))
    return string.format("%02d:%02d:%02d", math.floor(sec / 3600), math.floor(sec / 60) % 60, sec % 60)
end

-- ---------- ScreenGui ----------
local gui = new("ScreenGui", {
    Name = "NetAFishUI",
    ResetOnSpawn = false,
    DisplayOrder = 99999,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    IgnoreGuiInset = true,
})
pcall(function()
    if syn and syn.protect_gui then syn.protect_gui(gui) end
end)
gui.Parent = (gethui and gethui()) or LocalPlayer:WaitForChild("PlayerGui")

-- ---------- responsive scaling ----------
-- Every scaled element shrinks to fit the Roblox window (e.g. when it is resized / un-maximized).
local scaleTargets = {}
local function addResponsive(uiScale, w, h, minScale)
    table.insert(scaleTargets, { s = uiScale, w = w, h = h, min = minScale })
end
local function updateScales()
    local vp = gui.AbsoluteSize
    if vp.X <= 0 or vp.Y <= 0 then
        local cam = workspace.CurrentCamera
        vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
    end
    for _, t in ipairs(scaleTargets) do
        t.s.Scale = math.clamp(math.min((vp.X - 24) / t.w, (vp.Y - 24) / t.h), t.min, 1)
    end
end

-- ---------- toast notifications ----------
local toastHolder = new("Frame", {
    Name = "Toasts",
    BackgroundTransparency = 1,
    AnchorPoint = Vector2.new(1, 1),
    Position = UDim2.new(1, -16, 1, -16),
    Size = UDim2.fromOffset(290, 320),
    ZIndex = 50,
}, gui)
new("UIListLayout", {
    SortOrder = Enum.SortOrder.LayoutOrder,
    VerticalAlignment = Enum.VerticalAlignment.Bottom,
    HorizontalAlignment = Enum.HorizontalAlignment.Right,
    Padding = UDim.new(0, 8),
}, toastHolder)
addResponsive(new("UIScale", {}, toastHolder), 330, 340, 0.45)

notify = function(title, content, duration)
    local t = new("Frame", {
        Size = UDim2.new(1, 0, 0, 54),
        BackgroundColor3 = PALETTE.bg1,
        BackgroundTransparency = 0.05,
        BorderSizePixel = 0,
        LayoutOrder = nextOrder(),
        ZIndex = 50,
    }, toastHolder)
    corner(t, 10)
    local st = stroke(t, PALETTE.green, 1.2, 0.2)
    new("Frame", {
        Size = UDim2.new(0, 3, 1, -16), Position = UDim2.fromOffset(8, 8),
        BackgroundColor3 = PALETTE.green, BorderSizePixel = 0, ZIndex = 51,
    }, t)
    label(t, tostring(title), 13, PALETTE.green, Enum.Font.GothamBold, {
        Position = UDim2.fromOffset(20, 8), Size = UDim2.new(1, -30, 0, 16), ZIndex = 51,
    })
    label(t, tostring(content), 11, PALETTE.text, Enum.Font.Gotham, {
        Position = UDim2.fromOffset(20, 26), Size = UDim2.new(1, -30, 0, 22),
        TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, ZIndex = 51,
    })
    task.delay(duration or 2.5, function()
        if not t.Parent then return end
        tween(t, { BackgroundTransparency = 1 }, 0.25)
        tween(st, { Transparency = 1 }, 0.25)
        for _, d in ipairs(t:GetDescendants()) do
            if d:IsA("TextLabel") then tween(d, { TextTransparency = 1 }, 0.25) end
            if d:IsA("Frame") then tween(d, { BackgroundTransparency = 1 }, 0.25) end
        end
        task.wait(0.3)
        pcall(function() t:Destroy() end)
    end)
end

-- ---------- main window ----------
local WIN_W, WIN_H = 760, 470

local window = new("Frame", {
    Name = "Window",
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.fromOffset(WIN_W, WIN_H),
    BackgroundColor3 = PALETTE.bg0,
    BorderSizePixel = 0,
    ClipsDescendants = true,
}, gui)
corner(window, 16)
stroke(window, PALETTE.outline, 1.5, 0.15)
new("UIGradient", {
    Color = ColorSequence.new(PALETTE.bg1, PALETTE.bg0),
    Rotation = 60,
}, window)
local winScale = new("UIScale", {}, window)
addResponsive(winScale, WIN_W, WIN_H, 0.3)

-- if the window ends up off-screen after a resize, bring it back to the center
local function keepOnScreen()
    local vp = gui.AbsoluteSize
    local pos, size = window.AbsolutePosition, window.AbsoluteSize
    if pos.X < 0 or pos.Y < 0 or pos.X + size.X > vp.X + 1 or pos.Y + size.Y > vp.Y + 1 then
        window.Position = UDim2.fromScale(0.5, 0.5)
    end
end
trackConn(gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
    updateScales()
    task.defer(keepOnScreen)
end))
if workspace.CurrentCamera then
    trackConn(workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
        updateScales()
        task.defer(keepOnScreen)
    end))
end
updateScales()

-- starfield backdrop
do
    local rng = Random.new(7)
    local stars = new("Frame", { Name = "Stars", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 0 }, window)
    for _ = 1, 46 do
        local sz = rng:NextNumber(1, 2.4)
        local star = new("Frame", {
            BackgroundColor3 = Color3.new(1, 1, 1),
            BackgroundTransparency = rng:NextNumber(0.55, 0.92),
            BorderSizePixel = 0,
            Size = UDim2.fromOffset(sz, sz),
            Position = UDim2.fromScale(rng:NextNumber(), rng:NextNumber()),
        }, stars)
        corner(star, 2)
    end
end

-- sidebar
local sidebar = new("Frame", {
    Name = "Sidebar",
    Size = UDim2.new(0, 64, 1, 0),
    BackgroundColor3 = Color3.fromRGB(12, 7, 24),
    BackgroundTransparency = 0.2,
    BorderSizePixel = 0,
}, window)
new("Frame", {
    AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 0), Size = UDim2.new(0, 1, 1, 0),
    BackgroundColor3 = PALETTE.outline, BackgroundTransparency = 0.6, BorderSizePixel = 0,
}, sidebar)

local navList = new("Frame", {
    BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 12), Size = UDim2.new(1, 0, 1, -24),
}, sidebar)
new("UIListLayout", {
    Padding = UDim.new(0, 8),
    SortOrder = Enum.SortOrder.LayoutOrder,
    HorizontalAlignment = Enum.HorizontalAlignment.Center,
}, navList)

-- logo (logo.png from GitHub, emoji fallback)
local logoBox = new("Frame", {
    Size = UDim2.fromOffset(46, 46), BackgroundColor3 = PALETTE.card, BorderSizePixel = 0, LayoutOrder = 0,
}, navList)
corner(logoBox, 12)
stroke(logoBox, PALETTE.green, 1.5, 0.2)
if logoAsset then
    local img = new("ImageLabel", {
        BackgroundTransparency = 1, Size = UDim2.new(1, -8, 1, -8), Position = UDim2.fromOffset(4, 4),
        Image = logoAsset, ScaleType = Enum.ScaleType.Fit,
    }, logoBox)
else
    label(logoBox, "🎣", 24, PALETTE.text, Enum.Font.GothamBold, {
        Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center,
    })
end
new("Frame", { Size = UDim2.fromOffset(8, 6), BackgroundTransparency = 1, LayoutOrder = 1 }, navList) -- spacer

-- header
local header = new("Frame", {
    Name = "Header", Position = UDim2.fromOffset(64, 0), Size = UDim2.new(1, -64, 0, 60), BackgroundTransparency = 1,
}, window)
local titleLbl = label(header, "Dashboard", 22, PALETTE.text, Enum.Font.GothamBold, {
    Position = UDim2.fromOffset(16, 8), Size = UDim2.new(1, -270, 0, 26),
})
local subLbl = label(header, "Overview & quick controls", 11, PALETTE.muted, Enum.Font.Gotham, {
    Position = UDim2.fromOffset(16, 35), Size = UDim2.new(1, -270, 0, 16),
})

-- status pill (ACTIVE / IDLE)
local statusPill = new("Frame", {
    AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -96, 0, 17), Size = UDim2.fromOffset(112, 26),
    BackgroundColor3 = PALETTE.card, BorderSizePixel = 0,
}, header)
corner(statusPill, 13)
local statusStroke = stroke(statusPill, PALETTE.purple, 1.2, 0.2)
local statusDot = new("Frame", {
    Position = UDim2.fromOffset(11, 9), Size = UDim2.fromOffset(8, 8), BackgroundColor3 = PALETTE.purple, BorderSizePixel = 0,
}, statusPill)
corner(statusDot, 4)
local statusText = label(statusPill, "IDLE", 11, PALETTE.text, Enum.Font.GothamBold, {
    Position = UDim2.fromOffset(26, 0), Size = UDim2.new(1, -30, 1, 0),
})

local function headerButton(text, xOffset)
    local b = new("TextButton", {
        AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, xOffset, 0, 16), Size = UDim2.fromOffset(30, 28),
        BackgroundColor3 = PALETTE.card, BackgroundTransparency = 0.4, BorderSizePixel = 0,
        Text = text, TextColor3 = PALETTE.muted, TextSize = 14, Font = Enum.Font.GothamBold, AutoButtonColor = false,
    }, header)
    corner(b, 8)
    trackConn(b.MouseEnter:Connect(function() tween(b, { BackgroundTransparency = 0 }) end))
    trackConn(b.MouseLeave:Connect(function() tween(b, { BackgroundTransparency = 0.4 }) end))
    return b
end
local minBtn = headerButton("—", -52)
local closeBtn = headerButton("✕", -14)

-- drag the window by its header
do
    local dragging, dragStart, startPos = false, nil, nil
    trackConn(header.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = window.Position
        end
    end))
    trackConn(UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local d = (input.Position - dragStart) / winScale.Scale
            window.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end))
    trackConn(UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end))
end

-- page container
local content = new("Frame", {
    Name = "Content", Position = UDim2.fromOffset(76, 64), Size = UDim2.new(1, -88, 1, -76),
    BackgroundTransparency = 1, ClipsDescendants = true,
}, window)

-- ---------- config bindings (one source of truth, many widgets) ----------
local widgets = {}      -- key -> list of updater functions
local sideEffects = {}  -- key -> function(value)

local function register(key, updater)
    widgets[key] = widgets[key] or {}
    table.insert(widgets[key], updater)
    updater(Config[key])
end

local function setConfig(key, value)
    Config[key] = value
    local fx = sideEffects[key]
    if fx then pcall(fx, value) end
    for _, u in ipairs(widgets[key] or {}) do pcall(u, value) end
    if refreshStatus then refreshStatus() end
end

sideEffects.AutoCollectCash = function(val)
    if val then
        pcall(function()
            SetSettingRemote:FireServer("AutoCollect", true)
            LocalPlayer:SetAttribute("Set_AutoCollect", true)
        end)
        notify("Auto Collect", "Auto collect enabled!", 2)
    end
end
sideEffects.AntiAfk = function(val)
    if val then
        applyAntiCrashSettings()
        notify("Anti-AFK Active", "Auto-reconnect teleport blocked & idle kick prevented.", 2.5)
    end
end

-- ---------- reusable widgets ----------
local function box(parent, size, transparency)
    local f = new("Frame", {
        Size = size, BackgroundColor3 = PALETTE.card, BackgroundTransparency = transparency or 0.2,
        BorderSizePixel = 0, LayoutOrder = nextOrder(),
    }, parent)
    corner(f, 12)
    local st = stroke(f, PALETTE.outline, 1, 0.5)
    return f, st
end

local function newPage()
    local sf = new("ScrollingFrame", {
        BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), Visible = false,
        ScrollBarThickness = 3, ScrollBarImageColor3 = PALETTE.purple,
        AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new(),
        ScrollingDirection = Enum.ScrollingDirection.Y,
    }, content)
    new("UIListLayout", { Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder }, sf)
    new("UIPadding", { PaddingRight = UDim.new(0, 8), PaddingBottom = UDim.new(0, 6) }, sf)
    return sf
end

local function section(parent, text)
    return label(parent, text, 10, PALETTE.muted, Enum.Font.GothamBold, {
        Size = UDim2.new(1, -6, 0, 14), LayoutOrder = nextOrder(),
    })
end

local function addToggle(parent, key, title, desc)
    local row, st = box(parent, UDim2.new(1, -6, 0, 58))
    label(row, title, 13, PALETTE.text, Enum.Font.GothamBold, { Position = UDim2.fromOffset(14, 10), Size = UDim2.new(1, -90, 0, 16) })
    label(row, desc, 10, PALETTE.muted, Enum.Font.Gotham, {
        Position = UDim2.fromOffset(14, 28), Size = UDim2.new(1, -90, 0, 24),
        TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top,
    })
    local sw = new("Frame", {
        AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -14, 0.5, 0), Size = UDim2.fromOffset(44, 24),
        BackgroundColor3 = PALETTE.off, BorderSizePixel = 0,
    }, row)
    corner(sw, 12)
    local knob = new("Frame", {
        Position = UDim2.fromOffset(3, 3), Size = UDim2.fromOffset(18, 18), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0,
    }, sw)
    corner(knob, 9)
    local hit = new("TextButton", { BackgroundTransparency = 1, Text = "", Size = UDim2.fromScale(1, 1) }, row)
    click(hit, function() setConfig(key, not Config[key]) end)
    register(key, function(v)
        tween(sw, { BackgroundColor3 = v and PALETTE.green or PALETTE.off })
        tween(knob, { Position = v and UDim2.fromOffset(23, 3) or UDim2.fromOffset(3, 3), BackgroundColor3 = v and PALETTE.bg0 or Color3.new(1, 1, 1) })
        tween(st, { Color = v and PALETTE.green or PALETTE.outline, Transparency = v and 0.2 or 0.5 })
    end)
    return row
end

local function addSlider(parent, key, title, desc, min, max, step, unit)
    local row = box(parent, UDim2.new(1, -6, 0, 66))
    label(row, title, 13, PALETTE.text, Enum.Font.GothamBold, { Position = UDim2.fromOffset(14, 8), Size = UDim2.new(1, -120, 0, 16) })
    label(row, desc, 10, PALETTE.muted, Enum.Font.Gotham, { Position = UDim2.fromOffset(14, 25), Size = UDim2.new(1, -28, 0, 14) })
    local valLbl = label(row, "", 13, PALETTE.green, Enum.Font.GothamBold, {
        AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 8), Size = UDim2.fromOffset(100, 16),
        TextXAlignment = Enum.TextXAlignment.Right,
    })
    local track = new("Frame", {
        Position = UDim2.new(0, 14, 0, 49), Size = UDim2.new(1, -28, 0, 6), BackgroundColor3 = PALETTE.off, BorderSizePixel = 0,
    }, row)
    corner(track, 3)
    local fill = new("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = PALETTE.green, BorderSizePixel = 0 }, track)
    corner(fill, 3)
    local knob = new("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.fromOffset(14, 14),
        BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0,
    }, track)
    corner(knob, 7)
    local hit = new("TextButton", {
        BackgroundTransparency = 1, Text = "", Position = UDim2.new(0, 14, 0, 40), Size = UDim2.new(1, -28, 0, 24),
    }, row)

    local dragging = false
    local function applyX(x)
        local w = track.AbsoluteSize.X
        if w <= 0 then return end
        local rel = math.clamp((x - track.AbsolutePosition.X) / w, 0, 1)
        local val = min + rel * (max - min)
        val = math.clamp(math.floor(val / step + 0.5) * step, min, max)
        if Config[key] ~= val then setConfig(key, val) end
    end
    trackConn(hit.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            applyX(input.Position.X)
        end
    end))
    trackConn(UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            applyX(input.Position.X)
        end
    end))
    trackConn(UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end))
    register(key, function(v)
        local rel = (max > min) and math.clamp((v - min) / (max - min), 0, 1) or 0
        fill.Size = UDim2.fromScale(rel, 1)
        knob.Position = UDim2.fromScale(rel, 0.5)
        valLbl.Text = tostring(v) .. (unit or "")
    end)
    return row
end

local function addButton(parent, title, desc, buttonText, callback)
    local row = box(parent, UDim2.new(1, -6, 0, 58))
    label(row, title, 13, PALETTE.text, Enum.Font.GothamBold, { Position = UDim2.fromOffset(14, 10), Size = UDim2.new(1, -130, 0, 16) })
    label(row, desc, 10, PALETTE.muted, Enum.Font.Gotham, {
        Position = UDim2.fromOffset(14, 28), Size = UDim2.new(1, -130, 0, 24),
        TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top,
    })
    local b = new("TextButton", {
        AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -14, 0.5, 0), Size = UDim2.fromOffset(86, 30),
        BackgroundColor3 = PALETTE.card2, BorderSizePixel = 0, Text = buttonText or "RUN",
        TextColor3 = PALETTE.green, TextSize = 12, Font = Enum.Font.GothamBold, AutoButtonColor = false,
    }, row)
    corner(b, 8)
    stroke(b, PALETTE.green, 1, 0.5)
    trackConn(b.MouseEnter:Connect(function() tween(b, { BackgroundColor3 = PALETTE.greenDim }) end))
    trackConn(b.MouseLeave:Connect(function() tween(b, { BackgroundColor3 = PALETTE.card2 }) end))
    click(b, function() task.spawn(callback) end)
    return row
end

-- ---------- tabs ----------
local TABS = {
    { id = "dash", icon = "🏠", title = "Dashboard", sub = "Overview & quick controls" },
    { id = "farm", icon = "🎣", title = "Auto Farm", sub = "Net, reel and cash collection" },
    { id = "upg",  icon = "📈", title = "Upgrades & Rebirth", sub = "Spend cash and rebirth automatically" },
    { id = "misc", icon = "✨", title = "Showcase & Misc", sub = "Dock setup and utilities" },
    { id = "afk",  icon = "🛡️", title = "Anti-AFK & Stability", sub = "Stay connected without crashes" },
}
local pages, navButtons = {}, {}

local function selectTab(id)
    for _, tab in ipairs(TABS) do
        local active = (tab.id == id)
        pages[tab.id].Visible = active
        local nb = navButtons[tab.id]
        tween(nb.btn, { BackgroundTransparency = active and 0.1 or 1, BackgroundColor3 = active and PALETTE.greenDim or PALETTE.card })
        tween(nb.st, { Transparency = active and 0.1 or 1 })
        nb.btn.TextColor3 = active and PALETTE.green or PALETTE.muted
        if active then
            titleLbl.Text = tab.title
            subLbl.Text = tab.sub
        end
    end
end

for i, tab in ipairs(TABS) do
    pages[tab.id] = newPage()
    local btn = new("TextButton", {
        Size = UDim2.fromOffset(42, 42), BackgroundColor3 = PALETTE.card, BackgroundTransparency = 1, BorderSizePixel = 0,
        Text = tab.icon, TextSize = 20, TextColor3 = PALETTE.muted, Font = Enum.Font.GothamBold,
        AutoButtonColor = false, LayoutOrder = 10 + i,
    }, navList)
    corner(btn, 12)
    local st = stroke(btn, PALETTE.green, 1.2, 1)
    navButtons[tab.id] = { btn = btn, st = st }
    trackConn(btn.MouseEnter:Connect(function()
        if not pages[tab.id].Visible then tween(btn, { BackgroundTransparency = 0.6 }) end
    end))
    trackConn(btn.MouseLeave:Connect(function()
        if not pages[tab.id].Visible then tween(btn, { BackgroundTransparency = 1 }) end
    end))
    click(btn, function() selectTab(tab.id) end)
end

-- ============================================================
-- DASHBOARD PAGE
-- ============================================================
local dash = pages.dash
local FULL = UDim2.new(1, -6, 0, 0)

-- row 1: profile + live statistics
local row1 = new("Frame", { Size = UDim2.new(1, -6, 0, 128), BackgroundTransparency = 1, LayoutOrder = nextOrder() }, dash)
new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder }, row1)

-- profile card
local profile = box(row1, UDim2.fromOffset(232, 128))
local avatar = new("ImageLabel", {
    Position = UDim2.fromOffset(14, 14), Size = UDim2.fromOffset(62, 62), BackgroundColor3 = PALETTE.card2,
    BorderSizePixel = 0, Image = "",
}, profile)
corner(avatar, 31)
stroke(avatar, PALETTE.green, 2, 0.1)
task.spawn(function()
    local ok, img = pcall(function()
        return Players:GetUserThumbnailAsync(LocalPlayer.UserId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size150x150)
    end)
    if ok and img and avatar.Parent then avatar.Image = img end
end)
local onlineDot = new("Frame", {
    Position = UDim2.fromOffset(62, 62), Size = UDim2.fromOffset(14, 14), BackgroundColor3 = PALETTE.green, BorderSizePixel = 0,
}, profile)
corner(onlineDot, 7)
stroke(onlineDot, PALETTE.card, 2, 0)
label(profile, LocalPlayer.DisplayName, 15, PALETTE.text, Enum.Font.GothamBold, { Position = UDim2.fromOffset(88, 20), Size = UDim2.new(1, -98, 0, 20) })
label(profile, "@" .. LocalPlayer.Name, 11, PALETTE.muted, Enum.Font.Gotham, { Position = UDim2.fromOffset(88, 41), Size = UDim2.new(1, -98, 0, 14) })
label(profile, "ACCOUNT AGE", 9, PALETTE.muted, Enum.Font.GothamBold, { Position = UDim2.fromOffset(14, 90), Size = UDim2.fromOffset(100, 12) })
label(profile, tostring(LocalPlayer.AccountAge) .. " days", 13, PALETTE.text, Enum.Font.GothamBold, { Position = UDim2.fromOffset(14, 104), Size = UDim2.fromOffset(100, 16) })
label(profile, "SESSION", 9, PALETTE.muted, Enum.Font.GothamBold, { Position = UDim2.fromOffset(122, 90), Size = UDim2.fromOffset(100, 12) })
local sessionLbl = label(profile, "00:00:00", 13, PALETTE.green, Enum.Font.GothamBold, { Position = UDim2.fromOffset(122, 104), Size = UDim2.fromOffset(100, 16) })

-- live statistics card
local stats = box(row1, UDim2.new(1, -242, 1, 0))
label(stats, "LIVE STATISTICS", 10, PALETTE.muted, Enum.Font.GothamBold, { Position = UDim2.fromOffset(16, 10), Size = UDim2.new(1, -32, 0, 14) })

local function statBlock(index, caption, color)
    local holder = new("Frame", {
        BackgroundTransparency = 1, Position = UDim2.new((index - 1) / 3, 16, 0, 28), Size = UDim2.new(1 / 3, -10, 0, 44),
    }, stats)
    label(holder, caption, 9, PALETTE.muted, Enum.Font.GothamBold, { Size = UDim2.new(1, 0, 0, 12) })
    return label(holder, "—", 20, color, Enum.Font.GothamBold, { Position = UDim2.fromOffset(0, 14), Size = UDim2.new(1, 0, 0, 28) })
end
local cashLbl = statBlock(1, "CASH", PALETTE.green)
local tierLbl = statBlock(2, "NET TIER", PALETTE.purple)
local incomeLbl = statBlock(3, "INCOME / MIN", PALETTE.text)

local BAR_COUNT = 36
local bars = {}
local sparkArea = new("Frame", { BackgroundTransparency = 1, Position = UDim2.new(0, 16, 0, 80), Size = UDim2.new(1, -32, 0, 38) }, stats)
for i = 1, BAR_COUNT do
    local bar = new("Frame", {
        AnchorPoint = Vector2.new(0, 1), Position = UDim2.new((i - 1) / BAR_COUNT, 1, 1, 0),
        Size = UDim2.new(1 / BAR_COUNT, -2, 0.08, 0), BackgroundColor3 = PALETTE.purple,
        BackgroundTransparency = 0.45, BorderSizePixel = 0,
    }, sparkArea)
    corner(bar, 2)
    bars[i] = bar
end

-- quick controls
section(dash, "QUICK CONTROLS")
local grid = new("Frame", { Size = UDim2.new(1, -6, 0, 133), BackgroundTransparency = 1, LayoutOrder = nextOrder() }, dash)
new("UIGridLayout", {
    CellSize = UDim2.new(1 / 3, -6, 0, 62), CellPadding = UDim2.fromOffset(9, 9), SortOrder = Enum.SortOrder.LayoutOrder,
}, grid)

local function addCard(key, icon, title, desc)
    local card = new("Frame", { BackgroundColor3 = PALETTE.card, BackgroundTransparency = 0.2, BorderSizePixel = 0, LayoutOrder = nextOrder() }, grid)
    corner(card, 12)
    local st = stroke(card, PALETTE.outline, 1, 0.5)
    local iconBox = new("Frame", {
        Position = UDim2.fromOffset(10, 12), Size = UDim2.fromOffset(38, 38), BackgroundColor3 = PALETTE.card2, BorderSizePixel = 0,
    }, card)
    corner(iconBox, 10)
    label(iconBox, icon, 18, PALETTE.text, Enum.Font.GothamBold, { Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center })
    local titleLbl2 = label(card, title, 12, PALETTE.text, Enum.Font.GothamBold, { Position = UDim2.fromOffset(56, 10), Size = UDim2.new(1, -108, 0, 16) })
    label(card, desc, 9, PALETTE.muted, Enum.Font.Gotham, {
        Position = UDim2.fromOffset(56, 28), Size = UDim2.new(1, -62, 0, 26), TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top,
    })
    local pill = label(card, "OFF", 9, PALETTE.muted, Enum.Font.GothamBold, {
        AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -8, 0, 8), Size = UDim2.fromOffset(34, 15),
        BackgroundTransparency = 0, BackgroundColor3 = PALETTE.off, TextXAlignment = Enum.TextXAlignment.Center,
    })
    corner(pill, 7)
    local hit = new("TextButton", { BackgroundTransparency = 1, Text = "", Size = UDim2.fromScale(1, 1) }, card)
    click(hit, function() setConfig(key, not Config[key]) end)
    register(key, function(v)
        tween(card, { BackgroundColor3 = v and PALETTE.greenDim or PALETTE.card })
        tween(st, { Color = v and PALETTE.green or PALETTE.outline, Transparency = v and 0.15 or 0.5 })
        titleLbl2.TextColor3 = v and PALETTE.green or PALETTE.text
        pill.Text = v and "ON" or "OFF"
        pill.TextColor3 = v and PALETTE.bg0 or PALETTE.muted
        tween(pill, { BackgroundColor3 = v and PALETTE.green or PALETTE.off })
    end)
end
addCard("AutoThrow", "🎣", "Auto Throw", "Casts the net whenever idle")
addCard("AutoReel", "🔄", "Auto Reel", "Pulls in when full or on timer")
addCard("AutoCollectCash", "💰", "Auto Collect", "Sweeps showcase cash")
addCard("AutoResolveCatch", "🐟", "Auto Catch", "Claims fish instantly")
addCard("AutoRebirth", "⭐", "Auto Rebirth", "Rebirths as soon as ready")
addCard("AntiAfk", "🛡️", "Anti-AFK", "No idle kick or rejoin")

-- row 3: active modules + status
local row3 = new("Frame", { Size = UDim2.new(1, -6, 0, 92), BackgroundTransparency = 1, LayoutOrder = nextOrder() }, dash)
new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder }, row3)

local modulesPanel = box(row3, UDim2.new(0.5, -5, 1, 0))
label(modulesPanel, "ACTIVE MODULES", 10, PALETTE.muted, Enum.Font.GothamBold, { Position = UDim2.fromOffset(14, 10), Size = UDim2.new(1, -28, 0, 14) })
local modulesLabel = label(modulesPanel, "No modules enabled", 12, PALETTE.green, Enum.Font.GothamBold, {
    Position = UDim2.fromOffset(14, 30), Size = UDim2.new(1, -28, 0, 54),
    TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top,
})

local statusPanel = box(row3, UDim2.new(0.5, -5, 1, 0))
label(statusPanel, "STATUS", 10, PALETTE.muted, Enum.Font.GothamBold, { Position = UDim2.fromOffset(14, 10), Size = UDim2.new(1, -28, 0, 14) })
local statusInfo = label(statusPanel, "", 12, PALETTE.text, Enum.Font.Gotham, {
    Position = UDim2.fromOffset(14, 30), Size = UDim2.new(1, -28, 0, 56), TextYAlignment = Enum.TextYAlignment.Top,
    RichText = true,
})

-- row 4: banner / pro tip
local tip = new("Frame", {
    Size = UDim2.new(1, -6, 0, 78), BackgroundColor3 = PALETTE.bg1, BorderSizePixel = 0,
    ClipsDescendants = true, LayoutOrder = nextOrder(),
}, dash)
corner(tip, 12)
stroke(tip, PALETTE.green, 1.2, 0.35)
if bannerAsset then
    new("ImageLabel", {
        BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Image = bannerAsset,
        ScaleType = Enum.ScaleType.Crop, ImageTransparency = 0.35,
    }, tip)
end
local tipShade = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = PALETTE.bg0, BorderSizePixel = 0 }, tip)
new("UIGradient", {
    Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.05), NumberSequenceKeypoint.new(1, 0.85) }),
}, tipShade)
label(tip, "PRO TIP", 11, PALETTE.purple, Enum.Font.GothamBold, { Position = UDim2.fromOffset(16, 12), Size = UDim2.new(1, -32, 0, 14) })
label(tip, "Press Right Ctrl or the minimize button to hide the menu. Click the small tab at the top to bring it back (drag it to move it).", 11, PALETTE.text, Enum.Font.Gotham, {
    Position = UDim2.fromOffset(16, 30), Size = UDim2.new(1, -32, 0, 40), TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top,
})

-- ============================================================
-- FEATURE PAGES
-- ============================================================
local farm = pages.farm
section(farm, "NET & CATCHES")
addToggle(farm, "AutoThrow", "Auto Throw Net", "Automatically casts the net whenever it is idle")
addToggle(farm, "AutoReel", "Auto Reel In", "Pulls in the net when full or timer reached")
addToggle(farm, "ReelWhenFull", "Reel When Net Is Full", "Pulls the net immediately once capacity is full")
addSlider(farm, "ReelDelay", "Reel Timer Delay", "Max seconds to wait before pulling the net (0 = wait for full)", 0, 60, 1, " s")
addToggle(farm, "AutoResolveCatch", "Auto Dismiss / Resolve Catch", "Instantly claims fish and bypasses the catch popup")
section(farm, "CASH")
addToggle(farm, "AutoCollectCash", "Auto Collect Showcase Cash", "Enables auto collect gamepass or sweeps dock pads")
addSlider(farm, "CollectCashInterval", "Collect Cash Interval", "How often to collect money from pedestals", 1, 10, 1, " s")
addButton(farm, "Collect All Showcase Cash Now", "Instantly collects all cash currently waiting on pedestals", "COLLECT", function()
    pcall(function()
        SetSettingRemote:FireServer("AutoCollect", true)
        LocalPlayer:SetAttribute("Set_AutoCollect", true)
    end)
    local base = getMyBase()
    local char = LocalPlayer.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    local count = 0

    if hrp and base and base:FindFirstChild("Pedestals") then
        local origCF = hrp.CFrame
        for _, ped in ipairs(base.Pedestals:GetChildren()) do
            local slot = ped:GetAttribute("Slot")
            local pad = ped:FindFirstChild("Collect") and ped.Collect:FindFirstChild("Pad")
            if slot and pad then
                hrp.CFrame = pad.CFrame + Vector3.new(0, 2, 0)
                task.wait(0.08)
                CollectPadReqRemote:FireServer(slot)
                count = count + 1
            end
        end
        task.wait(0.08)
        hrp.CFrame = origCF
    end

    notify("Cash Collected", "Collected from " .. count .. " pedestals!", 2)
end)
section(farm, "TRAVEL")
addButton(farm, "Teleport to My Dock / Base", "Returns you to your dock if you wander off", "GO HOME", function()
    GoHomeRemote:FireServer()
end)

local upg = pages.upg
section(upg, "PROGRESSION")
addToggle(upg, "AutoUpgradeNets", "Auto Upgrade Net Tiers", "Automatically buys the next tier net when you have enough cash")
addToggle(upg, "AutoUpgradeStats", "Auto Upgrade Stats", "Automatically purchases affordable upgrades (Luck, Reel, Weave, etc.)")
addToggle(upg, "AutoRebirth", "Auto Rebirth", "Automatically rebirths as soon as cash & catch requirements are met")
section(upg, "TIMING")
addSlider(upg, "UpgradeInterval", "Upgrade Check Interval", "How often to look for affordable upgrades", 1, 30, 1, " s")
addSlider(upg, "RebirthInterval", "Rebirth Check Interval", "How often to check rebirth requirements", 1, 60, 1, " s")

local misc = pages.misc
section(misc, "SHOWCASE")
addToggle(misc, "AutoEquipBest", "Auto Equip Best (Smart)", "Only equips when a stronger fish or empty dock slot is found")
addButton(misc, "Equip Best Now (Force)", "Immediately forces equip best setup on your dock", "EQUIP", function()
    BestSetupRemote:FireServer()
    notify("Showcase", "Forced equip best setup!", 2)
end)
section(misc, "SCRIPT")
addButton(misc, "Unload Script", "Stops every automation loop and removes the menu and banner tab", "UNLOAD", function()
    cleanup()
end)

local afkPage = pages.afk
section(afkPage, "PROTECTION")
addToggle(afkPage, "AntiAfk", "Anti-AFK Mode (Anti-Crash)", "Prevents Roblox 20m idle kick & blocks game's 16m auto-reconnect teleport")
addButton(afkPage, "Force Refresh Anti-Crash Guards", "Re-applies anti-teleport and ensures 3D rendering is enabled", "REFRESH", function()
    applyAntiCrashSettings()
    notify("Guards Refreshed", "Set_StayAFK set to false; 3D rendering enabled.", 2)
end)

-- ============================================================
-- STATUS, LIVE STATS, MENU TOGGLE
-- ============================================================
local FEATURES = {
    { key = "AutoThrow", name = "Auto Throw", count = true },
    { key = "AutoReel", name = "Auto Reel", count = true },
    { key = "AutoCollectCash", name = "Auto Collect", count = true },
    { key = "AutoResolveCatch", name = "Auto Catch", count = false },
    { key = "AutoEquipBest", name = "Auto Equip", count = true },
    { key = "AutoUpgradeNets", name = "Net Upgrades", count = true },
    { key = "AutoUpgradeStats", name = "Stat Upgrades", count = true },
    { key = "AutoRebirth", name = "Auto Rebirth", count = true },
    { key = "AntiAfk", name = "Anti-AFK", count = false },
}
local sessionStart = os.clock()

refreshStatus = function()
    local n = 0
    local names = {}
    for _, f in ipairs(FEATURES) do
        if Config[f.key] then
            table.insert(names, f.name)
            if f.count then n += 1 end
        end
    end
    local active = n > 0
    statusText.Text = active and ("ACTIVE · " .. n) or "IDLE"
    statusText.TextColor3 = active and PALETTE.green or PALETTE.text
    tween(statusDot, { BackgroundColor3 = active and PALETTE.green or PALETTE.purple })
    tween(statusStroke, { Color = active and PALETTE.green or PALETTE.purple })
    modulesLabel.Text = (#names > 0) and table.concat(names, "  •  ") or "No modules enabled"
    modulesLabel.TextColor3 = (#names > 0) and PALETTE.green or PALETTE.muted
    statusInfo.Text = string.format(
        "Menu key:  <b>Right Ctrl</b>\nAnti-AFK:  <b>%s</b>\nUptime:  <b>%s</b>",
        Config.AntiAfk and "ON" or "OFF", fmtTime(os.clock() - sessionStart)
    )
end

-- live stats (polled only while the dashboard is on screen)
local samples = {}
local polling = false
local function pollStats()
    if polling then return end
    polling = true
    task.spawn(function()
        local ok, data = pcall(function() return GetDataRemote:InvokeServer() end)
        polling = false
        if not (ok and type(data) == "table") then return end
        local cash = tonumber(data.Cash)
        if not cash then return end
        local now = os.clock()
        table.insert(samples, { t = now, cash = cash })
        while #samples > BAR_COUNT do table.remove(samples, 1) end

        cashLbl.Text = fmtNum(cash)
        tierLbl.Text = tostring(data.NetTier or 0)

        -- income = sum of increases over the last 2 minutes (ignores spending)
        local gained, firstT = 0, now
        for i = 2, #samples do
            if now - samples[i].t <= 120 then
                firstT = math.min(firstT, samples[i - 1].t)
                local d = samples[i].cash - samples[i - 1].cash
                if d > 0 then gained += d end
            end
        end
        local minutes = math.max((now - firstT) / 60, 1 / 60)
        incomeLbl.Text = (#samples >= 2) and fmtNum(gained / minutes) or "—"

        -- sparkline
        local lo, hi = math.huge, -math.huge
        for _, s in ipairs(samples) do
            lo = math.min(lo, s.cash)
            hi = math.max(hi, s.cash)
        end
        for i = 1, BAR_COUNT do
            local s = samples[i - (BAR_COUNT - #samples)]
            local h = 0.08
            if s then
                h = (hi > lo) and (0.12 + 0.88 * (s.cash - lo) / (hi - lo)) or 0.3
            end
            tween(bars[i], { Size = UDim2.new(1 / BAR_COUNT, -2, h, 0) }, 0.3)
        end
    end)
end

task.spawn(function()
    local lastPoll = -10
    while isAlive() do
        sessionLbl.Text = fmtTime(os.clock() - sessionStart)
        refreshStatus()
        if window.Visible and pages.dash.Visible and os.clock() - lastPoll >= 4 then
            lastPoll = os.clock()
            pollStats()
        end
        task.wait(1)
    end
end)

-- ---------- minimized banner tab ----------
local PILL_W, PILL_H = 130, 38
local hasBanner = bannerAsset ~= nil
if not hasBanner then PILL_W, PILL_H = 104, 22 end

local pill = new("ImageButton", {
    Name = "BannerTab", Size = UDim2.fromOffset(PILL_W, PILL_H), AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 8),
    BackgroundColor3 = PALETTE.bg0, Image = bannerAsset or "", ScaleType = Enum.ScaleType.Fit,
    AutoButtonColor = true, BorderSizePixel = 0,
}, gui)
corner(pill, 8)
local pillStroke = stroke(pill, PALETTE.purple, 1.5, 0)
local pillScale = new("UIScale", {}, pill)
addResponsive(pillScale, PILL_W + 40, PILL_H + 40, 0.4)
updateScales()
local pillLabel = nil
if not hasBanner then
    pillLabel = label(pill, "🎣 Open [R-Ctrl]", 10, PALETTE.text, Enum.Font.GothamBold, {
        Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center,
    })
end

local isMenuOpen = true
local function setMenu(open)
    isMenuOpen = open
    window.Visible = open
    pill.Visible = not open -- minimized tab only shows while the menu is closed
end
local function toggleMenu() setMenu(not isMenuOpen) end

-- drag the banner tab (a click only counts when it did not move)
do
    local dragging, dragStart, startPos, moved = false, nil, nil, 0
    trackConn(pill.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging, dragStart, startPos, moved = true, input.Position, pill.Position, 0
        end
    end))
    trackConn(UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local d = (input.Position - dragStart) / pillScale.Scale
            moved = math.max(moved, math.abs(d.X) + math.abs(d.Y))
            pill.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end))
    trackConn(UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end))
    trackConn(pill.MouseButton1Click:Connect(function()
        if moved < 6 then toggleMenu() end
    end))
end

trackConn(UserInputService.InputBegan:Connect(function(input, gpe)
    if not gpe and input.KeyCode == Enum.KeyCode.RightControl then
        toggleMenu()
    end
end))

click(minBtn, function() setMenu(false) end)

local closeArmed = false
click(closeBtn, function()
    if not closeArmed then
        closeArmed = true
        closeBtn.TextColor3 = PALETTE.danger
        notify("Unload script?", "Click ✕ again within 3 seconds to unload everything.", 3)
        task.delay(3, function()
            closeArmed = false
            closeBtn.TextColor3 = PALETTE.muted
        end)
    else
        cleanup()
    end
end)

-- ---------- teardown ----------
local cleanedUp = false
cleanup = function()
    if cleanedUp then return end
    cleanedUp = true
    running = false
    for k, v in pairs(Config) do
        if type(v) == "boolean" then Config[k] = false end
    end
    for _, conn in ipairs(trackedConnections) do
        pcall(function() conn:Disconnect() end)
    end
    table.clear(trackedConnections)
    pcall(function() gui:Destroy() end)
end

if isLiveReload and STATE.onCleanup then
    STATE.onCleanup(cleanup)
end

selectTab("dash")
refreshStatus()
setMenu(true)

-- ============================================================
-- Main Automation Worker Loop
-- ============================================================
task.spawn(function()
    local lastThrow = 0
    local lastReel = 0
    local lastEquipBest = 0
    local lastUpgradeCheck = 0
    local lastCollectCash = 0
    local lastAfkPulse = 0
    local lastResolveDebounce = 0

    while isAlive() do
        local now = os.clock()
        local base = getMyBase()

        -- 1. Anti-AFK Pulse every 45 seconds
        if Config.AntiAfk and (now - lastAfkPulse >= 45) then
            lastAfkPulse = now
            pcall(function()
                -- Reset UserInputService and Roblox engine idle timers
                VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.F15, false, game)
                task.wait(0.02)
                VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.F15, false, game)

                -- Keep game's auto-teleport disabled and 3D rendering active
                LocalPlayer:SetAttribute("Set_StayAFK", false)
                RunService:Set3dRenderingEnabled(true)
            end)
        end

        -- 2. Net & Fishing Operations
        if base then
            local netState = base:GetAttribute("NetState") -- "Idle", "Out", "Fishing", "Reeling"
            local netCount = base:GetAttribute("NetCount") or 0
            local netCap = base:GetAttribute("NetCap") or 0

            -- Auto Throw Net
            if Config.AutoThrow and (netState == "Idle" or netState == nil) then
                if now - lastThrow >= 1.0 then
                    lastThrow = now
                    pcall(function()
                        ThrowNetRemote:FireServer()
                    end)
                end
            end

            -- Auto Reel In
            if Config.AutoReel and (netState == "Fishing" or netState == "Out") then
                local shouldReel = false
                if Config.ReelWhenFull and netCap > 0 and netCount >= netCap then
                    shouldReel = true
                elseif Config.ReelDelay > 0 and (now - lastThrow) >= Config.ReelDelay and netCount > 0 then
                    shouldReel = true
                end

                if shouldReel and (now - lastReel >= 1.0) then
                    lastReel = now
                    pcall(function()
                        ReelInRemote:FireServer()
                    end)
                end
            end

            -- Fast Dismiss fallback (debounced to avoid remote flood)
            if Config.AutoResolveCatch and netState == "Reeling" then
                if now - lastResolveDebounce >= 1.5 then
                    lastResolveDebounce = now
                    pcall(function()
                        ResolveCatchRemote:FireServer({})
                        local catchUI = LocalPlayer.PlayerGui:FindFirstChild("CatchUI")
                        if catchUI and catchUI.Enabled then
                            catchUI.Enabled = false
                        end
                    end)
                end
            end

            -- Auto Collect Cash from Pedestals
            if Config.AutoCollectCash and (now - lastCollectCash >= Config.CollectCashInterval) then
                lastCollectCash = now
                pcall(function()
                    SetSettingRemote:FireServer("AutoCollect", true)
                    -- If user doesn't have the pass or pass is slow, do physical pad sweep
                    if LocalPlayer:GetAttribute("Pass_AutoCollect") ~= true then
                        local char = LocalPlayer.Character
                        local hrp = char and char:FindFirstChild("HumanoidRootPart")
                        if hrp and base and base:FindFirstChild("Pedestals") then
                            local origCF = hrp.CFrame
                            for _, ped in ipairs(base.Pedestals:GetChildren()) do
                                local slot = ped:GetAttribute("Slot")
                                local col = ped:FindFirstChild("Collect")
                                local pad = col and col:FindFirstChild("Pad")
                                local label = col and col:FindFirstChild("LabelAnchor") and col.LabelAnchor:FindFirstChild("CollectInfo")
                                local amt = label and label:FindFirstChild("Amount") and label.Amount.Text
                                -- Only visit pads that actually have cash waiting
                                if slot and pad and amt and amt ~= "$0" and amt ~= "" then
                                    hrp.CFrame = pad.CFrame + Vector3.new(0, 2, 0)
                                    task.wait(0.06)
                                    CollectPadReqRemote:FireServer(slot)
                                end
                            end
                            task.wait(0.06)
                            hrp.CFrame = origCF
                        end
                    end
                end)
            end
        end

        -- 3. Shared Data, Progression & Smart Equip Best Check
        local needsData = (Config.AutoUpgradeStats or Config.AutoUpgradeNets or Config.AutoRebirth or Config.AutoEquipBest)
        local minInterval = math.min(Config.UpgradeInterval, Config.RebirthInterval)
        if needsData and (now - lastUpgradeCheck >= minInterval) then
            lastUpgradeCheck = now
            pcall(function()
                local data = GetDataRemote:InvokeServer()
                if data and type(data) == "table" then
                    -- Smart Equip Best: only fires when a stronger fish or empty slot is detected
                    if Config.AutoEquipBest and hasBetterShowcaseFish(data) then
                        if now - lastEquipBest >= 2.0 then
                            lastEquipBest = now
                            BestSetupRemote:FireServer()
                            pcall(notify, "Showcase Upgraded", "Equipped stronger fish to your dock!", 2.5)
                        end
                    end

                    local currentCash = data.Cash or 0

                    -- Net Tier Upgrade
                    if Config.AutoUpgradeNets then
                        local nextNetId = (data.NetTier or 0) + 1
                        local nextNet = FishingShared.Nets[nextNetId]
                        if nextNet and currentCash >= nextNet.Cost then
                            local ok = FishingShared.NetRebirthOk(data, nextNetId)
                            if ok then
                                BuyItemRemote:FireServer("Net", nextNetId)
                                currentCash = currentCash - nextNet.Cost
                            end
                        end
                    end

                    -- Stat Upgrades
                    if Config.AutoUpgradeStats and FishingShared.Upgrades then
                        for _, upg in ipairs(FishingShared.Upgrades) do
                            local lvl = (data.Upgrades and data.Upgrades[upg.Id]) or 0
                            if lvl < upg.Max then
                                local cost = FishingShared.UpgradeCost(upg.Id, lvl)
                                if currentCash >= cost then
                                    local ok = FishingShared.UpgradeLevelOk(data, upg, lvl + 1)
                                    if ok then
                                        BuyItemRemote:FireServer("Upgrade", upg.Id)
                                        currentCash = currentCash - cost
                                    end
                                end
                            end
                        end
                    end

                    -- Rebirth Check
                    if Config.AutoRebirth then
                        local canRb = FishingShared.CanRebirth(data)
                        if canRb then
                            RebirthRequestRemote:FireServer()
                        end
                    end
                end
            end)
        end

        task.wait(0.25)
    end
end)

notify("Net a Fish!", "Loaded with Anti-Crash protection. Press Right Ctrl or the minimize button to hide; click the small tab to reopen.", 4)
