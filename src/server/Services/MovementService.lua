local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local MovementConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("MovementConfig"))

local REMOTE_NAME = "MovementSprintRequest"
local SPRINT_ATTRIBUTE = "MovementSprinting"
local STATE_ATTRIBUTE = "MovementState"
local DASHING_ATTRIBUTE = "MovementDashing"
local SLIDING_ATTRIBUTE = "MovementSliding"
local WALLRUNNING_ATTRIBUTE = "MovementWallrunning"
local CLIMBING_ATTRIBUTE = "MovementClimbing"
local CLIMB_BOOST_ATTRIBUTE = "MovementClimbBoosting"
local MANTLING_ATTRIBUTE = "MovementMantling"
local PROTECTION_ATTRIBUTE = "MovementInvulnerable"
local MovementService = {}

local states = {}
local initialized = false
local stopWallrun
local stopClimb
local stopMantle

local function hasStandingClearance(player, record, targetHipHeight, targetRootSize)
	local character = player.Character
	local root = record.root
	if not character or not root or not root.Parent or record.humanoid.FloorMaterial == Enum.Material.Air then
		return false
	end

	local hipHeightNeeded = targetHipHeight - record.humanoid.HipHeight
	local rootHeightNeeded = targetRootSize.Y - root.Size.Y
	local heightNeeded = math.max(hipHeightNeeded, rootHeightNeeded)
	if heightNeeded <= 0.05 then
		return true
	end

	local boxCFrame, boxSize = character:GetBoundingBox()
	local boxTop = boxCFrame.Position.Y + boxSize.Y * 0.5
	local clearanceCFrame = CFrame.new(boxCFrame.Position.X, boxTop + heightNeeded * 0.5, boxCFrame.Position.Z)
	local clearanceSize = Vector3.new(
		math.max(root.Size.X, boxSize.X * 0.65),
		heightNeeded + 0.1,
		math.max(root.Size.Z, boxSize.Z * 0.65)
	)
	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = { character }
	overlapParams.RespectCanCollide = true
	return #Workspace:GetPartBoundsInBox(clearanceCFrame, clearanceSize, overlapParams) == 0
end

local function tryRestoreHipHeight(player, record)
	local pending = record.pendingSlideRestoration
	if pending and hasStandingClearance(player, record, pending.HipHeight, pending.RootSize) then
		record.humanoid.HipHeight = pending.HipHeight
		record.root.Size = pending.RootSize
		record.pendingSlideRestoration = nil
	end
end

local function canSprint(humanoid)
	if not humanoid or humanoid.Health <= 0 then
		return false
	end

	local state = humanoid:GetState()
	return state ~= Enum.HumanoidStateType.Dead
		and state ~= Enum.HumanoidStateType.Seated
		and state ~= Enum.HumanoidStateType.Swimming
		and state ~= Enum.HumanoidStateType.Climbing
		and state ~= Enum.HumanoidStateType.Physics
		and state ~= Enum.HumanoidStateType.PlatformStanding
end

local function publishStamina(player, record)
	record.stamina = math.clamp(record.stamina, 0, MovementConfig.MaxStamina)
	local displayedStamina = math.floor(record.stamina)
	if player:GetAttribute("Stamina") ~= displayedStamina then
		player:SetAttribute("Stamina", displayedStamina)
	end
	if player:GetAttribute("MaxStamina") ~= MovementConfig.MaxStamina then
		player:SetAttribute("MaxStamina", MovementConfig.MaxStamina)
	end
end

local function stopDash(player, record)
	local dash = record.dash
	if not dash then
		return
	end

	record.dash = nil
	if dash.velocityConstraint then
		dash.velocityConstraint:Destroy()
	end
	if dash.attachment then
		dash.attachment:Destroy()
	end
	player:SetAttribute(DASHING_ATTRIBUTE, false)
	player:SetAttribute(PROTECTION_ATTRIBUTE, false)
	if player:GetAttribute(STATE_ATTRIBUTE) == "Dodge" then
		local state = record.humanoid:GetState()
		if state == Enum.HumanoidStateType.Running or state == Enum.HumanoidStateType.RunningNoPhysics then
			player:SetAttribute(STATE_ATTRIBUTE, "Run")
		elseif state == Enum.HumanoidStateType.Freefall then
			player:SetAttribute(STATE_ATTRIBUTE, "Freefall")
		elseif state == Enum.HumanoidStateType.Dead then
			player:SetAttribute(STATE_ATTRIBUTE, "Dead")
		else
			player:SetAttribute(STATE_ATTRIBUTE, "Idle")
		end
	end
end

local function stopSlide(player, record, forceRestore)
	local slide = record.slide
	if not slide then
		return
	end

	record.slide = nil
	if slide.velocityConstraint then
		slide.velocityConstraint:Destroy()
	end
	if slide.attachment then
		slide.attachment:Destroy()
	end
	player:SetAttribute(SLIDING_ATTRIBUTE, false)
	record.slideCooldownUntil = os.clock() + MovementConfig.SlideRecovery

	if forceRestore or record.humanoid.Health <= 0 then
		record.humanoid.HipHeight = slide.originalHipHeight
		record.root.Size = slide.originalRootSize
		record.pendingSlideRestoration = nil
	elseif hasStandingClearance(player, record, slide.originalHipHeight, slide.originalRootSize) then
		record.humanoid.HipHeight = slide.originalHipHeight
		record.root.Size = slide.originalRootSize
		record.pendingSlideRestoration = nil
	else
		-- Stay low and mobile under a ceiling; restore height as soon as the space clears.
		record.pendingSlideRestoration = {
			HipHeight = slide.originalHipHeight,
			RootSize = slide.originalRootSize,
		}
	end

	local state = record.humanoid:GetState()
	if state == Enum.HumanoidStateType.Running or state == Enum.HumanoidStateType.RunningNoPhysics then
		player:SetAttribute(STATE_ATTRIBUTE, "Run")
	elseif state == Enum.HumanoidStateType.Freefall then
		player:SetAttribute(STATE_ATTRIBUTE, "Freefall")
	elseif state == Enum.HumanoidStateType.Dead then
		player:SetAttribute(STATE_ATTRIBUTE, "Dead")
	else
		player:SetAttribute(STATE_ATTRIBUTE, "Idle")
	end
end

