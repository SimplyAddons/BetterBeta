-- Better Forever: creature type (Humanoid, Beast, Undead, ...) above NPC tooltips.
--
-- A small box on top of the tooltip, left-aligned, with the creature type and
-- its icon (same art as the nameplate icon). Players and "Not specified" are
-- skipped. The client already puts the type on the level line ("Level 12
-- Humanoid"), so it's stripped from there to avoid showing it twice.
--
-- Hook: TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit),
-- which runs after the lines are built and before the tooltip is shown.
-- Older clients get GameTooltip's OnTooltipSetUnit instead. The post-call is
-- run via securecallfunction, which does NOT catch errors: an error here
-- aborts the whole tooltip. So the callback is pcall'd and disables itself
-- after the first failure (/reload to retry).
--
-- The box is parented to the tooltip so it shows, fades and hides with it;
-- OnTooltipCleared hides it when the tooltip is refilled. Size comes from
-- measuring the text; a secret type can't be measured and gets a fixed width.

local addonName, addon = ...
local Print = addon.Print or print

-- -----------------------------------------------------------------------------
-- Settings. Edited from the options panel and saved in BetterForeverDB.tooltip;
-- this table is what a fresh save falls back to.
-- -----------------------------------------------------------------------------
local DEFAULTS = {
  enabled = true,
  color = { 0.40, 0.80, 1.00 }, -- text colour (light blue, the addon's own accent colour)
}

local CREATURE_TYPE_NOT_SPECIFIED = 10 -- the id UnitCreatureType returns with "Not specified"

-- The box: its distance from the tooltip, the padding around its text, and the
-- text width assumed when a secret type cannot be measured.
local BOX_GAP = 2
local BOX_PAD_X, BOX_PAD_Y = 8, 5
local BOX_ICON_SIZE, BOX_ICON_GAP = 18, 5 -- the type's icon in front of the text
local BOX_SECRET_WIDTH = 80

-- Blizzard's level line starts with the localised word for "Level" (global
-- string LEVEL): "Level 12", "Level ??", "Level 60 (Elite)".
local levelWord = (type(LEVEL) == "string" and LEVEL ~= "") and LEVEL or "Level"

local function Escape(text)
  return (text:gsub("%p", "%%%0"))
end

local LEVEL_PATTERN = "^" .. Escape(levelWord) .. "%s"

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
  for i = 1, 3 do
    s.color[i] = Clamp(s.color[i], 0, 1)
  end
  return s
end

local settings = Sanitize(CopyDefaults()) -- replaced by the saved table on ADDON_LOADED

-- -----------------------------------------------------------------------------
-- The box. One per tooltip that has shown an NPC (usually just GameTooltip).
-- -----------------------------------------------------------------------------
local boxes = setmetatable({}, { __mode = "k" }) -- tooltip -> its box

-- A dark panel with a thin rim, for a client without TooltipBackdropTemplate.
local function PlainBox(parent)
  local box = CreateFrame("Frame", nil, parent)
  local bg = box:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0.03, 0.03, 0.06, 0.9)
  local edges = {
    { "TOPLEFT", "TOPRIGHT", "SetHeight" }, { "BOTTOMLEFT", "BOTTOMRIGHT", "SetHeight" },
    { "TOPLEFT", "BOTTOMLEFT", "SetWidth" }, { "TOPRIGHT", "BOTTOMRIGHT", "SetWidth" },
  }
  for _, edge in ipairs(edges) do
    local line = box:CreateTexture(nil, "BORDER")
    line:SetColorTexture(0.45, 0.45, 0.5, 1)
    line:SetPoint(edge[1])
    line:SetPoint(edge[2])
    line[edge[3]](line, 1)
  end
  return box
end

