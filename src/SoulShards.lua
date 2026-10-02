-- Better Forever: Soul Shard reaper (warlocks).
--
-- Drain Soul gives a shard per kill and the bags fill up. This keeps the
-- count at a limit (maxShards, default 3) by deleting the ones above it.
--
-- The catch: the client only lets an addon destroy an item while handling the
-- player's own keypress or click, never from a timer or bag event (from there
-- all you can do is pop up a "destroy item?" dialog), and only ONE deletion
-- per keypress. So the deleting happens from inside the Drain Soul macro on
-- the options page ("/bf reap"), from the keybind (Bindings.xml ->
-- BetterForever_ReapShards) or from the button on the page; each press removes
-- one shard. The shard from the current kill arrives after the channel ends
-- and gets cleaned up on the next cast. If the bags are full and we're at the
-- limit, one shard is deleted anyway so the incoming one has a slot.
--
-- Based on the ShardReaper addon. Uses its own command and macro name so the
-- two don't clash if both are loaded.
--
-- Item ids come from C_Container.GetContainerItemInfo (item link as fallback)
-- and are checked with issecretvalue; a secret one counts as not a shard.
-- Each reap is pcall'd: one failure prints and disables the feature until
-- /reload (the saved toggle is left alone).

local addonName, addon = ...
local Print = addon.Print or print

-- -----------------------------------------------------------------------------
-- Settings. Edited from the options panel and saved in
-- BetterForeverDB.soulShards; this table is what a fresh save falls back to.
-- -----------------------------------------------------------------------------
local DEFAULTS = {
  enabled = false, -- off by default: it destroys items
  maxShards = 3,   -- how many Soul Shards to keep; the rest go
}

local LIMITS = { -- numeric settings: { min, max }
  maxShards = { 0, 50 },
}

local SOUL_SHARD_ITEM_ID = 6265
local SOUL_BAG_FAMILY = 4 -- the bag family bit of Soul Bags; a free slot there takes a shard

-- The Drain Soul macro. "/bf reap" runs inside the keypress, which is the
-- only time the client lets an addon destroy an item.
local MACRO_NAME = "Reap Shards"
local MACRO_ICON = "Spell_Shadow_Haunting" -- Drain Soul's icon
local MACRO_BODY = "#showtooltip Drain Soul\n/bf reap\n/cast Drain Soul"

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
    if type(into[key]) ~= type(default) then
      into[key] = default
    end
  end
  return into
end

local function Sanitize(s)
  for key, limit in pairs(LIMITS) do
    s[key] = Clamp(math.floor(s[key] + 0.5), limit[1], limit[2])
  end
  return s
end

local settings = Sanitize(CopyDefaults()) -- replaced by the saved table on ADDON_LOADED
local broken = false -- set after an error: off until /reload

-- -----------------------------------------------------------------------------
-- Finding and deleting shards
-- -----------------------------------------------------------------------------

