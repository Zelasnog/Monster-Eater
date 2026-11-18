local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local CombatConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("CombatConfig"))
local REMOTE_NAME = "CombatAttackRequest"
local CombatService = {}

local initialized = false
local lastRequestAt = {}
local nextAttackAt = {}
local comboStates = {}
local lastLogAt = {}
local attackRemote

local function logService(message)
	if CombatConfig.EnableCombatLogs then
		print("[CombatService] " .. message)
	end
end

local function logEvent(prefix, player, message, throttleKey)
	if not CombatConfig.EnableCombatLogs then
		return
	end

	if throttleKey then
		local playerLogTimes = lastLogAt[player]
		if not playerLogTimes then
			playerLogTimes = {}
			lastLogAt[player] = playerLogTimes
		end
		local now = os.clock()
		if playerLogTimes[throttleKey] and now - playerLogTimes[throttleKey] < CombatConfig.LogRepeatInterval then
			return
		end
		playerLogTimes[throttleKey] = now
	end

	print(string.format("[%s] %s: %s", prefix, player.Name, message))
end

local function getComboState(player)
	local state = comboStates[player]
	if not state then
		state = {
			Sequence = {},
			RecentInputs = {},
			Status = "Waiting for input",
			ComboName = nil,
			Progress = 0,
			ComboLength = 0,
			ExpiresAt = nil,
			ResetReason = nil,
			WeaponName = nil,
			Generation = 0,
		}
		comboStates[player] = state
	end
	return state
end