stopWallrun = function(player, record, stateAfter)
	local wallrun = record.wallrun
	if not wallrun then return end
	record.wallrun = nil
	if wallrun.velocityConstraint then wallrun.velocityConstraint:Destroy() end
	if wallrun.attachment then wallrun.attachment:Destroy() end
	player:SetAttribute(WALLRUNNING_ATTRIBUTE, false)
	player:SetAttribute("MovementWallrunSide", nil)
	if player:GetAttribute(STATE_ATTRIBUTE) == "Wallrun" then
		local humanoidState = record.humanoid:GetState()
		if stateAfter then
			player:SetAttribute(STATE_ATTRIBUTE, stateAfter)
		elseif humanoidState == Enum.HumanoidStateType.Dead then
			player:SetAttribute(STATE_ATTRIBUTE, "Dead")
		elseif humanoidState == Enum.HumanoidStateType.Freefall then
			player:SetAttribute(STATE_ATTRIBUTE, "Freefall")
		else
			player:SetAttribute(STATE_ATTRIBUTE, "Idle")
		end
	end
end

stopClimb = function(player, record, stateAfter)
	local climb = record.climb
	if not climb then return end
	record.climb = nil
	if climb.velocityConstraint then climb.velocityConstraint:Destroy() end
	if climb.orientationConstraint then climb.orientationConstraint:Destroy() end
	if climb.attachment then climb.attachment:Destroy() end
	player:SetAttribute(CLIMB_BOOST_ATTRIBUTE, false)
	if record.humanoid and record.humanoid.Parent then
		if record.shiftLockEnabled then
			record.humanoid.AutoRotate = false
		else
			record.humanoid.AutoRotate = climb.originalAutoRotate
		end
	end
	player:SetAttribute(CLIMBING_ATTRIBUTE, false)
	player:SetAttribute("MovementClimbSurface", nil)
	if player:GetAttribute(STATE_ATTRIBUTE) == "Climb" or player:GetAttribute(STATE_ATTRIBUTE) == "ClimbBoost" then
		if stateAfter then
			player:SetAttribute(STATE_ATTRIBUTE, stateAfter)
		elseif record.humanoid.Health <= 0 then
			player:SetAttribute(STATE_ATTRIBUTE, "Dead")
		else
			player:SetAttribute(STATE_ATTRIBUTE, "Freefall")
			record.humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
		end
	end
end

stopMantle = function(player, record, stateAfter)
	local mantle = record.mantle
	if not mantle then return end
	record.mantle = nil
	if mantle.positionConstraint then mantle.positionConstraint:Destroy() end
	if mantle.orientationConstraint then mantle.orientationConstraint:Destroy() end
	if mantle.attachment then mantle.attachment:Destroy() end
	local root = mantle.root
	if mantle.networkOwnershipChanged and root and root.Parent then
		pcall(function() root:SetNetworkOwnershipAuto() end)
	end
	if record.humanoid and record.humanoid.Parent then
		if record.shiftLockEnabled then
			record.humanoid.AutoRotate = false
		else
			record.humanoid.AutoRotate = mantle.originalAutoRotate
		end
	end
	player:SetAttribute(MANTLING_ATTRIBUTE, false)
	if player:GetAttribute(STATE_ATTRIBUTE) == "Mantle" then
		if stateAfter then
			player:SetAttribute(STATE_ATTRIBUTE, stateAfter)
			if stateAfter == "Run" and record.humanoid.Health > 0 then
				record.humanoid:ChangeState(Enum.HumanoidStateType.Running)
			end
		elseif record.humanoid.Health <= 0 then
			player:SetAttribute(STATE_ATTRIBUTE, "Dead")
		else
			player:SetAttribute(STATE_ATTRIBUTE, "Freefall")
			record.humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
		end
	end
end

local function setSprint(player, requested)
	local record = states[player]
	if not record then
		return
	end

	local allowed = requested == true and not record.dash and not record.slide and not record.wallrun and not record.climb and not record.mantle and canSprint(record.humanoid)
	if record.sprinting == allowed then
		return
	end

	record.sprinting = allowed
	player:SetAttribute(SPRINT_ATTRIBUTE, allowed)
end

local function setShiftLock(player, requested)
	local record = states[player]
	if not record or typeof(requested) ~= "boolean" then return end
	if requested then
		if not record.shiftLockEnabled then
			record.shiftLockOriginalAutoRotate = record.defaultAutoRotate
		end
		record.shiftLockEnabled = true
		record.humanoid.AutoRotate = false
	else
		record.shiftLockEnabled = false
		if record.climb or record.mantle then
			record.humanoid.AutoRotate = false
		elseif record.shiftLockOriginalAutoRotate ~= nil then
			record.humanoid.AutoRotate = record.shiftLockOriginalAutoRotate
		else
			record.humanoid.AutoRotate = record.defaultAutoRotate
		end
		record.shiftLockOriginalAutoRotate = nil
	end
end

local function setMovementState(player, humanoid, newState)
	local record = states[player]
	if record and (record.dash or record.slide or record.wallrun or record.climb or record.mantle) then
		return
	end

	if humanoid.Health <= 0 then
		player:SetAttribute(STATE_ATTRIBUTE, "Dead")
	elseif newState == Enum.HumanoidStateType.Jumping then
		player:SetAttribute(STATE_ATTRIBUTE, "Jump")
	elseif newState == Enum.HumanoidStateType.Freefall then
		player:SetAttribute(STATE_ATTRIBUTE, "Freefall")
	elseif newState == Enum.HumanoidStateType.Landed then
		player:SetAttribute(STATE_ATTRIBUTE, "Land")
	elseif newState == Enum.HumanoidStateType.Running or newState == Enum.HumanoidStateType.RunningNoPhysics then
		player:SetAttribute(STATE_ATTRIBUTE, "Run")
	elseif newState == Enum.HumanoidStateType.Seated or newState == Enum.HumanoidStateType.GettingUp then
		player:SetAttribute(STATE_ATTRIBUTE, "Idle")
	end

	if not canSprint(humanoid) then
		setSprint(player, false)
	end
	if newState == Enum.HumanoidStateType.Jumping and record and record.dash then
		stopDash(player, record)
	end
	if newState == Enum.HumanoidStateType.Jumping and record and record.slide then
		stopSlide(player, record, false)
	end
end