local function NewBox(tooltip)
  local ok, box = pcall(CreateFrame, "Frame", nil, tooltip, "TooltipBackdropTemplate")
  if not ok then
    box = PlainBox(tooltip)
  end
  box:Hide()
  box:SetPoint("BOTTOMLEFT", tooltip, "TOPLEFT", 0, BOX_GAP) -- on top of the tooltip, left-aligned
  box.icon = box:CreateTexture(nil, "ARTWORK")
  box.icon:SetSize(BOX_ICON_SIZE, BOX_ICON_SIZE)
  box.icon:SetPoint("LEFT", BOX_PAD_X, 0)
  box.text = box:CreateFontString(nil, "OVERLAY", "GameTooltipText")
  if tooltip.HookScript and (not tooltip.HasScript or tooltip:HasScript("OnTooltipCleared")) then
    tooltip:HookScript("OnTooltipCleared", function() box:Hide() end)
  end
  boxes[tooltip] = box
  return box
end

local function Measured(value, fallback)
  if IsSecret(value) or type(value) ~= "number" or value <= 0 then
    return fallback
  end
  return value
end

-- The type's icon (the nameplate icon's art, looked up by CreatureIcon.lua,
-- which loads after this file) in front of the text; types without one get
-- the text alone.
local function Fill(box, creatureType, typeID)
  local c = settings.color
  box.text:SetText(creatureType)
  box.text:SetTextColor(c[1], c[2], c[3])
  box.text:ClearAllPoints()
  local icons = addon.creatureIcon
  local iconPath = icons and icons.IconForType(creatureType, typeID)
  local iconWidth, iconHeight = 0, 0
  if iconPath then
    icons.SetIcon(box, iconPath)
    box.icon:Show()
    box.text:SetPoint("LEFT", box.icon, "RIGHT", BOX_ICON_GAP, 0)
    iconWidth, iconHeight = BOX_ICON_SIZE + BOX_ICON_GAP, BOX_ICON_SIZE
  else
    box.icon:Hide()
    box.text:SetPoint("LEFT", BOX_PAD_X, 0)
  end
  local _, fontHeight = box.text:GetFont()
  local textHeight = Measured(box.text:GetStringHeight(), fontHeight or 12)
  local width = Measured(box.text:GetStringWidth(), BOX_SECRET_WIDTH) + iconWidth + 2 * BOX_PAD_X
  box:SetSize(width, math.max(textHeight, iconHeight) + 2 * BOX_PAD_Y)
end

local function HideBox(tooltip)
  local box = boxes[tooltip]
  if box then
    box:Hide()
  end
end

local function HideAllBoxes()
  for _, box in pairs(boxes) do
    box:Hide()
  end
end

local function RecolorBoxes()
  local c = settings.color
  for _, box in pairs(boxes) do
    box.text:SetTextColor(c[1], c[2], c[3])
  end
end

