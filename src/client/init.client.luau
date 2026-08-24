--!strict
-- init.client.luau — client bootstrap: requires and starts the client modules.

local MiningClient = require(script.MiningClient)
local InventoryUI = require(script.InventoryUI)
local CraftUI = require(script.CraftUI)
local BotClient = require(script.BotClient)
local BrainEditor = require(script.BrainEditor)
local GateClient = require(script.GateClient)

MiningClient.init()
InventoryUI.init()
CraftUI.init()
BotClient.init()
BrainEditor.init()
GateClient.init()

print("[scrapcraft] client up")
