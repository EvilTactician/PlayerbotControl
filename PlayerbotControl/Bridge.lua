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

-- Where the token and the three counts sit in each acknowledgement.
local ACKS = {
    FOLLOW_ORDER_ACK = { token = 1, counts = 2 },
    STAY_ORDER_ACK   = { token = 1, counts = 2 },
    ATTACK_ORDER_ACK = { token = 1, counts = 3 },
    FLEE_ORDER_ACK   = { token = 1, counts = 3 },
    GROUP_ACTION_ACK = { token = 1, counts = 3 },
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
-- callback(ok, reason, matched, succeeded, failed)
--   ok       true when at least one bot took the order
--   reason   the server's word for it: OK, PARTIAL, NO_GROUP, NO_BOTS, ...
--            or ours: NO_BRIDGE, CONNECTING, TIMEOUT
-------------------------------------------------------------------------------

local function run(build, callback)
    if Bridge.status ~= "ready" then
        local reason = (Bridge.status == "connecting") and "CONNECTING" or "NO_BRIDGE"
        Bridge:Hello()
        callback(false, reason, 0, 0, 0)
        return
    end

    local token = nextToken()
    pending[token] = callback
    send("RUN", build(token))

    PBC:After(ACK_TIMEOUT, function()
        local waiting = pending[token]
        if waiting then
            pending[token] = nil
            waiting(false, "TIMEOUT", 0, 0, 0)
        end
    end)
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

-- Changes strategies on the bots in your group.
--   state:   "C" (combat) or "N" (non-combat)
--   changes: such as "+passive" or "-passive"
function Bridge:GroupStrategy(state, changes, callback)
    run(function(token) return "STRATEGY~GROUP~~" .. token .. "~" .. state .. "~" .. changes end, callback)
end

-------------------------------------------------------------------------------
-- Incoming
-------------------------------------------------------------------------------

local function finish(token, reason, matched, succeeded, failed)
    local callback = pending[token]
    if not callback then
        return -- not ours (MultiBot shares the prefix) or already timed out
    end
    pending[token] = nil
    local ok = (reason == "OK") or (reason == "PARTIAL" and succeeded > 0)
    callback(ok, reason, matched, succeeded, failed)
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
        local token = fields[layout.token]
        if token and pending[token] then
            finish(token,
                decode(fields[layout.counts + 3] or "FAILED"),
                tonumber(fields[layout.counts]) or 0,
                tonumber(fields[layout.counts + 1]) or 0,
                tonumber(fields[layout.counts + 2]) or 0)
        end
    elseif opcode == "ERR" then
        -- opcode ~ request type ~ token ~ reason
        local fields = split(payload, "~")
        if fields[1] == "HELLO" then
            if self.status ~= "ready" then
                self.status = "incompatible"
                PBC:Refresh()
            end
        elseif fields[3] and pending[fields[3]] then
            finish(fields[3], decode(fields[4] or "FAILED"), 0, 0, 0)
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
