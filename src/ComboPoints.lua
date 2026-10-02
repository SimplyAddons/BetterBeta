-- Better Forever: combo points on the target's nameplate.
--
-- Blizzard's nameplate code (SetupClassNameplateBars) only ever puts class
-- resources on the player's own personal nameplate, so this draws its own row
-- of points and parents it to whichever nameplate belongs to the current
-- target; it follows that plate's position, scale and fade. Rogues always,
-- druids in cat form.
--
-- Secret values: UnitPower("player", ComboPoints) is a secret number on this
-- client; Lua may not compare, add, concatenate, tostring or format it, only
-- hand it to a widget. So every point is a stack of tiny StatusBars whose
-- min/max ranges decide "is point i lit?" inside the widget:
--   border + empty  range 0..1        visible once there is at least one point
--   fill            range i-1..i      lit when current >= i
--   full            range max-1..max  the max colour on every point at max
-- The same value goes into all of them and is never looked at here.
--
-- Restricted regions: nothing on a nameplate, nor the row once attached, is
-- ever measured ("Can't measure restricted regions"). The row is placed from
-- Blizzard's known layout: the name sits 2 above the health bar and is one
-- line of SystemFont_NamePlate tall, measured on our own FontString under
-- UIParent. Only SetParent/SetPoint/IsShown and frame levels touch the plate,
-- and the attach step runs under pcall: a failure reports once and switches
-- the function off until /reload.

local addonName, addon = ...
local Print = addon.Print or print

-- -----------------------------------------------------------------------------
-- Settings. Edited from the options panel and saved in
-- BetterForeverDB.comboPoints; this table is what a fresh save falls back to.
-- -----------------------------------------------------------------------------
local DEFAULTS = {
  enabled = true,
  shape = "dot",         -- "dot", "square" or "rectangle"
  size = 9,              -- dot diameter, square side, rectangle height
  width = 14,            -- rectangle width
  spacing = 3,           -- gap between points
  border = false,        -- dark rim around each point, like Blizzard's resource displays
  borderSize = 1,        -- rim thickness
  position = "above",    -- "above" the name, "below" the health bar, or "center" on the health bar
  offsetX = 0,           -- nudge right (+) / left (-); 0 = centred on the health bar
  offsetY = 0,           -- nudge up (+) / down (-)
  showEmpty = false,     -- keep the unlit points visible at 0 points
  color = { 1.00, 0.82, 0.00, 1.00 },       -- lit point
  colorMax = { 1.00, 0.25, 0.25, 1.00 },    -- every point once at max points
  colorEmpty = { 0.20, 0.20, 0.20, 0.80 },  -- unlit point
  colorBorder = { 0.00, 0.00, 0.00, 0.90 }, -- rim
}

local CP_CLASSES = { ROGUE = true, DRUID = true } -- any other class registers nothing
local POLL_INTERVAL = 0.1 -- seconds; safety-net re-read while a target has a nameplate (0 = events only)

local POWER_COMBO = (Enum and Enum.PowerType and Enum.PowerType.ComboPoints) or 4
local MAX_DOTS = 10
local DEFAULT_MAX = 5
local TEST_SECONDS = 8
local NAME_GAP = 2                   -- Blizzard anchors UnitFrame.name this far above HealthBarsContainer
local EDGE_GAP = 2                   -- breathing room between the row and the name / health bar
local NAME_LINE_HEIGHT_FALLBACK = 12 -- used if the nameplate font can't be measured

local SHAPES = { dot = true, square = true, rectangle = true }
local POSITIONS = { above = true, below = true, center = true }
local SHAPE_TEXTURE = {
  dot = "Interface\\CharacterFrame\\TempPortraitAlphaMask", -- plain white disc, in every client
  square = "Interface\\Buttons\\WHITE8X8",
  rectangle = "Interface\\Buttons\\WHITE8X8",
}
local COLOR_KEYS = { "color", "colorMax", "colorEmpty", "colorBorder" }
local LIMITS = { -- numeric settings: { min, max }
  size = { 3, 40 }, width = { 3, 80 }, spacing = { 0, 20 }, borderSize = { 1, 4 },
  offsetX = { -200, 200 }, offsetY = { -200, 200 },
}

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
      for i = 1, 4 do
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
  if not SHAPES[s.shape] then s.shape = DEFAULTS.shape end
  if not POSITIONS[s.position] then s.position = DEFAULTS.position end
  for key, limit in pairs(LIMITS) do
    s[key] = Clamp(math.floor(s[key] + 0.5), limit[1], limit[2])
  end
  for _, key in ipairs(COLOR_KEYS) do
    for i = 1, 4 do
      s[key][i] = Clamp(s[key][i], 0, 1)
    end
  end
  return s