local function onCharacterAdded(player, character)
	local previous = states[player]
	local stamina = previous and previous.stamina or player:GetAttribute("Stamina") or MovementConfig.MaxStamina
	local cooldownUntil = previous and previous.cooldownUntil or 0
	local slideCooldownUntil = previous and previous.slideCooldownUntil or 0
	local lastStaminaUse = previous and previous.lastStaminaUse or 0
	if previous then
		stopDash(player, previous)
		stopSlide(player, previous, true)
		stopWallrun(player, previous, "Idle")
		stopClimb(player, previous, "Idle")
		stopMantle(player, previous, "Idle")
		if previous.pendingSlideRestoration then
			previous.humanoid.HipHeight = previous.pendingSlideRestoration.HipHeight
			previous.root.Size = previous.pendingSlideRestoration.RootSize
		end
		for _, connection in previous.connections do
			connection:Disconnect()
		end
	end

	local humanoid = character:WaitForChild("Humanoid")
	local root = character:WaitForChild("HumanoidRootPart")
	if player.Parent ~= Players or player.Character ~= character then
		return
	end

	local record = {
		humanoid = humanoid,
		root = root,
		sprinting = false,
		dash = nil,
		slide = nil,
		wallrun = nil,
		wallrunCooldownUntil = 0,
		wallrunRaycastParams = RaycastParams.new(),
		climb = nil,
		climbBoostCooldownUntil = 0,
		mantle = nil,
		climbDirection = Vector2.zero,
		climbRaycastParams = RaycastParams.new(),
		shiftLockEnabled = false,
		shiftLockOriginalAutoRotate = nil,
		defaultAutoRotate = humanoid.AutoRotate,
		stamina = stamina,
		cooldownUntil = cooldownUntil,
		slideCooldownUntil = slideCooldownUntil,
		lastStaminaUse = lastStaminaUse,
		pendingSlideRestoration = nil,
		connections = {},
	}
	states[player] = record
	record.wallrunRaycastParams.FilterType = Enum.RaycastFilterType.Exclude
	record.wallrunRaycastParams.FilterDescendantsInstances = { character }
	record.wallrunRaycastParams.RespectCanCollide = true
	record.climbRaycastParams.FilterType = Enum.RaycastFilterType.Exclude
	record.climbRaycastParams.FilterDescendantsInstances = { character }
	record.climbRaycastParams.RespectCanCollide = true
	humanoid.UseJumpPower = MovementConfig.UseJumpPower
	humanoid.JumpPower = MovementConfig.JumpPower
	humanoid.WalkSpeed = MovementConfig.WalkSpeed
	player:SetAttribute(SPRINT_ATTRIBUTE, false)
	player:SetAttribute(STATE_ATTRIBUTE, "Idle")
	player:SetAttribute(DASHING_ATTRIBUTE, false)
	player:SetAttribute(SLIDING_ATTRIBUTE, false)
	player:SetAttribute(WALLRUNNING_ATTRIBUTE, false)
	player:SetAttribute(CLIMBING_ATTRIBUTE, false)
	player:SetAttribute(CLIMB_BOOST_ATTRIBUTE, false)
	player:SetAttribute(MANTLING_ATTRIBUTE, false)
	player:SetAttribute(PROTECTION_ATTRIBUTE, false)
	publishStamina(player, record)

	table.insert(record.connections, humanoid.StateChanged:Connect(function(_, newState)
		setMovementState(player, humanoid, newState)
	end))
	table.insert(record.connections, humanoid.Died:Connect(function()
		setSprint(player, false)
		stopDash(player, record)
		stopSlide(player, record, true)
		stopWallrun(player, record, "Dead")
		stopClimb(player, record, "Dead")
		stopMantle(player, record, "Dead")
		if record.pendingSlideRestoration then
			humanoid.HipHeight = record.pendingSlideRestoration.HipHeight
			root.Size = record.pendingSlideRestoration.RootSize
			record.pendingSlideRestoration = nil
		end
		player:SetAttribute(STATE_ATTRIBUTE, "Dead")
	end))
end

local function onPlayerAdded(player)
	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)
	if player.Character then
		task.spawn(onCharacterAdded, player, player.Character)
	end
end

local function onPlayerRemoving(player)
	local record = states[player]
	if record then
		stopDash(player, record)
		stopSlide(player, record, true)
		stopWallrun(player, record, "Dead")
		stopClimb(player, record, "Dead")
		stopMantle(player, record, "Dead")
		if record.pendingSlideRestoration then
			record.humanoid.HipHeight = record.pendingSlideRestoration.HipHeight
			record.root.Size = record.pendingSlideRestoration.RootSize
		end
		for _, connection in record.connections do
			connection:Disconnect()
		end
	end
	states[player] = nil
end

local function isGrounded(record)
	local humanoid = record.humanoid
	local state = humanoid:GetState()
	return humanoid.Health > 0
		and humanoid.FloorMaterial ~= Enum.Material.Air
		and (state == Enum.HumanoidStateType.Running
			or state == Enum.HumanoidStateType.RunningNoPhysics
			or state == Enum.HumanoidStateType.Landed)
end

local function parseDirection(value)
	if typeof(value) ~= "Vector3" then
		return nil
	end
	if value.X ~= value.X or value.Z ~= value.Z or math.abs(value.X) == math.huge or math.abs(value.Z) == math.huge then
		return nil
	end
	local horizontal = Vector3.new(value.X, 0, value.Z)
	local magnitude = horizontal.Magnitude
	if magnitude < 0.5 or magnitude > 1.5 then
		return nil
	end
	return horizontal.Unit
end

local function isTaggedWall(instance)
	local current = instance
	while current and current ~= Workspace do
		if CollectionService:HasTag(current, MovementConfig.WallrunTag) then
			return true
		end
		current = current.Parent
	end
	return false
end

local function findWall(record, side)
	local root = record.root
	local right = Vector3.new(root.CFrame.RightVector.X, 0, root.CFrame.RightVector.Z)
	if right.Magnitude < 0.01 then return nil end
	local direction = right.Unit * side
	local result = Workspace:Raycast(root.Position, direction * MovementConfig.WallrunDetectionDistance, record.wallrunRaycastParams)
	if not result or not isTaggedWall(result.Instance) or math.abs(result.Normal.Y) > 0.2 then
		return nil
	end
	return result, result.Normal, direction
end

local function getWallrunCandidate(record)
	local humanoid = record.humanoid
	local moveInput = humanoid.MoveDirection
	moveInput = Vector3.new(moveInput.X, 0, moveInput.Z)
	local velocity = record.root.AssemblyLinearVelocity
	local horizontalVelocity = Vector3.new(velocity.X, 0, velocity.Z)
	local move = moveInput
	if move.Magnitude * humanoid.WalkSpeed < MovementConfig.WallrunMinimumMoveSpeed then
		move = horizontalVelocity.Magnitude >= MovementConfig.WallrunMinimumMoveSpeed and horizontalVelocity.Unit or Vector3.zero
	end
	if move.Magnitude < 0.1 then
		return nil
	end
	local firstSide = move:Dot(record.root.CFrame.RightVector) >= 0 and 1 or -1
	for _, side in ipairs({ firstSide, -firstSide }) do
		local hit, normal = findWall(record, side)
		if hit then
			local tangent = normal:Cross(Vector3.yAxis).Unit
			if tangent:Dot(move) < 0 then tangent = -tangent end
			if tangent:Dot(move) > 0.2 then
				return hit, side, tangent
			end
		end
	end
	return nil
