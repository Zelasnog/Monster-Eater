local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("CombatConfig"))
local player = Players.LocalPlayer
local CombatAnimationController = {}

local initialized = false
local character
local humanoid
local animator
local equippedWeapon
local diedConnection
local loadedTracks = {}
local activeTrack
local activeFadeOutTime = 0.08
local reportedMissing = {}
local incompatibleMovementAttributes = {
	"MovementDashing",
	"MovementSliding",
	"MovementWallrunning",
	"MovementClimbing",
	"MovementClimbBoosting",
	"MovementMantling",
}

local function logMissingOnce(key, message)
	if reportedMissing[key] then
		return
	end
	reportedMissing[key] = true
	if CombatConfig.EnableCombatLogs then
		warn("[CombatAnimationController] " .. message)
	end
end

local function destroyLoadedTracks(fadeOutTime)
	local tracksToDestroy = loadedTracks
	loadedTracks = {}
	activeTrack = nil
	activeFadeOutTime = 0.08
	for _, entry in tracksToDestroy do
		if entry.Track.IsPlaying then
			entry.Track:Stop(fadeOutTime)
		end
		task.delay(fadeOutTime + 0.05, function()
			pcall(function()
				entry.Track:Destroy()
			end)
			if entry.Animation then
				entry.Animation:Destroy()
			end
		end)
	end
end

local function clearCharacter()
	destroyLoadedTracks(0.05)
	if diedConnection then
		diedConnection:Disconnect()
		diedConnection = nil
	end
	character = nil
	humanoid = nil
	animator = nil
	equippedWeapon = nil
end

local function attachCharacter(newCharacter)
	clearCharacter()
	character = newCharacter
	task.spawn(function()
		local newHumanoid = newCharacter:FindFirstChildOfClass("Humanoid") or newCharacter:WaitForChild("Humanoid", 10)
		if character ~= newCharacter or not newHumanoid then
			return
		end

		local newAnimator = newHumanoid:FindFirstChildOfClass("Animator")
		if not newAnimator then
			newAnimator = newHumanoid:WaitForChild("Animator", 10)
		end
		if character ~= newCharacter then
			return
		end

		humanoid = newHumanoid
		animator = newAnimator
		diedConnection = newHumanoid.Died:Connect(function()
			destroyLoadedTracks(0.05)
			equippedWeapon = nil
		end)
	end)
end

local function stopForIncompatibleMovement()
	for _, attributeName in incompatibleMovementAttributes do
		if player:GetAttribute(attributeName) == true then
			destroyLoadedTracks(0.06)
			return
		end
	end
end

local function getAnimationIdStatus(spec)
	if not spec then
		return nil, "AnimationConfigMissing"
	end
	if typeof(spec.AnimationId) ~= "string" or spec.AnimationId == "" then
		return nil, "AnimationIdNotConfigured"
	end
	if not string.match(spec.AnimationId, "^rbxassetid://%d+$") then
		return nil, "InvalidAnimationIdFormat"
	end
	return spec.AnimationId, nil
end

local function loadTrack(weaponName, animationKey, spec)
	local cacheKey = weaponName .. "/" .. animationKey
	local cached = loadedTracks[cacheKey]
	if cached then
		return cached, nil
	end
	local animationId, idError = getAnimationIdStatus(spec)
	if not animationId then
		return nil, idError
	end
	if not animator or not animator.Parent then
		return nil, "AnimatorUnavailable"
	end

	local animation = Instance.new("Animation")
	animation.Name = string.gsub(weaponName .. "_" .. animationKey, "[^%w_]", "_")
	animation.AnimationId = animationId
	local ok, trackOrError = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	if not ok then
		animation:Destroy()
		return nil, "LoadAnimationFailed: " .. tostring(trackOrError)
	end

	local track = trackOrError
	track.Name = animation.Name
	track.Priority = spec.Priority or Enum.AnimationPriority.Action
	track.Looped = false
	local entry = { Track = track, Animation = animation }
	loadedTracks[cacheKey] = entry
	return entry, nil
end

local function playTrack(entry, spec)
	if activeTrack and activeTrack ~= entry.Track and activeTrack.IsPlaying then
		activeTrack:Stop(activeFadeOutTime)
	elseif entry.Track.IsPlaying then
		entry.Track:Stop(spec.FadeOutTime or 0.08)
	end

	entry.Track:Play(spec.FadeInTime or 0.08, 1, spec.Speed or 1)
	activeTrack = entry.Track
	activeFadeOutTime = spec.FadeOutTime or 0.08
	return true