end

local settings = Sanitize(CopyDefaults()) -- replaced by the saved table on ADDON_LOADED

-- -----------------------------------------------------------------------------
-- A row of points. One is parented onto the target's nameplate; the options
-- panel makes two more for its preview. Each point is four StatusBars drawn
-- with the shape's texture, stacked border < empty < fill < full.
-- -----------------------------------------------------------------------------
local BAR_ORDER = { "border", "empty", "fill", "full" }
local Row = {}
Row.__index = Row

local function NewRow(parent, name)
  local row = setmetatable({ frame = CreateFrame("Frame", name, parent), dots = {}, max = 0 }, Row)
  row.frame:SetSize(1, 1)
  return row
end

local function NewBar(parent)
  local bar = CreateFrame("StatusBar", nil, parent)
  bar:SetStatusBarTexture(SHAPE_TEXTURE.dot)
  bar:SetMinMaxValues(0, 1)
  bar:SetValue(0)
  return bar
end

local function SetBarColor(bar, c)
  bar:SetStatusBarColor(c[1], c[2], c[3], c[4])
end

function Row:EnsureDots(max)
  for i = #self.dots + 1, max do
    local dot = {}
    for _, key in ipairs(BAR_ORDER) do
      dot[key] = NewBar(self.frame)
    end
    self.dots[i] = dot
  end
end

function Row:Restack()
  local base = self.frame:GetFrameLevel()
  for _, dot in ipairs(self.dots) do
    for level, key in ipairs(BAR_ORDER) do
      dot[key]:SetFrameLevel(base + level)
    end
  end
end

-- (Re)build the row for `max` points from the current settings.
function Row:Layout(max)
  local s = settings
  max = max or self.max
  if max < 1 then max = DEFAULT_MAX end
  self:EnsureDots(max)
  self.max = max

  local w = (s.shape == "rectangle") and s.width or s.size
  local h = s.size
  local texture = SHAPE_TEXTURE[s.shape] or SHAPE_TEXTURE.dot
  local rim = s.border and s.borderSize or 0
  -- With showEmpty the empty layers get the range -1..0: any real value is
  -- >= 0, so they are always full without Lua ever testing the value.
  local emptyMin, emptyMax = 0, 1
  if s.showEmpty then
    emptyMin, emptyMax = -1, 0
  end

  self.frame:SetSize(max * w + (max - 1) * s.spacing, h + 2 * rim)
  for i, dot in ipairs(self.dots) do
    local x = (i - 1) * (w + s.spacing) + w / 2
    for _, key in ipairs(BAR_ORDER) do
      local bar = dot[key]
      bar:ClearAllPoints()
      bar:SetPoint("CENTER", self.frame, "LEFT", x, 0)
      bar:SetStatusBarTexture(texture)
      bar:SetSize(w, h)
      bar:SetShown(i <= max and (key ~= "border" or rim > 0))
    end
    dot.border:SetSize(w + 2 * rim, h + 2 * rim)
    dot.border:SetMinMaxValues(emptyMin, emptyMax)
    dot.empty:SetMinMaxValues(emptyMin, emptyMax)
    dot.fill:SetMinMaxValues(i - 1, i)
    dot.full:SetMinMaxValues(max - 1, max)
    SetBarColor(dot.border, s.colorBorder)
    SetBarColor(dot.empty, s.colorEmpty)
    SetBarColor(dot.fill, s.color)
    SetBarColor(dot.full, s.colorMax)
  end
  self:Restack()
end

-- Push the (possibly secret) point count into every bar. Nothing here reads it.
function Row:SetValue(current)
  for i = 1, self.max do
    local dot = self.dots[i]
    for _, key in ipairs(BAR_ORDER) do
      dot[key]:SetValue(current)
    end
  end
end

local plateRow = NewRow(UIParent, "BetterForeverComboPoints")
local container = plateRow.frame
container:Hide()

-- -----------------------------------------------------------------------------
-- Reading the points and deciding whether this character uses them
-- -----------------------------------------------------------------------------

-- Current points. A secret number on this client: hand it to a Row and
-- nothing else.
local function ReadCurrent()
  if UnitPower then
    return UnitPower("player", POWER_COMBO)
  elseif GetComboPoints then
    return GetComboPoints("player", "target")
  end
  return 0
end

-- Maximum points; a plain number so far, but fall back to 5 if it ever isn't.
local function ReadMax()
  local max = UnitPowerMax and UnitPowerMax("player", POWER_COMBO)
  if type(max) ~= "number" or IsSecret(max) or max < 1 then
    max = DEFAULT_MAX
  end
  return math.min(max, MAX_DOTS)