end

local function startWallrun(player, record, hit, side, tangent, now)
	local root = record.root
	local attachment = Instance.new("Attachment")
	attachment.Name = "MovementWallrunAttachment"
	attachment.Parent = root
	local velocity = Instance.new("LinearVelocity")
	velocity.Name = "MovementWallrunVelocity"
	velocity.Attachment0 = attachment
	velocity.RelativeTo = Enum.ActuatorRelativeTo.World
	velocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	velocity.VectorVelocity = tangent * MovementConfig.WallrunSpeed + Vector3.yAxis * MovementConfig.WallrunVerticalSpeed
	velocity.ForceLimitsEnabled = true
	velocity.ForceLimitMode = Enum.ForceLimitMode.Magnitude
	velocity.MaxForce = math.max(root.AssemblyMass * Workspace.Gravity * 5, 1000)
	velocity.Parent = root
	record.wallrun = {
		startedAt = now,
		endsAt = now + MovementConfig.WallrunDuration,
		side = side,
		wall = hit.Instance,
		normal = hit.Normal,
		tangent = tangent,
		attachment = attachment,
		velocityConstraint = velocity,
	}
	record.sprinting = false
	player:SetAttribute(SPRINT_ATTRIBUTE, false)
	player:SetAttribute(WALLRUNNING_ATTRIBUTE, true)
	player:SetAttribute("MovementWallrunSide", side == -1 and "Left" or "Right")
	player:SetAttribute(STATE_ATTRIBUTE, "Wallrun")
end

local function requestWallJump(player)
	local record = states[player]
	local wallrun = record and record.wallrun
	if not wallrun or record.humanoid.Health <= 0 then return end
	local root = record.root
	local away = Vector3.new(wallrun.normal.X, 0, wallrun.normal.Z)
	if away.Magnitude < 0.1 then return end
	stopWallrun(player, record, "WallJump")
	record.wallrunCooldownUntil = os.clock() + MovementConfig.WallrunReentryDelay
	local current = root.AssemblyLinearVelocity
	root.AssemblyLinearVelocity = Vector3.new(
		current.X + away.Unit.X * MovementConfig.WallrunWallJumpOutSpeed,
		math.max(current.Y, MovementConfig.WallrunWallJumpUpSpeed),
		current.Z + away.Unit.Z * MovementConfig.WallrunWallJumpOutSpeed
	)
	record.humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
end

local function updateWallrun(player, record, now)
	local wallrun = record.wallrun
	if not wallrun then return end
	local humanoid = record.humanoid
	if humanoid.Health <= 0 or now >= wallrun.endsAt or record.stamina <= 0 then
		stopWallrun(player, record)
		return
	end
	local hit = findWall(record, wallrun.side)
	if not hit then
		stopWallrun(player, record)
		return
	end
	wallrun.normal = hit.Normal
	local tangent = hit.Normal:Cross(Vector3.yAxis).Unit
	if tangent:Dot(wallrun.tangent) < 0 then tangent = -tangent end
	wallrun.tangent = tangent
	wallrun.velocityConstraint.VectorVelocity = tangent * MovementConfig.WallrunSpeed + Vector3.yAxis * MovementConfig.WallrunVerticalSpeed
	local deltaTime = math.max(0, now - (wallrun.lastUpdate or now))
	wallrun.lastUpdate = now
	record.stamina = math.max(0, record.stamina - MovementConfig.WallrunStaminaPerSecond * deltaTime)
	record.lastStaminaUse = now
	publishStamina(player, record)
end

local function isClimbable(instance)
	local current = instance
	while current and current ~= Workspace do
		if CollectionService:HasTag(current, MovementConfig.ClimbTag) then return true end
		current = current.Parent
	end
	return false
end

local function findClimbSurface(record, normal, originOffset)
	local root = record.root
	local direction
	if normal then
		direction = -normal
	else
		direction = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
		if direction.Magnitude < 0.1 then return nil end
		direction = direction.Unit
	end
	local origin = root.Position + (originOffset or Vector3.zero)
	local result = Workspace:Raycast(origin, direction * MovementConfig.ClimbDetectionDistance, record.climbRaycastParams)
	if not result or not isClimbable(result.Instance) or math.abs(result.Normal.Y) > 0.2 then return nil end
	if not normal and direction:Dot(-result.Normal) < 0.35 then return nil end
	if normal and result.Normal:Dot(normal) < 0.55 then return nil end
	if result.Distance > MovementConfig.ClimbSurfaceDistance + MovementConfig.ClimbSurfaceTolerance then return nil end
	return result
end

local function startClimb(player, record, hit)
	local root = record.root
	local attachment = Instance.new("Attachment")
	attachment.Name = "MovementClimbAttachment"
	attachment.Parent = root
	local velocity = Instance.new("LinearVelocity")
	velocity.Name = "MovementClimbVelocity"
	velocity.Attachment0 = attachment
	velocity.RelativeTo = Enum.ActuatorRelativeTo.World
	velocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	velocity.VectorVelocity = Vector3.zero
	velocity.ForceLimitsEnabled = true
	velocity.ForceLimitMode = Enum.ForceLimitMode.Magnitude
	velocity.MaxForce = math.max(root.AssemblyMass * Workspace.Gravity * 8, 1500)
	velocity.Parent = root
	local orientation = Instance.new("AlignOrientation")
	orientation.Name = "MovementClimbOrientation"
	orientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
	orientation.Attachment0 = attachment
	orientation.Responsiveness = 25
	orientation.MaxTorque = math.max(root.AssemblyMass * Workspace.Gravity * 8, 1500)
	orientation.CFrame = CFrame.lookAt(root.Position, root.Position - hit.Normal).Rotation
	orientation.Parent = root
	local humanoid = record.humanoid
	local originalAutoRotate = humanoid.AutoRotate
	if record.shiftLockEnabled and record.shiftLockOriginalAutoRotate ~= nil then
		originalAutoRotate = record.shiftLockOriginalAutoRotate
	end
	record.climb = {
		wall = hit.Instance,
		normal = hit.Normal,
		attachment = attachment,
		velocityConstraint = velocity,
		orientationConstraint = orientation,
		originalAutoRotate = originalAutoRotate,
	}
	record.climbDirection = Vector2.zero
	record.sprinting = false
	player:SetAttribute(SPRINT_ATTRIBUTE, false)
	humanoid.AutoRotate = false
	humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	player:SetAttribute(CLIMBING_ATTRIBUTE, true)
	player:SetAttribute(CLIMB_BOOST_ATTRIBUTE, false)
	player:SetAttribute("MovementClimbSurface", hit.Instance:GetFullName())
	player:SetAttribute(STATE_ATTRIBUTE, "Climb")
