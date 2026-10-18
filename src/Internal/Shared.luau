--!strict

local InternalConfig = require(script.Parent.InternalConfig)

const SOURCE = InternalConfig.source
const HASH_SEPARATOR = InternalConfig.hashSeparator

local function createPath(path: any, key: string): any
	if rawget(path, "___isDefault") ~= false then
		path = rawget(path, "___path") or path
		path = table.clone(path)
		path.___isDefault = false
	end
	table.insert(path, key)
	path.___hash = rawget(path, "___hash")..HASH_SEPARATOR..key
	return path
end

local pathMeta = {__index = createPath}

local function createTemplatePaths(path, temp)
	local original = table.clone(path)
	local new = setmetatable({___path = original}, getmetatable(path)) :: any

	for k, v in temp do
		if type(k) ~= "string" then
			error(`{SOURCE} Data can only use string keys`)
		end
		if k == "___path" then
			error(`{SOURCE} Data cannot use '___path' as a key`)
		end
		if string.find(k :: string, HASH_SEPARATOR) ~= nil then
			error(`{SOURCE} Data keys cannot contain {HASH_SEPARATOR}`)
		end
		local currPath = table.clone(original)
		table.insert(currPath, k);
		(currPath :: any).___hash = table.concat(currPath, HASH_SEPARATOR)

		if type(v) == "table" then
			new[k] = createTemplatePaths(currPath, v)
		else
			new[k] = currPath
		end
	end
	return new
end

local Shared = {}

function Shared.createTemplatePaths(path, temp)
	return createTemplatePaths(setmetatable(path, pathMeta) :: any, temp)
end

return Shared
