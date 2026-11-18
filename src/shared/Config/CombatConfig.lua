return {
	Damage = 20,
	Cooldown = 0.6,
	Range = 7,
	MaxTargetsPerAttack = 1,
	RequestInterval = 0.1,
	HitboxWidth = 5,
	HitboxHeight = 5,
	ComboWindow = 1,
	MaxRecentInputs = 8,
	EnableDebugHUD = true,
	EnableCombatLogs = true,
	DebugToggleKey = Enum.KeyCode.P,
	LogRepeatInterval = 1,
	AnimationsByWeapon = {
		Sword = {
			Attacks = {
				L = {
					AnimationId = "",
					Priority = Enum.AnimationPriority.Action,
					FadeInTime = 0.08,
					FadeOutTime = 0.08,
					Speed = 1,
				},
				RC = {
					AnimationId = "",
					Priority = Enum.AnimationPriority.Action,
					FadeInTime = 0.08,
					FadeOutTime = 0.08,
					Speed = 1,
				},
			},
			Finishers = {
				["Combo A"] = {
					AnimationId = "",
					Priority = Enum.AnimationPriority.Action,
					FadeInTime = 0.08,
					FadeOutTime = 0.08,
					Speed = 1,
				},
				["Combo B"] = {
					AnimationId = "",
					Priority = Enum.AnimationPriority.Action,
					FadeInTime = 0.08,
					FadeOutTime = 0.08,
					Speed = 1,
				},
			},
		},
	},
	CombosByWeapon = {
		Sword = {
			{
				Name = "Combo A",
				Sequence = { "L", "RC", "L", "RC", "L" },
			},
			{
				Name = "Combo B",
				Sequence = { "RC", "RC", "L", "RC", "L", "RC" },
			},
		},
	},
}
