-- Services --
local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local CutsceneModule = {}
CutsceneModule.Cutscenes = {}
CutsceneModule.PlayingAnimation = false

export type AdditionalAnimation = {
	Model: Model,
	Animation: Animation
}

export type Options = {
	IncludePlayer: boolean,
	UsePlayerAsCamera: boolean,
	TeleportPart: BasePart?,
	
	CameraRig: Model?,
	CameraAnimation: Animation?,
	PlayerAnimation: Animation?,
	
	AdditionalAnimations: { AdditionalAnimation }?,
	CloneModels: boolean?,
	
	Sound: Sound?,
	
	HideOtherPlayers: boolean?
}

-- Get all instances that we have to preload so the cutscene plays smoothly
local function GetAssetsToPreload(options: Options): { Instance }
	local Assets = {}
	
	local function CheckChildren(instance: Instance)
		for _, child in pairs(instance:GetChildren()) do
			table.insert(Assets, child)
			
			CheckChildren(child)
		end
	end
	
	for _, value in pairs(options) do
		if typeof(value) == "Instance" then
			table.insert(Assets, value)
			
			CheckChildren(value)
		end
	end
	
	return Assets
end

--[=[
	Registers a new cutscene with the name and the options.
]=]
function CutsceneModule.RegisterCutscene(name: string, options: Options)
	-- Checks
	assert(not options.IncludePlayer or options.PlayerAnimation, "When using IncludePlayer, the player animation should be present!")
	
	if options.AdditionalAnimations then
		for _, anim: AdditionalAnimation in ipairs(options.AdditionalAnimations) do
			assert(anim.Model, "You must provide a model for the additional animation!")
		end
	end
	
	if not options.UsePlayerAsCamera then
		assert(options.CameraRig and options.CameraAnimation, "You must have a camera rig and camera animation if not using the player as the camera!")
	end
	
	if options.UsePlayerAsCamera then
		assert(options.IncludePlayer and options.PlayerAnimation, "You must include the player and provide a player animation if using the player as the camera!")
	end
	
	--
	
	local AssetsToPreload = GetAssetsToPreload(options)
	
	ContentProvider:PreloadAsync(AssetsToPreload)
	CutsceneModule.Cutscenes[name] = options
end