end

local function toggleClimb(player)
	local record = states[player]
	if not record or record.humanoid.Health <= 0 then return end
	if record.climb then
		stopClimb(player, record)
		return
	end
	if record.dash or record.slide or record.wallrun or record.mantle
		or record.stamina < MovementConfig.ClimbMinimumStamina
		or not canSprint(record.humanoid)
	then
		return
	end
	local hit = findClimbSurface(record)
	if hit then startClimb(player, record, hit) end
end

local function parseClimbDirection(value)
	if typeof(value) ~= "Vector2" or value.X ~= value.X or value.Y ~= value.Y
		or math.abs(value.X) == math.huge or math.abs(value.Y) == math.huge
	then
		return nil
	end
	local direction = Vector2.new(math.clamp(value.X, -1, 1), math.clamp(value.Y, -1, 1))
	if direction.Magnitude > 1 then direction = direction.Unit end
	return direction
end

local function hasMantleClearance(player, record, landingPart, targetCFrame)
	local character = player.Character
	if not character then return false end
	local boundsCFrame, boundsSize = character:GetBoundingBox()
	local boundsOffset = record.root.CFrame:PointToObjectSpace(boundsCFrame.Position)
	local targetBoundsCenter = targetCFrame:PointToWorldSpace(boundsOffset) + Vector3.yAxis * 0.08
	local clearanceSize = Vector3.new(
		math.max(1.5, boundsSize.X * 0.85),
		math.max(2, boundsSize.Y * 0.85),
		math.max(1.5, boundsSize.Z * 0.85)
	)
	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = { character, landingPart }
	overlapParams.RespectCanCollide = true
	return #Workspace:GetPartBoundsInBox(CFrame.new(targetBoundsCenter) * targetCFrame.Rotation, clearanceSize, overlapParams) == 0
end

local function hasMantlePathClearance(record, normal, startPosition, targetPosition)
	local root = record.root
	local castSize = Vector3.new(
		root.Size.X * 1.2,
		root.Size.Y * 1.1,
		root.Size.Z * 1.2
	)
	local params = record.climbRaycastParams
	local arc = Vector3.yAxis * MovementConfig.ClimbMantleArcHeight
	local points = {
		startPosition + arc,
		targetPosition + arc,
	}
	local previous = startPosition
	local facing = CFrame.lookAt(startPosition, startPosition - normal)
	for _, point in ipairs(points) do
		local displacement = point - previous
		if displacement.Magnitude > 0.05 and Workspace:Blockcast(facing, castSize, displacement, params) then
			return false
		end
		previous = point
	end
	return true
end

local function tryStartMantle(player, record, normal, wallContact, now)
	local climb = record.climb
	if not climb or record.mantle or record.stamina < MovementConfig.ClimbMantleStaminaCost then return false end
	local root = record.root
	local character = player.Character
	if not character then return false end
	local wallProbe = Workspace:Raycast(
		root.Position + Vector3.yAxis * MovementConfig.ClimbMantleWallProbeHeight,
		-normal * MovementConfig.ClimbDetectionDistance,
		record.climbRaycastParams
	)
	if wallProbe then return false end
	local support = wallContact or findClimbSurface(record, normal, -Vector3.yAxis * 1.25)
	if not support or not isClimbable(support.Instance) or support.Normal:Dot(normal) < 0.55 then return false end
	local forward = Vector3.new(-normal.X, 0, -normal.Z)
	if forward.Magnitude < 0.1 then return false end
	forward = forward.Unit
	local landingOrigin = root.Position
		+ forward * MovementConfig.ClimbMantleForwardDistance
		+ Vector3.yAxis * MovementConfig.ClimbMantleLandingProbeHeight
	local landing = Workspace:Raycast(
		landingOrigin,
		-Vector3.yAxis * MovementConfig.ClimbMantleLandingRayLength,
		record.climbRaycastParams
	)
	if not landing or landing.Normal.Y < 0.7 or not landing.Instance.CanCollide then return false end
	local boundsCFrame, boundsSize = character:GetBoundingBox()
	local rootToFeet = root.Position.Y - (boundsCFrame.Position.Y - boundsSize.Y * 0.5)
	local targetPosition = Vector3.new(
		landing.Position.X,
		landing.Position.Y + rootToFeet + MovementConfig.ClimbMantleStandClearance,
		landing.Position.Z
	)
	local rise = targetPosition.Y - root.Position.Y
	if rise < MovementConfig.ClimbMantleMinRise or rise > MovementConfig.ClimbMantleMaxRise then return false end
	local targetCFrame = CFrame.lookAt(targetPosition, targetPosition + forward)
	if not hasMantleClearance(player, record, landing.Instance, targetCFrame) then return false end
	if not hasMantlePathClearance(record, normal, root.Position, targetPosition) then return false end

	local attachment = Instance.new("Attachment")
	attachment.Name = "MovementMantleAttachment"
	attachment.Parent = root
	local position = Instance.new("AlignPosition")
	position.Name = "MovementMantlePosition"
	position.Mode = Enum.PositionAlignmentMode.OneAttachment
	position.Attachment0 = attachment
	position.Position = root.Position
	position.ApplyAtCenterOfMass = true
	position.RigidityEnabled = false
	position.ForceLimitMode = Enum.ForceLimitMode.Magnitude
	position.MaxForce = math.max(root.AssemblyMass * Workspace.Gravity * 12, 2000)
	position.MaxVelocity = MovementConfig.ClimbMantleMaxVelocity
	position.Responsiveness = MovementConfig.ClimbMantleResponsiveness
	position.Parent = root
	local orientation = Instance.new("AlignOrientation")
	orientation.Name = "MovementMantleOrientation"
	orientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
	orientation.Attachment0 = attachment
	orientation.CFrame = targetCFrame.Rotation
	orientation.MaxTorque = math.max(root.AssemblyMass * Workspace.Gravity * 10, 2000)
	orientation.Responsiveness = MovementConfig.ClimbMantleResponsiveness
	orientation.Parent = root

	local networkOwnershipChanged = pcall(function() root:SetNetworkOwner(nil) end)

	local climbOriginalAutoRotate = climb.originalAutoRotate
	player:SetAttribute(MANTLING_ATTRIBUTE, true)
	stopClimb(player, record, "Mantle")
	record.mantle = {
		startedAt = now,
		duration = MovementConfig.ClimbMantleDuration,
		root = root,
		startPosition = root.Position,
		targetPosition = targetPosition,
		targetCFrame = targetCFrame,
		normal = normal,
		attachment = attachment,
		positionConstraint = position,
		orientationConstraint = orientation,
		originalAutoRotate = climbOriginalAutoRotate,
		networkOwnershipChanged = networkOwnershipChanged,
	}
	record.stamina -= MovementConfig.ClimbMantleStaminaCost
	record.lastStaminaUse = now
	record.humanoid.AutoRotate = false
	record.humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	player:SetAttribute(MANTLING_ATTRIBUTE, true)
	player:SetAttribute(STATE_ATTRIBUTE, "Mantle")
	publishStamina(player, record)
	return true
