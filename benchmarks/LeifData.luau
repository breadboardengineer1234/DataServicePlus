local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataService = require(ReplicatedStorage.Modules.Packages.DataServiceTyped)

local template = {
	Cash = 22,
	Rebirth = 0,
	Upgrades = {
		Speed = 0,
		Damage = 0,
		Array = {},
	},
	Inventory = {
		Sword = {Damage = 2, Cooldown = 1.5}, 
		Bow = {Damage = 1, Cooldown = .5}
	},
}

return DataService(
	{
		dontSave = false,
		useMock = true,
		template = template,

	}
)

