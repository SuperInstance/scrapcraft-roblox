--!strict
-- Net.luau — shared RemoteEvent registry. Every pass gets its remotes through
-- this module so names exist exactly once (get-or-create in ReplicatedStorage).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = {}

Net.REMOTES = {
	Mine = "ScrapcraftMine",
	Inv = "ScrapcraftInv",
	Craft = "ScrapcraftCraft",
	Bot = "ScrapcraftBot",
	Brain = "ScrapcraftBrain", -- Phase 2 tile editor: open/save+run
	Gate = "ScrapcraftGate",  -- Phase 2 Earl's gate: dialogue + queue HUD
}

-- Net.remote(name) — `name` may be a Net.REMOTES key ("Mine") or a raw
-- RemoteEvent name ("ScrapcraftMine"). Returns the existing RemoteEvent from
-- ReplicatedStorage, creating it if missing.
function Net.remote(name: string): RemoteEvent
	local remoteName = Net.REMOTES[name]
	if remoteName == nil then
		remoteName = name
	end

	local existing = ReplicatedStorage:FindFirstChild(remoteName)
	if existing ~= nil and existing:IsA("RemoteEvent") then
		return existing
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = remoteName
	remote.Parent = ReplicatedStorage
	return remote
end

return Net