end

local function updateMantle(player, record, now)
	local mantle = record.mantle
	if not mantle then return end
	if record.humanoid.Health <= 0 or not mantle.root or not mantle.root.Parent then
		stopMantle(player, record, "Dead")
		return
	end
	local rawAlpha = math.clamp((now - mantle.startedAt) / mantle.duration, 0, 1)
	local alpha = rawAlpha * rawAlpha * (3 - 2 * rawAlpha)
	local inverse = 1 - alpha
	local arc = Vector3.yAxis * MovementConfig.ClimbMantleArcHeight
	local point = mantle.startPosition * (inverse ^ 3)
		+ (mantle.startPosition + arc) * (3 * inverse * inverse * alpha)
		+ (mantle.targetPosition + arc) * (3 * inverse * alpha * alpha)
		+ mantle.targetPosition * (alpha ^ 3)
	mantle.positionConstraint.Position = point
	mantle.orientationConstraint.CFrame = mantle.targetCFrame.Rotation
	local offset = mantle.root.Position - mantle.targetPosition
	local horizontalDistance = Vector2.new(offset.X, offset.Z).Magnitude
	local arrived = horizontalDistance <= MovementConfig.ClimbMantleArrivalHorizontalTolerance
		and math.abs(offset.Y) <= MovementConfig.ClimbMantleArrivalVerticalTolerance
	if alpha >= 1 and arrived then
		stopMantle(player, record, "Run")
	elseif now - mantle.startedAt >= mantle.duration + MovementConfig.ClimbMantleSettleTimeout then
		stopMantle(player, record)
	end
end

local function requestClimbBoost(player)
	local record = states[player]
	local climb = record and record.climb
	if not climb or record.humanoid.Health <= 0 or record.mantle then return end
	local now = os.clock()
	local minimumCost = MovementConfig.ClimbBoostStaminaCost
		+ MovementConfig.ClimbMinimumStamina
		+ MovementConfig.ClimbStaminaPerSecond * (MovementConfig.ClimbBoostDuration + 0.1)
	if now < record.climbBoostCooldownUntil or climb.boostEndsAt or record.stamina < minimumCost then return end
	record.stamina -= MovementConfig.ClimbBoostStaminaCost
	record.lastStaminaUse = now
	climb.boostEndsAt = now + MovementConfig.ClimbBoostDuration
	record.climbBoostCooldownUntil = now + MovementConfig.ClimbBoostCooldown
	player:SetAttribute(CLIMB_BOOST_ATTRIBUTE, true)
	player:SetAttribute(STATE_ATTRIBUTE, "ClimbBoost")
	publishStamina(player, record)
end

local function updateClimb(player, record, deltaTime)
	local climb = record.climb
	if not climb then return end
	local now = os.clock()
	if record.humanoid.Health <= 0 or record.stamina < MovementConfig.ClimbMinimumStamina then
		stopClimb(player, record)
		return
	end
	local hit = findClimbSurface(record, climb.normal)
	if not hit then
		hit = findClimbSurface(record, climb.normal, -Vector3.yAxis * 1.25)
	end
	if not hit then
		stopClimb(player, record)
		return
	end
	if tryStartMantle(player, record, hit.Normal, hit, now) then return end
	climb.normal = hit.Normal
	climb.wall = hit.Instance
	climb.orientationConstraint.CFrame = CFrame.lookAt(record.root.Position, record.root.Position - hit.Normal).Rotation
	local input = record.climbDirection
	local up = Vector3.yAxis
	local tangent = up:Cross(hit.Normal).Unit
	local x, y = input.X, input.Y
	if math.abs(x) > 0.01 or math.abs(y) > 0.01 then
		local probe = record.root.Position + tangent * x * 0.7 + up * y * 0.7
		local pathHit = Workspace:Raycast(probe, -hit.Normal * MovementConfig.ClimbDetectionDistance, record.climbRaycastParams)
		if not pathHit
			or pathHit.Distance > MovementConfig.ClimbSurfaceDistance + MovementConfig.ClimbSurfaceTolerance
			or not isClimbable(pathHit.Instance)
			or math.abs(pathHit.Normal.Y) > 0.2
			or pathHit.Normal:Dot(hit.Normal) < 0.55
		then
			x, y = 0, 0
		end
	end
	local distanceError = hit.Distance - MovementConfig.ClimbSurfaceDistance
	local correctionSpeed = math.clamp(distanceError * 2, -6, 6)
	if climb.boostEndsAt and now < climb.boostEndsAt then
		climb.velocityConstraint.VectorVelocity = up * MovementConfig.ClimbBoostVerticalSpeed - hit.Normal * correctionSpeed
	else
		if climb.boostEndsAt then
			climb.boostEndsAt = nil
			player:SetAttribute(CLIMB_BOOST_ATTRIBUTE, false)
			player:SetAttribute(STATE_ATTRIBUTE, "Climb")
		end
		climb.velocityConstraint.VectorVelocity = tangent * x * MovementConfig.ClimbSpeed
			+ up * y * MovementConfig.ClimbSpeed
			- hit.Normal * correctionSpeed
	end
	record.stamina = math.max(0, record.stamina - MovementConfig.ClimbStaminaPerSecond * deltaTime)
	record.lastStaminaUse = now
	publishStamina(player, record)
end

