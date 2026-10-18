--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Stats = game:GetService("Stats")

local LeifDataServiceTyped = require(script.Parent.LeifData).server
local DataServicePlus = require(ReplicatedStorage.Modules.Packages.DataServicePlus.Server)

local T = DataServicePlus.T

local player = Players:WaitForChild("u5eful")
local data = DataServicePlus:waitForData(player)
local leifDataTyped = LeifDataServiceTyped.Service:waitForData(player) :: typeof(LeifDataServiceTyped[player])

local tests = {
	DataServicePlus = {
		Write = function()
			DataServicePlus:set(player, T.Cash, 123)
		end,

		Read = function()
			DataServicePlus:get(player, T.Inventory.Bow.Cooldown)
		end,
	},

	LeifDataServiceTyped = {
		Write = function()
			leifDataTyped.Cash(123)
		end,

		Read = function()
			leifDataTyped.Inventory.Bow.Cooldown()
		end,
	},
}

local function test(name: string, testName: string, count: number, duration: number)
	local numFrames = 0
	local elapsed = 0
	local kbps = 0

	local testFn = tests[name][testName]

	local conn = RunService.Heartbeat:Connect(function(dt)
		for i = 1, count do
			testFn()
		end

		numFrames += 1
		elapsed += dt
		kbps += Stats.DataSendKbps
	end)
	task.wait(duration)
	conn:Disconnect()

	local avgFps = numFrames / elapsed
	local avgKbps = (60 / avgFps) * kbps / numFrames
	local text = string.format("\n[%s] [%s] \nAverage FPS: %.3f \nAverage Kbps: %.3f", name, testName, avgFps, avgKbps)
	print(text)
end

local dataModules = {"LeifDataServiceTyped", "DataServicePlus"}
local tests = {"Read", "Write"}

local function benchmark(count: number, duration: number)
	task.wait(2)
	for _, testName in tests do
		print(string.format("====[%s Test] [%d per frame]====", testName, count))
		for _, module in dataModules do
			task.wait(3)
			test(module, testName, count, duration)
		end
	end
end

task.wait(3)
--benchmark(10000, 10)




