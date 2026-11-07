--[[
    Net a Fish! Automation Script
    UI Library: WindUI
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
local FishingShared = require(ReplicatedStorage:WaitForChild("FishingShared"))

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
    local bases = workspace:FindFirstChild("Map") and workspace.Map:FindFirstChild("Bases")
    if not bases then return nil end
    for _, b in ipairs(bases:GetChildren()) do
        if b:GetAttribute("OwnerUserId") == LocalPlayer.UserId then
            return b
        end
    end
    return nil
end

-- Clean up any previous WindUI / toggle instances
local hui = gethui and gethui()
pcall(function()
    local containers = {}
    if hui then table.insert(containers, hui) end
    if LocalPlayer:FindFirstChild("PlayerGui") then table.insert(containers, LocalPlayer.PlayerGui) end
    for _, parent in ipairs(containers) do
        for _, c in ipairs(parent:GetChildren()) do
            if c.Name:find("WindUI") or c.Name == "NetAFishTogglePill" then
                pcall(function() c:Destroy() end)
            end
        end
    end
end)

-- Load WindUI
local WindUI = loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()

local Window = WindUI:CreateWindow({
    Title = "Net a Fish! Automation",
    Icon = "fish",
    Folder = "NetAFishAutomation",
    Size = UDim2.fromOffset(560, 430),
    Theme = "Dark",
    ToggleKey = Enum.KeyCode.RightControl,
    OpenButton = {
        Enabled = false,
    },
})

-- Persistent Floating Minimization Pill
local toggleGui = Instance.new("ScreenGui")
toggleGui.Name = "NetAFishTogglePill"
toggleGui.ResetOnSpawn = false
toggleGui.DisplayOrder = 99999
toggleGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
toggleGui.Parent = LocalPlayer:WaitForChild("PlayerGui")

local toggleBtn = Instance.new("TextButton")
toggleBtn.Name = "ToggleButton"
toggleBtn.Size = UDim2.fromOffset(190, 38)
toggleBtn.Position = UDim2.new(0.5, -95, 0, 18)
toggleBtn.BackgroundColor3 = Color3.fromRGB(20, 24, 38)
toggleBtn.Text = "🎣 Minimize [R-Ctrl]"
toggleBtn.TextColor3 = Color3.fromRGB(240, 245, 255)
toggleBtn.TextSize = 13
toggleBtn.FontFace = Font.new("rbxasset://fonts/families/SourceSansPro.json", Enum.FontWeight.Bold)
toggleBtn.AutoButtonColor = true
toggleBtn.Parent = toggleGui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 12)
corner.Parent = toggleBtn

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(56, 200, 100)
stroke.Thickness = 2
stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
stroke.Parent = toggleBtn

-- Make toggle button draggable
local dragging = false
local dragStart, startPos, dragInput

trackConn(toggleBtn.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        startPos = toggleBtn.Position
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                dragging = false
            end
        end)
    end
end))

trackConn(toggleBtn.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
        dragInput = input
    end
end))

trackConn(UserInputService.InputChanged:Connect(function(input)
    if input == dragInput and dragging then
        local delta = input.Position - dragStart
        toggleBtn.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
    end
end))

local isMenuOpen = true
local function toggleMenu()
    if isMenuOpen then
        isMenuOpen = false
        pcall(function() Window:Close() end)
        toggleBtn.Text = "🎣 Open Menu [R-Ctrl]"
        stroke.Color = Color3.fromRGB(52, 146, 255)
    else
        isMenuOpen = true
        pcall(function() Window:Open() end)
        toggleBtn.Text = "🎣 Minimize [R-Ctrl]"
        stroke.Color = Color3.fromRGB(56, 200, 100)
    end
end

trackConn(toggleBtn.MouseButton1Click:Connect(toggleMenu))

trackConn(UserInputService.InputBegan:Connect(function(input, gpe)
    if not gpe and input.KeyCode == Enum.KeyCode.RightControl then
        toggleMenu()
    end
end))

Window:OnClose(function()
    isMenuOpen = false
    toggleBtn.Text = "🎣 Open Menu [R-Ctrl]"
    stroke.Color = Color3.fromRGB(52, 146, 255)
end)

Window:OnOpen(function()
    isMenuOpen = true
    toggleBtn.Text = "🎣 Minimize [R-Ctrl]"
    stroke.Color = Color3.fromRGB(56, 200, 100)
end)

-- Teardown registration
local function cleanup()
    running = false
    for _, conn in ipairs(trackedConnections) do
        pcall(function() conn:Disconnect() end)
    end
    table.clear(trackedConnections)

    pcall(function()
        if toggleGui and toggleGui.Parent then
            toggleGui:Destroy()
        end
    end)
    pcall(function()
        if Window and Window.Destroy then
            Window:Destroy()
        end
    end)
end

if isLiveReload and STATE.onCleanup then
    STATE.onCleanup(cleanup)
end

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
-- UI Tabs
-- ============================================================

-- Main Fishing Tab
local FarmTab = Window:Tab({
    Title = "Auto Farm",
    Icon = "flame",
})

FarmTab:Toggle({
    Title = "Auto Throw Net",
    Desc = "Automatically casts the net whenever it is idle",
    Value = Config.AutoThrow,
    Callback = function(val)
        Config.AutoThrow = val
    end,
})

FarmTab:Toggle({
    Title = "Auto Reel In",
    Desc = "Pulls in the net when full or timer reached",
    Value = Config.AutoReel,
    Callback = function(val)
        Config.AutoReel = val
    end,
})

