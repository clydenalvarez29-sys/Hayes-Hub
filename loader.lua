-- Hayes Hub main loader: detects the game and runs the matching script.
local BASE = "https://raw.githubusercontent.com/clydenalvarez29-sys/Hayes-Hub/main/"

-- Key = the game's GameId (universe id, shared by every place in that game).
-- Not sure of an id? Run this loader in the game: it prints the id when unsupported.
local GAMES = {
	 [10708913337] = { name = "Anime Dice",  file = "scripts/anime-dice.lua" },
	-- [9876543210] = { name = "Other Game",  file = "scripts/other-game.lua" },
}

local function notify(title, body)
	pcall(function()
		game:GetService("StarterGui"):SetCore("SendNotification", {
			Title = title, Text = body, Duration = 6,
		})
	end)
end

local entry = GAMES[game.GameId]
if not entry then
	local msg = "Game not supported. GameId: " .. game.GameId .. "  PlaceId: " .. game.PlaceId
	print("[Hayes Hub] " .. msg)
	notify("Hayes Hub", "Game not supported (GameId " .. game.GameId .. ")")
	return
end

local ok, src = pcall(game.HttpGet, game, BASE .. entry.file)
if not ok or type(src) ~= "string" or src == "" or src:find("^404") then
	warn("[Hayes Hub] could not download " .. entry.file)
	notify("Hayes Hub", "Failed to download the " .. entry.name .. " script")
	return
end

local fn, err = loadstring(src)
if not fn then
	warn("[Hayes Hub] script error: " .. tostring(err))
	notify("Hayes Hub", "Script error, see console (F9)")
	return
end

notify("Hayes Hub", "Loading " .. entry.name .. "...")
fn()
