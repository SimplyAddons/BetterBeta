-- Better Forever: options panels.
--
-- Interface Options > AddOns > Better Forever is a page of on/off toggles, one
-- per feature, with the settings of each on sub-pages: FPS Counter, Creature
-- Types (tooltip box + nameplate icon, each section shown while that feature
-- is on), Combo Points, Wand Indicator, Soul Shards and Cinematic Ultra. A
-- sub-page with nothing on is hidden from the list. /bb or /bf opens the main
-- page; "/bf reap" is the line the Soul Shard macro runs and opens nothing.
-- Everything applies immediately and is saved in BetterForeverDB.
--
-- Widgets are hand-built from base frame types plus the templates every
-- client has (UICheckButtonTemplate, UIPanelButtonTemplate, InputBoxTemplate,
-- BackdropTemplate); a choice between a few options is a row of radio dots
-- drawn here. No UIDropDownMenu: it writes into Blizzard's shared menu
-- globals and is a classic taint source. Pages are built on first show.
--
-- Hiding a sub-page: the Settings category list (Blizzard_CategoryList.lua,
-- CreateSection) skips any category with a `redirectCategory` field, and
-- search results for it point at that category (Blizzard's keybindings page
-- uses this). So a sub-page with nothing on gets redirectCategory = our main
-- category and the list is rebuilt with
-- SettingsPanel:GetCategoryList():CreateCategories(); clearing the field
-- lists it again. That field is the only thing of Blizzard's we write to, and
-- only on our own categories. The pre-10.0 options frame has no such switch,
-- there every page is always listed.

local addonName, addon = ...
local Print = addon.Print or print
local general = addon.general
local tip = addon.tooltip
local ci = addon.creatureIcon
local cp = addon.comboPoints
local wi = addon.wandIndicator
local ss = addon.soulShards
local cu = addon.cinematicUltra

local MAIN_TITLE = "Better Forever"
local CONTENT_WIDTH = 580
local SLIDER_WIDTH = 160
local X0 = 16

local refreshing = false  -- true while a Refresh pushes values into widgets

-- -----------------------------------------------------------------------------
-- Widget helpers
-- -----------------------------------------------------------------------------
local function Label(parent, text, font)
  local fs = parent:CreateFontString(nil, "ARTWORK", font or "GameFontNormal")
  fs:SetText(text)
  return fs
end

local function Paragraph(parent, text, width)
  local fs = Label(parent, text, "GameFontHighlightSmall")
  fs:SetWidth(width or CONTENT_WIDTH)
  fs:SetJustifyH("LEFT")
  fs:SetWordWrap(true)
  return fs
end

local function CheckBox(parent, label, onChange, font)
  local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
  cb:SetSize(26, 26)
  local text = cb.Text or cb.text
  if not text then
    text = Label(cb, label, "GameFontHighlight")
    text:SetPoint("LEFT", cb, "RIGHT", 2, 0)
  end
  text:SetFontObject(font or "GameFontHighlight")
  text:SetText(label)
  cb:SetScript("OnClick", function(self)
    if not refreshing then
      onChange(self:GetChecked() and true or false)
    end
  end)
  return cb
end

-- A row of radio dots, one of which is selected. options = { { value =,
-- label = }, ... }. Drawn from the plain disc texture, not
-- UIRadioButtonTemplate: its 16 px art blurs when enlarged.
local RADIO_SIZE = 18
local DISC = "Interface\\CharacterFrame\\TempPortraitAlphaMask"

local function RadioGroup(parent, options, onSelect)
  local group = { buttons = {} }
  for i, option in ipairs(options) do
    local rb = CreateFrame("CheckButton", nil, parent)
    rb:SetSize(RADIO_SIZE, RADIO_SIZE)
    rb.value = option.value
    local rim = rb:CreateTexture(nil, "BACKGROUND")
    rim:SetTexture(DISC)
    rim:SetVertexColor(0.6, 0.6, 0.6, 1)
    rim:SetAllPoints()
    local inner = rb:CreateTexture(nil, "BORDER")
    inner:SetTexture(DISC)
    inner:SetVertexColor(0.1, 0.1, 0.1, 1)
    inner:SetPoint("TOPLEFT", 2, -2)
    inner:SetPoint("BOTTOMRIGHT", -2, 2)
    local dot = rb:CreateTexture(nil, "ARTWORK")
    dot:SetTexture(DISC)
    dot:SetVertexColor(1, 0.82, 0, 1)
    dot:SetPoint("TOPLEFT", 5, -5)
    dot:SetPoint("BOTTOMRIGHT", -5, 5)
    rb:SetCheckedTexture(dot)
    local glow = rb:CreateTexture(nil, "HIGHLIGHT")
    glow:SetTexture(DISC)
    glow:SetVertexColor(1, 1, 1, 0.25)
    glow:SetAllPoints()
    rb:SetHighlightTexture(glow)
    local text = Label(rb, option.label, "GameFontHighlight")
    text:SetPoint("LEFT", rb, "RIGHT", 6, 0)
    rb:SetScript("OnClick", function(self)
      group:Select(self.value)
      if not refreshing then
        onSelect(self.value)
      end
    end)
    group.buttons[i] = rb
  end
  function group:Select(value)
    for _, button in ipairs(self.buttons) do
      button:SetChecked(button.value == value)
    end
  end
  return group
end

local function RoundTo(value, step)
  return math.floor(value / step + 0.5) * step
end

local function Clamp(value, low, high)
  if value < low then return low end
  if value > high then return high end
  return value
end

