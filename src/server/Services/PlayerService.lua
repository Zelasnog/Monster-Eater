local Players = game:GetService("Players")

local PlayerService = {}

local initialized = false
local trackedPlayers: { [Player]: boolean } = {}

local function onCharacterAdded(player: Player, character: Model)
	print(string.format(
		"[PlayerService] Personaje apareció: %s | Jugador: %s (%d)",
		character.Name,
		player.Name,
		player.UserId
	))
end

local function onPlayerAdded(player: Player)
	if trackedPlayers[player] then
		return
	end

	trackedPlayers[player] = true

	print(string.format("[PlayerService] Jugador entró: %s (%d)", player.Name, player.UserId))

	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)

	if player.Character then
		onCharacterAdded(player, player.Character)
	end
end

local function onPlayerRemoving(player: Player)
	trackedPlayers[player] = nil
	print(string.format("[PlayerService] Jugador salió: %s (%d)", player.Name, player.UserId))
end

function PlayerService.Init()
	if initialized then
		warn("[PlayerService] Init ya estaba activo. No se volvieron a conectar los eventos.")
		return
	end

	initialized = true

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end

	print("[PlayerService] Inicializado.")
end

return PlayerService
