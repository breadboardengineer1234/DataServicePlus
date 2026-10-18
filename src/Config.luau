--!strict

local template = {
}

--[[
- arrays and dictionaries have a 65,535 size limit
- dictionary keys have a 255 char limit
- strings in general have a 65,535 char limit
- only datastore types allowed (number, string, boolean, array, dictionary)
- number paths not supported (string only)
]]

local Config = {
	storeName = "TestStore1",
	useMock = true,
	template = template,
}

return Config
