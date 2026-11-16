-- Playerbot Control: the minimap button. Left-click shows or hides the bar,
-- right-click opens the options, dragging moves it around the minimap.

local PBC = PlayerbotControl

local MinimapButton = {}
PBC.MinimapButton = MinimapButton

local RADIUS = 80

local function place(button)
    local angle = math.rad(PBC.db.minimap.angle or 200)
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * RADIUS, math.sin(angle) * RADIUS)
end

-- Runs only while the button is being dragged.
local function followCursor(button)
    local centerX, centerY = Minimap:GetCenter()
    local cursorX, cursorY = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    PBC.db.minimap.angle = math.deg(math.atan2(cursorY / scale - centerY, cursorX / scale - centerX))
    place(button)
end

local function showTooltip(button)
    GameTooltip:SetOwner(button, "ANCHOR_LEFT")
    GameTooltip:AddLine(PBC.title)
    if PBC.db.shown then
        GameTooltip:AddLine("Left-click: hide the bar", 1, 1, 1)
    else
        GameTooltip:AddLine("Left-click: show the bar", 1, 1, 1)
    end
    GameTooltip:AddLine("Right-click: options", 1, 1, 1)
    GameTooltip:AddLine("Drag: move this button", 1, 1, 1)
    GameTooltip:Show()
end

function MinimapButton:Create()
    if self.button then
        return
    end

    local button = CreateFrame("Button", "PlayerbotControlMinimapButton", Minimap)
    button:SetWidth(31)
    button:SetHeight(31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local icon = button:CreateTexture(nil, "BACKGROUND")
    icon:SetWidth(20)
    icon:SetHeight(20)
    icon:SetPoint("TOPLEFT", button, "TOPLEFT", 7, -5)
    icon:SetTexture("Interface\\Icons\\Ability_Hunter_Pathfinding")
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    self.icon = icon

    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetWidth(53)
    border:SetHeight(53)
    border:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    button:SetScript("OnClick", function(self, mouseButton)
        if mouseButton == "RightButton" then
            PBC.Options:Open()
        else
            PBC:ToggleBar()
        end
        if GameTooltip:IsOwned(self) then
            showTooltip(self)
        end
    end)
    button:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", followCursor)
    end)
    button:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)
    button:SetScript("OnEnter", showTooltip)
    button:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    self.button = button
    place(button)
    self:Refresh()
end

function MinimapButton:Refresh()
    local button = self.button
    if not button or not PBC.db then
        return
    end
    if PBC.db.minimap.show then
        button:Show()
    else
        button:Hide()
    end
    -- Greyed while the bar is hidden.
    self.icon:SetDesaturated(not PBC.db.shown)
end
