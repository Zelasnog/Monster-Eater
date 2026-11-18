local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContextActionService = game:GetService("ContextActionService")
local RunService = game:GetService("RunService")

local CombatConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("CombatConfig"))
local attackRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CombatAttackRequest")
local CombatAnimationController = require(script.Parent:WaitForChild("CombatAnimationController"))
local player = Players.LocalPlayer
local CombatController = {}

local initialized = false
local toolConnections = setmetatable({}, { __mode = "k" })
local backpack
local equippedWeapon
local debugGui
local debugLabel
local debugState = {
	RecentInputs = {},
	Sequence = {},
	Status = "Waiting for input",
}
local lastResult
local lastHudUpdate = 0
local animationDebug = {
	Requested = "—",
	Played = "—",
	Finisher = "—",
	Reason = "—",
}

local RIGHT_CLICK_ACTION = "MonsterEater_RightClickAttack"
local DEBUG_TOGGLE_ACTION = "MonsterEater_ToggleCombatDebug"
local RESET_REASON_LABELS = {
	AttackCooldown = "Cooldown compartido",
	CharacterRespawned = "Personaje reapareció",
	ComboWindowExpired = "Ventana del combo expirada",
	PlayerDead = "Jugador sin vida",
	RequestRateLimit = "Frecuencia de solicitudes",
	SequenceMismatch = "Entrada fuera de la ruta",
	WeaponNotEquippedOrHandleMissing = "Arma no equipada o sin Handle",
	WeaponUnequipped = "Arma desequipada",
	WeaponChanged = "Arma cambiada",
	["IncompatibleMovement:Dash/Dodge"] = "Dash/Dodge",
	["IncompatibleMovement:Slide"] = "Slide",
	["IncompatibleMovement:Wallrun"] = "Wallrun",
	["IncompatibleMovement:Climbing"] = "Climbing",
	["IncompatibleMovement:ClimbBoost"] = "Climb Boost",
	["IncompatibleMovement:Mantle"] = "Mantle",
}
local ANIMATION_REASON_LABELS = {
	AnimationConfigMissing = "Falta configurar esta animación",
	AnimationIdNotConfigured = "Falta importar/publicar el asset e ID",
	AnimatorUnavailable = "Animator no disponible",
	CharacterUnavailable = "Personaje no disponible",
	InvalidAnimationIdFormat = "AnimationId debe usar rbxassetid://<ID>",
	WeaponAnimationConfigMissing = "Arma sin configuración de animación",
	WeaponNotEquipped = "El arma ya no está equipada",
}

local function logClient(message)
	if CombatConfig.EnableCombatLogs then
		print("[CombatController] " .. message)
	end
end

local function formatSequence(sequence)
	if not sequence or #sequence == 0 then
		return "—"
	end
	return table.concat(sequence, " - ")
end

local function formatAnimationReason(reason)
	if not reason or reason == "" then
		return "—"
	end
	if ANIMATION_REASON_LABELS[reason] then
		return ANIMATION_REASON_LABELS[reason]
	elseif string.find(reason, "FinisherAnimationIdNotConfigured; using attack animation fallback", 1, true) then
		return "Falta el ID del remate; se usó la animación del ataque"
	elseif string.find(reason, "FinisherAnimationIdNotConfigured; attackAnimationIdNotConfigured", 1, true) then
		return "Faltan los IDs del remate y del ataque"
	elseif string.find(reason, "LoadAnimationFailed", 1, true) then
		return "No se pudo cargar el asset: " .. reason
	end
	return reason
end

local function getRemainingTime()
	if not debugState.ReceivedAt or not debugState.TimeRemaining then
		return 0
	end
	return math.max(0, debugState.TimeRemaining - (os.clock() - debugState.ReceivedAt))
end

