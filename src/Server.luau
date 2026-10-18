--!optimize 2
--!strict

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Internal = script.Parent.Internal
local ProfileStore = require(Internal.ProfileStore)
local Config = require(script.Parent.Config)
local InternalConfig = require(Internal.InternalConfig)
local Shared = require(Internal.Shared)
local Types = require(Internal.Types)
local Enums = require(Internal.Enums)
local Signal = require(Internal.UsefulSignal)
local Networker = require(Internal.Networker)

const SOURCE = InternalConfig.source
const VERSION = InternalConfig.version
const IS_STUDIO = RunService:IsStudio()
const PROFILE_KEY_PREFIX = "Player_"
const HASH_SEPARATOR = InternalConfig.hashSeparator
const CHANGED = Enums.changed
const ARRAY_INSERTED = Enums.arrayInserted
const ARRAY_REMOVED = Enums.arrayRemoved
const DICT_INSERTED = Enums.dictInserted
const DICT_REMOVED = Enums.dictRemoved
const DATA_REQUEST = Enums.dataRequest
const template = Config.template
const useMock = Config.useMock

export type Signal<T...> = Types.Signal<T...>
export type Data = Types.Data
export type Connection<T...> = Types.Connection<T...>
type Path = Types.Path
type Profile = ProfileStore.Profile<Data>
type Message = {key: string, data: {[any]: any}}
type GlobalCallback = (player: Player, data: {[any]: any}) -> boolean?

local store = ProfileStore.New(Config.storeName, template :: any)
local playerInitCallbacks = {} :: {[(player: Player, data: Data) -> ()]: boolean}
local playerRemovingCallbacks = {} :: {[(player: Player, data: Data) -> ()]: boolean}
local globalCallbacks = {} :: {[string]: GlobalCallback}
local globalCallbackAdded = Signal.new()
local profiles = {} :: {[Player]: Profile}
local playerData = {} :: {[Player]: Data}
local changed = {} :: {[Player]: {[string]: Signal<any, any>}}
local arrayInserted = {} :: {[Player]: {[string]: Signal<number, any>}}
local arrayRemoved = {} :: {[Player]: {[string]: Signal<number, any>}}
local dictInserted = {} :: {[Player]: {[string]: Signal<string, any>}}
local dictRemoved = {} :: {[Player]: {[string]: Signal<string, any>}}
local waitThreads = {} :: {[Player]: {thread}}
local dataRequestProcessed = {} :: {[Player]: boolean}
local dataRequest = Instance.new("RemoteEvent")
dataRequest.Name = "DataRequest"
dataRequest.Parent = script.Parent

local function getProfileKey(userId: number): string
	return PROFILE_KEY_PREFIX..userId
end

local function resumeWaits(player: Player, data: Data?)
	local waits = waitThreads[player]
	if not waits then return end 
	for _, thread in waits do
		if coroutine.status(thread) ~= "suspended" then continue end 
		task.spawn(thread, data)
	end
	table.clear(waits)
end

local function cleanupSignals<T...>(player: Player, playerSignals: {[Player]: {[string]: Signal<T...>}})
	local signals = playerSignals[player]
	if not signals then return end
	for _, signal in signals do
		signal:DisconnectAll()
	end
	playerSignals[player] = nil
end

local function cleanup(player: Player)
	playerData[player] = nil
	cleanupSignals(player, changed)
	cleanupSignals(player, arrayInserted)
	cleanupSignals(player, arrayRemoved)
	cleanupSignals(player, dictInserted)
	cleanupSignals(player, dictRemoved)
	resumeWaits(player, nil)
	waitThreads[player] = nil
	dataRequestProcessed[player] = nil
end

local function playerAdded(player: Player)	
	local userId = player.UserId
	local profile
	if useMock then
		profile = store.Mock:StartSessionAsync(getProfileKey(userId), {
			Cancel = function()
				return player.Parent ~= Players
			end,
		})
	else
		profile = store:StartSessionAsync(getProfileKey(userId), {
			Cancel = function()
				return player.Parent ~= Players
			end,
		})
	end

	if profile == nil then
		player:Kick(`Failed to load data, please rejoin`)
		return
	end
	
	profile:AddUserId(userId)
	profile:Reconcile()
	profile.OnSessionEnd:Connect(function()
		player:Kick(`Data session ended, please rejoin`)
	end)
	
	if not player or player.Parent ~= Players then
		profile:EndSession()
		return
	end
	profiles[player] = profile
	local data = profile.Data
	playerData[player] = data
	print(`{SOURCE} Data loaded for {player.Name}!`)
	for callback, _ in playerInitCallbacks do
		local success, err = pcall(callback, player, data :: Data)
		if not success then
			warn(`{SOURCE} {err}`)
		end
	end
	resumeWaits(player, data)
	
	profile:MessageHandler(function(message: any, processed: () -> ())
		local msgKey = message.key
		local msgData = message.data
		local callback = globalCallbacks[msgKey]
		
		if callback then
			if callback(player, msgData) ~= false then
				processed()
			end
			return
		end

		local waitConnection: Connection<string, GlobalCallback>
		waitConnection = globalCallbackAdded:Connect(function(key: string, addedCallback: GlobalCallback)
			if key ~= msgKey then
				return
			end

			if addedCallback(player, msgData) ~= false then
				processed()
			end
			waitConnection:Disconnect()
		end)
	end)