end

local function animationPath(weaponName, section, key)
	return string.format("%s.%s.%s", weaponName, section, tostring(key))
end

local function getPlaybackTarget(payload)
	local weaponName = payload.WeaponName
	local weaponAnimations = CombatConfig.AnimationsByWeapon[weaponName]
	if not weaponAnimations then
		return {
			Requested = animationPath(weaponName, "Attacks", payload.Input),
			Reason = "WeaponAnimationConfigMissing",
		}
	end

	if payload.FinisherExecuted and payload.ComboName then
		local finisherSpec = weaponAnimations.Finishers and weaponAnimations.Finishers[payload.ComboName]
		local finisherPath = animationPath(weaponName, "Finishers", payload.ComboName)
		local _, finisherIdError = getAnimationIdStatus(finisherSpec)
		local attackSpec = weaponAnimations.Attacks and weaponAnimations.Attacks[payload.Input]
		local attackPath = animationPath(weaponName, "Attacks", payload.Input)
		local _, attackIdError = getAnimationIdStatus(attackSpec)
		if not finisherIdError then
			return {
				Requested = finisherPath,
				PlayPath = finisherPath,
				Spec = finisherSpec,
				FallbackPath = not attackIdError and attackPath or nil,
				FallbackSpec = not attackIdError and attackSpec or nil,
			}
		elseif not attackIdError then
			return {
				Requested = finisherPath,
				PlayPath = attackPath,
				Spec = attackSpec,
				Reason = "Finisher" .. finisherIdError .. "; using attack animation fallback",
			}
		end
		return {
			Requested = finisherPath,
			Reason = "Finisher" .. finisherIdError .. "; attack" .. attackIdError,
		}
	end

	local attackSpec = weaponAnimations.Attacks and weaponAnimations.Attacks[payload.Input]
	local attackPath = animationPath(weaponName, "Attacks", payload.Input)
	return {
		Requested = attackPath,
		PlayPath = attackPath,
		Spec = attackSpec,
	}
end

function CombatAnimationController.Init()
	if initialized then
		return
	end
	initialized = true
	player.CharacterAdded:Connect(attachCharacter)
	for _, attributeName in incompatibleMovementAttributes do
		player:GetAttributeChangedSignal(attributeName):Connect(stopForIncompatibleMovement)
	end
	player.CharacterRemoving:Connect(function(removingCharacter)
		if character == removingCharacter then
			clearCharacter()
		end
	end)
	if player.Character then
		attachCharacter(player.Character)
	end
end

function CombatAnimationController.OnWeaponEquipped(tool)
	if equippedWeapon == tool then
		return
	end
	destroyLoadedTracks(0.08)
	equippedWeapon = tool
end

function CombatAnimationController.OnWeaponUnequipped(tool)
	if equippedWeapon == tool then
		equippedWeapon = nil
		destroyLoadedTracks(0.08)
	end
end

function CombatAnimationController.PlayConfirmedAttack(payload)
	local target = getPlaybackTarget(payload)
	local result = {
		Requested = target.Requested or "—",
		Played = "—",
		Reason = target.Reason,
	}
	if not target.Spec then
		result.Reason = target.Reason or "AnimationConfigMissing"
		logMissingOnce(result.Requested .. ":" .. result.Reason, result.Requested .. " no se reprodujo: " .. result.Reason)
		return result
	end
	if not character or character ~= player.Character or not humanoid or humanoid.Health <= 0 then
		result.Reason = "CharacterUnavailable"
		return result
	end
	if not equippedWeapon or equippedWeapon.Parent ~= character or equippedWeapon.Name ~= payload.WeaponName then
		result.Reason = "WeaponNotEquipped"
		return result
	end

	local entry, loadError = loadTrack(payload.WeaponName, target.PlayPath, target.Spec)
	local playedPath = target.PlayPath
	if not entry and target.FallbackPath then
		entry, loadError = loadTrack(payload.WeaponName, target.FallbackPath, target.FallbackSpec)
		if entry then
			playedPath = target.FallbackPath
			result.Reason = "FinisherLoadFailed; using attack animation fallback"
		end
	end
	if not entry then
		result.Reason = loadError or target.Reason or "AnimationUnavailable"
		logMissingOnce(result.Requested .. ":" .. result.Reason, result.Requested .. " no se reprodujo: " .. result.Reason)
		return result
	end

	playTrack(entry, target.PlayPath == playedPath and target.Spec or target.FallbackSpec or target.Spec)
	result.Played = playedPath
	return result
end

return CombatAnimationController
