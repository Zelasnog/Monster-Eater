local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local MovementConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("MovementConfig"))
local sprintRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("MovementSprintRequest")
local player = Players.LocalPlayer

local ACTION_NAME = "MonsterEater_Sprint"
local DASH_ACTION_NAME = "MonsterEater_Dash"
local SLIDE_ACTION_NAME = "MonsterEater_Slide"
local WALLJUMP_ACTION_NAME = "MonsterEater_WallJump"
local CLIMB_ACTION_NAME = "MonsterEater_ClimbToggle"
local CLIMBBOOST_ACTION_NAME = "MonsterEater_ClimbBoost"
local MovementController = {}
local bound = false
local requestedSprint = false
local dashRequested = false
local slideRequested = false
local climbKeys = { W = false, A = false, S = false, D = false }
local function sendClimbDirection()
	if player:GetAttribute("MovementClimbing") ~= true then return end
	local x = (climbKeys.D and 1 or 0) - (climbKeys.A and 1 or 0)
	local y = (climbKeys.W and 1 or 0) - (climbKeys.S and 1 or 0)
	local direction = Vector2.new(x, y)
	if direction.Magnitude > 1 then direction = direction.Unit end
	sprintRemote:FireServer({ Action = "ClimbMove", Direction = direction })
end

local climbKeyMap = {
	[Enum.KeyCode.W] = "W",
	[Enum.KeyCode.A] = "A",
	[Enum.KeyCode.S] = "S",
	[Enum.KeyCode.D] = "D",
}

local function handleClimbToggle(_, inputState)
	if inputState == Enum.UserInputState.Begin then
		sprintRemote:FireServer({ Action = "ClimbToggle" })
		return Enum.ContextActionResult.Sink
	end
	return Enum.ContextActionResult.Pass
end

local function handleClimbBoost(_, inputState)
	if inputState == Enum.UserInputState.Begin and player:GetAttribute("MovementClimbing") == true then
		sprintRemote:FireServer({ Action = "ClimbBoost" })
		return Enum.ContextActionResult.Sink
	end
	return Enum.ContextActionResult.Pass
end

local function handleWallJump(_, inputState)
	if inputState == Enum.UserInputState.Begin and player:GetAttribute("MovementWallrunning") == true then
		sprintRemote:FireServer({ Action = "WallJump" })
		return Enum.ContextActionResult.Sink
	end
	return Enum.ContextActionResult.Pass
end

local function handleSlide(_, inputState)
	if inputState == Enum.UserInputState.Begin and not slideRequested then
		slideRequested = true
		sprintRemote:FireServer({ Action = "Slide" })
	elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
		slideRequested = false
	end
	return Enum.ContextActionResult.Pass
end

local function canRequestSprint()
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

local function handleSprint(_, inputState)
	if inputState == Enum.UserInputState.Begin then
		if canRequestSprint() and not requestedSprint then
			requestedSprint = true
			sprintRemote:FireServer(true)
		end
	elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
		if requestedSprint then
			requestedSprint = false
			sprintRemote:FireServer(false)
		end
	end
	return Enum.ContextActionResult.Pass
end

local function getDashDirection()
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root then
		return nil
	end

	local direction = humanoid.MoveDirection
	direction = Vector3.new(direction.X, 0, direction.Z)
	if direction.Magnitude < 0.05 then
		direction = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
	end
	if direction.Magnitude < 0.05 then
		return nil
	end
	return direction.Unit
end

local function handleDash(_, inputState)
	if inputState == Enum.UserInputState.Begin and not dashRequested then
		local direction = getDashDirection()
		if direction then
			dashRequested = true
			sprintRemote:FireServer({ Action = "Dash", Direction = direction })
		end
	elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
		dashRequested = false
	end
	return Enum.ContextActionResult.Pass
end

function MovementController.Init()
	if bound then
		return
	end
	bound = true
	ContextActionService:BindAction(ACTION_NAME, handleSprint, false, MovementConfig.SprintKey)
	ContextActionService:BindAction(DASH_ACTION_NAME, handleDash, false, MovementConfig.DashKey)
	ContextActionService:BindAction(SLIDE_ACTION_NAME, handleSlide, false, Enum.KeyCode.LeftControl, Enum.KeyCode.RightControl)
	ContextActionService:BindActionAtPriority(WALLJUMP_ACTION_NAME, handleWallJump, false, 3000, Enum.KeyCode.Space)
	ContextActionService:BindAction(CLIMB_ACTION_NAME, handleClimbToggle, false, Enum.KeyCode.E)
	ContextActionService:BindActionAtPriority(CLIMBBOOST_ACTION_NAME, handleClimbBoost, false, 3000, Enum.KeyCode.Space)
	-- SprintAnimationController owns locomotion and server-confirmed Dash presentation.
	player:GetAttributeChangedSignal("MovementClimbing"):Connect(function()
		sendClimbDirection()
	end)
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		local key = climbKeyMap[input.KeyCode]
		if key and not gameProcessed then
			climbKeys[key] = true
			sendClimbDirection()
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		local key = climbKeyMap[input.KeyCode]
		if key then
			climbKeys[key] = false
			sendClimbDirection()
		end
	end)
	player.CharacterAdded:Connect(function()
		dashRequested = false
		slideRequested = false
		for key in climbKeys do climbKeys[key] = false end
		if requestedSprint then
			requestedSprint = false
			sprintRemote:FireServer(false)
		end
	end)
	player.CharacterRemoving:Connect(function()
		dashRequested = false
		slideRequested = false
		for key in climbKeys do climbKeys[key] = false end
		if requestedSprint then
			requestedSprint = false
			sprintRemote:FireServer(false)
		end
	end)
	print("[MovementController] Controles de movilidad inicializados.")
end

return MovementController
