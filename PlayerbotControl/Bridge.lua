-- Playerbot Control: talks to mod-multibot-bridge.
--
-- The bridge listens for addon messages with the prefix "MBOT". They are
-- whispered to yourself, the server takes them before anyone could see them,
-- and it answers the same way. Nothing is typed into chat and no bot is
-- whispered. A message is only ever sent when you click a button (plus one
-- hello after logging in).

local PBC = PlayerbotControl
local Bridge = {}
PBC.Bridge = Bridge

local PREFIX = "MBOT"
local PROTOCOL = "1"
local ACK_TIMEOUT = 5
local HELLO_TIMEOUT = 6
local HELLO_COOLDOWN = 10

-- "unknown" (not asked yet), "connecting", "ready", "missing", "incompatible"
Bridge.status = "unknown"
Bridge.caps = {}
Bridge.capsKnown = false
Bridge.serverName = nil

local pending = {}
local counter = 0
local session = tostring(time())
local lastHello = -1000
local helloSeq = 0

-- Acknowledgements that carry "matched, succeeded, failed, reason": where
-- the token and the first of the three counts sit.
local ACKS = {
    FOLLOW_ORDER_ACK = { token = 1, counts = 2 },
    STAY_ORDER_ACK   = { token = 1, counts = 2 },
    ATTACK_ORDER_ACK = { token = 1, counts = 3 },
    FLEE_ORDER_ACK   = { token = 1, counts = 3 },
    GROUP_ACTION_ACK = { token = 1, counts = 3 },
    BOT_RESET_ACK    = { token = 1, counts = 4 },
    STRATEGY_ACK     = { token = 3, counts = 5 },
}

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

