-- Services --
local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local CutsceneModule = {}
CutsceneModule.Cutscenes = {}
CutsceneModule.PlayingAnimation = false

-- Types for intellisense
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



-- Collect every instance that should be preloaded.
-- This ensures all models, animations, and sounds are ready before the cutscene starts
-- so playback is smooth and nothing loads mid-animation.
local function GetAssetsToPreload(options: Options): { Instance }
	local Assets = {}

	-- Recursively check all descendants of an instance so they also get preloaded.
	local function CheckChildren(instance: Instance)
		for _, child in pairs(instance:GetChildren()) do
			table.insert(Assets, child)

			CheckChildren(child)
		end
	end

	-- Loop through every value in the options and get anything that is an instance.
	-- This includes animations, rigs, sounds, models, etc.
	for _, value in pairs(options) do
		if typeof(value) == "Instance" then
			table.insert(Assets, value)

			CheckChildren(value)
		end
	end

	return Assets
end



-- Grab the humanoid or animation controller inside a model. Both types work.
-- The cutscene system requires a model that can play animations.
local function GetAnimator(model: Model): Humanoid | AnimationController
	local humanoid = model:FindFirstChildWhichIsA("Humanoid")
	if humanoid then
		return humanoid
	end

	local controller = model:FindFirstChildWhichIsA("AnimationController")
	assert(controller, "Model needs a Humanoid or AnimationController to play animations.")

	return controller
end



-- Load animation tracks
local function LoadTrackForModel(model: Model, animation: Animation): AnimationTrack
	local animator = GetAnimator(model)
	local track: AnimationTrack = animator:LoadAnimation(animation)

	track.Looped = false
	track.Priority = Enum.AnimationPriority.Action4 -- high priority so it visually overrides everything

	return track
end



-- Temporarily remove player accessories so the camera view isn't blocked when
-- the player becomes the camera model. It does this by reparenting all of the
-- player's accessories into a new folder
local function RemoveAccessories(character: Model): Folder?
	local holder = Instance.new("Folder")
	holder.Name = "AccessoryHolder"

	local hasAccessories = false

	for _, child in pairs(character:GetChildren()) do
		if child:IsA("Accessory") then
			child.Parent = holder
			hasAccessories = true
		end
	end

	if not hasAccessories then
		holder:Destroy()
		return nil
	end

	return holder
end



-- Restore accessories that were previously removed.
-- Must be done so the character returns to normal after the cutscene.
local function RestoreAccessories(character: Model, holder: Folder?)
	if not holder then
		return
	end
	
	-- Reparent the accessories from accessoryHolder to character
	for _, child in pairs(holder:GetChildren()) do
		if child:IsA("Accessory") then
			child.Parent = character
		end
	end

	holder:Destroy()
end



-- When requested, hide all other players by making their character parts transparent.
local function SetOtherPlayersHidden(hidden: boolean)
	local localPlayer = Players.LocalPlayer

	for _, plr in Players:GetPlayers() do
		if plr == localPlayer then
			continue
		end

		local char = plr.Character
		if not char then
			continue
		end
		
		-- Loop through all of character's descendants and make them invisible or visible		
		for _, desc in pairs(char:GetDescendants()) do
			if desc:IsA("BasePart") then

				-- Skip past HRP
				if desc.Name == "HumanoidRootPart" then
					continue
				end

				desc.Transparency = hidden and 1 or 0
			end
		end
	end
end



-- Construct all animations used in the cutscene.
-- This includes:
-- - Player animation
-- - Camera rig animation
-- - Any additional animated models
-- It also clones models if requested and prepares them for playback.
local function BuildAnimationsAndModels(options: Options, char: Model)
	local animations: { AnimationTrack } = {}
	local models = {}
	local ogParents = {}

	-- Teleport character before the cutscene if needed
	if options.TeleportPart then
		char.HumanoidRootPart.CFrame = options.TeleportPart.CFrame
	end

	-- Player animation track
	if options.IncludePlayer and options.PlayerAnimation then
		local track = LoadTrackForModel(char, options.PlayerAnimation)
		table.insert(animations, track)
	end

	-- Camera rig animation
	if (not options.UsePlayerAsCamera) and options.CameraRig and options.CameraAnimation then
		local track = LoadTrackForModel(options.CameraRig, options.CameraAnimation)
		table.insert(animations, track)
	end

	-- Extra model animations
	if options.AdditionalAnimations then
		for _, anim: AdditionalAnimation in pairs(options.AdditionalAnimations) do

			-- Clone or reuse model depending on what was passed
			local model = if options.CloneModels then anim.Model:Clone() else anim.Model

			-- Load animation if provided
			if anim.Animation then
				local track = LoadTrackForModel(model, anim.Animation)
				table.insert(animations, track)
			end

			-- If model is reused, save its original parent so we can restore later
			if not options.CloneModels then
				ogParents[model] = model.Parent
			end

			model.Parent = workspace

			table.insert(models, model)
		end
	end

	return animations, models, ogParents
end



-- Preload animations right before they play. It uses ContentProvider.
-- This is so the animations dont start too late caused by them not being loaded.
local function PreloadTracks(tracks: { AnimationTrack })
	for _, animation: AnimationTrack in pairs(tracks) do
		ContentProvider:PreloadAsync({ animation })
	end
