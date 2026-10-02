-- Better Forever: on-screen indicator while the wand is shooting.
--
-- Shoot (wand auto-repeat) is easy to lose track of: only its action button
-- flashes. So while it's active the wand icon shows near the middle of the
-- screen with a pulsing rim, a bar that fills up until the next shot and a
-- comic-book word ("ZAP!", "POOF!", "SHAZAM!") that slams in on every shot.
-- When a shot is overdue (out of range, not facing the target) the rim stops
-- pulsing, the icon turns grey and it goes "fizzle...". Hunter Auto Shot too.
--
-- Auto-repeat state comes from START_AUTOREPEAT_SPELL / STOP_AUTOREPEAT_SPELL.
-- After a /reload the server keeps shooting but sends no START, so on
-- PLAYER_ENTERING_WORLD we ask the action bars (C_ActionBar.IsAutoRepeatAction,
-- only works if Shoot is on a bar). Shots: UNIT_SPELLCAST_SUCCEEDED with the
-- Shoot / Auto Shot spell id. Shot interval is the ranged weapon speed
-- (UnitRangedDamage), else the last measured gap. A stall is only reported
-- once at least one shot event has been seen since login.
--
-- The frame is ours on UIParent; nothing of Blizzard's is touched. Secret
-- values (speed, spell id) are checked before use and skipped when secret.

local addonName, addon = ...

-- -----------------------------------------------------------------------------
-- Settings. Edited from the options panel and saved in
-- BetterForeverDB.wandIndicator; this table is what a fresh save falls back to.
-- -----------------------------------------------------------------------------
local DEFAULTS = {
  enabled = true,
  size = 40,                     -- icon width and height
  timer = true,                  -- the bar under the icon that fills up until the next shot
  text = true,                   -- a comic-book sound under it on every shot
  color = { 0.35, 1.00, 0.35 },  -- the rim, the bar and the text
  x = 0,                         -- position of its centre, from the centre of the screen
  y = -150,
}

local LIMITS = { -- numeric settings: { min, max }
  size = { 20, 96 }, x = { -1000, 1000 }, y = { -600, 600 },
}

local SHOT_SPELLS = { [5019] = true, [75] = true } -- Shoot (wands), Auto Shot (hunters)
local RANGED_SLOT = INVSLOT_RANGED or 18
local FALLBACK_ICON = "Interface\\Icons\\Ability_ShootWand"
local ICON_CROP = 0.07          -- trims the built-in rim of Blizzard's icons
local RIM = 3                   -- the pulsing rim around the icon
local BAR_HEIGHT, BAR_GAP = 6, 3
local TEXT_GAP = 4
local STALL_GRACE = 1.0         -- seconds past the weapon's speed without a shot before it fizzles
local STALL_COLOR = { 1.00, 0.35, 0.25 }
local PREVIEW_SPEED = 1.5       -- the pretend weapon speed while unlocked
local ACTION_SLOTS = 180

-- The sounds, one per shot, never the same twice in a row. FIZZLES are for a
-- shot that is overdue.
local WORDS = {
  "ZAP!", "ZZZAP!", "KA-ZAP!", "POOF!", "KAPOOF!", "ZING!", "ZOT!", "PEW!", "PEW PEW!", "FWOOSH!",
  "WHOOSH!", "SHAZAM!", "ALAKAZAM!", "PRESTO!", "KRZZT!", "BZZT!", "FZZT!", "FIZZ!", "SIZZLE!",
  "CRACKLE!", "SHWING!", "VWOOM!", "ZWOOP!", "ZIP!", "KABOOM!",
  "SHAZOOM!", "WHAM!", "HOCUS POCUS!", "ABRACADABRA!",
}
local FIZZLES = { "fizzle...", "pfft...", "sputter...", "*crickets*", "...nothing?", "fzzt..." }

local MAX_TILT = math.rad(12)   -- each word is tilted up to this far either way
local FONT_SCALE = 0.45         -- font size as a share of the icon size
local FONT_MIN, FONT_MAX = 14, 40

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
-- State
-- -----------------------------------------------------------------------------
local enabled = false
local unlocked = false    -- shown all the time and draggable; not saved, a /reload locks it
local shooting = false    -- auto-repeat is on
local runStart            -- GetTime() when it came on
local lastShot            -- GetTime() of the last shot in this run
local shotSpeed           -- seconds between shots, or nil when unknown
local measured            -- the last measured gap between two shots
local shotsSeen = false   -- a shot event has come since login, so a missing one means a stall
local previewStart = 0

