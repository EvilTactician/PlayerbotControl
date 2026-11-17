-- Playerbot Control: server commands, optional modules and confirmations.
--
-- Some buttons use a server module's own chat command (".levelsync ...",
-- ".tokenturnin ..."). The server takes a command before anyone can see it.
-- Commands are whispered to yourself rather than said, so that on a server
-- without the module the text can't end up in front of other players.

local PBC = PlayerbotControl

-- [module] = true (answered), false (didn't), nil (not checked yet)
PBC.modules = {}

local PROBE_WINDOW = 4

function PBC:Command(text)
    local me = UnitName("player")
    if me then
        SendChatMessage(text, "WHISPER", nil, me)
    end
end

-------------------------------------------------------------------------------
-- Which optional modules does the server have?
--
-- The client can't see server modules, so once after logging in each one is
-- sent a harmless command and the answer is read. Everything the server says
-- back to those checks is kept out of the chat window.
-------------------------------------------------------------------------------

local probes = {
    levelsync = {
        command = ".levelsync level",
        word = "levelsync",
        -- With no argument the module answers with its usage line.
        found = function(msg) return string.find(msg, "Usage: .levelsync level on", 1, true) ~= nil end,
    },
    tokenturnin = {
        command = ".tokenturnin check",
        word = "tokenturnin",
        found = function(msg)
            return string.find(msg, "[TokenTurnIn]", 1, true) ~= nil
                and string.find(msg, "currently disabled", 1, true) == nil
        end,
    },
}

local probing = false

local function systemFilter(self, event, msg)
    if not probing or type(msg) ~= "string" then
        return false
    end
    local lower = string.lower(msg)
    for name, probe in pairs(probes) do
        if string.find(lower, probe.word, 1, true) then
            if probe.found(msg) then
                PBC.modules[name] = true
            end
            return true
        end
    end
    return false
end

-- A server that doesn't know the command hands it back as a whisper.
local function whisperFilter(self, event, msg)
    if not probing then
        return false
    end
    for _, probe in pairs(probes) do
        if msg == probe.command then
            return true
        end
    end
    return false
end

function PBC:ProbeModules()
    if probing then
        return
    end
    probing = true
    ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", systemFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_WHISPER", whisperFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_WHISPER_INFORM", whisperFilter)

    for _, probe in pairs(probes) do
        self:Command(probe.command)
    end

    self:After(PROBE_WINDOW, function()
        probing = false
        ChatFrame_RemoveMessageEventFilter("CHAT_MSG_SYSTEM", systemFilter)
        ChatFrame_RemoveMessageEventFilter("CHAT_MSG_WHISPER", whisperFilter)
        ChatFrame_RemoveMessageEventFilter("CHAT_MSG_WHISPER_INFORM", whisperFilter)
        for name in pairs(probes) do
            if PBC.modules[name] == nil then
                PBC.modules[name] = false
            end
        end
        PBC:Refresh()
    end)
end

-------------------------------------------------------------------------------
-- Confirmation popup
-------------------------------------------------------------------------------

StaticPopupDialogs["PLAYERBOTCONTROL_CONFIRM"] = {
    text = "%s",
    button1 = "Yes",
    button2 = "Cancel",
    OnAccept = function(self, data)
        if type(data) == "function" then
            data()
        end
    end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
}

-- Asks first; fn only runs when the button is pressed.
function PBC:Confirm(text, button, fn)
    StaticPopupDialogs["PLAYERBOTCONTROL_CONFIRM"].button1 = button or "Yes"
    StaticPopup_Show("PLAYERBOTCONTROL_CONFIRM", text, nil, fn)
end

-------------------------------------------------------------------------------
-- Raid and dungeon lockouts
--
-- Game masters can use the core's ".instance unbind all". Everyone else needs
-- mod-levelsync's ".levelsync unbindall", which the server has to allow. The
-- first is tried, and if the server won't take it, the second. Both name you,
-- so a selected target is never the one unbound. Both keep the lockout of the
-- instance you are standing in.
-------------------------------------------------------------------------------

local UNBIND_WAIT = 3

function PBC:ResetLockouts()
    local me = UnitName("player")
    if not me then
        return
    end
    local gmCommand = ".instance unbind all " .. me
    local finished = false

    local function refused(msg)
        local lower = string.lower(msg)
        return string.find(lower, "no such command", 1, true) ~= nil
            or string.find(lower, "incorrect syntax", 1, true) ~= nil
    end

    local systemFilter, whisperFilter
    local function stopWatching()
        ChatFrame_RemoveMessageEventFilter("CHAT_MSG_SYSTEM", systemFilter)
        ChatFrame_RemoveMessageEventFilter("CHAT_MSG_WHISPER", whisperFilter)
        ChatFrame_RemoveMessageEventFilter("CHAT_MSG_WHISPER_INFORM", whisperFilter)
    end

    local function fallBack()
        if finished then
            return
        end
        finished = true
        if PBC.modules.levelsync then
            PBC:Command(".levelsync unbindall " .. me)
        else
            PBC:Print("Reset raid lockouts: the server didn't allow it. It needs game master rights, or mod-levelsync with LevelSync.AllowRaidUnbind = 1.")
        end
    end

    systemFilter = function(self, event, msg)
        if finished or type(msg) ~= "string" then
            return false
        end
        if string.find(msg, "instances unbound:", 1, true) == 1 then
            finished = true
            return false
        end
        if refused(msg) then
            PBC:After(0, fallBack)
            return true
        end
        return false
    end

    -- A server that won't run the command for you hands it back as a whisper.
    whisperFilter = function(self, event, msg)
        if msg == gmCommand then
            PBC:After(0, fallBack)
            return true
        end
        return false
    end

    ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", systemFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_WHISPER", whisperFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_WHISPER_INFORM", whisperFilter)
    self:Command(gmCommand)

    self:After(UNBIND_WAIT, function()
        stopWatching()
        fallBack()
    end)
end