end

local function playerRemoving(player: Player)
	local data = playerData[player]
	for callback, _ in playerRemovingCallbacks do
		local success, err = pcall(callback, player, data)
		if not success then
			warn(`{SOURCE} {err}`)
		end
	end
	
	local profile = profiles[player]
	if profile then
		profiles[player] = nil
		profile:EndSession()
	end
	cleanup(player)
end

local function waitForData(self: DataServicePlus, player: Player): Data?
	local data = playerData[player]
	if data then return data end 

	local waits = waitThreads[player]
	if not waits then
		waits = {}
		waitThreads[player] = waits
	end
	table.insert(waits, coroutine.running())
	return coroutine.yield()
end

local function readPath(path: any, data: Data): any
	local current = data
	for _, key in ipairs(path) do
		current = (current :: any)[key]		
	end
	return current
end

local function resolvePath(path: any, data: Data): ({[any]: any}, string, any)
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

local function init()
	for _, player in Players:GetPlayers() do
		task.spawn(playerAdded, player)
	end	
	Players.PlayerAdded:Connect(playerAdded)
	Players.PlayerRemoving:Connect(playerRemoving)

	dataRequest.OnServerEvent:Connect(function(player)
		if dataRequestProcessed[player] then return end
		dataRequestProcessed[player] = true
		local data = waitForData(nil :: any, player)
		if data == nil then return end
		Networker:fireDataRequest(player, DATA_REQUEST, data)
	end)
	print(`{SOURCE} {VERSION} initialized on Server!`)
end

local DataServicePlus = {}
DataServicePlus.T = Shared.createTemplatePaths({___hash = ""}, template :: any) :: Data
DataServicePlus.waitForData = waitForData

function DataServicePlus.playerInit(callback: (player: Player, data: Data) -> ()): () -> ()
	playerInitCallbacks[callback] = true
	return function()
		playerInitCallbacks[callback] = nil
	end
end

function DataServicePlus.playerRemoving(callback: (player: Player, data: Data) -> ()): () -> ()
	playerRemovingCallbacks[callback] = true
	return function()
		playerRemovingCallbacks[callback] = nil
	end
end

function DataServicePlus.sendGlobalMessage(self: DataServicePlus, key: string, userId: number, data: {[any]: any}): boolean
	return store:MessageAsync(getProfileKey(userId), {key = key, data = data})
end

function DataServicePlus.addGlobalCallback(self: DataServicePlus, key: string, callback: (player: Player, {[any]: any}) -> boolean?)
	if globalCallbacks[key] ~= nil then
		error(`{SOURCE} Callback already exists for key {key}`)
	end
	globalCallbacks[key] = callback 
	globalCallbackAdded:Fire(key, callback)
end

function DataServicePlus.asyncGetProfile(self: DataServicePlus, userId): Profile?
	return store:GetAsync(getProfileKey(userId))
end

function DataServicePlus.getProfile(self: DataServicePlus, player: Player): Profile?
	return profiles[player]
end

function DataServicePlus.resetData(self: DataServicePlus, player: Player)
	playerRemoving(player)
	store:RemoveAsync(getProfileKey(player.UserId))
	player:Kick(`Your data has been reset, please rejoin`)
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

local function validate(player: Player, data: Data): boolean
	if not data and IS_STUDIO then
		warn(`{SOURCE} Cannot write data for {player.Name}: player not in game`)
		return false
	end
	return true
end

local function getAndFireSignal<T...>(player: Player, category: {[Player]: {[string]: Signal<T...>}}, hash: string, ...: T...)
	local signals = category[player]
	local signal = signals and signals[hash]
	if signal then signal:Fire(...) end
end

function DataServicePlus.set(self: DataServicePlus, player: Player, path: Path, value: any, doNotReplicate: boolean?)
	path = getPath(path)
	local data = playerData[player]
	local hash = getHash(path)
	if not validate(player, data) then return end
	local layer, key, currValue = resolvePath(path, data)
	layer[key] = value
	getAndFireSignal(player, changed, hash, value, currValue)
	if doNotReplicate ~= true then
		Networker:fireChanged(player, CHANGED, hash, value)
	end
end

function DataServicePlus.get(self: DataServicePlus, player: Player, path: Path): any
	path = getPath(path)
	local data = playerData[player]
	if not data then return end 
	return readPath(path, data)
end

function DataServicePlus.increment(self: DataServicePlus, player: Player, path: Path, amount: number, doNotReplicate: boolean?)
	path = getPath(path)
	local data = playerData[player]
	local hash = getHash(path)
	if not validate(player, data) then return end
	local layer, key, currValue = resolvePath(path, data)
	local newValue = currValue + amount
	layer[key] = newValue
	getAndFireSignal(player, changed, hash, newValue, currValue)
	if doNotReplicate ~= true then
		Networker:fireChanged(player, CHANGED, hash, newValue)
	end
