-- Playerbot Control: the groups and buttons on the bar, and what each one does.
--
-- An action is a table:
--   id        unique key, also used for the per-button on/off setting
--   group     id of the group it sits in
--   name      shown in the tooltip and the options
--   caps      bridge capabilities it needs; nil when it needs none
--   bridge    true when it can't work without mod-multibot-bridge
--   module    optional server module it belongs to; hidden unless it answered
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
    { id = "group",    name = "Group",    icon = ICONS .. "INV_Misc_GroupLooking" },
    { id = "upkeep",   name = "Upkeep",   icon = ICONS .. "Trade_BlackSmithing" },
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

-------------------------------------------------------------------------------
-- Helpers for the Group and Upkeep buttons
-------------------------------------------------------------------------------

-- One order to every bot in the group, one answer back.
--   after      runs when the order was taken
--   declined   what to say when the bots were asked but none acted, for
--              orders where that is a normal answer and not a fault
local function groupOrder(id, name, sendOrder, after, declined)
    if PBC.busy[id] or not needGroup(name) then
        return
    end
    setBusy(id, true)
    sendOrder(function(ok, reason, matched, succeeded)
        PBC.busy[id] = nil
        if ok and after then
            after()
        end
        if declined and not ok and reason == "FAILED" and matched > 0 then
            PBC:Print(name .. ": " .. declined)
        else
            report(name, ok, reason, matched, succeeded)
        end
        PBC:Refresh()
    end)
end