local function RangedSpeed()
  local speed = UnitRangedDamage and UnitRangedDamage("player")
  if not IsSecret(speed) and type(speed) == "number" and speed > 0 then
    return speed
  end
end

local function WeaponIcon()
  local texture = GetInventoryItemTexture("player", RANGED_SLOT)
  if IsSecret(texture) or texture then
    return texture
  end
  return FALLBACK_ICON
end

-- -----------------------------------------------------------------------------
-- The indicator: the icon inside a pulsing rim, the bar under it, the text
-- under that.
-- -----------------------------------------------------------------------------
local wi = {} -- the API, filled in at the bottom

local f = CreateFrame("Frame", "BetterForeverWandIndicator", UIParent)
f:Hide()
f:SetFrameStrata("HIGH")
f:SetClampedToScreen(true)
f:SetMovable(true)
f:EnableMouse(false)
f:RegisterForDrag("LeftButton")
if f.SetDontSavePosition then
  f:SetDontSavePosition(true) -- the position is ours, in settings.x / y
end

f.bg = f:CreateTexture(nil, "BACKGROUND")
f.bg:SetAllPoints()
f.bg:SetColorTexture(0, 0, 0, 0.75)

f.icon = f:CreateTexture(nil, "ARTWORK")
f.icon:SetPoint("TOPLEFT", RIM, -RIM)
f.icon:SetPoint("BOTTOMRIGHT", -RIM, RIM)
f.icon:SetTexCoord(ICON_CROP, 1 - ICON_CROP, ICON_CROP, 1 - ICON_CROP)