local function requestDash(player, requestedDirection)
	local record = states[player]
	if not record or record.dash or record.slide or record.wallrun or record.climb or record.mantle or not isGrounded(record) then
		return
	end

	local now = os.clock()
	if now < record.cooldownUntil or record.stamina < MovementConfig.DashStaminaCost then
		return
	end

	local direction = parseDirection(requestedDirection)
	if not direction then
		return
	end

	local character = player.Character
	local root = record.root
	if not character or not root.Parent or not root:IsDescendantOf(character) then
		return
	end

	local attachment = Instance.new("Attachment")
	attachment.Name = "MovementDashAttachment"
	attachment.Parent = root

	local velocityConstraint = Instance.new("LinearVelocity")
	velocityConstraint.Name = "MovementDashVelocity"
	velocityConstraint.Attachment0 = attachment
	velocityConstraint.RelativeTo = Enum.ActuatorRelativeTo.World
	velocityConstraint.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
	velocityConstraint.PrimaryTangentAxis = Vector3.xAxis
	velocityConstraint.SecondaryTangentAxis = Vector3.zAxis
	velocityConstraint.ForceLimitsEnabled = false
	velocityConstraint.PlaneVelocity = Vector2.new(
		direction.X * MovementConfig.DashSpeed,
		direction.Z * MovementConfig.DashSpeed
	)
	velocityConstraint.Parent = root

	record.stamina -= MovementConfig.DashStaminaCost
	record.lastStaminaUse = now
	record.cooldownUntil = now + MovementConfig.DashDuration + MovementConfig.DashRecovery
	setSprint(player, false)
	record.dash = {
		direction = direction,
		startedAt = now,
		endsAt = now + MovementConfig.DashDuration,
		root = root,
		attachment = attachment,
		velocityConstraint = velocityConstraint,
		wallCheckParams = nil,
	}
	local wallCheckParams = RaycastParams.new()
	wallCheckParams.FilterType = Enum.RaycastFilterType.Exclude
	wallCheckParams.FilterDescendantsInstances = { character }
	wallCheckParams.RespectCanCollide = true
	record.dash.wallCheckParams = wallCheckParams
	player:SetAttribute(DASHING_ATTRIBUTE, true)
	player:SetAttribute(PROTECTION_ATTRIBUTE, true)
	player:SetAttribute(STATE_ATTRIBUTE, "Dodge")
	publishStamina(player, record)
end

local function requestSlide(player)
	local record = states[player]
	if not record or record.dash or record.slide or record.wallrun or record.climb or record.mantle or not isGrounded(record) then
		return
	end
	if record.pendingSlideRestoration then
		tryRestoreHipHeight(player, record)
		if record.pendingSlideRestoration then
			return
		end
	end

	local now = os.clock()
	if now < record.slideCooldownUntil or record.stamina < MovementConfig.SlideStaminaCost then
		return
	end

	local character = player.Character
	local humanoid = record.humanoid
	local root = record.root
	if not character or not root.Parent or not root:IsDescendantOf(character) then
		return
	end

	local currentVelocity = root.AssemblyLinearVelocity
	local horizontalVelocity = Vector3.new(currentVelocity.X, 0, currentVelocity.Z)
	local startSpeed = horizontalVelocity.Magnitude
	local speedLimit = math.min(MovementConfig.SlideMaximumStartSpeed, math.max(MovementConfig.SlideMinimumSpeed, humanoid.WalkSpeed + 4))
	if startSpeed < MovementConfig.SlideMinimumSpeed or startSpeed > speedLimit then
		return
	end

	local direction = horizontalVelocity.Unit
	local originalHipHeight = humanoid.HipHeight
	local originalRootSize = root.Size
	local reducedHipHeight = math.max(0, originalHipHeight - MovementConfig.SlideHipHeightReduction)
	local rootHeightReduction = originalHipHeight - reducedHipHeight < 0.05
		and MovementConfig.SlideHipHeightReduction
		or 0
	local reducedRootSize = Vector3.new(
		originalRootSize.X,
		math.max(1, originalRootSize.Y - rootHeightReduction),
		originalRootSize.Z
	)
	if originalHipHeight - reducedHipHeight < 0.05 and originalRootSize.Y - reducedRootSize.Y < 0.05 then
		return
	end

	local attachment = Instance.new("Attachment")
	attachment.Name = "MovementSlideAttachment"
	attachment.Parent = root

	local velocityConstraint = Instance.new("LinearVelocity")
	velocityConstraint.Name = "MovementSlideVelocity"
	velocityConstraint.Attachment0 = attachment
	velocityConstraint.RelativeTo = Enum.ActuatorRelativeTo.World
	velocityConstraint.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
	velocityConstraint.PrimaryTangentAxis = Vector3.xAxis
	velocityConstraint.SecondaryTangentAxis = Vector3.zAxis
	velocityConstraint.ForceLimitsEnabled = false
	velocityConstraint.PlaneVelocity = Vector2.new(direction.X * startSpeed, direction.Z * startSpeed)
	velocityConstraint.Parent = root

	local wallCheckParams = RaycastParams.new()
	wallCheckParams.FilterType = Enum.RaycastFilterType.Exclude
	wallCheckParams.FilterDescendantsInstances = { character }
	wallCheckParams.RespectCanCollide = true

	record.stamina -= MovementConfig.SlideStaminaCost
	record.lastStaminaUse = now
	record.sprinting = false
	player:SetAttribute(SPRINT_ATTRIBUTE, false)
	humanoid.HipHeight = reducedHipHeight
	root.Size = reducedRootSize
	record.slide = {
		startedAt = now,
		endsAt = now + MovementConfig.SlideDuration,
		direction = direction,
		initialSpeed = math.min(startSpeed, MovementConfig.SlideMaximumStartSpeed),
		originalHipHeight = originalHipHeight,
		originalRootSize = originalRootSize,
		attachment = attachment,
		velocityConstraint = velocityConstraint,
		wallCheckParams = wallCheckParams,
	}
	player:SetAttribute(SLIDING_ATTRIBUTE, true)
	player:SetAttribute(STATE_ATTRIBUTE, "Slide")
	publishStamina(player, record)
end

