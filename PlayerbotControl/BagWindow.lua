-- Playerbot Control: a bot's bags, for picking what it sells or trades.
--
-- Opened from Sell (right-click) and Trade with one of your bots targeted.
--   sell   click an item and the bot sells it to the vendor it is next to;
--          the bot's buyback list sits underneath
--   trade  a trade opens with the bot; click an item and the bot puts it in
--          the trade window, then accept as usual
-- The bags are fetched once when the window opens; Refresh fetches again.

local PBC = PlayerbotControl
local Bridge = PBC.Bridge

local BagWindow = {}
PBC.BagWindow = BagWindow

local SIZE = 32
local GAP = 4
local COLUMNS = 8
local BUYBACK_SLOTS = 12

local REASONS = {
    VENDOR_NOT_FOUND = "isn't standing next to a vendor",
    QUEST_ITEM       = "can't sell quest items",
    KEY_ITEM         = "can't sell keys",
    HEARTHSTONE      = "won't sell its hearthstone",
    NO_SELL_PRICE    = "can't sell that: it has no sell price",
    NONEMPTY_BAG     = "can't sell a bag with items in it",
    SOURCE_STALE     = "doesn't have that item there any more. Refresh the bags",
    NO_TRADE         = "isn't in a trade with you",
    WRONG_TRADER     = "is trading with someone else",
    TRADE_FULL       = "has no room left in the trade window",
    NOT_TRADABLE     = "can't trade that item",
    WRONG_BINDING    = "can't trade soulbound items",
    BOT_DEAD         = "is dead",
    RATE_LIMIT       = "was asked too quickly, try again in a moment",
    TIMEOUT          = "didn't answer",
    NOT_ENOUGH_MONEY = "doesn't have the money to buy it back",
}

local function reasonText(reason)
    return REASONS[reason] or ("refused (" .. tostring(reason) .. ")")
end

-------------------------------------------------------------------------------
-- Frame
-------------------------------------------------------------------------------

local function itemButton(parent)
    local button = CreateFrame("Button", nil, parent)
    button:SetWidth(SIZE)
    button:SetHeight(SIZE)
    button:RegisterForClicks("LeftButtonUp")

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints(button)
    button.icon = icon

    local count = button:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    count:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -2, 2)
    button.count = count

    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    border:SetBlendMode("ADD")
    border:SetWidth(SIZE * 1.8)
    border:SetHeight(SIZE * 1.8)
    border:SetPoint("CENTER", button, "CENTER", 0, 0)
    button.border = border

    button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    button:SetScript("OnEnter", function(self)
        if not self.entry then
            return
        end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink("item:" .. self.entry.itemId)
        if self.hint then
            GameTooltip:AddLine(self.hint, 0.2, 1, 0.2, true)
        end
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    return button
end

local function showItem(button, entry)
    button.entry = entry
    button.icon:SetTexture(GetItemIcon(entry.itemId) or "Interface\\Icons\\INV_Misc_QuestionMark")
    button.count:SetText((entry.count or 1) > 1 and entry.count or "")
    local _, _, quality = GetItemInfo(entry.itemId)
    if quality and quality > 1 then
        local r, g, b = GetItemQualityColor(quality)
        button.border:SetVertexColor(r, g, b)
        button.border:Show()
    else
        button.border:Hide()
    end
    button:SetAlpha(entry.done and 0.35 or 1)
    button:Show()
end

function BagWindow:Create()
    if self.frame then
        return
    end
    local frame = CreateFrame("Frame", "PlayerbotControlBagWindow", UIParent)
    frame:SetWidth(COLUMNS * (SIZE + GAP) + 28)
    frame:SetHeight(200)
    frame:SetPoint("CENTER", UIParent, "CENTER", 250, 0)
    frame:SetFrameStrata("DIALOG")
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:Hide()
    tinsert(UISpecialFrames, "PlayerbotControlBagWindow")
    self.frame = frame

    local title = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    title:SetPoint("TOP", frame, "TOP", 0, -16)
    self.title = title

    local status = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    status:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -34)
    status:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
    status:SetJustifyH("LEFT")
    status:SetHeight(26)
    status:SetJustifyV("TOP")
    self.status = status

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)

    local refresh = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    refresh:SetWidth(80)
    refresh:SetHeight(20)
    refresh:SetText("Refresh")
    refresh:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -16, 14)
    refresh:SetScript("OnClick", function()
        BagWindow:Load()
    end)

    local buybackLabel = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    buybackLabel:SetText("Buy back")
    self.buybackLabel = buybackLabel

    self.items = {}
    self.buyback = {}
    for i = 1, BUYBACK_SLOTS do
        local button = itemButton(frame)
        button:SetScript("OnClick", function(b)
            BagWindow:BuyBack(b.entry)
        end)
        self.buyback[i] = button
    end

    frame:SetScript("OnHide", function()
        if BagWindow.mode == "trade" and TradeFrame and TradeFrame:IsShown() then
            CloseTrade()
        end
        BagWindow.bot = nil
    end)

    -- Trade mode follows the trade window.
    local events = CreateFrame("Frame")
    events:RegisterEvent("TRADE_SHOW")
    events:RegisterEvent("TRADE_CLOSED")
    events:SetScript("OnEvent", function(_, event)
        if BagWindow.mode ~= "trade" or not frame:IsShown() then
            return
        end
        if event == "TRADE_SHOW" then
            BagWindow.trading = true
            BagWindow:SetStatus("Click an item and " .. BagWindow.bot .. " puts it in the trade window. Accept when you're done.")
        elseif event == "TRADE_CLOSED" then
            BagWindow.trading = false
            frame:Hide()
        end
    end)