-- -----------------------------------------------------------------------------
-- The tooltip work
-- -----------------------------------------------------------------------------
-- "Level 12 Humanoid" / "Level 12 (Humanoid)" -> "Level 12"
local function StripType(text, creatureType)
  local out = text:gsub("%s*%(?" .. Escape(creatureType) .. "%)?%s*", " ", 1)
  return (out:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Take the type off Blizzard's level line: the first line after the name that
-- starts with "Level". Secret line texts are left alone.
local function StripFromLevelLine(tooltip, creatureType)
  local name = tooltip.GetName and tooltip:GetName()
  if not name then
    return
  end
  for i = 2, tooltip:NumLines() do
    local fontString = _G[name .. "TextLeft" .. i]
    local text = fontString and fontString:GetText()
    if not IsSecret(text) and type(text) == "string" and text:find(LEVEL_PATTERN) then
      if text:find(creatureType, 1, true) then
        fontString:SetText(StripType(text, creatureType))
      end
      return
    end
  end
end

local function ShowCreatureType(tooltip)
  local _, unit = tooltip:GetUnit()
  if not unit or not UnitExists(unit) or UnitIsPlayer(unit) then
    HideBox(tooltip)
    return
  end
  local creatureType, typeID = UnitCreatureType(unit)
  if not IsSecret(creatureType) then
    if type(creatureType) ~= "string" or creatureType == ""
      or (not IsSecret(typeID) and typeID == CREATURE_TYPE_NOT_SPECIFIED) then
      HideBox(tooltip)
      return
    end
    StripFromLevelLine(tooltip, creatureType)
  end
  -- A secret type is shown unread; the level line cannot be searched for it.
  local box = boxes[tooltip] or NewBox(tooltip)
  Fill(box, creatureType, typeID)
  box:Show()
end

local stoppedByError = false
local lastError

local function OnUnitTooltip(tooltip)
  if stoppedByError or not settings.enabled then
    return
  end
  if type(tooltip) ~= "table" or type(tooltip.GetUnit) ~= "function" then
    return
  end
  local ok, err = pcall(ShowCreatureType, tooltip)
  if not ok then
    stoppedByError = true
    lastError = tostring(err)
    HideAllBoxes()
    Print("tooltip creature type switched off after an error (/reload retries): " .. lastError)
  end
end

-- -----------------------------------------------------------------------------
-- Hooking. Installed once, on ADDON_LOADED, whether or not the function is on;
-- the callback checks the setting, so turning it on later needs no re-hook.
-- -----------------------------------------------------------------------------
local hooks = {} -- names of the hooks installed (a tooltip handled twice comes out the same)
local hook       -- the same as text; set once something is hooked

local function Callback(tooltip)
  OnUnitTooltip(tooltip)
end

local function Install()
  if hook then
    return hook
  end
  local ok, err = pcall(function()
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall
      and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Unit then
      TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, Callback)
      hooks[#hooks + 1] = "TooltipDataProcessor"
    end
  end)
  if not ok then
    lastError = tostring(err)
  end
  -- The older script handler, gone from retail-engine clients but hooked as
  -- well wherever it still exists.
  if GameTooltip and GameTooltip.HookScript
    and (not GameTooltip.HasScript or GameTooltip:HasScript("OnTooltipSetUnit")) then
    if pcall(GameTooltip.HookScript, GameTooltip, "OnTooltipSetUnit", Callback) then
      hooks[#hooks + 1] = "OnTooltipSetUnit"
    end
  end
  if #hooks > 0 then
    hook = table.concat(hooks, "+")
  elseif lastError then
    Print("tooltip creature type: could not hook the tooltip: " .. lastError)
  else
    Print("tooltip creature type: no tooltip hook available in this client")
  end
  return hook
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" and arg1 == addonName then
    events:UnregisterEvent("ADDON_LOADED")
    settings = Sanitize(CopyDefaults(addon.GetSaved("tooltip")))
    Install()
  end
end)

-- -----------------------------------------------------------------------------
-- API for Options.lua
-- -----------------------------------------------------------------------------
local tip = {}
addon.tooltip = tip
tip.DEFAULTS = DEFAULTS

function tip.GetSettings()
  return settings
end

-- Change one setting. The colour goes through SetColor.
function tip.Set(key, value)
  if DEFAULTS[key] == nil or type(DEFAULTS[key]) == "table" or type(value) ~= type(DEFAULTS[key]) then
    return false
  end
  settings[key] = value
  if key == "enabled" then
    if value then
      stoppedByError = false
      Install()
    else
      HideAllBoxes()
    end
  end
  return true
end

function tip.SetColor(r, g, b)
  if type(r) ~= "number" or type(g) ~= "number" or type(b) ~= "number" then
    return false
  end
  local c = settings.color
  c[1], c[2], c[3] = r, g, b
  Sanitize(settings)
  RecolorBoxes()
  return true
end

function tip.Reset()
  for key in pairs(settings) do
    settings[key] = nil
  end
  Sanitize(CopyDefaults(settings))
  RecolorBoxes()
  stoppedByError = false
  Install()
end
