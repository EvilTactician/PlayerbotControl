-- Playerbot Control: the panel under Interface > AddOns.

local PBC = PlayerbotControl
local Bridge = PBC.Bridge

local Options = {}
PBC.Options = Options

local checks = {}   -- { button = CheckButton, get = function }
local count = 0

local function newName(kind)
    count = count + 1
    return "PlayerbotControlOptions" .. kind .. count
end

local function addCheck(parent, label, tip, get, set)
    local name = newName("Check")
    local check = CreateFrame("CheckButton", name, parent, "InterfaceOptionsCheckButtonTemplate")
    _G[name .. "Text"]:SetText(label)
    check.tooltipText = tip
    check:SetScript("OnClick", function(self)
        set(self:GetChecked() and true or false)
        PBC:Refresh()
    end)
    checks[#checks + 1] = { button = check, get = get }
    return check
end

local function addHeading(parent, text)
    local heading = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    heading:SetText(text)
    return heading
end

function Options:Create()
    if self.panel then
        return
    end

    local panel = CreateFrame("Frame", "PlayerbotControlOptionsPanel", UIParent)
    panel.name = PBC.title
    panel:Hide()
    self.panel = panel

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -16)
    title:SetText(PBC.title .. " " .. PBC.version)

    local status = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    status:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    status:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
    status:SetJustifyH("LEFT")
    self.status = status

    -- The bar ----------------------------------------------------------------

    local barHeading = addHeading(panel, "The bar")
    barHeading:SetPoint("TOPLEFT", status, "BOTTOMLEFT", 0, -16)

    local sliderName = newName("Slider")
    local slider = CreateFrame("Slider", sliderName, panel, "OptionsSliderTemplate")
    slider:SetPoint("TOPLEFT", barHeading, "BOTTOMLEFT", 4, -24)
    slider:SetWidth(200)
    slider:SetMinMaxValues(0.5, 2)
    slider:SetValueStep(0.05)
    _G[sliderName .. "Low"]:SetText("50%")
    _G[sliderName .. "High"]:SetText("200%")
    local function showSize(value)
        _G[sliderName .. "Text"]:SetText("Size: " .. math.floor(value * 100 + 0.5) .. "%")
    end
    slider.showSize = showSize
    slider:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value * 20 + 0.5) / 20
        showSize(value)
        if PBC.db.scale ~= value then
            PBC.db.scale = value
            PBC.Bar:ApplyPosition()
        end
    end)
    self.slider = slider

    local shown = addCheck(panel, "Show the bar",
        "The minimap button and /pbc toggle switch this too.",
        function() return PBC.db.shown end,
        function(value) PBC.db.shown = value end)
    shown:SetPoint("TOPLEFT", slider, "BOTTOMLEFT", -4, -22)

    local lock = addCheck(panel, "Lock the bar in place",
        "Hides the grip on the left of the bar so it can't be dragged.",
        function() return PBC.db.locked end,
        function(value) PBC.db.locked = value end)
    lock:SetPoint("TOPLEFT", shown, "BOTTOMLEFT", 0, -4)

    local down = addCheck(panel, "Open groups downwards",
        "A group's buttons appear below the bar instead of above it.",
        function() return PBC.db.growDown end,
        function(value) PBC.db.growDown = value end)
    down:SetPoint("TOPLEFT", lock, "BOTTOMLEFT", 0, -4)

    local minimap = addCheck(panel, "Show the minimap button",
        "Left-click it to show or hide the bar, right-click it for these options. Drag it to move it around the minimap.",
        function() return PBC.db.minimap.show end,
        function(value) PBC.db.minimap.show = value end)
    minimap:SetPoint("TOPLEFT", down, "BOTTOMLEFT", 0, -4)

    local reset = CreateFrame("Button", newName("Button"), panel, "UIPanelButtonTemplate")
    reset:SetWidth(140)
    reset:SetHeight(22)
    reset:SetText("Reset position")
    reset:SetPoint("LEFT", slider, "RIGHT", 40, 0)
    reset:SetScript("OnClick", function()
        PBC.db.pos = nil
        PBC.Bar:ApplyPosition()
    end)

    -- Behaviour --------------------------------------------------------------

    local behaviourHeading = addHeading(panel, "Behaviour")
    behaviourHeading:SetPoint("TOPLEFT", minimap, "BOTTOMLEFT", 0, -16)

    local skull = addCheck(panel, "Attack also marks the target with Skull",
        "Bots focus the Skull marker by default, so this keeps them on your target.",
        function() return PBC.db.skull end,
        function(value) PBC.db.skull = value end)
    skull:SetPoint("TOPLEFT", behaviourHeading, "BOTTOMLEFT", 0, -6)

    local confirm = addCheck(panel, "Confirm orders in chat",
        "Prints a line when an order succeeds. Failures are always printed.",
        function() return PBC.db.confirm end,
        function(value) PBC.db.confirm = value end)
    confirm:SetPoint("TOPLEFT", skull, "BOTTOMLEFT", 0, -4)

    local more = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    more:SetPoint("TOPLEFT", confirm, "BOTTOMLEFT", 0, -16)
    more:SetWidth(560)
    more:SetJustifyH("LEFT")
    more:SetText("Switching buttons on and off, and your altbot names, are on the Buttons and Altbots pages under this one.")

    panel:SetScript("OnShow", function()
        Options:Refresh()
    end)

    InterfaceOptions_AddCategory(panel)

    self:CreateButtonsPanel()
    self:CreateAltbotsPanel()