-- Horizontal slider with a caption, min/max labels and a box to type the
-- value. Enter or leaving the box applies the typed value; Escape reverts.
local function Slider(parent, label, minValue, maxValue, step, onChange)
  local slider = CreateFrame("Slider", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  slider:SetOrientation("HORIZONTAL")
  slider:SetSize(SLIDER_WIDTH, 16)
  slider:SetMinMaxValues(minValue, maxValue)
  slider:SetValueStep(step)
  slider:SetObeyStepOnDrag(true)
  slider.step = step
  if slider.SetBackdrop then
    slider:SetBackdrop({
      bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
      edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
      tile = true, tileSize = 8, edgeSize = 8,
      insets = { left = 3, right = 3, top = 6, bottom = 6 },
    })
  end
  slider:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")

  slider.label = Label(slider, label, "GameFontNormalSmall")
  slider.label:SetPoint("BOTTOMLEFT", slider, "TOPLEFT", 0, 5)
  slider.low = Label(slider, tostring(minValue), "GameFontHighlightSmall")
  slider.low:SetPoint("TOPLEFT", slider, "BOTTOMLEFT", 2, -1)
  slider.high = Label(slider, tostring(maxValue), "GameFontHighlightSmall")
  slider.high:SetPoint("TOPRIGHT", slider, "BOTTOMRIGHT", -2, -1)

  local input = CreateFrame("EditBox", nil, slider, "InputBoxTemplate")
  input:SetSize(46, 18)
  input:SetPoint("BOTTOMRIGHT", slider, "TOPRIGHT", 0, 3)
  input:SetAutoFocus(false)
  input:SetMaxLetters(6)
  input:SetJustifyH("CENTER")
  input:SetFontObject("GameFontHighlightSmall")
  slider.input = input

  function slider:SetTo(value)
    self.lastValue = value
    self:SetValue(value)
    input:SetText(tostring(value))
  end

  function slider:SetActive(active)
    if active then self:Enable() input:Enable() else self:Disable() input:Disable() end
    self:SetAlpha(active and 1 or 0.5)
  end

  local function Commit(box)
    local value = tonumber(box:GetText())
    if value then
      value = Clamp(RoundTo(value, step), minValue, maxValue)
      local changed = value ~= slider.lastValue
      slider:SetTo(value)
      if changed and not refreshing then
        onChange(value)
      end
    else
      input:SetText(tostring(slider.lastValue or minValue))
    end
  end
  input:SetScript("OnEnterPressed", function(box) Commit(box) box:ClearFocus() end)
  input:SetScript("OnEditFocusLost", Commit)
  input:SetScript("OnEscapePressed", function(box)
    box:SetText(tostring(slider.lastValue or minValue))
    box:ClearFocus()
  end)

  slider:SetScript("OnValueChanged", function(self, value)
    value = RoundTo(value, self.step)
    if not input:HasFocus() then
      input:SetText(tostring(value))
    end
    if not refreshing and value ~= self.lastValue then
      self.lastValue = value
      onChange(value)
    end
  end)
  return slider
end

local function Button(parent, text, width, onClick)
  local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  button:SetSize(width, 22)
  button:SetText(text)
  button:SetScript("OnClick", onClick)
  return button
end

-- Read-only text box to copy from: a multi-line edit box in a plain scroll
-- frame with a tooltip-style border. Clicking in it selects everything (then
-- CTRL+C); typing puts the text back. SetValues(text) replaces the text and
-- scrolls to the top.
local function CopyBox(parent, width, height)
  local holder = CreateFrame("Frame", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  holder:SetSize(width, height)
  if holder.SetBackdrop then
    holder:SetBackdrop({
      bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true, tileSize = 16, edgeSize = 16,
      insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    holder:SetBackdropColor(0, 0, 0, 0.6)
    holder:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
  end
  holder.text = ""

  local scroll = CreateFrame("ScrollFrame", nil, holder)
  scroll:SetPoint("TOPLEFT", 8, -8)
  scroll:SetPoint("BOTTOMRIGHT", -8, 8)
  scroll:EnableMouse(true)
  scroll:EnableMouseWheel(true)

  local edit = CreateFrame("EditBox", nil, scroll)
  edit:SetMultiLine(true)
  edit:SetAutoFocus(false)
  edit:SetFontObject("GameFontHighlight")
  edit:SetSize(width - 16, height - 16) -- the height grows with the text
  edit:SetTextInsets(2, 2, 0, 0)
  scroll:SetScrollChild(edit)
  holder.edit = edit

  local function ScrollTo(offset)
    scroll:SetVerticalScroll(Clamp(offset, 0, scroll:GetVerticalScrollRange()))
  end

  edit:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
  edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  edit:SetScript("OnTextChanged", function(self, userInput)
    if userInput then -- read-only: put the text back
      self:SetText(holder.text)
      self:HighlightText()
    end
  end)
  edit:SetScript("OnCursorChanged", function(_, _, y, _, h) -- keep the cursor in view
    local top, bottom = -y, -y + h
    local offset, visible = scroll:GetVerticalScroll(), scroll:GetHeight()
    if top < offset then
      ScrollTo(top)
    elseif bottom > offset + visible then
      ScrollTo(bottom - visible)
    end
  end)
  scroll:SetScript("OnMouseDown", function() edit:SetFocus() end)
  scroll:SetScript("OnMouseWheel", function(self, delta) ScrollTo(self:GetVerticalScroll() - delta * 30) end)

  function holder:SetValues(text)
    self.text = text or ""
    edit:SetText(self.text)
    edit:SetCursorPosition(0)
    ScrollTo(0)
  end

  function holder:SelectAll()
    edit:SetFocus()
    edit:HighlightText()
  end
  return holder
end

-- Colour swatch button; clicking opens Blizzard's colour picker. opts: get()
-- returns { r, g, b[, a] }, set(r, g, b, a) stores, hasOpacity adds the alpha
-- slider, onChange() runs after every change, key names the setting.
local ColorPickerOpen -- forward declaration

local function Swatch(parent, label, opts)
  local swatch = CreateFrame("Button", nil, parent)
  swatch:SetSize(22, 22)
  swatch.key = opts.key
  swatch.get, swatch.set = opts.get, opts.set
  swatch.hasOpacity = opts.hasOpacity and true or false
  swatch.onChange = opts.onChange
  swatch.rim = swatch:CreateTexture(nil, "BACKGROUND")
  swatch.rim:SetAllPoints()
  swatch.rim:SetColorTexture(0.7, 0.7, 0.7, 1)
  swatch.dark = swatch:CreateTexture(nil, "BORDER")
  swatch.dark:SetPoint("TOPLEFT", 2, -2)
  swatch.dark:SetPoint("BOTTOMRIGHT", -2, 2)
  swatch.dark:SetColorTexture(0.1, 0.1, 0.1, 1)
  swatch.color = swatch:CreateTexture(nil, "ARTWORK")
  swatch.color:SetPoint("TOPLEFT", 2, -2)
  swatch.color:SetPoint("BOTTOMRIGHT", -2, 2)
  swatch.text = Label(swatch, label, "GameFontHighlight")
  swatch.text:SetPoint("LEFT", swatch, "RIGHT", 6, 0)
  swatch:SetScript("OnClick", function(self)
    ColorPickerOpen(self)
  end)
  function swatch:Refresh()
    local c = self.get()
    self.color:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
  end
  return swatch
end

-- Colour picker. Modern clients: ColorPickerFrame:SetupColorPickerAndShow(info)
-- with real alpha. Older ones: fields on the frame with an inverted opacity
-- slider. Both call back into us; we write only to our own settings.
ColorPickerOpen = function(swatch)
  local c = swatch.get()
  local r0, g0, b0, a0 = c[1], c[2], c[3], c[4] or 1
  local hasOpacity = swatch.hasOpacity

  local function Apply(r, g, b, a)
    swatch.set(r, g, b, a)
    swatch:Refresh()
    if swatch.onChange then
      swatch.onChange()
    end
  end

  if not ColorPickerFrame then
    Print("colour picker not available in this client")
    return
  end

  if ColorPickerFrame.SetupColorPickerAndShow then
    local function FromPicker()
      local r, g, b = ColorPickerFrame:GetColorRGB()
      local a = a0
      if hasOpacity and ColorPickerFrame.GetColorAlpha then
        a = ColorPickerFrame:GetColorAlpha()
      end
      Apply(r, g, b, a)
    end
    ColorPickerFrame:SetupColorPickerAndShow({
      r = r0, g = g0, b = b0, opacity = a0, hasOpacity = hasOpacity,
      swatchFunc = FromPicker,
      opacityFunc = FromPicker,
      cancelFunc = function(previous)
        if type(previous) == "table" then
          Apply(previous.r or r0, previous.g or g0, previous.b or b0, previous.a or a0)
        else
          Apply(r0, g0, b0, a0)
        end
      end,
    })
  else
    local function FromPicker()
      local r, g, b = ColorPickerFrame:GetColorRGB()
      local a = a0
      if hasOpacity and OpacitySliderFrame and OpacitySliderFrame.GetValue then
        a = 1 - OpacitySliderFrame:GetValue()
      end
      Apply(r, g, b, a)
    end
    ColorPickerFrame.hasOpacity = hasOpacity
    ColorPickerFrame.opacity = 1 - a0
    ColorPickerFrame.previousValues = { r0, g0, b0, 1 - a0 }
    ColorPickerFrame.func = FromPicker
    ColorPickerFrame.opacityFunc = FromPicker
    ColorPickerFrame.cancelFunc = function(previous)
      Apply(previous[1], previous[2], previous[3], 1 - (previous[4] or 0))
    end
    ColorPickerFrame:SetColorRGB(r0, g0, b0)
    ColorPickerFrame:Hide()
    ColorPickerFrame:Show()
  end
end

-- -----------------------------------------------------------------------------
-- Pages. A page is a canvas frame plus the functions the Settings frame and
-- our own code call on it: Build runs on first show, Refresh pushes settings
-- into widgets, Default resets what the page owns; sub-pages also have Enabled
-- (is any of their functions on, so should the page be listed).
-- -----------------------------------------------------------------------------
local function NewPage(frameName, title)
  local frame = CreateFrame("Frame", frameName)
  frame.name = title
  frame:Hide()
  local page = { frame = frame, title = title, built = false, W = {} }
  frame:SetScript("OnShow", function()
    if not page.built then
      page.built = true
      page.Build()
    end
    page.Refresh()
  end)
  function frame:OnRefresh()
    if page.built then
      page.Refresh()
    end
  end
  function frame:OnDefault()
    page.Default()
    if page.built then
      page.Refresh()
    end
  end
  function frame:OnCommit() end
  return page
end

local function Title(page, text, description)
  local title = Label(page.frame, text, "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", X0, -16)
  local desc = Paragraph(page.frame, description)
  desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
  return desc
end

local main = NewPage("BetterForeverOptionsPanel", MAIN_TITLE)
local pages = {}          -- sub-pages in list order, filled in below
local RefreshVisibility   -- forward declarations; defined with the registration
local OpenPage

-- =============================================================================
-- Main page: a card per function with its icon, name, one line about it, a
-- Settings button while it is on, and the on/off tick. Clicking anywhere on a
-- card toggles it; an off card is greyed out.
-- =============================================================================
local CARD_HEIGHT = 54
local CARD_GAP = 4
local CARD_ICON = 36
local BLIZZARD_ICONS = "Interface\\Icons\\"
local OWN_ICONS = "Interface\\AddOns\\" .. addonName .. "\\creature_types\\"
local ICON_CROP = 0.07 -- trims the built-in rim of Blizzard's icons (ours have none)

local function ChangeToggle(apply)
  apply()
  RefreshVisibility()
  main.Refresh()
end

local function PageByTitle(title)
  for _, page in ipairs(pages) do
    if page.title == title then
      return page
    end
  end
end

-- spec: icon, label, description, page (its settings page, may be nil),
-- onChange(on)
local function Card(parent, above, spec)
  local card = CreateFrame("Frame", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  card:SetSize(CONTENT_WIDTH, CARD_HEIGHT)
  if above then
    card:SetPoint("TOPLEFT", above, "BOTTOMLEFT", 0, -CARD_GAP)
  end
  if card.SetBackdrop then
    card:SetBackdrop({
      bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true, tileSize = 16, edgeSize = 12,
      insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
  end
  card.on = false

  card.icon = card:CreateTexture(nil, "ARTWORK")
  card.icon:SetSize(CARD_ICON, CARD_ICON)
  card.icon:SetPoint("LEFT", 10, 0)
  card.icon:SetTexture(spec.icon)
  if spec.icon:find(BLIZZARD_ICONS, 1, true) == 1 then
    card.icon:SetTexCoord(ICON_CROP, 1 - ICON_CROP, ICON_CROP, 1 - ICON_CROP)
  end

  card.check = CreateFrame("CheckButton", nil, card, "UICheckButtonTemplate")
  card.check:SetSize(28, 28)
  card.check:SetPoint("RIGHT", -8, 0)
  card.check:SetScript("OnClick", function(self)
    if not refreshing then
      spec.onChange(self:GetChecked() and true or false)
    end
  end)

  card.settings = Button(card, "Settings", 76, function()
    if spec.page then
      OpenPage(spec.page)
    end
  end)
  card.settings:SetPoint("RIGHT", card.check, "LEFT", -8, 0)

  card.title = Label(card, spec.label, "GameFontNormal")
  card.title:SetPoint("TOPLEFT", card.icon, "TOPRIGHT", 10, -1)
  card.desc = Label(card, spec.description, "GameFontHighlightSmall")
  card.desc:SetPoint("TOPLEFT", card.title, "BOTTOMLEFT", 0, -3)
  card.desc:SetPoint("RIGHT", card.settings, "LEFT", -10, 0)
  card.desc:SetJustifyH("LEFT")
  card.desc:SetWordWrap(true)

  function card:Shade(hover)
    if not self.SetBackdropColor then
      return
    end
    local base = (self.on and 0.10 or 0.04) + (hover and 0.08 or 0)
    self:SetBackdropColor(base, base, base, 0.7)
    if self.on then
      self:SetBackdropBorderColor(0.85, 0.65, 0.15, hover and 1 or 0.8)
    else
      self:SetBackdropBorderColor(0.45, 0.45, 0.45, hover and 1 or 0.7)
    end
  end

  function card:SetOn(on)
    self.on = on and true or false
    self.check:SetChecked(self.on)
    self.icon:SetDesaturated(not self.on)
    self.icon:SetAlpha(self.on and 1 or 0.45)
    self.title:SetFontObject(self.on and "GameFontNormal" or "GameFontDisable")
    self.settings:SetShown(self.on and spec.page ~= nil)
    self:Shade(self:IsMouseOver())
  end

  -- the whole card is a button and lights up under the mouse
  card:EnableMouse(true)
  card:SetScript("OnEnter", function(self) self:Shade(true) end)
  card:SetScript("OnLeave", function(self) self:Shade(false) end)
  card:SetScript("OnMouseUp", function(self, button)
    if button == "LeftButton" and self:IsMouseOver() then
      self.check:Click()
    end
  end)
  card:SetOn(false)
  return card
end

function main.Build()
  local W, f = main.W, main.frame

  local title = Label(f, MAIN_TITLE, "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", X0, -16)
  local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
  local version = getMeta and getMeta(addonName, "Version")
  if type(version) == "string" and version ~= "" and version:sub(1, 1) ~= "@" then
    local v = Label(f, "v" .. version, "GameFontDisableSmall")
    v:SetPoint("LEFT", title, "RIGHT", 8, -1)
  end
  local sub = Paragraph(f, "Small fixes for the WoW Forever client. Tick what you want on; Settings opens a function's page.")
  sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
  local rule = f:CreateTexture(nil, "ARTWORK")
  rule:SetColorTexture(0.85, 0.65, 0.15, 0.5)
  rule:SetHeight(1)
  rule:SetPoint("TOPLEFT", sub, "BOTTOMLEFT", 0, -10)
  rule:SetPoint("RIGHT", sub, "RIGHT", 0, 0)

  local types = PageByTitle("Creature Types")
  W.fps = Card(f, nil, {
    icon = BLIZZARD_ICONS .. "INV_Misc_PocketWatch_01",
    label = "FPS counter",
    description = "Keeps the FPS counter on screen after you log in or reload.",
    page = PageByTitle("FPS Counter"),
    onChange = function(v) ChangeToggle(function() general.Set("showFPS", v) end) end,
  })
  W.fps:SetPoint("TOPLEFT", rule, "BOTTOMLEFT", 0, -10)
  W.tip = Card(f, W.fps, {
    icon = OWN_ICONS .. "beast",
    label = "Creature type above NPC tooltips",
    description = "Shows what kind of creature an NPC is (Beast, Undead, Humanoid, ...) above its tooltip.",
    page = types,
    onChange = function(v) ChangeToggle(function() tip.Set("enabled", v) end) end,
  })
  W.icon = Card(f, W.tip, {
    icon = OWN_ICONS .. "undead",
    label = "Creature type icon on nameplates",
    description = "Shows a small creature type icon next to nameplates.",
    page = types,
    onChange = function(v) ChangeToggle(function() ci.Set("enabled", v) end) end,
  })
  W.combo = Card(f, W.icon, {
    icon = BLIZZARD_ICONS .. "Ability_Rogue_Eviscerate",
    label = "Combo points on the target's nameplate",
    description = "Shows your combo points on your target's nameplate (rogues, and druids in cat form).",
    page = PageByTitle("Combo Points"),
    onChange = function(v) ChangeToggle(function() cp.Set("enabled", v) end) end,
  })
  W.wand = Card(f, W.combo, {
    icon = BLIZZARD_ICONS .. "Ability_ShootWand",
    label = "Wand indicator",
    description = "Shows an icon on screen while your wand is shooting.",
    page = PageByTitle("Wand Indicator"),
    onChange = function(v) ChangeToggle(function() wi.Set("enabled", v) end) end,
  })
  W.shards = Card(f, W.wand, {
    icon = BLIZZARD_ICONS .. "INV_Misc_Gem_Amethyst_02",
    label = "Soul Shard reaper (warlocks)",
    description = "Deletes Soul Shards above a limit you set, one each time you cast or press a key.",
    page = PageByTitle("Soul Shards"),
    onChange = function(v) ChangeToggle(function() ss.Set("enabled", v) end) end,
  })
  W.ultra = Card(f, W.shards, {
    icon = BLIZZARD_ICONS .. "INV_Misc_Spyglass_03",
    label = "Cinematic Ultra",
    description = "Switches on the Cinematic Ultra graphics settings. Your own settings are saved first and come back when you switch it off. Type /camp afterwards.",
    page = PageByTitle("Cinematic Ultra"),
    onChange = function(v) ChangeToggle(function() cu.Set("enabled", v) end) end,
  })

  local note = Paragraph(f, "Type /bb or /bf to open this panel.")
  note:SetPoint("TOPLEFT", W.ultra, "BOTTOMLEFT", 0, -12)
end

function main.Refresh()
  if not main.built then
    return
  end
  local W = main.W
  refreshing = true
  W.fps:SetOn(general.GetSettings().showFPS)
  W.tip:SetOn(tip.GetSettings().enabled)
  W.icon:SetOn(ci.GetSettings().enabled)
  W.combo:SetOn(cp.GetSettings().enabled)
  W.wand:SetOn(wi.GetSettings().enabled)
  W.shards:SetOn(ss.GetSettings().enabled)
  W.ultra:SetOn(cu.GetSettings().enabled)
  refreshing = false
end

function main.Default()
  general.Reset({ "showFPS" })
  tip.Set("enabled", tip.DEFAULTS.enabled)
  ci.Set("enabled", ci.DEFAULTS.enabled)
  cp.Set("enabled", cp.DEFAULTS.enabled)
  wi.Set("enabled", wi.DEFAULTS.enabled)
  ss.Set("enabled", ss.DEFAULTS.enabled)
  cu.Set("enabled", cu.DEFAULTS.enabled)
  RefreshVisibility()
end

-- =============================================================================
-- FPS counter page
-- =============================================================================
local fps = NewPage("BetterForeverFPSPanel", "FPS Counter")
pages[#pages + 1] = fps

function fps.Enabled()
  return general.GetSettings().showFPS
end

function fps.Build()
  local W, f = fps.W, fps.frame
  local desc = Title(fps, "FPS counter",
    "Keeps the FPS counter (the one CTRL+R toggles) on screen after you log in or reload. "
    .. "The buttons show or hide it right now.")

  W.show = Button(f, "Show", 110, function() general.SetFramerateShown(true) end)
  W.show:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -18)
  W.hide = Button(f, "Hide", 110, function() general.SetFramerateShown(false) end)
  W.hide:SetPoint("LEFT", W.show, "RIGHT", 10, 0)
end

function fps.Refresh() end

function fps.Default()
  general.Reset({ "showFPS" })
end

-- =============================================================================
-- Creature Types page: the tooltip box and the nameplate icon. Listed while
-- either is on; each has a section that is shown only while it is on.
-- =============================================================================
local typesPage = NewPage("BetterForeverCreatureTypesPanel", "Creature Types")
pages[#pages + 1] = typesPage

function typesPage.Enabled()
  return tip.GetSettings().enabled or ci.GetSettings().enabled
end

local function RefreshIconPreview()
  local W = typesPage.W
  if W.preview then
    ci.Layout(W.preview)
    ci.SetIcon(W.preview, ci.SamplePath)
  end
end

-- Show the section of each function that is on and stack them under the
-- description, with the reset button below the last one shown.
local function LayoutSections()
  local W = typesPage.W
  local tipOn, iconOn = tip.GetSettings().enabled, ci.GetSettings().enabled
  for _, widget in ipairs(W.tipWidgets) do
    widget:SetShown(tipOn)
  end
  for _, widget in ipairs(W.iconWidgets) do
    widget:SetShown(iconOn)
  end
  W.iconHeader:ClearAllPoints()
  if tipOn then
    W.iconHeader:SetPoint("TOPLEFT", W.tipBottom, "BOTTOMLEFT", 0, -28)
  else
    W.iconHeader:SetPoint("TOPLEFT", W.desc, "BOTTOMLEFT", 0, -20)
  end
  W.reset:ClearAllPoints()
  W.reset:SetPoint("TOPLEFT", iconOn and W.iconBottom or W.tipBottom, "BOTTOMLEFT", 0, -28)
end

function typesPage.Refresh()
  if not typesPage.built then
    return
  end
  local W = typesPage.W
  local s = ci.GetSettings()
  refreshing = true
  W.allPlates:SetChecked(s.allPlates)
  W.box:SetChecked(s.box)
  W.size:SetTo(s.size)
  W.gap:SetTo(s.gap)
  W.offsetX:SetTo(s.offsetX)
  W.offsetY:SetTo(s.offsetY)
  refreshing = false
  W.swatch:Refresh()
  W.iconSwatch:Refresh()
  RefreshIconPreview()
  LayoutSections()
end

function typesPage.Default()
  tip.Reset()
  ci.Reset()
end

local function ChangeIcon(key, value)
  ci.Set(key, value)
  typesPage.Refresh()
end

function typesPage.Build()
  local W, f = typesPage.W, typesPage.frame
  W.desc = Title(typesPage, "Creature types",
    "Shows what kind of creature an NPC is (Beast, Undead, Humanoid, ...): above its tooltip and as an icon next to "
    .. "its nameplate.")

  -- tooltip box
  W.tipHeader = Label(f, "Tooltip box", "GameFontHighlightLarge")
  W.tipHeader:SetPoint("TOPLEFT", W.desc, "BOTTOMLEFT", 0, -20)
  local colorLabel = Label(f, "Colour")
  colorLabel:SetPoint("TOPLEFT", W.tipHeader, "BOTTOMLEFT", 0, -16)
  W.swatch = Swatch(f, "Text", {
    key = "color",
    get = function() return tip.GetSettings().color end,
    set = function(r, g, b) tip.SetColor(r, g, b) end,
    hasOpacity = false,
  })
  W.swatch:SetPoint("LEFT", colorLabel, "LEFT", 90, 0)
  W.tipWidgets = { W.tipHeader, colorLabel, W.swatch }
  W.tipBottom = colorLabel

  -- nameplate icon (the header is anchored by LayoutSections)
  W.iconHeader = Label(f, "Nameplate icon", "GameFontHighlightLarge")
  W.allPlates = CheckBox(f, "Show on all nameplates, not only your target's",
    function(v) ChangeIcon("allPlates", v) end)
  W.allPlates:SetPoint("TOPLEFT", W.iconHeader, "BOTTOMLEFT", -4, -10)
  W.box = CheckBox(f, "Show icon in a box", function(v) ChangeIcon("box", v) end)
  W.box:SetPoint("TOPLEFT", W.allPlates, "BOTTOMLEFT", 0, 2)

  local iconColorLabel = Label(f, "Colour")
  iconColorLabel:SetPoint("TOPLEFT", W.box, "BOTTOMLEFT", 4, -12)
  W.iconSwatch = Swatch(f, "Icon (white = as drawn)", {
    key = "iconColor",
    get = function() return ci.GetSettings().color end,
    set = function(r, g, b) ci.SetColor(r, g, b) end,
    hasOpacity = false,
    onChange = RefreshIconPreview,
  })
  W.iconSwatch:SetPoint("LEFT", iconColorLabel, "LEFT", 90, 0)

  -- sliders, two rows
  W.size = Slider(f, "Size", 8, 48, 1, function(v) ChangeIcon("size", v) end)
  W.size:SetPoint("TOPLEFT", iconColorLabel, "BOTTOMLEFT", 0, -38)
  W.gap = Slider(f, "Gap", 0, 40, 1, function(v) ChangeIcon("gap", v) end)
  W.gap:SetPoint("LEFT", W.size, "RIGHT", 36, 0)
  W.offsetX = Slider(f, "Horizontal offset", -100, 100, 1, function(v) ChangeIcon("offsetX", v) end)
  W.offsetX:SetPoint("TOPLEFT", W.size, "BOTTOMLEFT", 0, -58)
  W.offsetY = Slider(f, "Vertical offset", -100, 100, 1, function(v) ChangeIcon("offsetY", v) end)
  W.offsetY:SetPoint("LEFT", W.offsetX, "RIGHT", 36, 0)

  -- preview
  local previewLabel = Label(f, "Preview")
  previewLabel:SetPoint("TOPLEFT", W.offsetX, "BOTTOMLEFT", 0, -44)
  W.preview = ci.NewIcon(f)
  W.preview:SetPoint("LEFT", previewLabel, "LEFT", 90, 0)
  W.preview:SetFrameLevel(f:GetFrameLevel() + 2)

  W.test = Button(f, "Test on my target", 170, function() ci.Test() end)
  W.test:SetPoint("TOPLEFT", previewLabel, "BOTTOMLEFT", 0, -34)

  W.iconWidgets = { W.iconHeader, W.allPlates, W.box, iconColorLabel, W.iconSwatch, W.size, W.gap, W.offsetX, W.offsetY,
    previewLabel, W.preview, W.test }
  W.iconBottom = W.test

  W.reset = Button(f, "Reset to defaults", 140, function()
    typesPage.Default()
    typesPage.Refresh()
    RefreshVisibility()
  end)
end

-- =============================================================================
-- Combo Points page: shape, position, sizes, colours, a live preview and the
-- test button. The on/off switch is on the main page.
-- =============================================================================
local comboPage = NewPage("BetterForeverComboPointsPanel", "Combo Points")
pages[#pages + 1] = comboPage

function comboPage.Enabled()
  return cp.GetSettings().enabled
end

local function RefreshComboPreview()
  local W = comboPage.W
  if W.previewSome then
    W.previewSome:Layout(5)
    W.previewSome:SetValue(3)
    W.previewMax:Layout(5)
    W.previewMax:SetValue(5)
  end
end

function comboPage.Refresh()
  if not comboPage.built then
    return
  end
  local W = comboPage.W
  local s = cp.GetSettings()
  refreshing = true
  W.showEmpty:SetChecked(s.showEmpty)
  W.border:SetChecked(s.border)
  W.shape:Select(s.shape)
  W.position:Select(s.position)
  W.size:SetTo(s.size)
  W.width:SetTo(s.width)
  W.spacing:SetTo(s.spacing)
  W.offsetX:SetTo(s.offsetX)
  W.offsetY:SetTo(s.offsetY)
  W.borderSize:SetTo(s.borderSize)
  W.width:SetActive(s.shape == "rectangle")
  W.borderSize:SetActive(s.border)
  refreshing = false
  for _, swatch in ipairs(W.swatches) do
    swatch:Refresh()
  end
  RefreshComboPreview()
end

function comboPage.Default()
  cp.Reset()
end

local function ChangeCombo(key, value)
  cp.Set(key, value)
  comboPage.Refresh()
end

function comboPage.Build()
  local W, f = comboPage.W, comboPage.frame
  local desc = Title(comboPage, "Combo points",
    "Shows your combo points on your target's nameplate. Rogues always, druids in cat form.")

  W.showEmpty = CheckBox(f, "Show the empty points too", function(v) ChangeCombo("showEmpty", v) end)
  W.showEmpty:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", -4, -14)
  W.border = CheckBox(f, "Dark border around each point",
    function(v) ChangeCombo("border", v) end)
  W.border:SetPoint("TOPLEFT", W.showEmpty, "BOTTOMLEFT", 0, 2)

  local shapeLabel = Label(f, "Shape")
  shapeLabel:SetPoint("TOPLEFT", W.border, "BOTTOMLEFT", 4, -12)
  W.shape = RadioGroup(f, {
    { value = "dot", label = "Dots" },
    { value = "square", label = "Squares" },
    { value = "rectangle", label = "Rectangles" },
  }, function(v) ChangeCombo("shape", v) end)
  W.shape.buttons[1]:SetPoint("LEFT", shapeLabel, "LEFT", 90, 0)
  W.shape.buttons[2]:SetPoint("LEFT", W.shape.buttons[1], "LEFT", 100, 0)
  W.shape.buttons[3]:SetPoint("LEFT", W.shape.buttons[2], "LEFT", 110, 0)

  local positionLabel = Label(f, "Position")
  positionLabel:SetPoint("TOPLEFT", shapeLabel, "BOTTOMLEFT", 0, -16)
  W.position = RadioGroup(f, {
    { value = "above", label = "Above the name" },
    { value = "below", label = "Below the health bar" },
    { value = "center", label = "On the health bar" },
  }, function(v) ChangeCombo("position", v) end)
  W.position.buttons[1]:SetPoint("LEFT", positionLabel, "LEFT", 90, 0)
  W.position.buttons[2]:SetPoint("LEFT", W.position.buttons[1], "LEFT", 150, 0)
  W.position.buttons[3]:SetPoint("LEFT", W.position.buttons[2], "LEFT", 180, 0)

  -- sliders, two rows of three
  W.size = Slider(f, "Size", 3, 40, 1, function(v) ChangeCombo("size", v) end)
  W.size:SetPoint("TOPLEFT", positionLabel, "BOTTOMLEFT", 0, -38)
  W.width = Slider(f, "Rectangle width", 3, 80, 1, function(v) ChangeCombo("width", v) end)
  W.width:SetPoint("LEFT", W.size, "RIGHT", 36, 0)
  W.spacing = Slider(f, "Spacing", 0, 20, 1, function(v) ChangeCombo("spacing", v) end)
  W.spacing:SetPoint("LEFT", W.width, "RIGHT", 36, 0)
  W.offsetX = Slider(f, "Horizontal offset", -100, 100, 1, function(v) ChangeCombo("offsetX", v) end)
  W.offsetX:SetPoint("TOPLEFT", W.size, "BOTTOMLEFT", 0, -58)
  W.offsetY = Slider(f, "Vertical offset", -100, 100, 1, function(v) ChangeCombo("offsetY", v) end)
  W.offsetY:SetPoint("LEFT", W.offsetX, "RIGHT", 36, 0)
  W.borderSize = Slider(f, "Border thickness", 1, 4, 1, function(v) ChangeCombo("borderSize", v) end)
  W.borderSize:SetPoint("LEFT", W.offsetY, "RIGHT", 36, 0)

  -- colours, with opacity
  local colorLabel = Label(f, "Colours")
  colorLabel:SetPoint("TOPLEFT", W.offsetX, "BOTTOMLEFT", 0, -44)
  local function ComboSwatch(label, key)
    return Swatch(f, label, {
      key = key,
      get = function() return cp.GetSettings()[key] end,
      set = function(r, g, b, a) cp.SetColor(key, r, g, b, a) end,
      hasOpacity = true,
      onChange = RefreshComboPreview,
    })
  end
  W.swatches = {
    ComboSwatch("Lit", "color"),
    ComboSwatch("At max", "colorMax"),
    ComboSwatch("Unlit", "colorEmpty"),
    ComboSwatch("Border", "colorBorder"),
  }
  W.swatches[1]:SetPoint("LEFT", colorLabel, "LEFT", 90, 0)
  W.swatches[2]:SetPoint("LEFT", W.swatches[1], "LEFT", 100, 0)
  W.swatches[3]:SetPoint("LEFT", W.swatches[2], "LEFT", 120, 0)
  W.swatches[4]:SetPoint("LEFT", W.swatches[3], "LEFT", 110, 0)

  -- preview: two rows under UIParent, so they can be laid out freely
  local previewLabel = Label(f, "Preview")
  previewLabel:SetPoint("TOPLEFT", colorLabel, "BOTTOMLEFT", 0, -24)
  W.previewSome = cp.NewRow(f)
  W.previewSome.frame:SetPoint("LEFT", previewLabel, "LEFT", 90, 0)
  W.previewSome.frame:SetFrameLevel(f:GetFrameLevel() + 2)
  local someLabel = Label(f, "3 of 5", "GameFontHighlightSmall")
  someLabel:SetPoint("LEFT", W.previewSome.frame, "RIGHT", 10, 0)
  W.previewMax = cp.NewRow(f)
  W.previewMax.frame:SetPoint("LEFT", previewLabel, "LEFT", 300, 0)
  W.previewMax.frame:SetFrameLevel(f:GetFrameLevel() + 2)
  local maxLabel = Label(f, "5 of 5", "GameFontHighlightSmall")
  maxLabel:SetPoint("LEFT", W.previewMax.frame, "RIGHT", 10, 0)

  W.test = Button(f, "Test on my target", 170, function() cp.Test(3) end)
  W.test:SetPoint("TOPLEFT", previewLabel, "BOTTOMLEFT", 0, -24)
  W.reset = Button(f, "Reset to defaults", 140, function()
    comboPage.Default()
    comboPage.Refresh()
    RefreshVisibility()
  end)
  W.reset:SetPoint("LEFT", W.test, "RIGHT", 10, 0)
end

-- =============================================================================
-- Wand Indicator page
-- =============================================================================
local wandPage = NewPage("BetterForeverWandPanel", "Wand Indicator")
pages[#pages + 1] = wandPage

function wandPage.Enabled()
  return wi.GetSettings().enabled
end

function wandPage.Refresh()
  if not wandPage.built then
    return
  end
  local W = wandPage.W
  local s = wi.GetSettings()
  refreshing = true
  W.unlock:SetChecked(wi.IsUnlocked())
  W.timer:SetChecked(s.timer)
  W.text:SetChecked(s.text)
  W.size:SetTo(s.size)
  W.x:SetTo(s.x)
  W.y:SetTo(s.y)
  refreshing = false
  W.swatch:Refresh()
end

function wandPage.Default()
  wi.Reset()
end

local function ChangeWand(key, value)
  wi.Set(key, value)
  wandPage.Refresh()
end

wi.onMoved = wandPage.Refresh -- dragging the indicator moves the position sliders

function wandPage.Build()
  local W, f = wandPage.W, wandPage.frame
  local desc = Title(wandPage, "Wand indicator",
    "Shows your wand on screen while it is shooting, with a bar that fills up until the next shot and a comic-book "
    .. "word on every shot. If a shot is late, it turns grey and says \"fizzle...\".")

  W.unlock = CheckBox(f, "Unlock so you can drag it",
    function(v) wi.SetUnlocked(v) wandPage.Refresh() end)
  W.unlock:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", -4, -14)
  W.timer = CheckBox(f, "Show the bar to the next shot", function(v) ChangeWand("timer", v) end)
  W.timer:SetPoint("TOPLEFT", W.unlock, "BOTTOMLEFT", 0, 2)
  W.text = CheckBox(f, "Show a comic-book word on every shot (ZAP!, POOF!, ...)",
    function(v) ChangeWand("text", v) end)
  W.text:SetPoint("TOPLEFT", W.timer, "BOTTOMLEFT", 0, 2)

  local colorLabel = Label(f, "Colour")
  colorLabel:SetPoint("TOPLEFT", W.text, "BOTTOMLEFT", 4, -12)
  W.swatch = Swatch(f, "Rim, bar and text", {
    key = "color",
    get = function() return wi.GetSettings().color end,
    set = function(r, g, b) wi.SetColor(r, g, b) end,
    hasOpacity = false,
  })
  W.swatch:SetPoint("LEFT", colorLabel, "LEFT", 90, 0)

  W.size = Slider(f, "Size", 20, 96, 1, function(v) ChangeWand("size", v) end)
  W.size:SetPoint("TOPLEFT", colorLabel, "BOTTOMLEFT", 0, -38)
  W.x = Slider(f, "Horizontal position", -1000, 1000, 1, function(v) ChangeWand("x", v) end)
  W.x:SetPoint("TOPLEFT", W.size, "BOTTOMLEFT", 0, -58)
  W.y = Slider(f, "Vertical position", -600, 600, 1, function(v) ChangeWand("y", v) end)
  W.y:SetPoint("LEFT", W.x, "RIGHT", 36, 0)

  W.reset = Button(f, "Reset to defaults", 140, function()
    wandPage.Default()
    wandPage.Refresh()
    RefreshVisibility()
  end)
  W.reset:SetPoint("TOPLEFT", W.x, "BOTTOMLEFT", 0, -40)
end

-- =============================================================================
-- Soul Shards page: how many to keep, a button that deletes one now, and the
-- Drain Soul macro to copy or create. The shard count on the status line is
-- re-read whenever the bags change while the page is shown.
-- =============================================================================
local shardsPage = NewPage("BetterForeverSoulShardsPanel", "Soul Shards")
pages[#pages + 1] = shardsPage

function shardsPage.Enabled()
  return ss.GetSettings().enabled
end

function shardsPage.Refresh()
  if not shardsPage.built then
    return
  end
  local W = shardsPage.W
  local s = ss.GetSettings()
  refreshing = true
  W.max:SetTo(s.maxShards)
  refreshing = false
  local count = ss.Count()
  local status
  if not count then
    status = "Your bags could not be read."
  elseif count > s.maxShards then
    status = "You have " .. count .. " Soul Shards and keep " .. s.maxShards .. ": " .. (count - s.maxShards)
      .. " will be deleted, one per cast or press."
  else
    status = "You have " .. count .. " Soul Shard" .. (count == 1 and "" or "s") .. " and keep "
      .. s.maxShards .. ": nothing to delete."
  end
  W.status:SetText(status)
end

function shardsPage.Default()
  ss.Reset({ "maxShards" })
end

function shardsPage.Build()
  local W, f = shardsPage.W, shardsPage.frame
  local desc = Title(shardsPage, "Soul Shards",
    "Deletes Soul Shards above the limit below. The game only allows this while you press a key or click, one shard "
    .. "at a time, so it happens from the macro below, from a key you bind, or from the button here.")

  W.status = Paragraph(f, "", CONTENT_WIDTH)
  W.status:SetFontObject("GameFontHighlight")
  W.status:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -10)

  W.max = Slider(f, "Shards to keep", 0, 50, 1, function(v) ss.Set("maxShards", v) shardsPage.Refresh() end)
  W.max:SetPoint("TOPLEFT", W.status, "BOTTOMLEFT", 0, -38)
  W.delete = Button(f, "Delete one now", 140, function() ss.DeleteExcess() shardsPage.Refresh() end)
  W.delete:SetPoint("LEFT", W.max, "RIGHT", 36, 0)

  local zeroNote = Paragraph(f, "The macro deletes before it casts, so you hold one shard above the limit until "
    .. "your next cast. Set the limit to 0 to keep only your newest shard.")
  zeroNote:SetPoint("TOPLEFT", W.max, "BOTTOMLEFT", 0, -22)

  W.macroHeader = Label(f, "Macro", "GameFontHighlightLarge")
  W.macroHeader:SetPoint("TOPLEFT", zeroNote, "BOTTOMLEFT", 0, -20)
  local macroText = Paragraph(f, "Use this instead of Drain Soul: it deletes the extra shards, then casts. Copy it "
    .. "into /macro or click the button, then put it on your action bar.")
  macroText:SetPoint("TOPLEFT", W.macroHeader, "BOTTOMLEFT", 0, -8)
  W.macro = CopyBox(f, CONTENT_WIDTH, 72)
  W.macro:SetPoint("TOPLEFT", macroText, "BOTTOMLEFT", 0, -10)
  W.macro:SetValues(ss.MACRO_BODY)
  local hint = Paragraph(f, "Click in the box, then press CTRL+C to copy.")
  hint:SetPoint("TOPLEFT", W.macro, "BOTTOMLEFT", 0, -6)
  W.create = Button(f, "Create macro", 140, function() ss.CreateMacro() end)
  W.create:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -10)

  local keyNote = Paragraph(f, "You can also bind a key: Options > Keybindings > AddOns > Better Forever > "
    .. ss.KEYBINDING .. ".")
  keyNote:SetPoint("TOPLEFT", W.create, "BOTTOMLEFT", 0, -12)

  W.reset = Button(f, "Reset to defaults", 140, function()
    shardsPage.Default()
    shardsPage.Refresh()
  end)
  W.reset:SetPoint("TOPLEFT", keyNote, "BOTTOMLEFT", 0, -20)

  -- the count on the status line follows the bags while the page is shown
  f:RegisterEvent("BAG_UPDATE_DELAYED")
  f:SetScript("OnEvent", function(self)
    if self:IsShown() then
      shardsPage.Refresh()
    end
  end)
end

-- =============================================================================
-- Cinematic Ultra page. Always listed, on or off: it shows the saved and the
-- live values, which matter most while the feature is off. A status line, two
-- copy boxes side by side, Apply/Restore again and Read again. The on/off
-- switch itself is on the main page.
-- =============================================================================
local ultraPage = NewPage("BetterForeverCinematicUltraPanel", "Cinematic Ultra")
pages[#pages + 1] = ultraPage

local VALUES_BOX_HEIGHT = 240
local VALUES_BOX_GAP = 12

function ultraPage.Enabled()
  return true
end

function ultraPage.Refresh()
  if not ultraPage.built then
    return
  end
  local W = ultraPage.W
  local st = cu.Status()
  local status
  if st.enabled then
    if st.differ == 0 then
      status = "On."
    else
      status = "On, but " .. st.differ .. " of " .. st.total .. " settings are different. Apply again fixes that."
    end
  elseif not st.haveOriginal then
    status = "Off. Nothing has been changed yet."
  elseif st.differ == 0 then
    status = "Off. Your original settings are in effect."
  else
    status = "Off, but " .. st.differ .. " of " .. st.total .. " settings are different from your original ones. "
      .. "Restore again fixes that."
  end
  if st.unsaved then
    status = status .. " " .. cu.CAMP_WARNING
  end
  W.status:SetText(status)
  W.origHeader:SetText(st.haveOriginal and ("Original settings (saved " .. (st.takenAt or "earlier") .. ")")
    or "Original settings")
  W.original:SetValues(cu.OriginalText())
  W.current:SetValues(cu.CurrentText())
  W.again:SetShown(st.enabled or st.haveOriginal)
  W.again:SetText(st.enabled and "Apply again" or "Restore again")
end

function ultraPage.Default()
  cu.Reset()
end

function ultraPage.Build()
  local W, f = ultraPage.W, ultraPage.frame
  local desc = Title(ultraPage, "Cinematic Ultra",
    "The Cinematic Ultra graphics settings: a sharper picture, better shadows and water, more detail in the "
    .. "distance, full weather and spell effects. Your own settings are saved first (left box) and come back when "
    .. "you switch it off. After each switch, type /camp: the game only keeps these settings after a proper logout.")

  W.status = Paragraph(f, "", CONTENT_WIDTH)
  W.status:SetFontObject("GameFontHighlight")
  W.status:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -10)

  W.menuNote = Paragraph(f, "Render Scale and Anti-Aliasing under Options > Graphics are part of this. If you change "
    .. "them there later, that part is undone and the line above says so.",
    CONTENT_WIDTH)
  W.menuNote:SetFontObject("GameFontNormalSmall")
  W.menuNote:SetPoint("TOPLEFT", W.status, "BOTTOMLEFT", 0, -8)

  local boxWidth = (CONTENT_WIDTH - VALUES_BOX_GAP) / 2
  W.origHeader = Label(f, "Original settings")
  W.origHeader:SetPoint("TOPLEFT", W.menuNote, "BOTTOMLEFT", 0, -14)
  W.original = CopyBox(f, boxWidth, VALUES_BOX_HEIGHT)
  W.original:SetPoint("TOPLEFT", W.origHeader, "BOTTOMLEFT", 0, -4)
  local curHeader = Label(f, "Current settings")
  curHeader:SetPoint("TOPLEFT", W.origHeader, "TOPLEFT", boxWidth + VALUES_BOX_GAP, 0)
  W.current = CopyBox(f, boxWidth, VALUES_BOX_HEIGHT)
  W.current:SetPoint("TOPLEFT", curHeader, "BOTTOMLEFT", 0, -4)

  W.again = Button(f, "Apply again", 120, function() cu.ApplyAgain() ultraPage.Refresh() end)
  W.again:SetPoint("TOPLEFT", W.original, "BOTTOMLEFT", 0, -12)
  W.read = Button(f, "Refresh", 110, function() ultraPage.Refresh() end)
  W.read:SetPoint("LEFT", W.again, "RIGHT", 10, 0)
  W.retake = Button(f, "Save current as original", 190, function()
    cu.UseCurrentAsOriginal()
    ultraPage.Refresh()
  end)
  W.retake:SetPoint("LEFT", W.read, "RIGHT", 10, 0)

  local note = Paragraph(f, "Click in a box, then press CTRL+C to copy it. Each line can be typed in chat to set "
    .. "one value by hand. Save current as original replaces the left box with the right one, if the saved "
    .. "settings are ever wrong.")
  note:SetPoint("TOPLEFT", W.again, "BOTTOMLEFT", 0, -12)
end

-- =============================================================================
-- Registration, sub-page visibility and /bb
-- =============================================================================
local category -- the main Better Forever category (modern Settings API only)

if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
  category = Settings.RegisterCanvasLayoutCategory(main.frame, MAIN_TITLE)
  main.category = category
  for _, page in ipairs(pages) do
    if Settings.RegisterCanvasLayoutSubcategory then
      page.category = Settings.RegisterCanvasLayoutSubcategory(category, page.frame, page.title)
    else
      page.category = Settings.RegisterCanvasLayoutCategory(page.frame, MAIN_TITLE .. ": " .. page.title)
      Settings.RegisterAddOnCategory(page.category)
    end
  end
  Settings.RegisterAddOnCategory(category)
elseif InterfaceOptions_AddCategory then
  InterfaceOptions_AddCategory(main.frame)
  for _, page in ipairs(pages) do
    page.frame.parent = MAIN_TITLE -- used by the pre-10.0 options frame
    InterfaceOptions_AddCategory(page.frame)
  end
end

-- See the header: a subcategory with `redirectCategory` set is left out of the
-- Settings category list. Assigning nil to a field that is already absent is
-- avoided so an all-on setup writes nothing into Blizzard's tables at all.
local function SetPageListed(page, listed)
  local sub = page.category
  if not sub or not category or sub == category then
    return
  end
  if listed then
    if rawget(sub, "redirectCategory") ~= nil then
      sub.redirectCategory = nil
    end
  else
    sub.redirectCategory = category
  end
end

RefreshVisibility = function()
  local changed = false
  for _, page in ipairs(pages) do
    local listed = page.Enabled() and true or false
    if page.listed ~= listed then
      page.listed = listed
      local ok, err = pcall(SetPageListed, page, listed)
      if not ok then
        Print("options: could not update the page list: " .. tostring(err))
      end
      changed = true
    end
  end
  if changed and type(SettingsPanel) == "table" and type(SettingsPanel.GetCategoryList) == "function" then
    pcall(function()
      local list = SettingsPanel:GetCategoryList()
      if list and list.CreateCategories then
        list:CreateCategories()
      end
    end)
  end
end

main.frame:HookScript("OnShow", function() RefreshVisibility() end)

-- Opens a page in the options window (the Settings buttons on the main page).
OpenPage = function(page)
  RefreshVisibility()
  if page.category and Settings and Settings.OpenToCategory then
    pcall(Settings.OpenToCategory, page.category.GetID and page.category:GetID() or page.frame.name)
  elseif InterfaceOptionsFrame_OpenToCategory then
    InterfaceOptionsFrame_OpenToCategory(page.frame)
    InterfaceOptionsFrame_OpenToCategory(page.frame) -- old clients need the second call
  end
end

-- Settings are loaded on ADDON_LOADED; by PLAYER_LOGIN every module has its
-- saved values, so that is when the initial page list is decided.
local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function(self)
  self:UnregisterEvent("PLAYER_LOGIN")
  RefreshVisibility()
end)
if IsLoggedIn and IsLoggedIn() then
  RefreshVisibility()
end

-- /bb and /bf open the main page. The one argument, "reap", is the line the
-- Soul Shard macro runs: it deletes one excess shard inside the keypress and
-- opens nothing (silent while that function is off).
SLASH_BETTERFOREVER1 = "/bb"
SLASH_BETTERFOREVER2 = "/bf"
SlashCmdList.BETTERFOREVER = function(msg)
  if type(msg) == "string" and msg:match("^%s*(%S*)"):lower() == "reap" then
    ss.Reap()
    return
  end
  RefreshVisibility()
  if category and Settings and Settings.OpenToCategory then
    Settings.OpenToCategory(category.GetID and category:GetID() or main.frame.name)
  elseif InterfaceOptionsFrame_OpenToCategory then
    InterfaceOptionsFrame_OpenToCategory(main.frame)
    InterfaceOptionsFrame_OpenToCategory(main.frame) -- old clients need the second call
  else
    Print("options: no options frame available in this client")
  end
end
