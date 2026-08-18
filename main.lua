-- TYRANT SPAWN + FARM ONLY
-- Standalone bootstrap.
-- Build: kaituncdkmm fast attack/tween + buy+farmtalon purchase logic + BFNEW compatibility.

if not game:IsLoaded() then game.Loaded:Wait() end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local LocalPlayer = Players.LocalPlayer
local remotes = ReplicatedStorage:WaitForChild("Remotes", 30)
local CommF_ = remotes and remotes:WaitForChild("CommF_", 30)

if not LocalPlayer then error("[K4 Tyrant] LocalPlayer not found") end
if not CommF_ then error("[K4 Tyrant] CommF_ remote not found after update") end

local function status(text)
    getgenv().K4TyrantStatus = tostring(text or "")
    print("[K4 Tyrant] " .. getgenv().K4TyrantStatus)
end

local AttackConfig = {
    AttackDistance = 105,
    AttackMobs = true,
    AttackPlayers = false,
    AutoClickEnabled = true,
    BringMobs = true,
    PreGrabDistance = 1500
}

local module = {}
local activeMoveTarget = nil
local activeMoveOptions = {}
local activeMoveEnabled = false
local activeMoveRoot = nil
local activeMoveVelocity = Vector3.zero
local activeMoveSmoothedPosition = nil
local activeMoveLastCommandAt = 0
local lastEquipAttempt = 0
local selectedCombatToolName = nil

local K4_MOVE_VELOCITY_NAME = "K4SmoothMoveVelocity"
local K4_MOVE_GYRO_NAME = "K4SmoothMoveGyro"

local function K4GetCharacterParts()
    local character = LocalPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")
    return character, humanoid, root
end

local function K4SetCharacterNoclip(character)
    if not character then return end
    for _, part in ipairs(character:GetDescendants()) do
        if part:IsA("BasePart") then
            part.CanCollide = false
        end
    end
end

local function K4GetMoveActuators(root)
    if not root or not root.Parent then return nil, nil end

    local velocity = root:FindFirstChild(K4_MOVE_VELOCITY_NAME)
    if not velocity then
        velocity = Instance.new("BodyVelocity")
        velocity.Name = K4_MOVE_VELOCITY_NAME
        velocity.P = 1600
        velocity.MaxForce = Vector3.new(1e9, 1e9, 1e9)
        velocity.Velocity = Vector3.zero
        velocity.Parent = root
    end

    local gyro = root:FindFirstChild(K4_MOVE_GYRO_NAME)
    if not gyro then
        gyro = Instance.new("BodyGyro")
        gyro.Name = K4_MOVE_GYRO_NAME
        gyro.P = 5000
        gyro.D = 850
        -- Only rotate around Y. Pitch/roll changes were another source of shaking.
        gyro.MaxTorque = Vector3.new(0, 1e9, 0)
        gyro.CFrame = root.CFrame
        gyro.Parent = root
    end

    return velocity, gyro
end

local function K4MoveVectorTowards(current, target, maximumChange)
    local difference = target - current
    local magnitude = difference.Magnitude
    if magnitude <= maximumChange or magnitude <= 1e-4 then
        return target
    end
    return current + difference.Unit * maximumChange
end

local function K4ClampVectorMagnitude(vector, maximumMagnitude)
    local magnitude = vector.Magnitude
    if magnitude <= maximumMagnitude or magnitude <= 1e-4 then
        return vector
    end
    return vector.Unit * maximumMagnitude
end

local function K4CancelMoveTween(clearTarget)
    activeMoveEnabled = false
    activeMoveVelocity = Vector3.zero
    activeMoveSmoothedPosition = nil
    activeMoveLastCommandAt = 0

    local _, humanoid, root = K4GetCharacterParts()
    if humanoid then
        humanoid.AutoRotate = true
    end
    if root then
        local velocity = root:FindFirstChild(K4_MOVE_VELOCITY_NAME)
        if velocity then
            pcall(function() velocity:Destroy() end)
        end
        local gyro = root:FindFirstChild(K4_MOVE_GYRO_NAME)
        if gyro then
            pcall(function() gyro:Destroy() end)
        end
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
    end

    activeMoveRoot = nil
    if clearTarget ~= false then
        activeMoveTarget = nil
        activeMoveOptions = {}
    end
