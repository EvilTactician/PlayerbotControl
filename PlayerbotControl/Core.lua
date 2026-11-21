-- Playerbot Control: shared table, saved settings, timers, events and slash commands.

PlayerbotControl = PlayerbotControl or {}
local PBC = PlayerbotControl

PBC.name = "PlayerbotControl"
PBC.title = "Playerbot Control"
PBC.version = GetAddOnMetadata("PlayerbotControl", "Version") or "?"

-- What the bots were last told, as far as this session knows.
--   mode:    "follow", "stay", "flee" or nil (not known)
--   passive: true, false or nil (not known)
PBC.state = {}

local defaults = {
    scale = 1,
    shown = true,       -- the whole bar; the minimap button switches it
    locked = false,
    growDown = false,   -- groups open upwards unless this is set
    skull = true,       -- Attack also puts the Skull marker on the target
    confirm = false,    -- print a line in chat when an order succeeds
    open = { movement = false, combat = false, group = false, upkeep = false, party = false },
    hidden = {},        -- [action id] = true for buttons switched off
    minimap = { show = true, angle = 200 },
}

-- A /reload keeps the last known state; logging in again doesn't.
local RELOAD_WINDOW = 20

-------------------------------------------------------------------------------
-- Chat output
-------------------------------------------------------------------------------

function PBC:Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffPlayerbot Control:|r " .. tostring(msg))
end

-------------------------------------------------------------------------------
-- Timers. The frame only runs while a timer is waiting, so it costs nothing
-- the rest of the time.
-------------------------------------------------------------------------------

local timers = {}
local timerFrame = CreateFrame("Frame")
timerFrame:Hide()
timerFrame:SetScript("OnUpdate", function(self, elapsed)
    -- Collect what is due first and run it afterwards. A timer started by one
    -- of those runs waits for the next frame, so a long frame (right after a
    -- loading screen, a frame can take seconds) can't make a repeating timer
    -- fire over and over within it.
    local due
    for i = #timers, 1, -1 do
        local timer = timers[i]
        timer.left = timer.left - elapsed
        if timer.left <= 0 then
            table.remove(timers, i)
            due = due or {}
            table.insert(due, 1, timer)
        end
    end
    if due then
        for _, timer in ipairs(due) do
            timer.fn()
        end
    end
    if #timers == 0 then
        self:Hide()
    end
end)