end

function DataServicePlus.update(self: DataServicePlus, player: Player, path: Path, callback: (any) -> any, doNotReplicate: boolean?)
	path = getPath(path)
	local data = playerData[player]
	local hash = getHash(path)
	if not validate(player, data) then return end
	local layer, key, currValue = resolvePath(path, data)
	local value = callback(currValue)
	layer[key] = value
	getAndFireSignal(player, changed, hash, value, currValue)
	if doNotReplicate ~= true then
		Networker:fireChanged(player, CHANGED, hash, value)
	end
end

function DataServicePlus.dictInsert(self: DataServicePlus, player: Player, path: Path, key: string, value: any, doNotReplicate: boolean?)
	path = getPath(path)
	local data = playerData[player]
	local hash = getHash(path)
	if not validate(player, data) then return end
	local dict = readPath(path, data)
	if dict[key] ~= nil then return end
	dict[key] = value
	getAndFireSignal(player, dictInserted, hash, key, value)
	if doNotReplicate ~= true then
		Networker:fireDict(player, DICT_INSERTED, hash, key, value)
	end
end

function DataServicePlus.dictRemove(self: DataServicePlus, player: Player, path: Path, key: string, doNotReplicate: boolean?)
	path = getPath(path)
	local data = playerData[player]
	local hash = getHash(path)
	if not validate(player, data) then return end
	local dict = readPath(path, data)
	local value = dict[key]
	if value == nil then
		return
	end
	dict[key] = nil
	getAndFireSignal(player, dictRemoved, hash, key, value)
	if doNotReplicate ~= true then
		Networker:fireDict(player, DICT_REMOVED, hash, key, value)
	end
end

function DataServicePlus.arrayInsert(self: DataServicePlus, player: Player, path: Path, index: number?, value: any, doNotReplicate: boolean?)
	path = getPath(path)
	local data = playerData[player]
	local hash = getHash(path)
	if not validate(player, data) then return end
	local array = readPath(path, data)
	if index ~= nil then
		table.insert(array, index, value)
	else
		index = #array + 1
		array[index] = value
	end
	getAndFireSignal(player, arrayInserted, hash, index :: number, value)
	if doNotReplicate ~= true then
		Networker:fireArray(player, ARRAY_INSERTED, hash, index :: number, value)
	end
end

function DataServicePlus.arrayRemove(self: DataServicePlus, player: Player, path: Path, index: number?, doNotReplicate: boolean?)
	path = getPath(path)
	local data = playerData[player]
	local hash = getHash(path)
	if not validate(player, data) then return end
	local array = readPath(path, data)
	local len = #array
	if len < 1 then return end 
	index = index or len
	local value = table.remove(array, index)
	getAndFireSignal(player, arrayRemoved, hash, index, value)
	if doNotReplicate ~= true then
		Networker:fireArray(player, ARRAY_REMOVED, hash, index, value)
	end
end

local function getSignal<T...>(player: Player, hash: string, playerSignals: {[Player]: {[string]: Signal<T...>}}): Signal<T...>
	local signals = playerSignals[player]
	if not signals then
		signals = {}
		playerSignals[player] = signals
	end
	local signal = signals[hash]
	if not signal then
		signal = Signal.new()
		signals[hash] = signal
	end
	return signal
end

function DataServicePlus.changed(player: Player, path: Path, callback: (newValue: any, oldValue: any) -> (), prefire: boolean?): Connection<any, any>?
	path = getPath(path)
	local hash = getHash(path)
	if prefire ~= false then
		local data = playerData[player]
		if data then
			local value = readPath(path, data)
			task.spawn(callback, value, value)
		end
	end
	
	local signal = getSignal(player, hash, changed)
	return signal:Connect(callback)
end

function DataServicePlus.dictInserted(player: Player, path: Path, callback: (key: string, value: any) -> ()): Connection<string, any>?
	path = getPath(path)
	local signal = getSignal(player, getHash(path), dictInserted)
	return signal:Connect(callback)
end

function DataServicePlus.dictRemoved(player: Player, path: Path, callback: (key: string, value: any) -> ()): Connection<string, any>?
	path = getPath(path)
	local signal = getSignal(player, getHash(path), dictRemoved)
	return signal:Connect(callback)
end

function DataServicePlus.arrayInserted(player: Player, path: Path, callback: (index: number, value: any) -> ()) :Connection<number, any>?
	path = getPath(path)
	local signal = getSignal(player, getHash(path), arrayInserted)
	return signal:Connect(callback)
end

function DataServicePlus.arrayRemoved(player: Player, path: Path, callback: (index: number, value: any) -> ()): Connection<number, any>?
	path = getPath(path)
	local signal = getSignal(player, getHash(path), arrayRemoved)
	return signal:Connect(callback)
end

init()

export type DataServicePlus = typeof(DataServicePlus)

return DataServicePlus
