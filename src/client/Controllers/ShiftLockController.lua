local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local MovementConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("MovementConfig"))
local movementRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("MovementSprintRequest")
local player = Players.LocalPlayer

local ACTION_NAME = "MonsterEater_ShiftLock"
local RENDER_BINDING = "MonsterEater_ShiftLockFacing"
local ShiftLockController = {}

local initialized = false
local enabled = false
local humanoid
local root
local originalCameraOffset
local originalAutoRotate
local originalMouseIconEnabled

local function restoreCharacter()
	if humanoid and humanoid.Parent then
		if originalCameraOffset then humanoid.CameraOffset = originalCameraOffset end
		if player:GetAttribute("MovementClimbing") == true then
			humanoid.AutoRotate = false
		elseif originalAutoRotate ~= nil then
			humanoid.AutoRotate = originalAutoRotate
		end
	end
	humanoid = nil
	root = nil
	originalCameraOffset = nil
	originalAutoRotate = nil
end

local function attachCharacter(character)
	restoreCharacter()
	if not enabled or not character then return end
	humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 5)
	root = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 5)
	if not humanoid or not root or not enabled then
		humanoid = nil
		root = nil
		return
	end

	originalCameraOffset = humanoid.CameraOffset
	originalAutoRotate = humanoid.AutoRotate
	humanoid.CameraOffset = originalCameraOffset + MovementConfig.ShiftLockCameraOffset
	humanoid.AutoRotate = false
end

local function updateFacing()
	if not enabled then return end
	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	if humanoid and humanoid.Parent then humanoid.AutoRotate = false end
	if not humanoid or not root or not root.Parent then return end
	local isClimbing = player:GetAttribute("MovementClimbing") == true
	local isMantling = player:GetAttribute("MovementMantling") == true
	if isClimbing or isMantling then return end
	local camera = workspace.CurrentCamera
	if not camera then return end
	local look = Vector3.new(camera.CFrame.LookVector.X, 0, camera.CFrame.LookVector.Z)
	if look.Magnitude > 0.01 then
		root.CFrame = CFrame.lookAt(root.Position, root.Position + look.Unit)
	end
end

local function setEnabled(shouldEnable)
	if enabled == shouldEnable then return end
	enabled = shouldEnable
	if enabled then
		originalMouseIconEnabled = UserInputService.MouseIconEnabled
		UserInputService.MouseIconEnabled = false
		movementRemote:FireServer({ Action = "ShiftLock", Enabled = true })
		attachCharacter(player.Character)
		RunService:BindToRenderStep(RENDER_BINDING, Enum.RenderPriority.Camera.Value + 1, updateFacing)
	else
		RunService:UnbindFromRenderStep(RENDER_BINDING)
		restoreCharacter()
		movementRemote:FireServer({ Action = "ShiftLock", Enabled = false })
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = if originalMouseIconEnabled == nil then true else originalMouseIconEnabled
		originalMouseIconEnabled = nil
	end
end

local function handleToggle(_, inputState)
	if inputState == Enum.UserInputState.Begin then
		setEnabled(not enabled)
		return Enum.ContextActionResult.Sink
	end
	return Enum.ContextActionResult.Pass
end

function ShiftLockController.Init()
	if initialized then return end
	initialized = true
	ContextActionService:BindActionAtPriority(ACTION_NAME, handleToggle, false, 3000, Enum.KeyCode.LeftAlt, Enum.KeyCode.RightAlt)
	player.CharacterAdded:Connect(function(character)
		if enabled then
			attachCharacter(character)
			task.spawn(function()
				character:WaitForChild("HumanoidRootPart")
				task.wait()
				if enabled and player.Character == character then
					movementRemote:FireServer({ Action = "ShiftLock", Enabled = true })
				end
			end)
		end
	end)
	player.CharacterRemoving:Connect(function()
		restoreCharacter()
	end)
	print("[ShiftLockController] Shift Lock personalizado inicializado.")
end

return ShiftLockController
