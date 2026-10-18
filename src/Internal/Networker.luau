--!optimize 2
--!strict

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Enums = require(script.Parent.NetworkEnums)
local InternalConfig = require(script.Parent.InternalConfig)
local Types = require(script.Parent.Types)

type Data = Types.Data

const SOURCE = InternalConfig.source
const IS_SERVER = RunService:IsServer()
const STATIC_ALLOC_SIZE = 1000
const HASH_SEPARATOR = InternalConfig.hashSeparator
const ENUM_NUM = Enums.types.number
const ENUM_STR = Enums.types.string
const ENUM_BOOL = Enums.types.boolean
const ENUM_ARRAY = Enums.types.array
const ENUM_DICT = Enums.types.dict
const ENUM_NIL = Enums.types["nil"]
const DATA_REQUEST = Enums.encoding.dataRequest
const GENERIC = Enums.encoding.generic
const CHANGED = Enums.encoding.changed
const DICT = Enums.encoding.dict
const ARRAY = Enums.encoding.array

@native local function ensureBufferSize(buff: buffer, total: number): buffer
	local len = buffer.len(buff)
	if total <= len then
		return buff
	end
	local newLen = len
	while total > newLen do
		newLen = newLen * 2
	end
	local newBuff = buffer.create(newLen)
	buffer.copy(newBuff, 0, buff, 0, len)
	return newBuff
end

@native local function determineIsArray(value: {[any]: any}): boolean
	local count = 1
	for i, _ in value do
		if i ~= count then
			return false
		end
		count += 1
	end
	return true
end

