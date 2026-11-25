local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContentProvider = game:GetService("ContentProvider")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("SprintAnimationConfig"))
local player = Players.LocalPlayer
local Controller = {}

local initialized = false
local character, humanoid, animator
local activeTrack, activeAnimation, activeId, activeMode
local pendingAnimation, pendingId, loading = nil, nil, false
local generation = 0
local characterConnections = {}
local stockLocomotionIds = {}
local lastEquippedTool

local SPECIAL_MOVEMENT_ATTRIBUTES = {
	"MovementDashing",
	"MovementSliding",
	"MovementWallrunning",
	"MovementClimbing",
	"MovementClimbBoosting",
	"MovementMantling",
}

local function log(message)
	print("[SprintAnimationController] " .. message)
end

local function reportError(reason)
	warn("[SprintAnimationController] ERROR: " .. tostring(reason))
end

local function validId(id)
	return type(id) == "string" and string.match(id, "^rbxassetid://%d+$") ~= nil
end

local function equippedWeapon()
	if not character then return nil end
	for _, weapon in Config.WeaponAnimations do
		if character:FindFirstChild(weapon.ToolName) then return weapon end
	end
	return nil
end

local function specialMovementActive()
	for _, attribute in SPECIAL_MOVEMENT_ATTRIBUTES do
		if player:GetAttribute(attribute) == true then return true end
	end
	return false
end

local function desiredAnimation()
	if character ~= player.Character or not humanoid or humanoid.Health <= 0 or not animator or not animator.Parent then
		return nil, nil
	end
	if player:GetAttribute("MovementDashing") == true then
		return validId(Config.DashAnimationId) and Config.DashAnimationId or nil, "Dash"
	end
	if specialMovementActive() then return nil, nil end
	local weapon = equippedWeapon()
	if humanoid.MoveDirection.Magnitude <= 0.05 then
		if weapon and validId(weapon.IdleAnimationId) then return weapon.IdleAnimationId, "Idle_" .. weapon.Type end
		return nil, nil
	end

	if player:GetAttribute("MovementSprinting") == true then
		if weapon and weapon.Type == "Sword" then
			local id = validId(Config.SwordRunAnimationId) and Config.SwordRunAnimationId or Config.RunAnimationId
			return validId(id) and id or nil, "SwordSprint"
		end
		return validId(Config.RunAnimationId) and Config.RunAnimationId or nil, "Sprint"
	end
	return validId(Config.WalkAnimationId) and Config.WalkAnimationId or nil, "Walk"
end

local function destroyActiveTrack(fadeTime)
	if activeTrack then
		if activeTrack.IsPlaying then activeTrack:Stop(fadeTime or Config.FadeTime) end
		activeTrack:Destroy()
		activeTrack = nil
	end
	if activeAnimation then activeAnimation:Destroy(); activeAnimation = nil end
	activeId, activeMode = nil, nil
end

local function clearPending()
	if pendingAnimation then pendingAnimation:Destroy(); pendingAnimation = nil end
	pendingId, loading = nil, false
end

local function getStockLocomotionIds()
	local ids = {}
	local animate = character and character:FindFirstChild("Animate")
	if not animate then return ids end
	for _, descendant in animate:GetDescendants() do
		if descendant:IsA("Animation") then
			local branch = descendant
			while branch and branch ~= animate do
				local name = string.lower(branch.Name)
				if string.find(name, "run", 1, true) or string.find(name, "walk", 1, true) then
					if validId(descendant.AnimationId) then ids[descendant.AnimationId] = true end
					break
				end
				branch = branch.Parent
			end
		end
	end
	return ids
end

local function isStockLocomotion(track)
	if track == activeTrack or track.Priority.Value > Enum.AnimationPriority.Movement.Value then return false end
	local animationId = track.Animation and track.Animation.AnimationId
	if animationId and stockLocomotionIds[animationId] then return true end
	local name = string.lower(track.Name)
	return string.find(name, "run", 1, true) ~= nil or string.find(name, "walk", 1, true) ~= nil
end

local function stopStockLocomotion()
	if not animator then return end
	for _, playingTrack in animator:GetPlayingAnimationTracks() do
		if isStockLocomotion(playingTrack) then playingTrack:Stop(Config.FadeTime) end
	end
end

local function onAnimationPlayed(playedTrack)
	if (activeTrack and activeTrack.IsPlaying or specialMovementActive()) and isStockLocomotion(playedTrack) then
		playedTrack:Stop(Config.FadeTime)
	end
end

local update
local function equipChanged()
	local weapon = equippedWeapon()
	local equipped = weapon and weapon.ToolName or nil
	if lastEquippedTool ~= nil and equipped ~= lastEquippedTool then
		log(equipped and (equipped .. " equipada") or "Arma desequipada")
	end
	lastEquippedTool = equipped
	update()
end