-- Splits on a plain separator and keeps empty fields.
local function split(text, sep)
    local out, start = {}, 1
    while true do
        local pos = string.find(text, sep, start, true)
        if not pos then
            out[#out + 1] = string.sub(text, start)
            break
        end
        out[#out + 1] = string.sub(text, start, pos - 1)
        start = pos + 1
    end
    return out
end

-- Percent-encodes everything but letters and digits, for names.
local function encode(text)
    return (string.gsub(text or "", "[^%w]", function(char)
        return string.format("%%%02X", string.byte(char))
    end))
end

local function decode(text)
    return (string.gsub(text or "", "%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

local function send(opcode, payload)
    local me = UnitName("player")
    if not me then
        return false
    end
    local message = opcode
    if payload and payload ~= "" then
        message = message .. "~" .. payload
    end
    SendAddonMessage(PREFIX, message, "WHISPER", me)
    return true
end

local function nextToken()
    counter = counter + 1
    return "PBC-" .. session .. "-" .. counter
end

-------------------------------------------------------------------------------
-- Status
-------------------------------------------------------------------------------

function Bridge:IsReady()
    return self.status == "ready"
end

-- true or false once the server has listed what it supports, nil before that.
function Bridge:Supports(cap)
    if not self.capsKnown then
        return nil
    end
    return self.caps[cap] and true or false
end

function Bridge:StatusText()
    if self.status == "ready" then
        return "Connected to " .. (self.serverName or "mod-multibot-bridge") .. "."
    elseif self.status == "connecting" then
        return "Looking for mod-multibot-bridge..."
    elseif self.status == "missing" then
        return "mod-multibot-bridge didn't answer. Is it installed on the server?"
    elseif self.status == "incompatible" then
        return "mod-multibot-bridge uses a protocol this version doesn't know."
    end
    return "Not connected yet."
end

-------------------------------------------------------------------------------
-- Hello
-------------------------------------------------------------------------------

function Bridge:Hello(force)
    local now = GetTime()
    if not force and (now - lastHello) < HELLO_COOLDOWN then
        return
    end
    lastHello = now

    if self.status ~= "ready" then
        self.status = "connecting"
    end

    helloSeq = helloSeq + 1
    local seq = helloSeq
    send("HELLO", PROTOCOL)

    PBC:After(HELLO_TIMEOUT, function()
        if seq == helloSeq and Bridge.status == "connecting" then
            Bridge.status = "missing"
            PBC:Refresh()
        end
    end)
    PBC:Refresh()
end

-------------------------------------------------------------------------------
-- Requests
--
-- Group orders call back with (ok, reason, matched, succeeded, failed):
--   ok       true when at least one bot took the order
--   reason   the server's word for it: OK, PARTIAL, NO_GROUP, NO_BOTS, ...
--            or ours: NO_BRIDGE, CONNECTING, TIMEOUT
-- Orders for one bot call back with (ok, reason, number).
-------------------------------------------------------------------------------

-- Sends a request and keeps its callback until the answer or the timeout.
local function request(token, payload, callback, timeout, opcode)
    pending[token] = callback
    send(opcode or "RUN", payload)

    PBC:After(timeout or ACK_TIMEOUT, function()
        if pending[token] == callback then
            pending[token] = nil
            callback(false, "TIMEOUT", 0, 0, 0)
        end
    end)
end

local function run(build, callback, opcode)
    if Bridge.status ~= "ready" then
        local reason = (Bridge.status == "connecting") and "CONNECTING" or "NO_BRIDGE"
        Bridge:Hello()
        callback(false, reason, 0, 0, 0)
        return
    end
    local token = nextToken()
    request(token, build(token), callback, nil, opcode)
end

function Bridge:FollowOrder(callback)
    run(function(token) return "FOLLOW_ORDER~" .. token end, callback)
end

function Bridge:StayOrder(callback)
    run(function(token) return "STAY_ORDER~" .. token end, callback)
end

function Bridge:FleeOrder(callback)
    run(function(token) return "FLEE_ORDER~" .. token .. "~ALL~" end, callback)
end

-- The server reads your current target itself.
function Bridge:AttackOrder(callback)
    run(function(token) return "ATTACK_ORDER~" .. token .. "~ALL" end, callback)
end

-- action: SUMMON, DRINK, RELEASE or REVIVE
function Bridge:GroupAction(action, callback)
    run(function(token) return "GROUP_ACTION~" .. token .. "~" .. action end, callback)
end

-- Every bot in the group rolls 1-100.
function Bridge:GroupRoll(callback)
    run(function(token) return "GROUP_ROLL~" .. token .. "~NORMAL" end, callback)
end

-- operation: "ACTIONS" (drop what they're doing) or "AI" (strategies back to
-- their defaults)
function Bridge:GroupReset(operation, callback)
    run(function(token) return "BOT_RESET~" .. token .. "~GROUP~" .. operation .. "~" end, callback)
end

-- Changes strategies on the bots in your group.
--   state:   "C" (combat) or "N" (non-combat)
--   changes: such as "+passive" or "-passive"
function Bridge:GroupStrategy(state, changes, callback)
    run(function(token) return "STRATEGY~GROUP~~" .. token .. "~" .. state .. "~" .. changes end, callback)
end

-- One bot: repair, reagents, food and the rest of Playerbots' maintenance.
function Bridge:Maintenance(bot, callback)
    run(function(token) return "BOT_MAINTENANCE~" .. bot .. "~" .. token end, callback)
end

-- One bot sells to a vendor it is standing next to.
--   action: "SELL_GREY" or "SELL_VENDOR". The number is how many it sold.
function Bridge:Sell(bot, action, callback)
    run(function(token) return "ITEM_ACTION~" .. bot .. "~" .. token .. "~" .. action .. "~0~0" end, callback)
end

-- One bot: new gear from the server's item pool, with the server's own
-- limits. The server wants this in two steps, a plan and then the go-ahead.
-- The number is how many slots changed.
function Bridge:Autogear(bot, callback)
    if self.status ~= "ready" then
        run(nil, callback)
        return
    end
    local token = nextToken()
    request(token, "AUTOGEAR_PLAN~" .. token .. "~" .. bot .. "~DEFAULT~0~0", function(ok, reason)
        if not ok then
            callback(false, reason, 0)
            return
        end
        request(token, "AUTOGEAR_APPLY~" .. token, callback, 10)
    end)
end

-- Changes strategies on one bot by name, in or out of your group.
function Bridge:BotStrategy(bot, state, changes, callback)
    run(function(token) return "STRATEGY~BOT~" .. encode(bot) .. "~" .. token .. "~" .. state .. "~" .. changes end, callback)
end

-- Looks a character up by name. Only characters you may control as bots
-- are found. The callback gets (ok, reason, guid, state, name), where state
-- is ONLINE, OFFLINE or CONNECTING and name is spelt as the server has it.
function Bridge:Resolve(name, callback)
    run(function(token) return "BOT_TARGET_RESOLVE~" .. encode(name) .. "~" .. token end, callback, "GET")
end

-- Logs a bot in. It joins your group by itself once it is online.
function Bridge:Login(guid, callback)
    run(function(token) return "BOT_CONNECT~" .. guid .. "~" .. token end, callback)
end

-- Removes a bot from your group and logs it out.
function Bridge:LogoutFromGroup(guid, callback)
    run(function(token) return "BOT_DISCONNECT_GROUP~" .. guid .. "~" .. token end, callback)
end

-- Asks which bots the bridge can see: yours, and random bots in your group.
-- The callback gets a table of [lower-case name] = true, or nil on failure.
local rosterCallback
function Bridge:Roster(callback)
    if self.status ~= "ready" then
        callback(nil)
        return
    end
    if rosterCallback then
        local previous = rosterCallback
        rosterCallback = function(bots)
            previous(bots)
            callback(bots)
        end
        return
    end
    rosterCallback = callback
    send("GET", "ROSTER")
    PBC:After(ACK_TIMEOUT, function()
        if rosterCallback then
            local waiting = rosterCallback
            rosterCallback = nil
            waiting(nil)
        end
    end)
end

-------------------------------------------------------------------------------
-- Incoming
-------------------------------------------------------------------------------

local function resolve(token, ...)
    local callback = token and pending[token]
    if not callback then
        return -- not ours (MultiBot shares the prefix) or already timed out
    end
    pending[token] = nil
    callback(...)
end

function Bridge:OnAddonMessage(prefix, message, channel, sender)
    if prefix ~= PREFIX or type(message) ~= "string" then
        return
    end
    if sender ~= UnitName("player") then
        return
    end

    local sep = string.find(message, "~", 1, true)
    local opcode = sep and string.sub(message, 1, sep - 1) or message
    local payload = sep and string.sub(message, sep + 1) or ""

    local layout = ACKS[opcode]
    if layout then
        local fields = split(payload, "~")
        local reason = decode(fields[layout.counts + 3] or "FAILED")
        local succeeded = tonumber(fields[layout.counts + 1]) or 0
        resolve(fields[layout.token],
            (reason == "OK") or (reason == "PARTIAL" and succeeded > 0),
            reason,
            tonumber(fields[layout.counts]) or 0,
            succeeded,
            tonumber(fields[layout.counts + 2]) or 0)
    elseif opcode == "GROUP_ROLL_ACK" then
        -- token ~ status ~ mode ~ scope ~ matched ~ invoked ~ reason
        local fields = split(payload, "~")
        local matched, invoked = tonumber(fields[5]) or 0, tonumber(fields[6]) or 0
        resolve(fields[1], fields[2] == "OK", decode(fields[7] or "FAILED"), matched, invoked, matched - invoked)
    elseif opcode == "BOT_MAINTENANCE_ACK" then
        -- token ~ bot ~ status ~ reason
        local fields = split(payload, "~")
        resolve(fields[1], fields[3] == "OK", decode(fields[4] or "FAILED"), 0)
    elseif opcode == "INVENTORY_ITEM_ACTION" then
        -- bot ~ token ~ action ~ item ~ status ~ reason ~ how many
        local fields = split(payload, "~")
        resolve(fields[2], fields[5] == "OK", decode(fields[6] or "FAILED"), tonumber(fields[7]) or 0)
    elseif opcode == "AUTOGEAR_READY" or opcode == "AUTOGEAR_RESULT" then
        -- token ~ status ~ reason ~ number ~ number
        local fields = split(payload, "~")
        resolve(fields[1], fields[2] == "OK", decode(fields[3] or "FAILED"), tonumber(fields[4]) or 0)
    elseif opcode == "ROSTER" then
        -- name,class,level,... ; name,class,level,...
        if rosterCallback then
            local waiting, bots = rosterCallback, {}
            rosterCallback = nil
            for entry in string.gmatch(payload, "[^;]+") do
                local name = string.match(entry, "^([^,]+)")
                if name then
                    bots[string.lower(name)] = true
                end
            end
            waiting(bots)
        end
    elseif opcode == "BOT_TARGET_RESOLVE" then
        -- token ~ status ~ reason ~ name ~ guid ~ state
        local fields = split(payload, "~")
        resolve(fields[1], fields[2] == "OK", decode(fields[3] or "FAILED"),
            tonumber(fields[5]) or 0, fields[6] or "UNKNOWN", decode(fields[4] or ""))
    elseif opcode == "BOT_LIFECYCLE" then
        -- token ~ guid ~ name ~ action ~ status ~ reason
        local fields = split(payload, "~")
        resolve(fields[1], fields[5] == "OK" or fields[5] == "PENDING", decode(fields[6] or "FAILED"), 0)
    elseif opcode == "ERR" then
        -- opcode ~ request type ~ token ~ reason
        local fields = split(payload, "~")
        if fields[1] == "HELLO" then
            if self.status ~= "ready" then
                self.status = "incompatible"
                PBC:Refresh()
            end
        else
            resolve(fields[3], false, decode(fields[4] or "FAILED"), 0, 0, 0)
        end
    elseif opcode == "HELLO_ACK" then
        local fields = split(payload, "~")
        self.status = "ready"
        self.serverName = fields[2]
        PBC:Refresh()
    elseif opcode == "CAPS_BEGIN" then
        self.incomingCaps = {}
    elseif opcode == "CAPS" then
        if self.incomingCaps then
            for _, cap in ipairs(split(payload, ",")) do
                self.incomingCaps[cap] = true
            end
        end
    elseif opcode == "CAPS_END" then
        if self.incomingCaps then
            self.caps = self.incomingCaps
            self.incomingCaps = nil
            self.capsKnown = true
            PBC:Refresh()
        end
    end
end
