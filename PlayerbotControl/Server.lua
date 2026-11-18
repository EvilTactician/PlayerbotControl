-- Playerbot Control: server commands, optional modules and confirmations.
--
-- Some buttons use a server module's own chat command (".levelsync ...",
-- ".tokenturnin ..."). The server takes a command before anyone can see it.
-- Commands are whispered to yourself rather than said, so that on a server
-- without the module the text can't end up in front of other players.

local PBC = PlayerbotControl

-- [module] = true (answered), false (didn't), nil (not checked yet)
PBC.modules = {}

-- The check ends once every module has answered and a moment has passed, or
-- after PROBE_MAX seconds. Measured on the clock, not in frames: right after a
-- loading screen one frame can take seconds.
local PROBE_SETTLE = 1.5
local PROBE_MAX = 15

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
local answered = {}
local lastAnswer = 0

local function heard(name)
    answered[name] = true
    lastAnswer = GetTime()
end

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
            heard(name)
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
    for name, probe in pairs(probes) do
        if msg == probe.command then
            heard(name)
            return true
        end
    end
    return false
end

local function allAnswered()
    for name in pairs(probes) do
        if not answered[name] then
            return false
        end
    end
    return true
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

    local started = GetTime()
    local function finished()
        local now = GetTime()
        return (allAnswered() and (now - lastAnswer) >= PROBE_SETTLE) or (now - started) >= PROBE_MAX
    end
    local function wait()
        if not finished() then
            PBC:After(0.5, wait)
            return
        end
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
    end
    self:After(0.5, wait)
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
-- Game masters can use the core's ".instance unbind all <name>". Everyone
-- else needs mod-levelsync's ".levelsync unbindall <name>", which the server
-- has to allow. The first is tried on you, and if the server won't take it,
-- the second. Then the same one is sent for everyone else. Each is given a
-- name, so a selected target is never the one unbound. Both keep the lockout
-- of the instance that character is standing in.
--
-- The server answers every command with a few lines. Those are kept out of
-- the chat window and added up into one line at the end.
-------------------------------------------------------------------------------

local DETECT_WAIT = 3
local SEND_GAP = 0.3
local FINISH_WAIT = 2

local function plain(msg)
    return (string.gsub(string.gsub(msg, "|c%x%x%x%x%x%x%x%x", ""), "|r", ""))
end

-- others: names besides you. They need to be online for mod-levelsync.
function PBC:ResetLockouts(others)
    local me = UnitName("player")
    if not me or self.resettingLockouts then
        return
    end
    self.resettingLockouts = true

    local method          -- "gm" or "levelsync" once known
    local finished = false
    local removed, answered, skipped = 0, 0, 0
    local disabled = false

    local systemFilter, whisperFilter

    local function finish(message)
        if finished then
            return
        end
        finished = true
        ChatFrame_RemoveMessageEventFilter("CHAT_MSG_SYSTEM", systemFilter)
        ChatFrame_RemoveMessageEventFilter("CHAT_MSG_WHISPER", whisperFilter)
        ChatFrame_RemoveMessageEventFilter("CHAT_MSG_WHISPER_INFORM", whisperFilter)
        PBC.resettingLockouts = nil
        PBC:Print("Reset raid lockouts: " .. message)
    end

    local function summary()
        if disabled then
            finish("the server has mod-levelsync's unbind switched off. It needs LevelSync.AllowRaidUnbind = 1, or game master rights.")
            return
        end
        local who = (#others > 0) and ("you and " .. #others .. ((#others == 1) and " other" or " others")) or "you"
        local text = removed .. ((removed == 1) and " lockout" or " lockouts") .. " removed for " .. who .. "."
        if skipped > 0 then
            text = text .. " " .. skipped .. " couldn't be found (offline?)."
        end
        finish(text)
    end

    local function command(name)
        if method == "gm" then
            return ".instance unbind all " .. name
        end
        return ".levelsync unbindall " .. name
    end

    -- Everyone after you, a moment apart, then the summary.
    local function sendOthers()
        for index, name in ipairs(others) do
            PBC:After(index * SEND_GAP, function()
                if not finished then
                    PBC:Command(command(name))
                end
            end)
        end
        PBC:After(#others * SEND_GAP + FINISH_WAIT, summary)
    end

    local function useLevelSync()
        if method or finished then
            return
        end
        if not PBC.modules.levelsync then
            finish("the server didn't allow it. It needs game master rights, or mod-levelsync with LevelSync.AllowRaidUnbind = 1.")
            return
        end
        method = "levelsync"
        PBC:Command(command(me))
        sendOthers()
    end

    systemFilter = function(self, event, msg)
        if finished or type(msg) ~= "string" then
            return false
        end
        local text = plain(msg)
        local lower = string.lower(text)

        -- The core's answers
        local count = string.match(text, "^instances unbound: (%d+)")
        if count then
            removed = removed + tonumber(count)
            answered = answered + 1
            if not method then
                method = "gm"
                sendOthers()
            end
            return true
        end
        if string.find(text, "unbinding map:", 1, true) == 1 then
            return true
        end
        if string.find(lower, "player not found", 1, true) then
            skipped = skipped + 1
            return true
        end
        -- "Command '...' does not exist": the server lets players use dot
        -- commands, but not this one.
        if not method and (string.find(lower, "does not exist", 1, true) or string.find(lower, "no such command", 1, true)) then
            PBC:After(0, useLevelSync)
            return true
        end

        -- mod-levelsync's answers
        if string.find(text, "[LevelSync]", 1, true) then
            count = string.match(text, "Unbound (%d+) instance")
            if count then
                removed = removed + tonumber(count)
                answered = answered + 1
            elseif string.find(text, "not found or offline", 1, true) then
                skipped = skipped + 1
            elseif string.find(text, "disabled", 1, true) then
                disabled = true
            end
            return true
        end
        return false
    end

    -- A server that won't run the command for you hands it back as a whisper.
    whisperFilter = function(self, event, msg)
        if type(msg) == "string" and string.find(msg, ".instance unbind all ", 1, true) == 1 then
            if not method then
                PBC:After(0, useLevelSync)
            end
            return true
        end
        return false
    end

    ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", systemFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_WHISPER", whisperFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_WHISPER_INFORM", whisperFilter)
    self:Command(".instance unbind all " .. me)

    self:After(DETECT_WAIT, useLevelSync)
end