local function renderDebugHud()
	if not debugLabel then
		return
	end

	local progress = string.format("%d/%d", debugState.Progress or 0, debugState.ComboLength or 0)
	local comboName = debugState.ComboName or "—"
	local remaining = getRemainingTime()
	local rawReason = debugState.ResetReason
	local reason = rawReason and (RESET_REASON_LABELS[rawReason] or rawReason) or "—"
	local status = debugState.Status or "Waiting for input"
	if status == "Combo active" then
		status = "COMBO ACTIVO"
	elseif status == "Combo completed" then
		status = "COMBO COMPLETADO"
	elseif status == "Chain reset" then
		status = "CADENA REINICIADA"
	elseif status == "Waiting for input" then
		status = "ESPERANDO ENTRADA"
	end
	local resultLine = lastResult and string.format(
		"Último resultado: %s %s",
		lastResult.Accepted and "ACEPTADO" or "RECHAZADO",
		lastResult.Reason or ""
	) or "Último resultado: esperando"
	local finisherLine = animationDebug.Finisher ~= "—"
		and (animationDebug.Finisher .. " (aceptado por servidor)")
		or "—"

	debugLabel.Text = string.format(
		"COMBAT DEBUG  [P: ocultar]\n"
			.. "Últimas entradas: %s\n"
			.. "Secuencia actual: %s\n"
			.. "Reconocido: %s\n"
			.. "Progreso: %s\n"
			.. "Estado: %s\n"
			.. "Tiempo restante: %.1f s\n"
			.. "Motivo: %s\n"
			.. "%s\n"
			.. "Animación solicitada: %s\n"
			.. "Animación reproducida: %s\n"
			.. "Remate ejecutado: %s\n"
			.. "Motivo de animación: %s",
		formatSequence(debugState.RecentInputs),
		formatSequence(debugState.Sequence),
		comboName,
		progress,
		status,
		remaining,
		reason,
		resultLine,
		animationDebug.Requested,
		animationDebug.Played,
		finisherLine,
		formatAnimationReason(animationDebug.Reason)
	)
end

local function createDebugHud()
	if not CombatConfig.EnableDebugHUD then
		return
	end

	local playerGui = player:WaitForChild("PlayerGui")
	debugGui = Instance.new("ScreenGui")
	debugGui.Name = "CombatDebugGui"
	debugGui.ResetOnSpawn = false
	debugGui.DisplayOrder = 20
	debugGui.Parent = playerGui

	debugLabel = Instance.new("TextLabel")
	debugLabel.Name = "CombatDebugText"
	debugLabel.AnchorPoint = Vector2.new(0, 0)
	debugLabel.Position = UDim2.fromOffset(12, 150)
	debugLabel.Size = UDim2.fromOffset(390, 265)
	debugLabel.BackgroundColor3 = Color3.fromRGB(15, 20, 28)
	debugLabel.BackgroundTransparency = 0.18
	debugLabel.BorderSizePixel = 0
	debugLabel.Font = Enum.Font.Code
	debugLabel.TextColor3 = Color3.fromRGB(235, 242, 255)
	debugLabel.TextSize = 13
	debugLabel.TextWrapped = false
	debugLabel.TextXAlignment = Enum.TextXAlignment.Left
	debugLabel.TextYAlignment = Enum.TextYAlignment.Top
	debugLabel.Parent = debugGui

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 9)
	padding.PaddingRight = UDim.new(0, 9)
	padding.PaddingTop = UDim.new(0, 8)
	padding.PaddingBottom = UDim.new(0, 8)
	padding.Parent = debugLabel

	debugGui.Enabled = true
	renderDebugHud()
end

local function requestAttack(input)
	logClient("Entrada recibida: " .. input)
	lastResult = nil
	local weaponName = equippedWeapon and equippedWeapon.Name or "Arma"
	animationDebug.Requested = string.format("%s.Attacks.%s", weaponName, input)
	animationDebug.Played = "—"
	animationDebug.Finisher = "—"
	animationDebug.Reason = "Esperando confirmación del servidor"
	attackRemote:FireServer(input)
	if debugLabel then
		renderDebugHud()
	end
end

local function onRightClickAttack(_, inputState)
	if inputState == Enum.UserInputState.Begin and equippedWeapon and equippedWeapon.Parent == player.Character then
		requestAttack("RC")
	end
	return Enum.ContextActionResult.Sink
end

local function setEquippedWeapon(tool)
	if equippedWeapon == tool then
		return
	end
	if equippedWeapon then
		CombatAnimationController.OnWeaponUnequipped(equippedWeapon)
	end
	ContextActionService:UnbindAction(RIGHT_CLICK_ACTION)
	equippedWeapon = tool
	if equippedWeapon then
		CombatAnimationController.OnWeaponEquipped(equippedWeapon)
		ContextActionService:BindActionAtPriority(
			RIGHT_CLICK_ACTION,
			onRightClickAttack,
			false,
			Enum.ContextActionPriority.High.Value,
			Enum.UserInputType.MouseButton2
		)
	end
