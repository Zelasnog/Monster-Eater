local ReplicatedStorage = game:GetService("ReplicatedStorage")

local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local configFolder = sharedFolder:WaitForChild("Config")
local GameConfig = require(configFolder:WaitForChild("GameConfig"))

print(string.format("[ClientInit] Cliente inicializado | %s v%s", GameConfig.Name, GameConfig.Version))

local controllersFolder = script.Parent:WaitForChild("Controllers")
local MovementController = require(controllersFolder:WaitForChild("MovementController"))
MovementController.Init()
local ShiftLockController = require(controllersFolder:WaitForChild("ShiftLockController"))
ShiftLockController.Init()
local CombatController = require(controllersFolder:WaitForChild("CombatController"))
CombatController.Init()