-- Everyone else in your party or raid who is online. The bridge works out
-- which of them are bots of yours and turns the rest down.
local function otherMembers()
    local names, me = {}, UnitName("player")
    local function addUnit(unit)
        local name = UnitName(unit)
        if name and name ~= me and name ~= UNKNOWN and UnitIsConnected(unit) then
            names[#names + 1] = name
        end
    end
    if PBC:InRaid() then
        for i = 1, GetNumRaidMembers() do
            addUnit("raid" .. i)
        end
    else
        for i = 1, GetNumPartyMembers() do
            addUnit("party" .. i)
        end
    end
    return names
end

local BOT_REASONS = {
    VENDOR_NOT_FOUND = "not standing next to a vendor",
    IN_COMBAT        = "in combat",
    DEAD             = "dead",
    LEVEL_TOO_LOW    = "below level 5",
    ALT_BOT_REFUSED  = "the server has autogear switched off for altbots (AiPlayerbot.AutoGearCommandAltBots)",
    COOLDOWN         = "autogeared a moment ago, try again shortly",
    FORBIDDEN        = "not yours to command",
    BOT_UNAVAILABLE  = "not available right now",
    NOT_IN_WORLD     = "not available right now",
    RATE_LIMIT       = "the server was busy, try again",
    TIMEOUT          = "no answer from the server",
    TARGET_CHANGED   = "changed while it was being prepared, try again",
    PLAN_EXPIRED     = "changed while it was being prepared, try again",
    PLAN_CHANGED     = "changed while it was being prepared, try again",
    EXECUTION_FAILED = "the server couldn't finish it",
}

-- Works through the group one bot at a time and waits for each answer, with
-- a pause in between where the server limits how fast it may be asked.
--   each(bot, done)   sends the order; done(ok, reason, number)
--   finish(result)    result.bots (succeeded), result.total (numbers summed),
--                     result.quiet (turned down for a reason in `quiet`)
--   reasons           wording for this job's own refusals
local function runBatch(id, name, interval, quiet, reasons, each, finish)
    local names = otherMembers()
    local result = { bots = 0, total = 0, quiet = 0 }
    local failed, failedOrder = {}, {}
    local index = 0

    local function step()
        index = index + 1
        local bot = names[index]
        if not bot then
            PBC.busy[id] = nil
            for _, reason in ipairs(failedOrder) do
                local why = (reasons and reasons[reason]) or BOT_REASONS[reason] or ("refused (" .. reason .. ")")
                PBC:Print(name .. ": " .. table.concat(failed[reason], ", ") .. ": " .. why .. ".")
            end
            if result.bots == 0 and result.quiet == 0 and #failedOrder == 0 then
                PBC:Print(name .. ": none of the others in your group are bots of yours.")
            else
                finish(result)
            end
            PBC:Refresh()
            return
        end

        PBC.busy[id] = #names - index + 1
        PBC:Refresh()

        each(bot, function(ok, reason, number)
            if ok then
                result.bots = result.bots + 1
                result.total = result.total + (number or 0)
            elseif reason == "NO_BRIDGE" or reason == "CONNECTING" then
                PBC.busy[id] = nil
                report(name, false, reason)
                PBC:Refresh()
                return
            elseif quiet and quiet[reason] then
                result.quiet = result.quiet + 1
            elseif reason ~= "NO_BOT" then
                if not failed[reason] then
                    failed[reason] = {}
                    failedOrder[#failedOrder + 1] = reason
                end
                table.insert(failed[reason], bot)
            end
            if interval > 0 and names[index + 1] then
                PBC:After(interval, step)
            else
                step()
            end
        end)
    end

    step()
end

local function batch(id, name, interval, quiet, reasons, each, finish)
    if PBC.busy[id] or not needGroup(name) then
        return
    end
    runBatch(id, name, interval, quiet, reasons, each, finish)
end

local function plural(count, word)
    return count .. " " .. word .. (count == 1 and "" or "s")
end

-------------------------------------------------------------------------------
-- Group
-------------------------------------------------------------------------------

add({
    id = "drink",
    group = "group",
    name = "Drink",
    caps = { "GROUP_ACTION_V1" },
    bridge = true,
    Visual = function()
        return ICONS .. "INV_Drink_07"
    end,
    Tooltip = function(tooltip)
        tooltip:AddLine("Bots that are short of mana sit down to drink.", 1, 1, 1, true)
        tooltip:AddLine("Not while they are mounted or in combat.", 0.7, 0.7, 0.7, true)
    end,
    Click = function()
        groupOrder("drink", "Drink", function(done) Bridge:GroupAction("DRINK", done) end, nil,
            "none of your bots needed a drink. They only drink when short of mana, and not while mounted or in combat.")
    end,
})

add({
    id = "release",
    group = "group",
    name = "Release",
    caps = { "GROUP_ACTION_V1" },
    bridge = true,
    Visual = function()
        return ICONS .. "INV_Misc_Bone_HumanSkull_01"
    end,
    Tooltip = function(tooltip)
        tooltip:AddLine("Dead bots release their spirit to the nearest graveyard.", 1, 1, 1, true)
    end,
    Click = function()
        groupOrder("release", "Release", function(done) Bridge:GroupAction("RELEASE", done) end)
    end,
})

add({
    id = "revive",
    group = "group",
    name = "Revive",
    caps = { "GROUP_ACTION_V1" },
    bridge = true,
    Visual = function()
        return ICONS .. "Spell_Holy_Resurrection"
    end,
    Tooltip = function(tooltip)
        tooltip:AddLine("Bots that released come back to life at the graveyard's spirit healer.", 1, 1, 1, true)
    end,
    Click = function()
        groupOrder("revive", "Revive", function(done) Bridge:GroupAction("REVIVE", done) end)
    end,
})

add({
    id = "roll",
    group = "group",
    name = "Roll",
    caps = { "GROUP_ROLL_V1" },
    bridge = true,
    Visual = function()
        return ICONS .. "INV_Misc_Dice_02"
    end,
    Tooltip = function(tooltip)
        tooltip:AddLine("Every bot in your group rolls 1-100.", 1, 1, 1, true)
    end,
    Click = function()
        groupOrder("roll", "Roll", function(done) Bridge:GroupRoll(done) end)
    end,
})

add({
    id = "reset",
    group = "group",
    name = "Reset",
    caps = { "BOT_RESET_V1" },
    bridge = true,
    Visual = function()
        return ICONS .. "Spell_Holy_DispelMagic"
    end,
    Tooltip = function(tooltip)
        tooltip:AddLine("For bots that are stuck.", 1, 1, 1, true)
        tooltip:AddLine("Left-click: they drop what they're doing and start over", 1, 1, 1)
        tooltip:AddLine("Shift-click: reset their AI to its default strategies (asks first)", 1, 1, 1)
    end,
    Click = function(mouseButton)
        if mouseButton ~= "LeftButton" then
            return
        end
        if not IsShiftKeyDown() then
            groupOrder("reset", "Reset", function(done) Bridge:GroupReset("ACTIONS", done) end)
            return
        end
        if PBC.busy.reset or not needGroup("Reset AI") then
            return
        end
        PBC:Confirm("Reset your bots' AI?\n\nEvery bot in your group goes back to its default strategies. Anything changed on them since, such as Stay, Passive or strategies you set yourself, is lost.",
            "Reset AI",
            function()
                groupOrder("reset", "Reset AI", function(done) Bridge:GroupReset("AI", done) end, function()
                    -- Their follow and passive settings are gone with it.
                    PBC.state.mode = nil
                    PBC.state.passive = nil
                end)
            end)
    end,
})

-------------------------------------------------------------------------------
-- Upkeep
-------------------------------------------------------------------------------

add({
    id = "maintenance",
    group = "upkeep",
    name = "Maintenance",
    caps = { "BOT_MAINTENANCE_V1" },
    bridge = true,
    Visual = function()
        return ICONS .. "Ability_Repair"
    end,
    Tooltip = function(tooltip)
        tooltip:AddLine("Playerbots' maintenance for every bot in your group: repairs, reagents, food, ammo, spells and the like.", 1, 1, 1, true)
        tooltip:AddLine("The server allows a few bots at a time, so a full group takes a little while. The number on the button counts down.", 0.7, 0.7, 0.7, true)
    end,
    Click = function()
        -- The bridge takes four of these per ten seconds.
        batch("maintenance", "Maintenance", 2.6, nil,
            { DISABLED = "the server has the maintenance command switched off (AiPlayerbot.MaintenanceCommand)" },
            function(bot, done)
                Bridge:Maintenance(bot, done)
            end,
            function(result)
                if PBC.db.confirm and result.bots > 0 then
                    PBC:Print("Maintenance: done for " .. plural(result.bots, "bot") .. ".")
                end
            end)
    end,
})

add({
    id = "autogear",
    group = "upkeep",
    name = "Autogear",
    caps = { "AUTOGEAR_OPTIONS_V1" },
    bridge = true,
    Visual = function()
        return ICONS .. "INV_Chest_Chain"
    end,
    Tooltip = function(tooltip)
        tooltip:AddLine("Gives every bot in your group new gear for its level from the server's item pool.", 1, 1, 1, true)
        tooltip:AddLine("Replaces what they wear. Asks first.", 1, 0.6, 0, true)
    end,
    Click = function()
        if PBC.busy.autogear or not needGroup("Autogear") then
            return
        end
        PBC:Confirm("Autogear every bot in your group?\n\nEach bot gets new gear for its level from the server's item pool, within the server's quality and item level limits. It replaces what they are wearing and can't be undone.",
            "Autogear",
            function()
                batch("autogear", "Autogear", 0.2, nil,
                    { DISABLED = "the server has autogear switched off (AiPlayerbot.AutoGearCommand)" },
                    function(bot, done)
                        Bridge:Autogear(bot, done)
                    end,
                    function(result)
                        if result.bots > 0 then
                            PBC:Print("Autogear: " .. plural(result.bots, "bot") .. ", " .. plural(result.total, "slot") .. " changed.")
                        end
                    end)
            end)
    end,
})

-- "Nothing to sell" comes back as a failure; it isn't one.
local NOTHING_TO_SELL = { FAILED = true, ITEM_NOT_FOUND = true }

local function sell(action, what)
    runBatch("sell", "Sell", 0.1, NOTHING_TO_SELL, nil,
        function(bot, done)
            Bridge:Sell(bot, action, done)
        end,
        function(result)
            if result.bots > 0 then
                PBC:Print("Sell: " .. plural(result.bots, "bot") .. " sold " .. plural(result.total, what) .. ".")
            elseif result.quiet > 0 then
                PBC:Print("Sell: nothing to sell.")
            end
        end)
end

add({
    id = "sell",
    group = "upkeep",
    name = "Sell",
    caps = { "INVENTORY_BULK_SELL_V1" },
    bridge = true,
    Visual = function()
        return ICONS .. "INV_Misc_Coin_02"
    end,
    Tooltip = function(tooltip)
        tooltip:AddLine("Each bot sells to a vendor it is standing next to.", 1, 1, 1, true)
        tooltip:AddLine("Left-click: grey items only", 1, 1, 1)
        tooltip:AddLine("Shift-click: everything they count as vendor trash, after equipping upgrades from their bags (asks first)", 1, 1, 1, true)
    end,
    Click = function(mouseButton)
        if mouseButton ~= "LeftButton" or PBC.busy.sell or not needGroup("Sell") then
            return
        end
        if not IsShiftKeyDown() then
            sell("SELL_GREY", "grey item")
            return
        end
        PBC:Confirm("Sell everything your bots count as vendor trash?\n\nThey first equip any upgrades from their bags. Then each bot next to a vendor sells what Playerbots sees no use for. That includes soulbound gear a bot can't wear yet because its level is too low, even if it would be an upgrade later.",
            "Sell",
            function()
                if PBC.busy.sell or not needGroup("Sell") then
                    return
                end
                -- The one order that has to go through chat: the bridge has
                -- no way to ask for it.
                SendChatMessage("equip upgrade", PBC:InRaid() and "RAID" or "PARTY")
                setBusy("sell", true)
                PBC:After(3, function()
                    sell("SELL_VENDOR", "item")
                end)
            end)
    end,
})

add({
    id = "levelsync",
    group = "upkeep",
    name = "Level sync",
    module = "levelsync",
    Visual = function()
        return ICONS .. "Achievement_Level_80"
    end,
    Tooltip = function(tooltip)
        tooltip:AddLine("Runs mod-levelsync's level sync for your sync group (.levelsync level on).", 1, 1, 1, true)
    end,
    Click = function()
        PBC:Command(".levelsync level on")
    end,
})

add({
    id = "tokens",
    group = "upkeep",
    name = "Raid tokens",
    module = "tokenturnin",
    Visual = function()
        return ICONS .. "INV_Jewelry_Talisman_07"
    end,
    Tooltip = function(tooltip)
        tooltip:AddLine("mod-token-turnin: turns raid tokens into the matching item for each character.", 1, 1, 1, true)
        tooltip:AddLine("Left-click: check what would be redeemed, changing nothing", 1, 1, 1, true)
        tooltip:AddLine("Shift-click: redeem (asks first)", 1, 1, 1)
    end,
    Click = function(mouseButton)
        if mouseButton ~= "LeftButton" then
            return
        end
        if not IsShiftKeyDown() then
            PBC:Command(".tokenturnin check")
            return
        end
        PBC:Confirm("Redeem raid tokens?\n\nEvery token the check lists is turned into its item for that character. This can't be undone. Left-click the button first to see what would happen.",
            "Redeem",
            function()
                PBC:Command(".tokenturnin redeem")
            end)
    end,
})
