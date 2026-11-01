-- Anime Dice Hub: existing uploaded backend + connected animated GUI
-- Halloween event controls remain UI-only (no event endpoints or door locations verified).

--!nocheck
-- [Anime Dice] - full idle loop, every lever measured live against the server's
-- own data table, not assumed.
--
-- Oracle: require(RS.Framework.Features.Data.DataController).___X is the live,
-- server-mirrored player data (Money, Rolls, Rebirth, Dice, Inventory, Slots,
-- OwnedDice, ...). Every before/after check below reads it, so nothing here is a
-- client-only illusion.
--
-- What was verified (2026-09-24, bridge 1):
--   * Roll   RollService.RF.RollDice:InvokeServer() - FREE (costs no money, only
--            increments Rolls), returns { { result = <unitName> } }. No batch
--            argument works. Hard server cooldown ~2s: 40 fast calls over ~8s
--            registered only 4 rolls, and over-fast calls silently no-op (the
--            InvokeServer returns but nothing changes). So we roll at ~2.1s.
--   * Income Placed units sit on plot Slots ("1".."N" = {unitId, balance}) and
--            accrue `balance` per second. EquipBest collects EVERY slot balance
--            into Money AND re-places the best-income units into every unlocked
--            slot in one call - verified Money 235 -> 106016 (+105781) while
--            slots went 2 -> 4. It is the whole income engine.
--   * Collect CollectBalance:FireServer(slotNumber) empties one slot (number, not
--            string). EquipBest already does all of them, so this is only a
--            manual helper.
--   * Level  LevelUpSlot:FireServer(slotNumber) +1 level on that slot's unit.
--            income(attributes) = base x (1 + 0.25 x (level - 1)); price =
--            income(mutation only) x 1.6^(level-1). Payback therefore grows 1.6x
--            per level whatever the unit - levelled only up to a payback cap.
--            income() takes u.ATTRIBUTES; passing the entry drops mutation,
--            grade, trait and level (the first build did, and ranked wrong).
--   * Place  EquipBest ranks WITH level, so levelled weak units never leave.
--            (the old manual placeBest swap logic has been removed.)
--   * Dice   Dice.GetAll() -> {key, luck, price, rarity}. Higher luck rolls rarer
--            units, and rarity is the income driver (base Uncommon 100, Rare 1e3,
--            Epic 1e5, Legendary 1e7, Mythical 1e9 ... Heavenly 1e23). BuyDice
--            (key) costs Money, EquipDice(key) equips. Verified Water: -10000,
--            Normal -> Water.
--   * Rebirth Rebirth:FireServer() wipes ONLY Money (105963 -> 0), +1 Rebirth,
--            KEEPS Inventory, OwnedDice, equipped Dice, Slots and Upgrades. Each
--            level is a permanent x money AND x luck multiplier and unlocks one
--            more slot. Cost/mult ladder from Rebirths.Get(n): r1 50k x1.5,
--            r2 5M x2, r3 500M x2.5, r4 50B x3 ... r10 1e22 x14.
--   * Slots  PlotConfig.GetSlotRebirthRequirement(i): 1-4 free, 5=rb1, 6=rb2,
--            7=rb3, 8=rb4, 9=rb6 ... 15=rb12. GetMaxSlots = 15.
--   * AutoSell UpdateAutoSell:FireServer(order) sets the game's own auto-sell to
--            drop rolled units below that rarity sortOrder (Common 1, Uncommon 2,
--            Rare 3, Epic 4, Legendary 5 ...). Verified the flag stores.
--   * Codes  MonetizationConfig.Codes lists them; RedeemCode:FireServer(code)
--            redeems (RELEASE -> +10000 money verified, RedeemedCodes updated).
--   * Claims OfflineEarnings/DailyReward/GroupReward .Claim:FireServer().
--
--   * Luck   The roll only draws units whose 1-in-N chance is >= your luck and
--            weights them by luck/chance, so luck decides rarity outright. The
--            server's luck = GetBuff("Luck") x equipped die (2nd return of
--            RollDice). Dice + rebirth + boosts are the whole path to Legendary.
--   * Rerolls Grade (1 Gem) / trait (1 Trait Reroll) on the placed units, good
--            tiers protected by name so the server stops on them.
--   * Tower  The server simulates each floor; CompleteTowerFloor just asks for
--            the next one. Skipping the animation is the speed-up. CancelTower
--            only queues the end - a cancelled run must be drained or it blocks
--            every new PlayTower.
--
--   * Fuse   3 spare units -> 1 whose chance is ~0.667x their SUM, i.e. about
--            twice as rare as their mean. Balanced trios only (see doFuse).
--
-- Update of 2026-10-11, re-read from the server modules (they ship to the client):
--   * RollDice returns nothing while FusingService.Fusing is set - ONE 3s flag for
--            the whole server, set by every Fuse call before it checks the units,
--            so a failing fuse attempt still blocks everybody's rolls.
--   * The game's AutoSell is a 1-in-N chance: a rolled unit whose chance is below
--            it is sold on the spot. It was being sent a rarity index (1-11).
--   * InteractSlot with an EMPTY hand picks the slot's unit up into the hand, and
--            a unit in the hand is no longer protected from SellInventory.
--   * Units can be locked (attributes.locked); Sell and Fuse both skip them.
--   * Codes moved to Codes.CodesConfig + CodesService.RE.RedeemCode (0.5s debounce).
--   * New: rebirth points (RebirthService.AddStat, x(1 + 0.1 per point) on one
--            buff), daily/weekly quests paying Tickets (QuestService.Claim), and a
--            Ticket shop that sells gamepasses for Tickets only (QuestService.Buy).
--
-- Deliberately left out, do not add without new evidence:
--   Forging  ___X is a mirror; purchases are checked against the server copy.

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")

-- Generation guard: re-executing does not restart the VM, so every loop below
-- exits the moment a newer run bumps this counter.
_G.__ANIMEDICE = (_G.__ANIMEDICE or 0) + 1
local generation = _G.__ANIMEDICE
if _G.__ANIMEDICE_GUI then pcall(function() _G.__ANIMEDICE_GUI:Destroy() end) end

-------------------------------------------------------------------- config -----

local CONFIG = {
		autoRoll    = false,   -- fire RollDice on the server cooldown
	autoSpins   = false,   -- activate Lucky/Jackpot Spins (x100/x1000 on the next roll)
	autoCollect = false,   -- collect every slot balance (no longer places units)
	smartPlace  = false,   -- Auto Equip Best Unit: fire the game's own EquipBest
	autoLevel   = false,   -- pour a share of money into placed-slot levels
	levelShare  = 0.3,    -- fraction of money slot-leveling may spend each pass
	levelPayback = 10,    -- only buy a level that pays itself back within N minutes
	saveMinutes = 15,     -- skip leveling/fusing while the next dice/rebirth is
	                      -- this close; at 5 the fuse machine ate every rebirth
	-- Grade/trait odds come from the configs' weights. Grades: D 45%, C 28%, B 15%,
	-- A 8%, A+ 3%, S 0.9%, S+ 0.11%, Z 0.03%, 神 0.002%. Waiting for S costs ~100
	-- Gems per unit on average; "A or better" (12%) costs ~8, so that is the default.
	-- Traits: ~66% are Damage/Health (no income at all); Money II+ (x1.5) is 8.4%.
	autoGrade   = false,   -- spend Gems rerolling the placed units' grades
	gradeMin    = 3,      -- keep grades worth >= this income x (A and better)
	autoTrait   = false,   -- spend Trait Rerolls on the placed units' traits
	traitMin    = 1.5,    -- keep traits worth >= this income x (Money II and better)
	autoBoost   = false,   -- activate owned Luck/Income/Roll Speed boosts
	-- Potions tab: only ticked potion types are ever used.
	potionPick  = { ["Luck Potion"] = false, ["Speed Potion"] = false,
	                ["Coin Potion"] = false, ["Damage Potion"] = false },
	-- Potion families (by name prefix): a potion needs its family AND its buff ticked.
	potionFamilies = { Normal = true, Dragon = true, Cursed = true, Pirate = true,
	                   Leaf = true, Shadow = true, Slayer = true, Spooky = true },
	debug = false,         -- verbose console lines (sell, tower, potions); toggle with _G.AnimeDiceDebug(true)
	guiScale = 0.8,       -- window size: 0.6 small, 0.8 medium, 1.0 large (shrinks further to fit the screen)
	stackPotions = false,  -- false: one potion per category; true: one per potion kind
	-- Off by default and under a new key, so saved panels start off too: fusing
	-- eats units ("my units got stolen") and every attempt locks rolling for 3s.
	autoFusion  = false,  -- fuse spare units three at a time into rarer ones
	fuseShare   = 0.35,   -- share of money one fusion may cost...
	fuseSeconds = 30,     -- ...and never more than this many seconds of income
	autoTower   = false,   -- farm a tower for boosts, gems and trait rerolls
	tower       = "Auto (best)",  -- or a fixed tower name
	autoDice    = false,   -- buy the best affordable dice we do not own, equip best
	autoUpgrade = false,   -- buy the cheapest affordable world-pad upgrade tier
	autoRebirth = false,   -- rebirth once money reaches nextCost x factor
	rebirthMult = 1,      -- rebirth wipes ALL money and nothing else, so rebirthing
	                      -- the moment the cost is met throws away the least
	autoSell    = false,   -- keep the backpack under its cap by selling junk
	autoCodes   = false,   -- redeem every code once
	autoClaim   = false,   -- claim offline / daily / group rewards
	antiAfk     = true,    -- on at execution (toggle in Settings still works)
	autoQuests  = false,   -- claim finished daily/weekly quests (they pay Tickets)
	autoPasses  = false,   -- buy the Ticket-shop gamepasses with Tickets (no Robux)
	autoStats   = false,   -- spend rebirth points
	statPick    = "Money",-- x1.5 money for 5 points beats x1.5 luck (~x1.34 income)
}

-- Which world-pad upgrade lines auto-buy. Damage/Health join them while the tower
-- is farmed (TOWER_CATS); Walkspeed is irrelevant to an idle build.
local UPGRADE_CATS = { "Money", "Luck", "Fortune", "Roll Speed", "Unit Storage", "Sell" }
local INV_CAP_BASE = 100   -- Unit Storage buff default; each owned tier adds +5

-- Ticket-shop gamepasses, best first: More Cash x2 money, Luck x1.5, Roll Speed
-- -0.6s per roll, Ultra Luck x3; grade/trait rolls only help the rerolls.
local PASS_ORDER = { "More Cash", "Luck", "Roll Speed", "Ultra Luck", "More Grades", "More Traits" }

CONFIG.dprint = function(...) if CONFIG.debug then print(...) end end
_G.AnimeDiceDebug = function(on) CONFIG.debug = on ~= false; print("[AnimeDiceHub] debug output " .. (CONFIG.debug and "on" or "off")) end

local STATE = {
	money = 0, rolls = 0, rebirth = 0, dice = "-", nextDice = "-",
	slotsUsed = 0, slotsMax = 4, incomePerSec = 0,
	invCount = 0, invCap = INV_CAP_BASE, nextUpgrade = "-",
	rolled = 0, collected = 0, diceBought = 0, rebirths = 0, leveled = 0,
	upgradesBought = 0, sold = 0, soldValue = 0,
	gradeRolls = 0, traitRolls = 0, boostsUsed = 0, luck = 0,
	towerRuns = 0, towerFloors = 0, towerBest = 0, towerFloor = 0, towerDrops = 0,
	fused = 0, fuseLast = "-", fuseBestChance = 0,
	towerPick = "-", towerPredict = 0, towerRate = 0,
	codesDone = 0, claims = 0, questsClaimed = 0, passesBought = 0, statsAdded = 0,
	phase = "idle", note = "-", uiOwner = "-",
}

-------------------------------------------------------------- game handles -----

local Network = ReplicatedStorage:WaitForChild("Network", 15)
local Framework = ReplicatedStorage:WaitForChild("Framework", 15)

local function svc(path)
	local node = Network
	for part in string.gmatch(path, "[^%.]+") do
		node = node and node:FindFirstChild(part)
	end
	return node
end

local R = {
	RollDice        = svc("RollService.RF.RollDice"),
	EquipBest       = svc("PlotService.RE.EquipBest"),
	CollectBalance  = svc("PlotService.RE.CollectBalance"),
	LevelUpSlot     = svc("PlotService.RE.LevelUpSlot"),
	BuyDice         = svc("DiceShopService.RE.BuyDice"),
	EquipDice       = svc("DiceShopService.RE.EquipDice"),
	Rebirth         = svc("RebirthService.RE.Rebirth"),
	BuyUpgrade      = svc("RE.BuyUpgrade"),
	SellInventory   = svc("SellService.RF.SellInventory"),
	UpdateAutoSell  = svc("SellService.RE.UpdateAutoSell"),
	RedeemCode      = svc("CodesService.RE.RedeemCode") or svc("MonetizationService.RE.RedeemCode"),
	QuestClaim      = svc("QuestService.RE.Claim"),
	QuestBuy        = svc("QuestService.RE.Buy"),
	AddStat         = svc("RebirthService.RE.AddStat"),
	UnequipUnit     = svc("UnitService.RF.Unequip"),
	ClaimOffline    = svc("OfflineEarningsService.RE.Claim"),
	ClaimDaily      = svc("DailyRewardService.RE.Claim"),
	ClaimGroup      = svc("GroupRewardService.RE.Claim"),
	GradeRoll       = svc("GradeService.RE.Roll"),
	GradeProtect    = svc("GradeService.RE.SetGradeProtected"),
	TraitRoll       = svc("TraitService.RE.Roll"),
	TraitProtect    = svc("TraitService.RE.SetTraitProtected"),
	BoostUse        = svc("BoostService.RE.Use"),
	PlayTower       = svc("Towers.RF.PlayTower"),
	CompleteFloor   = svc("Towers.RF.CompleteTowerFloor"),
	CancelTower     = svc("Towers.RF.CancelTower"),
	BestTowerTeam   = svc("Towers.RE.EquipBestTowerTeam"),
	InteractSlot    = svc("PlotService.RE.InteractSlot"),
	UseSpin         = svc("SpinService.RE.Use"),
	EquipUnit       = svc("UnitService.RF.Equip"),
	Fuse            = svc("FusingService.RE.Fuse"),
	FuseResult      = svc("FusingService.RE.Result"),
	HalloweenQuestClaim = svc("HalloweenQuestService.RE.Claim"),
	TotKnocked      = svc("TrickOrTreatService.RE.Knocked"),
}

local DataController = require(Framework.Features.Data.DataController)
local Dice           = require(Framework.Features.Rolling.Dice)
local Rebirths       = require(Framework.Features.Rebirth.Rebirths)
local PlotConfig     = require(Framework.Features.Plot.PlotConfig)
local MonetConfig    = require(Framework.Features.Monetization.MonetizationConfig)
local UpgradeConfig  = require(Framework.Features.Upgrades.Upgrades)
local UpgradeTree
pcall(function() UpgradeTree = require(Framework.Features.Upgrades.TreeStructure) end)
local UnitConfig     = require(Framework.Features.Inventory.Kinds.Unit.UnitConfig)
local Grades         = require(Framework.Features.Grades.Grades)
local Traits         = require(Framework.Features.Traits.Traits)
local TowersConfig   = require(Framework.Features.Towers.Towers)
local BuffController = require(Framework.Features.Buffs.BuffController)
local FusingUtil     = require(Framework.Features.Fusing.FusingUtil)
local FusingConfig   = require(Framework.Features.Fusing.FusingConfig)
local UnitUtil
for _, m in ipairs(Framework:GetDescendants()) do
	if m.Name == "UnitUtil" and m:IsA("ModuleScript") then
		pcall(function() UnitUtil = require(m) end)
		break
	end
end
local BoostConfig
pcall(function() BoostConfig = require(Framework.Features.Inventory.Kinds.Boost.BoostConfig) end)
local BOOSTS = (BoostConfig and (BoostConfig.entries or BoostConfig)) or {}

-- Added by the 2026-10-11 update; every one optional so an older build still loads.
local CODES, QuestConfig, RebirthStats, UnitCtl
pcall(function() CODES = require(Framework.Features.Codes.CodesConfig) end)
CODES = CODES or MonetConfig.Codes or {}
pcall(function() QuestConfig = require(Framework.Features.Quests.QuestConfig) end)
pcall(function() RebirthStats = require(Framework.Features.Rebirth.RebirthStatsConfig) end)
pcall(function() UnitCtl = require(Framework.Features.Inventory.Kinds.Unit.UnitController) end)

local NumberFormatter
pcall(function() NumberFormatter = require(ReplicatedStorage.Packages.NumberFormatter) end)

local function fmt(n)
	if NumberFormatter and NumberFormatter.FormatCompact then
		local ok, s = pcall(NumberFormatter.FormatCompact, math.floor(tonumber(n) or 0))
		if ok then return s end
	end
	return tostring(math.floor(tonumber(n) or 0))