end

-- One persistent physics controller is used for every player movement.
-- Long-distance travel uses smooth acceleration/braking. While attacking a mob,
-- FollowPart mode continuously matches the mob velocity and corrects positional
-- error every Heartbeat, so the player stays attached without CFrame snapping.
RunService.Heartbeat:Connect(function(deltaTime)
    if not activeMoveEnabled or typeof(activeMoveTarget) ~= "CFrame" then return end

    local character, humanoid, root = K4GetCharacterParts()
    if not character or not humanoid or not root or humanoid.Health <= 0 then
        return
    end

    if activeMoveRoot ~= root then
        activeMoveRoot = root
        activeMoveVelocity = Vector3.zero
        activeMoveSmoothedPosition = activeMoveTarget.Position
    end

    K4SetCharacterNoclip(character)
    humanoid.Sit = false
    humanoid.AutoRotate = false

    local velocityMover, gyro = K4GetMoveActuators(root)
    if not velocityMover or not gyro then return end

    deltaTime = math.clamp(tonumber(deltaTime) or 0.016, 0.001, 0.10)
    local options = activeMoveOptions
    local followPart = options.FollowPart
    local followingPart = typeof(followPart) == "Instance"
        and followPart:IsA("BasePart")
        and followPart:IsDescendantOf(Workspace)

    local rawTargetPosition = activeMoveTarget.Position
    local targetVelocity = Vector3.zero
    local lookPosition = rawTargetPosition + activeMoveTarget.LookVector

    if followingPart then
        local followOffset = options.FollowOffset
        if typeof(followOffset) ~= "Vector3" then
            followOffset = Vector3.new(0, tonumber(options.FollowHeight) or 18, 0)
        end

        targetVelocity = followPart.AssemblyLinearVelocity
        local targetVelocityCap = math.max(tonumber(options.TargetVelocityCap) or 95, 1)
        targetVelocity = K4ClampVectorMagnitude(targetVelocity, targetVelocityCap)

        local prediction = math.clamp(tonumber(options.PredictionTime) or 0.08, 0, 0.25)
        rawTargetPosition = followPart.Position + followOffset + targetVelocity * prediction
        lookPosition = followPart.Position
    end

    local targetResponsiveness = math.max(
        tonumber(options.TargetResponsiveness) or (followingPart and 24 or 18),
        1
    )
    local targetAlpha = 1 - math.exp(-targetResponsiveness * deltaTime)

    if not activeMoveSmoothedPosition then
        activeMoveSmoothedPosition = rawTargetPosition
    else
        activeMoveSmoothedPosition = activeMoveSmoothedPosition:Lerp(rawTargetPosition, targetAlpha)
    end

    local offset = activeMoveSmoothedPosition - root.Position
    local distance = offset.Magnitude
    local maximumSpeed = math.max(tonumber(options.Speed) or 300, 1)
    local acceleration = math.max(tonumber(options.Acceleration) or 750, 50)
    local deceleration = math.max(tonumber(options.Deceleration) or 850, 50)
    local desiredVelocity = Vector3.zero

    if followingPart then
        -- Continuous follow: inside the dead zone, inherit the enemy velocity;
        -- outside it, add proportional correction instead of stopping/restarting.
        local deadZone = math.max(tonumber(options.FollowDeadZone) or 1.25, 0.25)
        local followGain = math.max(tonumber(options.FollowGain) or 7.5, 0.5)
        local correction = Vector3.zero

        if distance > deadZone and distance > 1e-3 then
            local correctedDistance = distance - deadZone
            correction = offset.Unit * math.min(maximumSpeed, correctedDistance * followGain)
        end

        desiredVelocity = K4ClampVectorMagnitude(targetVelocity + correction, maximumSpeed)
    else
        local arrivalDistance = math.max(tonumber(options.ArrivalDistance) or 5, 2)
        if distance > arrivalDistance and distance > 1e-3 then
            local brakingDistance = math.max(distance - arrivalDistance, 0)
            local brakingSpeed = math.sqrt(2 * deceleration * brakingDistance)
            local desiredSpeed = math.min(maximumSpeed, brakingSpeed)
            if distance > 30 then
                desiredSpeed = math.max(desiredSpeed, math.min(maximumSpeed, 45))
            end
            desiredVelocity = offset.Unit * desiredSpeed
        end
    end

    local velocityChangeRate = desiredVelocity.Magnitude < activeMoveVelocity.Magnitude
        and deceleration
        or acceleration
    activeMoveVelocity = K4MoveVectorTowards(
        activeMoveVelocity,
        desiredVelocity,
        velocityChangeRate * deltaTime
    )

    if not followingPart and desiredVelocity.Magnitude < 0.5 and activeMoveVelocity.Magnitude < 3 then
        activeMoveVelocity = Vector3.zero
    end

    velocityMover.Velocity = activeMoveVelocity
    root.AssemblyAngularVelocity = Vector3.zero

    local flatLook = Vector3.new(
        lookPosition.X - root.Position.X,
        0,
        lookPosition.Z - root.Position.Z
    )
    if flatLook.Magnitude > 0.05 then
        gyro.CFrame = CFrame.lookAt(root.Position, root.Position + flatLook.Unit)
    end
end)

