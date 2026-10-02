-- Better Forever: creature type icons on nameplates.
--
-- An icon for the unit's creature type (beast, humanoid, undead, ...) left of
-- the health bar, on every nameplate or only the target's. Optionally in a
-- box drawn like the level box this client shows right of the bar. Tinted by
-- the color setting (white = as drawn). Players get nothing.
--
-- Icons are the TGAs in creature_types\, looked up by the id UnitCreatureType
-- returns, with the English name as fallback (Murloc and Plant have no id).
-- Types without an icon show nothing. Icon files added while the game is
-- running only load after a full restart, not a /reload.
--
-- Nameplate gotchas: anything parented to a plate is a restricted region, so
-- nothing on a plate is ever measured (no GetWidth/GetPoint/backdrops, only
-- anchored color textures). The update runs under pcall; a failure reports
-- once and switches the feature off until /reload. A secret creature type
-- can't be mapped to an icon and shows nothing.

local addonName, addon = ...
local Print = addon.Print or print

-- -----------------------------------------------------------------------------
-- Settings. Edited from the options panel and saved in
-- BetterForeverDB.creatureIcon; this table is what a fresh save falls back to.
-- -----------------------------------------------------------------------------
local DEFAULTS = {
  enabled = true,
  allPlates = true,   -- every nameplate; off: only the target's
  size = 28,          -- icon width and height
  box = false,        -- in a box like the level box; off: just the icon
  color = { 1, 1, 1 }, -- icon tint; white shows the icon as drawn
  gap = 4,            -- space between the icon (or its box) and the health bar
  offsetX = 0,        -- nudge right (+) / left (-)
  offsetY = 0,        -- nudge up (+) / down (-)
}

local ICON_PATH = "Interface\\AddOns\\" .. addonName .. "\\creature_types\\"
local BLIZZARD_ICON_PATH = "Interface\\Icons\\"
local ICONS_BY_ID = {
  [1] = ICON_PATH .. "beast",
  [2] = ICON_PATH .. "dragonkin",
  [3] = ICON_PATH .. "demon",
  [4] = ICON_PATH .. "elemental",
  [5] = ICON_PATH .. "giant",
  [6] = ICON_PATH .. "undead",
  [7] = ICON_PATH .. "humanoid",
  [8] = ICON_PATH .. "critter",
  [9] = ICON_PATH .. "mechanical",
  [11] = ICON_PATH .. "totem",
  [12] = BLIZZARD_ICON_PATH .. "INV_Box_PetCarrier_01", -- Non-combat Pet: no icon of our own yet
  -- 10 Not specified, 13 Gas Cloud, 14 Wild Pet, 15 Aberration: no icon
}
local ICONS_BY_NAME = { -- English type names, for a client that returns no id
  Beast = ICONS_BY_ID[1], Dragonkin = ICONS_BY_ID[2], Demon = ICONS_BY_ID[3], Elemental = ICONS_BY_ID[4],
  Giant = ICONS_BY_ID[5], Undead = ICONS_BY_ID[6], Humanoid = ICONS_BY_ID[7], Critter = ICONS_BY_ID[8],
  Mechanical = ICONS_BY_ID[9], Totem = ICONS_BY_ID[11], ["Non-combat Pet"] = ICONS_BY_ID[12],
  Murloc = ICON_PATH .. "murloc", Plant = ICON_PATH .. "plant",
}
local SAMPLE_TYPE_ID = 7 -- Humanoid: the preview and the test button

local LIMITS = { -- numeric settings: { min, max }
  size = { 8, 48 }, gap = { 0, 40 }, offsetX = { -100, 100 }, offsetY = { -100, 100 },
}
local ICON_CROP = 0.07          -- trims the built-in rim of Blizzard's own icons (ours have none)
local BOX_PADDING = 3           -- the box around the icon: dark edge, grey line, dark gap, 1 px each
local POLL_INTERVAL = 0.25      -- seconds; re-check the nameplates (event coverage is unverified)
local TEST_SECONDS = 8

local function IsSecret(value)
  return type(issecretvalue) == "function" and issecretvalue(value) or false
end

