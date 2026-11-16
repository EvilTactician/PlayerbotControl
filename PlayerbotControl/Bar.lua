-- Playerbot Control: the bar itself.
--
-- A row of group buttons, with each open group's buttons stacked above (or
-- below) it. Nothing here runs on a timer: the bar is only redrawn when a
-- setting, the bridge status or the bots' state changes.

local PBC = PlayerbotControl
local Bridge = PBC.Bridge

local Bar = {}
PBC.Bar = Bar

local SIZE = 32
local GAP = 4
local GRIP_WIDTH = 10

local headers = {}  -- [group id] = button
local buttons = {}  -- [action id] = button

-------------------------------------------------------------------------------
-- Which buttons show
-------------------------------------------------------------------------------

-- A button is left out when it's switched off in the options, or when the
-- server has said it doesn't support what the button needs.
local function isShown(action)
    if PBC.db.hidden[action.id] then
        return false
    end
    if action.caps then
        for _, cap in ipairs(action.caps) do
            if Bridge:Supports(cap) == false then
                return false
            end
        end
    end
    return true
end

-- A bridge button is greyed out until the bridge has answered.
local function isUsable(action)
    return not action.bridge or Bridge:IsReady()
end

-------------------------------------------------------------------------------
-- Button building
-------------------------------------------------------------------------------

local function setGrey(texture, grey)
    -- SetDesaturated says whether the graphics card could do it.
    local done = texture:SetDesaturated(grey)
    if grey and not done then
        texture:SetVertexColor(0.5, 0.5, 0.5)
    else
        texture:SetVertexColor(1, 1, 1)
    end
end

local function newButton(parent)
    local button = CreateFrame("Button", nil, parent)
    button:SetWidth(SIZE)
    button:SetHeight(SIZE)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints(button)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    button.icon = icon

    -- Coloured glow that shows a toggle's state.
    local glow = button:CreateTexture(nil, "OVERLAY")
    glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    glow:SetBlendMode("ADD")
    glow:SetWidth(SIZE * 1.75)
    glow:SetHeight(SIZE * 1.75)
    glow:SetPoint("CENTER", button, "CENTER", 0, 0)
    glow:Hide()
    button.glow = glow

    local corner = button:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    corner:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)
    button.corner = corner

    button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    button:SetPushedTexture("Interface\\Buttons\\UI-Quickslot-Depress")

    button:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    return button
end

local function showTooltip(button, build)
    if PBC.db.growDown then
        GameTooltip:SetOwner(button, "ANCHOR_BOTTOMRIGHT")
    else
        GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
    end
    build(GameTooltip)
    GameTooltip:Show()
end

local function actionTooltip(button)
    local action = button.action
    showTooltip(button, function(tooltip)
        tooltip:AddLine(action.name)
        if not isUsable(action) then
            tooltip:AddLine(Bridge:StatusText(), 1, 0.3, 0.3, true)
        else
            action.Tooltip(tooltip)
        end
    end)
end

local function getActionButton(action)
    local button = buttons[action.id]
    if button then
        return button
    end
    button = newButton(Bar.frame)
    button.action = action
    button:SetScript("OnClick", function(self, mouseButton)
        if not isUsable(action) then
            Bridge:Hello()
            PBC:Print(action.name .. ": " .. Bridge:StatusText())
            return
        end
        action.Click(mouseButton)
        if GameTooltip:IsOwned(self) then
            actionTooltip(self)
        end
    end)
    button:SetScript("OnEnter", actionTooltip)
    buttons[action.id] = button
    return button
end

local function headerTooltip(button)
    local group = button.group
    showTooltip(button, function(tooltip)
        tooltip:AddLine(group.name)
        if PBC.db.open[group.id] then
            tooltip:AddLine("Left-click: close this group", 1, 1, 1)
        else
            tooltip:AddLine("Left-click: open this group", 1, 1, 1)
        end
        tooltip:AddLine("Right-click: options", 1, 1, 1)
    end)
end

local function getHeader(group)
    local button = headers[group.id]
    if button then
        return button
    end
    button = newButton(Bar.frame)
    button.group = group
    button.icon:SetTexture(group.icon)

    -- A slot frame around the icon sets group buttons apart from actions.
    local frame = button:CreateTexture(nil, "OVERLAY")
    frame:SetTexture("Interface\\Buttons\\UI-Quickslot2")
    frame:SetWidth(SIZE * 1.72)
    frame:SetHeight(SIZE * 1.72)
    frame:SetPoint("CENTER", button, "CENTER", 0, -1)

    button:SetScript("OnClick", function(self, mouseButton)
        if mouseButton == "RightButton" then
            PBC.Options:Open()
            return
        end
        PBC.db.open[group.id] = not PBC.db.open[group.id]
        Bar:Refresh()
        if GameTooltip:IsOwned(self) then
            headerTooltip(self)
        end
    end)
    button:SetScript("OnEnter", headerTooltip)
    headers[group.id] = button
    return button