local function sendDebugState(player)
	if not CombatConfig.EnableDebugHUD or not attackRemote or not player.Parent then
		return
	end

	local state = getComboState(player)
	local recentInputs = table.clone(state.RecentInputs)
	local sequence = table.clone(state.Sequence)
	attackRemote:FireClient(player, "ComboDebug", {
		RecentInputs = recentInputs,
		Sequence = sequence,
		ComboName = state.ComboName,
		Progress = state.Progress,
		ComboLength = state.ComboLength,
		Status = state.Status,
		TimeRemaining = state.ExpiresAt and math.max(0, state.ExpiresAt - os.clock()) or 0,
		ResetReason = state.ResetReason,
		LastInput = recentInputs[#recentInputs],
	})
end

local function resetCombo(player, reason)
	local state = getComboState(player)
	local hadActiveChain = state.Status == "Combo active" and #state.Sequence > 0
	state.Generation += 1
	state.Sequence = {}
	state.Status = "Chain reset"
	state.ComboName = nil
	state.Progress = 0
	state.ComboLength = 0
	state.ExpiresAt = nil
	state.ResetReason = reason
	state.WeaponName = nil

	if hadActiveChain then
		logEvent("ComboSystem", player, "Cadena reiniciada: " .. reason)
	end
	sendDebugState(player)
end

local function addRecentInput(state, input)
	table.insert(state.RecentInputs, input)
	while #state.RecentInputs > CombatConfig.MaxRecentInputs do
		table.remove(state.RecentInputs, 1)
	end
end

local function startsWith(sequence, prefix)
	for index, value in prefix do
		if sequence[index] ~= value then
			return false
		end
	end
	return true
end

local function findLongestMatchingSuffix(sequence, definitions)
	for startIndex = 1, #sequence do
		local suffixLength = #sequence - startIndex + 1
		local suffix = {}
		for index = startIndex, #sequence do
			table.insert(suffix, sequence[index])
		end
		local matches = {}
		for _, definition in definitions do
			if suffixLength <= #definition.Sequence and startsWith(definition.Sequence, suffix) then
				table.insert(matches, definition)
			end
		end
		if #matches > 0 then
			return suffix, matches, startIndex
		end
	end
	return {}, {}, #sequence + 1
end

local function scheduleComboExpiry(player, state)
	state.Generation += 1
	local generation = state.Generation
	state.ExpiresAt = os.clock() + CombatConfig.ComboWindow
	task.delay(CombatConfig.ComboWindow, function()
		local currentState = comboStates[player]
		if currentState == state
			and state.Generation == generation
			and state.Status == "Combo active"
			and state.ExpiresAt
			and os.clock() >= state.ExpiresAt
		then
			resetCombo(player, "ComboWindowExpired")
		end
	end)
end

local function advanceCombo(player, weaponName, input, now)
	local state = getComboState(player)
	local definitions = CombatConfig.CombosByWeapon[weaponName] or {}
	if state.Status == "Combo active" and state.ExpiresAt and now >= state.ExpiresAt then
		resetCombo(player, "ComboWindowExpired")
	end
	if state.WeaponName and state.WeaponName ~= weaponName then
		resetCombo(player, "WeaponChanged")
	end
	if state.Status == "Combo completed" or state.Status == "Chain reset" then
		state.Sequence = {}
	end

	local attemptedSequence = table.clone(state.Sequence)
	table.insert(attemptedSequence, input)
	local sequence, matches, startIndex = findLongestMatchingSuffix(attemptedSequence, definitions)
	local mismatch = startIndex > 1
	if #matches == 0 then
		if #state.Sequence > 0 then
			logEvent("ComboSystem", player, "Cadena reiniciada: SequenceMismatch")
		end
		state.Generation += 1
		state.Sequence = {}
		state.Status = "Chain reset"
		state.ComboName = nil
		state.Progress = 0
		state.ComboLength = 0
		state.ExpiresAt = nil
		state.ResetReason = "SequenceMismatch"
		state.WeaponName = nil
		sendDebugState(player)
		return
	end

	if mismatch then
		logEvent("ComboSystem", player, "Cadena reiniciada: SequenceMismatch; se conserva el sufijo válido")
	end
	state.Sequence = sequence
	state.WeaponName = weaponName
	state.ResetReason = if mismatch then "SequenceMismatch" else nil

	local exactMatch
	local continuingMatch
	for _, definition in matches do
		if #definition.Sequence == #sequence then
			exactMatch = exactMatch or definition
		else
			continuingMatch = continuingMatch or definition
		end
	end

	if exactMatch and not continuingMatch then
		state.Status = "Combo completed"
		state.ComboName = exactMatch.Name
		state.Progress = #sequence
		state.ComboLength = #exactMatch.Sequence
		state.ExpiresAt = nil
		state.Generation += 1
		state.ResetReason = nil
		logEvent("ComboSystem", player, "Combo reconocido: " .. exactMatch.Name)
		logEvent("ComboSystem", player, "Combo completado: " .. exactMatch.Name)
	else
		local displayMatch = continuingMatch or exactMatch
		state.Status = "Combo active"
		state.ComboName = displayMatch and displayMatch.Name or nil
		state.Progress = #sequence
		state.ComboLength = displayMatch and #displayMatch.Sequence or #sequence
		scheduleComboExpiry(player, state)
		logEvent("ComboSystem", player, "Secuencia: " .. table.concat(sequence, " - "))
		if exactMatch then
			logEvent("ComboSystem", player, "Ruta reconocida y extensible: " .. exactMatch.Name)
		end
	end
	sendDebugState(player)
end

local function getIncompatibleMovement(player)
	local movementState = player:GetAttribute("MovementState")
	if player:GetAttribute("MovementDashing") == true or movementState == "Dodge" then
		return "Dash/Dodge"
	elseif player:GetAttribute("MovementSliding") == true or movementState == "Slide" then
		return "Slide"
	elseif player:GetAttribute("MovementWallrunning") == true or movementState == "Wallrun" then
		return "Wallrun"
	elseif player:GetAttribute("MovementClimbing") == true or movementState == "Climb" then
		return "Climbing"
	elseif player:GetAttribute("MovementClimbBoosting") == true or movementState == "ClimbBoost" then
		return "ClimbBoost"
	elseif player:GetAttribute("MovementMantling") == true or movementState == "Mantle" then
		return "Mantle"
	end
	return nil
end


local function getEquippedWeapon(character)
	for _, tool in character:GetChildren() do
		if tool:IsA("Tool") and tool.Parent == character and CombatConfig.CombosByWeapon[tool.Name] then
			local handle = tool:FindFirstChild("Handle")
			if handle and handle:IsA("BasePart") then
				return tool
			end
		end
	end
	return nil
end

local function getLivingNpcFromPart(part, attackerCharacter)
	local ancestor = part.Parent
	while ancestor and ancestor ~= Workspace do
		if ancestor:IsA("Model") and ancestor ~= attackerCharacter then
			local humanoid = ancestor:FindFirstChildOfClass("Humanoid")
			if humanoid then
				if humanoid.Health > 0 and not Players:GetPlayerFromCharacter(ancestor) then
					local root = ancestor:FindFirstChild("HumanoidRootPart") or humanoid.RootPart
					if root and root:IsA("BasePart") then
						return ancestor, humanoid, root
					end
				end
				return nil
			end
		end
		ancestor = ancestor.Parent
	end
	return nil
end

local function hasClearLineOfSight(origin, targetRoot, targetModel, attackerCharacter)
	local direction = targetRoot.Position - origin
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = { attackerCharacter }
	raycastParams.IgnoreWater = true

	local result = Workspace:Raycast(origin, direction, raycastParams)
	return result ~= nil and result.Instance:IsDescendantOf(targetModel)
end

local function applyAttack(character, root)
	local range = CombatConfig.Range
	local hitboxCFrame = root.CFrame + root.CFrame.LookVector * (range * 0.5)
	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = { character }
	local parts = Workspace:GetPartBoundsInBox(
		hitboxCFrame,
		Vector3.new(CombatConfig.HitboxWidth, CombatConfig.HitboxHeight, range),
		overlapParams
	)

	local candidates = {}
	local seenModels = {}
	for _, part in parts do
		local model, humanoid, targetRoot = getLivingNpcFromPart(part, character)
		if model and not seenModels[model] then
			local offset = targetRoot.Position - root.Position
			local distance = offset.Magnitude
			if distance <= range and offset:Dot(root.CFrame.LookVector) > 0 then
				seenModels[model] = true
				table.insert(candidates, {
					Model = model,
					Humanoid = humanoid,
					Root = targetRoot,
					Distance = distance,
				})
			end
		end
	end

	table.sort(candidates, function(a, b)
		return a.Distance < b.Distance
	end)

	local hitCount = 0
	for _, candidate in candidates do
		if hitCount >= CombatConfig.MaxTargetsPerAttack then
			break
		end
		if candidate.Humanoid.Health > 0
			and hasClearLineOfSight(root.Position, candidate.Root, candidate.Model, character)
		then
			candidate.Humanoid:TakeDamage(CombatConfig.Damage)
			hitCount += 1
		end
	end
	return hitCount
end

local function sendCombatResult(player, input, accepted, reason, details)
	if attackRemote and player.Parent then
		attackRemote:FireClient(player, "CombatResult", {
			Input = input,
			Accepted = accepted,
			Reason = reason,
			WeaponName = details and details.WeaponName or nil,
			ComboName = details and details.ComboName or nil,
			FinisherExecuted = details and details.FinisherExecuted or false,
		})
	end
end

local function rejectAttack(player, input, reason, now)
	logEvent("CombatService", player, string.format("Solicitud %s rechazada: %s", input, reason), "Reject:" .. reason)
	resetCombo(player, reason)
	sendCombatResult(player, input, false, reason)
end

local function onAttackRequested(player, input)
	local now = os.clock()
	local previousRequest = lastRequestAt[player]
	if previousRequest and now - previousRequest < CombatConfig.RequestInterval then
		logEvent("CombatService", player, "Solicitud rechazada: RequestRateLimit", "Reject:RequestRateLimit")
		return
	end
	lastRequestAt[player] = now

	if input ~= "L" and input ~= "RC" then
		logEvent("CombatService", player, "Solicitud rechazada: InvalidInput", "Reject:InvalidInput")
		sendCombatResult(player, tostring(input), false, "InvalidInput")
		return
	end
	logEvent("CombatService", player, "Entrada recibida: " .. input)
	local comboState = getComboState(player)
	addRecentInput(comboState, input)

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not character or not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
		rejectAttack(player, input, "PlayerDead", now)
		return
	end

	local weapon = getEquippedWeapon(character)
	if not weapon then
		rejectAttack(player, input, "WeaponNotEquippedOrHandleMissing", now)
		return
	end

	local incompatibleMovement = getIncompatibleMovement(player)
	if incompatibleMovement then
		rejectAttack(player, input, "IncompatibleMovement:" .. incompatibleMovement, now)
		return
	end

	if now < (nextAttackAt[player] or 0) then
		rejectAttack(player, input, "AttackCooldown", now)
		return
	end
	nextAttackAt[player] = now + CombatConfig.Cooldown

	logEvent("CombatService", player, "Ataque " .. input .. " aceptado (Damage=" .. CombatConfig.Damage .. ")")
	advanceCombo(player, weapon.Name, input, now)
	local comboState = getComboState(player)
	local hitCount = applyAttack(character, root)
	if hitCount == 0 then
		logEvent("CombatService", player, "Ataque " .. input .. " sin objetivo válido")
	end
	sendCombatResult(player, input, true, nil, {
		WeaponName = weapon.Name,
		ComboName = comboState.Status == "Combo completed" and comboState.ComboName or nil,
		FinisherExecuted = comboState.Status == "Combo completed",
	})
end

local function onCharacterAdded(player, character)
	resetCombo(player, "CharacterRespawned")
	character.ChildRemoved:Connect(function(child)
		if child:IsA("Tool") and CombatConfig.CombosByWeapon[child.Name] then
			resetCombo(player, "WeaponUnequipped")
		end
	end)
end

local function onPlayerAdded(player)
	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)
	if player.Character then
		onCharacterAdded(player, player.Character)
	end
end

function CombatService.Init()
	if initialized then
		warn("[CombatService] Init ya estaba activo.")
		return
	end
	initialized = true

	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotes then
		remotes = Instance.new("Folder")
		remotes.Name = "Remotes"
		remotes.Parent = ReplicatedStorage
	end

	attackRemote = remotes:FindFirstChild(REMOTE_NAME)
	if attackRemote and not attackRemote:IsA("RemoteEvent") then
		error(string.format("ReplicatedStorage.Remotes.%s existe y no es RemoteEvent", REMOTE_NAME))
	end
	if not attackRemote then
		attackRemote = Instance.new("RemoteEvent")
		attackRemote.Name = REMOTE_NAME
		attackRemote.Parent = remotes
	end

	attackRemote.OnServerEvent:Connect(onAttackRequested)
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(function(player)
		lastRequestAt[player] = nil
		nextAttackAt[player] = nil
		comboStates[player] = nil
		lastLogAt[player] = nil
	end)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end

	logService("Inicializado.")
end

return CombatService