function module:topos(targetCF, moveOptions)
    if typeof(targetCF) ~= "CFrame" then return false end

    local character, humanoid, root = K4GetCharacterParts()
    if not character or not humanoid or not root or humanoid.Health <= 0 then
        return false
    end

    moveOptions = type(moveOptions) == "table" and moveOptions or {}
    local targetPosition = targetCF.Position
    targetPosition = Vector3.new(targetPosition.X, math.max(targetPosition.Y, 5), targetPosition.Z)
    targetCF = CFrame.new(targetPosition) * (targetCF - targetCF.Position)

    local wasActive = activeMoveEnabled
    local previousTarget = activeMoveTarget
    activeMoveTarget = targetCF
    activeMoveOptions = moveOptions
    activeMoveEnabled = true
    activeMoveLastCommandAt = tick()

    if not wasActive or activeMoveRoot ~= root then
        activeMoveRoot = root
        activeMoveVelocity = Vector3.zero
        activeMoveSmoothedPosition = targetPosition
    elseif moveOptions.ResetVelocity == true then
        activeMoveVelocity = Vector3.zero
    elseif moveOptions.Follow ~= true
        and previousTarget
        and (previousTarget.Position - targetPosition).Magnitude > 250
    then
        -- A new long-distance destination should start immediately rather than
        -- smoothing through the old destination.
        activeMoveSmoothedPosition = targetPosition
    end

    humanoid.Sit = false
    humanoid.AutoRotate = false
    K4SetCharacterNoclip(character)
    K4GetMoveActuators(root)
    return true
end

function module:haki()
    local character = LocalPlayer.Character
    if character and not character:FindFirstChild("HasBuso") then
        pcall(function()
            CommF_:InvokeServer("Buso")
        end)
    end
end

function module:eq()
    local character, humanoid = K4GetCharacterParts()
    local backpack = LocalPlayer:FindFirstChild("Backpack")
    if not character or not humanoid or humanoid.Health <= 0 or not backpack then
        return false
    end

    local config = getgenv().TyrantConfig
    local wanted = tostring(selectedCombatToolName or (config and config.Weapon) or "")
        :gsub("%s+", "")
        :lower()

    local equipped = character:FindFirstChildWhichIsA("Tool")
    if equipped then
        local equippedName = equipped.Name:gsub("%s+", ""):lower()
        if equippedName == wanted then
            return true
        end
    end

    if tick() - lastEquipAttempt < 0.8 then return false end
    lastEquipAttempt = tick()

    local meleeFallback = nil
    for _, tool in ipairs(backpack:GetChildren()) do
        if tool:IsA("Tool") then
            local normalized = tool.Name:gsub("%s+", ""):lower()
            if normalized == wanted then
                selectedCombatToolName = tool.Name
                humanoid:EquipTool(tool)
                return true
            end
            if not meleeFallback then
                local tooltip = string.lower(tostring(tool.ToolTip or ""))
                local weaponType = string.lower(tostring(tool:GetAttribute("WeaponType") or ""))
                if tooltip == "melee" or weaponType == "melee" then
                    meleeFallback = tool
                end
            end
        end
    end

    if meleeFallback and not equipped then
        selectedCombatToolName = meleeFallback.Name
        humanoid:EquipTool(meleeFallback)
        return true
    end
    return false