@native local function encode(buff: buffer, offset: number, value: any, isArray: boolean?): (number, buffer)
	local dt = type(value)
	local bytes = 0
	if dt == "number" then
		buff = ensureBufferSize(buff, offset + 9)
		buffer.writeu8(buff, offset, ENUM_NUM)
		buffer.writef64(buff, offset + 1, value)
		bytes = 9
		
	elseif dt == "string" then
		local len = string.len(value)
		bytes = len + 3
		buff = ensureBufferSize(buff, offset + bytes)
		buffer.writeu8(buff, offset, ENUM_STR)
		buffer.writeu16(buff, offset + 1, len)
		buffer.writestring(buff, offset + 3, value, len)
		
	elseif dt == "boolean" then
		buff = ensureBufferSize(buff, offset + 2)
		buffer.writeu8(buff, offset, ENUM_BOOL)
		buffer.writeu8(buff, offset + 1, if value then 1 else 0)
		bytes = 2
	
	elseif dt == "nil" then
		buff = ensureBufferSize(buff, offset + 1)
		buffer.writeu8(buff, offset, ENUM_NIL)
		bytes = 1
	
	else --table
		local ptr = offset
		if isArray == nil then
			isArray = determineIsArray(value)
		end
		if isArray then
			buff = ensureBufferSize(buff, ptr + 3)
			buffer.writeu8(buff, ptr, ENUM_ARRAY)
			buffer.writeu16(buff, ptr + 1, #value)
			ptr += 3
			for _, val in value do
				local b, newBuff = encode(buff, ptr, val)
				ptr += b
				buff = newBuff
			end
			return ptr - offset, buff
		else
			buff = ensureBufferSize(buff, ptr + 3)
			buffer.writeu8(buff, ptr, ENUM_DICT)
			ptr += 3
			local count = 0
			for k, v in value do
				local kb, keyBuff = encode(buff, ptr, k)
				ptr += kb
				buff = keyBuff
				local vb, valBuff = encode(buff, ptr, v)
				ptr += vb
				buff = valBuff
				count += 1
			end
			buffer.writeu16(buff, offset + 1, count)
			return ptr - offset, buff
		end
	end
	return bytes, buff
end

@native local function decode(buff: buffer, offset: number): (any, number)
	local dt = buffer.readu8(buff, offset)
	local ptr = offset + 1

	if dt == ENUM_NUM then
		return buffer.readf64(buff, ptr), 9

	elseif dt == ENUM_STR then
		local len = buffer.readu16(buff, ptr)
		return buffer.readstring(buff, ptr + 2, len), len + 3

	elseif dt == ENUM_BOOL then
		return buffer.readu8(buff, ptr) == 1, 2
		
	elseif dt == ENUM_NIL then
		return nil, 1

	elseif dt == ENUM_DICT then
		local len = buffer.readu16(buff, ptr)
		ptr += 2
		local dict = {}
		
		for i = 1, len do
			local key, kb = decode(buff, ptr)
			ptr += kb
			local value, vb = decode(buff, ptr)
			ptr += vb
			dict[key] = value
		end
		return dict, ptr - offset
	
	else --ENUM_ARRAY
		local len = buffer.readu16(buff, ptr)
		ptr += 2
		local array = table.create(len)
		for i = 1, len do
			local value, b = decode(buff, ptr)
			array[i] = value
			ptr += b
		end
		return array, ptr - offset
	end
end

type Queue = {
	byteSize: number,
	queueSize: number,
	staticBuffer: buffer,
}

local function getRemote(name: string): RemoteEvent
	local remote
	if IS_SERVER then
		remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = script
	else
		remote = script:WaitForChild(name)
	end
	return remote :: RemoteEvent
end

local Networker = {
	queues = {} :: {[Player]: Queue}, 	
	remote = getRemote("NetworkerRemote"),
	onEvent = function() end,
}

@native local function fastUnpack(args: {any}, argCount: number): ...any
	if argCount == 3 then
		return args[1], args[2], args[3]
	elseif argCount == 2 then
		return args[1], args[2]
	else
		return table.unpack(args, 1, argCount)
	end
end

@native local function decodeHeader(buff: buffer, ptr: number): (number, number, string)
	local actionId = buffer.readu8(buff, ptr)
	local len = buffer.readu16(buff, ptr + 1)
	local hash = buffer.readstring(buff, ptr + 3, len)
	ptr += len + 3
	return ptr, actionId, hash
end

local decoders = {
	[DATA_REQUEST] = @native function(buff: buffer, offset: number): (number, ...any)
		local ptr = offset
		local actionId = buffer.readu8(buff, ptr)
		ptr += 1
		local value, b = decode(buff, ptr)
		ptr += b
		return ptr - offset, actionId, nil, nil, value
	end,
	
	[GENERIC] = @native function(buff: buffer, offset: number): (number, ...any)
		local ptr = offset
		local argCount = buffer.readu8(buff, ptr)
		ptr += 1
		local args = table.create(argCount)
		for i = 1, argCount do
			local value, b = decode(buff, ptr)
			args[i] = value
			ptr += b
		end
		return ptr - offset, fastUnpack(args, argCount)
	end,
	
	[CHANGED] = @native function(buff: buffer, offset: number): (number, number, {string}, string, any)
		local ptr, actionId, hash = decodeHeader(buff, offset)
		local value, b = decode(buff, ptr)
		ptr += b
		return ptr - offset, actionId, string.split(hash, HASH_SEPARATOR), hash, value
	end,
	
	[DICT] = @native function(buff: buffer, offset: number): (number, number, {string}, string, string, any)
		local ptr, actionId, hash = decodeHeader(buff, offset)
		local keyLen = buffer.readu8(buff, ptr)
		local key = buffer.readstring(buff, ptr + 1, keyLen)
		ptr += keyLen + 1
		local value, b = decode(buff, ptr)
		ptr += b
		return ptr - offset, actionId, string.split(hash, HASH_SEPARATOR), hash, key, value
	end,
	
	[ARRAY] = @native function(buff: buffer, offset: number): (number, number, {string}, string, number, any)
		local ptr, actionId, hash = decodeHeader(buff, offset)
		local index = buffer.readu16(buff, ptr)
		ptr += 2
		local value, b = decode(buff, ptr)
		ptr += b
		return ptr - offset, actionId, string.split(hash, HASH_SEPARATOR), hash, index, value
	end,
}

@native local function processIncoming(buff: buffer)
	local onEvent = Networker.onEvent
	local numCalls = buffer.readu16(buff, 0)
	local ptr = 2
	
	for i = 1, numCalls do
		local encodingId = buffer.readu8(buff, ptr)
		local decodePacket = decoders[encodingId]
		ptr += 1
		local b, arg1, arg2, arg3, arg4, arg5 = decodePacket(buff, ptr)
		ptr += b
		onEvent(arg1, arg2, arg3, arg4, arg5)
	end
end

@native function Networker.fireDataRequest(self: Networker, player: Player, actionId: number, data: Data)
	local queue = self.queues[player]
	if not queue then return end
	local ptr = queue.byteSize
	local buff = queue.staticBuffer
	buff = ensureBufferSize(buff, ptr + 2)
	buffer.writeu8(buff, ptr, DATA_REQUEST)
	buffer.writeu8(buff, ptr + 1, actionId)
	ptr += 2
	local b, newBuff = encode(buff, ptr, data, false)
	ptr += b
	queue.staticBuffer = newBuff
	queue.byteSize = ptr
	queue.queueSize += 1
end

@native local function encodeHeader(buff: buffer, ptr: number, encodingId: number, actionId: number, hash: string)
	: (number, buffer)
	local hashLen = string.len(hash)
	buff = ensureBufferSize(buff, ptr + 4 + hashLen)
	buffer.writeu8(buff, ptr, encodingId)
	buffer.writeu8(buff, ptr + 1, actionId)
	buffer.writeu16(buff, ptr + 2, hashLen)
	buffer.writestring(buff, ptr + 4, hash, hashLen)
	ptr += 4 + hashLen
	return ptr, buff
end

@native function Networker.fireChanged(self: Networker, player: Player, actionId: number, hash: string, value: any)
	local queue = self.queues[player]
	if not queue then return end
	local ptr = queue.byteSize
	local buff = queue.staticBuffer
	ptr, buff = encodeHeader(buff, ptr, CHANGED, actionId, hash)
	local b, newBuff = encode(buff, ptr, value)
	ptr += b
	queue.staticBuffer = newBuff
	queue.byteSize = ptr
	queue.queueSize += 1
end

@native function Networker.fireDict(self: Networker, player: Player, actionId: number, hash: string, key: string, value: any)
	local queue = self.queues[player]
	if not queue then return end
	local ptr = queue.byteSize
	local buff = queue.staticBuffer
	ptr, buff = encodeHeader(buff, ptr, DICT, actionId, hash)
	local keyLen = string.len(key)
	buff = ensureBufferSize(buff, ptr + keyLen + 1)
	if keyLen > 255 then
		error(`{SOURCE} Dictionary keys cannot be longer than 255 characters`)
	end
	buffer.writeu8(buff, ptr, keyLen)
	buffer.writestring(buff, ptr + 1, key, keyLen)
	ptr += keyLen + 1
	local b, newBuff = encode(buff, ptr, value, false)
	ptr += b	
	queue.staticBuffer = newBuff
	queue.byteSize = ptr
	queue.queueSize += 1	
end

@native function Networker.fireArray(self: Networker, player: Player, actionId: number, hash: string, index: number, value: any)
	local queue = self.queues[player]
	if not queue then return end
	local ptr = queue.byteSize
	local buff = queue.staticBuffer
	ptr, buff = encodeHeader(buff, ptr, ARRAY, actionId, hash)	
	buff = ensureBufferSize(buff, ptr + 2)
	buffer.writeu16(buff, ptr, index)
	ptr += 2
	local b, newBuff = encode(buff, ptr, value, true)
	ptr += b	
	queue.staticBuffer = newBuff
	queue.byteSize = ptr
	queue.queueSize += 1	
end

@native function Networker.fire<T...>(self: Networker, player: Player, ...: T...)
	local queue = self.queues[player]
	if not queue then return end 
	local ptr = queue.byteSize
	local buff = queue.staticBuffer
	local args = {...}
	local argCount = #args
	buff = ensureBufferSize(buff, ptr + 2)
	buffer.writeu8(buff, ptr, GENERIC)
	buffer.writeu8(buff, ptr + 1, argCount)
	ptr += 2
	
	for _, arg in args do
		local b, newBuff = encode(buff, ptr, arg)
		ptr += b
		buff = newBuff
	end
	queue.staticBuffer = buff
	queue.byteSize = ptr
	queue.queueSize += 1
end

local function init(self: Networker)
	if IS_SERVER then
		local function playerAdded(player: Player)
			self.queues[player] = {
				byteSize = 0,
				queueSize = 0,
				staticBuffer = buffer.create(STATIC_ALLOC_SIZE),
			}
		end
		
		for _, player in Players:GetPlayers() do
			task.spawn(playerAdded, player)
		end
		Players.PlayerAdded:Connect(playerAdded)

		Players.PlayerRemoving:Connect(function(player)
			self.queues[player] = nil
		end)
		
		RunService.PostSimulation:Connect(@native function()
			local remote = self.remote
			for player, queue in self.queues do
				local size = queue.byteSize
				if size < 1 then continue end
				local finalBuff = buffer.create(size + 2)
				buffer.writeu16(finalBuff, 0, queue.queueSize)
				buffer.copy(finalBuff, 2, queue.staticBuffer, 0, size)
				remote:FireClient(player, finalBuff)
				queue.byteSize = 0
				queue.queueSize = 0
			end
		end)
	else
		self.remote.OnClientEvent:Connect(processIncoming)
	end
end

init(Networker)

export type Networker = typeof(Networker)

return Networker