f.glow = CreateFrame("Frame", nil, f)
f.glow:SetAllPoints()
f.rim = {}
local edges = {
  { "TOPLEFT", 0, 0, "TOPRIGHT", 0, 0, "SetHeight" },
  { "BOTTOMLEFT", 0, 0, "BOTTOMRIGHT", 0, 0, "SetHeight" },
  { "TOPLEFT", 0, -RIM, "BOTTOMLEFT", 0, RIM, "SetWidth" },
  { "TOPRIGHT", 0, -RIM, "BOTTOMRIGHT", 0, RIM, "SetWidth" },
}
for _, e in ipairs(edges) do
  local edge = f.glow:CreateTexture(nil, "OVERLAY")
  edge:SetPoint(e[1], e[2], e[3])
  edge:SetPoint(e[4], e[5], e[6])
  edge[e[7]](edge, RIM)
  f.rim[#f.rim + 1] = edge
end

f.pulse = f.glow:CreateAnimationGroup()
f.pulse:SetLooping("BOUNCE")
local fade = f.pulse:CreateAnimation("Alpha")
fade:SetFromAlpha(1)
fade:SetToAlpha(0.2)
fade:SetDuration(0.5)
fade:SetSmoothing("IN_OUT")

f.bar = CreateFrame("StatusBar", nil, f)
f.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
f.bar:SetMinMaxValues(0, 1)
f.bar:SetHeight(BAR_HEIGHT)
f.bar:SetPoint("TOP", f, "BOTTOM", 0, -BAR_GAP)
f.bar.bg = f.bar:CreateTexture(nil, "BACKGROUND")
f.bar.bg:SetPoint("TOPLEFT", -1, 1)
f.bar.bg:SetPoint("BOTTOMRIGHT", 1, -1)
f.bar.bg:SetColorTexture(0, 0, 0, 0.75)

-- The word sits on a frame of its own, a point under the bar, so one Scale
-- animation on that frame can slam it in (from twice the size) on every shot.
f.wordFrame = CreateFrame("Frame", nil, f)
f.wordFrame:SetSize(1, 1)
f.label = f.wordFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
f.label:SetPoint("CENTER")
local FONT_PATH = (GameFontNormal and GameFontNormal:GetFont()) or "Fonts\\FRIZQT__.TTF"

f.pop = f.wordFrame:CreateAnimationGroup()
local slam = f.pop:CreateAnimation("Scale")
slam:SetScaleFrom(2, 2)
slam:SetScaleTo(1, 1)
slam:SetDuration(0.15)
slam:SetSmoothing("IN")
local flash = f.pop:CreateAnimation("Alpha")
flash:SetFromAlpha(0)
flash:SetToAlpha(1)
flash:SetDuration(0.06)

local function Layout()
  local s = settings
  local width = s.size + 2 * RIM
  f:SetSize(width, width)
  f:ClearAllPoints()
  f:SetPoint("CENTER", UIParent, "CENTER", s.x, s.y)
  f.bar:SetWidth(width)
  local fontSize = Clamp(math.floor(s.size * FONT_SCALE + 0.5), FONT_MIN, FONT_MAX)
  f.label:SetFont(FONT_PATH, fontSize, "THICKOUTLINE")
  f.wordFrame:ClearAllPoints()
  f.wordFrame:SetPoint("CENTER", s.timer and f.bar or f, "BOTTOM", 0, -(TEXT_GAP + fontSize / 2))
  f.wordFrame:SetShown(s.text)
  f.state = nil -- colours are redone on the next frame
end

-- A random word from `list` (never the one showing), slammed in at a tilt.
-- Long words tilt less so they do not swing into the bar.
local function Say(list)
  local i = math.random(#list)
  if list[i] == f.lastWord then
    i = i % #list + 1
  end
  local word = list[i]
  f.lastWord = word
  f.label:SetText(word)
  if f.label.SetRotation then
    local tilt = MAX_TILT * math.min(1, 6 / #word)
    f.label:SetRotation((math.random() * 2 - 1) * tilt)
  end
  if f:IsShown() then
    f.pop:Stop()
    f.pop:Play()
  end
end

local function Restyle(state)
  f.state = state
  local c = state == "stalled" and STALL_COLOR or settings.color
  for _, edge in ipairs(f.rim) do
    edge:SetColorTexture(c[1], c[2], c[3], 1)
  end
  f.bar:SetStatusBarColor(c[1], c[2], c[3])
  f.label:SetTextColor(c[1], c[2], c[3])
  f.icon:SetDesaturated(state == "stalled")
  if state == "stalled" then
    f.pulse:Stop() -- a steady rim: auto-repeat is on but nothing is firing
    Say(FIZZLES)
  elseif not f.pulse:IsPlaying() then
    f.pulse:Play()
  end
end

f:SetScript("OnUpdate", function()
  local now = GetTime()
  local state, speed, since
  if shooting and enabled then
    speed = shotSpeed
    since = now - (lastShot or runStart or now)
    state = (shotsSeen and speed and since > speed + STALL_GRACE) and "stalled" or "shooting"
  else -- unlocked: pretend to fire every PREVIEW_SPEED seconds
    speed = PREVIEW_SPEED
    since = (now - previewStart) % PREVIEW_SPEED
    state = "preview"
    local cycle = math.floor((now - previewStart) / PREVIEW_SPEED)
    if cycle ~= f.previewCycle then
      f.previewCycle = cycle
      Say(WORDS)
    end
  end
  if f.state ~= state then
    Restyle(state)
  end
  local showBar = settings.timer and speed ~= nil
  if f.bar:IsShown() ~= showBar then
    f.bar:SetShown(showBar)
  end
  if showBar then
    f.bar:SetValue(math.min(since / speed, 1))
  end
end)

f:SetScript("OnShow", function()
  f.state = nil
end)
f:SetScript("OnHide", function()
  f.pulse:Stop()
end)

f:SetScript("OnDragStart", function(self)
  if unlocked then
    self:StartMoving()
  end
end)
f:SetScript("OnDragStop", function(self)
  self:StopMovingOrSizing()
  local cx, cy = self:GetCenter()
  local ux, uy = UIParent:GetCenter()
  if cx and ux then
    settings.x, settings.y = cx - ux, cy - uy
    Sanitize(settings)
  end
  Layout()
  if wi.onMoved then
    wi.onMoved()
  end
end)

local function UpdateShown()
  if (enabled and shooting) or unlocked then
    f.icon:SetTexture(WeaponIcon())
    f:SetFrameStrata(unlocked and "DIALOG" or "HIGH") -- unlocked: above the options panel too
    f:EnableMouse(unlocked)
    f.state = nil
    f:Show()
  else
    f:EnableMouse(false)
    f:Hide()
  end
end

-- -----------------------------------------------------------------------------
-- Auto-repeat and shots
-- -----------------------------------------------------------------------------
local function StartRun()
  shooting = true
  runStart, lastShot = GetTime(), nil
  shotSpeed = RangedSpeed() or measured
end

local function OnShot()
  local now = GetTime()
  local first = lastShot == nil
  if lastShot then
    local gap = now - lastShot
    if gap > 0.3 and gap < 6 then
      measured = gap
    end
  end
  lastShot = now
  shotsSeen = true
  shotSpeed = RangedSpeed() or measured
  -- a first shot right on the heels of the start keeps the start's word
  if not (first and now - runStart < 0.3) then
    Say(WORDS)
  end
end

-- Whether any action button's spell is auto-repeating right now.
local function ActionBarsShooting()
  local IsAutoRepeat = (C_ActionBar and C_ActionBar.IsAutoRepeatAction) or IsAutoRepeatAction
  if not IsAutoRepeat then
    return false
  end
  for slot = 1, ACTION_SLOTS do
    local ok, on = pcall(IsAutoRepeat, slot)
    if ok and not IsSecret(on) and on == true then
      return true
    end
  end
  return false
end

local function SetEnabled(on)
  enabled = on and true or false
  if not enabled then
    unlocked = false
  end
  UpdateShown()
end

local events = CreateFrame("Frame")
events:SetScript("OnEvent", function(_, event, arg1, _, arg3)
  if event == "ADDON_LOADED" then
    if arg1 == addonName then
      settings = Sanitize(CopyDefaults(addon.GetSaved("wandIndicator")))
      Layout()
      events:UnregisterEvent("ADDON_LOADED")
    end
  elseif event == "PLAYER_LOGIN" then
    SetEnabled(settings.enabled)
  elseif event == "START_AUTOREPEAT_SPELL" then
    StartRun()
    UpdateShown()
    Say(WORDS)
  elseif event == "STOP_AUTOREPEAT_SPELL" then
    shooting = false
    UpdateShown()
  elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
    if shooting and not IsSecret(arg3) and SHOT_SPELLS[arg3] then
      OnShot()
    end
  elseif event == "PLAYER_ENTERING_WORLD" then
    if not shooting and ActionBarsShooting() then
      StartRun()
      UpdateShown()
      Say(WORDS)
    else
      UpdateShown()
    end
  end
end)
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("START_AUTOREPEAT_SPELL")
events:RegisterEvent("STOP_AUTOREPEAT_SPELL")
events:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
Layout()
if IsLoggedIn and IsLoggedIn() then
  SetEnabled(settings.enabled)
end

-- -----------------------------------------------------------------------------
-- API for Options.lua
-- -----------------------------------------------------------------------------
addon.wandIndicator = wi
wi.DEFAULTS = DEFAULTS
wi.onMoved = nil -- set by Options.lua: called after the indicator was dragged

function wi.GetSettings()
  return settings
end

-- Change one setting. The colour goes through SetColor.
function wi.Set(key, value)
  if DEFAULTS[key] == nil or type(DEFAULTS[key]) == "table" or type(value) ~= type(DEFAULTS[key]) then
    return false
  end
  settings[key] = value
  Sanitize(settings)
  if key == "enabled" then
    SetEnabled(settings.enabled)
  else
    Layout()
  end
  return true
end

function wi.SetColor(r, g, b)
  if type(r) ~= "number" or type(g) ~= "number" or type(b) ~= "number" then
    return false
  end
  local c = settings.color
  c[1], c[2], c[3] = r, g, b
  Sanitize(settings)
  f.state = nil
  return true
end

function wi.Reset()
  for key in pairs(settings) do
    settings[key] = nil
  end
  Sanitize(CopyDefaults(settings))
  Layout()
  SetEnabled(settings.enabled)
end

-- Unlocked: shown all the time, firing pretend shots, and draggable.
function wi.SetUnlocked(on)
  unlocked = (on and enabled) and true or false
  previewStart, f.previewCycle = GetTime(), nil
  UpdateShown()
end

function wi.IsUnlocked()
  return unlocked
end
