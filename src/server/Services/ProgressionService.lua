local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("GameConfig"))
local PlayerDataService = require(script.Parent:WaitForChild("PlayerDataService"))

local AUTHORITATIVE_BRIDGE_NAME = "MonsterEaterProgressionAuthoritative"

export type ProgressionResult = {
	ExperienceGranted: number,
	LevelsGained: number,
	Level: number,
	Experience: number,
}

local ProgressionService = {}

local MAX_SAFE_INTEGER = 9007199254740991
local initialized = false

local FORMULA_CHECKS = {
	{ Level = 1, Required = 100 },
	{ Level = 2, Required = 130 },
	{ Level = 3, Required = 170 },
	{ Level = 4, Required = 220 },
	{ Level = 5, Required = 280 },
	{ Level = 10, Required = 730 },
}

local function isSafeInteger(value: any): boolean
	if typeof(value) ~= "number" then
		return false
	end

	if value ~= value or value >= math.huge or value <= -math.huge then
		return false
	end

	if value > MAX_SAFE_INTEGER or value < -MAX_SAFE_INTEGER then
		return false
	end

	return math.floor(value) == value
end

local function isConnectedPlayer(player: any): boolean
	return typeof(player) == "Instance"
		and player:IsA("Player")
		and player.Parent == Players
		and Players:GetPlayerByUserId(player.UserId) == player
end

local function getAuthoritativeBridge(): BindableFunction?
	local bridge = ServerStorage:FindFirstChild(AUTHORITATIVE_BRIDGE_NAME)
	if bridge and bridge:IsA("BindableFunction") then
		return bridge
	end

	return nil
end

function ProgressionService.GetRequiredExperience(level: number): number?
	if not isSafeInteger(level) or level < 1 then
		warn(string.format("[ProgressionService] Nivel inválido. Recibido: %s", tostring(level)))
		return nil
	end

	local required = GameConfig.GetRequiredExperience(level)
	if not isSafeInteger(required) or required < 1 then
		warn(string.format(
			"[ProgressionService] La XP requerida del nivel %d no es un entero positivo. Resultado: %s",
			level,
			tostring(required)
		))
		return nil
	end

	return required
end

function ProgressionService.AddExperience(player: Player, amount: number): ProgressionResult?
	if not RunService:IsServer() then
		warn("[ProgressionService] AddExperience solo puede ejecutarse en el servidor.")
		return nil
	end

	-- La Barra de comandos ejecuta otro require y no ve el estado de ServerInit.
	if not initialized then
		local bridge = getAuthoritativeBridge()
		if bridge then
			return bridge:Invoke(player, amount)
		end

		warn("[ProgressionService] AddExperience llamado antes de Init.")
		return nil
	end

	if not isConnectedPlayer(player) then
		warn("[ProgressionService] XP rechazada: el jugador no está conectado.")
		return nil
	end

	local profile = PlayerDataService.GetProfile(player)
	if not profile then
		warn(string.format(
			"[ProgressionService] XP rechazada: %s (%d) no tiene perfil.",
			player.Name,
			player.UserId
		))
		return nil
	end

	if not isSafeInteger(amount) or amount < 1 then
		warn(string.format(
			"[ProgressionService] XP rechazada para %s (%d): la cantidad debe ser un entero positivo. Recibido: %s",
			player.Name,
			player.UserId,
			tostring(amount)
		))
		return nil
	end

	local level = profile.Level
	local experience = profile.Experience
	local previousLevel = level

	if not isSafeInteger(level) or level < 1 or not isSafeInteger(experience) or experience < 0 then
		warn(string.format(
			"[ProgressionService] XP rechazada: perfil inconsistente de %s (%d).",
			player.Name,
			player.UserId
		))
		return nil
	end

	if experience > MAX_SAFE_INTEGER - amount then
		warn(string.format(
			"[ProgressionService] XP rechazada para %s (%d): la suma supera el entero exacto máximo.",
			player.Name,
			player.UserId
		))
		return nil
	end

	experience += amount
	local levelsGained = 0
	local requiredNow: number? = nil

	while true do
		local required = ProgressionService.GetRequiredExperience(level)
		if not required then
			warn(string.format(
				"[ProgressionService] XP no aplicada a %s (%d): no se pudo calcular la XP del nivel %d.",
				player.Name,
				player.UserId,
				level
			))
			return nil
		end

		if experience < required then
			requiredNow = required
			break
		end

		local nextExperience = experience - required
		local nextLevel = level + 1
		if nextExperience >= experience or not isSafeInteger(nextExperience) or not isSafeInteger(nextLevel) or nextLevel < 1 then
			warn(string.format(
				"[ProgressionService] XP no aplicada a %s (%d): la subida de nivel dejó de ser exacta.",
				player.Name,
				player.UserId
			))
			return nil
		end

		experience = nextExperience
		level = nextLevel
		levelsGained += 1
	end

	if not isConnectedPlayer(player) then
		warn("[ProgressionService] XP no aplicada: el jugador se desconectó antes de guardar.")
		return nil
	end

	local applied = PlayerDataService.UpdateProgress(player, level, experience)
	if not applied then
		warn(string.format(
			"[ProgressionService] XP no aplicada a %s (%d). El perfil no cambió.",
			player.Name,
			player.UserId
		))
		return nil
	end

	print(string.format(
		"[ProgressionService] XP concedida: %s (%d) | +%d",
		player.Name,
		player.UserId,
		amount
	))

	if levelsGained > 0 then
		print(string.format(
			"[ProgressionService] Subió de nivel: %s (%d) | %d -> %d | Niveles ganados: %d",
			player.Name,
			player.UserId,
			previousLevel,
			level,
			levelsGained
		))
	end

	print(string.format(
		"[ProgressionService] Experiencia restante: %s (%d) | Level %d | %d/%s",
		player.Name,
		player.UserId,
		level,
		experience,
		tostring(requiredNow)
	))

	return table.freeze({
		ExperienceGranted = amount,
		LevelsGained = levelsGained,
		Level = level,
		Experience = experience,
	})
end

function ProgressionService.Init()
	if initialized or getAuthoritativeBridge() then
		warn("[ProgressionService] Init ya estaba activo. No se volvió a inicializar.")
		return
	end

	for _, check in ipairs(FORMULA_CHECKS) do
		local required = ProgressionService.GetRequiredExperience(check.Level)
		if required ~= check.Required then
			error(string.format(
				"[ProgressionService] La fórmula de XP no coincide en el nivel %d. Esperado: %d. Obtenido: %s",
				check.Level,
				check.Required,
				tostring(required)
			))
		end
	end

	local bridge = Instance.new("BindableFunction")
	bridge.Name = AUTHORITATIVE_BRIDGE_NAME
	bridge.OnInvoke = function(player: Player, amount: number)
		return ProgressionService.AddExperience(player, amount)
	end

	initialized = true
	bridge.Parent = ServerStorage
	print("[ProgressionService] Inicializado.")
end

return ProgressionService
