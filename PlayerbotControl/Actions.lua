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
    { id = "group",    name = "Group Actions", icon = ICONS .. "INV_Misc_GroupLooking" },
    { id = "upkeep",   name = "Upkeep",   icon = ICONS .. "Trade_BlackSmithing" },
    { id = "party",    name = "Party",    icon = ICONS .. "Spell_Holy_PrayerofSpirit" },
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
--   list              names to work through; the rest of your group when nil
local function runBatch(id, name, interval, quiet, reasons, each, finish, list)
    local names = list or otherMembers()
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
            if not list and result.bots == 0 and result.quiet == 0 and #failedOrder == 0 then
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
        tooltip:AddLine("Left-click: dead bots release their spirit to the nearest graveyard.", 1, 1, 1, true)
        tooltip:AddLine("Shift-click: revive. Bots that released come back to life at the spirit healer.", 1, 1, 1, true)
    end,
    Click = function(mouseButton)
        if mouseButton ~= "LeftButton" then
            return
        end
        if IsShiftKeyDown() then
            groupOrder("release", "Revive", function(done) Bridge:GroupAction("REVIVE", done) end)
        else
            groupOrder("release", "Release", function(done) Bridge:GroupAction("RELEASE", done) end)
        end
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

local function autogearAll()
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
end

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
        tooltip:AddLine("Left-click: Playerbots' maintenance for every bot in your group: repairs, reagents, food, ammo, spells and the like.", 1, 1, 1, true)
        if not PBC.db.separateAutogear then
            tooltip:AddLine("Shift-click: autogear. Every bot in your group gets new gear for its level from the server's item pool, replacing what it wears. Asks first.", 1, 1, 1, true)
        end
        tooltip:AddLine("The server allows a few bots at a time, so a full group takes a little while. The number on the button counts down.", 0.7, 0.7, 0.7, true)
    end,
    Click = function(mouseButton)
        if mouseButton ~= "LeftButton" then
            return
        end
        if IsShiftKeyDown() then
            if not PBC.db.separateAutogear then
                autogearAll()
            end
            return
        end
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

-- Only shown with "Separate Autogear button" on; otherwise it is Shift-click
-- on Maintenance.
add({
    id = "autogear",
    group = "upkeep",
    name = "Autogear",
    setting = "separateAutogear",
    optionLabel = "Separate Autogear button",
    optionTip = "Autogear as its own button. Off: it's Shift-click on Maintenance instead.",
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
        autogearAll()
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
        tooltip:AddLine("Right-click: open your targeted bot's bags and pick what it sells, with buyback", 1, 1, 1, true)
    end,
    Click = function(mouseButton)
        if mouseButton == "RightButton" then
            PBC.BagWindow:OpenFor("sell")
            return
        end
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
    id = "trade",
    group = "upkeep",
    name = "Trade",
    caps = { "INVENTORY_EXACT_V1", "ITEM_TRADE_V1" },
    bridge = true,
    Visual = function()
        return ICONS .. "INV_Misc_Bag_10"
    end,
    Tooltip = function(tooltip)
        tooltip:AddLine("Opens a trade with your targeted bot and shows its bags. Click an item and the bot puts it in the trade window; accept as usual.", 1, 1, 1, true)
        tooltip:AddLine("The bot has to be close enough to trade with.", 0.7, 0.7, 0.7, true)
    end,
    Click = function()
        PBC.BagWindow:OpenFor("trade")
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
        PBC:ModuleCommand("levelsync", "Level sync", ".levelsync level on")
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
            PBC:ModuleCommand("tokenturnin", "Raid tokens", ".tokenturnin check")
            return
        end
        PBC:Confirm("Redeem raid tokens?\n\nEvery token the check lists is turned into its item for that character. This can't be undone. Left-click the button first to see what would happen.",
            "Redeem",
            function()
                PBC:ModuleCommand("tokenturnin", "Raid tokens", ".tokenturnin redeem")
            end)
    end,
})