update = function()
	local id, mode = desiredAnimation()
	if not id then
		if loading or activeTrack then
			local endedMode = activeMode
			generation += 1
			clearPending()
			destroyActiveTrack()
		if endedMode == "Walk" then log("Walk terminado") elseif endedMode and string.sub(endedMode, 1, 5) == "Idle_" then log("Idle de arma terminado") elseif endedMode == "Dash" then log("Dash terminado") else log("Sprint terminado") end
		end
		return
	end
	if activeTrack and activeId == id and activeMode == mode and activeTrack.IsPlaying then
		stopStockLocomotion()
		return
	end
	if loading and pendingId == id then return end

	generation += 1
	local currentGeneration = generation
	clearPending()
	destroyActiveTrack()
	pendingAnimation = Instance.new("Animation")
	pendingAnimation.Name = "MonsterEater_" .. mode
	pendingAnimation.AnimationId = id
	pendingId, loading = id, true
	if mode == "Walk" then
		log("Walk detectado")
	elseif mode == "Dash" then
		log("Dash confirmado por el servidor")
	elseif string.sub(mode, 1, 5) == "Idle_" then
		log("Idle de arma: " .. string.sub(mode, 6))
	elseif mode == "SwordSprint" then
		log("Sprint con Sword")
	else
		log("Sprint sin Sword")
	end
	log("Cargando animación " .. id)
	local animationToLoad = pendingAnimation
	local ok, preloadError = pcall(function()
		ContentProvider:PreloadAsync({ animationToLoad }, function(assetId, status)
			log(string.format("Carga del asset %s: %s", tostring(assetId), tostring(status)))
			if status ~= Enum.AssetFetchStatus.Success then
				reportError(string.format("PreloadAsync devolvió %s para %s", tostring(status), tostring(assetId)))
			end
		end)
	end)
	if not ok then reportError("falló PreloadAsync para " .. id .. ": " .. tostring(preloadError)) end
	local currentId, currentMode = desiredAnimation()
	if currentGeneration ~= generation or currentId ~= id or currentMode ~= mode then
		if pendingAnimation == animationToLoad then clearPending() end
		return
	end
	local success, loadedTrack = pcall(function() return animator:LoadAnimation(animationToLoad) end)
	loading, pendingId, pendingAnimation = false, nil, nil
	if not success then
		animationToLoad:Destroy()
		reportError("LoadAnimation falló para " .. id .. ": " .. tostring(loadedTrack))
		return
	end
	activeAnimation = animationToLoad
	activeTrack = loadedTrack
	activeId, activeMode = id, mode
	activeTrack.Name = "MonsterEater_" .. mode
	activeTrack.Priority = mode == "Dash" and Config.DashPriority or (string.sub(mode, 1, 5) == "Idle_" and Enum.AnimationPriority.Idle or Config.Priority)
	activeTrack.Looped = mode ~= "Dash"
	stopStockLocomotion()
	local played, playError = pcall(function() activeTrack:Play(Config.FadeTime) end)
	if not played then
		reportError("Play falló para " .. id .. ": " .. tostring(playError))
		destroyActiveTrack(0)
		return
	end
	log(string.format("Animación reproducida | modo=%s | ID=%s | prioridad=%s | duración=%.3f", mode, id, tostring(activeTrack.Priority), activeTrack.Length))
	local monitoredTrack = activeTrack
	task.spawn(function()
		local deadline = os.clock() + 8
		while monitoredTrack == activeTrack and monitoredTrack.IsPlaying and monitoredTrack.Length <= 0 and os.clock() < deadline do
			task.wait(0.2)
		end
		if monitoredTrack == activeTrack and monitoredTrack.IsPlaying and monitoredTrack.Length <= 0 then
			reportError("la pista no cargó (Length=0) para " .. id .. "; revisar permisos/propiedad del asset y Output de Roblox")
		elseif monitoredTrack == activeTrack and monitoredTrack.Length > 0 then
			log(string.format("Asset cargado | modo=%s | duración=%.3f s", mode, monitoredTrack.Length))
		end
	end)
end

local function disconnectCharacter()
	for _, connection in characterConnections do connection:Disconnect() end
	table.clear(characterConnections)
	generation += 1
	clearPending()
	destroyActiveTrack(0.05)
	character, humanoid, animator = nil, nil, nil
	stockLocomotionIds = {}
	lastEquippedTool = nil
end

local function attach(newCharacter)
	disconnectCharacter()
	character = newCharacter
	humanoid = newCharacter:WaitForChild("Humanoid", 10)
	animator = humanoid and (humanoid:FindFirstChildOfClass("Animator") or humanoid:WaitForChild("Animator", 10))
	if not humanoid then reportError("Humanoid no apareció en el personaje"); return end
	if not animator then reportError("Animator no apareció en el Humanoid"); return end
	stockLocomotionIds = getStockLocomotionIds()
	characterConnections[#characterConnections + 1] = humanoid.Running:Connect(update)
	characterConnections[#characterConnections + 1] = animator.AnimationPlayed:Connect(onAnimationPlayed)
	characterConnections[#characterConnections + 1] = newCharacter.ChildAdded:Connect(function(child)
		equipChanged()
	end)
	characterConnections[#characterConnections + 1] = newCharacter.ChildRemoved:Connect(function(child)
		equipChanged()
	end)
	log("Animator conectado al personaje " .. newCharacter.Name)
	lastEquippedTool = equippedWeapon() and equippedWeapon().ToolName or nil
	update()
end

function Controller.Init()
	if initialized then return end
	initialized = true
	if not validId(Config.RunAnimationId) then reportError("RunAnimationId no está configurado")
	else log("ID Sprint normal verificado: " .. Config.RunAnimationId) end
	if not validId(Config.WalkAnimationId) then log("WalkAnimationId pendiente de publicación; Animate conservará su caminata") end
	if not validId(Config.SwordRunAnimationId) then log("SwordRunAnimationId pendiente de publicación; Sprint con Sword usará el Sprint normal") end
	for _, attribute in SPECIAL_MOVEMENT_ATTRIBUTES do
		player:GetAttributeChangedSignal(attribute):Connect(update)
	end
	player:GetAttributeChangedSignal("MovementSprinting"):Connect(update)
	player.CharacterAdded:Connect(attach)
	player.CharacterRemoving:Connect(function(removing)
		if character == removing then disconnectCharacter() end
	end)
	log("Inicializado")
	if player.Character then task.spawn(attach, player.Character) end
end

return Controller