end

local playerClass -- class file name ("ROGUE"), resolved at login

local function ClassUsesComboPoints()
  if not playerClass then
    local _, class = UnitClass("player")
    playerClass = class
  end
  return playerClass ~= nil and CP_CLASSES[playerClass] == true
end

local function UsesComboPoints()
  if not ClassUsesComboPoints() then
    return false
  end
  if playerClass == "DRUID" and GetShapeshiftFormID then
    local form = GetShapeshiftFormID()
    return not IsSecret(form) and form == (CAT_FORM or 1)
  end
  return true
end

-- -----------------------------------------------------------------------------
-- Attaching to the target's nameplate. Blizzard's layout (NamePlateUnitFrame
-- UpdateAnchors), bottom to top: cast bar, HealthBarsContainer, name. The
-- name is NAME_GAP above the health bar and one line of SystemFont_NamePlate
-- tall, and its width varies with the health text, so "above" centres on the
-- health bar and rises by that known height.
-- -----------------------------------------------------------------------------
local probe = CreateFrame("Frame", nil, UIParent):CreateFontString(nil, "ARTWORK")
if SystemFont_NamePlate then
  pcall(probe.SetFontObject, probe, SystemFont_NamePlate)
end

local function NameRise()
  if NamePlateSetupOptions and NamePlateSetupOptions.unitNameInsideHealthBar then
    return 0
  end
  local ok, lineHeight = pcall(probe.GetLineHeight, probe)
  if not ok or type(lineHeight) ~= "number" or lineHeight <= 0 then
    lineHeight = NAME_LINE_HEIGHT_FALLBACK
  end
  return lineHeight + NAME_GAP
end

local attachedPlate, attachedUnitFrame

local function Detach(force)
  if not attachedPlate and not force then
    return
  end
  attachedPlate, attachedUnitFrame = nil, nil
  container:Hide()
  container:ClearAllPoints()
  container:SetParent(UIParent)
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

-- Only SetParent/SetPoint/IsShown and frame-level calls touch the nameplate.
local function Attach(plate)
  local s = settings
  local unitFrame = plate.UnitFrame
  local bars = unitFrame and (unitFrame.HealthBarsContainer or unitFrame.healthBar)
  local name = unitFrame and unitFrame.name

  container:ClearAllPoints()
  container:SetParent(plate)
  container:SetFrameStrata(plate:GetFrameStrata())
  container:SetFrameLevel(((unitFrame and unitFrame:GetFrameLevel()) or plate:GetFrameLevel()) + 10)
  plateRow:Restack()

  local barsShown = bars and bars:IsShown()
  if s.position == "below" and barsShown then
    container:SetPoint("TOP", bars, "BOTTOM", s.offsetX, s.offsetY - EDGE_GAP)
  elseif s.position == "center" and barsShown then
    container:SetPoint("CENTER", bars, "CENTER", s.offsetX, s.offsetY)
  elseif barsShown then
    local rise = (name and name:IsShown()) and NameRise() or 0
    container:SetPoint("BOTTOM", bars, "TOP", s.offsetX, s.offsetY + rise + EDGE_GAP)
  elseif name then
    container:SetPoint("BOTTOM", name, "TOP", s.offsetX, s.offsetY + EDGE_GAP)
  else
    container:SetPoint("BOTTOM", plate, "TOP", s.offsetX, s.offsetY + EDGE_GAP)
  end

  attachedPlate, attachedUnitFrame = plate, unitFrame
end

-- -----------------------------------------------------------------------------
-- Update: idempotent and cheap (a handful of SetValue calls) so the poll can
-- run it. The row is shown whenever the target has a nameplate and this
-- character uses combo points; at 0 points every bar is empty, so nothing is
-- drawn, which is how "hidden at 0" works without reading the value.
-- -----------------------------------------------------------------------------
local enabled = false
local forced   -- { count = n, expires = GetTime() } while a test display is running

local function Update(force)
  if forced and GetTime() >= forced.expires then
    forced = nil
  end
  if not enabled and not forced then
    Detach()
    return
  end

  local plate = TargetNamePlate()
  if not plate then
    Detach()
    return
  end

  if not forced and not UsesComboPoints() then
    container:Hide() -- druid out of cat form
    return
  end

  if force or plate ~= attachedPlate or plate.UnitFrame ~= attachedUnitFrame then
    local ok, err = pcall(Attach, plate)
    if not ok then
      -- A failing attach must not retry ten times a second from the poll.
      enabled = false
      forced = nil
      Detach(true)
      Print("combo points: could not attach to the target nameplate; off until /reload. " .. tostring(err))
      return
    end
  end

  local max = ReadMax()
  if max ~= plateRow.max then
    plateRow:Layout(max)
  end

  local current
  if forced then
    current = math.min(forced.count, max)
  else
    current = ReadCurrent()
  end
  plateRow:SetValue(current)
  container:Show()
