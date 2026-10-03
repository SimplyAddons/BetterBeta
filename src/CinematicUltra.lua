-- Better Forever: Cinematic Ultra.
--
-- One switch for the 17 graphics CVars from the "Cinematic Ultra" guide: the
-- menu part (render scale 133%, and 2x MSAA instead of the guide's "None",
-- because 133% alone leaves edges jagged) plus its /console block (CAS
-- sharpening, 4K shadow maps, full water reflections and ripples, ground
-- clutter past the slider caps, far object/doodad/terrain detail, heavy
-- weather, every spell particle). See CVARS below.
--
-- Switching on first saves your own value of every CVar in
-- BetterForeverDB.cinematicUltra.original, then applies the Cinematic Ultra
-- values; switching off puts the saved ones back. Off by default and nothing
-- is applied on login or /reload. The game only writes CVars to Config.wtf
-- on a clean logout, and Logout() is protected (an addon can't call it), so
-- every switch ends with a popup, a chat line and a status line on the
-- options page saying you MUST /camp. The page also shows the saved and the
-- live values in two copy boxes, so you can put things back by hand.
--
-- The snapshot is taken on every switch-on, unless one exists and the live
-- values still equal what the last switch-on set (an earlier switch-off never
-- took); then the existing one is kept. The addon never deletes it.
--
-- CVars are read/set via C_CVar (GetCVar/SetCVar on older clients) under
-- pcall; after a set the value is read back and anything the client refused
-- (unknown here, out of range, read-only, locked) is reported in chat and in
-- the popup with the flags from C_CVar.GetCVarInfo.

local addonName, addon = ...
local Print = addon.Print or print

-- -----------------------------------------------------------------------------
-- Settings. Edited from the options panel and saved in
-- BetterForeverDB.cinematicUltra; this table is what a fresh save falls back to.
-- Besides it the saved table holds `original` (name -> value, your own
-- values, saved on switch-on), `originalTakenAt` (when) and `applied` (what
-- the CVars read right after the last switch-on).
-- -----------------------------------------------------------------------------
local DEFAULTS = {
  enabled = false,  -- off by default, it changes your graphics settings
  cityPause = true, -- lighter values inside a capital city, the full set again outside
}

-- The CVars and their Cinematic Ultra values, in the order the options page
-- lists them.
local CVARS = {
  { "RenderScale", "1.333333" },     -- 133% render scale, supersampling (the menu's Render Scale)
  { "ffxAntiAliasingMode", "0" },    -- no FXAA / CMAA blur pass ...
  { "MSAAQuality", "1" },            -- ... but 2x MSAA (MSAA_SAMPLES; the index is looked up at apply time)
  { "ResampleQuality", "3" },        -- FidelityFX CAS sharpening ...
  { "ResampleSharpness", "0.7" },    -- ... at this strength
  { "shadowTextureSize", "2048" },   -- the guide says 4096; this client caps it at 2048
  { "reflectionMode", "3" },         -- full world and character water reflections
  { "rippleDetail", "2" },           -- the guide says 3; this client caps it at 2
  { "groundEffectDensity", "128" },  -- ground clutter past the slider cap (48) ...
  { "groundEffectDist", "500" },     -- ... out to 500 yards (slider cap 320)
  { "lodObjectFadeScale", "200" },   -- doodads fade in twice as far away
  { "lodObjectCullSize", "8" },      -- smaller objects are still drawn
  { "doodadLodScale", "200" },       -- doodad detail at twice the distance
  { "terrainLodDist", "1000" },      -- full-detail terrain out to 1000 yards
  { "weatherDensity", "3" },         -- heaviest weather
  { "graphicsSpellDensity", "2" },   -- the guide says 5; this client caps it at 2
  { "spellClutter", "0" },           -- no culling of "non-essential" spell effects
}

local ULTRA = {} -- name -> Cinematic Ultra value
for _, entry in ipairs(CVARS) do
  ULTRA[entry[1]] = entry[2]
end

-- MSAA: the MSAAQuality CVar is an index into the modes this client supports,
-- not a sample count. MultiSampleAntiAliasingSupported() lists them as triples
-- (mode string "index,coverage", samples, coverage samples), the same list the
-- Anti-Aliasing dropdown is built from. Looked up at apply time; the "1" in
-- CVARS is the fallback if the list can't be read.
local MSAA_SAMPLES = 2

local function MSAAQualityFor(samples)
  if type(MultiSampleAntiAliasingSupported) == "function" then
    local ok, modes = pcall(function() return { MultiSampleAntiAliasingSupported() } end)
    if ok then
      for i = 1, #modes, 3 do
        local mode, sampleCount = modes[i], modes[i + 1]
        if tonumber(sampleCount) == samples and mode ~= nil then
          local index = tostring(mode):match("^[^,]+")
          if index then
            return index
          end
        end
      end
    end
  end
  return ULTRA.MSAAQuality
end

-- ULTRA with the MSAA index resolved for this client.
local function UltraValues()
  ULTRA.MSAAQuality = MSAAQualityFor(MSAA_SAMPLES)
  return ULTRA
end

-- The warning after every switch. Red with /camp in yellow; the colour codes
-- are closed and reopened around /camp so it reads right in chat and in a
-- white font string alike.
local CAMP_WARNING = "|cffff5555You MUST type |r|cffffff00/camp|r|cffff5555 for the settings to take effect: "
  .. "the game saves console variables only on a clean logout.|r"

-- The CVars behind the guide's menu step (Options > Graphics), with the menu
-- setting to do by hand if the client refuses the CVar.
local MENU_SETTINGS = {
  RenderScale = "Render Scale 133%",
  ffxAntiAliasingMode = "Anti-Aliasing: Multisample 2x",
  MSAAQuality = "Anti-Aliasing: Multisample 2x",
}

local cu = {} -- the API, filled in at the bottom

local function IsSecret(value)
  return type(issecretvalue) == "function" and issecretvalue(value) or false
end

local function CopyDefaults(into)
  into = into or {}
  for key, default in pairs(DEFAULTS) do
    if type(into[key]) ~= type(default) then
      into[key] = default
    end
  end
  return into
end

-- A table of CVar name -> value string, or nil; anything else is dropped.
local function CleanValues(values)
  if type(values) ~= "table" then
    return nil
  end
  for name, value in pairs(values) do
    if type(name) ~= "string" or type(value) ~= "string" then
      values[name] = nil
    end
  end
  if next(values) == nil then
    return nil
  end
  return values
end

local function Sanitize(s)
  s.original = CleanValues(s.original)
  s.applied = CleanValues(s.applied)
  if type(s.originalTakenAt) ~= "string" then
    s.originalTakenAt = nil
  end
  return s
end

local settings = Sanitize(CopyDefaults()) -- replaced by the saved table on ADDON_LOADED
local changedThisSession = false -- CVars set since login; only a clean logout saves them

-- -----------------------------------------------------------------------------
-- Reading and writing CVars
-- -----------------------------------------------------------------------------
local function ReadCVar(name)
  local getter = (type(C_CVar) == "table" and C_CVar.GetCVar) or GetCVar
  if type(getter) ~= "function" then
    return nil
  end
  local ok, value = pcall(getter, name)
  if not ok or value == nil or IsSecret(value) then
    return nil
  end
  return tostring(value)
end

-- Two CVar values are the same if they are equal as numbers ("0.7" and
-- "0.69999999", "3" and "3.0"), else as text.
local function SameValue(a, b)
  if a == nil or b == nil then
    return a == b
  end
  local x, y = tonumber(a), tonumber(b)
  if not (x and y) then -- "1,0" style (MSAAQuality): the first field is the value
    x, y = tonumber(tostring(a):match("^[^,]+") or ""), tonumber(tostring(b):match("^[^,]+") or "")
  end
  if x and y then -- rounding, or the slider's 1.33 against 1.333333, is the same value
    local diff = math.abs(x - y)
    return diff < 0.0001 or diff < 0.005 * math.max(math.abs(x), math.abs(y))
  end
  return a == b
end

-- Sets one CVar and reads it back. Returns nil when it took, else a short
-- note for the report: "capped at X" when SetCVar accepted the call but the
-- engine clamped the value (CVARS already carries this client's caps for
-- shadowTextureSize, rippleDetail and graphicsSpellDensity), "rejected, kept X" when
-- SetCVar said no outright, else "kept X"; plus read-only / locked if the
-- client says so, and the default.
local function WriteCVar(name, value)
  local setter = (type(C_CVar) == "table" and C_CVar.SetCVar) or SetCVar
  if type(setter) ~= "function" then
    return "no SetCVar"
  end
  local ok, accepted = pcall(setter, name, value)
  local now = ReadCVar(name)
  if now == nil then
    return "not on this client"
  elseif SameValue(now, value) then
    return nil
  end
  local why = ""
  if type(C_CVar) == "table" and type(C_CVar.GetCVarInfo) == "function" then
    local ok, _, _, _, _, locked, _, readOnly = pcall(C_CVar.GetCVarInfo, name)
    if ok and readOnly then
      why = ", read-only"
    elseif ok and locked then
      why = ", locked"
    end
  end
  local default = ""
  if type(C_CVar) == "table" and type(C_CVar.GetCVarDefault) == "function" then
    local okDefault, value = pcall(C_CVar.GetCVarDefault, name)
    if okDefault and value ~= nil and not IsSecret(value) then
      default = ", default " .. tostring(value)
    end
  end
  local verdict = "kept "
  if ok and accepted == false then
    verdict = "rejected, kept "
  elseif ok and accepted == true and tonumber(now) and tonumber(value) and tonumber(now) < tonumber(value) then
    verdict = "capped at "
  end
  return verdict .. now .. why .. default
end

local function ReadAll()
  local values = {}
  for _, entry in ipairs(CVARS) do
    values[entry[1]] = ReadCVar(entry[1])
  end
  return values
end

-- Sets every CVar that `values` (name -> string) has a value for. Returns how
-- many took, the list of those the client refused as "name (note)", and, when
-- the Cinematic Ultra values were being set and a refused one stands for a
-- menu setting, a hint to do that setting by hand.
local function ApplyValues(values, transient)
  local set, failed, menu, seen = 0, {}, {}, {}
  for _, entry in ipairs(CVARS) do
    local name = entry[1]
    if values[name] ~= nil then
      local note = WriteCVar(name, values[name])
      if note then
        failed[#failed + 1] = name .. " (" .. note .. ")"
        local setting = values == ULTRA and MENU_SETTINGS[name]
        if setting and not seen[setting] then
          seen[setting] = true
          menu[#menu + 1] = setting
        end
      else
        set = set + 1
      end
    end
  end
  if not transient then
    changedThisSession = true
  end
  local hint
  if #menu > 0 then
    hint = "Set by hand under Options > Graphics: " .. table.concat(menu, ", ") .. "."
  end
  return set, failed, hint
end

-- True when every CVar present in both tables holds the same value.
local function SameValues(a, b)
  for _, entry in ipairs(CVARS) do
    local name = entry[1]
    if a[name] ~= nil and b[name] ~= nil and not SameValue(a[name], b[name]) then
      return false
    end
  end
  return true
end

-- Adds to the snapshot the live value of every CVar it lacks: one added to
-- CVARS after the snapshot was taken, which the addon has never set, so its
-- live value is still the original.
local function FillSnapshot(current)
  if not settings.original then
    return
  end
  for _, entry in ipairs(CVARS) do
    local name = entry[1]
    if settings.original[name] == nil and current[name] ~= nil then
      settings.original[name] = current[name]
    end
  end
end

-- Saves the current values as the originals, unless a snapshot exists and the
-- live values are still the ones the last switch-on set (an earlier
-- switch-off never took): then the snapshot is the real original and is
-- kept, filled in for any CVar added since.
local function TakeSnapshot()
  local current = ReadAll()
  if next(current) == nil then
    return false
  end
  if settings.original and settings.applied and SameValues(current, settings.applied) then
    FillSnapshot(current)
    return false
  end
  settings.original = current
  settings.originalTakenAt = date("%Y-%m-%d %H:%M")
  if SameValues(current, UltraValues()) then
    Print("Cinematic Ultra: heads up, the settings just saved as your original ones already match Cinematic Ultra. "
      .. "If that is not what you had before, type your own values in chat and press Save current as original.")
  end
  return true
end

-- True when the snapshot holds every value that can be read right now. The
-- originals must be safe before anything is changed; without them a switch-on
-- would leave nothing to put back.
local function SnapshotCovers()
  if type(settings.original) ~= "table" then
    return false
  end
  for name in pairs(ReadAll()) do
    if settings.original[name] == nil then
      return false
    end
  end
  return true
end

local NO_SNAPSHOT = "Cinematic Ultra was not applied: your current graphics settings could not be saved first, "
  .. "and they must be so they can be put back."

-- -----------------------------------------------------------------------------
-- The popup after a switch: what happened, then the /camp warning in red and
-- large, and one OK button. Our own frame, not a StaticPopupDialogs entry
-- (that table is Blizzard's).
-- -----------------------------------------------------------------------------
local popup

local function BuildPopup()
  popup = CreateFrame("Frame", "BetterForeverCinematicUltraPopup", UIParent,
    BackdropTemplateMixin and "BackdropTemplate" or nil)
  popup:SetSize(440, 180)
  popup:SetPoint("TOP", UIParent, "TOP", 0, -140)
  popup:SetFrameStrata("FULLSCREEN_DIALOG")
  popup:SetToplevel(true)
  popup:EnableMouse(true)
  popup:Hide()
  if popup.SetBackdrop then
    popup:SetBackdrop({
      bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
      edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
      tile = true, tileSize = 32, edgeSize = 32,
      insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    popup:SetBackdropColor(0, 0, 0, 0.92) -- the stock dialog background is too see-through over the options
  else
    local bg = popup:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.85)
  end
  popup.text = popup:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  popup.text:SetPoint("TOP", 0, -22)
  popup.text:SetWidth(390)
  popup.text:SetJustifyH("CENTER")
  popup.text:SetWordWrap(true)

  popup.warning = popup:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  popup.warning:SetPoint("TOP", popup.text, "BOTTOM", 0, -14)
  popup.warning:SetWidth(390)
  popup.warning:SetJustifyH("CENTER")
  popup.warning:SetWordWrap(true)
  popup.warning:SetText(CAMP_WARNING)

  popup.ok = CreateFrame("Button", nil, popup, "UIPanelButtonTemplate")
  popup.ok:SetSize(120, 22)
  popup.ok:SetText("OK")
  popup.ok:SetPoint("BOTTOM", 0, 20)
  popup.ok:SetScript("OnClick", function() popup:Hide() end)
end

local function ShowPopup(text)
  if not popup then
    BuildPopup()
  end
  popup.text:SetText(text)
  -- 22 above the text, 14 between, 18 to the button, the button, 20 below
  popup:SetHeight(popup.text:GetStringHeight() + popup.warning:GetStringHeight() + 96)
  popup:Show()
end

-- After a switch or an "again": the detail (counts, values the client capped
-- or refused, `hint` for menu settings to do by hand) goes to chat; the popup
-- only says on or off and that /camp is needed.
local function Report(on, set, failed, hint)
  local state = on and "Cinematic Ultra is |cff33ff33on|r." or "Cinematic Ultra is |cffff3333off|r."
  local what = state .. " " .. set .. (on and " values set." or " of your own values set back.")
  if #failed > 0 then
    what = what .. " Not taken as given: " .. table.concat(failed, ", ") .. "."
  end
  if hint then
    what = what .. " " .. hint
  end
  Print(what)
  Print(CAMP_WARNING)
  ShowPopup(state)
end

-- -----------------------------------------------------------------------------
-- Capital cities. Inside one the crowd costs the frames, not the scenery, so
-- while Cinematic Ultra is on and cityPause is set the CITY values take its
-- place there and the full set comes back on leaving. One chat line per
-- switch, no popup and no /camp warning: these changes are temporary.
-- -----------------------------------------------------------------------------
local CITY = { -- CVars not listed keep their value
  RenderScale = "1",            -- native resolution
  MSAAQuality = "0",            -- no multisampling
  shadowTextureSize = "1024",   -- small shadow maps
  reflectionMode = "0",         -- no water reflections ...
  rippleDetail = "0",           -- ... or ripples
  groundEffectDensity = "16",   -- little ground clutter ...
  groundEffectDist = "70",      -- ... and only close by
  lodObjectFadeScale = "100",   -- doodads fade at the normal distance
  lodObjectCullSize = "20",     -- small objects are dropped sooner
  doodadLodScale = "100",
  terrainLodDist = "400",
  weatherDensity = "0",         -- no weather
  graphicsSpellDensity = "0",   -- fewest spell effects
}
local CITY_NAMES = {
  ["Stormwind City"] = true, Ironforge = true, Darnassus = true,
  Orgrimmar = true, ["Thunder Bluff"] = true, Undercity = true,
}
local CITY_MAPS = { -- the same six by map id, in case the zone text is not English
  [1453] = true, [1455] = true, [1457] = true, [1454] = true, [1456] = true, [1458] = true,
}

local cityPaused = false -- the CITY values are in place of the Cinematic Ultra ones

local function InCity()
  if type(GetRealZoneText) == "function" then
    local zone = GetRealZoneText()
    if type(zone) == "string" and not IsSecret(zone) and CITY_NAMES[zone] then
      return true
    end
  end
  if type(C_Map) == "table" and type(C_Map.GetBestMapForUnit) == "function" then
    local ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
    if ok and type(mapID) == "number" and not IsSecret(mapID) and CITY_MAPS[mapID] then
      return true
    end
  end
  return false
end

-- Puts the values the current place calls for in effect, if they are not
-- already: CITY inside a capital, the full set outside. Runs on zone changes
-- and on login, so a logout inside a city heals itself on the way out.
local function UpdateCity()
  if not settings.enabled or not settings.cityPause then
    if cityPaused then -- the option went off inside a city: the full set again
      cityPaused = false
      if settings.enabled then
        ApplyValues(UltraValues(), true)
      end
    end
    return
  end
  local inCity = InCity()
  local target = inCity and CITY or UltraValues()
  if inCity ~= cityPaused or not SameValues(ReadAll(), target) then
    ApplyValues(target, true)
  end
  if inCity and not cityPaused then
    Print("Cinematic Ultra |cffffff00paused|r: lighter settings while you are in the city.")
  elseif cityPaused and not inCity then
    Print("Cinematic Ultra |cff33ff33resumed|r.")
  end
  cityPaused = inCity
end

-- -----------------------------------------------------------------------------
-- The switch
-- -----------------------------------------------------------------------------
local function SetEnabled(on)
  on = on and true or false
  if on == settings.enabled then
    return
  end
  if on then
    TakeSnapshot()
    if not SnapshotCovers() then
      Print(NO_SNAPSHOT)
      return
    end
    local set, failed, hint = ApplyValues(UltraValues())
    settings.applied = ReadAll()
    settings.enabled = true
    Report(true, set, failed, hint)
    UpdateCity() -- switched on inside a city: paused at once, with its chat line
  else
    settings.enabled = false
    cityPaused = false
    if not settings.original then
      Print("Cinematic Ultra off, but no original values were saved, so nothing was put back")
      return
    end
    local set, failed = ApplyValues(settings.original)
    Report(false, set, failed)
  end
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("ZONE_CHANGED_NEW_AREA")
events:SetScript("OnEvent", function(self, event, arg1)
  if event == "ADDON_LOADED" and arg1 == addonName then
    settings = Sanitize(CopyDefaults(addon.GetSaved("cinematicUltra")))
    self:UnregisterEvent("ADDON_LOADED")
  elseif event == "PLAYER_ENTERING_WORLD" then
    UpdateCity() -- the map is not always known yet, hence the second look
    C_Timer.After(1, UpdateCity)
  elseif event == "ZONE_CHANGED_NEW_AREA" then
    UpdateCity()
  end
end)

-- -----------------------------------------------------------------------------
-- API for Options.lua
-- -----------------------------------------------------------------------------
addon.cinematicUltra = cu
cu.DEFAULTS = DEFAULTS
cu.CVARS = CVARS
cu.CAMP_WARNING = CAMP_WARNING

function cu.GetSettings()
  return settings
end

-- Change one setting; `enabled` applies or restores and shows the popup.
function cu.Set(key, value)
  if DEFAULTS[key] == nil or type(value) ~= type(DEFAULTS[key]) then
    return false
  end
  if key == "enabled" then
    SetEnabled(value)
  else
    settings[key] = value
    if key == "cityPause" then
      UpdateCity()
    end
  end
  return true
end

-- Back to the defaults: off, which restores the original values. The saved
-- snapshot is kept.
function cu.Reset()
  SetEnabled(false)
end

-- Sets the values for the current state once more: the Cinematic Ultra ones
-- while on, the originals while off.
function cu.ApplyAgain()
  if settings.enabled then
    FillSnapshot(ReadAll())
    if not SnapshotCovers() then
      Print(NO_SNAPSHOT)
      return
    end
    if cityPaused then
      ApplyValues(CITY, true)
      Print("Cinematic Ultra: the lighter city settings are set again; the full set comes back when you leave the city.")
      return
    end
    local set, failed, hint = ApplyValues(UltraValues())
    settings.applied = ReadAll()
    Report(true, set, failed, hint)
  elseif settings.original then
    local set, failed = ApplyValues(settings.original)
    Report(false, set, failed)
  end
end

-- Replaces the snapshot with the live values, for when the saved one is wrong:
-- switching on with a fresh saved file while the Cinematic Ultra values were
-- live records those as the originals. Returns how many values were saved.
function cu.UseCurrentAsOriginal()
  local current = ReadAll()
  if next(current) == nil then
    Print("Cinematic Ultra: no values could be read, nothing saved")
    return 0
  end
  settings.original = current
  settings.originalTakenAt = date("%Y-%m-%d %H:%M")
  local n = 0
  for _ in pairs(current) do
    n = n + 1
  end
  Print("Cinematic Ultra: the current " .. n .. " values are now saved as your original settings")
  return n
end

-- The state in one table, for the options page: whether it is on, whether a
-- snapshot exists and when it was taken, how many of the CVars differ from
-- the values the state calls for, and whether CVars were set this session.
function cu.Status()
  local target = settings.original
  if settings.enabled then
    target = cityPaused and CITY or UltraValues()
  end
  local differ = 0
  if target then
    local current = ReadAll()
    for _, entry in ipairs(CVARS) do
      local want = target[entry[1]]
      if want ~= nil and not SameValue(current[entry[1]], want) then
        differ = differ + 1
      end
    end
  end
  return {
    enabled = settings.enabled,
    paused = cityPaused,
    haveOriginal = settings.original ~= nil,
    takenAt = settings.originalTakenAt,
    differ = differ,
    total = #CVARS,
    unsaved = changedThisSession,
  }
end

-- One "/console name value" line per CVar (can be typed to put a value back
-- by hand), or a "-- name: <note>" line where there is none.
local function ValuesText(values, missingNote)
  local lines = {}
  for i, entry in ipairs(CVARS) do
    local name = entry[1]
    local value = values[name]
    if value == nil then
      lines[i] = "-- " .. name .. ": " .. missingNote
    else
      lines[i] = "/console " .. name .. " " .. value
    end
  end
  return table.concat(lines, "\n")
end

function cu.OriginalText()
  if not settings.original then
    return "(none saved yet: your values are saved the moment Cinematic Ultra is switched on)"
  end
  return ValuesText(settings.original, "was not on this client")
end

function cu.CurrentText()
  return ValuesText(ReadAll(), "not on this client")
end