end

-- The live, server-mirrored data table. Read fresh every time - it updates in
-- place, so stale-currency mistakes are impossible as long as we never cache it.
local function data() return DataController.___X end

local function count(t)
	local n = 0
	if type(t) == "table" then for _ in pairs(t) do n = n + 1 end end
	return n
end

-- income() takes the unit's ATTRIBUTES (mutation, grade, trait, level). Passing
-- the whole inventory entry silently drops all four and made a Diamond Rare look
-- like a plain one - which is how the first build ranked, sold and fused wrong.
-- Income = base x (1 + 0.25 x (level - 1)), so:
--   curIncome   what the unit earns right now, level included (EquipBest's view)
--   baseIncome  the same at level 1 - its potential, since every placed unit is
--               levelled to the same payback cap anyway
local function curIncome(u)
	local e = u and UnitConfig.entries[u.name]
	if not e then return 0 end
	return tonumber(select(2, pcall(e.income, u.attributes or {}))) or 0
end

local function baseIncome(u)
	local e = u and UnitConfig.entries[u.name]
	if not e then return 0 end
	local a = u.attributes or {}
	return tonumber(select(2, pcall(e.income,
		{ mutation = a.mutation, grade = a.grade, trait = a.trait, level = 1 }))) or 0
end

---------------------------------------------------------------- dice model -----

-- Sorted once: name -> {luck, price}. Basic has no price (the free default).
local DICE = {}
do
	local ok, all = pcall(Dice.GetAll)
	if ok and type(all) == "table" then
		for key, def in pairs(all) do
			DICE[#DICE + 1] = {
				key = key,
				luck = tonumber(def.luck) or 0,
				price = tonumber(def.price),  -- nil for the free Basic die
			}
		end
		table.sort(DICE, function(a, b) return a.luck < b.luck end)
	end
end

local function ownedLuck()
	local d = data()
	local best, name = 0, "-"
	for _, die in ipairs(DICE) do
		if d.OwnedDice[die.key] and die.luck > best then best, name = die.luck, die.key end
	end
	return best, name
end

-- Effective roll luck = buff luck x equipped die (the 2nd return of RollDice).
-- The roll only draws units whose 1-in-N chance is >= this.
local function rollLuck()
	local d = data()
	local buffLuck = tonumber(select(2, pcall(BuffController.GetBuff, "Luck"))) or 1
	local dieLuck = 1
	for _, die in ipairs(DICE) do if die.key == d.Dice then dieLuck = die.luck end end
	return buffLuck * dieLuck
end

-- The single strongest die we can pay for right now and do not already own.
-- reserve: money that must stay untouched (a rebirth waiting for it).
local function bestAffordableDice(reserve)
	local d = data()
	local pick
	local spendable = d.Money - (reserve or 0)
	for _, die in ipairs(DICE) do
		if die.price and not d.OwnedDice[die.key] and spendable >= die.price then
			if not pick or die.luck > pick.luck then pick = die end
		end
	end
	return pick
end

------------------------------------------------------------- upgrade model -----

-- Roman numeral -> int, enough for the I..XIV tiers the game ships.
local ROMAN = { I=1, V=5, X=10 }
local function romanToInt(s)
	local total, prev = 0, 0
	for i = #s, 1, -1 do
		local v = ROMAN[s:sub(i, i)] or 0
		if v < prev then total = total - v else total = total + v end
		prev = v
	end
	return total
end

-- Per category: an ascending list of { name, price, storage } tiers.
local UPGRADE_LINES = {}
do
	for name, def in pairs(UpgradeConfig) do
		local cat, roman = name:match("^(.-)%s+([IVX]+)$")
		if cat and roman and def.price then
			UPGRADE_LINES[cat] = UPGRADE_LINES[cat] or {}
			local storage = 0
			if def.buffs and def.buffs["Unit Storage"] then
				storage = tonumber(def.buffs["Unit Storage"].amount) or 0
			end
			table.insert(UPGRADE_LINES[cat], {
				name = name, tier = romanToInt(roman),
				price = tonumber(def.price) or math.huge, storage = storage,
			})
		end
	end
	for _, list in pairs(UPGRADE_LINES) do
		table.sort(list, function(a, b) return a.tier < b.tier end)
	end
end

-- The lowest-tier upgrade in a category we do not yet own - IF it can be bought.
-- The pads are a tree (TreeStructure.GetParent) and BuyUpgrade silently refuses
-- a node whose parent is not owned. Health I hangs off Damage III, so the old
-- "cheapest next tier" picked Health I (1k) every tick, the server dropped it,
-- and not one other upgrade was bought for the whole session after that.
local function nextTier(cat)
	local owned = data().Upgrades
	for _, up in ipairs(UPGRADE_LINES[cat] or {}) do
		if not owned[up.name] then
			local parent = UpgradeTree and select(2, pcall(UpgradeTree.GetParent, up.name))
			if type(parent) == "string" and parent ~= "Start" and not owned[parent] then
				return nil                     -- locked behind another line
			end
			return up
		end
	end
	return nil
end

-- Across the enabled categories, the cheapest next tier we can pay for now.
-- Damage/Health lines only matter to the tower, so they join while it is farmed.
local TOWER_CATS = { "Damage", "Health" }

local function bestUpgrade(reserve)
	local d = data()
	local pick
	local spendable = d.Money - (reserve or 0)
	local cats = UPGRADE_CATS
	if CONFIG.autoTower then
		cats = {}
		for _, c in ipairs(UPGRADE_CATS) do cats[#cats + 1] = c end
		for _, c in ipairs(TOWER_CATS) do cats[#cats + 1] = c end
	end
	for _, cat in ipairs(cats) do
		local up = nextTier(cat)
		if up and spendable >= up.price then
			if not pick or up.price < pick.price then pick = up end
		end
	end
	return pick
end

-- Current backpack capacity. The server refuses a roll once the UNIT count
-- reaches the Unit Storage buff (+ Rolls - 1); items do not count. Fallback:
-- base 100 plus every owned Unit Storage tier's +5.
local function invCap()
	local buff = tonumber(select(2, pcall(BuffController.GetBuff, "Unit Storage")))
	if buff and buff > 0 then return buff end
	local cap = INV_CAP_BASE
	local owned = data().Upgrades
	for _, up in ipairs(UPGRADE_LINES["Unit Storage"] or {}) do
		if owned[up.name] then cap = cap + up.storage end
	end
	return cap
end

---------------------------------------------------------------- slot model -----

local function unlockedSlots()
	local rb, n = data().Rebirth, 0
	local maxS = 15
	pcall(function() maxS = PlotConfig.GetMaxSlots(rb) or 15 end)
	for i = 1, maxS do
		local req = 0
		pcall(function() req = PlotConfig.GetSlotRebirthRequirement(i) or 0 end)
		if req <= rb then n = n + 1 end
	end
	return n
end

local function nextRebirthCost()
	local d = data()
	local info
	pcall(function() info = Rebirths.Get(d.Rebirth + 1) end)
	if not info then pcall(function() info = Rebirths.GetNext(d.Rebirth) end) end
	return info and tonumber(info.cost), info and tonumber(info.moneyMultiplier)
end

--------------------------------------------------------------- unit safety -----

local function goodGrade(g)
	local def = g and Grades[g]
	return def and (tonumber(def.incomeMultiplier) or 0) >= CONFIG.gradeMin
end

local function goodTrait(t)
	local def = t and Traits[t]
	return def and (tonumber(def.incomeMultiplier) or 0) >= CONFIG.traitMin
end

-- The unit in the character's hand. The server does NOT protect it from
-- SellInventory, and InteractSlot with an empty hand puts a slot's unit there.
local function heldUnit()
	if not (UnitCtl and UnitCtl.EquippedUnit) then return nil end
	local ok, id = pcall(UnitCtl.EquippedUnit)
	return ok and id or nil
end

-- Units the automation never sells or fuses: locked in the game (the server
-- skips them too), limited (no roll chance, real trade value), carrying a grade
-- or trait that cost Gems / Trait Rerolls, or held in the hand. Three reports
-- ("my units got stolen") were spares like these going into Sell and Fuse.
local function isProtected(id, u)
	local a = u.attributes or {}
	if a.locked then return true end
	local e = UnitConfig.entries[u.name]
	if not e or e.limited then return true end
	if goodGrade(a.grade) or goodTrait(a.trait) then return true end
	return id == heldUnit()
end

-- Sell and fuse each move units around and used to run in parallel:
-- a unit picked for a slot could be sold mid-swap. One owner at a time.
local unitOwner, unitSince = nil, 0
local function claimUnits(who)
	if unitOwner and unitOwner ~= who and os.clock() - unitSince < 20 then return false end
	unitOwner, unitSince = who, os.clock()
	return true
end
local function releaseUnits(who)
	if unitOwner == who then unitOwner = nil end
end

------------------------------------------------------------------- actions -----

-- Spins (SpinService, readable): Use(name) moves one Lucky Spin (x100) / Jackpot
-- Spin (x1000) into ActiveEntries, and the next RollDice multiplies its luck by it
-- and consumes it. The codes alone hand a new account ~20 Lucky Spins - luck 200
-- instead of 2 in the first minute. One is armed at a time, right before a roll.
local SPINS = { "Jackpot Spin", "Lucky Spin" }
local function armSpin()
	if not (CONFIG.autoSpins and R.UseSpin) then return end
	local d = data()
	for _, name in ipairs(SPINS) do
		local active = d.ActiveEntries and d.ActiveEntries[name]
		if active then return end                 -- one is already waiting
	end
	for _, name in ipairs(SPINS) do
		local item = d.Inventory[name]
		if item and (tonumber(item.amount) or 0) >= 1 then
			R.UseSpin:FireServer(name)
			STATE.note = "armed " .. name
			task.wait(0.25)
			return
		end
	end
end

local function doRoll()
	if not R.RollDice then return end
	pcall(armSpin)
	local ok = pcall(function() return R.RollDice:InvokeServer() end)
	if ok then STATE.rolled = STATE.rolled + 1 end
end

-- The server's own roll cooldown: the Roll Duration buff (2.5s base, -0.15s per
-- Roll Speed pad). A fixed interval rolls slower than allowed once those land.
local function rollInterval()
	local dur = tonumber(select(2, pcall(BuffController.GetBuff, "Roll Duration"))) or 2.5
	return math.max(0.3, dur + 0.05)
end

-- Collect every slot explicitly (Auto Collect Balance). Placing the best units is
-- a separate toggle now - Auto Equip Best Unit (the game's EquipBest) - in the loop below.
-- The explicit CollectBalance per slot is what keeps the money flowing.
local function doCollectPlace()
	local d = data()
	-- Count what the slots hold as they are banked. A Money delta read 0 here:
	-- levels and upgrades spend in the same seconds, and the panel then said
	-- "collected 0" while every slot was being emptied every 5s.
	local banked = 0
	if R.CollectBalance then
		for key, slot in pairs(d.Slots) do
			banked = banked + (tonumber(slot.balance) or 0)
			pcall(function() R.CollectBalance:FireServer(tonumber(key)) end)
		end
	end
	STATE.collected = STATE.collected + banked
end

local function doDice(reserve)
	local pick = bestAffordableDice(reserve)
	if pick then
		local curLuck = ownedLuck()
		if pick.luck > curLuck then
			R.BuyDice:FireServer(pick.key)
			STATE.diceBought = STATE.diceBought + 1
			STATE.note = "bought " .. pick.key .. " dice"
			task.wait(0.2)
		end
	end
	-- Always keep the strongest owned die equipped.
	local _, bestName = ownedLuck()
	if bestName ~= "-" and data().Dice ~= bestName then
		R.EquipDice:FireServer(bestName)
	end
end

local function doUpgrade(reserve)
	if not R.BuyUpgrade then return end
	local owned = data().Upgrades
	-- "Start" (price 0) unlocks the roll area; buy it once.
	if UpgradeConfig.Start and not owned.Start then
		R.BuyUpgrade:FireServer("Start")
		task.wait(0.15)
	end
	local up = bestUpgrade(reserve)
	if up then
		R.BuyUpgrade:FireServer(up.name)
		STATE.upgradesBought = STATE.upgradesBought + 1
		STATE.note = "upgrade " .. up.name
		task.wait(0.15)
	end
end

------------------------------------------------------ rerolls, boosts, tower -----

local function itemAmount(key)
	local e = data().Inventory[key]
	return (e and tonumber(e.amount)) or 0
end

local function unitIncome(u) return baseIncome(u) end

-- The units that actually earn, strongest first: a reroll there pays the most.
local function placedUnits()
	local d = data()
	local list = {}
	for _, slot in pairs(d.Slots) do
		local u = slot.unitId and d.Inventory[slot.unitId]
		if u then list[#list + 1] = { id = slot.unitId, u = u, inc = unitIncome(u) } end
	end
	table.sort(list, function(a, b) return a.inc > b.inc end)
	return list
end

-- Protection is per grade/trait NAME and the server skips a protected one on a
-- reroll, so protecting every good tier turns "spam reroll" into "reroll until
-- it lands on something good, then stop". Only fires when a flag must change.
local function syncProtectionFlags()
	local d = data()
	for name, g in pairs(Grades) do
		if type(g) == "table" then
			local want = (tonumber(g.incomeMultiplier) or 0) >= CONFIG.gradeMin
			if R.GradeProtect and (d.ProtectedGrades[name] and true or false) ~= want then
				R.GradeProtect:FireServer(name, want)
			end
		end
	end
	for name, t in pairs(Traits) do
		if type(t) == "table" then
			local want = (tonumber(t.incomeMultiplier) or 0) >= CONFIG.traitMin
			if R.TraitProtect and (d.ProtectedTraits[name] and true or false) ~= want then
				R.TraitProtect:FireServer(name, want)
			end
		end
	end
end

-- Reroll grade and trait on the placed units until each lands on a kept tier.
-- Gems pay for grades (神 x50 at the top), Trait Rerolls for traits (Eternal x27).
local function doRerolls()
	syncProtectionFlags()
	local rolls = 0
	for _, p in ipairs(placedUnits()) do
		if rolls >= 8 then break end
		local attrs = p.u.attributes or {}
		if CONFIG.autoGrade and R.GradeRoll and not goodGrade(attrs.grade)
			and itemAmount("Gems") >= 1 then
			R.GradeRoll:FireServer(p.id)
			STATE.gradeRolls = STATE.gradeRolls + 1
			rolls = rolls + 1
			task.wait(0.25)
		end
		if CONFIG.autoTrait and R.TraitRoll and not goodTrait(attrs.trait)
			and itemAmount("Trait Reroll") >= 1 then
			R.TraitRoll:FireServer(p.id)
			STATE.traitRolls = STATE.traitRolls + 1
			rolls = rolls + 1
			task.wait(0.25)
		end
	end
end

local useBoosts, useTowerBoosts
do
-- Boosts are timed (2-5 min). Only potion types and families ticked in the Potions
-- tab are used, and only ONE potion per group at a time - always the strongest owned:
--   Stack on : one potion per (family, buff), so Normal Luck, Shadow Luck... run together
--   Stack off: one potion per buff across every ticked family
-- When the best tier runs out of the inventory the next best is used. Damage potions
-- are only fired at the start of a tower run.
-- What is already running is read from the player's data (ActiveEntries); the local
-- timer is the backstop for when that data can't be parsed.
local boostUntil = {}
local POTION_BUFF = { ["Luck Potion"] = "Luck", ["Speed Potion"] = "Roll Duration",
	["Coin Potion"] = "Money Multiplier", ["Damage Potion"] = "Damage Multiplier" }

local FAMILY_PREFIX = { Dragon = true, Cursed = true, Pirate = true, Leaf = true,
	Shadow = true, Slayer = true, Spooky = true }
-- "Shadow Luck II" -> Shadow, "Luck II" / "Income III" / "Damage I" -> Normal.
local function potionFamily(key)
	local first = tostring(key):match("^(%a+)%s")
	if first and FAMILY_PREFIX[first] then return first end
	return "Normal"
end

local ROMAN = { I = 1, II = 2, III = 3, IV = 4, V = 5, VI = 6 }
local function tierOf(key)
	return ROMAN[tostring(key):match("%s(%u+)$") or ""] or 0
end

-- The buff's strength, read from the config; tier numeral breaks ties / fills gaps.
local function buffPower(def, buff)
	local v = def.buffs[buff]
	if type(v) == "number" then return v end
	if type(v) == "table" then
		for _, f in ipairs({ "Multiplier", "multiplier", "Value", "value", "Amount", "amount",
			"Mult", "mult", "Bonus", "bonus", "Add", "add" }) do
			if tonumber(v[f]) then return tonumber(v[f]) end
		end
		local best
		for _, x in pairs(v) do
			if type(x) == "number" and (not best or x > best) then best = x end
		end
		return best
	end
	return nil
end

-- Is this boost's family ticked, and does it give a buff whose box is ticked?
-- Returns the ticked buff name. onlyDamage picks Damage buffs (tower runs) or the rest.
local function pickedBuff(def, key, onlyDamage)
	if type(def) ~= "table" or type(def.buffs) ~= "table" then return nil end
	if not CONFIG.potionFamilies[potionFamily(key)] then return nil end
	for box, buff in pairs(POTION_BUFF) do
		local isDamage = buff == "Damage Multiplier"
		if CONFIG.potionPick[box] and def.buffs[buff] and (onlyDamage == isDamage) then return buff end
	end
	return nil
end

local function groupKey(key, buff)
	return CONFIG.stackPotions and (potionFamily(key) .. ":" .. buff) or buff
end

-- Which boosts are running right now, according to the player's data.
local function activeBoosts()
	local names, parsed = {}, false
	local ae = data().ActiveEntries
	if type(ae) ~= "table" then return names, parsed end
	local now = os.time()
	for k, e in pairs(ae) do
		local name = type(k) == "string" and BOOSTS[k] and k or nil
		if not name and type(e) == "table" then
			for _, f in ipairs({ "name", "key", "id", "boost", "Name" }) do
				if type(e[f]) == "string" and BOOSTS[e[f]] then name = e[f]; break end
			end
		end
		if name then
			local alive
			if type(e) == "table" then
				for _, f in ipairs({ "expiresAt", "expireAt", "endsAt", "endTime", "expires", "finishAt" }) do
					local v = tonumber(e[f])
					if v and v > 1e9 then alive = v > now; break end   -- real epoch seconds only
				end
				if alive == nil then
					local st = tonumber(e.startedAt or e.startTime or e.activatedAt or e.usedAt)
					local dur = tonumber(e.duration) or tonumber(BOOSTS[name].duration)
					if st and st > 1e9 and dur then alive = st + dur > now end
				end
			end
			if alive ~= nil then parsed = true end
			if alive then
				names[name] = true
			end
		end
	end
	return names, parsed
end

-- Groups that already have a potion running, per the player's data.
local function busyGroups(names)
	local busy = {}
	for n in pairs(names) do
		local def = BOOSTS[n]
		if type(def) == "table" and type(def.buffs) == "table" then
			for _, buff in pairs(POTION_BUFF) do
				if def.buffs[buff] then busy[groupKey(n, buff)] = true end
			end
		end
	end
	return busy
end

-- Strongest owned potion of every group.
local function chooseBoosts(onlyDamage)
	local best = {}
	for key, item in pairs(data().Inventory) do
		local def = type(key) == "string" and BOOSTS[key]
		if def and (tonumber(item.amount) or 0) >= 1 then
			local buff = pickedBuff(def, key, onlyDamage)
			if buff then
				local g = groupKey(key, buff)
				local cand = { key = key, def = def, power = buffPower(def, buff) or 0, tier = tierOf(key) }
				local cur = best[g]
				if not cur or cand.power > cur.power or (cand.power == cur.power and cand.tier > cur.tier) then
					best[g] = cand
				end
			end
		end
	end
	return best
end

local lastExplain = 0
local function useChosen(onlyDamage)
	local best = chooseBoosts(onlyDamage)
	local busy = busyGroups((activeBoosts()))
	local used = false
	local lines = {}
	for g, c in pairs(best) do
		local running = busy[g] or (boostUntil[g] or 0) > os.clock()
		lines[#lines + 1] = string.format("%s -> %s (power=%s tier=%d) %s", g, c.key,
			tostring(c.power), c.tier, running and "running" or "using now")
		if not running then
			R.BoostUse:FireServer(c.key)
			boostUntil[g] = os.clock() + (tonumber(c.def.duration) or 120) + 1
			STATE.boostsUsed = STATE.boostsUsed + 1
			STATE.note = "boost " .. c.key
			used = true
			task.wait(0.3)
		end
	end
	-- Why nothing happened, at most once a minute while a box is ticked.
	if not used and os.clock() - lastExplain > 60 then
		lastExplain = os.clock()
		table.sort(lines)
		CONFIG.dprint("[AnimeDiceHub] POTIONS (" .. (onlyDamage and "damage" or "normal") .. ")\n"
			.. (#lines > 0 and table.concat(lines, "\n") or "no owned potion matches the ticked types and families"))
	end
	return used
end

function useBoosts()
	if not R.BoostUse then return end
	useChosen(false)
end

function useTowerBoosts()
	if not (CONFIG.potionPick["Damage Potion"] and R.BoostUse) then return end
	useChosen(true)
end
end

-- One tower run. The server simulates every floor and hands back the sequence the
-- client would animate; skipping that animation is the whole speed-up. Asking
-- before the server's per-floor clock (~1.5-2s) returns nil - that is "not yet",
-- the run is still alive, so we poll instead of cancelling like the client does.
--
-- Read from TowerService itself (it ships to the client): PlayTower refuses while
-- the player still has a run, and CancelTower does NOT end a run - it only queues
-- the ending, which the server carries out on the next CompleteTowerFloor. A run
-- that is cancelled and then left alone therefore blocks every new run forever.
-- Tower choice by simulation. TowerClass (server, ships to the client) is fully
-- deterministic except for the drop rolls: the team fights in order, a member
-- hits (damage), and if the enemy survives it hits back (enemyDamage); health
-- carries across floors and a fallen member hands the SAME enemy to the next.
-- A one-hit kill costs the member nothing. Member damage/health =
-- damage/health(attributes) x Damage/Health Multiplier - level and grade play no
-- part. Nothing is saved between runs and no tower is locked, so the only
-- question is which tower pays the most per second for THIS team. Drop tiers are
-- cumulative: from its minFloor on, every tier rolls on every floor.
local TOWER_WAIT = { initial = 0.76, transition = 0.38, hit = 0.62, done = 0.24, fall = 0.32 }

-- Rough worth of a drop in "luck-seconds": a boost is worth (mult - 1) x
-- duration, weighted by what that buff does for us. Luck decides rarity, so it
-- leads; gems and trait rerolls feed the income rerolls.
local DROP_WEIGHT = { Luck = 1, ["Money Multiplier"] = 0.5, ["Damage Multiplier"] = 0.15 }
local function dropValue(name)
	if name == "Gems" then return 40 end
	if name == "Trait Reroll" then return 25 end
	local def = BOOSTS[name]
	if type(def) ~= "table" or type(def.buffs) ~= "table" then return 0 end
	local v = 0
	for buff, b in pairs(def.buffs) do
		local w = DROP_WEIGHT[buff] or 0
		v = v + w * math.max(0, (tonumber(b.amount) or 1) - 1) * (tonumber(def.duration) or 0)
	end
	return v
end

local function towerTeam()
	local d = data()
	local dmgMul = tonumber(select(2, pcall(BuffController.GetBuff, "Damage Multiplier"))) or 1
	local hpMul = tonumber(select(2, pcall(BuffController.GetBuff, "Health Multiplier"))) or 1
	local team = {}
	for i = 1, 4 do
		local id = d.TowerTeam and d.TowerTeam[i]
		local u = id and d.Inventory[id]
		local e = u and UnitConfig.entries[u.name]
		if e then
			local a = u.attributes or {}
			team[#team + 1] = {
				dmg = (tonumber(select(2, pcall(e.damage, a))) or 0) * dmgMul,
				hp = (tonumber(select(2, pcall(e.health, a))) or 0) * hpMul,
			}
		end
	end
	return team
end

-- Returns floors cleared, seconds the server will make us wait, expected value.
local function simulateTower(tw, team)
	if #team == 0 then return 0, 0, 0 end
	local members = {}
	for i, m in ipairs(team) do members[i] = { dmg = m.dmg, hp = m.hp } end
	local cap = tw.maxFloors or 300          -- Infinity has none
	local floor, cur, secs, value = 1, 1, 0, 0
	while floor <= cap do
		local enemy = tonumber(select(2, pcall(tw.enemyHealth, floor))) or math.huge
		local hit = tonumber(select(2, pcall(tw.enemyDamage, floor))) or math.huge
		secs = secs + (floor == 1 and TOWER_WAIT.initial or TOWER_WAIT.transition)
		local cleared = false
		for _ = 1, 2000 do
			local m = members[cur]
			if not m then break end
			enemy = enemy - m.dmg
			secs = secs + TOWER_WAIT.hit
			if enemy <= 0 then cleared = true; break end
			m.hp = m.hp - hit
			secs = secs + TOWER_WAIT.hit
			if m.hp <= 0 then
				cur = cur + 1
				secs = secs + TOWER_WAIT.fall + TOWER_WAIT.transition
			end
		end
		if not cleared then break end
		secs = secs + TOWER_WAIT.done
		for _, tier in ipairs(tw.drops or {}) do
			if (tier.minFloor or 1) <= floor then
				for _, en in ipairs(tier.entries or {}) do
					value = value + (tonumber(en.chance) or 0) / 100
						* (tonumber(en.amount) or 1) * dropValue(en.name)
				end
			end
		end
		floor = floor + 1
	end
	return floor - 1, secs, value
end

-- The tower with the best expected value per second for the current team.
local function pickTower()
	local all = select(2, pcall(TowersConfig.GetAll))
	-- A saved tower the game no longer has falls back to the simulation.
	if CONFIG.tower ~= "Auto (best)" and type(all) == "table" and all[CONFIG.tower] then
		return CONFIG.tower
	end
	local team = towerTeam()
	local best, bestRate, bestFloors = nil, -1, 0
	if type(all) == "table" then
		for name, tw in pairs(all) do
			local floors, secs, value = simulateTower(tw, team)
			local rate = secs > 0 and value / (secs + 4) or 0     -- +4s run overhead
			if floors > 0 and rate > bestRate then
				best, bestRate, bestFloors = name, rate, floors
			end
		end
	end
	STATE.towerPick = best or "Dragon Tower"
	STATE.towerPredict = bestFloors
	STATE.towerRate = bestRate
	return STATE.towerPick
end

-- Damage boosts only help inside the tower, so they are fired at the start of a
-- run, one per category, never over a running one of the same category.
local function drainTower()
	if not R.CancelTower then return end
	local okC, queued = pcall(function() return R.CancelTower:InvokeServer() end)
	if not (okC and queued) then return end          -- no run exists
	for _ = 1, 60 do
		local ok, seq = pcall(function() return R.CompleteFloor:InvokeServer() end)
		if ok and type(seq) == "table" then
			for _, ev in ipairs(seq) do
				if ev.action == "ended" then return end
			end
		end
		task.wait(0.3)
	end
end

local function towerRun()
	if not (R.PlayTower and R.CompleteFloor) then return end
	if R.BestTowerTeam then R.BestTowerTeam:FireServer(); task.wait(0.6) end
	-- Boosts first: the run snapshots Damage Multiplier at PlayTower, so the
	-- simulation must see the same multiplier or it undershoots (56 predicted vs
	-- ~100 reached before this order was fixed).
	useTowerBoosts()
	task.wait(0.4)
	local tower = pickTower()
	local ok, started = pcall(function() return R.PlayTower:InvokeServer(tower) end)
	if not (ok and started) then
		drainTower()                                  -- a stale run is in the way
		task.wait(3.2)                                -- PlayTower's 3s debounce
		ok, started = pcall(function() return R.PlayTower:InvokeServer(tower) end)
		if not (ok and started) then STATE.note = "tower refused"; return end
	end
	STATE.towerRuns = STATE.towerRuns + 1
	STATE.towerFloor = 0
	local misses, sawEnded = 0, false
	local reason = "Auto Tower turned off or script reloaded"
	local runDrops = 0
	while _G.__ANIMEDICE == generation and CONFIG.autoTower do
		local okF, seq = pcall(function() return R.CompleteFloor:InvokeServer() end)
		if not okF or seq == nil or (type(seq) == "table" and #seq == 0) then
			misses = misses + 1
			if misses > 50 then reason = "SCRIPT gave up: no server reply for ~15s"; break end         -- ~15s with nothing: give up
			task.wait(0.3)
		else
			misses = 0
			local ended, done = false, false
			for _, ev in ipairs(seq) do
				if ev.action == "floorCompleted" then
					done = true
					STATE.towerFloor = tonumber(ev.floor) or (STATE.towerFloor + 1)
					if type(ev.rewards) == "table" then
						STATE.towerDrops = STATE.towerDrops + #ev.rewards
						runDrops = runDrops + #ev.rewards
					end
				elseif ev.action == "ended" then
					ended = true
					-- the drops of the whole run arrive here, not per floor
					if type(ev.rewards) == "table" then
						STATE.towerDrops = STATE.towerDrops + #ev.rewards
						runDrops = runDrops + #ev.rewards
					end
				end
			end
			if done then STATE.towerFloors = STATE.towerFloors + 1 end
			if STATE.towerFloor > STATE.towerBest then STATE.towerBest = STATE.towerFloor end
			if ended then sawEnded = true; reason = "server ended the run (your team lost or the tower was cleared)"; break end   -- lost, or the run is over
			if not done then reason = "SCRIPT stopped: reply had no completed floor"; break end
			task.wait(0.2)
		end
	end
	-- Never leave a run hanging: it would block the next PlayTower.
	local cancelled = not sawEnded
	if cancelled then drainTower() end
	STATE.note = "tower ended at floor " .. tostring(STATE.towerFloor)
	-- One line per run, so an early exit is visible: "SCRIPT ..." reasons mean the
	-- script cut the run short; "server ended" means the game finished it.
	CONFIG.dprint(string.format("[AnimeDiceHub] TOWER RUN #%d | %s | floor %s (best %s) | drops %d | %s%s",
		STATE.towerRuns, tostring(tower), tostring(STATE.towerFloor), tostring(STATE.towerBest),
		runDrops, reason, cancelled and " | run cancelled by script" or ""))
end

-- Fuse machine (FusingService, which ships to the client and decompiles):
-- Fuse(id1, id2, id3) sums the three units' 1-in-N chances (mutation included -
-- Diamond is x10000) and rolls a unit whose chance is that sum x a pool factor
-- averaging 0.667. So the result is on average TWICE as rare as the three
-- inputs' mean - rarity without luck, paid in money:
-- cost = S x 10000 x (S / 1e12)^0.2. The output is also the next fusion's fodder,
-- so fusing the spare pile greedily from the top climbs a ladder (three ~5.7M
-- -> ~11M+, the Legendary band). Inputs must be single, unlocked, non-limited.
-- The server lock is ONE flag for every player on the server, 3s long, so
-- "Please wait" just means retry.
local fuseResult
if R.FuseResult then
	local conn
	conn = R.FuseResult.OnClientEvent:Connect(function(unit, err, newId)
		if _G.__ANIMEDICE ~= generation then conn:Disconnect(); return end
		fuseResult = { unit = unit, err = err, newId = newId }
	end)
end

-- Trios the server refused for good ("No balanced fusion" once the sum outgrows
-- the rarest units, locked/limited units). Without this the top trio of a late
-- account is retried every pass and blocks every trio below it.
local badTrio = {}

-- Every Fuse call - a failing one included - sets FusingService.Fusing for 3s,
-- and RollDice returns nothing while it is set, for every player on the server.
-- Fusing every 4s therefore ate ~3/4 of the auto rolls ("auto roll didn't work").
local FUSE_GAP = 15
local fuseNext = 0

local function fuseOnce()
	local d = data()
	local busy = {}
	for _, slot in pairs(d.Slots) do if slot.unitId then busy[slot.unitId] = true end end
	for _, id in pairs(d.TowerTeam or {}) do busy[id] = true end
	-- Never fuse a unit that is good enough to be placed: the top (slots + 2) by
	-- level-free income stay out of the pile. The first build fused on chance
	-- alone and ate spares that should have been standing on the plot.
	do
		local ranked = {}
		for id, u in pairs(d.Inventory) do
			if UnitConfig.entries[u.name] then ranked[#ranked + 1] = { id = id, v = baseIncome(u) } end
		end
		table.sort(ranked, function(a, b) return a.v > b.v end)
		for i = 1, math.min(#ranked, unlockedSlots() + 2) do busy[ranked[i].id] = true end
	end

	local pile = {}
	for id, u in pairs(d.Inventory) do
		if not busy[id] and UnitConfig.entries[u.name] and not isProtected(id, u) then
			local ch = select(2, pcall(FusingUtil.GetChance, u))
			if type(ch) == "number" then pile[#pile + 1] = { id = id, ch = ch } end
		end
	end
	table.sort(pile, function(a, b) return a.ch > b.ch end)

	-- A share of the balance alone starves the rebirth: at 1e12 in the bank 35%
	-- was 350B per fusion, three fusions in 20s, and money fell while earning
	-- 8B/s. Capping by income-seconds keeps fusing proportional to what comes in.
	local budget = math.min(d.Money * math.clamp(CONFIG.fuseShare, 0, 1),
		math.max(STATE.incomePerSec, 0) * CONFIG.fuseSeconds)
	for i = 1, #pile - 2 do
		local a, b, c = pile[i], pile[i + 1], pile[i + 2]
		local sum = a.ch + b.ch + c.ch
		-- Only a balanced trio pays: the expected result must beat its best input,
		-- otherwise one strong unit gets diluted by two weak ones.
		local key = a.id .. b.id .. c.id
		-- The server's own "No balanced fusion" check, run here first: a refused
		-- attempt would still lock everybody's rolls for 3s.
		local okP, pools = pcall(FusingUtil.BuildPools, sum)
		if okP and not pools then badTrio[key] = true end
		if not badTrio[key] and sum * FusingConfig.AverageMultiplier >= a.ch then
			local cost = FusingConfig.GetCost(sum)
			if cost <= budget and cost <= d.Money then
				fuseResult = nil
				fuseNext = os.clock() + FUSE_GAP
				R.Fuse:FireServer(a.id, b.id, c.id)
				for _ = 1, 25 do
					if fuseResult then break end
					task.wait(0.2)
				end
				local r = fuseResult
				if r and r.unit then
					STATE.fused = STATE.fused + 1
					local ch = r.newId and d.Inventory[r.newId]
						and select(2, pcall(FusingUtil.GetChance, d.Inventory[r.newId]))
					if type(ch) == "number" and ch > STATE.fuseBestChance then STATE.fuseBestChance = ch end
					STATE.fuseLast = tostring(r.unit.name)
						.. (r.unit.attributes and r.unit.attributes.mutation
							and (" " .. r.unit.attributes.mutation) or "")
					STATE.note = "fused -> " .. STATE.fuseLast
					return true
				end
				local err = tostring(r and r.err or "no answer")
				STATE.note = "fuse: " .. err
				-- "Please wait" is the server-wide 3s lock and money errors fix
				-- themselves; anything else about THESE units is permanent.
				if r and r.err and not err:find("wait") and not err:find("money")
					and not err:find("trade") and not err:find("ready") then
					badTrio[key] = true
				end
				return false
			end
		end
	end
	return false
end

local function doFuse()
	if not R.Fuse or os.clock() < fuseNext then return false end
	if not claimUnits("fuse") then return false end
	local ok, did = pcall(fuseOnce)
	releaseUnits("fuse")
	return ok and did or false
end

local function doRebirth()
	local cost = nextRebirthCost()
	if not cost then return false end          -- max rebirth reached
	if data().Money >= cost * math.max(1, CONFIG.rebirthMult) then
		R.Rebirth:FireServer()
		STATE.rebirths = STATE.rebirths + 1
		STATE.note = "rebirth -> " .. tostring(data().Rebirth)
		task.wait(0.5)
		return true
	end
	return false
end

-- Level the weakest placed slot once. Cost grows and is server-checked, so an
-- unaffordable call simply no-ops. Returns true only if money actually dropped.
--
-- Price = income(mutation only) x 1.6^(level-1) (UnitUtil.GetLevelPrice), gain =
-- 0.25 x base x Money Multiplier per second. So payback grows 1.6x per level and
-- does not care which unit it is; at x23.6 money: lvl 10 12s, 15 2min, 20 21min,
-- 25 3.7h, 30 39h. The first build levelled to 26-31 and burned most of that.
-- Buy the shortest payback first and stop at the levelPayback cap.
local function levelPayback(u)
	if not (UnitUtil and UnitUtil.GetLevelPrice) then return math.huge end
	local price = tonumber(select(2, pcall(UnitUtil.GetLevelPrice, u.name, u.attributes or {})))
	local mult = tonumber(select(2, pcall(BuffController.GetBuff, "Money Multiplier"))) or 1
	local gain = 0.25 * baseIncome(u) * mult
	if not price or gain <= 0 then return math.huge end
	return price / gain
end

local function doLevel()
	local d = data()
	local lowestKey, lowestLvl
	for key, slot in pairs(d.Slots) do
		if slot.unitId and d.Inventory[slot.unitId] then
			local pb = levelPayback(d.Inventory[slot.unitId])
			if not lowestLvl or pb < lowestLvl then lowestLvl, lowestKey = pb, key end
		end
	end
	if not lowestKey or lowestLvl > CONFIG.levelPayback * 60 then return false end
	local before = d.Money
	R.LevelUpSlot:FireServer(tonumber(lowestKey))
	task.wait(0.12)
	if d.Money < before then
		STATE.leveled = STATE.leveled + 1
		return true
	end
	return false
end

-- The money the next LUCK step needs: the next stronger die, or the rebirth
-- threshold, whichever is cheaper. Luck is what unlocks rarer units (the roll
-- only picks units whose 1-in-N chance is at least your luck), so leveling must
-- not eat money that would buy the next luck step within a few minutes.
local function nextLuckGoal()
	local d = data()
	local curLuck = 0
	for _, die in ipairs(DICE) do
		if d.OwnedDice[die.key] and die.luck > curLuck then curLuck = die.luck end
	end
	local goal
	for _, die in ipairs(DICE) do
		if die.price and not d.OwnedDice[die.key] and die.luck > curLuck then
			if not goal or die.price < goal then goal = die.price end
		end
	end
	if CONFIG.autoRebirth then
		local cost = nextRebirthCost()
		if cost then
			local rb = cost * math.max(1, CONFIG.rebirthMult)
			if not goal or rb < goal then goal = rb end
		end
	end
	return goal
end

-- Pour a share of the current money into slot levels (the placed units' "Lvl x>y"
-- pads), weakest slot first so the cheapest levels go first. It protects a
-- fraction of money for dice/upgrades/rebirth, and stops the moment a level is
-- unaffordable. This is a real income lever: a leveled unit earns much more.
-- True while the next dice/rebirth is within saveMinutes of income: leveling and
-- fusing then hold back so the luck step is not pushed further away.
local function savingForLuck()
	local goal = nextLuckGoal()
	local money = data().Money
	return goal and money < goal and money + STATE.incomePerSec * CONFIG.saveMinutes * 60 >= goal
end

local function levelSlots()
	if savingForLuck() then
		STATE.phase = "saving for luck"
		return
	end
	local floor = data().Money * (1 - math.clamp(CONFIG.levelShare, 0, 1))
	for _ = 1, 15 do
		if data().Money <= floor then break end
		if not doLevel() then break end
	end
end

-- Codes live in Codes.CodesConfig since the 2026-10-11 update (the old
-- MonetizationConfig.Codes is gone) and RedeemCode has a 0.5s debounce.
local function doCodes()
	if not R.RedeemCode then return end
	local d = data()
	local did = 0
	for code in pairs(CODES) do
		if type(code) == "string" and not d.RedeemedCodes[code] then
			R.RedeemCode:FireServer(code)
			did = did + 1
			task.wait(0.6)
		end
	end
	if did > 0 then STATE.codesDone = STATE.codesDone + did end
end

-- Daily/weekly quests (Playtime, Rolls, Towers, UnitsSold) pay Tickets. The
-- server wants the period, the quest id and the period's expiresAt.
local function doQuests()
	if not (QuestConfig and QuestConfig.Periods and R.QuestClaim) then return end
	local d = data()
	for period, def in pairs(QuestConfig.Periods) do
		local q = d.Quests and d.Quests[period]
		if type(q) == "table" and type(q.progress) == "table" then
			for _, quest in ipairs(def.quests or {}) do
				local claimed = q.claimed and q.claimed[quest.id]
				if not claimed and (tonumber(q.progress[quest.id]) or 0) >= (tonumber(quest.target) or math.huge) then
					R.QuestClaim:FireServer(period, quest.id, q.expiresAt)
					STATE.questsClaimed = STATE.questsClaimed + 1
					STATE.note = "quest " .. period .. " " .. tostring(quest.id)
					task.wait(0.3)
				end
			end
		end
	end
end

-- The Ticket shop sells real gamepasses for Tickets alone (the server removes
-- Tickets and sets OwnedGamepasses - no Robux prompt anywhere on that path).
local function doPasses()
	if not (QuestConfig and QuestConfig.Shop and R.QuestBuy) then return end
	local d = data()
	local tickets = itemAmount("Tickets")
	local price = {}
	for _, item in ipairs(QuestConfig.Shop) do
		if item.gamepass then price[item.name] = tonumber(item.tickets) end
	end
	for _, name in ipairs(PASS_ORDER) do
		if price[name] and not (d.OwnedGamepasses and d.OwnedGamepasses[name]) then
			-- Best first: save up for it rather than buying something weaker.
			if tickets >= price[name] then
				R.QuestBuy:FireServer(name)
				STATE.passesBought = STATE.passesBought + 1
				STATE.note = "gamepass " .. name .. " for " .. price[name] .. " tickets"
			end
			return
		end
	end
end

-- One rebirth point per rebirth; each is x(1 + 0.1 x points) on one buff.
local function doStats()
	if not (RebirthStats and RebirthStats.Get and R.AddStat) then return end
	if not RebirthStats.Get(CONFIG.statPick) then return end
	local d = data()
	local left = tonumber(select(2, pcall(RebirthStats.GetRemaining, d.Rebirth, d.RebirthStats))) or 0
	for _ = 1, math.min(left, 30) do
		R.AddStat:FireServer(CONFIG.statPick)
		STATE.statsAdded = STATE.statsAdded + 1
		task.wait(0.15)                         -- AddRebirthStat debounce 0.1s
	end
end

local function doClaims()
	for _, ev in ipairs({ R.ClaimOffline, R.ClaimDaily, R.ClaimGroup }) do
		if ev then pcall(function() ev:FireServer() end) end
	end
	STATE.claims = STATE.claims + 1
end

local function applyAutoSell()
	-- Turn off the game's own chance-based AutoSell; the rarity filter below does the selling.
	if not R.UpdateAutoSell then return end
	pcall(function() R.UpdateAutoSell:FireServer(0) end)
end

local sellRarities = {}

-- Unit ids already sent to the server, so a unit is never submitted twice. Every
-- unowned-slot unit in the bag that matches a ticked rarity is sold, old or new.
local attemptedSellIds = {}
local function inventoryUnitIds()
	local ids = {}
	local d = data()
	for id, u in pairs((d and d.Inventory) or {}) do
		if type(u) == "table" and UnitConfig.entries[u.name] then ids[id] = u end
	end
	return ids
end
local function normalizeSellRarity(value)
	if type(value) ~= "string" then return nil end
	local s = value:gsub("^%s+", ""):gsub("%s+$", ""):lower()
	-- A combined label such as "Secret I / II" is ambiguous: keep it rather
	-- than guessing whether it means Secret 1 or Secret 2.
	if s:find("/", 1, true) or s:find("secret i and ii", 1, true) then return nil end
	-- Normalize formatting only; do not infer one rarity from another or use
	-- numeric sort-order indexes, since those can differ between game versions.
	s = s:gsub("[%s%p_]+", "")
	local aliases = {
		common = "Common", uncommon = "Uncommon", rare = "Rare", epic = "Epic",
		legendary = "Legendary", mythical = "Mythical", divine = "Divine",
		exotic = "Exotic", celestial = "Celestial", exclusive = "Exclusive",
		secret1 = "Secret 1", secreti = "Secret 1",
		secret2 = "Secret 2", secretii = "Secret 2",
	}
	return aliases[s]
end

local autoSellNewUnits
do
-- ref -> canonical rarity name, built once from the game's own Rarities module.
-- The old resolver read u.rarity off the inventory entry and fed it to Rar.Get;
-- that value is not the same kind of ref as UnitConfig's entry.rarity, so it
-- resolved to a neighbouring rarity (Exotic read as Divine, Celestial as Exotic).
-- Now only entry.rarity is used, and a name is accepted only if every source
-- (Refs key, ref itself, info name) that yields a name agrees. Otherwise the
-- rarity is left unmapped and never sold.
local REF_NAME = {}
local refNamesBuilt = false
local function buildRefNames()
	local ok, Rar = pcall(require, Framework.Other.Rarities)
	if not (ok and Rar and Rar.Refs and Rar.Get) then return end
	local byName, bad = {}, {}
	local lines = {}
	for key, ref in pairs(Rar.Refs) do
		local got, info = pcall(Rar.Get, ref)
		if got and type(info) == "table" then
			local names = {}
			local function add(v)
				local c = normalizeSellRarity(v)
				if c then names[c] = true end
			end
			add(key)
			add(ref)
			add(info.name); add(info.Name); add(info.displayName); add(info.DisplayName)
			local only, count
			for c in pairs(names) do only = c; count = (count or 0) + 1 end
			if count == 1 then
				if byName[only] and byName[only] ~= ref then bad[only] = true end
				byName[only] = ref
				REF_NAME[ref] = only
			end
			lines[#lines + 1] = string.format("%s (ref=%s, sortOrder=%s) -> %s",
				tostring(key), tostring(ref), tostring(info.sortOrder), tostring(only or "UNMAPPED"))
		end
	end
	for ref, name in pairs(REF_NAME) do
		if bad[name] then REF_NAME[ref] = nil end
	end
	if next(REF_NAME) then
		refNamesBuilt = true
		table.sort(lines)
		CONFIG.dprint("[AnimeDiceHub] rarity map:\n" .. table.concat(lines, "\n"))
	end
end

-- Rarity is NOT fixed per unit name: a mutation multiplies the 1-in-N chance
-- (Diamond x10000, Ghost...), and the game then shows the unit under the rarity
-- that chance falls in. So a Legendary "Huge Loffy" with a mutation is Celestial.
-- Tier floors are learned from UnitConfig itself: each rarity's floor is the
-- smallest base chance among its units. A unit's rarity is the highest tier
-- whose floor its EFFECTIVE (mutated) chance reaches. Tiers with no known name
-- (Secret etc.) still count as tiers, so units above Celestial return nil and
-- are never sold by mistake.
local TIERS
local function buildTiers()
	if not refNamesBuilt then buildRefNames() end
	local floors = {}
	for _, e in pairs(UnitConfig.entries) do
		if type(e) == "table" and not e.limited and e.rarity ~= nil then
			local ch = tonumber(select(2, pcall(e.chance, {})))
			if ch and (not floors[e.rarity] or ch < floors[e.rarity]) then floors[e.rarity] = ch end
		end
	end
	TIERS = {}
	for ref, floor in pairs(floors) do
		TIERS[#TIERS + 1] = { ref = ref, floor = floor, name = REF_NAME[ref] }
	end
	table.sort(TIERS, function(a, b) return a.floor > b.floor end)
end

local function effectiveChance(u, entry)
	local ok, ch = pcall(FusingUtil.GetChance, u)
	ch = ok and tonumber(ch) or nil
	if not ch then
		local ok2, c2 = pcall(entry.chance, u.attributes or {})
		ch = ok2 and tonumber(c2) or nil
	end
	return ch
end

local function effectiveSellRarity(u, entry)
	if not entry then return nil end
	if not TIERS or #TIERS == 0 then buildTiers() end
	local ch = effectiveChance(u, entry)
	if not ch or not TIERS then return nil end
	for _, t in ipairs(TIERS) do
		if ch >= t.floor then return t.name, ch end
	end
	return nil, ch
end

local gameAutoSellCleared = false
function autoSellNewUnits()
	-- Only sell units whose resolved rarity exactly matches an enabled checkbox.
	-- Unknown or differently named rarities fail closed and are never sold.
	if not CONFIG.autoSell or not R.SellInventory then return end
	local selected = {}
	for label, wanted in pairs(sellRarities) do
		if wanted then
			local canonical = normalizeSellRarity(label)
			if canonical then selected[canonical] = true end
		end
	end
	if not next(selected) then return end
	if not gameAutoSellCleared then
		gameAutoSellCleared = true
		pcall(applyAutoSell) -- clear any server-side AutoSell left by older builds / the game UI
	end
	if not claimUnits("sell") then return end
	local okRun, err = pcall(function()
		local d = data()
		local current = inventoryUnitIds()
		local placed = {}
		for _, slot in pairs(d.Slots or {}) do
			if slot.unitId then placed[tostring(slot.unitId)] = true end
		end
		for _, id in pairs(d.TowerTeam or {}) do placed[tostring(id)] = true end

		local list = {}
		for id, u in pairs(current) do
			local sid = tostring(id)
			if not attemptedSellIds[sid] and not placed[sid] and not isProtected(id, u) then
				local entry = UnitConfig.entries[u.name]
				local rarity, ech = effectiveSellRarity(u, entry)
				if entry and not entry.limited and rarity and selected[rarity] then
					list[#list + 1] = id
					CONFIG.dprint(string.format("[AnimeDiceHub] SELL %s | mutation=%s base=%s -> effective=%s | chance=1/%s",
						tostring(u.name), tostring((u.attributes or {}).mutation),
						tostring(REF_NAME[entry.rarity] or entry.rarity), tostring(rarity), tostring(ech)))
				end
			end
		end

		if #list > 0 then
			local soldOk, value, sold = pcall(function()
				return R.SellInventory:InvokeServer(list)
			end)
			if soldOk then
				STATE.sold = STATE.sold + (tonumber(sold) or #list)
				STATE.soldValue = STATE.soldValue + (tonumber(value) or 0)
				STATE.note = "Auto Sell exact checked rarities: " .. tostring(sold or #list) .. " unit(s)"
				for _, id in ipairs(list) do attemptedSellIds[tostring(id)] = true end
			else
				STATE.note = "Auto Sell failed: " .. tostring(value)
			end
		end
		local currentIds = {}
		for id in pairs(current) do currentIds[tostring(id)] = true end
		for id in pairs(attemptedSellIds) do
			if not currentIds[id] then attemptedSellIds[id] = nil end
		end
	end)
	releaseUnits("sell")
	if not okRun then STATE.note = "Auto Sell error: " .. tostring(err) end
end
end

-- Debug/console handle: drive any single action or read state without clicking.
_G.__ANIMEDICE_DBG = {
	CONFIG = CONFIG, STATE = STATE, data = data,
	doRoll = doRoll, doCollectPlace = doCollectPlace, doDice = doDice,
	doUpgrade = doUpgrade, levelSlots = levelSlots,
	doRerolls = doRerolls, useBoosts = useBoosts, towerRun = towerRun, drainTower = drainTower,
	doFuse = doFuse, savingForLuck = savingForLuck,
	pickTower = pickTower, simulateTower = simulateTower, towerTeam = towerTeam,
	baseIncome = baseIncome, curIncome = curIncome, levelPayback = levelPayback,
	nextLuckGoal = nextLuckGoal, placedUnits = placedUnits,
	doRebirth = doRebirth, doLevel = doLevel, doCodes = doCodes,
	doClaims = doClaims, DICE = DICE, UPGRADE_LINES = UPGRADE_LINES,
	invCap = invCap, bestUpgrade = bestUpgrade,
	doQuests = doQuests, doPasses = doPasses, doStats = doStats,
	isProtected = isProtected, heldUnit = heldUnit, rollLuck = rollLuck,
	applyAutoSell = applyAutoSell,
}



-- ANIME DICE HUB V2
-- GUI prototype for an experience you own or are authorized to modify.
-- Feature toggles and selections are UI-only.

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local old = playerGui:FindFirstChild("AnimeDiceHub")
if old then old:Destroy() end

local C = {
	bg = Color3.fromRGB(12, 10, 20),
	panel = Color3.fromRGB(21, 17, 33),
	card = Color3.fromRGB(30, 25, 45),
	hover = Color3.fromRGB(45, 34, 66),
	purple = Color3.fromRGB(173, 112, 255),
	purpleDark = Color3.fromRGB(111, 61, 190),
	purpleGlow = Color3.fromRGB(205, 165, 255),
	white = Color3.fromRGB(248, 245, 255),
	muted = Color3.fromRGB(157, 148, 179),
	green = Color3.fromRGB(105, 235, 166),
	red = Color3.fromRGB(240, 82, 112),
}

local gui = Instance.new("ScreenGui")
gui.Name = "AnimeDiceHub"
gui.ResetOnSpawn = false
gui.Parent = playerGui
_G.__ANIMEDICE_GUI = gui

local enabled = {}
local selectedHalloween = "Front Yard"

-- Existing backend bindings: these switches change the live CONFIG table.
local featureKeys = {
    ["Auto Fast Roll"]="autoRoll",
    ["Auto Sell"]="autoSell", ["Auto Collect Balance"]="autoCollect",
    ["Auto Equip Best Unit"]="smartPlace", ["Auto Buy Dice"]="autoDice",
    ["Auto Upgrades"]="autoUpgrade", ["Auto Rebirth"]="autoRebirth",
    ["Auto Tower"]="autoTower", ["Auto Use Potions"]="autoBoost",
    ["Auto Claim Quest"]="autoQuests",
    ["Anti-AFK"]="antiAfk", ["Auto Claim Halloween Quest"]="autoHalloweenQuest", ["Auto Trick or Treat"]="autoTrickOrTreat",
}
for name,key in pairs(featureKeys) do enabled[name] = CONFIG[key] == true end
local applyHalloweenTower
do
local halloweenSaved
function applyHalloweenTower(on)
    -- The Halloween areas are ordinary entries in TowersConfig (Front Yard, Foyer,
    -- Crypt, Attic, Bell Tower, Catacombs, The Abyss), so the existing tower loop
    -- runs them once CONFIG.tower names one.
    if on then
        if not halloweenSaved then
            halloweenSaved = { tower = CONFIG.tower, auto = CONFIG.autoTower }
        end
        CONFIG.tower = selectedHalloween
        CONFIG.autoTower = true
        enabled["Auto Tower"] = true
    elseif halloweenSaved then
        CONFIG.tower = halloweenSaved.tower
        CONFIG.autoTower = halloweenSaved.auto
        enabled["Auto Tower"] = halloweenSaved.auto
        halloweenSaved = nil
    end
end
end
local function updateFeature(name, value)
    enabled[name] = value
    if name == "Auto Halloween Tower" then applyHalloweenTower(value); return end
    local key = featureKeys[name]
    if key then
        CONFIG[key] = value
        if key == "autoSell" then pcall(applyAutoSell) end
    end
end

local potionChoices = CONFIG.potionPick
local selectedTower = "Dragon Tower"
local halloweenRoute = {"Left-side houses", "Central crossroads", "Right-side houses"}
local halloweenDoorWait = 8 -- planning setting only; not verified against the game
local minimizeKey = Enum.KeyCode.RightShift
local waitingForKey = false
local minimized = false
local alive = true

local connections = {}
local pageConnections = {}

local function connect(signal, callback, pageOnly)
	local c = signal:Connect(callback)
	table.insert(pageOnly and pageConnections or connections, c)
	return c
end

local function clearPageConnections()
	for _, c in ipairs(pageConnections) do
		pcall(function() c:Disconnect() end)
	end
	table.clear(pageConnections)
end

local function make(class, props, parent)
	local obj = Instance.new(class)
	for k, v in pairs(props or {}) do obj[k] = v end
	obj.Parent = parent
	return obj
end

local function round(obj, radius)
	make("UICorner", {
		CornerRadius = UDim.new(0, radius or 9)
	}, obj)
end


-- REUSABLE TWEEN / HOVER HELPERS
local function tween(object, duration, properties, style, direction)
	if not object or not object.Parent then return nil end
	local info = TweenInfo.new(
		duration or 0.2,
		style or Enum.EasingStyle.Quint,
		direction or Enum.EasingDirection.Out
	)
	local animation = TweenService:Create(object, info, properties)
	animation:Play()
	return animation
end

local function addHover(button, normalColor, hoverColor)
	button.AutoButtonColor = false
	connect(button.MouseEnter, function()
		tween(button, 0.16, {BackgroundColor3 = hoverColor})
	end)
	connect(button.MouseLeave, function()
		tween(button, 0.2, {BackgroundColor3 = normalColor})
	end)
end

local function text(parent, value, size, position, fontSize, color, bold)
	local obj = make("TextLabel", {
		BackgroundTransparency = 1,
		Size = size,
		Position = position,
		Text = value,
		TextColor3 = color or C.white,
		TextSize = fontSize or 12,
		Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
		TextWrapped = true,
	}, parent)
	return obj
end

local main = make("Frame", {
	Name = "Main",
	Size = UDim2.fromOffset(850, 530),
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	BackgroundColor3 = C.bg,
	BorderSizePixel = 0,
	ClipsDescendants = true,
}, gui)
round(main, 14)

-- Window size: a UIScale on the whole window. It never grows past the chosen size
-- and shrinks further to fit small screens (e.g. a minimized Roblox window).
local uiScale = Instance.new("UIScale")
uiScale.Parent = main
local function applyFit()
	local vp = gui.AbsoluteSize
	if vp.X <= 0 or vp.Y <= 0 then return end
	local fit = math.min((vp.X - 24) / 850, (vp.Y - 24) / 530)
	uiScale.Scale = math.clamp(math.min(CONFIG.guiScale or 0.8, fit), 0.4, 1)
end
applyFit()
connect(gui:GetPropertyChangedSignal("AbsoluteSize"), applyFit)

make("UIStroke", {
	Color = C.purple,
	Transparency = 0.25,
	Thickness = 1.4,
}, main)

-- HEADER

local header = make("Frame", {
	Size = UDim2.new(1, 0, 0, 65),
	BackgroundColor3 = C.panel,
	BorderSizePixel = 0,
}, main)

make("UIGradient", {
	Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(36, 23, 58)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(19, 16, 30)),
	}),
	Rotation = 0,
}, header)

make("Frame", {
	Size = UDim2.new(1, 0, 0, 2),
	BackgroundColor3 = C.purple,
	BorderSizePixel = 0,
}, header)

-- Logo beside the title + banner behind the minimized tab. Everything sits in a
-- do-block so these variables don't count toward Lua's 200-top-level-locals limit.
-- Each image can come from any ONE of: a workspace file (getcustomasset), a direct
-- URL (downloaded once into the workspace, then reused), or a Roblox asset id.
-- Any failure falls back (logo -> dice emoji, banner -> none).
do
	local FOLDER       = "AnimeDiceHub"
	local LOGO_FILE    = FOLDER .. "/logo.png"
	local LOGO_URL     = "https://raw.githubusercontent.com/clydenalvarez29-sys/Hayes-Hub/main/logo/logo.png"
	local LOGO_IMAGE   = ""     -- or "rbxassetid://..."
	local BANNER_FILE  = FOLDER .. "/banner.png"
	local BANNER_URL   = "https://raw.githubusercontent.com/clydenalvarez29-sys/Hayes-Hub/main/logo/banner.png"
	local BANNER_IMAGE = ""     -- or "rbxassetid://..."

	local function resolve(assetId, file, url)
		if assetId ~= "" then return assetId end
		local src = ""
		pcall(function()
			if url ~= "" and isfile and writefile and not isfile(file) then
				if makefolder and isfolder and not isfolder(FOLDER) then makefolder(FOLDER) end
				writefile(file, game:HttpGet(url))
			end
			if getcustomasset and isfile and isfile(file) then
				src = getcustomasset(file)
			end
		end)
		return src
	end

	local logoSrc = resolve(LOGO_IMAGE, LOGO_FILE, LOGO_URL)
	if logoSrc ~= "" then
		local logo = make("ImageLabel", {
			Size = UDim2.fromOffset(36, 36),
			Position = UDim2.fromOffset(14, 14),
			BackgroundTransparency = 1,
			Image = logoSrc,
			ScaleType = Enum.ScaleType.Fit,
		}, header)
		round(logo, 8)
	else
		text(header, "🎲", UDim2.fromOffset(34, 38),
			UDim2.fromOffset(16, 14), 24, C.purple, true)
	end

	-- Banner: only shown while minimized (setMinimized toggles it by name).
	-- Created before the header buttons so they stay on top of it.
	local bannerSrc = resolve(BANNER_IMAGE, BANNER_FILE, BANNER_URL)
	if bannerSrc ~= "" then
		local banner = make("ImageLabel", {
			Name = "MiniBanner",
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = C.panel,
			Image = bannerSrc,
			ScaleType = Enum.ScaleType.Crop,
			Visible = false,
			BorderSizePixel = 0,
		}, header)
		round(banner, 10)
		-- soft dark wash so the floor text and buttons stay readable
		local wash = make("Frame", {
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = Color3.new(0, 0, 0),
			BackgroundTransparency = 0.5,
			BorderSizePixel = 0,
		}, banner)
		round(wash, 10)
	end
end

text(header, "ANIME DICE HUB",
	UDim2.fromOffset(240, 27),
	UDim2.fromOffset(55, 8), 19, C.white, true)

text(header, "AUTOMATION CONTROL PANEL",
	UDim2.fromOffset(240, 17),
	UDim2.fromOffset(57, 34), 10, C.muted)

local status = text(header, "●  GUI READY",
	UDim2.fromOffset(110, 24),
	UDim2.new(1, -195, 0, 20), 10, C.green, true)
status.TextXAlignment = Enum.TextXAlignment.Right

local minimizeButton = make("TextButton", {
	Size = UDim2.fromOffset(32, 31),
	Position = UDim2.new(1, -76, 0, 17),
	Text = "—",
	TextSize = 18,
	TextColor3 = C.white,
	BackgroundColor3 = C.card,
	Font = Enum.Font.GothamBold,
	BorderSizePixel = 0,
}, header)
round(minimizeButton, 7)

local closeButton = make("TextButton", {
	Size = UDim2.fromOffset(32, 31),
	Position = UDim2.new(1, -37, 0, 17),
	Text = "×",
	TextSize = 23,
	TextColor3 = C.white,
	BackgroundColor3 = Color3.fromRGB(125, 43, 65),
	Font = Enum.Font.Gotham,
	BorderSizePixel = 0,
}, header)
round(closeButton, 7)
addHover(closeButton, Color3.fromRGB(125, 43, 65), Color3.fromRGB(185, 48, 79))
addHover(minimizeButton, C.card, C.hover)

-- CONTENT ON LEFT

local content = make("Frame", {
	Position = UDim2.fromOffset(17, 83),
	Size = UDim2.new(1, -233, 1, -99),
	BackgroundTransparency = 1,
}, main)

local pageTitle = text(content, "ROLLING & UNITS",
	UDim2.new(1, 0, 0, 32), UDim2.new(), 24, C.white, true)

local pageSubtitle = text(content, "Manage your rolls and units",
	UDim2.new(1, 0, 0, 22), UDim2.fromOffset(0, 32),
	13, C.muted)

make("Frame", {
	Position = UDim2.fromOffset(0, 58),
	Size = UDim2.new(1, 0, 0, 1),
	BackgroundColor3 = C.card,
	BorderSizePixel = 0,
}, content)

local page = make("ScrollingFrame", {
	Position = UDim2.fromOffset(0, 70),
	Size = UDim2.new(1, 0, 1, -70),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ScrollBarThickness = 4,
	ScrollBarImageColor3 = C.purple,
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, content)

make("UIListLayout", {
	Padding = UDim.new(0, 9),
	SortOrder = Enum.SortOrder.LayoutOrder,
}, page)

make("UIPadding", {
	PaddingRight = UDim.new(0, 7),
	PaddingBottom = UDim.new(0, 8),
}, page)

-- LABELED NAVIGATION ON RIGHT

local nav = make("Frame", {
	Position = UDim2.new(1, -205, 0, 80),
	Size = UDim2.new(0, 190, 1, -96),
	BackgroundColor3 = C.panel,
	BorderSizePixel = 0,
}, main)
round(nav, 11)

text(nav, "NAVIGATION", UDim2.new(1, -20, 0, 28),
	UDim2.fromOffset(14, 6), 12, C.muted, true)

local navList = make("ScrollingFrame", {
	Position = UDim2.fromOffset(7, 38),
	Size = UDim2.new(1, -14, 1, -46),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ScrollBarThickness = 3,
	ScrollBarImageColor3 = C.purple,
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, nav)

make("UIListLayout", {
	Padding = UDim.new(0, 6),
	SortOrder = Enum.SortOrder.LayoutOrder,
}, navList)

local categories = {
	{name = "Main", icon = "🏠",
		subtitle = "Profile, event currency and live income"},
	{name = "Rolling & Units", icon = "🎲",
		subtitle = "Rolling, selling and unit management"},
	{name = "Shop", icon = "🛒",
		subtitle = "Dice purchases and upgrades"},
	{name = "Tower", icon = "🏰",
		subtitle = "Choose a tower to configure"},
	{name = "Potions", icon = "🧪",
		subtitle = "Potion selection and stacking preferences"},
	{name = "Quests", icon = "📜",
		subtitle = "Quest claim preferences"},
	{name = "Halloween", icon = "🎃",
		subtitle = "Halloween event settings"},
	{name = "Settings", icon = "⚙",
		subtitle = "Interface and keybind settings"},
}

local navButtons = {}
local currentCategory = "Main"

-- FEATURE TOGGLE CARD

local function featureCard(name, description)
	local card = make("Frame", {
		Size = UDim2.new(1, -5, 0, 70),
		BackgroundColor3 = C.card,
		BorderSizePixel = 0,
	}, page)
	round(card, 9)
	-- A narrower card keeps the toggle close to its label.
	make("UISizeConstraint", { MaxSize = Vector2.new(400, 1000) }, card)

	text(card, name, UDim2.new(1, -80, 0, 26),
		UDim2.fromOffset(13, 8), 15, C.white, true)

	text(card, description or "Toggle preference",
		UDim2.new(1, -80, 0, 22),
		UDim2.fromOffset(13, 37), 12, C.muted)

	local button = make("TextButton", {
		Size = UDim2.fromOffset(44, 24),
		Position = UDim2.new(1, -57, 0.5, -12),
		Text = "",
		BackgroundColor3 = C.panel,
		BorderSizePixel = 0,
		AutoButtonColor = false,
	}, card)
	round(button, 12)

	local dot = make("Frame", {
		Size = UDim2.fromOffset(18, 18),
		Position = UDim2.fromOffset(3, 3),
		BackgroundColor3 = C.muted,
		BorderSizePixel = 0,
	}, button)
	round(dot, 10)

	local function refresh(animated)
		local on = enabled[name] == true
		local targetColor = on and C.purpleDark or C.panel
		local targetPosition = on
			and UDim2.new(1, -21, 0, 3)
			or UDim2.fromOffset(3, 3)
		if animated then
			tween(button, 0.2, {BackgroundColor3 = targetColor})
			tween(dot, 0.22, {
				Position = targetPosition,
				BackgroundColor3 = on and C.white or C.muted,
			}, Enum.EasingStyle.Back)
		else
			button.BackgroundColor3 = targetColor
			dot.Position = targetPosition
			dot.BackgroundColor3 = on and C.white or C.muted
		end
	end

	refresh(false)
	connect(button.Activated, function()
		updateFeature(name, not enabled[name])
		refresh(true)
	end, true)

	connect(card.MouseEnter, function()
		tween(card, 0.16, {BackgroundColor3 = C.hover})
	end, true)
	connect(card.MouseLeave, function()
		tween(card, 0.2, {BackgroundColor3 = C.card})
	end, true)
end

local function sectionTitle(value)
	local t = text(page, string.upper(value),
		UDim2.new(1, -5, 0, 28), UDim2.new(),
		13, C.purple, true)
	t.LayoutOrder = 0
end

-- MULTI-SELECT OPTIONS

local function multiSelect(title, description, options, values, prefix)
	local outer = make("Frame", {
		Size = UDim2.new(1, -5, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = C.card,
		BorderSizePixel = 0,
	}, page)
	round(outer, 9)

	text(outer, title, UDim2.new(1, -24, 0, 26),
		UDim2.fromOffset(12, 8), 15, C.white, true)

	text(outer, description, UDim2.new(1, -24, 0, 34),
		UDim2.fromOffset(12, 34), 12, C.muted)

	local grid = make("Frame", {
		Position = UDim2.fromOffset(12, 74),
		Size = UDim2.new(1, -24, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
	}, outer)

	make("UIGridLayout", {
		CellSize = UDim2.new(0.5, -5, 0, 36),
		CellPadding = UDim2.fromOffset(8, 7),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, grid)

	for _, option in ipairs(options) do
		local button = make("TextButton", {
			Size = UDim2.new(0.5, -5, 0, 36),
			BackgroundColor3 = values[option]
				and C.purpleDark or C.panel,
			Text = (values[option] and "✓ " or "○ ") .. option,
			TextColor3 = values[option] and C.white or C.muted,
			TextSize = 14,
			Font = Enum.Font.GothamSemibold,
			BorderSizePixel = 0,
			AutoButtonColor = false,
		}, grid)
		round(button, 6)

		connect(button.Activated, function()
			values[option] = not values[option]
			button.Text = (values[option] and "✓ " or "○ ") .. option
			button.BackgroundColor3 = values[option]
				and C.purpleDark or C.panel
			button.TextColor3 = values[option] and C.white or C.muted
		end, true)
	end

	local rows = math.ceil(#options / 2)
	outer.Size = UDim2.new(1, -5, 0, 84 + rows * 43)
end

-- SINGLE-SELECT OPTIONS

local function singleSelect(title, description, options, getValue, setValue)
	local outer = make("Frame", {
		Size = UDim2.new(1, -5, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = C.card,
		BorderSizePixel = 0,
	}, page)
	round(outer, 9)

	text(outer, title, UDim2.new(1, -24, 0, 26),
		UDim2.fromOffset(12, 8), 15, C.white, true)

	text(outer, description, UDim2.new(1, -24, 0, 34),
		UDim2.fromOffset(12, 34), 12, C.muted)

	local grid = make("Frame", {
		Position = UDim2.fromOffset(12, 74),
		Size = UDim2.new(1, -24, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
	}, outer)

	make("UIGridLayout", {
		CellSize = UDim2.new(0.5, -5, 0, 38),
		CellPadding = UDim2.fromOffset(8, 7),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, grid)

	local buttons = {}

	local function refresh()
		for _, entry in ipairs(buttons) do
			local active = getValue() == entry.value
			entry.button.BackgroundColor3 = active
				and C.purpleDark or C.panel
			entry.button.TextColor3 = active and C.white or C.muted
			entry.button.Text = (active and "✓ " or "○ ")
				.. entry.value
		end
	end

	for _, option in ipairs(options) do
		local button = make("TextButton", {
			BackgroundColor3 = C.panel,
			Text = option,
			TextColor3 = C.muted,
			TextSize = 14,
			Font = Enum.Font.GothamSemibold,
			BorderSizePixel = 0,
			AutoButtonColor = false,
		}, grid)
		round(button, 6)

		table.insert(buttons, {button = button, value = option})

		connect(button.Activated, function()
			setValue(option)
			refresh()
		end, true)
	end

	outer.Size = UDim2.new(1, -5, 0, 84
		+ math.ceil(#options / 2) * 45)

	refresh()
end

local rarities = {
	"Common", "Uncommon", "Rare", "Epic",
	"Legendary", "Mythical", "Divine", "Exotic",
	"Celestial", "Exclusive", "Secret 1", "Secret 2",
}

local towers = {
	"Dragon Tower",
	"Cursed Tower",
	"Pirate Tower",
	"Hidden Leaf Tower",
	"Slayer Tower",
	"Shadow Tower",
	"Infinity Tower",
}

local halloweenAreas = {
	"Front Yard",
	"Foyer",
	"Crypt",
	"Attic",
	"Bell Tower",
	"Catacombs",
	"The Abyss",
}

local definitions = {
	["Rolling & Units"] = {
		{"Auto Fast Roll", "Rolling preference"},
		{"Auto Sell", "Enable rarity-based selling"},
		{"Auto Collect Balance", "Balance collection preference"},
		{"Auto Equip Best Unit", "Best unit equipment preference"},
	},
	Shop = {
		{"Auto Buy Dice", "Dice purchase preference"},
		{"Auto Upgrades", "Upgrade purchase preference"},
		{"Auto Rebirth", "Rebirth preference"},
	},
	Tower = {
		{"Auto Tower", "Tower automation preference"},
	},
	Potions = {
		{"Auto Use Potions", "Potion use preference"},
	},
	Quests = {
		{"Auto Claim Quest", "Quest claiming preference"},
	},
	Halloween = {
		{"Auto Claim Halloween Quest", "Event quest preference"},
		{"Auto Halloween Tower", "Halloween tower preference"},
		{"Auto Trick or Treat", "Event interaction preference"},
	},
	Settings = {
		{"Anti-AFK", "Prevents the 20 minute idle kick"},
	},
}


-- MAIN TAB (added): profile, Halloween currency, money/s, tower floor ------------
-- Pure read-only display. Nothing here fires a remote or changes CONFIG/STATE.
local MainTab = (function()
	local M = {}
	local refs = {}
	local ORANGE = Color3.fromRGB(255, 150, 60)
	local PINK   = Color3.fromRGB(255, 120, 190)

	-- Same rule as the rest of the script: read the live data table fresh each time.
	local function amountOf(v)
		if type(v) == "number" then return v end
		if type(v) == "table" then
			return tonumber(v.amount) or tonumber(v.Amount) or tonumber(v.value) or tonumber(v.Value)
		end
	end

	-- Pumpkins / candy are located by name: Inventory items first (like Gems and
	-- Tickets), then top-level data, then the Halloween table. Exact names win.
	local function findAmount(names, words)
		local d = data()
		local sources = { d.Inventory, d, d.Halloween, d.Currencies, d.Currency, d.Event, d.Events }
		for _, srcT in ipairs(sources) do
			if type(srcT) == "table" then
				for _, n in ipairs(names) do
					local a = amountOf(srcT[n])
					if a then return a end
				end
			end
		end
		for _, srcT in ipairs(sources) do
			if type(srcT) == "table" then
				for k, v in pairs(srcT) do
					if type(k) == "string" then
						local lk = string.lower(k)
						for _, w in ipairs(words) do
							if string.find(lk, w, 1, true) then
								local a = amountOf(v)
								if a then return a end
							end
						end
					end
				end
			end
		end
		return nil
	end

	-- Money per second = what the placed units earn x the live Money Multiplier
	-- buff (rebirths, potions, boosts, gamepasses all flow through GetBuff).
	local function incomeNow()
		local d = data()
		local mult = tonumber(select(2, pcall(BuffController.GetBuff, "Money Multiplier"))) or 1
		local base = 0
		for _, slot in pairs(d.Slots or {}) do
			local u = slot.unitId and d.Inventory[slot.unitId]
			if u then base = base + curIncome(u) end
		end
		return base * mult, mult
	end

	local function multText(m)
		if m >= 1000 then return "x" .. fmt(m) end
		return string.format("x%.2f", m)
	end

	local function card(parent, size, accent)
		local f = make("Frame", {
			Size = size, BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0,
		}, parent)
		round(f, 11)
		make("UIGradient", {
			Color = ColorSequence.new(Color3.fromRGB(38, 31, 58), Color3.fromRGB(25, 20, 39)),
			Rotation = 90,
		}, f)
		make("UIStroke", { Color = accent, Transparency = 0.72, Thickness = 1 }, f)
		local bar = make("Frame", {
			Size = UDim2.new(0, 3, 1, -24), Position = UDim2.fromOffset(0, 12),
			BackgroundColor3 = accent, BorderSizePixel = 0,
		}, f)
		round(bar, 2)
		return f
	end

	local function oneLine(label)
		label.TextWrapped = false
		label.TextTruncate = Enum.TextTruncate.AtEnd
		return label
	end

	local function chip(parent, txt, color)
		local c = make("TextLabel", {
			AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, 22),
			BackgroundColor3 = C.panel, Text = txt, TextColor3 = color or C.muted,
			TextSize = 11, Font = Enum.Font.GothamSemibold, BorderSizePixel = 0,
		}, parent)
		round(c, 11)
		make("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }, c)
		return c
	end

	-- One stat tile: icon, caption, big value, small sub-line.
	local function stat(parent, size, accent, icon, caption, valueColor, valueSize)
		local f = card(parent, size, accent)
		text(f, icon, UDim2.fromOffset(34, 30), UDim2.fromOffset(16, 11), 22, accent, true)
		oneLine(text(f, string.upper(caption), UDim2.new(1, -70, 0, 18),
			UDim2.fromOffset(54, 17), 11, C.muted, true))
		local value = oneLine(text(f, "-", UDim2.new(1, -28, 0, 34),
			UDim2.fromOffset(18, 44), valueSize or 26, valueColor or C.white, true))
		local sub = oneLine(text(f, "", UDim2.new(1, -28, 0, 16),
			UDim2.fromOffset(18, 80), 11, C.muted))
		return value, sub
	end

	local function row(parent, height)
		local r = make("Frame", {
			Size = UDim2.new(1, -5, 0, height), BackgroundTransparency = 1,
		}, parent)
		make("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			Padding = UDim.new(0, 9), SortOrder = Enum.SortOrder.LayoutOrder,
		}, r)
		return r
	end

	local HALF = UDim2.new(0.5, -5, 1, 0)

	function M.build()
		table.clear(refs)
		local lp = player

		-- Profile --------------------------------------------------------------
		local pc = card(page, UDim2.new(1, -5, 0, 104), C.purple)
		local avFrame = make("Frame", {
			Size = UDim2.fromOffset(72, 72), Position = UDim2.fromOffset(20, 16),
			BackgroundColor3 = C.panel, BorderSizePixel = 0,
		}, pc)
		round(avFrame, 36)
		make("UIStroke", { Color = C.purple, Thickness = 2, Transparency = 0.1 }, avFrame)
		local av = make("ImageLabel", {
			Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1,
			Image = "rbxthumb://type=AvatarHeadShot&id=" .. tostring(lp.UserId) .. "&w=150&h=150",
		}, avFrame)
		round(av, 36)
		oneLine(text(pc, lp.DisplayName, UDim2.new(1, -124, 0, 26),
			UDim2.fromOffset(108, 14), 20, C.white, true))
		oneLine(text(pc, "@" .. lp.Name, UDim2.new(1, -124, 0, 18),
			UDim2.fromOffset(108, 41), 13, C.muted))
		local chips = make("Frame", {
			Size = UDim2.new(1, -124, 0, 22), Position = UDim2.fromOffset(108, 68),
			BackgroundTransparency = 1,
		}, pc)
		make("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder,
		}, chips)
		refs.rebirth = chip(chips, "Rebirth 0", C.purpleGlow)
		chip(chips, tostring(lp.AccountAge) .. " days old")
		chip(chips, "ID " .. tostring(lp.UserId))

		-- Halloween currency ---------------------------------------------------
		sectionTitle("Halloween")
		local r1 = row(page, 104)
		refs.pumpkin, refs.pumpkinSub = stat(r1, HALF, ORANGE, "🎃", "Pumpkins", C.white)
		refs.candy,   refs.candySub   = stat(r1, HALF, PINK,   "🍬", "Candy",    C.white)

		-- Economy --------------------------------------------------------------
		sectionTitle("Economy")
		local r2 = row(page, 104)
		refs.rate,  refs.rateSub  = stat(r2, HALF, C.green, "💰", "Money / second", C.green)
		refs.money, refs.moneySub = stat(r2, HALF, C.purpleGlow, "🏦", "Total money", C.white)

		-- Tower ----------------------------------------------------------------
		sectionTitle("Tower")
		local r3 = row(page, 104)
		r3.Size = UDim2.new(1, -5, 0, 104)
		refs.floor, refs.floorSub = stat(r3, UDim2.new(1, 0, 1, 0), C.purple, "🏰", "Current tower floor", C.white)

		M.refresh()
	end

	local mini
	function M.setMini(v)
		if mini then mini.Visible = v end
	end

	function M.refresh()
		local d = data()
		if not d then return end

		-- Tower floor feeds both the page and the minimized tab.
		local floorTxt = (STATE.towerRuns > 0 or STATE.towerFloor > 0) and tostring(STATE.towerFloor) or "-"
		if mini then mini.Text = "🏰 Floor " .. floorTxt end

		local function alive_(l) return l and l.Parent end
		if not alive_(refs.floor) then return end

		if alive_(refs.rebirth) then refs.rebirth.Text = "Rebirth " .. tostring(d.Rebirth or 0) end

		local pump = findAmount({ "Pumpkins", "Pumpkin", "HalloweenPumpkins", "Halloween Pumpkins" },
			{ "pumpkin" })
		local candy = findAmount({ "Candy", "Candies", "HalloweenCandy", "Halloween Candy" },
			{ "candy", "candies" })
		refs.pumpkin.Text = pump and fmt(pump) or "-"
		refs.pumpkinSub.Text = pump and "collected" or "not found in player data"
		refs.candy.Text = candy and fmt(candy) or "-"
		refs.candySub.Text = candy and "collected" or "not found in player data"

		local rate, mult = incomeNow()
		local shown = rate
		if shown <= 0 then shown = STATE.incomePerSec or 0 end
		refs.rate.Text = fmt(shown) .. "/s"
		refs.rateSub.Text = "buffs " .. multText(mult) .. " included  |  measured " .. fmt(STATE.incomePerSec or 0) .. "/s"
		refs.money.Text = fmt(d.Money or 0)
		refs.moneySub.Text = fmt(shown * 60) .. " per minute"

		refs.floor.Text = floorTxt == "-" and "No run yet" or ("Floor " .. floorTxt)
		local towerName = (STATE.towerPick and STATE.towerPick ~= "-") and STATE.towerPick or tostring(CONFIG.tower)
		refs.floorSub.Text = towerName .. "  |  " .. (CONFIG.autoTower and "running" or "idle")
			.. "  |  best floor " .. tostring(STATE.towerBest)
	end

	-- Minimized-tab floor readout. Lives on `main` (not the header) because
	-- setMinimized hides every header child while minimized.
	mini = make("TextLabel", {
		Size = UDim2.fromOffset(100, 45), Position = UDim2.fromOffset(12, 0),
		BackgroundTransparency = 1, Text = "🏰 Floor -", TextColor3 = C.white,
		TextSize = 12, Font = Enum.Font.GothamBold, TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd, Visible = false,
	}, main)

	task.spawn(function()
		while _G.__ANIMEDICE == generation and gui.Parent do
			pcall(M.refresh)
			task.wait(0.5)
		end
	end)

	return M
end)()

local function clearPage()
	clearPageConnections()
	for _, child in ipairs(page:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

local function render(category)
	currentCategory = category
	clearPage()

	for _, item in ipairs(categories) do
		local button = navButtons[item.name]
		if button then
			local active = item.name == category
			button.BackgroundColor3 = active and C.purpleDark or C.panel
			button.TextColor3 = active and C.white or C.muted
		end
	end

	for _, item in ipairs(categories) do
		if item.name == category then
			pageTitle.Text = string.upper(item.name)
			pageSubtitle.Text = item.subtitle
			break
		end
	end

	if category == "Main" then
		MainTab.build()
		page.Position = UDim2.fromOffset(8, 70)
		tween(page, 0.24, { Position = UDim2.fromOffset(0, 70) }, Enum.EasingStyle.Quint)
		return
	end

	sectionTitle(category .. " features")

	for _, feature in ipairs(definitions[category] or {}) do
		featureCard(feature[1], feature[2])
	end

	if category == "Rolling & Units" then
		sectionTitle("Auto sell rarities")
		multiSelect(
			"Select rarities to sell",
			"Selected rarities are marked with a check.",
			rarities,
			sellRarities,
			"sell"
		)
	elseif category == "Tower" then
		sectionTitle("Tower selection")
		singleSelect(
			"Choose tower",
			"Select your preferred tower.",
			towers,
			function() return selectedTower end,
			function(v) selectedTower = v; CONFIG.tower = v end
		)
	elseif category == "Halloween" then
		sectionTitle("Halloween tower area")
		singleSelect(
			"Choose area",
			"Select your preferred Halloween area.",
			halloweenAreas,
			function() return selectedHalloween end,
			function(v) selectedHalloween = v; if enabled["Auto Halloween Tower"] then CONFIG.tower = v end end
		)
		sectionTitle("Trick or Treat route plan")
		local routeCard = make("Frame", {
			Size = UDim2.new(1, -5, 0, 98),
			BackgroundColor3 = C.card,
			BorderSizePixel = 0,
		}, page)
		round(routeCard, 9)
		text(routeCard, "FIXED HOUSE ROUTE", UDim2.new(1, -24, 0, 25),
			UDim2.fromOffset(12, 6), 12, C.white, true)
		text(routeCard,
			"Visits every tagged trick-or-treat door: the nearest ready door first, then the one that is ready soonest. Each door has a 30s cooldown.",
			UDim2.new(1, -24, 0, 55), UDim2.fromOffset(12, 32), 11, C.muted)
		sectionTitle("Connection status")
		local state = text(page,
			"Auto Halloween Tower, Auto Claim Halloween Quest and Auto Trick or Treat are connected. Trick or Treat teleports you door to door on the Halloween island.",
			UDim2.new(1, -5, 0, 42), UDim2.new(), 11, C.muted)
		state.TextWrapped = true
	elseif category == "Potions" then
		sectionTitle("Potion selection")
		local potionNames = {
			"Luck Potion", "Speed Potion",
			"Coin Potion", "Damage Potion",
		}
		multiSelect(
			"Choose potions",
			"Luck, Speed (roll time), Coin (money) and Damage. Damage potions are used when a tower run starts.",
			potionNames,
			potionChoices,
			"potions"
		)
		multiSelect(
			"Potion families",
			"A potion is used only if its family and its type above are both ticked.",
			{ "Normal", "Dragon", "Cursed", "Pirate", "Leaf", "Shadow", "Slayer", "Spooky" },
			CONFIG.potionFamilies,
			"families"
		)
		singleSelect(
			"Potion stacking",
			"Don't Stack: one potion per category at a time. Stack: also one of each potion kind.",
			{"Stack", "Don't Stack"},
			function()
				return CONFIG.stackPotions and "Stack" or "Don't Stack"
			end,
			function(v)
				CONFIG.stackPotions = v == "Stack"
			end
		)
	elseif category == "Settings" then
		sectionTitle("Window size")
		singleSelect(
			"GUI size",
			"Smaller windows fit a minimized Roblox window. It also shrinks on its own to fit the screen.",
			{ "Small", "Medium", "Large" },
			function()
				local g = CONFIG.guiScale or 0.8
				return g <= 0.65 and "Small" or (g >= 0.95 and "Large" or "Medium")
			end,
			function(v)
				CONFIG.guiScale = v == "Small" and 0.6 or (v == "Large" and 1 or 0.8)
				applyFit()
			end
		)
		sectionTitle("Keybind")
		local keyLabel = text(page,
			"Current key: " .. minimizeKey.Name,
			UDim2.new(1, -5, 0, 35), UDim2.new(),
			12, C.white, true)

		local capture = make("TextButton", {
			Size = UDim2.new(1, -5, 0, 40),
			BackgroundColor3 = C.card,
			Text = "CLICK HERE, THEN PRESS A KEY",
			TextColor3 = C.white,
			TextSize = 11,
			Font = Enum.Font.GothamBold,
			BorderSizePixel = 0,
		}, page)
		round(capture, 8)

		connect(capture.Activated, function()
			waitingForKey = true
			capture.Text = "PRESS ANY KEY..."
		end, true)

		-- Update the visible label when a key is selected.
		connect(UIS.InputBegan, function(input, processed)
			if not waitingForKey or processed then return end
			if input.UserInputType == Enum.UserInputType.Keyboard
				and input.KeyCode ~= Enum.KeyCode.Unknown then
				minimizeKey = input.KeyCode
				waitingForKey = false
				keyLabel.Text = "Current key: " .. minimizeKey.Name
				capture.Text = "CLICK HERE, THEN PRESS A KEY"
			end
		end, true)
	end

	-- Slide the rebuilt page in smoothly.
	page.Position = UDim2.fromOffset(8, 70)
	tween(page, 0.24, {
		Position = UDim2.fromOffset(0, 70),
	}, Enum.EasingStyle.Quint)
end

for i, item in ipairs(categories) do
	local button = make("TextButton", {
		Name = item.name,
		Size = UDim2.new(1, 0, 0, 48),
		BackgroundColor3 = C.panel,
		Text = item.icon .. "  " .. item.name,
		TextColor3 = C.muted,
		TextSize = 14,
		Font = Enum.Font.GothamSemibold,
		TextXAlignment = Enum.TextXAlignment.Left,
		BorderSizePixel = 0,
		LayoutOrder = i,
		AutoButtonColor = false,
	}, navList)
	round(button, 7)

	local navScale = make("UIScale", {Scale = 1}, button)
	connect(button.MouseEnter, function()
		tween(button, 0.16, {BackgroundColor3 = C.hover, TextColor3 = C.white})
		tween(navScale, 0.16, {Scale = 1.025})
	end)
	connect(button.MouseLeave, function()
		local active = currentCategory == item.name
		tween(button, 0.16, {
			BackgroundColor3 = active and C.purpleDark or C.panel,
			TextColor3 = active and C.white or C.muted,
		})
		tween(navScale, 0.16, {Scale = 1})
	end)

	make("UIPadding", {
		PaddingLeft = UDim.new(0, 14),
	}, button)

	navButtons[item.name] = button

	connect(button.Activated, function()
		render(item.name)
	end)
end

-- DRAGGING

local dragging = false
local dragStart
local startPosition

connect(header.InputBegan, function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch then
		dragging = true
		dragStart = input.Position
		startPosition = main.Position
	end
end)

connect(UIS.InputChanged, function(input)
	if not dragging then return end
	if input.UserInputType == Enum.UserInputType.MouseMovement
		or input.UserInputType == Enum.UserInputType.Touch then
		local delta = input.Position - dragStart
		local vp = gui.AbsoluteSize
		if vp.X > 0 and vp.Y > 0 then
			main.Position = UDim2.new(
				startPosition.X.Scale + delta.X / vp.X, startPosition.X.Offset,
				startPosition.Y.Scale + delta.Y / vp.Y, startPosition.Y.Offset
			)
		end
	end
end)

connect(UIS.InputEnded, function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch then
		dragging = false
	end
end)

-- MINIMIZE / RESTORE

-- The minimized tab and the open panel keep separate positions: the tab stays
-- wherever it was dragged, and the panel always opens centred (and can then be
-- moved freely without touching the tab's spot).
local tabPosition
local function setMinimized(value)
	minimized = value

	content.Visible = not value
	nav.Visible = not value
	MainTab.setMini(value)

	local targetPosition
	if value then
		tabPosition = tabPosition or main.Position
		targetPosition = tabPosition
	else
		tabPosition = main.Position   -- remember where the tab was left
		targetPosition = UDim2.fromScale(0.5, 0.5)
	end

	-- Resize the window and move it to the tab spot / the centre.
	tween(main, 0.28, {
		Size = value
			and UDim2.fromOffset(180, 45)
			or UDim2.fromOffset(850, 530),
		Position = targetPosition,
	}, Enum.EasingStyle.Quint)

	tween(header, 0.28, {
		Size = value
			and UDim2.fromOffset(180, 45)
			or UDim2.new(1, 0, 0, 65),
	}, Enum.EasingStyle.Quint)

	-- Hide every direct header element except the two control buttons.
	-- This uses the actual objects in the uploaded script, so it does
	-- not depend on titleLabel/subtitleLabel variables that don't exist.
	for _, child in ipairs(header:GetChildren()) do
		if child:IsA("GuiObject")
			and child ~= minimizeButton
			and child ~= closeButton
			and child.Name ~= "MiniBanner" then
			child.Visible = not value
		end
	end

	local miniBanner = header:FindFirstChild("MiniBanner")
	if miniBanner then miniBanner.Visible = value end

	-- Keep both buttons visible and inside the minimized window.
	minimizeButton.Visible = true
	closeButton.Visible = true

	minimizeButton.Size = value
		and UDim2.fromOffset(26, 25)
		or UDim2.fromOffset(32, 31)

	minimizeButton.Position = value
		and UDim2.new(1, -64, 0, 10)
		or UDim2.new(1, -76, 0, 17)

	closeButton.Size = value
		and UDim2.fromOffset(26, 25)
		or UDim2.fromOffset(32, 31)

	closeButton.Position = value
		and UDim2.new(1, -33, 0, 10)
		or UDim2.new(1, -37, 0, 17)

	minimizeButton.Text = value and "□" or "—"
end

connect(minimizeButton.Activated, function()
	setMinimized(not minimized)
end)

connect(UIS.InputBegan, function(input, processed)
	if not alive or processed then return end
	if waitingForKey then return end

	if input.KeyCode == minimizeKey then
		setMinimized(not minimized)
	end
end)

connect(closeButton.Activated, function()
	if not alive then return end
	alive = false

	-- Unload the backend too: every automation loop checks this generation token.
	-- Bumping it makes those loops exit instead of continuing after the UI closes.
	if _G.__ANIMEDICE == generation then
		_G.__ANIMEDICE = generation + 1
	end

	clearPageConnections()
	for _, c in ipairs(connections) do
		pcall(function() c:Disconnect() end)
	end
	table.clear(connections)

	-- Remove public handles so another script cannot mistake this instance as active.
	if _G.AnimeDiceHubGetSettings then _G.AnimeDiceHubGetSettings = nil end
	if _G.__ANIMEDICE_GUI == gui then _G.__ANIMEDICE_GUI = nil end

	local function destroyGui()
		pcall(function() gui:Destroy() end)
	end
	local closeTween = tween(main, 0.2, {
		Size = UDim2.fromOffset(0, 0),
		BackgroundTransparency = 1,
	}, Enum.EasingStyle.Quint)

	if closeTween then
		closeTween.Completed:Once(destroyGui)
	else
		destroyGui()
	end
end)

-- Expose a read-only snapshot for an authorized integration to consume.
_G.AnimeDiceHubGetSettings = function()
	return {
		enabled = table.clone(enabled),
		sellRarities = table.clone(sellRarities),
		potionChoices = table.clone(potionChoices),
		selectedTower = selectedTower,
		selectedHalloween = selectedHalloween,
		halloweenRoute = table.clone(halloweenRoute),
		halloweenDoorWait = halloweenDoorWait,
	}
end

render("Main")


do
---------------------------------------------- halloween quests + trick or treat -----
-- Verified from the game's own modules (HalloweenQuestService, TrickOrTreatService):
--  * Quest claim: Claim:FireServer(period, questId) with period "Hourly" or "Daily";
--    the server wants the quest in data().Halloween[dataKey].ids, progress >= target,
--    not yet claimed. dataKey: Hourly -> HourlyQuests, Daily -> Quests.
--  * Trick or treat is checked on the SERVER every 0.2s from your character's
--    position: inside a door part's range (model attribute Range, default 14
--    studs horizontally, under 20 vertically), the door armed and its readyAt
--    passed. Each door then cools down 30s. Two knocks must be at least
--    max(2s, distance/60) apart. Doors are parts tagged "TrickOrTreatDoor".
local HalloweenQuestsCfg
pcall(function() HalloweenQuestsCfg = require(Framework.Features.Halloween.HalloweenQuests) end)
CONFIG.autoHalloweenQuest = CONFIG.autoHalloweenQuest or false
CONFIG.autoTrickOrTreat = CONFIG.autoTrickOrTreat or false
STATE.halloweenQuests = STATE.halloweenQuests or 0
STATE.totKnocks = STATE.totKnocks or 0

local function doHalloweenQuests()
	if not (HalloweenQuestsCfg and R.HalloweenQuestClaim) then return end
	local h = data().Halloween
	if type(h) ~= "table" then return end
	for _, period in ipairs(HalloweenQuestsCfg.PERIODS or {}) do
		local def = HalloweenQuestsCfg[period]
		local q = def and h[def.dataKey]
		if type(q) == "table" and type(q.ids) == "table" then
			local targets = {}
			for _, item in ipairs(def.pool or {}) do targets[item.id] = item.target end
			for _, id in ipairs(q.ids) do
				local claimed = type(q.claimed) == "table" and q.claimed[id]
				local progress = type(q.progress) == "table" and tonumber(q.progress[id]) or 0
				if not claimed and targets[id] and progress >= targets[id] then
					R.HalloweenQuestClaim:FireServer(period, id)
					STATE.halloweenQuests = STATE.halloweenQuests + 1
					STATE.note = "halloween quest " .. period .. " " .. tostring(id)
					task.wait(0.4)   -- the server debounces claims at 0.2s
				end
			end
		end
	end
end

local CollectionService = game:GetService("CollectionService")
local totNext = {}        -- door part -> os.clock() when it should be ready again
local totKnockedAt = {}   -- door part -> os.clock() of the last Knocked event
local totLastDoor
if R.TotKnocked then
	local conn
	conn = R.TotKnocked.OnClientEvent:Connect(function(...)
		if _G.__ANIMEDICE ~= generation then conn:Disconnect(); return end
		local args = { ... }
		local part = args[1]
		if typeof(part) ~= "Instance" then return end
		local readyAt = tonumber(args[#args]) or (workspace:GetServerTimeNow() + 30)
		totNext[part] = os.clock() + math.max(0, readyAt - workspace:GetServerTimeNow()) + 0.5
		totKnockedAt[part] = os.clock()
		STATE.totKnocks = STATE.totKnocks + 1
	end)
end

local function doTrickOrTreat()
	local char = Players.LocalPlayer.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp then return end
	local doors = CollectionService:GetTagged("TrickOrTreatDoor")
	if #doors == 0 then
		STATE.note = "trick or treat: no doors found - go to the Halloween island"
		task.wait(3)
		return
	end
	local now = os.clock()
	local best, bestKey
	for _, d in ipairs(doors) do
		if d:IsA("BasePart") and d:IsDescendantOf(workspace) then
			local t = totNext[d] or 0
			local key
			if t <= now then
				key = (d.Position - hrp.Position).Magnitude        -- ready: nearest first
			else
				key = 1e9 + t                                      -- cooling: soonest first
			end
			if not bestKey or key < bestKey then best, bestKey = d, key end
		end
	end
	if not best then return end
	local readyIn = (totNext[best] or 0) - now
	if readyIn > 0 then
		STATE.note = string.format("trick or treat: next door in %ds", math.ceil(readyIn))
		task.wait(math.min(readyIn, 1))
		return
	end
	-- Leave the last door's range first, otherwise it never re-arms.
	if best == totLastDoor then
		hrp.CFrame = CFrame.new(best.Position + Vector3.new(35, 3, 0))
		task.wait(0.6)
	end
	local gap = (totLastDoor and (best.Position - totLastDoor.Position).Magnitude or 0) / 50
	totKnockedAt[best] = nil
	local t0 = os.clock()
	hrp.CFrame = CFrame.new(best.Position + Vector3.new(0, 3, 0))
	hrp.AssemblyLinearVelocity = Vector3.zero
	local window = 3.5 + gap
	while os.clock() - t0 < window and not totKnockedAt[best] and _G.__ANIMEDICE == generation do
		task.wait(0.1)
	end
	if totKnockedAt[best] then
		totLastDoor = best
		STATE.note = "trick or treat: knocked (" .. tostring(STATE.totKnocks) .. " total)"
	else
		-- Not knocked: usually just armed for the first time, which needs up to 30s.
		totNext[best] = os.clock() + 20
	end
end

-- Halloween quests (cheap) and trick-or-treat doors.
task.spawn(function()
	while _G.__ANIMEDICE == generation do
		if CONFIG.autoHalloweenQuest then pcall(doHalloweenQuests) end
		task.wait(5)
	end
end)
task.spawn(function()
	while _G.__ANIMEDICE == generation do
		if CONFIG.autoTrickOrTreat then
			pcall(doTrickOrTreat)
			task.wait(0.3)
		else
			task.wait(1)
		end
	end
end)
end

do
	-- Roblox kicks a player after 20 minutes without input. Silent, two layers:
	-- 1) Idled fires right before the kick: answer it with a virtual click.
	-- 2) a keep-alive click every 4 minutes, so the timer never gets that far.
	-- Both only act while the Anti-AFK toggle is on.
	CONFIG.antiAfk = CONFIG.antiAfk or false
	STATE.afkPings = STATE.afkPings or 0
	local VirtualUser = game:GetService("VirtualUser")
	local warned = false
	-- Silent: a virtual click that only resets Roblox's idle timer. No character
	-- movement, no jump, and the real mouse cursor is not touched.
	local function ping()
		local ok, err = pcall(function()
			VirtualUser:CaptureController()
			VirtualUser:ClickButton2(Vector2.new(0, 0))
		end)
		if not ok and not warned then
			warned = true
			print("[AnimeDiceHub] anti-afk: VirtualUser failed: " .. tostring(err))
		end
		STATE.afkPings = STATE.afkPings + 1
		STATE.afkLast = os.clock()
		print(string.format("[AnimeDiceHub] anti-afk ping #%d %s", STATE.afkPings, ok and "sent" or "FAILED"))
		if _G.AnimeDiceLog then _G.AnimeDiceLog("anti-afk ping #" .. STATE.afkPings .. (ok and " sent" or " FAILED")) end
		return ok
	end
	-- What Infinite Yield's anti-idle does first: switch off the connections already
	-- attached to Idled (when the executor offers getconnections), then add ours.
	local getConns = getconnections or get_signal_cons
	if getConns then
		pcall(function()
			for _, c in ipairs(getConns(Players.LocalPlayer.Idled)) do pcall(function() c:Disable() end) end
		end)
	end
	local idleConn
	idleConn = Players.LocalPlayer.Idled:Connect(function()
		if _G.__ANIMEDICE ~= generation then idleConn:Disconnect(); return end
		if CONFIG.antiAfk then ping(); STATE.note = "anti-afk: answered idle warning" end
	end)
	task.spawn(function()
		while _G.__ANIMEDICE == generation do
			task.wait(240)
			if CONFIG.antiAfk then ping() end
		end
	end)
	-- Quick check without waiting 20 minutes: run _G.AnimeDiceTestAfk() and watch
	-- STATE.afkPings go up with no error in the console.
	-- Session log in your executor's workspace folder (AnimeDice_log.txt), so that
	-- after a long idle you can see WHY the script went away: disconnect message,
	-- teleport/server change, or the window being destroyed.
	local logLines = {}
	local function logEvent(msg)
		logLines[#logLines + 1] = os.date("%H:%M:%S") .. "  " .. msg
		if #logLines > 300 then table.remove(logLines, 1) end
		if type(writefile) == "function" then
			pcall(writefile, "AnimeDice_log.txt", table.concat(logLines, "\n"))
		end
	end
	_G.AnimeDiceLog = logEvent
	logEvent("script started | job " .. tostring(game.JobId) .. " | place " .. tostring(game.PlaceId))
	connect(gui.Destroying, function() logEvent("GUI destroyed (by close button or by something else)") end)
	connect(gui.AncestryChanged, function(_, parent) logEvent("GUI parent changed to " .. tostring(parent)) end)
	connect(Players.LocalPlayer.OnTeleport, function(state) logEvent("teleport state: " .. tostring(state)) end)
	connect(Players.PlayerRemoving, function(p)
		if p == Players.LocalPlayer then logEvent("local player is being removed from the game") end
	end)
	pcall(function()
		local GuiService = game:GetService("GuiService")
		connect(GuiService.ErrorMessageChanged, function()
			logEvent("game error message: " .. tostring(GuiService:GetErrorMessage()) .. " (code " .. tostring(GuiService:GetErrorCode()) .. ")")
		end)
	end)
	pcall(function()
		connect(game:GetService("NetworkClient").ChildRemoved, function() logEvent("network client connection removed") end)
	end)

	-- The game's own client script "AFK" waits 1080 seconds (18 minutes) with no
	-- UserInputService input, then calls TeleportService:Teleport(game.PlaceId), which
	-- rejoins you and wipes this script. VirtualUser input never reaches
	-- UserInputService, so it can't reset that timer. The game's AFK script re-arms the
	-- timer from its InputBegan handler, so while Anti-AFK is on we call that handler
	-- every 4 minutes (found through getconnections). If the executor can't, we send an
	-- F15 key press, which nothing in the game uses. No movement, no clicks, no jump.
	local function resetGameAfk()
		local UIS = game:GetService("UserInputService")
		local how = "none"
		local gc = getconnections or get_signal_cons
		if gc then
			pcall(function()
				for _, c in ipairs(gc(UIS.InputBegan)) do
					local f = c.Function
					if f then
						local okInfo, src = pcall(debug.info, f, "s")
						if okInfo and type(src) == "string" and string.find(src, "AFK", 1, true) then
							task.spawn(f)
							how = "game timer reset"
						end
					end
				end
			end)
		end
		if how == "none" then
			pcall(function()
				local vim = game:GetService("VirtualInputManager")
				vim:SendKeyEvent(true, Enum.KeyCode.F15, false, game)
				task.wait(0.05)
				vim:SendKeyEvent(false, Enum.KeyCode.F15, false, game)
				how = "F15 key fallback"
			end)
		end
		logEvent("game AFK timer: " .. how)
		print("[AnimeDiceHub] anti-afk: game AFK timer -> " .. how)
		return how
	end
	pcall(function()
		if hookmetamethod and getnamecallmethod then
			local TeleportService = game:GetService("TeleportService")
			local wrap = newcclosure or function(f) return f end
			local checkc = checkcaller or function() return false end
			local oldNamecall
			oldNamecall = hookmetamethod(game, "__namecall", wrap(function(self, ...)
				if CONFIG.antiAfk and _G.__ANIMEDICE == generation and self == TeleportService
					and getnamecallmethod() == "Teleport" and not checkc() then
					local placeId = ...
					if placeId == game.PlaceId then
						logEvent("blocked a same-place Teleport made by the game")
						return
					end
				end
				return oldNamecall(self, ...)
			end))
		end
	end)
	task.spawn(function()
		local last = -1e9
		while _G.__ANIMEDICE == generation do
			if CONFIG.antiAfk and os.clock() - last >= 240 then
				last = os.clock()
				pcall(resetGameAfk)
			end
			task.wait(5)
		end
	end)

	-- Writes the game's whole AFK script to AnimeDice_afk_source.txt so it can be read
	-- instead of guessed at.
	_G.AnimeDiceDumpAfk = function()
		local ps = Players.LocalPlayer:FindFirstChild("PlayerScripts")
		local afk = ps and ps:FindFirstChild("AFK")
		if not afk then print("[AnimeDiceHub] no AFK script found (already removed?)"); return end
		if type(decompile) ~= "function" or type(writefile) ~= "function" then
			print("[AnimeDiceHub] this executor has no decompile/writefile"); return
		end
		local ok, src = pcall(decompile, afk)
		if ok then
			pcall(writefile, "AnimeDice_afk_source.txt", tostring(src))
			print("[AnimeDiceHub] AFK script saved to AnimeDice_afk_source.txt")
		else
			print("[AnimeDiceHub] decompile failed: " .. tostring(src))
		end
	end

	-- Finds the GAME's own AFK / teleport code. The log showed the client starting a
	-- teleport after ~19 minutes, which is not Roblox's idle kick but the game moving
	-- you itself. Run _G.AnimeDiceFindAfk() once (it can take a few seconds); it writes
	-- AnimeDice_afk_scan.txt to the executor workspace folder.
	_G.AnimeDiceFindAfk = function()
		local out, scanned = {}, 0
		local canDecompile = type(decompile) == "function"
		local roots = { game:GetService("ReplicatedStorage"), Players.LocalPlayer:FindFirstChild("PlayerScripts"),
			Players.LocalPlayer:FindFirstChild("PlayerGui") }
		local keywords = { "TeleportService", "Teleport(", "AFK", "Afk", "afk", "Idled", "LastInput", "idle", "Rejoin", "Kick" }
		for _, root in ipairs(roots) do
			for _, inst in ipairs(root:GetDescendants()) do
				if (inst:IsA("LocalScript") or inst:IsA("ModuleScript")) and scanned < 600 then
					scanned = scanned + 1
					local nameHit = inst.Name:lower():find("afk", 1, true) or inst.Name:lower():find("idle", 1, true)
					if nameHit then out[#out + 1] = "NAME MATCH: " .. inst:GetFullName() end
					if canDecompile then
						local ok, src = pcall(decompile, inst)
						if ok and type(src) == "string" then
							local hits = {}
							local n = 0
							for line in src:gmatch("[^\n]+") do
								n = n + 1
								for _, k in ipairs(keywords) do
									if line:find(k, 1, true) then hits[#hits + 1] = "  " .. n .. ": " .. line:sub(1, 160); break end
								end
								if #hits >= 25 then break end
							end
							if #hits > 0 and (nameHit or src:find("TeleportService", 1, true)) then
								out[#out + 1] = "== " .. inst:GetFullName()
								for _, h in ipairs(hits) do out[#out + 1] = h end
							end
						end
						if scanned % 10 == 0 then task.wait() end
					end
				end
			end
		end
		out[#out + 1] = string.format("scanned %d scripts, decompile available: %s", scanned, tostring(canDecompile))
		if type(writefile) == "function" then pcall(writefile, "AnimeDice_afk_scan.txt", table.concat(out, "\n")) end
		print("[AnimeDiceHub] AFK scan finished: " .. #out .. " lines written to AnimeDice_afk_scan.txt")
		return out
	end

	-- After leaving it idle with the monitor off, run _G.AnimeDiceAfkStatus(): if the
	-- ping count kept rising the script kept running; if it is stuck, Roblox itself
	-- was throttled or frozen while the display was off.
	_G.AnimeDiceAfkStatus = function()
		print(string.format("[AnimeDiceHub] anti-afk: toggle=%s pings=%d last ping %ds ago",
			tostring(CONFIG.antiAfk), STATE.afkPings or 0,
			STATE.afkLast and math.floor(os.clock() - STATE.afkLast) or -1))
	end
	_G.AnimeDiceTestAfk = function() local a = ping(); print("[AnimeDiceHub] anti-afk test: VirtualUser=" .. tostring(a) .. " toggle=" .. tostring(CONFIG.antiAfk)); return a end
end

--------------------------------------------------------------------- loops -----

-- Roll runs on its own clock so the cooldown paces it regardless of the economy.
task.spawn(function()
	while _G.__ANIMEDICE == generation do
		if CONFIG.autoRoll then pcall(doRoll) end
		task.wait(rollInterval())
	end
end)

-- Collect, then equip best. Each has its own toggle. Cheap and safe to run often;
-- it is the money engine.
task.spawn(function()
	while _G.__ANIMEDICE == generation do
		if CONFIG.autoCollect then pcall(doCollectPlace) end
		-- Auto Equip Best Unit: the game's own EquipBest.
		if CONFIG.smartPlace and R.EquipBest then
			pcall(function() R.EquipBest:FireServer() end)
		end
		task.wait(5)
	end
end)

-- Watch for new inventory entries and sell selected rarities promptly.
task.spawn(function()
	while _G.__ANIMEDICE == generation do
		pcall(autoSellNewUnits)
		task.wait(0.35)
	end
end)

-- Grade/trait rerolls on the earning units, paid in Gems / Trait Rerolls.
task.spawn(function()
	while _G.__ANIMEDICE == generation do
		if CONFIG.autoGrade or CONFIG.autoTrait then pcall(doRerolls) end
		task.wait(3)
	end
end)

-- Fuse machine: one balanced trio per pass, off while saving for a luck step.
task.spawn(function()
	while _G.__ANIMEDICE == generation do
		if CONFIG.autoFusion and not savingForLuck() then pcall(doFuse) end
		task.wait(4)
	end
end)

-- Owned Luck/Income boosts, each category kept running.
task.spawn(function()
	while _G.__ANIMEDICE == generation do
		if CONFIG.autoBoost then pcall(useBoosts) end
		task.wait(10)
	end
end)

-- Tower farming: runs back to back; its drops feed the two loops above.
task.spawn(function()
	while _G.__ANIMEDICE == generation do
		if CONFIG.autoTower then
			pcall(towerRun)
			task.wait(3)
		else
			task.wait(2)
		end
	end
end)

-- The economy tick decides how to SPEND, in one place so the money reads stay
-- coherent: dice first (permanent luck), then rebirth (permanent x mult + slot),
-- then leftover into slot levels.
task.spawn(function()
	while _G.__ANIMEDICE == generation do
		do
			STATE.phase = "spending"
			-- Dice (permanent luck) and one upgrade tier (money/luck/roll speed/
			-- storage) each pass, then rebirth (permanent x mult + slot).
			-- The rebirth is the one purchase that wipes the balance, so it gets
			-- the money first. Once it is affordable, only the EXCESS it would wipe
			-- is spent on dice/upgrades, then it fires. Before that, a dice priced
			-- at or above the rebirth must wait, otherwise it takes the money the
			-- moment both are affordable (Solar 5e12 beat rebirth 5 that way) and
			-- the rebirth - x4/3 on every later second of income - slips again.
			local cost = CONFIG.autoRebirth and nextRebirthCost() or nil
			local need = cost and cost * math.max(1, CONFIG.rebirthMult) or nil
			if need and data().Money >= need then
				if CONFIG.autoDice then pcall(doDice, need) end
				if CONFIG.autoUpgrade then pcall(doUpgrade, need) end
				pcall(doRebirth)
			else
				local diceReserve, upReserve = 0, 0
				if need then
					local nextDice
					for _, die in ipairs(DICE) do
						if die.price and not data().OwnedDice[die.key] and die.luck > ownedLuck() then
							if not nextDice or die.price < nextDice then nextDice = die.price end
						end
					end
					if nextDice and nextDice >= need then diceReserve = need end
				end
				if savingForLuck() then upReserve = nextLuckGoal() or 0 end
				if CONFIG.autoDice then pcall(doDice, diceReserve) end
				if CONFIG.autoUpgrade then pcall(doUpgrade, upReserve) end
			end
			-- Leveling comes last so dice/upgrades/rebirth get first claim on the
			-- money; it then pours its share of whatever is left into the slots.
			if CONFIG.autoLevel then pcall(levelSlots) end
		end
		task.wait(3)
	end
end)

-- Codes once, then claims, quests, ticket gamepasses and rebirth points.
task.spawn(function()
	while _G.__ANIMEDICE == generation do
		if CONFIG.autoCodes then pcall(doCodes) end
		if CONFIG.autoClaim then pcall(doClaims) end
		if CONFIG.autoQuests then pcall(doQuests) end
		if CONFIG.autoPasses then pcall(doPasses) end
		if CONFIG.autoStats then pcall(doStats) end
		task.wait(30)
	end
end)

-- Snapshot for the UI + an income/s estimate from positive slot-balance deltas.
task.spawn(function()
	local lastSum, lastT = nil, os.clock()
	while _G.__ANIMEDICE == generation do
		local d = data()
		STATE.money = d.Money
		STATE.rolls = d.Rolls
		STATE.rebirth = d.Rebirth
		STATE.dice = d.Dice or "-"
		-- Filled slots and owned UNITS - the old counts took empty slot entries and
		-- every item (Gems, boosts, spins) and read as a full plot / full bag.
		local filled, units = 0, 0
		for _, slot in pairs(d.Slots) do if slot.unitId then filled = filled + 1 end end
		for _, u in pairs(d.Inventory) do if UnitConfig.entries[u.name] then units = units + 1 end end
		STATE.slotsUsed = filled
		STATE.slotsMax = unlockedSlots()
		local _, bestName = ownedLuck()
		local pick = bestAffordableDice()
		STATE.nextDice = pick and pick.key or ("best: " .. bestName)
		STATE.invCount = units
		STATE.invCap = invCap()
		local up = bestUpgrade()
		STATE.nextUpgrade = up and (up.name .. " " .. fmt(up.price)) or "-"
		STATE.luck = rollLuck()

		local sum = 0
		for _, slot in pairs(d.Slots) do sum = sum + (slot.balance or 0) end
		local now = os.clock()
		if lastSum and now > lastT then
			local delta = sum - lastSum
			if delta > 0 then STATE.incomePerSec = delta / (now - lastT) end
		end
		lastSum, lastT = sum, now

		task.wait(2)
	end
end)