end

-- A page listed under the main one in Interface > AddOns.
local function subPanel(name, heading, intro, introHeight)
    local sub = CreateFrame("Frame", nil, UIParent)
    sub.name = name
    sub.parent = PBC.title
    sub:Hide()

    local title = sub:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", sub, "TOPLEFT", 16, -16)
    title:SetText(heading)

    local text = sub:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    text:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    text:SetWidth(560)
    text:SetHeight(introHeight or 14)
    text:SetJustifyH("LEFT")
    text:SetJustifyV("TOP")
    text:SetText(intro)
    sub.intro = text

    sub:SetScript("OnShow", function()
        Options:Refresh()
    end)
    return sub
end

-------------------------------------------------------------------------------
-- Buttons: switch each button on or off
-------------------------------------------------------------------------------

function Options:CreateButtonsPanel()
    local sub = subPanel("Buttons", PBC.title .. ": Buttons",
        "Untick a button to take it off the bar. A group with no buttons left disappears.")
    self.buttonsPanel = sub

    -- Three groups to a row. Each row starts below the longest group above.
    local COLUMNS, WIDTH = 3, 190
    local rowTop, rowColumn, rowOffset = sub.intro, 0, -16
    local tallest, tallestColumn, tallestCount = nil, 0, -1
    for index, group in ipairs(PBC.groups) do
        local column = (index - 1) % COLUMNS
        if column == 0 and index > 1 then
            rowTop, rowColumn, rowOffset = tallest, tallestColumn, -16
            tallest, tallestCount = nil, -1
        end

        local groupLabel = sub:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        groupLabel:SetPoint("TOPLEFT", rowTop, "BOTTOMLEFT", (column - rowColumn) * WIDTH, rowOffset)
        groupLabel:SetText(group.name)

        local previous, count = groupLabel, 0
        for _, action in ipairs(PBC.actions) do
            if action.group == group.id then
                local id = action.id
                local check = addCheck(sub, action.name, nil,
                    function() return not PBC.db.hidden[id] end,
                    function(value) PBC.db.hidden[id] = (not value) or nil end)
                check:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -4)
                previous = check
                count = count + 1
            end
        end

        if count > tallestCount then
            tallest, tallestColumn, tallestCount = previous, column, count
        end
    end

    InterfaceOptions_AddCategory(sub)
end

-------------------------------------------------------------------------------
-- Altbots: the two name lists
-------------------------------------------------------------------------------

