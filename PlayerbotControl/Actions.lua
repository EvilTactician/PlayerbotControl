-- Playerbot Control: the groups and buttons on the bar, and what each one does.
--
-- An action is a table:
--   id        unique key, also used for the per-button on/off setting
--   group     id of the group it sits in
--   name      shown in the tooltip and the options
--   caps      bridge capabilities it needs; nil when it needs none
--   bridge    true when it can't work without mod-multibot-bridge
--   Visual()  returns icon, r, g, b, corner text (colour and text may be nil)
--   Tooltip(tooltip)  adds its lines under the name
--   Click(mouseButton)
--
-- A group may name one action as its "primary". That one sits on the bar
-- itself: left-click uses it, right-click opens the rest of the group.

local PBC = PlayerbotControl
local Bridge = PBC.Bridge

local ICONS = "Interface\\Icons\\"

local SKULL = 8
local MOON = 5

PBC.groups = {
    { id = "movement", name = "Movement", icon = ICONS .. "Ability_Rogue_FleetFooted",   primary = "followstay" },
    { id = "combat",   name = "Combat",   icon = ICONS .. "Ability_Warrior_BattleShout", primary = "passive" },
}

PBC.actions = {}
PBC.actionById = {}
PBC.busy = {}

local function add(action)
    PBC.actions[#PBC.actions + 1] = action
    PBC.actionById[action.id] = action
end

-------------------------------------------------------------------------------
-- Reporting. Failures always get a line in chat; successes only when the
-- "confirm in chat" option is on, because the button itself shows the result.
-------------------------------------------------------------------------------

local REASONS = {
    NO_GROUP   = "you're not in a group.",
    NO_BOTS    = "none of the bots in your group are yours to command.",
    NO_MATCH   = "none of the bots in your group are yours to command.",
    NO_TARGET  = "you have no target.",
    RATE_LIMIT = "too many orders at once. Try again in a moment.",
    FAILED     = "the bots didn't take the order.",
    BOT_LIMIT  = "there are too many bots for one order.",
    REPLAY     = "the server saw that order twice. Try again.",
    TIMEOUT    = "the server didn't answer.",
    CONNECTING = "still connecting to mod-multibot-bridge. Try again in a moment.",
    NO_BRIDGE  = "mod-multibot-bridge didn't answer. Is it installed on the server?",
}

local function report(name, ok, reason, matched, succeeded)
    if ok then
        if reason == "PARTIAL" then
            PBC:Print(name .. ": only " .. succeeded .. " of " .. matched .. " bots took the order.")
        elseif PBC.db.confirm then
            PBC:Print(name .. ": " .. succeeded .. (succeeded == 1 and " bot." or " bots."))
        end
    else
        PBC:Print(name .. ": " .. (REASONS[reason] or ("refused (" .. tostring(reason) .. ").")))
    end
end

local function setBusy(id, busy)
    PBC.busy[id] = busy or nil
    PBC:Refresh()
end

-- Checks shared by every order that goes to the bots in your group.
local function needGroup(name)
    if not PBC:InGroup() then
        report(name, false, "NO_GROUP")
        return false
    end
    return true
end

local function hostileTarget()
    return UnitExists("target") and UnitCanAttack("player", "target") and not UnitIsDead("target")
end

-- Puts a marker on your target unless it already has that one (setting the
-- same marker twice would take it off again).
local function mark(index)
    if GetRaidTargetIndex("target") ~= index then
        SetRaidTarget("target", index)
    end
end

-------------------------------------------------------------------------------
-- Passive
--
-- Playerbots keeps separate strategy lists for in and out of combat, so
-- passive goes on (or off) both, one after the other.
-------------------------------------------------------------------------------

local function sendPassive(on, callback)
    local change = (on and "+" or "-") .. "passive"
    local first

    -- Both go out together; report once, with the worse of the two results.
    local function done(ok, reason, matched, succeeded, failed)
        if not first then
            first = { ok, reason, matched, succeeded, failed }
        elseif not first[1] then
            callback(unpack(first))
        else
            callback(ok, reason, matched, succeeded, failed)
        end
    end

    Bridge:GroupStrategy("C", change, done)
    Bridge:GroupStrategy("N", change, done)
end

-------------------------------------------------------------------------------
-- Movement
-------------------------------------------------------------------------------

-- Playerbots clears passive on every Follow or Stay order. When the Passive
-- button is on, put it straight back so the button keeps telling the truth.
-- It is sent right behind the order, without waiting for the answer, so the
-- bots get no moment in between to start a fight.
local function restorePassive()
    if PBC.state.passive and Bridge:IsReady() then
        sendPassive(true, function(ok, reason)
            -- No bots to hear it is the order's own failure, reported there.
            if not ok and reason ~= "NO_MATCH" and reason ~= "NO_BOTS" and reason ~= "NO_GROUP" then
                PBC.state.passive = nil
                report("Passive", ok, reason, 0, 0)
            end
            PBC:Refresh()
        end)
    end
end

local function order(id, name, mode)
    if PBC.busy[id] or not needGroup(name) then
        return
    end
    setBusy(id, true)
    local function done(ok, reason, matched, succeeded)
        PBC.busy[id] = nil
        if ok then
            PBC.state.mode = mode
        end
        report(name, ok, reason, matched, succeeded)
        PBC:Refresh()
    end
    if mode == "follow" then
        Bridge:FollowOrder(done)
    else
        Bridge:StayOrder(done)
    end
    restorePassive()
end

add({
    id = "followstay",
    group = "movement",
    name = "Follow / Stay",
    caps = { "FOLLOW_ORDER_V1", "STAY_ORDER_V1" },
    bridge = true,
    Visual = function()
        local mode = PBC.state.mode
        if mode == "follow" then
            return ICONS .. "Ability_Hunter_Pathfinding", 0.2, 1, 0.2
        elseif mode == "stay" then
            return ICONS .. "Spell_Nature_TimeStop", 1, 0.6, 0
        elseif mode == "flee" then
            return ICONS .. "Ability_Rogue_Sprint", 1, 0.2, 0.2
        end
        return ICONS .. "Ability_Hunter_Pathfinding", nil, nil, nil, "?"
    end,
    Tooltip = function(tooltip)
        local mode = PBC.state.mode
        if mode == "follow" then
            tooltip:AddLine("Your bots are following you.", 0.2, 1, 0.2)
            tooltip:AddLine("Left-click: Stay", 1, 1, 1)
            tooltip:AddLine("Shift-click: repeat Follow, for bots that just joined", 1, 1, 1)
        elseif mode == "stay" then
            tooltip:AddLine("Your bots are staying where they are.", 1, 0.6, 0)
            tooltip:AddLine("Left-click: Follow", 1, 1, 1)
            tooltip:AddLine("Shift-click: repeat Stay, for bots that just joined", 1, 1, 1)
        elseif mode == "flee" then
            tooltip:AddLine("Your bots are fleeing to you.", 1, 0.2, 0.2)
            tooltip:AddLine("Left-click: Follow, and fight again", 1, 1, 1)
        else
            tooltip:AddLine("No order given yet this session.", 0.7, 0.7, 0.7)
            tooltip:AddLine("Left-click: Follow", 1, 1, 1)
        end
    end,
    Click = function(mouseButton)
        if mouseButton ~= "LeftButton" then
            return
        end
        local mode = PBC.state.mode
        if IsShiftKeyDown() then
            if mode == "stay" then
                order("followstay", "Stay", "stay")
            else
                order("followstay", "Follow", "follow")
            end
        elseif mode == "follow" then
            order("followstay", "Stay", "stay")
        else
            order("followstay", "Follow", "follow")
        end
    end,
})

add({
    id = "flee",
    group = "movement",
    name = "Flee",
    caps = { "FLEE_ORDER_V1" },
    bridge = true,
    Visual = function()
        return ICONS .. "Ability_Rogue_Sprint"
    end,
    Tooltip = function(tooltip)
        tooltip:AddLine("Your bots run to you and ignore enemies until you order Follow or Stay.", 1, 1, 1, true)
    end,
    Click = function()
        if PBC.busy.flee or not needGroup("Flee") then
            return
        end
        setBusy("flee", true)
        Bridge:FleeOrder(function(ok, reason, matched, succeeded)
            PBC.busy.flee = nil
            if ok then
                PBC.state.mode = "flee"
            end
            report("Flee", ok, reason, matched, succeeded)
            PBC:Refresh()
        end)
    end,
})

add({
    id = "summon",
    group = "movement",
    name = "Summon",
    caps = { "GROUP_ACTION_V1" },
    bridge = true,
    Visual = function()
        return ICONS .. "Spell_Shadow_Twilight"
    end,
    Tooltip = function(tooltip)
        tooltip:AddLine("Brings the bots in your group to you.", 1, 1, 1, true)
    end,
    Click = function()
        if PBC.busy.summon or not needGroup("Summon") then
            return
        end
        setBusy("summon", true)
        Bridge:GroupAction("SUMMON", function(ok, reason, matched, succeeded)
            PBC.busy.summon = nil
            report("Summon", ok, reason, matched, succeeded)
            PBC:Refresh()
        end)
    end,
})

-------------------------------------------------------------------------------
-- Combat
-------------------------------------------------------------------------------

local function setPassive(on)
    local name = on and "Passive" or "Active"
    if PBC.busy.passive or not needGroup(name) then
        return
    end
    setBusy("passive", true)
    sendPassive(on, function(ok, reason, matched, succeeded)
        PBC.busy.passive = nil
        if ok then
            PBC.state.passive = on
        end
        report(name, ok, reason, matched, succeeded)
        PBC:Refresh()
    end)
end

add({
    id = "passive",
    group = "combat",
    name = "Passive / Active",
    caps = { "STRATEGY_MUTATION_V1" },
    bridge = true,
    Visual = function()
        local passive = PBC.state.passive
        if passive == true then
            return ICONS .. "Spell_Nature_Sleep", 0.3, 0.6, 1
        elseif passive == false then
            return ICONS .. "Ability_Warrior_OffensiveStance", 1, 0.25, 0.2
        end
        return ICONS .. "Ability_Warrior_OffensiveStance", nil, nil, nil, "?"
    end,
    Tooltip = function(tooltip)
        local passive = PBC.state.passive
        if passive == true then
            tooltip:AddLine("Your bots are passive: they won't fight.", 0.3, 0.6, 1)
            tooltip:AddLine("Left-click: Active", 1, 1, 1)
            tooltip:AddLine("Shift-click: repeat Passive, for bots that just joined", 1, 1, 1)
        elseif passive == false then
            tooltip:AddLine("Your bots are active: they fight.", 1, 0.25, 0.2)
            tooltip:AddLine("Left-click: Passive", 1, 1, 1)
            tooltip:AddLine("Shift-click: repeat Active, for bots that just joined", 1, 1, 1)
        else
            tooltip:AddLine("Not set yet this session. Bots are active unless told otherwise.", 0.7, 0.7, 0.7, true)
            tooltip:AddLine("Left-click: Passive", 1, 1, 1)
            tooltip:AddLine("Shift-click: Active", 1, 1, 1)
        end
    end,
    Click = function(mouseButton)
        if mouseButton ~= "LeftButton" then
            return
        end
        local passive = PBC.state.passive and true or false
        if IsShiftKeyDown() then
            setPassive(passive)
        else
            setPassive(not passive)
        end
    end,
})

add({
    id = "attack",
    group = "combat",
    name = "Attack my target",
    caps = { "ATTACK_ORDER_V1" },
    bridge = true,
    Visual = function()
        return ICONS .. "Ability_DualWield"
    end,
    Tooltip = function(tooltip)
        tooltip:AddLine("Your bots attack what you have targeted.", 1, 1, 1, true)
        if PBC.db.skull then
            tooltip:AddLine("Also puts the Skull marker on it.", 0.7, 0.7, 0.7, true)
        end
        if PBC.state.passive then
            tooltip:AddLine("Your bots are passive, so they won't fight until you set them Active.", 1, 0.6, 0, true)
        end
    end,
    Click = function()
        if PBC.busy.attack or not needGroup("Attack") then
            return
        end
        if not hostileTarget() then
            PBC:Print("Attack: target an enemy first.")
            return
        end
        if PBC.db.skull and PBC:CanMark() then
            mark(SKULL)
        end
        setBusy("attack", true)
        Bridge:AttackOrder(function(ok, reason, matched, succeeded)
            PBC.busy.attack = nil
            if not ok and reason == "FAILED" and matched > 0 then
                -- A bot that is already on this target counts as a refusal on
                -- the server, so mid-fight this is the normal answer.
                if not UnitAffectingCombat("target") then
                    PBC:Print("Attack: your bots couldn't attack that target. It may be out of their sight.")
                end
                PBC:Refresh()
                return
            end
            report("Attack", ok, reason, matched, succeeded)
            PBC:Refresh()
        end)
    end,
})

-- Bots with a crowd control spell use it on whatever carries the Moon marker
-- (Playerbots' default "rti cc"), so marking the target is the whole order.
add({
    id = "cc",
    group = "combat",
    name = "CC my target",
    Visual = function()
        return ICONS .. "Spell_Nature_Polymorph"
    end,
    Tooltip = function(tooltip)
        tooltip:AddLine("Puts the Moon marker on your target. Bots that can crowd control keep it controlled.", 1, 1, 1, true)
        tooltip:AddLine("Right-click: take the Moon marker off your target", 1, 1, 1)
        tooltip:AddLine("In a raid you need to be leader or assistant.", 0.7, 0.7, 0.7, true)
    end,
    Click = function(mouseButton)
        if not PBC:InGroup() then
            report("CC", false, "NO_GROUP")
            return
        end
        if not PBC:CanMark() then
            PBC:Print("CC: only the raid leader and assistants can set markers.")
            return
        end
        if mouseButton == "RightButton" then
            if UnitExists("target") and GetRaidTargetIndex("target") == MOON then
                SetRaidTarget("target", 0)
            end
            return
        end
        if not hostileTarget() then
            PBC:Print("CC: target an enemy first.")
            return
        end
        mark(MOON)
        if PBC.db.confirm then
            PBC:Print("CC: Moon marker set on " .. (UnitName("target") or "your target") .. ".")
        end
    end,
})
