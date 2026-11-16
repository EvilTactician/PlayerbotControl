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

    -- Buttons ----------------------------------------------------------------

    local buttonsHeading = addHeading(panel, "Buttons on the bar")
    buttonsHeading:SetPoint("TOPLEFT", confirm, "BOTTOMLEFT", 0, -16)

    -- One column per group.
    local column = 0
    for _, group in ipairs(PBC.groups) do
        local groupLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        groupLabel:SetPoint("TOPLEFT", buttonsHeading, "BOTTOMLEFT", column * 150, -8)
        groupLabel:SetText(group.name)

        local previous = groupLabel
        for _, action in ipairs(PBC.actions) do
            if action.group == group.id then
                local id = action.id
                local check = addCheck(panel, action.name, nil,
                    function() return not PBC.db.hidden[id] end,
                    function(value) PBC.db.hidden[id] = (not value) or nil end)
                check:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -4)
                previous = check
            end
        end
        column = column + 1
    end

    panel:SetScript("OnShow", function()
        Options:Refresh()
    end)

    InterfaceOptions_AddCategory(panel)
end

function Options:Refresh()
    local panel = self.panel
    if not panel or not panel:IsShown() then
        return
    end
    self.status:SetText(Bridge:StatusText())
    self.slider:SetValue(PBC.db.scale or 1)
    self.slider.showSize(PBC.db.scale or 1)
    for _, check in ipairs(checks) do
        check.button:SetChecked(check.get() and true or false)
    end
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
