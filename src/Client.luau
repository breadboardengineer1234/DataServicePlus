--!optimize 2
--!strict

local Players = game:GetService("Players")

local Internal = script.Parent.Internal
local Config = require(script.Parent.Config)
local InternalConfig = require(Internal.InternalConfig)
local Enums = require(Internal.Enums)
local Types = require(Internal.Types)
local Shared = require(Internal.Shared)
local Networker = require(Internal.Networker)
local Signal = require(Internal.UsefulSignal)

const SOURCE = InternalConfig.source
const VERSION = InternalConfig.version
const HASH_SEPARATOR = InternalConfig.hashSeparator
const CHANGED = Enums.changed
const ARRAY_INSERTED = Enums.arrayInserted
const ARRAY_REMOVED = Enums.arrayRemoved
const DICT_INSERTED = Enums.dictInserted
const DICT_REMOVED = Enums.dictRemoved
const DATA_REQUEST = Enums.dataRequest

export type Data = Types.Data
type Path = Types.Path
type Signal<T...> = Types.Signal<T...>
type Connection<T...> = Signal.Connection<T...>

local dataRequest = script.Parent:WaitForChild("DataRequest") :: RemoteEvent
local dataReadySignal = Signal.new()
local playerData: Data
local changed = {} :: {[string]: Signal<any, any>}
local arrayInserted = {} :: {[string]: Signal<number, any>}
local arrayRemoved = {} :: {[string]: Signal<number, any>}
local dictInserted = {} :: {[string]: Signal<string, any>}
local dictRemoved = {} :: {[string]: Signal<string, any>}

local DataServicePlus = {}
DataServicePlus.T = Shared.createTemplatePaths({___hash = ""}, Config.template :: any) :: Data

local function getSignal<T...>(hash: string, signals: {[string]: Signal<T...>}): Signal<T...>
	local signal = signals[hash]
	if not signal then
		signal = Signal.new()
		signals[hash] = signal
	end
	return signal
end

local function readPath(path: Path, data: Data): any
	local current = data
	for _, key in ipairs(path) do
		current = (current :: any)[key]		
	end
	return current
end

local function resolvePath(path: Path, data: Data): ({[any]: any}, string, any)
	local current = data
	local len = #path
	local layer: any
	local lastKey: string

	for i, key in ipairs(path) do
		if i == len then
			layer = current
			lastKey = key
		end
		current = (current :: any)[key]
	end
	return layer, lastKey, current
end

local function getPath(path: Path): any
	return rawget(path, "___path") or path
end

local function getHash(path: Path): string
	local hash = rawget(path, "___hash")
	if not hash then
		error(`{SOURCE} Invalid path`)
	end
	return hash
end

function DataServicePlus.getData(self: DataServicePlus): Data
	return playerData
end

function DataServicePlus.get(self: DataServicePlus, path: Path): any
	path = getPath(path)
	return readPath(path, playerData)
end

function DataServicePlus.changed(path: Path, callback: (newValue: any, oldValue: any) -> (), prefire: boolean?): Connection<any, any>?
	path = getPath(path)
	local hash = getHash(path)
	if prefire ~= false then
		if playerData then
			local value = readPath(path, playerData)
			task.spawn(callback, value, value)
		end
	end
	local signal = getSignal(hash, changed)
	return signal:Connect(callback)
end

function DataServicePlus.dictInserted(path: Path, callback: (key: string, value: any) -> ()): Connection<string, any>?
	path = getPath(path)
	local signal = getSignal(getHash(path), dictInserted)
	return signal:Connect(callback)
end

function DataServicePlus.dictRemoved(path: Path, callback: (key: string, value: any) -> ()): Connection<string, any>?
	path = getPath(path)
	local signal = getSignal(getHash(path), dictRemoved)
	return signal:Connect(callback)
end

function DataServicePlus.arrayInserted(path: Path, callback: (index: number, value: any) -> ()): Connection<number, any>?
	path = getPath(path)
	local signal = getSignal(getHash(path), arrayInserted)
	return signal:Connect(callback)
end

function DataServicePlus.arrayRemoved(path: Path, callback: (index: number, value: any) -> ()): Connection<number, any>?
	path = getPath(path)
	local hash = getHash(path)
	local signal = getSignal(hash, arrayRemoved)
	return signal:Connect(callback)
end

local actions = {
	[CHANGED] = function(path: {string}, hash: string, value: any)
		local layer, key, current = resolvePath(path, playerData)
		layer[key] = value
		local signal = changed[hash]
		if signal then signal:Fire(value, current) end
	end,
	
	[DATA_REQUEST] = function(path: nil, hash: nil, value: Data)
		playerData = value
		dataReadySignal:Fire()
	end,
	
	[DICT_INSERTED] = function(path: {string}, hash: string, key: string, value: any)
		local dict = readPath(path, playerData)
		dict[key] = value
		local signal = dictInserted[hash]
		if signal then signal:Fire(key, value) end
	end,
	
	[DICT_REMOVED] = function(path: {string}, hash: string, key: string, value: any)
		local dict = readPath(path, playerData)
		dict[key] = nil
		local signal = dictRemoved[hash]
		if signal then signal:Fire(key, value) end
	end,
	
	[ARRAY_INSERTED] = function(path: {string}, hash: string, index: number, value: any)
		local array = readPath(path, playerData)
		table.insert(array, index, value)
		local signal = arrayInserted[hash]
		if signal then signal:Fire(index, value) end
	end,
	
	[ARRAY_REMOVED] = function(path: {string}, hash: string, index: number, value: any)
		local array = readPath(path, playerData)
		table.remove(array, index)
		local signal = arrayRemoved[hash]
		if signal then signal:Fire(index, value) end
	end,
}

Networker.onEvent = function(actionId: number, path: {string}, hash: string, value1: any, value2: any)	
	local action = actions[actionId]
	if not action then return end
	if not playerData and actionId ~= DATA_REQUEST then return end
	(action :: any)(path, hash, value1, value2)
end

dataRequest:FireServer()
dataReadySignal:Wait()
print(`{SOURCE} {VERSION} initialized on Client!`)

export type DataServicePlus = typeof(DataServicePlus)

return DataServicePlus