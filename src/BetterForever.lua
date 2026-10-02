-- Better Forever: small fixes for the WoW Forever beta client.
--
-- This file: the shared addon table, Print, saved variables and the FPS
-- counter (the client hides the CTRL+R framerate frame on every login and
-- /reload, so we show it again).
--
-- Tooltip.lua        creature type in a box above NPC tooltips
-- CreatureIcon.lua   creature type icon on nameplates
-- ComboPoints.lua    combo points on the target's nameplate
-- WandIndicator.lua  on-screen indicator while Shoot is active
-- SoulShards.lua     deletes excess Soul Shards (warlocks)
-- CinematicUltra.lua the "Cinematic Ultra" graphics CVars, with a backup
-- Options.lua        settings panel and /bb
--
-- The Lua lives in src\; the toc, Bindings.xml and creature_types\ stay at
-- the root, where the client looks for them.
local DEFAULTS = {
  showFPS = true, -- show the FPS counter after login / reload
}

-- seconds after entering the world at which the fixes are (re)applied
local APPLY_DELAYS = { 0.5, 2, 5 }

-- Taint: never write into globals or tables that Blizzard code reads later,
-- Blizzard SavedVariables included. Tainted values spread to whatever reads
-- them and break anything that touches secret values ("attempt to perform
-- string conversion on a secret string value"). Calling methods on Blizzard
-- frames (Show/Hide/SetPoint/HookScript) is fine.

local addonName, addon = ...  -- `addon`: private table shared by every file of this addon
local PREFIX = "|cff66ccffBetter Forever|r: "

local function Print(msg)
  print(PREFIX .. msg)
end
addon.Print = Print

-- Saved variables. One root table, one sub-table per module. Only call this
-- from ADDON_LOADED onwards: before that the client has not loaded the file
-- and would overwrite whatever we created.
function addon.GetSaved(moduleKey)
  if type(BetterForeverDB) ~= "table" then
    BetterForeverDB = {}
  end
  if type(BetterForeverDB[moduleKey]) ~= "table" then
    BetterForeverDB[moduleKey] = {}
  end
  return BetterForeverDB[moduleKey]
end

-- -----------------------------------------------------------------------------
-- General settings (this file's jobs)
-- -----------------------------------------------------------------------------
local function CopyDefaults(into)
  into = into or {}
  for key, default in pairs(DEFAULTS) do
    if type(into[key]) ~= type(default) then
      into[key] = default
    end
  end
  return into
end

local settings = CopyDefaults() -- replaced by the saved table on ADDON_LOADED

-- -----------------------------------------------------------------------------
-- FPS counter. Blizzard_FramerateFrame defines the global FramerateFrame
-- (hidden by default, parented to WorldFrame); CTRL+R runs
-- FramerateFrame:Toggle(), which is just SetShown(not IsShown()). The client
-- starts it hidden on every login and /reload, so it is shown again on the
-- post-PLAYER_ENTERING_WORLD timers while showFPS is on; the options toggle
-- also hides it when switched off.
-- -----------------------------------------------------------------------------
local fpsAnnounced = false

local function HaveFramerateFrame(verbose)
  if type(FramerateFrame) ~= "table" or type(FramerateFrame.Show) ~= "function" then
    if verbose then
      Print("FramerateFrame not found; cannot show FPS")
    end
    return false
  end
  return true
end

local function ApplyFramerate(hideWhenOff)
  if not HaveFramerateFrame() then
    return false
  end
  if settings.showFPS then
    if not FramerateFrame:IsShown() then
      FramerateFrame:Show()
      if not fpsAnnounced then
        fpsAnnounced = true
        Print("FPS counter shown")
      end
    end
  elseif hideWhenOff and FramerateFrame:IsShown() then
    FramerateFrame:Hide()
  end
  return true
end

local function ApplyAll()
  ApplyFramerate()
end

-- -----------------------------------------------------------------------------
-- API for Options.lua
-- -----------------------------------------------------------------------------
local general = {}
addon.general = general
general.DEFAULTS = DEFAULTS

function general.GetSettings()
  return settings
end

function general.Set(key, value)
  if DEFAULTS[key] == nil or type(value) ~= type(DEFAULTS[key]) then
    return false
  end
  settings[key] = value
  if key == "showFPS" then
    ApplyFramerate(true)
  end
  return true
end

-- Reset the given keys (a list), or everything, to DEFAULTS and apply.
function general.Reset(keys)
  if keys then
    for _, key in ipairs(keys) do
      if DEFAULTS[key] ~= nil then
        settings[key] = DEFAULTS[key]
      end
    end
  else
    for key in pairs(settings) do
      settings[key] = nil
    end
    CopyDefaults(settings)
  end
  ApplyFramerate(true)
end

-- Show or hide the FPS counter right now, without touching the setting.
function general.SetFramerateShown(shown)
  if not HaveFramerateFrame(true) then
    return false
  end
  if shown then
    FramerateFrame:Show()
  else
    FramerateFrame:Hide()
  end
  return true
end

-- -----------------------------------------------------------------------------
-- Events
-- -----------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" then
    if arg1 == addonName then
      settings = CopyDefaults(addon.GetSaved("general"))
      eventFrame:UnregisterEvent("ADDON_LOADED")
    end
  elseif event == "PLAYER_ENTERING_WORLD" then -- login and every /reload
    for _, delay in ipairs(APPLY_DELAYS) do
      C_Timer.After(delay, ApplyAll)
    end
  end
end)