end



-- Start all animations and wait until every animation finishes.
local function PlayTracksAndWait(tracks: { AnimationTrack })
	local count = #tracks
	if count == 0 then
		return
	end

	local completed = 0

	-- Connect .Ended connections first, then play, so we don't miss events
	for _, animation: AnimationTrack in pairs(tracks) do
		animation.Ended:Once(function()
			completed += 1
		end)
	end

	for _, animation: AnimationTrack in pairs(tracks) do
		animation:Play()
	end

	-- Wait for all animations to fire Ended
	repeat
		task.wait()
	until completed == count
end



-- Start a camera override loop that moves the camera every PreRender
local function SetupCameraLoop(options: Options, char: Model, camera: Camera)
	local subjectPart

	-- Determine which part the camera should follow:
	-- - Player's head
	-- - Or the camera rig's primary part
	if options.UsePlayerAsCamera then
		subjectPart = char:FindFirstChild("Head")
	else
		if options.CameraRig then
			subjectPart = options.CameraRig.PrimaryPart
		end
	end

	-- If no valid subject, cutscene continues but camera stays normal
	if not subjectPart then
		return nil
	end
	
	camera.CameraSubject = subjectPart

	-- Force the camera CFrame each PreRender
	local con = RunService.PreRender:Connect(function()
		camera.CameraType = Enum.CameraType.Custom
		camera.CFrame = subjectPart.CFrame

		-- Ensure player stays fully visible to themselves
		for _, child in pairs(char:GetChildren()) do
			if child:IsA("BasePart") then
				child.LocalTransparencyModifier = 0
			end
		end
	end)

	return con
end



-- Restore all models to their original state.
-- If they were cloned, destroy them, and if reused, restore their original parent.
local function CleanupModels(models, ogParents, cloneModels: boolean?)
	if cloneModels then
		for _, model in pairs(models) do
			model:Destroy()
		end
	else
		for model, parent in pairs(ogParents) do
			model.Parent = parent
		end
	end
end



--[=[
	Register a new cutscene with the provided name and options.
	This validates the structure and preloads all assets beforehand.
]=]
function CutsceneModule.RegisterCutscene(name: string, options: Options)
	-- Check animation logic so users don't register invalid cutscenes
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

	-- Preload content for smooth playback
	local AssetsToPreload = GetAssetsToPreload(options)
	ContentProvider:PreloadAsync(AssetsToPreload)

	CutsceneModule.Cutscenes[name] = options
end



--[=[
	Play the cutscene associated with the provided name.

	What this function handles:
	- Preparing animations
	- Teleporting character if required
	- Hiding other players
	- Setting up and controlling the camera
	- Playing animations and sounds
	- Cleaning up everything afterwards
]=]
function CutsceneModule.PlayCutscene(name: string)
	assert(not CutsceneModule.PlayingAnimation, "You can't play multiple cutscenes at once.")
	assert(CutsceneModule.Cutscenes[name], "Cutscene has not been registered yet!")

	CutsceneModule.PlayingAnimation = true

	local options = CutsceneModule.Cutscenes[name]
	local plr = Players.LocalPlayer
	local char = plr.Character or plr.CharacterAdded:Wait()
	local camera = workspace.CurrentCamera

	-- Build animation tracks, clone models if needed and prepare the scene
	local animations, models, ogParents = BuildAnimationsAndModels(options, char)

	local CompletedAnimations = 0
	local accessoryHolder

	-- Hide accessories when using player-head camera to avoid clipping
	if options.UsePlayerAsCamera then
		accessoryHolder = RemoveAccessories(char)
	end

	-- Hide other players if requested
	if options.HideOtherPlayers then
		SetOtherPlayersHidden(true)
	end

	-- Anchor player so physics dont mess up the cutscene
	char.HumanoidRootPart.Anchored = true

	PreloadTracks(animations)

	-- Count finishing animations
	for _, animation: AnimationTrack in pairs(animations) do
		animation.Ended:Once(function()
			CompletedAnimations += 1
		end)
	end

	-- Optional cutscene sound
	if options.Sound then
		options.Sound:Play()
	end

	-- Force custom camera type before camera loop
	local originalSubject = camera.CameraSubject

	repeat
		task.wait()
		camera.CameraType = Enum.CameraType.Custom
	until camera.CameraType == Enum.CameraType.Custom

	-- Begin forced camera loop
	local con = SetupCameraLoop(options, char, camera)

	-- Start animations only after camera is ready
	for _, animation: AnimationTrack in pairs(animations) do
		animation:Play()
	end

	-- Wait until all animations report completion
	repeat
		task.wait()
	until CompletedAnimations == #animations



	-- ======== RESTORE EVERYTHING ======== --

	if con then
		con:Disconnect()
	end

	camera.CameraSubject = originalSubject
	char.HumanoidRootPart.Anchored = false
	CutsceneModule.PlayingAnimation = false

	if options.Sound then
		options.Sound:Stop()
	end

	RestoreAccessories(char, accessoryHolder)
	CleanupModels(models, ogParents, options.CloneModels)

	if options.HideOtherPlayers then
		SetOtherPlayersHidden(false)
	end
end



return CutsceneModule