-- Names typed one per line (commas and spaces work too), without repeats.
local function parseNames(text)
    local names, seen = {}, {}
    for name in string.gmatch(text or "", "[^%s,;]+") do
        local key = string.lower(name)
        if not seen[key] then
            seen[key] = true
            names[#names + 1] = name
        end
    end
    return names
end

local nameBoxes = {}

-- A heading, a short note under it, and the box. x and y place the heading
-- relative to the bottom-left of anchor.
local BOX_WIDTH = 220

local function addNameBox(parent, anchor, x, y, label, tip, listKey)
    local heading = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    heading:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", x, y)
    heading:SetText(label)

    local note = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    note:SetPoint("TOPLEFT", heading, "BOTTOMLEFT", 0, -4)
    note:SetWidth(BOX_WIDTH)
    note:SetHeight(28)
    note:SetJustifyH("LEFT")
    note:SetJustifyV("TOP")
    note:SetText(tip)

    local box = CreateFrame("Frame", nil, parent)
    box:SetPoint("TOPLEFT", note, "BOTTOMLEFT", 0, -4)
    box:SetWidth(BOX_WIDTH)
    box:SetHeight(120)
    box:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    box:SetBackdropColor(0, 0, 0, 0.6)

    local scrollName = newName("Scroll")
    local scroll = CreateFrame("ScrollFrame", scrollName, box, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", box, "TOPLEFT", 8, -8)
    scroll:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -28, 8)

    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetFontObject(ChatFontNormal)
    edit:SetWidth(BOX_WIDTH - 40)
    edit:SetHeight(100)
    scroll:SetScrollChild(edit)

    local function save()
        PBC.chardb[listKey] = parseNames(edit:GetText())
    end
    edit:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    edit:SetScript("OnTextChanged", function(self)
        if not self.filling then
            save()
        end
        ScrollingEdit_OnTextChanged(self, scroll)
    end)
    edit:SetScript("OnCursorChanged", ScrollingEdit_OnCursorChanged)
    edit:SetScript("OnUpdate", function(self, elapsed)
        ScrollingEdit_OnUpdate(self, elapsed, scroll)
    end)
    -- Tidies the list (one name per line) once you click away.
    edit:SetScript("OnEditFocusLost", function(self)
        save()
        Options:FillNames()
    end)

    -- Clicking anywhere in the box starts typing.
    box:EnableMouse(true)
    box:SetScript("OnMouseDown", function()
        edit:SetFocus()
    end)

    nameBoxes[#nameBoxes + 1] = { edit = edit, key = listKey }
    return box
end

function Options:CreateAltbotsPanel()
    local sub = subPanel("Altbots", PBC.title .. ": Altbots",
        "Altbots are characters you have manually created either on your account or another, linked account. The server can't tell them apart from random bots, so list them here to use this addon to its full extent.\n\n"
            .. "Type one name per line. Commas or spaces between names work too, and capitals don't matter. "
            .. "Changes are saved as you type. A name can be on more than one list. These lists belong to the character you're playing.",
        56)
    self.altbotsPanel = sub

    local altbots = addNameBox(sub, sub.intro, 0, -12, "Altbots",
        "Park altbots and Logout altbots act on these names when they're in your group.",
        "altbots")
    addNameBox(sub, altbots, 0, -16, "Quick group 1",
        "Left-click Quick group to log these in and invite them.",
        "quickgroup")
    addNameBox(sub, altbots, BOX_WIDTH + 30, -16, "Quick group 2",
        "Right-click Quick group to log these in and invite them.",
        "quickgroup2")

    InterfaceOptions_AddCategory(sub)
end

-- Writes the saved lists into the boxes, except one you're typing in.
function Options:FillNames()
    for _, entry in ipairs(nameBoxes) do
        local edit = entry.edit
        if not edit:HasFocus() then
            edit.filling = true
            edit:SetText(table.concat(PBC.chardb[entry.key] or {}, "\n"))
            edit.filling = nil
        end
    end
end

function Options:Refresh()
    local shown = (self.panel and self.panel:IsShown())
        or (self.buttonsPanel and self.buttonsPanel:IsShown())
        or (self.altbotsPanel and self.altbotsPanel:IsShown())
    if not shown then
        return
    end
    self.status:SetText(Bridge:StatusText())
    self.slider:SetValue(PBC.db.scale or 1)
    self.slider.showSize(PBC.db.scale or 1)
    for _, check in ipairs(checks) do
        check.button:SetChecked(check.get() and true or false)
    end
    self:FillNames()
end

function Options:Open()
    if not self.panel then
        return
    end
    -- Called twice on purpose: the first call on a fresh login only opens
    -- the window without selecting the panel.
    InterfaceOptionsFrame_OpenToCategory(self.panel)
    InterfaceOptionsFrame_OpenToCategory(self.panel)
end