--[=[
Plays a cutscene with the name that you used when registering.
]=]
function CutsceneModule.PlayCutscene(name: string)
	assert(not CutsceneModule.PlayingAnimation, "You can't play multiple cutscenes at once.")
	assert(CutsceneModule.Cutscenes[name], "Cutscene has not been registered yet!")
	
	CutsceneModule.PlayingAnimation = true
	
	local options = CutsceneModule.Cutscenes[name]
	local animations: { AnimationTrack } = {}
	local plr = Players.LocalPlayer
	local char = plr.Character or plr.CharacterAdded:Wait()
	local camera = workspace.CurrentCamera
	
	if options.TeleportPart then
		char.HumanoidRootPart.CFrame = options.TeleportPart.CFrame
	end
	
	if options.IncludePlayer then
		local thingToPlayAnimWith = char:FindFirstChildWhichIsA("Humanoid") or char:FindFirstChildWhichIsA("AnimationController")
		local track: AnimationTrack = thingToPlayAnimWith:LoadAnimation(options.PlayerAnimation)
		track.Looped = false
		track.Priority = Enum.AnimationPriority.Action4

		table.insert(animations, 
			track
		)
	end
	
	if not options.UsePlayerAsCamera then
		local thingToPlayAnimWith = options.CameraRig:FindFirstChildWhichIsA("Humanoid") or options.CameraRig:FindFirstChildWhichIsA("AnimationController")
		local track: AnimationTrack = thingToPlayAnimWith:LoadAnimation(options.CameraAnimation)
		track.Looped = false
		track.Priority = Enum.AnimationPriority.Action4

		table.insert(animations, 
			track
		)
	end
	
	local models = {}
	local ogParents = {}
	
	if options.AdditionalAnimations then
		for _, anim: AdditionalAnimation in pairs(options.AdditionalAnimations) do
			local model = if options.CloneModels then anim.Model:Clone() else anim.Model
			
			if anim.Animation then
				local thingToPlayAnimWith = model:FindFirstChildWhichIsA("Humanoid") or model:FindFirstChildWhichIsA("AnimationController")
				local track: AnimationTrack = thingToPlayAnimWith:LoadAnimation(anim.Animation)
				track.Looped = false
				track.Priority = Enum.AnimationPriority.Action4

				table.insert(animations, 
					track
				)
			end
			
			if not options.CloneModels then
				ogParents[model] = model.Parent
			end
			
			model.Parent = game.Workspace
			
			table.insert(models, model)
		end
	end
	
	local CompletedAnimations = 0
	
	-- Remove accessories
	local accessoryHolder
	
	if options.UsePlayerAsCamera then
		accessoryHolder = Instance.new("Folder")
		
		for _, child in pairs(char:GetChildren()) do
			if child:IsA("Accessory") then
				child.Parent = accessoryHolder
			end
		end
	end
	
	if options.HideOtherPlayers then
		for _, plr in Players:GetPlayers() do
			if plr == Players.LocalPlayer then continue end
			
			local char = plr.Character
			if not char then continue end
			
			for _, desc in pairs(char:GetDescendants()) do
				if desc:IsA("BasePart") then
					desc.Transparency = 1
				end
			end
		end
	end
	
	char.HumanoidRootPart.Anchored = true
	
	-- Preload the animations
	for _, animation: AnimationTrack in pairs(animations) do
		ContentProvider:PreloadAsync({animation})
	end
	
	-- Play the animations
	for _, animation: AnimationTrack in pairs(animations) do
		animation:Play()
		
		animation.Ended:Once(function()
			CompletedAnimations += 1
		end)
	end
	
	-- Play the sound
	if options.Sound then
		options.Sound:Play()
	end
	
	-- Set the camera
	local originalSubject = camera.CameraSubject
	
	repeat
		task.wait() camera.CameraType = Enum.CameraType.Custom
	until camera.CameraType == Enum.CameraType.Custom
	
	local con
	
	if options.UsePlayerAsCamera then
		camera.CameraSubject = char.Head
		
		-- Update camera every frame
		con = RunService.PreRender:Connect(function()
			camera.CFrame = char.Head.CFrame
			
			for _, child in pairs(char:GetChildren()) do
				if child:IsA("BasePart") then
					child.LocalTransparencyModifier = 0
				end
			end
		end)
	else
		local part = options.CameraRig.PrimaryPart
		camera.CameraSubject = part
		
		-- Update camera every frame
		con = RunService.PreRender:Connect(function()
			camera.CFrame = part.CFrame
			
			for _, child in pairs(char:GetChildren()) do
				if child:IsA("BasePart") then
					child.LocalTransparencyModifier = 0
				end
			end
		end)
	end
	
	repeat task.wait() until CompletedAnimations == #animations
	
	-- Restore everything
	
	con:Disconnect()
	camera.CameraSubject = originalSubject
	char.HumanoidRootPart.Anchored = false
	CutsceneModule.PlayingAnimation = false
	
	if options.Sound then
		options.Sound:Stop()
	end
	
	if accessoryHolder then
		for _, child in pairs(accessoryHolder:GetChildren()) do
			if child:IsA("Accessory") then
				child.Parent = char
			end
		end
	end
	
	if options.CloneModels then
		for _, model in pairs(models) do
			model:Destroy()
		end
	else
		for model, parent in pairs(ogParents) do
			model.Parent = parent
		end
	end
	
	if options.HideOtherPlayers then
		for _, plr in Players:GetPlayers() do
			if plr == Players.LocalPlayer then continue end

			local char = plr.Character
			if not char then continue end

			for _, desc in pairs(char:GetDescendants()) do
				if desc:IsA("BasePart") then
					if desc.Name == "HumanoidRootPart" then continue end
					
					desc.Transparency = 0
				end
			end
		end
	end
end

return CutsceneModule