end

local NetFolder = ReplicatedStorage:WaitForChild("Modules", 30)
NetFolder = NetFolder and NetFolder:WaitForChild("Net", 30)
local RegisterAttack = NetFolder and NetFolder:WaitForChild("RE/RegisterAttack", 30)
local RegisterHit = NetFolder and NetFolder:WaitForChild("RE/RegisterHit", 30)

local TyrantFastAttackContext = {
    Enabled = false,
    GetTargets = function()
        return {}
    end
}

local TyrantRemoteAttack = nil
local TyrantRemoteId = nil
local TyrantAttackSeed = nil
local TyrantLastAttack = 0

pcall(function()
    local seedRemote = NetFolder and NetFolder:FindFirstChild("seed")
    if seedRemote then
        TyrantAttackSeed = seedRemote:InvokeServer()
    end
end)

local function TyrantGetEncryptedAttackRemote()
    if TyrantRemoteAttack and TyrantRemoteAttack.Parent and TyrantRemoteId then
        return true
    end

    TyrantRemoteAttack = nil
    TyrantRemoteId = nil

    for _, folder in ipairs({
        ReplicatedStorage:FindFirstChild("Util"),
        ReplicatedStorage:FindFirstChild("Common"),
        ReplicatedStorage:FindFirstChild("Remotes"),
        ReplicatedStorage:FindFirstChild("Assets"),
        ReplicatedStorage:FindFirstChild("FX")
    }) do
        if folder then
            for _, object in ipairs(folder:GetChildren()) do
                if object:IsA("RemoteEvent") and object:GetAttribute("Id") then
                    TyrantRemoteAttack = object
                    TyrantRemoteId = object:GetAttribute("Id")
                    return true
                end
            end
        end
    end

    return false
end

local function TyrantEncryptedRegisterHit(hitData)
    if not TyrantAttackSeed then
        pcall(function()
            local seedRemote = NetFolder and NetFolder:FindFirstChild("seed")
            if seedRemote then
                TyrantAttackSeed = seedRemote:InvokeServer()
            end
        end)
    end

    if not TyrantGetEncryptedAttackRemote() or not TyrantAttackSeed then
        return false
    end

    return pcall(function()
        local encodedName = string.gsub("RE/RegisterHit", ".", function(character)
            return string.char(bit32.bxor(
                string.byte(character),
                math.floor(Workspace:GetServerTimeNow() / 10 % 10) + 1
            ))
        end)

        TyrantRemoteAttack:FireServer(
            encodedName,
            bit32.bxor(TyrantRemoteId + 909090, TyrantAttackSeed * 2),
            unpack(hitData)
        )
    end)
end