local function Clamp(value, low, high)
  if value < low then return low end
  if value > high then return high end
  return value
end

local function CopyDefaults(into)
  into = into or {}
  for key, default in pairs(DEFAULTS) do
    if type(default) == "table" then
      if type(into[key]) ~= "table" then
        into[key] = {}
      end
      for i = 1, 3 do
        if type(into[key][i]) ~= "number" then
          into[key][i] = default[i]
        end
      end
    elseif type(into[key]) ~= type(default) then
      into[key] = default
    end
  end
  return into
end

local function Sanitize(s)
  for key, limit in pairs(LIMITS) do
    s[key] = Clamp(math.floor(s[key] + 0.5), limit[1], limit[2])
  end
  for i = 1, 3 do
    s.color[i] = Clamp(s.color[i], 0, 1)
  end
  return s
end

local settings = Sanitize(CopyDefaults()) -- replaced by the saved table on ADDON_LOADED

-- -----------------------------------------------------------------------------
-- The icon frame: the icon, optionally in a box drawn like this client's level
-- box (a dark square with a thin grey line one pixel inside its edge). Only
-- anchored colour textures, nothing measured, so it is safe on a nameplate.
-- The options panel makes one more for its preview.
-- -----------------------------------------------------------------------------
local function NewIcon(parent, name)
  local frame = CreateFrame("Frame", name, parent)
  frame:SetSize(1, 1)
  frame.box = {} -- the box's textures
  local bg = frame:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints(frame)
  bg:SetColorTexture(0.05, 0.05, 0.05, 0.9)
  frame.box[1] = bg
  local edges = {
    { "TOPLEFT", 1, -1, "TOPRIGHT", -1, -1, "SetHeight" },
    { "BOTTOMLEFT", 1, 1, "BOTTOMRIGHT", -1, 1, "SetHeight" },
    { "TOPLEFT", 1, -1, "BOTTOMLEFT", 1, 1, "SetWidth" },
    { "TOPRIGHT", -1, -1, "BOTTOMRIGHT", -1, 1, "SetWidth" },
  }
  for _, e in ipairs(edges) do
    local line = frame:CreateTexture(nil, "BORDER")
    line:SetColorTexture(0.55, 0.55, 0.55, 1)
    line:SetPoint(e[1], e[2], e[3])
    line:SetPoint(e[4], e[5], e[6])
    line[e[7]](line, 1)
    frame.box[#frame.box + 1] = line
  end
  frame.icon = frame:CreateTexture(nil, "ARTWORK")
  frame.icon:SetPoint("CENTER")
  return frame
end

local function Layout(frame)
  local s = settings
  local padding = s.box and BOX_PADDING or 0
  frame:SetSize(s.size + 2 * padding, s.size + 2 * padding)
  frame.icon:SetSize(s.size, s.size)
  for _, texture in ipairs(frame.box) do
    texture:SetShown(s.box)
  end
end

local function SetIcon(frame, path)
  if frame.path ~= path then
    frame.path = path
    frame.icon:SetTexture(path)
    local crop = path:find(BLIZZARD_ICON_PATH, 1, true) == 1 and ICON_CROP or 0
    frame.icon:SetTexCoord(crop, 1 - crop, crop, 1 - crop)
  end
  local c = settings.color -- the tint, on every call so a colour change shows at once
  frame.icon:SetVertexColor(c[1], c[2], c[3])
end

-- -----------------------------------------------------------------------------
-- Which icon
-- -----------------------------------------------------------------------------
-- The icon path for a creature type (UnitCreatureType's name and id), or nil
-- when it has none or cannot be read. The tooltip box uses it too.
local function IconForType(name, id)
  if not IsSecret(id) and type(id) == "number" and ICONS_BY_ID[id] then
    return ICONS_BY_ID[id]
  end
  if not IsSecret(name) and type(name) == "string" then
    return ICONS_BY_NAME[name]
  end
  return nil
end

local function IconForUnit(unit)
  return IconForType(UnitCreatureType(unit))
end

-- -----------------------------------------------------------------------------
-- Nameplates. One icon frame per plate that shows one, taken from a pool.
-- Only SetParent/SetPoint/IsShown and frame-level calls touch a plate;
-- nothing on it is measured.
-- -----------------------------------------------------------------------------
local active = {}  -- plate -> its icon frame
local pool = {}    -- icon frames not in use
local version = 0  -- bumped by every settings change; frames laid out for an older one are redone

local enabled = false
local forced -- { path = ..., expires = GetTime() } while a test display runs on the target

local function PlateUnit(plate)
  local unit = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
  if not IsSecret(unit) and type(unit) == "string" then
    return unit
  end
end

local function IsTarget(unit)
  local isTarget = UnitIsUnit(unit, "target")
  return not IsSecret(isTarget) and isTarget == true
end

local function TargetNamePlate()
  if not (C_NamePlate and C_NamePlate.GetNamePlateForUnit) or not UnitExists("target") then
    return nil
  end
  return C_NamePlate.GetNamePlateForUnit("target")
end

-- The region on `plate` the icon is anchored to.
local function AnchorFor(plate)
  local unitFrame = plate.UnitFrame
  if not unitFrame then
    return plate
  end
  local bars = unitFrame.HealthBarsContainer or unitFrame.healthBar
  if bars and bars:IsShown() then
    return bars
  end
  local name = unitFrame.name
  if name and name:IsShown() then
    return name
  end
  return plate
end

local function Attach(frame, plate, anchor)
  local s = settings
  local unitFrame = plate.UnitFrame
  frame:ClearAllPoints()
  frame:SetParent(plate)
  frame:SetFrameStrata(plate:GetFrameStrata())
  frame:SetFrameLevel(((unitFrame and unitFrame:GetFrameLevel()) or plate:GetFrameLevel()) + 10)
  frame:SetPoint("RIGHT", anchor, "LEFT", -s.gap + s.offsetX, s.offsetY)
  frame.plate, frame.anchor, frame.version = plate, anchor, version
end

local function ShowOn(plate, path)
  local frame = active[plate]
  if not frame then
    frame = table.remove(pool) or NewIcon(UIParent)
    active[plate] = frame
  end
  local anchor = AnchorFor(plate)
  if frame.plate ~= plate or frame.anchor ~= anchor or frame.version ~= version then
    Layout(frame)
    Attach(frame, plate, anchor)
  end
  SetIcon(frame, path)
  frame:Show()
end

local function Release(plate)
  local frame = active[plate]
  if frame then
    active[plate] = nil
    frame:Hide()
    frame:ClearAllPoints()
    frame:SetParent(UIParent)
    frame.plate, frame.anchor = nil, nil
    pool[#pool + 1] = frame
  end
end

local function ReleaseAll()
  for plate in pairs(active) do
    Release(plate)
  end
end

-- The icon for `unit`'s plate, or nil for none.
local function PathFor(unit)
  if forced and IsTarget(unit) then
    return forced.path
  end
  if UnitIsPlayer(unit) then
    return nil
  end
  return IconForUnit(unit)
end

-- Decide which plates get an icon, show those and release the rest.
-- Idempotent and cheap, so the poll can run it.
local function UpdateAll()
  if forced and GetTime() >= forced.expires then
    forced = nil
  end
  local wanted = {} -- plate -> icon path
  if (enabled or forced) and C_NamePlate and C_NamePlate.GetNamePlates then
    for _, plate in ipairs(C_NamePlate.GetNamePlates()) do
      local unit = PlateUnit(plate)
      if unit and ((enabled and settings.allPlates) or IsTarget(unit)) then
        wanted[plate] = PathFor(unit)
      end
    end
  end
  for plate in pairs(active) do
    if not wanted[plate] then
      Release(plate)
    end
  end
  for plate, path in pairs(wanted) do
    ShowOn(plate, path)
  end
end

local function Update()
  local ok, err = pcall(UpdateAll)
  if not ok then
    -- A failing update must not retry four times a second from the poll.
    enabled = false
    forced = nil
    ReleaseAll()
    Print("creature icon: could not attach to a nameplate; off until /reload. " .. tostring(err))
  end
end

local function UpdateSoon()
  -- a nameplate's own layout settles a frame after it appears
  Update()
  C_Timer.After(0, Update)
end

-- Re-layout and re-anchor every icon after a settings change.
local function Apply()
  version = version + 1
  Update()
end

-- -----------------------------------------------------------------------------
-- Events
-- -----------------------------------------------------------------------------
local events = CreateFrame("Frame")
local runtimeEventsRegistered = false

local function SafeRegister(event)
  return pcall(events.RegisterEvent, events, event)
end

local function RegisterRuntimeEvents()
  if runtimeEventsRegistered then
    return
  end
  runtimeEventsRegistered = true
  SafeRegister("PLAYER_TARGET_CHANGED")
  SafeRegister("NAME_PLATE_UNIT_ADDED")
  SafeRegister("NAME_PLATE_UNIT_REMOVED")
end

local function SetEnabled(on)
  enabled = on and true or false
  if enabled then
    RegisterRuntimeEvents()
    UpdateSoon()
  else
    ReleaseAll()
  end
end

local function Setup()
  SetEnabled(settings.enabled)
end

local function LoadSettings()
  settings = Sanitize(CopyDefaults(addon.GetSaved("creatureIcon")))
end

events:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" then
    if arg1 == addonName then
      LoadSettings()
      events:UnregisterEvent("ADDON_LOADED")
    end
  elseif event == "PLAYER_LOGIN" then
    Setup()
  elseif event == "PLAYER_ENTERING_WORLD" then
    UpdateSoon()
    C_Timer.After(1, Update)
  elseif event == "NAME_PLATE_UNIT_REMOVED" then
    local plate = C_NamePlate.GetNamePlateForUnit(arg1)
    if plate then
      Release(plate)
    end
  else -- PLAYER_TARGET_CHANGED, NAME_PLATE_UNIT_ADDED
    UpdateSoon()
  end
end)
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
if IsLoggedIn and IsLoggedIn() then
  Setup()
end

-- Safety net: re-check the nameplates every POLL_INTERVAL seconds, in case an
-- event this client should send never comes.
local pollElapsed = 0
events:SetScript("OnUpdate", function(_, elapsed)
  if POLL_INTERVAL <= 0 or not (enabled or forced) then
    return
  end
  pollElapsed = pollElapsed + elapsed
  if pollElapsed < POLL_INTERVAL then
    return
  end
  pollElapsed = 0
  Update()
end)

-- -----------------------------------------------------------------------------
-- API for Options.lua (and Tooltip.lua, for the icons)
-- -----------------------------------------------------------------------------
local ci = {}
addon.creatureIcon = ci
ci.DEFAULTS = DEFAULTS
ci.NewIcon = NewIcon
ci.Layout = Layout
ci.SetIcon = SetIcon
ci.IconForType = IconForType
ci.SamplePath = ICONS_BY_ID[SAMPLE_TYPE_ID]

function ci.GetSettings()
  return settings
end

-- Change one setting. The colour goes through SetColor.
function ci.Set(key, value)
  if DEFAULTS[key] == nil or type(DEFAULTS[key]) == "table" or type(value) ~= type(DEFAULTS[key]) then
    return false
  end
  settings[key] = value
  Sanitize(settings)
  if key == "enabled" then
    SetEnabled(settings.enabled)
  else
    Apply()
  end
  return true
end

function ci.SetColor(r, g, b)
  if type(r) ~= "number" or type(g) ~= "number" or type(b) ~= "number" then
    return false
  end
  local c = settings.color
  c[1], c[2], c[3] = r, g, b
  Sanitize(settings)
  Apply()
  return true
end

function ci.Reset()
  for key in pairs(settings) do
    settings[key] = nil
  end
  Sanitize(CopyDefaults(settings))
  SetEnabled(settings.enabled)
  Apply()
end

-- Show the sample icon on the target's nameplate for a few seconds, any target.
function ci.Test()
  if not TargetNamePlate() then
    Print("creature icon: target something that has a nameplate first")
    return false
  end
  forced = { path = ci.SamplePath, expires = GetTime() + TEST_SECONDS }
  Update()
  C_Timer.After(TEST_SECONDS + 0.1, Update)
  return true
end
