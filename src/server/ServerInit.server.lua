local ReplicatedStorage = game:GetService("ReplicatedStorage")

local function startServer()
	local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
	local configFolder = sharedFolder:WaitForChild("Config")
	local GameConfig = require(configFolder:WaitForChild("GameConfig"))

	local servicesFolder = script.Parent:WaitForChild("Services")
	local PlayerService = require(servicesFolder:WaitForChild("PlayerService"))
	local PlayerDataService = require(servicesFolder:WaitForChild("PlayerDataService"))
	local ProgressionService = require(servicesFolder:WaitForChild("ProgressionService"))
	local MovementService = require(servicesFolder:WaitForChild("MovementService"))
	local CombatService = require(servicesFolder:WaitForChild("CombatService"))

	print("================================")
	print(string.format("   %s", GameConfig.Name))
	print(string.format("   Versión %s", GameConfig.Version))
	print("   Sistema de servidor activo")
	print("================================")

	local startupSteps = {
		{ Name = "PlayerService", Init = PlayerService.Init },
		{ Name = "PlayerDataService", Init = PlayerDataService.Init },
		{ Name = "ProgressionService", Init = ProgressionService.Init },
		{ Name = "MovementService", Init = MovementService.Init },
		{ Name = "CombatService", Init = CombatService.Init },
	}

	for _, step in ipairs(startupSteps) do
		local initOk, initErr = pcall(step.Init)
		if not initOk then
			error(string.format("%s: %s", step.Name, tostring(initErr)))
		end
	end
end

local ok, err = pcall(startServer)

if not ok then
	warn(string.format("[ServerInit] Error al inicializar el servidor: %s", tostring(err)))
end