-- The bags to scan: backpack and the four bags, plus the reagent bag where
-- the client has one.
local function BagIndexes()
  local E = Enum and Enum.BagIndex
  if E and E.Backpack and E.Bag_1 and E.Bag_2 and E.Bag_3 and E.Bag_4 then
    local bags = { E.Backpack, E.Bag_1, E.Bag_2, E.Bag_3, E.Bag_4 }
    if E.ReagentBag then
      bags[#bags + 1] = E.ReagentBag
    end
    return bags
  end
  return { 0, 1, 2, 3, 4 }
end

local function IsSoulShard(bag, slot)
  local info = C_Container.GetContainerItemInfo(bag, slot)
  if type(info) ~= "table" then
    return false
  end
  local id = info.itemID
  if id ~= nil and not IsSecret(id) then
    return id == SOUL_SHARD_ITEM_ID
  end
  local link = info.hyperlink or C_Container.GetContainerItemLink(bag, slot)
  return type(link) == "string" and not IsSecret(link) and link:find("Soul Shard", 1, true) ~= nil
end

-- Every Soul Shard in the bags, as { bag, slot }, and how many of them are
-- over the limit.
local function FindShards()
  local found = {}
  for _, bag in ipairs(BagIndexes()) do
    local slots = C_Container.GetContainerNumSlots(bag)
    if type(slots) ~= "number" or IsSecret(slots) then
      slots = 0
    end
    for slot = 1, slots do
      if IsSoulShard(bag, slot) then
        found[#found + 1] = { bag = bag, slot = slot }
      end
    end
  end
  return found, math.max(#found - settings.maxShards, 0)
end

-- True when a free slot can take a Soul Shard: one in a plain bag or a Soul
-- Bag (quivers, herb bags and the like cannot).
local function HasRoomForShard()
  for _, bag in ipairs(BagIndexes()) do
    local free, family = C_Container.GetContainerNumFreeSlots(bag)
    if type(free) == "number" and not IsSecret(free) and free > 0 then
      if type(family) ~= "number" or IsSecret(family) then
        family = 0
      end
      if family == 0 or bit.band(family, SOUL_BAG_FAMILY) ~= 0 then
        return true
      end
    end
  end
  return false
end

-- Deletes one Soul Shard over the limit. Must run inside the player's own
-- keypress or click (macro, keybind, button); the client destroys one item
-- per keypress and silently ignores more, so each call removes one and says
-- how many are still over. quiet: print nothing unless a shard goes.
-- makeRoom: a cast follows, so if the bags are full and we're at the limit,
-- delete one shard to give the incoming one a slot.
local function DeleteOne(quiet, makeRoom)
  local shards, excess = FindShards()
  local total = #shards
  local madeRoom = false
  if makeRoom and excess == 0 and total > 0 and not HasRoomForShard() then
    excess, madeRoom = 1, true
  end
  if excess == 0 then
    if not quiet then
      Print(total .. " Soul Shard(s) found, nothing to delete (keeping up to " .. settings.maxShards .. ")")
    end
    return false
  end

  ClearCursor()
  C_Container.PickupContainerItem(shards[1].bag, shards[1].slot)
  if not CursorHasItem() then
    ClearCursor()
    if not quiet then
      Print("could not pick up a Soul Shard to delete; try again in a moment")
    end
    return false
  end
  DeleteCursorItem()

  local left, over = total - 1, excess - 1
  if madeRoom then
    Print("bags full: deleted 1 Soul Shard to make room for the next one (keeping " .. left .. ")")
  elseif over > 0 then
    Print("deleted 1 Soul Shard, " .. over .. " more over the limit; the game allows one deletion per keypress, so the next "
      .. (quiet and "cast" or "click") .. " removes another")
  else
    Print("deleted 1 Soul Shard, keeping " .. left)
  end
  return true
end

-- One reap under pcall. Silent while the function is off (the macro runs on
-- every cast); a failure reports once and stops it until /reload.
local function Run(quiet, makeRoom)
  if broken or not settings.enabled then
    return
  end
  if type(C_Container) ~= "table" then
    broken = true
    Print("soul shards: C_Container is not on this client; off until /reload")
    return
  end
  local ok, err = pcall(DeleteOne, quiet, makeRoom)
  if not ok then
    broken = true
    pcall(ClearCursor)
    Print("soul shards: " .. tostring(err) .. "; off until /reload")
  end
end

-- -----------------------------------------------------------------------------
-- The macro
-- -----------------------------------------------------------------------------
local function CreateReapMacro()
  if InCombatLockdown() then
    Print("macros cannot be created in combat")
    return false
  end
  local index = GetMacroIndexByName(MACRO_NAME)
  if index and index > 0 then
    EditMacro(index, MACRO_NAME, MACRO_ICON, MACRO_BODY)
    Print("updated the '" .. MACRO_NAME .. "' macro; drag it from /macro onto your action bar in place of Drain Soul")
    return true
  end
  local numGlobal, numPerChar = GetNumMacros()
  local perCharacter
  if (numGlobal or 0) < (MAX_ACCOUNT_MACROS or 120) then
    perCharacter = false
  elseif (numPerChar or 0) < (MAX_CHARACTER_MACROS or 18) then
    perCharacter = true
  else
    Print("no free macro slot; delete a macro in /macro and try again, or copy the macro text by hand")
    return false
  end
  CreateMacro(MACRO_NAME, MACRO_ICON, MACRO_BODY, perCharacter)
  Print("created the '" .. MACRO_NAME .. "' macro; open /macro and drag it onto your action bar in place of Drain Soul")
  return true
end

-- -----------------------------------------------------------------------------
-- Keybinding (Bindings.xml): the two BINDING_ globals name it in the
-- keybindings UI, the global function is what the key runs.
-- -----------------------------------------------------------------------------
BINDING_HEADER_BETTERFOREVER = "Better Forever"
BINDING_NAME_BETTERFOREVER_REAP_SHARDS = "Reap excess Soul Shards"

function BetterForever_ReapShards()
  Run(true, true)
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(self, event, arg1)
  if event == "ADDON_LOADED" and arg1 == addonName then
    settings = Sanitize(CopyDefaults(addon.GetSaved("soulShards")))
    self:UnregisterEvent("ADDON_LOADED")
  end
end)

-- -----------------------------------------------------------------------------
-- API for Options.lua
-- -----------------------------------------------------------------------------
local ss = {}
addon.soulShards = ss
ss.DEFAULTS = DEFAULTS
ss.MACRO_NAME = MACRO_NAME
ss.MACRO_BODY = MACRO_BODY
ss.KEYBINDING = BINDING_NAME_BETTERFOREVER_REAP_SHARDS

function ss.GetSettings()
  return settings
end

function ss.Set(key, value)
  if DEFAULTS[key] == nil or type(value) ~= type(DEFAULTS[key]) then
    return false
  end
  settings[key] = value
  Sanitize(settings)
  return true
end

-- Reset the given keys (a list), or everything, to DEFAULTS.
function ss.Reset(keys)
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
  Sanitize(settings)
end

-- The macro and the key: quiet, and makes room for the incoming shard.
function ss.Reap()
  Run(true, true)
end

-- The button on the options page: says what it found.
function ss.DeleteExcess()
  Run(false, false)
end

ss.CreateMacro = CreateReapMacro

-- How many Soul Shards the bags hold, or nil when they cannot be read.
function ss.Count()
  if type(C_Container) ~= "table" then
    return nil
  end
  local ok, shards = pcall(FindShards)
  if ok then
    return #shards
  end
  return nil
end
