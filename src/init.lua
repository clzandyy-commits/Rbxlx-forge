--!strict
--!native
--!optimize 2

local OmniDump = {}

local HttpService = game:GetService("HttpService")
local CollectionService = game:GetService("CollectionService")

local Config = {
    FileName = "OmniDump_Full.rbxlx",
    ChunkSize = 1_048_576,
    SaveAttributes = true,
    SaveTags = true,
    DecompileScripts = true,
    WriteBytecodeFallback = true,
    Services = {
        "Workspace", "Lighting", "ReplicatedFirst", "ReplicatedStorage",
        "ServerScriptService", "ServerStorage", "StarterGui", "StarterPack",
        "StarterPlayer", "SoundService", "Teams", "Chat", "TextChatService",
        "LocalizationService", "TestService", "MaterialService",
    },
}

local State = {
    Buffer = {},
    BufferSize = 0,
    ItemCount = 0,
    IsRunning = false,
    StartTime = 0,
    RefMap = {},
    RefIdCounter = 2_000_000_000,
    TotalBytes = 0,
    SeenServices = {},
}

local ATTR = {
    String = 0x02,
    Bool = 0x03,
    Number = 0x04,
    UDim = 0x05,
    UDim2 = 0x06,
    Rect = 0x07,
    Color3 = 0x08,
    Vector2 = 0x09,
    Vector3 = 0x0A,
    CFrame = 0x0B,
    NumberSequence = 0x0C,
    ColorSequence = 0x0D,
    NumberRange = 0x0E,
    Ray = 0x0F,
    Vector3int16 = 0x12,
    Vector2int16 = 0x13,
    BrickColor = 0x14,
    Font = 0x15,
}

local function EscapeXML(str: string?): string
    if not str then return "" end
    str = tostring(str)
    str = string.gsub(str, "&", "&amp;")
    str = string.gsub(str, "<", "&lt;")
    str = string.gsub(str, ">", "&gt;")
    str = string.gsub(str, '"', "&quot;")
    str = string.gsub(str, "'", "&apos;")
    str = string.gsub(str, "[\0\1\2\3\4\5\6\7\8\11\12\14\15\16\17\18\19\20\21\22\23\24\25\26\27\28\29\30\31]", "")
    return str
end

local function U8(n: number): string
    return string.char(math.floor(n) % 256)
end

local function U16LE(n: number): string
    n = math.floor(n)
    return string.char(n % 256, math.floor(n / 256) % 256)
end

local function U32LE(n: number): string
    n = math.floor(n) % 4294967296
    if n < 0 then n = n + 4294967296 end
    return string.char(
        n % 256,
        math.floor(n / 256) % 256,
        math.floor(n / 65536) % 256,
        math.floor(n / 16777216) % 256
    )
end

local function I32LE(n: number): string
    n = math.floor(n)
    if n < 0 then n = n + 4294967296 end
    n = n % 4294967296
    return string.char(
        n % 256,
        math.floor(n / 256) % 256,
        math.floor(n / 65536) % 256,
        math.floor(n / 16777216) % 256
    )
end

local function I16LE(n: number): string
    n = math.floor(n) % 65536
    if n < 0 then n = n + 65536 end
    return string.char(n % 256, math.floor(n / 256) % 256)
end

local function F32(n: number): string
    return string.pack("<f", n)
end

local function F64(n: number): string
    return string.pack("<d", n)
end