end

local function UpdateSoon()
  -- the nameplate's own layout settles a frame after it appears / is targeted
  Update(true)
  C_Timer.After(0, function() Update(true) end)
end

-- Re-layout and re-anchor after a settings change.
local function Apply()
  if plateRow.max > 0 then
    plateRow:Layout(plateRow.max)
  end
  Update(true)
end

-- -----------------------------------------------------------------------------
-- Events
-- -----------------------------------------------------------------------------
local events = CreateFrame("Frame")
local runtimeEventsRegistered = false

local function SafeRegister(event, ...)
  if select("#", ...) > 0 and events.RegisterUnitEvent then
    if pcall(events.RegisterUnitEvent, events, event, ...) then
      return true
    end
  end
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
  SafeRegister("UNIT_POWER_UPDATE", "player", "target")
  SafeRegister("UNIT_POWER_FREQUENT", "player", "target")
  SafeRegister("UNIT_MAXPOWER", "player")
  SafeRegister("UPDATE_SHAPESHIFT_FORM")
end

local function SetEnabled(on)
  enabled = (on and ClassUsesComboPoints()) or false
  if enabled then
    RegisterRuntimeEvents()
    UpdateSoon()
  else
    Detach(true)
  end
end

local function Setup()
  local _, class = UnitClass("player")
  playerClass = class or playerClass
  SetEnabled(settings.enabled)
end

events:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" then
    if arg1 == addonName then
      settings = Sanitize(CopyDefaults(addon.GetSaved("comboPoints")))
      events:UnregisterEvent("ADDON_LOADED")
    end
  elseif event == "PLAYER_LOGIN" then
    Setup()
  elseif event == "PLAYER_ENTERING_WORLD" then
    UpdateSoon()
    C_Timer.After(1, function() Update(true) end)
  elseif event == "PLAYER_TARGET_CHANGED" then
    UpdateSoon()
  elseif event == "NAME_PLATE_UNIT_ADDED" then
    if IsTarget(arg1) then
      UpdateSoon()
    end
  elseif event == "NAME_PLATE_UNIT_REMOVED" then
    if attachedPlate and (C_NamePlate.GetNamePlateForUnit(arg1) == attachedPlate or IsTarget(arg1)) then
      Detach()
    end
  elseif event == "UNIT_POWER_UPDATE" or event == "UNIT_POWER_FREQUENT" then
    Update() -- the power type arrives as arg2 and may be secret, so every update is taken
  elseif event == "UNIT_MAXPOWER" or event == "UPDATE_SHAPESHIFT_FORM" then
    Update(true)
  end
end)
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
if IsLoggedIn and IsLoggedIn() then
  Setup()
end

-- Safety net: while a target has a nameplate re-push the points every
-- POLL_INTERVAL seconds, in case an event this client should send never comes.
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
  if attachedPlate or UnitExists("target") then
    Update()
  end
end)

-- -----------------------------------------------------------------------------
-- API for Options.lua
-- -----------------------------------------------------------------------------
local cp = {}
addon.comboPoints = cp
cp.DEFAULTS = DEFAULTS
cp.NewRow = NewRow

function cp.GetSettings()
  return settings
end

function cp.ClassUsesComboPoints()
  return ClassUsesComboPoints()
end

-- Change one setting and apply it. Colours go through SetColor.
function cp.Set(key, value)
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

function cp.SetColor(key, r, g, b, a)
  local c = settings[key]
  if type(DEFAULTS[key]) ~= "table" or type(c) ~= "table" then
    return false
  end
  c[1], c[2], c[3], c[4] = r, g, b, a or 1
  Sanitize(settings)
  Apply()
  return true
end

function cp.Reset()
  for key in pairs(settings) do
    settings[key] = nil
  end
  Sanitize(CopyDefaults(settings))
  SetEnabled(settings.enabled)
  Apply()
end

-- Show `count` lit points on the target's nameplate for a few seconds, any class.
function cp.Test(count)
  if not TargetNamePlate() then
    Print("combo points: target something that has a nameplate first")
    return false
  end
  forced = { count = count or 3, expires = GetTime() + TEST_SECONDS }
  Update(true)
  C_Timer.After(TEST_SECONDS + 0.1, function() Update(true) end)
  return true
end