end

-------------------------------------------------------------------------------
-- Position and scale
-------------------------------------------------------------------------------

-- The position is kept as the bar's bottom-left corner in screen units, so
-- changing the scale doesn't make the bar wander.
function Bar:ApplyPosition()
    local frame = self.frame
    if not frame then
        return
    end
    local scale = PBC.db.scale or 1
    frame:SetScale(scale)
    frame:ClearAllPoints()
    local pos = PBC.db.pos
    if pos and pos.x and pos.y then
        frame:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", pos.x / scale, pos.y / scale)
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, -120 / scale)
    end
end

local function savePosition(frame)
    local scale = frame:GetScale()
    local left, bottom = frame:GetLeft(), frame:GetBottom()
    if left and bottom then
        PBC.db.pos = { x = left * scale, y = bottom * scale }
    end
    Bar:ApplyPosition()
end

-------------------------------------------------------------------------------
-- Create
-------------------------------------------------------------------------------

function Bar:Create()
    if self.frame then
        return
    end

    local frame = CreateFrame("Frame", "PlayerbotControlBar", UIParent)
    frame:SetWidth(GRIP_WIDTH + SIZE)
    frame:SetHeight(SIZE)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:SetFrameStrata("MEDIUM")
    self.frame = frame

    -- The grip: drag it to move the bar. Hidden while the bar is locked.
    local grip = CreateFrame("Button", nil, frame)
    grip:SetWidth(GRIP_WIDTH)
    grip:SetHeight(SIZE)
    grip:SetPoint("LEFT", frame, "LEFT", 0, 0)
    grip:RegisterForClicks("RightButtonUp")
    grip:RegisterForDrag("LeftButton")

    local back = grip:CreateTexture(nil, "BACKGROUND")
    back:SetAllPoints(grip)
    back:SetTexture(0, 0, 0, 0.6)
    for i = -1, 1 do
        local dot = grip:CreateTexture(nil, "ARTWORK")
        dot:SetWidth(4)
        dot:SetHeight(4)
        dot:SetPoint("CENTER", grip, "CENTER", 0, i * 8)
        dot:SetTexture(0.8, 0.8, 0.8, 0.9)
    end

    grip:SetScript("OnDragStart", function()
        if not PBC.db.locked then
            frame:StartMoving()
        end
    end)
    grip:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        savePosition(frame)
    end)
    grip:SetScript("OnClick", function()
        PBC.Options:Open()
    end)
    grip:SetScript("OnEnter", function(self)
        showTooltip(self, function(tooltip)
            tooltip:AddLine(PBC.title)
            tooltip:AddLine("Drag: move the bar", 1, 1, 1)
            tooltip:AddLine("Right-click: options", 1, 1, 1)
        end)
    end)
    grip:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    self.grip = grip

    self:ApplyPosition()
    self:Refresh()
end

-------------------------------------------------------------------------------
-- Refresh: lay the buttons out and bring every icon up to date.
-------------------------------------------------------------------------------

local function refreshAction(button)
    local action = button.action
    local icon, r, g, b, corner = action.Visual()
    local usable = isUsable(action)

    button.icon:SetTexture(icon)
    setGrey(button.icon, not usable)

    if usable and r then
        button.glow:SetVertexColor(r, g, b)
        button.glow:Show()
    else
        button.glow:Hide()
    end
    button.corner:SetText(usable and corner or "")

    if not usable then
        button:SetAlpha(0.6)
    elseif PBC.busy[action.id] then
        button:SetAlpha(0.5)
    else
        button:SetAlpha(1)
    end
end

function Bar:Refresh()
    local frame = self.frame
    if not frame or not PBC.db then
        return
    end

    local growDown = PBC.db.growDown
    local x = 0

    if PBC.db.locked then
        self.grip:Hide()
    else
        self.grip:Show()
        x = GRIP_WIDTH + GAP
    end

    for _, button in pairs(buttons) do
        button:Hide()
    end

    for _, group in ipairs(PBC.groups) do
        local members = {}
        for _, action in ipairs(PBC.actions) do
            if action.group == group.id and isShown(action) then
                members[#members + 1] = action
            end
        end

        local header = headers[group.id]
        if #members == 0 then
            if header then
                header:Hide()
            end
        else
            header = getHeader(group)
            header:ClearAllPoints()
            header:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", x, 0)
            header:Show()

            local open = PBC.db.open[group.id]
            if open then
                header:LockHighlight()
            else
                header:UnlockHighlight()
            end

            if open then
                for index, action in ipairs(members) do
                    local button = getActionButton(action)
                    local offset = index * (SIZE + GAP)
                    button:ClearAllPoints()
                    if growDown then
                        button:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", x, -offset)
                    else
                        button:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", x, offset)
                    end
                    refreshAction(button)
                    button:Show()
                end
            end

            x = x + SIZE + GAP
        end
    end

    frame:SetWidth(math.max(x - GAP, GRIP_WIDTH))
end