local function onActionRequest(player, request)
	-- Retain the original sprint request format alongside validated movement actions.
	if typeof(request) == "boolean" then
		setSprint(player, request)
		return
	end
	if typeof(request) ~= "table" then
		return
	end
	if request.Action == "Sprint" and typeof(request.Enabled) == "boolean" then
		setSprint(player, request.Enabled)
	elseif request.Action == "Dash" then
		requestDash(player, request.Direction)
	elseif request.Action == "Slide" then
		requestSlide(player)
	elseif request.Action == "WallJump" then
		requestWallJump(player)
	elseif request.Action == "ClimbToggle" then
		toggleClimb(player)
	elseif request.Action == "ClimbBoost" then
		requestClimbBoost(player)
	elseif request.Action == "ClimbMove" then
		local record = states[player]
		local direction = parseClimbDirection(request.Direction)
		if record and record.climb and direction then
			record.climbDirection = direction
		end
	elseif request.Action == "ShiftLock" and typeof(request.Enabled) == "boolean" then
		setShiftLock(player, request.Enabled)
	end
end

local function updateDash(player, record, deltaTime, now)
	local dash = record.dash
	if not dash then
		return
	end

	local humanoid = record.humanoid
	local root = dash.root
	if humanoid.Health <= 0 or not root.Parent or now >= dash.endsAt then
		stopDash(player, record)
		return
	end

	if humanoid:GetState() == Enum.HumanoidStateType.Jumping then
		stopDash(player, record)
		return
	end

	local supportDistance = humanoid.HipHeight + root.Size.Y + 1
	local ground = Workspace:Raycast(root.Position, Vector3.new(0, -supportDistance, 0), dash.wallCheckParams)
	if not ground then
		stopDash(player, record)
		return
	end

	local elapsed = now - dash.startedAt
	local exitStart = math.max(0, MovementConfig.DashDuration - MovementConfig.DashExitDuration)
	local exitAlpha = math.clamp((elapsed - exitStart) / math.max(MovementConfig.DashExitDuration, 0.001), 0, 1)
	local targetSpeed = MovementConfig.DashSpeed + (MovementConfig.WalkSpeed - MovementConfig.DashSpeed) * exitAlpha
	local displacement = dash.direction * targetSpeed * deltaTime
	local result = Workspace:Blockcast(root.CFrame, root.Size * Vector3.new(0.8, 0.85, 0.8), displacement, dash.wallCheckParams)
	if result then
		stopDash(player, record)
		return
	end

	dash.velocityConstraint.PlaneVelocity = Vector2.new(
		dash.direction.X * targetSpeed,
		dash.direction.Z * targetSpeed
	)
end

local function updateSlide(player, record, now, deltaTime)
	local slide = record.slide
	if not slide then
		return
	end

	local humanoid = record.humanoid
	local root = record.root
	if humanoid.Health <= 0 or not root.Parent or now >= slide.endsAt then
		stopSlide(player, record, false)
		return
	end
	if humanoid:GetState() == Enum.HumanoidStateType.Jumping then
		stopSlide(player, record, false)
		return
	end

	local supportDistance = humanoid.HipHeight + root.Size.Y + 1
	local ground = Workspace:Raycast(root.Position, Vector3.new(0, -supportDistance, 0), slide.wallCheckParams)
	if not ground then
		stopSlide(player, record, false)
		return
	end

	local elapsed = now - slide.startedAt
	local targetSpeed = math.max(MovementConfig.SlideEndSpeed, slide.initialSpeed - MovementConfig.SlideDeceleration * elapsed)
	local displacement = slide.direction * targetSpeed * deltaTime
	local obstacle = Workspace:Blockcast(root.CFrame, root.Size * Vector3.new(0.8, 0.85, 0.8), displacement, slide.wallCheckParams)
	if obstacle then
		stopSlide(player, record, false)
		return
	end

	slide.velocityConstraint.PlaneVelocity = Vector2.new(
		slide.direction.X * targetSpeed,
		slide.direction.Z * targetSpeed
	)
end

function MovementService.Init()
	if initialized then
		warn("[MovementService] Init ya estaba activo.")
		return
	end
	initialized = true

	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotes then
		remotes = Instance.new("Folder")
		remotes.Name = "Remotes"
		remotes.Parent = ReplicatedStorage
	end

	local actionRemote = remotes:FindFirstChild(REMOTE_NAME)
	if actionRemote and not actionRemote:IsA("RemoteEvent") then
		error(string.format("ReplicatedStorage.Remotes.%s existe y no es RemoteEvent", REMOTE_NAME))
	end
	if not actionRemote then
		actionRemote = Instance.new("RemoteEvent")
		actionRemote.Name = REMOTE_NAME
		actionRemote.Parent = remotes
	end

	actionRemote.OnServerEvent:Connect(onActionRequest)
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end

	RunService.Heartbeat:Connect(function(deltaTime)
		local now = os.clock()
		for player, record in states do
			local humanoid = record.humanoid
			if humanoid.Parent and humanoid.Health > 0 then
				if record.dash then
					updateDash(player, record, deltaTime, now)
				elseif record.slide then
					updateSlide(player, record, now, deltaTime)
				elseif record.wallrun then
					updateWallrun(player, record, now)
				elseif record.climb then
					updateClimb(player, record, deltaTime)
				elseif record.mantle then
					updateMantle(player, record, now)
				else
					local state = humanoid:GetState()
					if now >= record.wallrunCooldownUntil
						and record.stamina > 0
						and humanoid.FloorMaterial == Enum.Material.Air
						and (state == Enum.HumanoidStateType.Freefall or state == Enum.HumanoidStateType.Jumping)
					then
						local hit, side, tangent = getWallrunCandidate(record)
						if hit then startWallrun(player, record, hit, side, tangent, now) end
					end
					local targetSpeed = record.sprinting and canSprint(humanoid) and MovementConfig.SprintSpeed or MovementConfig.WalkSpeed
					local rate = targetSpeed > humanoid.WalkSpeed and MovementConfig.Acceleration or MovementConfig.Deceleration
					local difference = targetSpeed - humanoid.WalkSpeed
					local step = rate * deltaTime
					if math.abs(difference) <= step then
						humanoid.WalkSpeed = targetSpeed
					elseif difference > 0 then
						humanoid.WalkSpeed += step
					else
						humanoid.WalkSpeed -= step
					end
				end
				if not record.slide and record.pendingSlideRestoration then
					tryRestoreHipHeight(player, record)
				end

				if not record.dash
					and not record.slide
					and not record.wallrun
					and not record.climb
					and not record.mantle
					and now - record.lastStaminaUse >= MovementConfig.StaminaRegenerationDelay
					and record.stamina < MovementConfig.MaxStamina
				then
					record.stamina += MovementConfig.StaminaRegeneration * deltaTime
					publishStamina(player, record)
				end
			elseif record.dash then
				stopDash(player, record)
			end
		end
	end)

	print("[MovementService] Inicializado.")
end

return MovementService