end

function BagWindow:SetStatus(text)
    self.status:SetText(text)
end

-------------------------------------------------------------------------------
-- Opening
-------------------------------------------------------------------------------

-- mode: "sell" or "trade". Uses your current target.
function BagWindow:OpenFor(mode)
    local label = (mode == "trade") and "Trade" or "Sell"
    local target = UnitExists("target") and UnitIsPlayer("target") and UnitName("target")
    local inGroup = false
    if target then
        if PBC:InRaid() then
            inGroup = UnitInRaid("target") and true or false
        else
            inGroup = UnitInParty("target") and true or false
        end
    end
    if not target or target == UnitName("player") or not inGroup then
        PBC:Print(label .. ": target one of your bots in your group first.")
        return
    end
    if not Bridge:IsReady() then
        PBC:Print(label .. ": " .. Bridge:StatusText())
        Bridge:Hello()
        return
    end
    if mode == "trade" and not CheckInteractDistance("target", 2) then
        PBC:Print("Trade: " .. target .. " is too far away to trade with.")
        return
    end

    self:Create()
    self.mode = mode
    self.bot = target
    self.trading = false
    self.title:SetText(target .. ": " .. label)
    if mode == "trade" then
        self:SetStatus("Opening a trade with " .. target .. "...")
        InitiateTrade("target")
    else
        self:SetStatus("Click an item and " .. target .. " sells it to the vendor it's standing next to.")
    end
    self.frame:Show()
    self:Load()
end

-------------------------------------------------------------------------------
-- Bags and buyback
-------------------------------------------------------------------------------