-------------------------------------------------------------------------------
-- Party
--
-- Altbots are your own characters played as bots. The bridge can't tell them
-- from random bots, so the names come from two lists in the options:
--   Altbots       Park and Logout act on these, when they are in your group
--   Quick group   two short lists that Quick group logs in and invites
-------------------------------------------------------------------------------

local function isLeader()
    if PBC:InRaid() then
        return IsRaidLeader() and true or false
    end
    return (not PBC:InGroup()) or (IsPartyLeader() and true or false)
end

-- [lower-case name] = name as the game shows it, for everyone in your group.
local function groupNames()
    local names = {}
    for _, name in ipairs(otherMembers()) do
        names[string.lower(name)] = name
    end
    return names
end

-- The names from a list that are in your group right now.
local function listedInGroup(list)
    local inGroup, found = groupNames(), {}
    for _, name in ipairs(list) do
        local member = inGroup[string.lower(name)]
        if member then
            found[#found + 1] = member
        end
    end
    return found
end

local function noNames(name, listName)
    PBC:Print(name .. ": your " .. listName .. " list is empty. Add names under Interface > AddOns > Playerbot Control > Altbots.")
end

local LIFECYCLE_REASONS = {
    NOT_ALLOWED      = "not one of your characters, or the name is misspelt",
    IN_USE           = "being played by someone",
    MAX_BOTS         = "you're at the server's bot limit (AiPlayerbot.MaxAddedBots)",
    TOO_MANY_PENDING = "too many logging in at once, try again",
    NOT_LEADER       = "only the group leader can invite",
    INVITE_FAILED    = "couldn't be invited",
    STUCK            = "stuck in another group. A game master can free it with .group disband and the bot's name",
}

-- Invites a player and listens for the game's answer.
--   done("ok")    invited
--   done("busy")  "<name> is already in a group." (that line is hidden)
local INVITE_WAIT = 1.5

local function inviteAndCheck(name, done)
    local busyText = string.format(ERR_ALREADY_IN_GROUP_S or "%s is already in a group.", name)
    local sentText = string.format(ERR_INVITE_PLAYER_S or "You have invited %s to join your group.", name)
    local result

    local function filter(self, event, msg)
        if msg == busyText then
            result = result or "busy"
            return true
        end
        if msg == sentText then
            result = result or "ok"
        end
        return false
    end

    ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", filter)
    InviteUnit(name)

    local started = GetTime()
    local function check()
        if not result and (GetTime() - started) < INVITE_WAIT then
            PBC:After(0.2, check)
            return
        end
        ChatFrame_RemoveMessageEventFilter("CHAT_MSG_SYSTEM", filter)
        -- No answer either way: the invite most likely went out.
        done(result or "ok")
    end
    PBC:After(0.2, check)
end

-- Takes a bot out of the group it is stuck in, for game masters only:
-- ".group remove <name>". done(true) when the server took the command.
local function freeFromGroup(name, done)
    local command = ".group remove " .. name
    local refused = false

    local function systemFilter(self, event, msg)
        if type(msg) == "string" and string.find(msg, "does not exist", 1, true) and string.find(msg, "group remove", 1, true) then
            refused = true
            return true
        end
        return false
    end
    -- A server that won't run the command for you hands it back as a whisper.
    local function whisperFilter(self, event, msg)
        if msg == command then
            refused = true
            return true
        end
        return false
    end

    ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", systemFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_WHISPER", whisperFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_WHISPER_INFORM", whisperFilter)
    PBC:Command(command)

    PBC:After(1, function()
        ChatFrame_RemoveMessageEventFilter("CHAT_MSG_SYSTEM", systemFilter)
        ChatFrame_RemoveMessageEventFilter("CHAT_MSG_WHISPER", whisperFilter)
        ChatFrame_RemoveMessageEventFilter("CHAT_MSG_WHISPER_INFORM", whisperFilter)
        done(not refused)
    end)
end

-- Logs in and invites the bots on one of the Quick group lists.
local function quickGroup(listKey, label)
    if PBC.busy.quickgroup then
        return
    end
    local list = PBC.chardb[listKey]
    if #list == 0 then
        noNames(label, label)
        return
    end

    local inGroup = groupNames()
    local wanted = {}
    for _, name in ipairs(list) do
        if not inGroup[string.lower(name)] then
            wanted[#wanted + 1] = name
        end
    end
    if #wanted == 0 then
        PBC:Print(label .. ": everyone on the list is already in your group.")
        return
    end

    local invited, loggingIn = {}, {}

    -- Bots asked to join that haven't arrived yet.
    local function onTheirWay()
        local members, count = groupNames(), 0
        for _, names in ipairs({ invited, loggingIn }) do
            for _, name in ipairs(names) do
                if not members[string.lower(name)] then
                    count = count + 1
                end
            end
        end
        return count
    end

    runBatch("quickgroup", label, 0.1, nil, LIFECYCLE_REASONS,
        function(bot, done)
            Bridge:Resolve(bot, function(ok, reason, guid, state, name)
                if not ok then
                    done(false, reason)
                    return
                end
                name = (name ~= "" and name) or bot
                if state == "ONLINE" then
                    -- Online but not with you, such as a parked bot.
                    if not isLeader() then
                        done(false, "NOT_LEADER")
                        return
                    end
                    -- A party holds five; a sixth needs a raid.
                    if PBC:InGroup() and not PBC:InRaid()
                        and (GetNumPartyMembers() + onTheirWay()) >= 4 then
                        ConvertToRaid()
                    end
                    -- A bot can be stuck in a group without you. A game master
                    -- can free it; then it is invited again.
                    inviteAndCheck(name, function(result)
                        if result == "ok" then
                            invited[#invited + 1] = name
                            done(true, "OK", 0)
                            return
                        end
                        freeFromGroup(name, function(freed)
                            if not freed then
                                done(false, "STUCK")
                                return
                            end
                            inviteAndCheck(name, function(again)
                                if again == "ok" then
                                    invited[#invited + 1] = name .. " (freed from another group)"
                                    done(true, "OK", 0)
                                else
                                    done(false, "STUCK")
                                end
                            end)
                        end)
                    end)
                elseif state == "CONNECTING" then
                    loggingIn[#loggingIn + 1] = name
                    done(true, "OK", 0)
                elseif reason == "IN_USE" then
                    done(false, "IN_USE")
                else
                    Bridge:Login(guid, function(ok2, reason2)
                        if ok2 then
                            loggingIn[#loggingIn + 1] = name
                        end
                        done(ok2, reason2, 0)
                    end)
                end
            end)
        end,
        function()
            local parts = {}
            if #loggingIn > 0 then
                parts[#parts + 1] = "logging in " .. table.concat(loggingIn, ", ")
            end
            if #invited > 0 then
                parts[#parts + 1] = "inviting " .. table.concat(invited, ", ")
            end
            if #parts > 0 then
                PBC:Print(label .. ": " .. table.concat(parts, "; ") .. ".")
            end
        end,
        wanted)
end

local function listLine(tooltip, label, list)
    if #list > 0 then
        tooltip:AddLine(label .. ": " .. table.concat(list, ", "), 0.7, 0.7, 0.7, true)
    else
        tooltip:AddLine(label .. ": empty. Add names in the options under Altbots.", 1, 0.6, 0, true)
    end
end

add({
    id = "quickgroup",
    group = "party",
    name = "Quick group",
    caps = { "BOT_TARGET_RESOLVE_V1", "BOT_LIFECYCLE_V1" },
    bridge = true,
    Visual = function()
        return ICONS .. "INV_Misc_GroupNeedMore"
    end,
    Tooltip = function(tooltip)
        tooltip:AddLine("Logs in the bots on a Quick group list and invites the ones already online.", 1, 1, 1, true)
        tooltip:AddLine("Left-click: Quick group 1", 1, 1, 1)
        tooltip:AddLine("Right-click: Quick group 2", 1, 1, 1)
        listLine(tooltip, "Quick group 1", PBC.chardb.quickgroup)
        listLine(tooltip, "Quick group 2", PBC.chardb.quickgroup2)
    end,
    Click = function(mouseButton)
        if mouseButton == "RightButton" then
            quickGroup("quickgroup2", "Quick group 2")
        else
            quickGroup("quickgroup", "Quick group 1")
        end
    end,
})

-- Seconds after removing parked altbots before their Stay is put back on.
local PARK_RECHECK = 2.5

add({
    id = "park",
    group = "party",
    name = "Park altbots",
    caps = { "STAY_ORDER_V1", "FOLLOW_ORDER_V1" },
    bridge = true,
    Visual = function()
        return ICONS .. "INV_Misc_Rune_01"
    end,
    Tooltip = function(tooltip)
        tooltip:AddLine("Your altbots in this group stay where they are now and leave the group. They stay online.", 1, 1, 1, true)
        tooltip:AddLine("Random bots and players aren't affected: they keep following, or staying, as before.", 0.7, 0.7, 0.7, true)
        tooltip:AddLine("Invite them, or use Quick group, to have them join you again.", 0.7, 0.7, 0.7, true)
    end,
    Click = function()
        if PBC.busy.park then
            return
        end
        if #PBC.chardb.altbots == 0 then
            noNames("Park altbots", "Altbots")
            return
        end
        if not needGroup("Park altbots") then
            return
        end
        local names = listedInGroup(PBC.chardb.altbots)
        if #names == 0 then
            PBC:Print("Park altbots: none of your altbots are in your group.")
            return
        end
        if not isLeader() then
            PBC:Print("Park altbots: only the group leader can remove them from the group.")
            return
        end

        if not Bridge:IsReady() then
            report("Park altbots", false, Bridge.status == "connecting" and "CONNECTING" or "NO_BRIDGE")
            Bridge:Hello()
            return
        end

        -- There is no Stay for a single bot, so everyone is told to stay, the
        -- altbots leave, and the rest are given back what they were doing.
        -- The game only lets an addon remove group members straight from a
        -- click, so they're removed now, right behind the Stay order. The
        -- server handles the two in the order they were sent.
        local previous = PBC.state.mode
        setBusy("park", true)
        Bridge:StayOrder(function(ok, reason, matched, succeeded)
            if not ok then
                PBC.busy.park = nil
                report("Park altbots", ok, reason, matched, succeeded)
                PBC:Refresh()
                return
            end
            if reason == "PARTIAL" then
                PBC:Print("Park altbots: only " .. succeeded .. " of " .. matched .. " bots took the Stay order, so a parked altbot may keep following you.")
            end
            PBC:After(1.5, function()
                PBC.busy.park = nil
                PBC:Print("Park altbots: " .. table.concat(names, ", ") .. " parked.")
                if not PBC:InGroup() then
                    PBC:Refresh()
                    return
                end
                if previous == "stay" then
                    PBC.state.mode = "stay"
                    restorePassive()
                    PBC:Refresh()
                    return
                end
                Bridge:FollowOrder(function(ok2, reason2, matched2, succeeded2)
                    if ok2 then
                        PBC.state.mode = "follow"
                    elseif reason2 ~= "NO_BOTS" and reason2 ~= "NO_MATCH" and reason2 ~= "NO_GROUP" then
                        report("Follow", ok2, reason2, matched2, succeeded2)
                    end
                    PBC:Refresh()
                end)
                restorePassive()
            end)
        end)
        for _, name in ipairs(names) do
            UninviteUnit(name)
        end

        -- A bot that finds itself alone after leaving can reset its AI to the
        -- defaults, Follow included. Once that has had time to happen, Stay
        -- goes back on each parked altbot by name.
        local function stayOn(name, state, done)
            Bridge:BotStrategy(name, state, "+stay,-follow", done)
        end
        local failed = {}
        for index, name in ipairs(names) do
            PBC:After(PARK_RECHECK + (index - 1) * 0.3, function()
                stayOn(name, "N", function(ok, reason)
                    if not ok then
                        failed[#failed + 1] = name .. " (" .. tostring(reason) .. ")"
                    else
                        stayOn(name, "C", function() end)
                    end
                    if index == #names and #failed > 0 then
                        PBC:Print("Park altbots: couldn't make sure these stay put: " .. table.concat(failed, ", ") .. ".")
                    end
                end)
            end)
        end
    end,
})

-- Right-click on Logout altbots: every bot of yours that is online. The
-- bridge lists the bots you can see (yours, and random bots in your group);
-- each is looked up, and only those logged in under your control are logged
-- out. Random bots come back as "not allowed" and are skipped quietly.
local function logoutEveryBot()
    if not Bridge:IsReady() then
        report("Logout altbots", false, Bridge.status == "connecting" and "CONNECTING" or "NO_BRIDGE")
        Bridge:Hello()
        return
    end
    setBusy("logout", true)
    Bridge:Roster(function(bots)
        local names = {}
        local me = string.lower(UnitName("player") or "")
        for key, botName in pairs(bots or {}) do
            if key ~= me then
                names[#names + 1] = botName
            end
        end
        if #names == 0 then
            PBC.busy.logout = nil
            PBC:Print("Logout altbots: you have no bots online.")
            PBC:Refresh()
            return
        end

        local online, left = {}, #names
        for _, key in ipairs(names) do
            Bridge:Resolve(key, function(ok, reason, guid, state, name)
                if ok and state == "ONLINE" then
                    online[#online + 1] = { name = (name ~= "" and name) or key, guid = guid }
                end
                left = left - 1
                if left > 0 then
                    return
                end
                PBC.busy.logout = nil
                PBC:Refresh()
                if #online == 0 then
                    PBC:Print("Logout altbots: you have no bots of your own online.")
                    return
                end
                table.sort(online, function(a, b) return a.name < b.name end)
                local list = {}
                for _, bot in ipairs(online) do
                    list[#list + 1] = bot.name
                end
                PBC:Confirm("Log out all your bots?\n\n" .. table.concat(list, ", ") .. " will log out, wherever they are. Bots in your group leave it first.",
                    "Log out",
                    function()
                        local inGroup = groupNames()
                        runBatch("logout", "Logout altbots", 0.1, { BOT_NOT_ONLINE = true }, {
                                FORBIDDEN        = "only the group leader can remove them from your group",
                                TARGET_IS_LEADER = "is the group leader, so can't be removed",
                            },
                            function(botName, done)
                                for _, bot in ipairs(online) do
                                    if bot.name == botName then
                                        if inGroup[string.lower(botName)] then
                                            Bridge:LogoutFromGroup(bot.guid, done)
                                        else
                                            Bridge:Logout(bot.guid, done)
                                        end
                                        return
                                    end
                                end
                                done(false, "NO_BOT")
                            end,
                            function(result)
                                if result.bots > 0 then
                                    PBC:Print("Logout altbots: " .. plural(result.bots, "bot") .. " logged out.")
                                end
                            end,
                            list)
                    end)
            end)
        end
    end)
end

add({
    id = "logout",
    group = "party",
    name = "Logout altbots",
    caps = { "BOT_TARGET_RESOLVE_V1", "BOT_LIFECYCLE_V1" },
    bridge = true,
    Visual = function()
        return ICONS .. "Ability_Vanish"
    end,
    Tooltip = function(tooltip)
        tooltip:AddLine("Left-click: your listed altbots in this group leave the group and log out. Random bots, players and parked altbots aren't affected.", 1, 1, 1, true)
        tooltip:AddLine("Right-click: log out every bot of yours that is online, wherever it is: grouped, parked or stuck. Random bots aren't affected.", 1, 1, 1, true)
        tooltip:AddLine("Both ask first.", 0.7, 0.7, 0.7, true)
    end,
    Click = function(mouseButton)
        if PBC.busy.logout then
            return
        end
        if mouseButton == "RightButton" then
            logoutEveryBot()
            return
        end
        if #PBC.chardb.altbots == 0 then
            noNames("Logout altbots", "Altbots")
            return
        end
        if not needGroup("Logout altbots") then
            return
        end
        local names = listedInGroup(PBC.chardb.altbots)
        if #names == 0 then
            PBC:Print("Logout altbots: none of your altbots are in your group.")
            return
        end
        PBC:Confirm("Log out your altbots?\n\n" .. table.concat(names, ", ") .. " will leave the group and log out. Random bots, players and parked altbots stay.",
            "Log out",
            function()
                if PBC.busy.logout then
                    return
                end
                runBatch("logout", "Logout altbots", 0.1, nil, {
                        FORBIDDEN        = "only the group leader can remove them",
                        TARGET_IS_LEADER = "is the group leader, so can't be removed",
                        BOT_NOT_ONLINE   = "already offline",
                        NOT_IN_GROUP     = "no longer in your group",
                        NOT_ALLOWED      = "not one of your characters",
                    },
                    function(bot, done)
                        Bridge:Resolve(bot, function(ok, reason, guid)
                            if not ok then
                                done(false, reason)
                                return
                            end
                            Bridge:LogoutFromGroup(guid, done)
                        end)
                    end,
                    function(result)
                        if result.bots > 0 then
                            PBC:Print("Logout altbots: " .. plural(result.bots, "altbot") .. " logged out.")
                        end
                    end,
                    names)
            end)
    end,
})

add({
    id = "resetraids",
    group = "party",
    name = "Reset raid lockouts",
    Visual = function()
        return ICONS .. "INV_Misc_Key_10"
    end,
    Tooltip = function(tooltip)
        tooltip:AddLine("Removes raid and dungeon lockouts, except for the instance each of you is in. Asks first.", 1, 1, 1, true)
        tooltip:AddLine("Left-click: you and every bot in your group", 1, 1, 1)
        tooltip:AddLine("Shift-click: you and everyone in your group, players too", 1, 1, 1)
        tooltip:AddLine("Needs game master rights, or mod-levelsync with LevelSync.AllowRaidUnbind = 1.", 0.7, 0.7, 0.7, true)
    end,
    Click = function(mouseButton)
        if PBC.resettingLockouts then
            return
        end
        if mouseButton ~= "LeftButton" then
            return
        end
        local everyone = IsShiftKeyDown()

        local function ask(others, note)
            local who = "you"
            if #others > 0 then
                who = "you and " .. table.concat(others, ", ")
            end
            PBC:Confirm("Reset raid lockouts?\n\nEvery raid and dungeon lockout is removed for " .. who
                    .. ", except for the instance each is standing in. This can't be undone." .. (note or ""),
                "Reset",
                function()
                    PBC:ResetLockouts(others)
                end)
        end

        local members = otherMembers()
        if #members == 0 or everyone then
            ask(members)
            return
        end

        -- Which of the others are bots? The bridge knows.
        Bridge:Roster(function(bots)
            if not bots then
                ask({}, "\n\nThe bridge didn't say which of your group are bots, so only you. Shift-click to include everyone.")
                return
            end
            local others = {}
            for _, name in ipairs(members) do
                if bots[string.lower(name)] then
                    others[#others + 1] = name
                end
            end
            ask(others)
        end)
    end,
})

-------------------------------------------------------------------------------
-- Pulling (in the Combat group, between Attack and CC)
--
-- Playerbots has its own pull: a tank given "pull rti target" pulls the mob
-- with the Skull marker from range, then runs back to where it stood. Other
-- bots ignore that order, but every bot treats whatever carries the Skull as
-- an enemy to fight, so the Skull only goes on once the group is held:
--   1. everyone goes passive (and, for a careful pull, stays where it is)
--   2. then the Skull goes on, and the tanks go active and pull
--   3. the group is released: for a careful pull once a tank is back near you
--      in combat, for a plain pull as soon as a tank is in combat
-------------------------------------------------------------------------------

-- Strategies that make Playerbots count a bot as a tank.
local TANK_STRATEGIES = { ["tank assist"] = true, ["tank"] = true, ["bear"] = true, ["blood"] = true }

-- [lower-case name] = true or false, learnt once per session per bot.
local tankCache = {}

local function hasAny(list, wanted)
    for name in pairs(wanted) do
        if list[name] then
            return true
        end
    end
    return false
end

-- Your puller if one is set and in your group, else the tanks among your
-- bots. Bots already known are answered at once; only new ones are asked.
local function findTanks(done)
    local inGroup = groupNames()
    local puller = PBC.chardb.puller
    if puller and inGroup[string.lower(puller)] then
        done({ inGroup[string.lower(puller)] })
        return
    end

    local members = otherMembers()
    local unknown = {}
    for _, name in ipairs(members) do
        if tankCache[string.lower(name)] == nil then
            unknown[#unknown + 1] = name
        end
    end

    local function finish()
        local tanks = {}
        for _, name in ipairs(members) do
            if tankCache[string.lower(name)] then
                tanks[#tanks + 1] = name
            end
        end
        done(tanks)
    end

    if #unknown == 0 then
        finish()
        return
    end
    local left = #unknown
    for _, name in ipairs(unknown) do
        Bridge:BotStrategies(name, function(combat)
            -- Bots that don't answer aren't remembered; players are (no strategies).
            if combat then
                tankCache[string.lower(name)] = hasAny(combat, TANK_STRATEGIES)
            end
            left = left - 1
            if left == 0 then
                finish()
            end
        end)
    end
end

-- The party or raid unit for a name, to check where the tank is.
local function unitFor(name)
    if PBC:InRaid() then
        for i = 1, GetNumRaidMembers() do
            if UnitName("raid" .. i) == name then
                return "raid" .. i
            end
        end
    else
        for i = 1, GetNumPartyMembers() do
            if UnitName("party" .. i) == name then
                return "party" .. i
            end
        end
    end
end

-- How close (CheckInteractDistance 3, about 10 yards) and how long to wait.
local RELEASE_DISTANCE = 3
local CAREFUL_TIMEOUT = 20
local PULL_TIMEOUT = 10

local function watchAndRelease(name, tanks, careful, previous)
    local started = GetTime()
    local timeout = careful and CAREFUL_TIMEOUT or PULL_TIMEOUT
    local released = false

    local function release(timedOut)
        if released then
            return
        end
        released = true
        PBC.busy.carefulpull = nil
        if timedOut then
            PBC:Print(name .. ": the tank " .. (careful and "wasn't back" or "hadn't pulled") .. " after " .. timeout .. " seconds, so the group is released.")
        end
        sendPassive(false, function() end)
        if not careful or previous == "stay" then
            PBC:Refresh()
            return
        end
        Bridge:FollowOrder(function(ok, reason, matched, succeeded)
            if ok then
                PBC.state.mode = "follow"
            elseif reason ~= "NO_BOTS" and reason ~= "NO_MATCH" and reason ~= "NO_GROUP" then
                report("Follow", ok, reason, matched, succeeded)
            end
            PBC:Refresh()
        end)
    end

    -- Checks four times a second, only while a pull runs.
    local function watch()
        if released then
            return
        end
        if not PBC:InGroup() then
            release(false)
            return
        end
        for _, tank in ipairs(tanks) do
            local unit = unitFor(tank)
            if unit and UnitAffectingCombat(unit)
                and (not careful or CheckInteractDistance(unit, RELEASE_DISTANCE)) then
                release(false)
                return
            end
        end
        if GetTime() - started >= timeout then
            release(true)
            return
        end
        PBC:After(0.25, watch)
    end
    -- Give the tank a moment to set off before looking.
    PBC:After(1, watch)
end

-- Everything goes out at once, in this order; the server handles it in
-- that order before any bot next thinks:
--   1. careful only: everyone Stays (Stay also clears Passive, so it's first)
--   2. everyone goes Passive, so nobody goes for the Skull
--   3. the Skull goes on
--   4. the tanks drop Stay (a bot on Stay won't move to pull) and Passive,
--      and are told to pull
local function startPull(name, tanks, careful)
    local previous = PBC.state.mode
    local function failed(ok, reason, matched, succeeded)
        if not ok then
            report(name, ok, reason, matched, succeeded)
        end
    end
    if careful then
        Bridge:StayOrder(failed)
    end
    sendPassive(true, failed)
    mark(SKULL)
    local change = careful and "-stay,-passive" or "-passive"
    for _, tank in ipairs(tanks) do
        Bridge:BotStrategy(tank, "C", change, function() end)
        Bridge:BotStrategy(tank, "N", change, function() end)
        Bridge:BotRti(tank, "pull rti target", function() end)
    end
    watchAndRelease(name, tanks, careful, previous)
end

-- Shift-click: your targeted bot becomes the puller; no bot targeted clears it.
local function setPuller()
    local target = UnitExists("target") and UnitIsPlayer("target") and UnitName("target")
    if target and groupNames()[string.lower(target)] then
        PBC.chardb.puller = target
        PBC:Print("Careful pull: " .. target .. " is your puller. Shift-click with no bot targeted to go back to all tanks.")
    elseif not UnitExists("target") or UnitCanAttack("player", "target") then
        PBC.chardb.puller = nil
        PBC:Print("Careful pull: no puller set; every tank in your group pulls.")
    else
        PBC:Print("Careful pull: target one of your bots in your group to make it the puller.")
    end
end

local function pullClick(careful)
    local name = careful and "Careful pull" or "Pull"
    if PBC.busy.carefulpull or not needGroup(name) then
        return
    end
    if not hostileTarget() then
        PBC:Print(name .. ": target an enemy first.")
        return
    end
    if not PBC:CanMark() then
        PBC:Print(name .. ": only the raid leader and assistants can set the Skull marker the tank pulls.")
        return
    end
    if PBC.state.passive then
        PBC:Print(name .. ": your bots are passive, and a passive tank won't pull. Set them Active first.")
        return
    end
    if not Bridge:IsReady() then
        report(name, false, Bridge.status == "connecting" and "CONNECTING" or "NO_BRIDGE")
        Bridge:Hello()
        return
    end
    if GetRaidTargetIndex("target") == SKULL then
        -- Already marked: the bots are on their way in, too late to hold them.
        PBC:Print(name .. ": your target already has the Skull, so the bots will go for it. Take the Skull off first (or use Attack).")
        return
    end

    setBusy("carefulpull", true)
    findTanks(function(tanks)
        if #tanks == 0 then
            PBC.busy.carefulpull = nil
            PBC:Print(name .. ": there's no tank among your bots in this group.")
            PBC:Refresh()
            return
        end
        if PBC.db.confirm then
            PBC:Print(name .. ": " .. table.concat(tanks, ", ") .. " pulling.")
        end
        startPull(name, tanks, careful)
    end)
end

local pullAction = {
    id = "carefulpull",
    group = "combat",
    name = "Careful pull",
    caps = { "STAY_ORDER_V1", "FOLLOW_ORDER_V1", "STRATEGY_MUTATION_V1" },
    bridge = true,
    Visual = function()
        return ICONS .. "INV_Weapon_Rifle_01"
    end,
    Tooltip = function(tooltip)
        tooltip:AddLine("Your tank pulls the target from range and brings it back to you. Puts the Skull marker on it.", 1, 1, 1, true)
        tooltip:AddLine("Left-click: careful pull. Everyone else waits where they are and holds fire until the tank is back with the mob. Stand still while it runs.", 1, 1, 1, true)
        tooltip:AddLine("Right-click: pull. Everyone else holds fire until the tank has pulled, then joins in from where they are.", 1, 1, 1, true)
        tooltip:AddLine("Shift-click: make your targeted bot the puller (no bot targeted: every tank pulls).", 1, 1, 1, true)
        local puller = PBC.chardb.puller
        if puller then
            tooltip:AddLine("Puller: " .. puller .. " (when in your group; it needs to count as a tank for Playerbots)", 0.7, 0.7, 0.7, true)
        else
            tooltip:AddLine("Puller: every tank in your group", 0.7, 0.7, 0.7, true)
        end
    end,
    Click = function(mouseButton)
        if mouseButton == "LeftButton" and IsShiftKeyDown() then
            setPuller()
            return
        end
        pullClick(mouseButton ~= "RightButton")
    end,
}

-- Sits just above Attack, below CC.
for index, action in ipairs(PBC.actions) do
    if action.id == "cc" then
        table.insert(PBC.actions, index, pullAction)
        break
    end
end
PBC.actionById.carefulpull = pullAction
