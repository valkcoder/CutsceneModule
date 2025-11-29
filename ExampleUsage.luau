local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CutsceneModule = require(ReplicatedStorage.CutsceneModule)

CutsceneModule.RegisterCutscene("Push", {
	IncludePlayer = true,
	UsePlayerAsCamera = false,

	CameraRig = game.Workspace.Cam,
	TeleportPart = game.Workspace.Cam:WaitForChild("HumanoidRootPart"),
	CameraAnimation = ReplicatedStorage.CamAnim,
	PlayerAnimation = ReplicatedStorage.Animation,

	AdditionalAnimations = {
		{
			Model = workspace.Player2,
			Animation = ReplicatedStorage.Player2Anim
		}
	},

	CloneModels = false,
	HideOtherPlayers = true
})

UserInputService.InputBegan:Connect(function(input, gpe)
	if gpe then return end
	
	if input.KeyCode == Enum.KeyCode.E then
		CutsceneModule.PlayCutscene("Push")
	end
end)
