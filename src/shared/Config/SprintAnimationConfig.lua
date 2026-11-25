-- Published IDs must be filled from Roblox Studio; blank IDs stay disabled.
return {
	WalkAnimationId = "rbxassetid://104789365891956",
	RunAnimationId = "rbxassetid://127404678659518",
	SwordRunAnimationId = "rbxassetid://124752628014679",
	Priority = Enum.AnimationPriority.Movement,
	DashAnimationId = "",
	DashPriority = Enum.AnimationPriority.Action,
	WeaponAnimations = {
		{ ToolName = "Sword", Type = "Sword", IdleAnimationId = "" },
		{ ToolName = "SwordAndShield_Prototype", Type = "SwordAndShield", IdleAnimationId = "" },
		{ ToolName = "Greatsword_Prototype", Type = "Greatsword", IdleAnimationId = "" },
	},
	SwordAndShieldCoverAnimationId = "",
	SwordAndShieldCoverPriority = Enum.AnimationPriority.Action,
	FadeTime = 0.12,
}