function PBC:After(delay, fn)
    timers[#timers + 1] = { left = delay, fn = fn }
    timerFrame:Show()
end

-------------------------------------------------------------------------------
-- Group helpers
-------------------------------------------------------------------------------

function PBC:InRaid()
    return (GetNumRaidMembers() or 0) > 0
end

function PBC:InGroup()
    return self:InRaid() or (GetNumPartyMembers() or 0) > 0
end

-- Anyone can set markers in a party; a raid needs leader or assistant.
function PBC:CanMark()
    if self:InRaid() then
        return (IsRaidLeader() or IsRaidOfficer()) and true or false
    end
    return self:InGroup()
end

-------------------------------------------------------------------------------
-- Refresh: redraw the bar and the options panel, whichever exist.
-------------------------------------------------------------------------------

function PBC:Refresh()
    if self.Bar and self.Bar.Refresh then
        self.Bar:Refresh()
    end
    if self.MinimapButton and self.MinimapButton.Refresh then
        self.MinimapButton:Refresh()
    end
    if self.Options and self.Options.Refresh then
        self.Options:Refresh()
    end
end

function PBC:ToggleBar()
    self.db.shown = not self.db.shown
    self:Refresh()
end

function PBC:ResetState()
    if self.state.mode ~= nil or self.state.passive ~= nil then
        self.state.mode = nil
        self.state.passive = nil
        self:Refresh()
    end
end

-------------------------------------------------------------------------------
-- Saved settings
-------------------------------------------------------------------------------

local function applyDefaults(db, source)
    for key, value in pairs(source) do
        if type(value) == "table" then
            if type(db[key]) ~= "table" then
                db[key] = {}
            end
            applyDefaults(db[key], value)
        elseif db[key] == nil then
            db[key] = value
        end
    end
end

local function loadSettings()
    if type(PlayerbotControlDB) ~= "table" then
        PlayerbotControlDB = {}
    end
    if type(PlayerbotControlCharDB) ~= "table" then
        PlayerbotControlCharDB = {}
    end
    applyDefaults(PlayerbotControlDB, defaults)
    PBC.db = PlayerbotControlDB
    PBC.chardb = PlayerbotControlCharDB

    -- Altbot names belong to the character who plays with them.
    if type(PBC.chardb.altbots) ~= "table" then
        PBC.chardb.altbots = {}
    end
    if type(PBC.chardb.quickgroup) ~= "table" then
        PBC.chardb.quickgroup = {}
    end
    if type(PBC.chardb.quickgroup2) ~= "table" then
        PBC.chardb.quickgroup2 = {}
    end

    local saved = PBC.chardb.state
    local logoutAt = PBC.chardb.logoutAt
    if type(saved) == "table" and type(logoutAt) == "number" and (time() - logoutAt) <= RELOAD_WINDOW then
        PBC.state.mode = saved.mode
        PBC.state.passive = saved.passive
    end
    PBC.chardb.state = nil
    PBC.chardb.logoutAt = nil
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

local events = CreateFrame("Frame")
local enteredWorld = false
local rosterReady = false

events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PLAYER_LOGOUT")
events:RegisterEvent("CHAT_MSG_ADDON")
events:RegisterEvent("PARTY_MEMBERS_CHANGED")
events:RegisterEvent("RAID_ROSTER_UPDATE")

events:SetScript("OnEvent", function(self, event, ...)
    if event == "CHAT_MSG_ADDON" then
        PBC.Bridge:OnAddonMessage(...)
    elseif event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" then
        -- Out of the group: nothing is known about any bots any more.
        if rosterReady and not PBC:InGroup() then
            PBC:ResetState()
        end
    elseif event == "ADDON_LOADED" then
        if ... == PBC.name then
            loadSettings()
            self:UnregisterEvent("ADDON_LOADED")
        end
    elseif event == "PLAYER_LOGIN" then
        PBC.Bar:Create()
        PBC.MinimapButton:Create()
        PBC.Options:Create()
    elseif event == "PLAYER_ENTERING_WORLD" then
        if not enteredWorld then
            enteredWorld = true
            PBC:After(2, function()
                PBC.Bridge:Hello(true)
            end)
            PBC:After(4, function()
                PBC:ProbeModules()
            end)
            -- The group isn't known for the first moments after loading.
            PBC:After(5, function()
                rosterReady = true
                if not PBC:InGroup() then
                    PBC:ResetState()
                end
            end)
        end
    elseif event == "PLAYER_LOGOUT" then
        PBC.chardb.state = { mode = PBC.state.mode, passive = PBC.state.passive }
        PBC.chardb.logoutAt = time()
    end
end)

-------------------------------------------------------------------------------
-- Key bindings (Bindings.xml). Only Movement and Combat have them; the other
-- groups are better used with care. All are unbound until you set a key.
-------------------------------------------------------------------------------

BINDING_HEADER_PLAYERBOTCONTROL = "Playerbot Control"
BINDING_NAME_PLAYERBOTCONTROL_FOLLOWSTAY = "Follow / Stay"
BINDING_NAME_PLAYERBOTCONTROL_FLEE = "Flee"
BINDING_NAME_PLAYERBOTCONTROL_SUMMON = "Summon"
BINDING_NAME_PLAYERBOTCONTROL_PASSIVE = "Passive / Active"
BINDING_NAME_PLAYERBOTCONTROL_ATTACK = "Attack my target"
BINDING_NAME_PLAYERBOTCONTROL_CAREFULPULL = "Careful pull"
BINDING_NAME_PLAYERBOTCONTROL_PULL = "Pull"
BINDING_NAME_PLAYERBOTCONTROL_CC = "CC my target"

-- A key does what a left-click on the button does, even while the bar or the
-- button is hidden.
function PBC:RunBinding(id, mouseButton)
    local action = self.actionById and self.actionById[id]
    if not action or not self.db then
        return
    end
    if action.bridge and not self.Bridge:IsReady() then
        self.Bridge:Hello()
        self:Print(action.name .. ": " .. self.Bridge:StatusText())
        return
    end
    action.Click(mouseButton or "LeftButton")
end

-------------------------------------------------------------------------------
-- Slash commands
-------------------------------------------------------------------------------

SLASH_PLAYERBOTCONTROL1 = "/pbc"
SLASH_PLAYERBOTCONTROL2 = "/playerbotcontrol"

SlashCmdList["PLAYERBOTCONTROL"] = function(input)
    local cmd = string.lower(string.match(input or "", "^%s*(%S*)") or "")

    if cmd == "lock" then
        PBC.db.locked = true
        PBC:Refresh()
        PBC:Print("Bar locked.")
    elseif cmd == "unlock" then
        PBC.db.locked = false
        PBC:Refresh()
        PBC:Print("Bar unlocked. Drag the grip on its left to move it.")
    elseif cmd == "toggle" then
        PBC:ToggleBar()
    elseif cmd == "show" or cmd == "hide" then
        PBC.db.shown = (cmd == "show")
        PBC:Refresh()
    elseif cmd == "reset" then
        PBC.db.pos = nil
        PBC.db.scale = 1
        PBC.db.shown = true
        PBC.Bar:ApplyPosition()
        PBC:Refresh()
        PBC:Print("Bar moved back to the middle of the screen at normal size.")
    elseif cmd == "status" then
        PBC:Print("Version " .. PBC.version .. ". " .. PBC.Bridge:StatusText())
    elseif cmd == "" or cmd == "options" or cmd == "config" then
        PBC.Options:Open()
    else
        PBC:Print("/pbc (options), /pbc toggle, /pbc show, /pbc hide, /pbc lock, /pbc unlock, /pbc reset, /pbc status")
    end
end