end

local function connectWeapon(tool)
	if not tool:IsA("Tool") or not CombatConfig.CombosByWeapon[tool.Name] or toolConnections[tool] then
		return
	end

	local connections = {}
	connections.Activated = tool.Activated:Connect(function()
		if tool.Parent ~= player.Character then
			return
		end
		requestAttack("L")
	end)
	connections.Equipped = tool.Equipped:Connect(function()
		setEquippedWeapon(tool)
	end)
	connections.Unequipped = tool.Unequipped:Connect(function()
		if equippedWeapon == tool then
			setEquippedWeapon(nil)
		end
	end)
	toolConnections[tool] = connections
	if tool.Parent == player.Character then
		setEquippedWeapon(tool)
	end

	tool.AncestryChanged:Connect(function(_, parent)
		if parent == player.Character then
			setEquippedWeapon(tool)
		elseif parent == backpack and equippedWeapon == tool then
			setEquippedWeapon(nil)
		end

		if parent ~= player.Character and parent ~= backpack then
			for _, connection in connections do
				connection:Disconnect()
			end
			if equippedWeapon == tool then
				setEquippedWeapon(nil)
			end
			toolConnections[tool] = nil
		end
	end)
end

local function watchCharacter(character)
	for _, child in character:GetChildren() do
		connectWeapon(child)
	end
	character.ChildAdded:Connect(connectWeapon)
end

local function toggleDebugHud(_, inputState)
	if inputState == Enum.UserInputState.Begin and debugGui then
		debugGui.Enabled = not debugGui.Enabled
		logClient("HUD de diagnóstico " .. (debugGui.Enabled and "activado" or "desactivado"))
	end
	return Enum.ContextActionResult.Sink
end

local function onServerEvent(eventName, payload)
	if eventName == "ComboDebug" and typeof(payload) == "table" then
		debugState = payload
		debugState.ReceivedAt = os.clock()
		if debugLabel then
			renderDebugHud()
		end
	elseif eventName == "CombatResult" and typeof(payload) == "table" then
		lastResult = payload
		if payload.Accepted then
			logClient("Servidor aceptó " .. tostring(payload.Input))
			local playback = CombatAnimationController.PlayConfirmedAttack(payload)
			animationDebug.Requested = playback.Requested
			animationDebug.Played = playback.Played
			animationDebug.Finisher = payload.FinisherExecuted and payload.ComboName or "—"
			animationDebug.Reason = playback.Reason or "—"
		else
			logClient(string.format("Servidor rechazó %s: %s", tostring(payload.Input), tostring(payload.Reason)))
			animationDebug.Played = "—"
			animationDebug.Finisher = "—"
			animationDebug.Reason = "Ataque rechazado: " .. tostring(payload.Reason)
		end
		if debugLabel then
			renderDebugHud()
		end
	end
end

function CombatController.Init()
	if initialized then
		return
	end
	initialized = true

	backpack = player:WaitForChild("Backpack")
	CombatAnimationController.Init()
	for _, child in backpack:GetChildren() do
		connectWeapon(child)
	end
	backpack.ChildAdded:Connect(connectWeapon)
	attackRemote.OnClientEvent:Connect(onServerEvent)
	player.CharacterAdded:Connect(watchCharacter)
	player.CharacterRemoving:Connect(function()
		setEquippedWeapon(nil)
	end)
	if player.Character then
		watchCharacter(player.Character)
	end

	createDebugHud()
	if CombatConfig.EnableDebugHUD then
		ContextActionService:BindActionAtPriority(
			DEBUG_TOGGLE_ACTION,
			toggleDebugHud,
			false,
			Enum.ContextActionPriority.Low.Value,
			CombatConfig.DebugToggleKey
		)
		RunService.Heartbeat:Connect(function()
			if debugGui and debugGui.Enabled and os.clock() - lastHudUpdate >= 0.1 then
				lastHudUpdate = os.clock()
				renderDebugHud()
			end
		end)
	end

	logClient("Controles de combate inicializados.")
end

return CombatController