local function TyrantFastAttack()
    if TyrantFastAttackContext.Enabled ~= true then return false end
    if AttackConfig.AutoClickEnabled == false then return false end

    local character, humanoid = K4GetCharacterParts()
    if not character or not humanoid or humanoid.Health <= 0 then
        return false
    end

    local tool = character:FindFirstChildWhichIsA("Tool")
    if not tool then
        module:eq()
        tool = character:FindFirstChildWhichIsA("Tool")
    end
    if not tool then return false end

    local config = getgenv().TyrantConfig
    local delay = math.max(tonumber(config and config.AttackDelay) or 0.03, 0.01)
    if tick() - TyrantLastAttack < delay then return false end

    local targets = TyrantFastAttackContext.GetTargets()
    if type(targets) ~= "table" or #targets == 0 then return false end

    local firstHitPart = targets[1] and targets[1][2]
    if not firstHitPart or not firstHitPart:IsA("BasePart") then return false end

    local hitData = {
        [1] = firstHitPart,
        [2] = {}
    }

    for _, target in ipairs(targets) do
        local object = target[1]
        local hitPart = target[2]
        if object and object.Parent and hitPart and hitPart:IsA("BasePart") and hitPart.Parent then
            hitData[2][#hitData[2] + 1] = { object, hitPart }
        end
    end

    if #hitData[2] == 0 then return false end

    if RegisterAttack then
        pcall(function()
            RegisterAttack:FireServer()
        end)
    end

    if RegisterHit then
        pcall(function()
            RegisterHit:FireServer(unpack(hitData))
        end)
    end

    TyrantEncryptedRegisterHit(hitData)
    TyrantLastAttack = tick()
    return true
end

local AttackInstance = {}
function AttackInstance:Attack()
    return TyrantFastAttack()
end

getgenv().TyrantFastAttack = TyrantFastAttack

task.spawn(function()
    while task.wait() do
        if TyrantFastAttackContext.Enabled then
            pcall(TyrantFastAttack)
        end
    end
end)

-- Persistent Kaitun noclip/stabilizer. It does not force an artificial cruise
-- altitude, so it cannot fight with boss hover or vase skill positioning.
RunService.Stepped:Connect(function()
    local character, humanoid, root = K4GetCharacterParts()
    if character and humanoid and humanoid.Health > 0 and root then
        K4SetCharacterNoclip(character)
        root.AssemblyAngularVelocity = Vector3.zero
        local head = character:FindFirstChild("Head")
        local bodyVelocity = head and head:FindFirstChild("K4KaitunBodyVelocity")
        if bodyVelocity then
            pcall(function() bodyVelocity:Destroy() end)
        end
    end
end)

LocalPlayer.CharacterAdded:Connect(function()
    K4CancelMoveTween()
    lastEquipAttempt = 0
    selectedCombatToolName = nil
end)

getgenv().TyrantConfig = getgenv().TyrantConfig or {}
for key, value in pairs({
    Team = "Marines",
    Weapon = "Dragon Talon",
    AutoBuyDragonTalon = true,
    DragonTalonBuyRetry = 30,
    DragonTalonNoMoneyRetry = 300,
    DragonTalonRequirementRetry = 180,
    DragonTalonBuyMaxAttempts = 8,
    AutoBuso = true,
    TweenSpeed = 300,
    FarmFollowSpeed = 300,
    FarmArrivalDistance = 7,
    FarmFollowDeadZone = 1.25,
    FarmFollowGain = 7.5,
    FarmFollowPrediction = 0.08,
    FarmTargetVelocityCap = 95,
    FarmHeight = 18,
    BossHeight = 25,
    AttackDistance = 105,
    AttackDelay = 0.03,
    BringMobs = true,
    BringRadius = 350,
    BringCooldown = 1,
    BringLockTimeout = 10,
    BringMaxMobs = 4,
    MobNoDamageTimeout = 15,

    -- Tyrant 4 logic: wait for all four real eyes to turn red, then break
    -- the twelve fixed vases with Z/X/C using the existing Kaitun tween/attack.
    UseSkillsForVases = true,
    VaseSkillKeys = { "Z", "X", "C" },
    VaseSkillHoldTime = 0.12,
    VaseSkillReleaseDelay = 0.45,
    VaseSkillRetryDelay = 0.18,
    VaseTargetTimeout = 45,

    TyrantScanInterval = 0.15
}) do
    if getgenv().TyrantConfig[key] == nil then
        getgenv().TyrantConfig[key] = value
    end
end
getgenv().TyrantConfig.VaseSkillKeys = { "Z", "X", "C" }
TyrantConfig = getgenv().TyrantConfig

K4TyrantFarmController = (function()
local TyrState = {
    Farming = false,
    CurrentMode = "IDLE",
    CurrentTarget = nil,
    SkillCasting = false,
    SkillInputBusy = false,
    VaseSkillIndex = 0,
    CachedTyrant = nil,
    LastTyrantScan = 0,
    CachedEyesReady = false,
    CachedActiveEyeCount = 0,
    EyeReadySince = nil,
    CachedEye1 = nil,
    CachedEye2 = nil,
    CachedEye3 = nil,
    CachedEye4 = nil,
    EyeConnections = {},
    LastEyeBindAttempt = 0,
    InternalSkillReadyAt = {},
    LastBring = 0,
    B
