local GameConfig = {
	Name = "Monster Eater",
	Version = "0.1.0",
	Progression = {
		BaseExperience = 100,
		LinearExperience = 25,
		QuadraticExperience = 5,
	},
}

-- XPRequired(level) = Base + Linear * (level - 1) + Quadratic * (level - 1)^2
function GameConfig.GetRequiredExperience(level: number): number
	local step = level - 1
	local progression = GameConfig.Progression

	return progression.BaseExperience
		+ progression.LinearExperience * step
		+ progression.QuadraticExperience * step * step
end

return GameConfig
