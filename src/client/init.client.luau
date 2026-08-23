--!strict
-- init.client.luau — client bootstrap: requires and starts the client modules.

local MiningClient = require(script.MiningClient)
local InventoryUI = require(script.InventoryUI)
local CraftUI = require(script.CraftUI)
local BotClient = require(script.BotClient)

MiningClient.init()
InventoryUI.init()
CraftUI.init()
BotClient.init()

print("[scrapcraft] client up")