FarmTab:Toggle({
    Title = "Reel When Net Is Full",
    Desc = "Pulls the net immediately once capacity is full",
    Value = Config.ReelWhenFull,
    Callback = function(val)
        Config.ReelWhenFull = val
    end,
})

FarmTab:Slider({
    Title = "Reel Timer Delay (Seconds)",
    Desc = "Max seconds to wait before pulling net (0 = wait for full)",
    Value = { Min = 0, Max = 60, Default = Config.ReelDelay },
    Callback = function(val)
        Config.ReelDelay = val
    end,
})

FarmTab:Toggle({
    Title = "Auto Dismiss / Resolve Catch",
    Desc = "Instantly claims fish and bypasses the catch popup UI",
    Value = Config.AutoResolveCatch,
    Callback = function(val)
        Config.AutoResolveCatch = val
    end,
})

FarmTab:Toggle({
    Title = "Auto Collect Showcase Cash",
    Desc = "Enables auto collect gamepass or sweeps dock pads",
    Value = Config.AutoCollectCash,
    Callback = function(val)
        Config.AutoCollectCash = val
        if val then
            pcall(function()
                SetSettingRemote:FireServer("AutoCollect", true)
                LocalPlayer:SetAttribute("Set_AutoCollect", true)
            end)
            WindUI:Notify({
                Title = "Auto Collect",
                Content = "Auto collect enabled!",
                Icon = "circle-dollar-sign",
                Duration = 2,
            })
        end
    end,
})

FarmTab:Slider({
    Title = "Collect Cash Interval (Seconds)",
    Desc = "How often to collect money from pedestals",
    Value = { Min = 1, Max = 10, Default = Config.CollectCashInterval },
    Callback = function(val)
        Config.CollectCashInterval = val
    end,
})

FarmTab:Button({
    Title = "Collect All Showcase Cash Now",
    Desc = "Instantly collects all cash currently waiting on pedestals",
    Callback = function()
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

        WindUI:Notify({
            Title = "Cash Collected",
            Content = "Collected from " .. count .. " pedestals!",
            Icon = "circle-dollar-sign",
            Duration = 2,
        })
    end,
})

FarmTab:Button({
    Title = "Teleport to My Dock / Base",
    Desc = "Returns you to your dock if you wander off",
    Callback = function()
        GoHomeRemote:FireServer()
    end,
})

-- Upgrades & Progression Tab
local UpgradeTab = Window:Tab({
    Title = "Upgrades & Rebirth",
    Icon = "trending-up",
})

UpgradeTab:Toggle({
    Title = "Auto Upgrade Net Tiers",
    Desc = "Automatically buys the next tier net when you have enough cash",
    Value = Config.AutoUpgradeNets,
    Callback = function(val)
        Config.AutoUpgradeNets = val
    end,
})

UpgradeTab:Toggle({
    Title = "Auto Upgrade Stats",
    Desc = "Automatically purchases affordable upgrades (Luck, Reel, Weave, etc.)",
    Value = Config.AutoUpgradeStats,
    Callback = function(val)
        Config.AutoUpgradeStats = val
    end,
})

UpgradeTab:Toggle({
    Title = "Auto Rebirth",
    Desc = "Automatically rebirths as soon as cash & catch requirements are met",
    Value = Config.AutoRebirth,
    Callback = function(val)
        Config.AutoRebirth = val
    end,
})

-- Showcase & Misc Tab
local MiscTab = Window:Tab({
    Title = "Showcase & Misc",
    Icon = "sparkles",
})

MiscTab:Toggle({
    Title = "Auto Equip Best (Smart)",
    Desc = "Only equips when a stronger fish or empty dock slot is found",
    Value = Config.AutoEquipBest,
    Callback = function(val)
        Config.AutoEquipBest = val
    end,
})

MiscTab:Button({
    Title = "Equip Best Now (Force)",
    Desc = "Immediately forces equip best setup on your dock",
    Callback = function()
        BestSetupRemote:FireServer()
        WindUI:Notify({
            Title = "Showcase",
            Content = "Forced equip best setup!",
            Icon = "check",
            Duration = 2,
        })
    end,
})

-- Anti-AFK & Stability Tab
local AntiAfkTab = Window:Tab({
    Title = "Anti-AFK & Stability",
    Icon = "shield-check",
})

AntiAfkTab:Toggle({
    Title = "Anti-AFK Mode (Anti-Crash)",
    Desc = "Prevents Roblox 20m idle kick & blocks game's 16m auto-reconnect teleport",
    Value = Config.AntiAfk,
    Callback = function(val)
        Config.AntiAfk = val
        if val then
            applyAntiCrashSettings()
            WindUI:Notify({
                Title = "Anti-AFK Active",
                Content = "Auto-reconnect teleport blocked & idle kick prevented.",
                Icon = "shield-check",
                Duration = 2.5,
            })
        end
    end,
})

AntiAfkTab:Button({
    Title = "Force Refresh Anti-Crash Guards",
    Desc = "Re-applies anti-teleport and ensures 3D rendering is enabled",
    Callback = function()
        applyAntiCrashSettings()
        WindUI:Notify({
            Title = "Guards Refreshed",
            Content = "Set_StayAFK set to false; 3D rendering enabled.",
            Icon = "check",
            Duration = 2,
        })
    end,
})

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
                            pcall(function()
                                WindUI:Notify({
                                    Title = "Showcase Upgraded",
                                    Content = "Equipped stronger fish to your dock!",
                                    Icon = "sparkles",
                                    Duration = 2.5,
                                })
                            end)
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

WindUI:Notify({
    Title = "Net a Fish!",
    Content = "Automation loaded with Anti-Crash protection. Press [R-Ctrl] or toggle button.",
    Icon = "shield-check",
    Duration = 4,
})