local function Base64Encode(data: string): string
    local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local out = {}
    local len = #data
    local i = 1
    while i <= len do
        local b1, b2, b3 = string.byte(data, i, i + 2)
        local n = (b1 or 0) * 65536 + (b2 or 0) * 256 + (b3 or 0)
        local c1 = math.floor(n / 262144) % 64
        local c2 = math.floor(n / 4096) % 64
        local c3 = math.floor(n / 64) % 64
        local c4 = n % 64
        out[#out + 1] = string.sub(chars, c1 + 1, c1 + 1)
        out[#out + 1] = string.sub(chars, c2 + 1, c2 + 1)
        out[#out + 1] = b2 and string.sub(chars, c3 + 1, c3 + 1) or "="
        out[#out + 1] = b3 and string.sub(chars, c4 + 1, c4 + 1) or "="
        i = i + 3
    end
    return table.concat(out)
end

local function EncodeAttributeValue(value: any): (number?, string)
    local t = typeof(value)
    if t == "string" then
        local s = string.gsub(value, "%z", "")
        return ATTR.String, U32LE(#s) .. s
    elseif t == "boolean" then
        return ATTR.Bool, value and "\1" or "\0"
    elseif t == "number" then
        return ATTR.Number, F64(value)
    elseif t == "UDim" then
        return ATTR.UDim, F32(value.Scale) .. I32LE(value.Offset)
    elseif t == "UDim2" then
        return ATTR.UDim2,
            F32(value.X.Scale) .. I32LE(value.X.Offset) ..
            F32(value.Y.Scale) .. I32LE(value.Y.Offset)
    elseif t == "Rect" then
        return ATTR.Rect,
            F32(value.Min.X) .. F32(value.Min.Y) ..
            F32(value.Max.X) .. F32(value.Max.Y)
    elseif t == "Color3" then
        return ATTR.Color3, F32(value.R) .. F32(value.G) .. F32(value.B)
    elseif t == "Vector2" then
        return ATTR.Vector2, F32(value.X) .. F32(value.Y)
    elseif t == "Vector3" then
        return ATTR.Vector3, F32(value.X) .. F32(value.Y) .. F32(value.Z)
    elseif t == "CFrame" then
        local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = value:GetComponents()
        return ATTR.CFrame,
            F32(x) .. F32(y) .. F32(z) ..
            F32(r00) .. F32(r01) .. F32(r02) ..
            F32(r10) .. F32(r11) .. F32(r12) ..
            F32(r20) .. F32(r21) .. F32(r22)
    elseif t == "NumberSequence" then
        local kps = value.Keypoints
        local parts = { U32LE(#kps) }
        for _, kp in ipairs(kps) do
            parts[#parts + 1] = F32(kp.Time)
            parts[#parts + 1] = F32(kp.Value)
            parts[#parts + 1] = F32(kp.Envelope)
        end
        return ATTR.NumberSequence, table.concat(parts)
    elseif t == "ColorSequence" then
        local kps = value.Keypoints
        local parts = { U32LE(#kps) }
        for _, kp in ipairs(kps) do
            parts[#parts + 1] = F32(kp.Time)
            parts[#parts + 1] = F32(kp.Value.R)
            parts[#parts + 1] = F32(kp.Value.G)
            parts[#parts + 1] = F32(kp.Value.B)
            parts[#parts + 1] = F32(0)
        end
        return ATTR.ColorSequence, table.concat(parts)
    elseif t == "NumberRange" then
        return ATTR.NumberRange, F32(value.Min) .. F32(value.Max)
    elseif t == "Ray" then
        return ATTR.Ray,
            F32(value.Origin.X) .. F32(value.Origin.Y) .. F32(value.Origin.Z) ..
            F32(value.Direction.X) .. F32(value.Direction.Y) .. F32(value.Direction.Z)
    elseif t == "Vector3int16" then
        return ATTR.Vector3int16,
            I16LE(value.X) .. I16LE(value.Y) .. I16LE(value.Z)
    elseif t == "Vector2int16" then
        return ATTR.Vector2int16, I16LE(value.X) .. I16LE(value.Y)
    elseif t == "BrickColor" then
        return ATTR.BrickColor, U32LE(value.Number)
    elseif t == "Font" then
        return ATTR.Font,
            U32LE(value.Family) .. U16LE(value.Weight) .. U8(value.Style)
    end
    return nil, ""
end

local function SerializeAttributes(attributes: {[string]: any}): string
    local keys = {}
    for k in pairs(attributes) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    local parts = { U32LE(#keys) }
    for _, k in ipairs(keys) do
        local typeId, encoded = EncodeAttributeValue(attributes[k])
        if typeId then
            parts[#parts + 1] = U32LE(#k)
            parts[#parts + 1] = k
            parts[#parts + 1] = U8(typeId)
            parts[#parts + 1] = encoded
        end
    end
    return table.concat(parts)
end

local function SerializeTags(tags: {string}): string
    if #tags == 0 then return "" end
    return table.concat(tags, "\0") .. "\0"
end

local function GetRef(inst: Instance?): string
    if not inst or typeof(inst) ~= "Instance" then return "null" end
    local ref = State.RefMap[inst]
    return ref and string.format("RBX%s", tostring(ref)) or "null"
end

local function SerializeProp(name: string, value: any): string?
    local t = typeof(value)
    local n = EscapeXML(name)

    if t == "string" then
        return string.format('<string name="%s">%s</string>', n, EscapeXML(value))
    elseif t == "boolean" then
        return string.format('<bool name="%s">%s</bool>', n, tostring(value))
    elseif t == "number" then
        if math.type(value) == "integer" then
            return string.format('<int name="%s">%d</int>', n, value)
        end
        return string.format('<float name="%s">%.17g</float>', n, value)
    elseif t == "Vector3" then
        return string.format(
            '<Vector3 name="%s"><X>%.17g</X><Y>%.17g</Y><Z>%.17g</Z></Vector3>',
            n, value.X, value.Y, value.Z)
    elseif t == "Vector2" then
        return string.format(
            '<Vector2 name="%s"><X>%.17g</X><Y>%.17g</Y></Vector2>',
            n, value.X, value.Y)
    elseif t == "CFrame" then
        local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = value:GetComponents()
        return string.format(
            '<CoordinateFrame name="%s"><X>%.17g</X><Y>%.17g</Y><Z>%.17g</Z>' ..
            '<R00>%.17g</R00><R01>%.17g</R01><R02>%.17g</R02>' ..
            '<R10>%.17g</R10><R11>%.17g</R11><R12>%.17g</R12>' ..
            '<R20>%.17g</R20><R21>%.17g</R21><R22>%.17g</R22></CoordinateFrame>',
            n, x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22)
    elseif t == "Color3" then
        local r = math.clamp(math.floor(value.R * 255 + 0.5), 0, 255)
        local g = math.clamp(math.floor(value.G * 255 + 0.5), 0, 255)
        local b = math.clamp(math.floor(value.B * 255 + 0.5), 0, 255)
        local packed = 4278190080 + r * 65536 + g * 256 + b
        return string.format('<Color3uint8 name="%s">%d</Color3uint8>', n, packed)
    elseif t == "BrickColor" then
        return string.format('<BrickColor name="%s">%d</BrickColor>', n, value.Number)
    elseif t == "UDim" then
        return string.format('<UDim name="%s"><S>%.17g</S><O>%d</O></UDim>',
            n, value.Scale, value.Offset)
    elseif t == "UDim2" then
        return string.format(
            '<UDim2 name="%s"><XS>%.17g</XS><XO>%d</XO><YS>%.17g</YS><YO>%d</YO></UDim2>',
            n, value.X.Scale, value.X.Offset, value.Y.Scale, value.Y.Offset)
    elseif t == "Rect" then
        return string.format(
            '<Rect2D name="%s"><min><X>%.17g</X><Y>%.17g</Y></min><max><X>%.17g</X><Y>%.17g</Y></max></Rect2D>',
            n, value.Min.X, value.Min.Y, value.Max.X, value.Max.Y)
    elseif t == "EnumItem" then
        return string.format('<token name="%s">%d</token>', n, value.Value)
    elseif t == "Instance" then
        return string.format('<Ref name="%s">%s</Ref>', n, GetRef(value))
    elseif t == "NumberSequence" then
        local kps = value.Keypoints
        local parts = {}
        for _, kp in ipairs(kps) do
            parts[#parts + 1] = string.format("%.17g %.17g %.17g", kp.Time, kp.Value, kp.Envelope)
        end
        return string.format('<NumberSequence name="%s">%s</NumberSequence>',
            n, table.concat(parts, " "))
    elseif t == "ColorSequence" then
        local kps = value.Keypoints
        local parts = {}
        for _, kp in ipairs(kps) do
            parts[#parts + 1] = string.format("%.17g %.17g %.17g %.17g 0",
                kp.Time, kp.Value.R, kp.Value.G, kp.Value.B)
        end
        return string.format('<ColorSequence name="%s">%s</ColorSequence>',
            n, table.concat(parts, " "))
    elseif t == "NumberRange" then
        return string.format('<NumberRange name="%s"><Min>%.17g</Min><Max>%.17g</Max></NumberRange>',
            n, value.Min, value.Max)
    elseif t == "Ray" then
        return string.format(
            '<Ray name="%s"><Origin><X>%.17g</X><Y>%.17g</Y><Z>%.17g</Z></Origin>' ..
            '<Direction><X>%.17g</X><Y>%.17g</Y><Z>%.17g</Z></Direction></Ray>',
            n, value.Origin.X, value.Origin.Y, value.Origin.Z,
            value.Direction.X, value.Direction.Y, value.Direction.Z)
    elseif t == "Faces" then
        local bits = (value.Top and 1 or 0) + (value.Bottom and 2 or 0) +
                     (value.Left and 4 or 0) + (value.Right and 8 or 0) +
                     (value.Back and 16 or 0) + (value.Front and 32 or 0)
        return string.format('<Faces name="%s"><faces>%d</faces></Faces>', n, bits)
    elseif t == "Axes" then
        local bits = (value.X and 1 or 0) + (value.Y and 2 or 0) + (value.Z and 4 or 0)
        return string.format('<Axes name="%s"><axes>%d</axes></Axes>', n, bits)
    elseif t == "PhysicalProperties" then
        if value.CustomPhysicalProperties then return nil end
        return string.format(
            '<PhysicalProperties name="%s"><CustomPhysics>false</CustomPhysics>' ..
            '<Density>%.17g</Density><Friction>%.17g</Friction><Elasticity>%.17g</Elasticity>' ..
            '<FrictionWeight>%.17g</FrictionWeight><ElasticityWeight>%.17g</ElasticityWeight>' ..
            '</PhysicalProperties>',
            n, value.Density, value.Friction, value.Elasticity,
            value.FrictionWeight, value.ElasticityWeight)
    elseif t == "Content" then
        local s = tostring(value)
        if s == "" then return nil end
        return string.format('<Content name="%s"><url>%s</url></Content>', n, EscapeXML(s))
    elseif t == "ProtectedString" then
        return string.format('<ProtectedString name="%s">%s</ProtectedString>',
            n, EscapeXML(value))
    elseif t == "Vector3int16" then
        return string.format('<Vector3int16 name="%s"><X>%d</X><Y>%d</Y><Z>%d</Z></Vector3int16>',
            n, value.X, value.Y, value.Z)
    elseif t == "Vector2int16" then
        return string.format('<Vector2int16 name="%s"><X>%d</X><Y>%d</Y></Vector2int16>',
            n, value.X, value.Y)
    elseif t == "Font" then
        return string.format(
            '<Font name="%s"><Family>%s</Family><Weight>%d</Weight><Style>%d</Style></Font>',
            n, EscapeXML(value.Family), value.Weight, value.Style)
    end
    return nil
end

local FallbackProps = {
    "Archivable", "CFrame", "Size", "Position", "Rotation", "Orientation",
    "Color", "Material", "Anchored", "CanCollide", "CanTouch", "CanQuery",
    "CastShadow", "Locked", "Massless", "Transparency", "Reflectance",
    "RootPriority", "CustomPhysicalProperties", "CollisionGroup",
    "TopSurface", "BottomSurface", "FrontSurface", "BackSurface",
    "LeftSurface", "RightSurface", "Shape",
    "MeshId", "TextureID", "MeshSize", "RenderFidelity", "DoubleSided",
    "AllowTeamChangeOnTouch", "Duration", "Enabled", "Neutral", "TeamColor",
    "MaxSpeed", "Torque", "TurnSpeed", "HeadsUpDisplay", "Disabled",
    "Health", "MaxHealth", "WalkSpeed", "JumpPower", "JumpHeight", "HipHeight",
    "AutoRotate", "WalkToPoint", "DisplayName", "DisplayDistanceType",
    "HealthDisplayDistance", "NameDisplayDistance", "BreakJointsOnDeath",
    "UseJumpPower", "AutoJumpEnabled", "PlatformStand", "Sit", "Jump",
    "CameraOffset", "RequiresNeck", "EvaluateStateMachine",
    "Ambient", "Brightness", "ColorShift_Bottom", "ColorShift_Top",
    "ExposureCompensation", "FogColor", "FogEnd", "FogStart",
    "GlobalShadows", "OutdoorAmbient", "ShadowSoftness",
    "EnvironmentDiffuseScale", "EnvironmentSpecularScale",
    "ClockTime", "GeographicLatitude", "TimeOfDay", "Technology",
    "ShadowColor", "EnvironmentDiffuseScale", "EnvironmentSpecularScale",
    "SoundId", "Volume", "Pitch", "Looped", "PlaybackSpeed", "PlayOnRemove",
    "RollOffMode", "RollOffMaxDistance", "RollOffMinDistance", "EmitterSize",
    "Acceleration", "Drag", "EmissionDirection", "Lifetime", "LightEmission",
    "LightInfluence", "LockedToPart", "Rate", "RotSpeed", "Speed",
    "SpreadAngle", "Texture", "TimeScale", "VelocityInheritance", "ZOffset",
    "Attachment0", "Attachment1", "FaceCamera", "Segments", "TextureLength",
    "TextureMode", "TextureSpeed", "Width0", "Width1", "CurveSize0", "CurveSize1",
    "MaxLength", "MinLength", "WidthScale",
    "Heat", "SecondaryColor",
    "Opacity", "RiseVelocity",
    "BlastPressure", "BlastRadius", "DestroyJointRadiusPercent", "ExplosionType",
    "Range", "Shadows", "Angle", "Face",
    "Active", "AnchorPoint", "AutoLocalize", "BackgroundColor3",
    "BackgroundTransparency", "BorderColor3", "BorderMode", "BorderSizePixel",
    "ClipsDescendants", "LayoutOrder", "Position", "Rotation", "Selectable",
    "SelectionImageObject", "SizeConstraint", "Visible", "ZIndex",
    "Draggable",
    "Font", "FontFace", "LineHeight", "MaxVisibleGraphemes", "RichText",
    "Text", "TextBounds", "TextColor3", "TextDirection", "TextFits",
    "TextScaled", "TextSize", "TextStrokeColor3", "TextStrokeTransparency",
    "TextTransparency", "TextTruncate", "TextWrapped", "TextXAlignment",
    "TextYAlignment",
    "AutoButtonColor", "Modal", "Selected", "Style",
    "ClearTextOnFocus", "MultiLine", "PlaceholderColor3", "PlaceholderText",
    "TextEditable",
    "Image", "ImageColor3", "ImageRectOffset", "ImageRectSize",
    "ImageTransparency", "ScaleType", "SliceCenter", "SliceScale", "TileSize",
    "HoverImage", "PressedImage",
    "AutomaticCanvasSize", "BottomImage", "CanvasPosition", "CanvasSize",
    "ElasticBehavior", "MidImage", "ScrollBarImageColor3",
    "ScrollBarImageTransparency", "ScrollBarThickness", "ScrollingDirection",
    "ScrollingEnabled", "TopImage", "VerticalScrollBarInset",
    "VerticalScrollBarPosition",
    "CurrentCamera", "LightColor", "LightDirection",
    "DisplayOrder", "IgnoreGuiInset", "ResetOnSpawn", "ZIndexBehavior",
    "ClipToDeviceSafeArea", "SafeAreaCompatibility", "ScreenInsets",
    "AlwaysOnTop", "CanvasSize", "MaxDistance", "PixelsPerStud", "SizingMode",
    "ToolPunchThroughDistance",
    "Adornee", "ExtentsOffset", "ExtentsOffsetWorldSpace", "Offset",
    "SizeOffset", "StudsOffset", "StudsOffsetWorldSpace",
    "PrimaryPart", "WorldPivot",
    "RunContext",
    "Part0", "Part1", "C0", "C1", "CurrentAngle", "DesiredAngle", "Transform",
    "ActuatorType", "AngularSpeed", "AngularVelocity", "LimitsEnabled",
    "LowerAngle", "UpperAngle", "MotorMaxAcceleration", "MotorMaxTorque",
    "Radius", "Restitution", "ServoMaxTorque", "TargetAngle",
    "Coils", "CurrentLength", "Damping", "FreeLength", "MaxForce",
    "MinLength", "Stiffness", "Thickness",
    "LowerLimit", "UpperLimit", "MotorMaxForce", "ServoMaxForce",
    "Speed", "TargetPosition", "Velocity",
    "Length", "WinchEnabled", "WinchForce", "WinchResponsiveness",
    "WinchSpeed", "WinchTarget",
    "CurrentDistance",
    "MaxAngle", "MaxTorque",
    "MaxFrictionTorque", "TwistLimitsEnabled", "TwistLowerAngle", "TwistUpperAngle",
    "AlignOffset", "ApplyAtCenterOfMass", "MaxVelocity", "Mode",
    "ReactionForceEnabled", "Responsiveness", "RigidityEnabled",
    "MaxAngularVelocity", "PrimaryAxis", "PrimaryAxisOnly",
    "ReactionTorqueEnabled", "SecondaryAxis",
    "ForceLimitMode", "ForceLimitsEnabled", "LineDirection",
    "LineVelocity", "MaxPlanarAxesForce", "PlaneVelocity",
    "PrimaryTangentAxis", "SecondaryTangentAxis", "VectorVelocity",
    "VelocityConstraintMode", "VelocityGroundOnly",
    "Force", "RelativeTo", "Torque",
    "CelestialBodiesShown", "MoonAngularSize", "MoonTextureId",
    "SkyboxBk", "SkyboxDn", "SkyboxFt", "SkyboxLf", "SkyboxRt", "SkyboxUp",
    "StarCount", "SunAngularSize", "SunTextureId",
    "Decay", "Density", "Glare", "Haze",
    "Cover", "Intensity", "Threshold", "Contrast", "Saturation", "TintColor",
    "FarIntensity", "FocusDistance", "InFocusRadius", "NearIntensity",
    "Spread",
    "WaterColor", "WaterTransparency", "WaterWaveSize", "WaterWaveSpeed",
    "WaterReflectance", "Decoration", "MaterialColors",
    "AnimationId",
    "TextureId",
    "SoundGroup",
}

local function GetPropertyCandidates(inst: Instance): {string}
    local seen = {}
    local result = {}
    local ok, props = pcall(function()
        return (getproperties :: any)(inst)
    end)
    if ok and type(props) == "table" then
        for _, p in ipairs(props) do
            if type(p) == "string" and not seen[p] then
                seen[p] = true
                result[#result + 1] = p
            end
        end
    end
    for _, p in ipairs(FallbackProps) do
        if not seen[p] then
            seen[p] = true
            result[#result + 1] = p
        end
    end
    return result
end

local function ExtractProperties(inst: Instance): string
    local parts = {}
    local seen = {}

    parts[#parts + 1] = string.format('<string name="Name">%s</string>', EscapeXML(inst.Name))
    seen["Name"] = true

    if inst.Parent then
        parts[#parts + 1] = string.format('<Ref name="Parent">%s</Ref>', GetRef(inst.Parent))
    end
    seen["Parent"] = true

    local candidates = GetPropertyCandidates(inst)
    for _, propName in ipairs(candidates) do
        if not seen[propName] then
            seen[propName] = true
            local ok, value = pcall(function()
                return (inst :: any)[propName]
            end)
            if ok and value ~= nil then
                local serialized = SerializeProp(propName, value)
                if serialized then
                    parts[#parts + 1] = serialized
                end
            end
        end
    end

    if inst:IsA("LuaSourceContainer") and Config.DecompileScripts then
        local ok, source = pcall(function()
            return (decompile :: any)(inst)
        end)
        if ok and type(source) == "string" and source ~= "" then
            parts[#parts + 1] = string.format(
                '<ProtectedString name="Source">%s</ProtectedString>',
                EscapeXML(source))
        else
            if Config.WriteBytecodeFallback then
                local bOk, bytecode = pcall(function()
                    return (getscriptbytecode :: any)(inst)
                end)
                if bOk and type(bytecode) == "string" and #bytecode > 0 then
                    parts[#parts + 1] = string.format(
                        '<BinaryString name="Bytecode">%s</BinaryString>',
                        Base64Encode(bytecode))
                end
            end
            parts[#parts + 1] = '<ProtectedString name="Source">-- Source unavailable</ProtectedString>'
        end
    end

    if Config.SaveAttributes then
        local ok, attrs = pcall(function()
            return inst:GetAttributes()
        end)
        if ok and attrs and next(attrs) ~= nil then
            local blob = SerializeAttributes(attrs)
            parts[#parts + 1] = string.format(
                '<BinaryString name="AttributesSerialize">%s</BinaryString>',
                Base64Encode(blob))
        end
    end

    if Config.SaveTags then
        local ok, tags = pcall(function()
            return CollectionService:GetTags(inst)
        end)
        if ok and tags and #tags > 0 then
            local blob = SerializeTags(tags)
            parts[#parts + 1] = string.format(
                '<BinaryString name="TagsSerialize">%s</BinaryString>',
                Base64Encode(blob))
            parts[#parts + 1] = string.format(
                '<BinaryString name="Tags">%s</BinaryString>',
                Base64Encode(blob))
        end
    end

    return table.concat(parts, "\n      ")
end

local function RegisterRef(inst: Instance)
    if State.RefMap[inst] then return end
    State.RefIdCounter = State.RefIdCounter + 1
    State.RefMap[inst] = State.RefIdCounter
end

local function MapReferences(root: Instance)
    local stack = { root }
    while #stack > 0 do
        local inst = table.remove(stack)
        if inst and not State.RefMap[inst] then
            if inst.ClassName ~= "Camera" then
                RegisterRef(inst)
                local children = inst:GetChildren()
                for i = #children, 1, -1 do
                    stack[#stack + 1] = children[i]
                end
            end
        end
    end
end

local function FlushBuffer()
    if State.BufferSize == 0 then return end
    local chunk = table.concat(State.Buffer)
    if appendfile then
        appendfile(Config.FileName, chunk)
        State.TotalBytes = State.TotalBytes + #chunk
    end
    State.Buffer = {}
    State.BufferSize = 0
end

local function ProcessInstance(root: Instance, isService: boolean?)
    local stack = { { inst = root, isService = isService or false, depth = 0 } }
    local closeTags = {}

    while #stack > 0 do
        local frame = table.remove(stack)
        local inst = frame.inst
        if inst and inst.ClassName ~= "Camera" then
            local refId = State.RefMap[inst]
            if refId then
                local xml = string.format('  <Item class="%s" referent="RBX%s">\n',
                    inst.ClassName, tostring(refId))
                xml = xml .. '    <Properties>\n      '
                xml = xml .. ExtractProperties(inst)
                xml = xml .. '\n    </Properties>\n'

                State.Buffer[#State.Buffer + 1] = xml
                State.BufferSize = State.BufferSize + #xml
                State.ItemCount = State.ItemCount + 1

                local children = inst:GetChildren()
                if #children > 0 then
                    closeTags[#closeTags + 1] = frame.depth
                    for i = #children, 1, -1 do
                        stack[#stack + 1] = {
                            inst = children[i],
                            isService = false,
                            depth = frame.depth + 1,
                        }
                    end
                else
                    State.Buffer[#State.Buffer + 1] = '  </Item>\n'
                    State.BufferSize = State.BufferSize + 11

                    while #closeTags > 0 and closeTags[#closeTags] == frame.depth do
                        table.remove(closeTags)
                        State.Buffer[#State.Buffer + 1] = '  </Item>\n'
                        State.BufferSize = State.BufferSize + 11
                        frame = { depth = frame.depth - 1 }
                    end
                end

                if State.BufferSize >= Config.ChunkSize then
                    FlushBuffer()
                end
            end
        end
    end

    while #closeTags > 0 do
        table.remove(closeTags)
        State.Buffer[#State.Buffer + 1] = '  </Item>\n'
        State.BufferSize = State.BufferSize + 11
    end
end

local function ResetState()
    State.Buffer = {}
    State.BufferSize = 0
    State.ItemCount = 0
    State.IsRunning = false
    State.StartTime = 0
    State.RefMap = {}
    State.RefIdCounter = 2_000_000_000
    State.TotalBytes = 0
    State.SeenServices = {}
end

function OmniDump.Run(): (boolean, number, number, number)
    if State.IsRunning then return false, 0, 0, 0 end
    if typeof(writefile) ~= "function" then return false, 0, 0, 0 end

    ResetState()
    State.IsRunning = true
    State.StartTime = tick()

    local header = '<?xml version="1.0" encoding="utf-8"?>\n' ..
        '<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" ' ..
        'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" ' ..
        'xsi:noNamespaceSchemaLocation="http://www.roblox.com/roblox.xsd" version="4">\n' ..
        '\t<External>null</External>\n' ..
        '\t<External>nil</External>\n'

    local ok = pcall(writefile, Config.FileName, header)
    if not ok then
        State.IsRunning = false
        return false, 0, 0, 0
    end

    local services = {}
    for _, name in ipairs(Config.Services) do
        local sOk, service = pcall(function()
            return game:GetService(name)
        end)
        if sOk and service then
            services[#services + 1] = service
        end
    end

    for _, service in ipairs(services) do
        RegisterRef(service)
        State.SeenServices[service] = true
        for _, child in ipairs(service:GetChildren()) do
            MapReferences(child)
        end
    end

    for _, service in ipairs(services) do
        ProcessInstance(service, true)
    end

    FlushBuffer()

    if appendfile then
        appendfile(Config.FileName, '\n</roblox>\n')
    end

    local elapsed = tick() - State.StartTime
    State.IsRunning = false
    return true, State.ItemCount, elapsed, State.TotalBytes
end

function OmniDump.GetConfig(): {[string]: any}
    return table.clone(Config)
end

function OmniDump.SetConfig(patch: {[string]: any})
    for k, v in pairs(patch) do
        if Config[k] ~= nil then
            Config[k] = v
        end
    end
end

return OmniDump
