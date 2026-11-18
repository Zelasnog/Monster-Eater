local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("GameConfig"))

export type PlayerProfile = {
	Level: number,
	Experience: number,
	Currency: number,
}

local PlayerDataService = {}

local MAX_SAFE_INTEGER = 9007199254740991
local initialized = false
local profiles: { [Player]: PlayerProfile } = {}

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

local function createDefaultProfile(): PlayerProfile
	return {
		Level = 1,
		Experience = 0,
		Currency = 0,
	}
end

local function publishProfile(player: Player, profile: PlayerProfile)
	player:SetAttribute("Level", profile.Level)
	player:SetAttribute("Experience", profile.Experience)
	player:SetAttribute("Currency", profile.Currency)
end

local function onPlayerAdded(player: Player)
	if profiles[player] then
		return
	end

	local profile = createDefaultProfile()
	profiles[player] = profile
	publishProfile(player, profile)

	print(string.format(
		"[PlayerDataService] Perfil creado: %s (%d) | Level=%d Experience=%d Currency=%d",
		player.Name,
		player.UserId,
		profile.Level,
		profile.Experience,
		profile.Currency
	))
	print(string.format(
		"[PlayerDataService] Atributos asignados: %s (%d) | Level=%s Experience=%s Currency=%s",
		player.Name,
		player.UserId,
		tostring(player:GetAttribute("Level")),
		tostring(player:GetAttribute("Experience")),
		tostring(player:GetAttribute("Currency"))
	))
end

local function onPlayerRemoving(player: Player)
	if profiles[player] == nil then
		return
	end

	profiles[player] = nil
	print(string.format("[PlayerDataService] Perfil eliminado: %s (%d)", player.Name, player.UserId))
end

function PlayerDataService.Init()
	if initialized then
		warn("[PlayerDataService] Init ya estaba activo. No se volvieron a conectar los eventos.")
		return
	end

	initialized = true

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end

	print("[PlayerDataService] Inicializado.")
end

function PlayerDataService.GetProfile(player: Player): PlayerProfile?
	local profile = profiles[player]
	if not profile then
		return nil
	end

	return table.freeze({
		Level = profile.Level,
		Experience = profile.Experience,
		Currency = profile.Currency,
	})
end

function PlayerDataService.UpdateProgress(player: Player, level: number, experience: number): boolean
	if not isConnectedPlayer(player) then
		warn("[PlayerDataService] Progresión rechazada: el jugador no está conectado.")
		return false
	end

	local profile = profiles[player]
	if not profile then
		warn(string.format(
			"[PlayerDataService] Progresión rechazada: %s (%d) no tiene perfil.",
			player.Name,
			player.UserId
		))
		return false
	end

	if not isSafeInteger(level) or level < 1 then
		warn(string.format(
			"[PlayerDataService] Progresión rechazada: nivel inválido para %s (%d). Recibido: %s",
			player.Name,
			player.UserId,
			tostring(level)
		))
		return false
	end

	if not isSafeInteger(experience) or experience < 0 then
		warn(string.format(
			"[PlayerDataService] Progresión rechazada: experiencia inválida para %s (%d). Recibido: %s",
			player.Name,
			player.UserId,
			tostring(experience)
		))
		return false
	end

	local requiredExperience = GameConfig.GetRequiredExperience(level)
	if not isSafeInteger(requiredExperience) or requiredExperience < 1 or experience >= requiredExperience then
		warn(string.format(
			"[PlayerDataService] Progresión rechazada: estado inconsistente para %s (%d). Level=%s Experience=%s XP requerida=%s",
			player.Name,
			player.UserId,
			tostring(level),
			tostring(experience),
			tostring(requiredExperience)
		))
		return false
	end

	local previousLevel = profile.Level
	local previousExperience = profile.Experience
	local currency = profile.Currency
	local currencyAttribute = player:GetAttribute("Currency")

	profile.Level = level
	profile.Experience = experience

	local published = pcall(function()
		player:SetAttribute("Level", level)
		player:SetAttribute("Experience", experience)
	end)

	local readOk, levelAttribute, experienceAttribute, currencyValue = pcall(function()
		return player:GetAttribute("Level"), player:GetAttribute("Experience"), player:GetAttribute("Currency")
	end)

	local consistent = published
		and readOk
		and levelAttribute == level
		and experienceAttribute == experience
		and profile.Currency == currency
		and currencyValue == currencyAttribute

	if consistent then
		return true
	end

	profile.Level = previousLevel
	profile.Experience = previousExperience
	pcall(function()
		player:SetAttribute("Level", previousLevel)
		player:SetAttribute("Experience", previousExperience)
	end)
	warn(string.format(
		"[PlayerDataService] Progresión revertida: no se pudo publicar un estado consistente para %s (%d).",
		player.Name,
		player.UserId
	))
	return false
end

return PlayerDataService