function BagWindow:Layout()
    local frame = self.frame
    local list = self.list or {}
    for _, button in ipairs(self.items) do
        button:Hide()
    end
    for index, entry in ipairs(list) do
        local button = self.items[index]
        if not button then
            button = itemButton(frame)
            button:SetScript("OnClick", function(b)
                BagWindow:Use(b)
            end)
            self.items[index] = button
        end
        local column = (index - 1) % COLUMNS
        local row = math.floor((index - 1) / COLUMNS)
        button:ClearAllPoints()
        button:SetPoint("TOPLEFT", frame, "TOPLEFT", 16 + column * (SIZE + GAP), -64 - row * (SIZE + GAP))
        button.hint = nil
        if self.mode == "sell" and entry.soulbound then
            button.hint = "Soulbound"
        end
        showItem(button, entry)
    end
    local rows = math.max(1, math.ceil(#list / COLUMNS))
    local height = 64 + rows * (SIZE + GAP) + 44

    for _, button in ipairs(self.buyback) do
        button:Hide()
    end
    if self.mode == "sell" then
        self.buybackLabel:ClearAllPoints()
        self.buybackLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -height + 34)
        self.buybackLabel:Show()
        for index, entry in ipairs(self.buybackList or {}) do
            local button = self.buyback[index]
            if button then
                local column = (index - 1) % COLUMNS
                local row = math.floor((index - 1) / COLUMNS)
                button:ClearAllPoints()
                button:SetPoint("TOPLEFT", frame, "TOPLEFT", 16 + column * (SIZE + GAP), -height + 16 - row * (SIZE + GAP))
                button.hint = "Click to buy back for " .. GetCoinTextureString(entry.price or 0)
                showItem(button, entry)
            end
        end
        height = height + 20 + 2 * (SIZE + GAP)
    else
        self.buybackLabel:Hide()
    end
    frame:SetHeight(height)
end

function BagWindow:Load()
    local bot = self.bot
    if not bot then
        return
    end
    Bridge:Bags(bot, function(items, reason)
        if self.bot ~= bot then
            return
        end
        if not items then
            self:SetStatus("Couldn't read " .. bot .. "'s bags: " .. reasonText(reason) .. ".")
            return
        end
        table.sort(items, function(a, b)
            if a.bag ~= b.bag then
                return a.bag < b.bag
            end
            return a.slot < b.slot
        end)
        self.list = items
        if #items == 0 then
            self:SetStatus(bot .. "'s bags are empty.")
        end
        self:Layout()
    end)
    if self.mode == "sell" then
        self:LoadBuyback()
    end
end

function BagWindow:LoadBuyback()
    local bot = self.bot
    Bridge:BuybackList(bot, function(entries)
        if self.bot ~= bot or self.mode ~= "sell" then
            return
        end
        self.buybackList = entries or {}
        self:Layout()
    end)
end

-------------------------------------------------------------------------------
-- Clicking
-------------------------------------------------------------------------------

local function link(itemId)
    local _, itemLink = GetItemInfo(itemId)
    return itemLink or ("item " .. itemId)
end

function BagWindow:Use(button)
    local entry, bot = button.entry, self.bot
    if not entry or entry.done or not bot then
        return
    end

    local function result(ok, reason)
        if ok then
            entry.done = true
            showItem(button, entry)
            if self.mode == "sell" then
                -- Once the clicking stops, read the bags and buyback list again.
                self.reloadDue = (self.reloadDue or 0) + 1
                local due = self.reloadDue
                PBC:After(1, function()
                    if due == self.reloadDue and self.bot == bot and self.frame:IsShown() then
                        self:Load()
                    end
                end)
            end
        else
            PBC:Print(bot .. " " .. reasonText(reason) .. ".")
        end
    end

    if self.mode == "trade" then
        if not self.trading then
            PBC:Print("Trade: the trade window with " .. bot .. " isn't open yet.")
            return
        end
        Bridge:TradeItem(bot, entry, result)
        return
    end

    -- Selling: ask first for anything rare or better, or soulbound gear.
    local _, _, quality = GetItemInfo(entry.itemId)
    if (quality and quality >= 3) or (entry.soulbound and IsEquippableItem(entry.itemId)) then
        PBC:Confirm("Sell " .. link(entry.itemId) .. ((entry.count or 1) > 1 and (" x" .. entry.count) or "") .. " from " .. bot .. "?\n\nYou can buy it back from the list underneath until the bot logs out.",
            "Sell",
            function()
                Bridge:SellItem(bot, entry, result)
            end)
        return
    end
    Bridge:SellItem(bot, entry, result)
end

function BagWindow:BuyBack(entry)
    local bot = self.bot
    if not entry or not bot then
        return
    end
    Bridge:BuyBack(bot, entry, function(ok, reason)
        if not ok then
            PBC:Print(bot .. " " .. reasonText(reason) .. ".")
            return
        end
        if self.bot == bot then
            self:Load()
        end
    end)
end
