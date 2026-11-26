-- Levelling.lua
-- Levelling answers: what to do next, quests here, zones, dungeons, rares, quest log tidy-up,
-- hand-in route, where your group is, the hearthstone, and class spells to train.

local _, AskBot = ...
local D = AskBot.Data
local Out = AskBot.Out
local Levelling = {}
AskBot.Levelling = Levelling
local GOLD, GREY, say, askerLevel, autoPin = Out.GOLD, Out.GREY, Out.say, Out.askerLevel, Out.autoPin
local makeLink, pinLink, formatTime, whereText = Out.makeLink, Out.pinLink, Out.formatTime, Out.whereText
local shortHow, describe, showRanked, pinBest = Out.shortHow, Out.describe, Out.showRanked, Out.pinBest
local placesForIds, questAvailable = AskBot.Quests.placesForIds, AskBot.Quests.questAvailable
local questComplete, turnInPlaces = AskBot.Quests.questComplete, AskBot.Quests.turnInPlaces
local quicker, questTasks = AskBot.Quests.quicker, AskBot.Quests.questTasks
local objectiveText, lootUnavailable = AskBot.Quests.objectiveText, AskBot.Quests.lootUnavailable
local questLogEntries, questLabel = AskBot.Quests.questLogEntries, AskBot.Quests.questLabel
local questGivers, joinSome = AskBot.Quests.questGivers, AskBot.Quests.joinSome
local groupUnits = AskBot.Quests.groupUnits
local askerClass, targetsById = Out.askerClass, Out.targetsById
local friendlyPlaces, questXP = AskBot.Quests.friendlyPlaces, AskBot.Quests.questXP
local resolveQuest, questObjectives = AskBot.Quests.resolveQuest, AskBot.Quests.questObjectives
local questStatus, questForMe = AskBot.Quests.questStatus, AskBot.Quests.questForMe
local missingSteps, forMyClass = AskBot.Quests.missingSteps, AskBot.Quests.forMyClass

--------------------------------------------------------------------------------------------
-- Levelling helper: what's next, quests near me, dungeons for my level, rares
--------------------------------------------------------------------------------------------

local function answerQuestLog()
    local entries = questLogEntries()
    if #entries == 0 then
        return say("Your quest log is empty. Try " .. GOLD .. "/ab quests here|r to find some.")
    end

    local turnIns, objectives, unknown = {}, {}, 0
    for _, q in ipairs(entries) do
        local name = QuestDB.name(q.id) or q.name
        local complete, objs, turnIn = questTasks(q.id)
        if complete then
            if turnIn then turnIns[#turnIns + 1] = { quest = q.id, name = name, r = turnIn } else unknown = unknown + 1 end
        else
            for _, o in ipairs(objs) do
                if o.best and not o.later then objectives[#objectives + 1] = { quest = q.id, name = name, o = o, r = o.best } end
            end
        end
    end
    table.sort(turnIns, function(a, b) return quicker(a.r, b.r) end)
    table.sort(objectives, function(a, b) return quicker(a.r, b.r) end)

    if #turnIns > 0 then
        say("Ready to hand in" .. (#turnIns > 4 and (" (" .. #turnIns .. ")") or "") .. ":")
        for i = 1, math.min(4, #turnIns) do
            local t = turnIns[i]
            say("  " .. questLabel(t.quest, t.name) .. ": " .. describe(t.r, t.name))
        end
    end
    if #objectives > 0 then
        say("Nearest objectives:")
        for i = 1, math.min(5, #objectives) do
            local o = objectives[i]
            say("  " .. questLabel(o.quest, o.name) .. ": " .. objectiveText(o.o))
        end
    end
    if #turnIns == 0 and #objectives == 0 then
        say("Questie doesn't know where any of your " .. #entries .. " quests' objectives are.")
    end
    if unknown > 0 then
        say(GREY .. "  (" .. unknown .. " complete quest" .. (unknown == 1 and "" or "s") .. " with no known turn-in.)|r")
    end
    local first = turnIns[1] or objectives[1]
    if first then autoPin(first.r.place, first.r.spawn, first.name) end
end

--- Quests you could pick up: right level, not grey, not already in your log, and doable
--- by Questie's own checks when it runs, else ours (completed, prerequisites, class, reputation...).
--- `level` defaults to yours; for another level, a simple grey-quest rule replaces the game's.
local function doableQuests(level)
    local isDoable, isTrivial = AskBot.Compat.IsDoable, AskBot.Compat.IsTrivial
    local myLevel = askerLevel()
    level = level or myLevel
    local inLog = {}
    for _, q in ipairs(questLogEntries()) do inLog[q.id] = true end

    local ids = {}
    for id, info in pairs(D.questInfo) do
        local req = (info.req and info.req > 0) and info.req or info.level or 1
        local fitsLevel = req <= level and not (info.max and info.max > 0 and level > info.max)
        if fitsLevel and not inLog[id] then
            local trivial = false
            if level ~= myLevel then
                trivial = info.level ~= nil and info.level > 0 and info.level < level - 7
            elseif isTrivial then
                local ok, result = pcall(isTrivial, info.level)
                trivial = ok and result
            end
            if not trivial then
                local ok, doable = false, nil
                if isDoable then ok, doable = pcall(isDoable, id) end
                if not ok then doable = questAvailable(id) end -- fallback: faction only
                if doable then ids[#ids + 1] = id end
            end
        end
    end
    return ids
end

--- "Gryan Stoutmantle, 68 yds [pin]: [14] Patrolling Westfall, [15] Westfall Stew +1"
local function giverLine(g, maxQuests)
    local names = {}
    for j, id in ipairs(g.quests) do
        if j > maxQuests then names[#names + 1] = GREY .. "+" .. (#g.quests - maxQuests) .. "|r"; break end
        local xp = questXP(id)
        names[#names + 1] = questLabel(id) .. (xp and (GREY .. " " .. xp .. "xp|r") or "")
    end
    return GOLD .. g.r.place.name .. "|r, " .. shortHow(g.r) .. " " .. pinLink(g.r.place, g.r.spawn, "quests")
        .. ": " .. table.concat(names, ", ")
end

--- Quest givers near you with quests you can take, nearest first (same continent).
local function answerQuestsHere(ids, maxGivers)
    local list, count = questGivers(ids or doableQuests())
    if #list == 0 then
        return say("No new quests for you on this continent, as far as Questie knows.")
    end
    say("Quests you can pick up (" .. count .. " on this continent), nearest first:")
    for i = 1, math.min(maxGivers or 5, #list) do say("  " .. giverLine(list[i], 3)) end
    return list[1].r
end

--- Zones worth questing in: those with the most quests you can take near your level,
--- each with its busiest quest giver as the hub to head for.
-- Capital cities: their quests are mostly class, profession and chain quests, so they're
-- not suggested as places to level.
local CAPITALS = { [1453] = true, [1455] = true, [1457] = true, [1454] = true, [1456] = true, [1458] = true }

--- The zone map you're in; sub-zone maps (towns, caves) roll up to their zone.
local function currentZoneMap()
    local mapId = C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    local info = mapId and C_Map.GetMapInfo(mapId)
    while info and info.mapType and info.mapType > 3 and info.parentMapID and info.parentMapID > 0 do
        mapId = info.parentMapID
        info = C_Map.GetMapInfo(mapId)
    end
    return mapId
end

--- For /ab zones debug: every quest given in the zone you're in, sorted by why it does or
--- doesn't count towards the zone suggestions.
local function explainCurrentZone(level)
    local mapId = currentZoneMap()
    if not mapId then return say(GREY .. "(I can't tell which zone you're in.)|r") end

    local isDoable, isTrivial = AskBot.Compat.IsDoable, AskBot.Compat.IsTrivial
    local isCompleted = (C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted) or IsQuestFlaggedCompleted
    local inLog = {}
    for _, q in ipairs(questLogEntries()) do inLog[q.id] = true end

    local order = { "counted", "done", "inLog", "tooHigh", "grey", "hostile", "unavailable" }
    local labels = {
        counted = "counted", done = "already done", inLog = "in your log", tooHigh = "need a higher level",
        grey = "too easy (grey)", hostile = "from NPCs hostile to you",
        unavailable = "not available yet (prerequisites, class, reputation...)",
    }
    local buckets, total = {}, 0
    for _, k in ipairs(order) do buckets[k] = {} end
    for id, qi in pairs(D.questInfo) do
        local giver = placesForIds(qi.npcs, qi.objects)[1]
        local spawn = giver and giver.spawns[1]
        if spawn and spawn.uiMapId == mapId then
            total = total + 1
            local req = (qi.req and qi.req > 0) and qi.req or qi.level or 1
            local bucket
            if inLog[id] then
                bucket = "inLog"
            elseif isCompleted and isCompleted(id) then
                bucket = "done"
            elseif req > level or (qi.max and qi.max > 0 and level > qi.max) then
                bucket = "tooHigh"
            elseif isTrivial and select(2, pcall(isTrivial, qi.level)) == true then
                bucket = "grey"
            elseif not placesForIds(qi.npcs, qi.objects, true)[1] then
                bucket = "hostile"
            elseif isDoable and select(2, pcall(isDoable, id)) ~= true then
                bucket = "unavailable"
            else
                bucket = "counted"
            end
            table.insert(buckets[bucket], id)
        end
    end

    say(GREY .. "Quests given in|r " .. GOLD .. D.ZoneName(mapId) .. "|r" .. GREY .. ": " .. total .. "|r")
    for _, k in ipairs(order) do
        local ids = buckets[k]
        if #ids > 0 then
            table.sort(ids, function(a, b) return (QuestDB.questLevel(a) or 0) < (QuestDB.questLevel(b) or 0) end)
            local names = {}
            for j = 1, math.min(4, #ids) do names[j] = questLabel(ids[j]) end
            say("  " .. #ids .. " " .. labels[k] .. ": " .. table.concat(names, ", ") .. (#ids > 4 and (GREY .. " ...|r") or ""))
        end
    end
end

-- New quests count towards a zone when their level is within this many levels of yours.
local ZONE_LEVELS = 2

--- XP a quest is worth for ranking zones: QuestieDB's XP, or a flat 1000 when there's no
--- XP table. nil when the table says it gives none.
local function hasXPTable()
    return AskBot.Compat.HasXPTable() or AskBot.Compat.QuestieModule("QuestXP") ~= nil
end
local function rankXP(id)
    local xp = questXP(id)
    if xp then return xp end
    return not hasXPTable() and 1000 or nil
end

--- Zones worth questing in, best first: the most XP from quests within two levels of yours,
--- weighed by how far away the zone is. Each is { map, active = your quests there,
--- levels = new quests' levels, xp, r = where to start (ranked result) }, or nil if none.
local function rankZones(level, ids)
    local zones = {}
    local function zoneFor(map)
        local z = zones[map]
        if not z then
            z = { map = map, quests = {}, levels = {}, givers = {}, fit = 0, active = {}, xp = 0 }
            zones[map] = z
        end
        return z
    end

    -- Quests already in your log count where their next step is (the nearest unfinished
    -- objective, or the turn-in once complete), and count more than new quests.
    if not AskBot.asker then
        for _, q in ipairs(questLogEntries()) do
            local complete, objectives, turnIn = questTasks(q.id)
            local nextStep
            if not complete then
                for _, o in ipairs(objectives) do
                    if o.best and (not nextStep or quicker(o.best, nextStep)) then nextStep = o.best end
                end
            end
            nextStep = nextStep or turnIn
            if nextStep and nextStep.spawn and not CAPITALS[nextStep.spawn.uiMapId] then
                local z = zoneFor(nextStep.spawn.uiMapId)
                z.active[#z.active + 1] = { id = q.id, r = nextStep }
                z.xp = z.xp + (rankXP(q.id) or 0)
            end
        end
    end

    for _, id in ipairs(ids) do
        local info = D.questInfo[id]
        local giver = placesForIds(info.npcs, info.objects, true)[1]
        local spawn = giver and giver.spawns[1]
        local ql = info.level or 0
        local xp = rankXP(id)
        if spawn and not CAPITALS[spawn.uiMapId] and xp and math.abs(ql - level) <= ZONE_LEVELS then
            local z = zoneFor(spawn.uiMapId)
            z.quests[#z.quests + 1] = id
            z.levels[#z.levels + 1] = ql
            z.fit = z.fit + 1
            z.xp = z.xp + xp
            local key = giver.kind .. giver.id
            local g = z.givers[key]
            if not g then g = { place = giver, n = 0 }; z.givers[key] = g end
            g.n = g.n + 1
        end
    end

    -- Score: the XP of your quests there and the new ones near your level. Then weigh the
    -- best few by travel time: 20 minutes away halves a zone's score.
    local list = {}
    for _, z in pairs(zones) do
        if #z.levels + #z.active >= 2 and z.xp > 0 then
            z.questScore = z.xp
            -- The hub is the town: the giver with the most quests from givers within 300 yards.
            local function spawnHere(place)
                for _, s in ipairs(place.spawns) do
                    if s.uiMapId == z.map then return s end
                end
            end
            for _, g in pairs(z.givers) do
                local s = spawnHere(g.place)
                g.town = 0
                for _, h in pairs(z.givers) do
                    local d = D.SpawnDistance(s, spawnHere(h.place))
                    if h == g or (d and d <= 300) then g.town = g.town + h.n end
                end
                if not z.hub or g.town > z.hub.town or (g.town == z.hub.town and g.n > z.hub.n) then z.hub = g end
            end
            z.hubSpawn = z.hub and spawnHere(z.hub.place)
            list[#list + 1] = z
        end
    end
    if #list == 0 then return nil end
    table.sort(list, function(a, b) return a.questScore > b.questScore end)
    for i = #list, 13, -1 do list[i] = nil end -- only the best dozen are worth timing
    for _, z in ipairs(list) do
        -- Where to go: your nearest quest step there, else the busiest new quest giver.
        for _, a in ipairs(z.active) do
            if not z.activeR or quicker(a.r, z.activeR) then z.activeR = a.r end
        end
        z.r = z.activeR or (z.hub and D.Rank({ z.hub.place })[1])
        local minutes = (z.r and z.r.time or 1800) / 60
        z.score = z.questScore / (1 + minutes / 20)
    end
    table.sort(list, function(a, b) return a.score > b.score end)
    return list
end

--- "Westfall: 2 yours + 4 new"
local function zoneCounts(z)
    local counts = {}
    if #z.active > 0 then counts[#counts + 1] = #z.active .. " yours" end
    if #z.levels > 0 then counts[#counts + 1] = #z.levels .. " new" end
    return table.concat(counts, " + ")
end

--- ", FP Lakeshire (not learned)": the flight path in the zone's busiest town, for zones
--- you're not in. The town name shows once a flight map has listed it.
local function townFlightText(z)
    if z.map == currentZoneMap() then return "" end
    local fm, town, learned = D.TownFlight(z.hubSpawn)
    if not fm then return "" end
    return ", FP " .. GOLD .. (town or fm.name) .. "|r" .. (learned == false and (GREY .. " (not learned)|r") or "")
end

--- Where to quest, one line per zone. With `debug`, also prints the numbers behind the ranking.
local function answerZones(level, ids, maxZones, debug)
    level = level or askerLevel()
    ids = ids or doableQuests(level)
    maxZones = maxZones or 3
    local list = rankZones(level, ids)
    if not list then
        say("Questie doesn't know of a zone with several quests for level " .. level .. " that you haven't done.")
        return nil
    end

    say("Where to quest at level " .. level .. ":")
    local firstHub
    for i = 1, math.min(maxZones, #list) do
        local z = list[i]
        local levels = {}
        for _, l in ipairs(z.levels) do levels[#levels + 1] = l end
        for _, a in ipairs(z.active) do levels[#levels + 1] = QuestDB.questLevel(a.id) or 0 end
        table.sort(levels)
        local lo = levels[math.floor(#levels * 0.15) + 1]
        local hi = levels[math.max(1, math.ceil(#levels * 0.85))]
        local zoneName = D.ZoneName(z.map)
        -- One line per zone: "1. Redridge Mountains: 10 yours + 3 new, lvl 15-26 - Glinting Mud, 75 yds [pin]"
        local line = i .. ". " .. GOLD .. zoneName .. "|r: " .. zoneCounts(z)
            .. (lo > 0 and (", lvl " .. lo .. (hi > lo and ("-" .. hi) or "")) or "")
            .. (hasXPTable() and (", " .. (BreakUpLargeNumbers and BreakUpLargeNumbers(z.xp) or tostring(z.xp)) .. " xp") or "")
        if z.r then
            line = line .. " - " .. z.r.place.name .. ", " .. shortHow(z.r) .. " " .. pinLink(z.r.place, z.r.spawn, zoneName)
        end
        line = line .. townFlightText(z)
        say("  " .. line)
        firstHub = firstHub or z.r
    end

    if debug then
        explainCurrentZone(level)
        say(GREY .. "How these were ranked (XP of your quests there and of new ones within " .. ZONE_LEVELS
            .. " levels of yours; 20 min of travel halves the score):|r")
        for i = 1, math.min(8, #list) do
            local z = list[i]
            local names = {}
            for _, a in ipairs(z.active) do names[#names + 1] = questLabel(a.id) .. GREY .. " (yours)|r" end
            table.sort(z.quests, function(a, b) return (QuestDB.questLevel(a) or 0) < (QuestDB.questLevel(b) or 0) end)
            for _, id in ipairs(z.quests) do names[#names + 1] = questLabel(id) end
            local shown = {}
            for j = 1, math.min(4, #names) do shown[j] = names[j] end
            say(string.format("  %s: %d of yours, %d new, %d xp, %s away, score %.1f", D.ZoneName(z.map),
                #z.active, #z.levels, z.xp, z.r and z.r.time and formatTime(z.r.time) or "unknown", z.score))
            say("      " .. table.concat(shown, ", ") .. (#names > 4 and (GREY .. " ...|r") or ""))
        end
    end
    return firstHub
end

--- "Where should I quest next?": the best zones, then the nearest quest givers.
local function answerWhereToQuest()
    local ids = doableQuests()
    local hub = answerZones(nil, ids, 2)
    local nearest = answerQuestsHere(ids, 3)
    local target = hub or nearest
    if target then autoPin(target.place, target.spawn, "quests") end
end

--- AtlasLoot's dungeons whose level range includes `level`, best fit first:
--- { inst, lo, hi, best }.
local function dungeonsFor(level)
    local fits = {}
    for _, inst in ipairs(AskBot.Loot.instances) do
        local range = inst.levelRange
        if range and range[1] then
            local lo, hi = range[1], range[#range]
            local best = #range >= 3 and range[2] or (lo + hi) / 2
            if level >= lo and level <= hi then fits[#fits + 1] = { inst = inst, lo = lo, hi = hi, best = best } end
        end
    end
    table.sort(fits, function(a, b) return math.abs(a.best - level) < math.abs(b.best - level) end)
    return fits
end

local function answerDungeons(level)
    if lootUnavailable() then return end
    level = level or askerLevel()
    local fits = dungeonsFor(level)
    if #fits == 0 then return say("AtlasLoot has no dungeons for level " .. level .. ".") end

    say("Dungeons for level " .. level .. ":")
    local pinned
    for i = 1, math.min(4, #fits) do
        local f = fits[i]
        local entrance = AskBot.Loot.EntrancePlace(f.inst)
        local r = entrance and D.Rank({ entrance })[1]
        local inst = f.inst
        local loot = makeLink("loot", function() AskBot.Ask("what does " .. inst.name .. " drop") end)
        say("  " .. GOLD .. inst.name .. "|r (" .. f.lo .. "-" .. f.hi .. ") " .. loot
            .. (r and (" - entrance " .. whereText(r, inst.name)) or ""))
        if r and not pinned then pinned = r end
    end
    if pinned then autoPin(pinned.place, pinned.spawn, pinned.place.name) end
end

--- One line for a quest objective: "Kill Defias Trapper, 150 yds [pin]",
--- "Collect Linen Cloth from Defias Thug, ~2 min [pin]".
local function shortObjective(o, label)
    local r = o.best
    local what
    if o.verb == "Collect" then
        what = "Collect " .. GOLD .. o.name .. "|r from " .. GOLD .. r.place.name .. "|r"
    elseif o.verb == "Make" then
        what = "Make " .. GOLD .. o.name .. "|r at " .. GOLD .. r.place.name .. "|r"
    else
        what = o.verb .. " " .. GOLD .. o.name .. "|r"
    end
    return what .. ", " .. shortHow(r) .. " " .. pinLink(r.place, r.spawn, label)
end

--- "What should I do next?": one line each for the nearest hand-in, the nearest objective,
--- the nearest new quests, a better zone (if it isn't this one) and a dungeon for your level.
local function answerPlan()
    local level = askerLevel()
    local lines, first = {}, nil
    local function add(text, r)
        lines[#lines + 1] = "  " .. text
        first = first or r
    end

    local turnIns, nearest = {}, nil
    for _, q in ipairs(questLogEntries()) do
        local name = QuestDB.name(q.id) or q.name
        local complete, objectives, turnIn = questTasks(q.id)
        if complete then
            if turnIn then turnIns[#turnIns + 1] = { quest = q.id, name = name, r = turnIn } end
        else
            for _, o in ipairs(objectives) do
                if o.best and not o.later and not o.have and (not nearest or quicker(o.best, nearest.o.best)) then
                    nearest = { quest = q.id, name = name, o = o }
                end
            end
        end
    end
    table.sort(turnIns, function(a, b) return quicker(a.r, b.r) end)

    local t = turnIns[1]
    if t then
        local more = #turnIns > 1
            and (" " .. makeLink("+" .. (#turnIns - 1) .. " more", function() AskBot.Ask("hand in route") end)) or ""
        add("Hand in: " .. questLabel(t.quest, t.name) .. " - " .. GOLD .. t.r.place.name .. "|r, " .. shortHow(t.r)
            .. " " .. pinLink(t.r.place, t.r.spawn, t.name) .. more, t.r)
    end
    if nearest then
        add("Objective: " .. questLabel(nearest.quest, nearest.name) .. " - " .. shortObjective(nearest.o, nearest.name),
            nearest.o.best)
    end

    local ids = doableQuests(level)
    local givers = questGivers(ids)
    if givers[1] then add("New quests: " .. giverLine(givers[1], 2), givers[1].r) end

    local zones = rankZones(level, ids)
    local z = zones and zones[1]
    if z and z.r and z.map ~= currentZoneMap() then
        add("Best zone: " .. GOLD .. D.ZoneName(z.map) .. "|r (" .. zoneCounts(z) .. ") - " .. z.r.place.name .. ", "
            .. shortHow(z.r) .. " " .. pinLink(z.r.place, z.r.spawn, D.ZoneName(z.map)) .. townFlightText(z), z.r)
    end

    if AskBot.Loot.status == "ready" then
        local f = dungeonsFor(level)[1]
        if f then
            local entrance = AskBot.Loot.EntrancePlace(f.inst)
            local r = entrance and D.Rank({ entrance })[1]
            add("Dungeon: " .. GOLD .. f.inst.name .. "|r (" .. f.lo .. "-" .. f.hi .. ")"
                .. (r and (" - entrance " .. shortHow(r) .. " " .. pinLink(r.place, r.spawn, f.inst.name)) or ""))
        end
    end

    if #lines == 0 then
        return say("Questie doesn't know of anything for you nearby. Try " .. GOLD .. "/ab zones|r.")
    end
    say("What to do next (level " .. level .. "):")
    for _, line in ipairs(lines) do say(line) end
    say("  " .. GREY .. "More:|r " .. makeLink("my quests", function() AskBot.Ask("my quests") end) .. " "
        .. makeLink("where to quest", function() AskBot.Ask("where should i quest") end) .. " "
        .. makeLink("dungeons", function() AskBot.Ask("dungeons") end))
    if first then autoPin(first.place, first.spawn, first.place.name) end
end

--- Too easy to be worth much XP: the game's grey rule for your level.
local function questIsGrey(level)
    if not level or level <= 0 then return false end
    return AskBot.Compat.IsTrivial(level)
end

--- The game's quest tag: "Elite", "Dungeon", "Raid", "Group", "PvP"... or nil.
local function questTag(id)
    local name
    if C_QuestLog and C_QuestLog.GetQuestTagInfo then
        local ok, info = pcall(C_QuestLog.GetQuestTagInfo, id)
        if ok and type(info) == "table" then name = info.tagName end
    end
    if not name and GetQuestTagInfo then
        local ok, _, tagName = pcall(GetQuestTagInfo, id)
        if ok then name = tagName end
    end
    return name ~= "" and name or nil
end

--- "Which quests should I abandon?": grey quests, quests that need a group, and quests
--- whose next step is far away (another continent, or over 10 minutes).
local function answerTidy()
    local entries = questLogEntries()
    if #entries == 0 then return say("Your quest log is empty.") end
    local grey, group, far = {}, {}, {}
    for _, q in ipairs(entries) do
        local name = QuestDB.name(q.id) or q.name
        local label = questLabel(q.id, name)
        if questIsGrey(QuestDB.questLevel(q.id)) then
            grey[#grey + 1] = label
        else
            local complete, objectives, turnIn = questTasks(q.id)
            local dungeon, nextStep
            for _, o in ipairs(objectives) do
                if o.best then
                    dungeon = dungeon or o.best.spawn.dungeon
                    if not o.have and (not nextStep or quicker(o.best, nextStep)) then nextStep = o.best end
                end
            end
            if complete then nextStep = turnIn end
            local tag = questTag(q.id)
            if dungeon then
                group[#group + 1] = label .. GREY .. " (in " .. dungeon .. ")|r"
            elseif tag and tag ~= "PvP" then
                group[#group + 1] = label .. GREY .. " (" .. tag:lower() .. ")|r"
            elseif q.group and q.group > 1 then
                group[#group + 1] = label .. GREY .. " (group of " .. q.group .. ")|r"
            elseif nextStep and nextStep.time and (nextStep.time > 600 or not nextStep.dist) then
                far[#far + 1] = label .. GREY .. " (" .. D.ZoneName(nextStep.spawn.uiMapId) .. ", " .. shortHow(nextStep) .. ")|r"
            end
        end
    end

    local max = (C_QuestLog and C_QuestLog.GetMaxNumQuestsCanAccept and C_QuestLog.GetMaxNumQuestsCanAccept()) or 20
    if #grey + #group + #far == 0 then
        return say("Nothing to drop: none of your " .. #entries .. " quests are grey, need a group or are far away.")
    end
    say("Quest log: " .. #entries .. " of " .. max .. ". Could drop:")
    if #grey > 0 then say("  Grey (little XP): " .. joinSome(grey, 4)) end
    if #group > 0 then say("  Need a group: " .. joinSome(group, 3)) end
    if #far > 0 then say("  Far away: " .. joinSome(far, 3)) end
end

--- "Where do I hand in my quests?": every complete quest's turn-in, as a route that
--- always goes to the nearest stop next. One line per stop.
local function answerHandInRoute()
    local stops, byKey, unknown = {}, {}, 0
    for _, q in ipairs(questLogEntries()) do
        if questComplete(q.id) then
            local turnIn = D.Rank(turnInPlaces(q.id))[1]
            if turnIn then
                local key = turnIn.place.kind .. turnIn.place.id
                local stop = byKey[key]
                if not stop then
                    stop = { place = turnIn.place, quests = {} }
                    byKey[key] = stop
                    stops[#stops + 1] = stop
                end
                stop.quests[#stop.quests + 1] = questLabel(q.id, QuestDB.name(q.id) or q.name)
            else
                unknown = unknown + 1
            end
        end
    end
    if #stops == 0 then
        return say(unknown > 0 and ("Questie doesn't know where to hand in your " .. unknown .. " complete quest"
            .. (unknown == 1 and "" or "s") .. ".") or "Nothing in your quest log is ready to hand in yet.")
    end

    local route, origin, total, count = {}, nil, 0, 0
    while #stops > 0 do
        local places = {}
        for i, s in ipairs(stops) do places[i] = s.place end
        local r = D.Rank(places, origin)[1]
        for i, s in ipairs(stops) do
            if s.place == r.place then
                route[#route + 1] = { stop = s, r = r }
                count = count + #s.quests
                table.remove(stops, i)
                break
            end
        end
        total = total + (r.time or 0)
        local sp = r.spawn
        origin = sp.wx and { x = sp.wx, y = sp.wy, inst = sp.inst } or nil
    end

    say("Hand-in route (" .. count .. " quest" .. (count == 1 and "" or "s")
        .. (total > 0 and (", " .. formatTime(total)) or "") .. "):")
    for i = 1, math.min(6, #route) do
        local s, r = route[i].stop, route[i].r
        say("  " .. i .. ". " .. GOLD .. s.place.name .. "|r, " .. shortHow(r) .. " " .. pinLink(r.place, r.spawn, s.place.name)
            .. ": " .. joinSome(s.quests, 3))
    end
    if #route > 6 then say(GREY .. "  +" .. (#route - 6) .. " more stops|r") end
    if unknown > 0 then say(GREY .. "  (" .. unknown .. " more with no known turn-in.)|r") end
    autoPin(route[1].r.place, route[1].r.spawn, route[1].stop.place.name)
end

local function answerRares()
    local places = {}
    for id in pairs(D.rares) do
        local p = D.NpcPlace(id)
        if p and #p.spawns > 0 then places[#places + 1] = p end
    end
    if #places == 0 then return say("Questie doesn't list any rare mobs.") end
    local best = showRanked(places, "Rare mobs nearest you:", "rare", AskBot.Option("maxResults") + 2, {
        showLevel = true,
        extra = function(p) return " |cffc0c0c0(" .. (D.rares[p.id] == 2 and "rare elite" or "rare") .. ")|r" end,
    })
    pinBest(best, "rare")
end

--------------------------------------------------------------------------------------------
-- Group members: "where is my party", "where is Buddy"
--------------------------------------------------------------------------------------------

--- Where your group members are, nearest first; `only` (lower-case name) limits it to one.
--- When answering someone's "!ask", "your group" is theirs: everyone but them, you included.
local function isAsker(unit, name)
    local a = AskBot.asker
    if not a then return unit == "player" end
    if a.unit then return unit == a.unit end
    if a.guid and UnitGUID then return UnitGUID(unit) == a.guid end
    return D.SameName(name, a.name)
end

local function answerGroup(only)
    local units, places, notes, askerInGroup = groupUnits(), {}, {}, not AskBot.asker
    for _, unit in ipairs(units) do
        local name = UnitExists(unit) and UnitName(unit)
        local asking = name and isAsker(unit, name)
        if asking then askerInGroup = true end
        if name and not asking and (not only or D.SameName(name, only)) then
            if UnitIsConnected and not UnitIsConnected(unit) then
                notes[#notes + 1] = GOLD .. name .. "|r is offline."
            else
                local spawn, mapId = D.UnitSpawn(unit)
                local className = UnitClass(unit)
                local sub = (UnitLevel(unit) or "?") .. " " .. (className or "")
                if spawn then
                    places[#places + 1] = { kind = "unit", name = name, sub = sub, spawns = { spawn } }
                else
                    notes[#notes + 1] = GOLD .. name .. "|r is in " .. (mapId and D.ZoneName(mapId) or "a place I can't see")
                        .. GREY .. " (no exact position there)|r."
                end
            end
        end
    end
    if not askerInGroup then return say("I can only see my own group, and you're not in it.") end
    if #places == 0 and #notes == 0 then
        return say(#units == 1 and "You're not in a group." or "No one else in your group.")
    end
    local results = D.Rank(places)
    if not only and #results + #notes > 0 then say("Your group:") end
    for _, r in ipairs(results) do say((only and "" or "  ") .. describe(r)) end
    for _, n in ipairs(notes) do say((only and "" or "  ") .. n) end
    if only and results[1] then autoPin(results[1].place, results[1].spawn) end
end

--- "where is <name>": a group member, else a guild member (zone only). True if answered.
local function answerPerson(subject)
    local key = subject:lower()
    for _, unit in ipairs(groupUnits()) do
        local name = UnitExists(unit) and UnitName(unit)
        if name and D.SameName(name, key) then
            answerGroup(key)
            return true
        end
    end
    if IsInGuild and IsInGuild() and GetNumGuildMembers and GetGuildRosterInfo then
        for i = 1, GetNumGuildMembers() do
            local fullName, _, _, level, className, zone, _, _, online = GetGuildRosterInfo(i)
            local name = fullName and (fullName:match("^([^%-]+)") or fullName)
            if name and D.SameName(name, key) then
                if online then
                    say(GOLD .. name .. "|r (level " .. tostring(level) .. " " .. tostring(className) .. ") is in "
                        .. tostring(zone) .. GREY .. " (from the guild roster; exact positions only for group members)|r.")
                else
                    say(GOLD .. name .. "|r is offline.")
                end
                return true
            end
        end
    end
    return false
end

--------------------------------------------------------------------------------------------
-- Hearthstone: "/ab hearth"
--------------------------------------------------------------------------------------------

local HEARTH_QUESTIONS = {}
for _, s in ipairs({ "hearth", "hearthstone", "my hearth", "my hearthstone", "where is my hearth", "where is my hearthstone",
    "where does my hearth go", "where does my hearthstone go", "is my hearth ready", "hearth cooldown",
    "hearthstone cooldown" }) do HEARTH_QUESTIONS[s] = true end

--- "/ab hearth": where your hearthstone goes and when it's ready.
local function answerHearth()
    local h, known, current = D.Hearth()
    if not h then
        if known == false and current then
            return say("Your hearthstone is set to " .. GOLD .. current .. "|r. Use it once (or set it again) and I'll learn"
                .. " where that is, so travel times can include hearthing.")
        end
        return say("I don't see a hearthstone in your bags.")
    end
    local ready = h.remaining <= 0 and "|cff40ff40ready|r" or ("ready in " .. formatTime(h.remaining):gsub("^~", ""))
    local spawn = h.uiMapId and h.x and { uiMapId = h.uiMapId, x = h.x, y = h.y }
    say("Hearthstone: " .. GOLD .. h.name .. "|r" .. (h.uiMapId and (" (" .. D.ZoneName(h.uiMapId) .. ")") or "") .. ", " .. ready
        .. (spawn and (" " .. pinLink({ name = h.name }, spawn, "hearth")) or "")
        .. GREY .. ". Travel times use it when it's ready and saves a minute or more.|r")
end

--------------------------------------------------------------------------------------------
-- Class training: "/ab skills I can learn", from the class trainer's window
--------------------------------------------------------------------------------------------

-- AskBotCharDB.training = { seen = time, spells = { ["Rend|Rank 2"] = { name, rank, level, cost, used } } }
-- When the trainer gives no rank (Forever), the key is "Rend|L20": each rank has its own level.
local function trainingKey(name, rank, level)
    if rank then return name .. "|" .. rank end
    return name .. "|L" .. (level or "")
end

local SERVICE_TYPES = { header = true, available = true, unavailable = true, used = true }

--- One trainer row as name, rank (or nil), type, collapsed (a header that's folded up).
--- The classic API gives name, rank, type, expanded; Forever gives the type second and no rank.
local function trainerRow(i)
    local name, a, b, c = GetTrainerServiceInfo(i)
    if SERVICE_TYPES[a] then
        local rank = type(b) == "string" and b:find("%d") and b or nil
        local expanded = type(b) == "boolean" and b or c
        return name, rank, a, expanded == false
    end
    return name, (a ~= "" and a) or nil, b, not c
end

--- Is the open trainer window your class trainer (not a profession, pet or weapon trainer)?
local function isClassTrainerWindow()
    if IsTradeskillTrainer and IsTradeskillTrainer() then return false end
    local guid = UnitGUID and UnitGUID("npc")
    local npcId = guid and tonumber(guid:match("^Creature%-%d+%-%d+%-%d+%-%d+%-(%d+)"))
    local sub = npcId and NpcDB.subName(npcId)
    if not sub then return true end -- a trainer Questie doesn't know
    local t = targetsById[askerClass()]
    return t ~= nil and t.test(sub:lower(), function() return true end)
end

--- Reads the open class trainer window into AskBotCharDB.training, merged with earlier visits.
local function recordTraining()
    if not (GetNumTrainerServices and GetTrainerServiceInfo) or not isClassTrainerWindow() then return end
    AskBotCharDB = AskBotCharDB or {}
    local t = AskBotCharDB.training or { spells = {} }
    AskBotCharDB.training = t
    -- Lists saved before 0.14.1 on Forever stored the type as the rank, one entry per spell
    -- name (the highest rank won): drop them, this visit rebuilds the list.
    for key, e in pairs(t.spells) do
        if SERVICE_TYPES[e.rank] then t.spells[key] = nil end
    end
    local visible, collapsed = {}, false
    for i = 1, (GetNumTrainerServices() or 0) do
        local name, rank, category, folded = trainerRow(i)
        if category == "header" then
            if folded then collapsed = true end
        elseif name and category then
            local level = GetTrainerServiceLevelReq and GetTrainerServiceLevelReq(i)
            local key = trainingKey(name, rank, level)
            visible[key] = true
            local e = t.spells[key] or {}
            e.name, e.rank = name, rank
            e.level = level or e.level
            e.cost = (GetTrainerServiceCost and GetTrainerServiceCost(i)) or e.cost
            e.used = category == "used"
            t.spells[key] = e
        end
    end
    -- Learned spells leave the list while the "used" filter is off (the default), so anything
    -- missing from a full list of unlearned spells has been learned.
    local filter = GetTrainerServiceTypeFilter
    local unlearnedShown = not filter or (filter("available") and filter("unavailable"))
    if next(visible) and not collapsed and unlearnedShown and not (filter and filter("used")) then
        for key, e in pairs(t.spells) do
            if not visible[key] then e.used = true end
        end
    end
    t.seen = time and time() or 0
end

--- A spell was learned (LEARNED_SPELL_IN_TAB): tick it off.
local function learnedSpell(spellId)
    local t = AskBotCharDB and AskBotCharDB.training
    if not t or not spellId then return end
    local name = (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellId))
        or (GetSpellInfo and GetSpellInfo(spellId))
    local rank = (C_Spell and C_Spell.GetSpellSubtext and C_Spell.GetSpellSubtext(spellId))
        or (GetSpellSubtext and GetSpellSubtext(spellId))
    if not name then return end
    rank = (rank ~= "" and rank) or nil
    local e = rank and t.spells[trainingKey(name, rank)]
    if not e then
        -- No rank to match (Forever): the lowest unlearned one you're high enough for.
        local level = askerLevel()
        for _, s in pairs(t.spells) do
            if s.name == name and not s.used and s.level and s.level <= level
                and (not e or s.level < e.level) then
                e = s
            end
        end
    end
    if e then e.used = true end
end

--- "what skills can I learn", "spells I can train", "what can I train".
local TRAIN_NOUNS = { skill = true, skills = true, spell = true, spells = true, ability = true, abilities = true,
    rank = true, ranks = true }
local function trainingQuestion(q)
    if q == "train" or q == "training" or q:find("^what can i train") or q:find("^what can i learn")
        or q:find("^what should i train") or q:find("^new spells") or q:find("^new skills") or q:find("^new abilities") then
        return true
    end
    local noun, verb
    for w in q:gmatch("%a+") do
        if TRAIN_NOUNS[w] then noun = true end
        if w == "learn" or w == "train" or w == "trainable" or w == "learnable" or w == "available" then verb = true end
    end
    return noun and verb or false
end

local function spellLabel(e)
    local n = e.rank and e.rank:match("%d+")
    return GOLD .. e.name .. "|r" .. (n and (" " .. n) or "")
end

local function bySpell(a, b)
    if a.level ~= b.level then return a.level < b.level end
    if a.name ~= b.name then return a.name < b.name end
    return (tonumber(a.rank and a.rank:match("%d+")) or 0) < (tonumber(b.rank and b.rank:match("%d+")) or 0)
end

--- Class spells you can train now (from the recorded trainer list), their cost, the nearest
--- class trainer, and what comes next.
local function answerTraining()
    local classFile, level = askerClass(), askerLevel()
    local target = targetsById[classFile]
    local best = target and D.Rank(friendlyPlaces(D.byTarget[target.id]))[1]
    local trainer = best and (GOLD .. best.place.name .. "|r, " .. shortHow(best) .. " " .. pinLink(best.place, best.spawn, target.label)) or ""
    local t = AskBotCharDB and AskBotCharDB.training
    if not t or not next(t.spells) then
        return say("Open your class trainer once so I can read what it teaches."
            .. (best and (" Nearest " .. target.label .. ": " .. trainer) or ""))
    end
    local now, nextLevel, cost = {}, nil, 0
    for _, e in pairs(t.spells) do
        if not e.used and e.level then
            if e.level <= level then
                now[#now + 1] = e
                cost = cost + (e.cost or 0)
            elseif not nextLevel or e.level < nextLevel then
                nextLevel = e.level
            end
        end
    end
    table.sort(now, bySpell)
    if #now > 0 then
        local labels = {}
        for i, e in ipairs(now) do labels[i] = spellLabel(e) end
        say("Ready to train (" .. #now .. "): " .. joinSome(labels, 8)
            .. (cost > 0 and (GREY .. " - " .. AskBot.Prices.Format(cost) .. "|r") or ""))
        if best then
            say("  " .. target.label .. ": " .. trainer)
            autoPin(best.place, best.spawn, target.label)
        end
    else
        say("Nothing new to train at level " .. level .. ".")
    end
    if nextLevel then
        local later = {}
        for _, e in pairs(t.spells) do
            if not e.used and e.level == nextLevel then later[#later + 1] = e end
        end
        table.sort(later, bySpell)
        local labels = {}
        for i, e in ipairs(later) do labels[i] = spellLabel(e) end
        say(GREY .. "  Next at level " .. nextLevel .. ":|r " .. joinSome(labels, 6))
    end
end
AskBot.RecordTraining, AskBot.LearnedSpell = recordTraining, learnedSpell

--------------------------------------------------------------------------------------------
-- Quest picks: XP per minute, and quests whose objectives share a spot
--------------------------------------------------------------------------------------------

-- Rough effort: seconds per kill, per click (objects, items you're handed), the chance a
-- quest item drops when Questie has no rate, and how close objectives count as one spot.
local KILL_TIME, CLICK_TIME, DROP_CHANCE, NEAR_YARDS = 30, 20, 0.4, 300

--- How many of `name` the quest's objective text asks for ("Gather 8 Wendigo Manes" -> 8), else 1.
local function objectiveCount(id, name)
    local texts = QuestDB.objectivesText and QuestDB.objectivesText(id)
    local text = (type(texts) == "table" and table.concat(texts, " ")) or (type(texts) == "string" and texts) or ""
    text = text:lower()
    -- The name's longest word, shortened a letter so plurals match ("mane" in "manes").
    local key = ""
    for w in (name or ""):lower():gmatch("%a+") do if #w > #key then key = w end end
    if #key < 3 then return 1 end
    local pos = text:find(key:sub(1, math.max(3, #key - 1)), 1, true)
    if not pos then return 1 end
    local n
    for d in text:sub(math.max(1, pos - 30), pos - 1):gmatch("(%d+)") do n = tonumber(d) end
    return n or 1
end

--- Seconds of work for one objective (from questObjectives), how many, and a verb.
local function objectiveWork(id, obj, logObjectives)
    local count = objectiveCount(id, obj[2])
    for _, lo in ipairs(logObjectives or {}) do
        if lo.text and lo.numRequired and lo.text:lower():find(obj[2]:lower(), 1, true) then
            count = math.max(0, lo.numRequired - (lo.numFulfilled or 0))
            break
        end
    end
    local verb, first = obj[1], obj[3][1]
    if count == 0 then return 0, 0 end
    if verb == "Kill" then return count * KILL_TIME, count, "kill" end
    if verb == "Collect" or verb == "Make" then
        if first and first.kind == "npc" and not first.via then return count / DROP_CHANCE * KILL_TIME, count, "loot" end
        return count * CLICK_TIME, count, "collect"
    end
    return CLICK_TIME, 1, verb:lower()
end

--- Rough seconds to do quest `id` from where you are: fetch it (unless it's in your log), go
--- to its objectives, do them, hand it in. Also a summary ("kill 10, loot 8") and the first
--- place to go. nil when Questie can't place it.
local function questEffort(id, inLog)
    local secs, first, here = 0, nil, nil
    if not inLog then
        local info = D.questInfo[id]
        local giver = info and D.Rank(placesForIds(info.npcs, info.objects, true))[1]
        if not (giver and giver.time) then return nil end
        secs, first, here = giver.time, giver, giver.spawn.point
    end
    local parts = {}
    if not (inLog and questComplete(id)) then
        local logObjectives = inLog and C_QuestLog and C_QuestLog.GetQuestObjectives and C_QuestLog.GetQuestObjectives(id)
        local places = {}
        for _, obj in ipairs(questObjectives(id)) do
            local work, count, verb = objectiveWork(id, obj, logObjectives)
            if count > 0 then
                secs = secs + work
                parts[#parts + 1] = verb .. (count > 1 and (" " .. count) or "")
                for _, p in ipairs(obj[3]) do places[#places + 1] = p end
            end
        end
        local spot = #places > 0 and D.Rank(places, here)[1]
        if spot and spot.time then
            secs = secs + spot.time
            first = first or spot
            here = spot.spawn.point
        end
    end
    local turnIn = D.Rank(turnInPlaces(id), here)[1]
    if turnIn and turnIn.time then
        secs = secs + turnIn.time
        first = first or turnIn
    end
    if not first then return nil end
    if #parts == 0 then parts[1] = inLog and "hand in" or "talk" end
    return secs, table.concat(parts, ", "), first
end

--- New quests near you (from the nearest givers) and the ones in your log, as { id, inLog }.
--- New quests more than 5 levels above you (red) are left out: besides being hard, most are
--- event or war-effort quests listed at level 60 that anyone can take, whose scaled XP looks huge.
local function nearbyCandidates(maxNew)
    local list = {}
    for _, q in ipairs(questLogEntries()) do list[#list + 1] = { id = q.id, inLog = true } end
    local n, maxLevel = 0, askerLevel() + 5
    for _, g in ipairs((questGivers(doableQuests()))) do
        for _, id in ipairs(g.quests) do
            if n >= maxNew then return list end
            if (QuestDB.questLevel(id) or 0) <= maxLevel then
                list[#list + 1] = { id = id }
                n = n + 1
            end
        end
    end
    return list
end

--- What a quest asks of you: "kill" (only kill mobs), "loot" (kill mobs and/or bring items
--- only mobs drop), or nil (anything else: objects, exploring, talking, items from elsewhere).
local function killKind(id)
    local o = QuestDB.objectives(id) or {}
    if (o[2] and #o[2] > 0) or (o[4] and #o[4] > 0) or (o[6] and #o[6] > 0) then return nil end
    if QuestDB.triggerEnd and QuestDB.triggerEnd(id) then return nil end
    local items = {}
    for _, c in ipairs(o[3] or {}) do items[c[1]] = true end
    for _, itemId in ipairs((QuestDB.requiredSourceItems and QuestDB.requiredSourceItems(id)) or {}) do
        if not items[itemId] then return nil end
    end
    local kills = (o[1] and #o[1] > 0) or (o[5] and #o[5] > 0)
    if not next(items) then return kills and "kill" or nil end
    for itemId in pairs(items) do
        local drops = ItemDB.npcDrops(itemId)
        if not (drops and #drops > 0) then return nil end
        local objs, sold = ItemDB.objectDrops(itemId), ItemDB.vendors(itemId)
        if (objs and #objs > 0) or (sold and #sold > 0) then return nil end
    end
    return "loot"
end

--- "kill only quests here" -> "kill"; "kill and loot quests" -> "loot"; else nil.
local function killQuestsQuestion(q)
    if not (q:find("quest", 1, true) and (q:find("kill", 1, true) or q:find("slay", 1, true))) then return nil end
    if q:find("loot", 1, true) or q:find("collect", 1, true) or q:find("drop", 1, true) then return "loot" end
    if q:find("kill only", 1, true) or q:find("killing only", 1, true) or q:find("only kill", 1, true)
        or q:find("kill quest", 1, true) or q:find("killing quest", 1, true) or q:find("slay quest", 1, true) then
        return "kill"
    end
end

--- Does quest `id` have a mob to kill (or one that drops its items) in zone map `zone`?
local function killsInZone(id, zone)
    local o = QuestDB.objectives(id) or {}
    local npcs = {}
    for _, c in ipairs(o[1] or {}) do npcs[#npcs + 1] = c[1] end
    for _, c in ipairs(o[5] or {}) do
        for _, npc in ipairs(type(c[1]) == "table" and c[1] or {}) do npcs[#npcs + 1] = npc end
    end
    for _, c in ipairs(o[3] or {}) do
        for _, npc in ipairs(ItemDB.npcDrops(c[1]) or {}) do npcs[#npcs + 1] = npc end
    end
    for _, npc in ipairs(npcs) do
        local p = D.NpcPlace(npc)
        for _, sp in ipairs(p and p.spawns or {}) do
            if sp.uiMapId == zone then return true end
        end
    end
    return false
end

--- Kill quests in the zone you're in: new ones whose giver is here, and ones in your log
--- with a mob to kill here.
local function answerKillQuests(mode)
    local function fits(id)
        local k = killKind(id)
        return k == "kill" or (mode == "loot" and k == "loot")
    end
    local what = mode == "loot" and "Kill and loot quests" or "Kill-only quests"
    local zone = currentZoneMap()
    if not zone then return say("I can't tell which zone you're in.") end
    local zoneName = D.ZoneName(zone) or "this zone"
    local ids = {}
    local doable = doableQuests()
    for _, id in ipairs(doable) do
        if fits(id) then ids[#ids + 1] = id end
    end
    local all = questGivers(ids)
    local list, count = {}, 0
    for _, g in ipairs(all) do
        if g.r.spawn and g.r.spawn.uiMapId == zone then
            list[#list + 1] = g
            count = count + #g.quests
        end
    end
    local mine = {}
    for _, q in ipairs(questLogEntries()) do
        if not questComplete(q.id) and fits(q.id) and killsInZone(q.id, zone) then mine[#mine + 1] = questLabel(q.id) end
    end
    if #list == 0 then
        say("No " .. what:lower() .. " to pick up in " .. zoneName .. ", as far as Questie knows.")
    else
        say(what .. " to pick up in " .. zoneName .. " (" .. count .. "), nearest first:")
        for i = 1, math.min(5, #list) do say("  " .. giverLine(list[i], 3)) end
    end
    if #mine > 0 then say("  In your log: " .. table.concat(mine, ", ")) end

    -- Coming up: ones given here that open within two levels or after an earlier quest.
    local level, inLog, soon = askerLevel(), {}, {}
    for _, q in ipairs(questLogEntries()) do inLog[q.id] = true end
    for id, info in pairs(D.questInfo) do
        local req = (info.req and info.req > 0) and info.req or info.level or 1
        if not inLog[id] and req <= level + 2 and (info.level or 0) <= level + 5 and fits(id)
            and forMyClass(id) and questForMe(id) then
            local status = questStatus(id, inLog)
            local why
            if status == "level" then
                why = "at " .. req
            elseif status == "locked" then
                local steps = missingSteps(id, inLog, {}, {}, 0)
                local before = steps[#steps - 1]
                if before then why = "after " .. (QuestDB.name(before) or ("quest " .. before)) end
            end
            local givenHere = false
            if why then
                for _, p in ipairs(placesForIds(info.npcs, info.objects, true)) do
                    for _, sp in ipairs(p.spawns) do
                        if sp.uiMapId == zone then givenHere = true; break end
                    end
                    if givenHere then break end
                end
            end
            if givenHere then soon[#soon + 1] = { id = id, req = req, why = why } end
        end
    end
    table.sort(soon, function(a, b) return a.req < b.req end)
    if #soon > 0 then
        local parts = {}
        for i = 1, math.min(4, #soon) do
            parts[i] = questLabel(soon[i].id) .. GREY .. " (" .. soon[i].why .. ")|r"
        end
        say("  " .. GREY .. "Coming up:|r " .. table.concat(parts, ", ") .. (#soon > 4 and (GREY .. " +" .. (#soon - 4) .. "|r") or ""))
    end

    -- Kill-only asked: how many more need mob drops too.
    if mode ~= "loot" then
        local loot = 0
        for _, id in ipairs(doable) do
            if killKind(id) == "loot" then
                local best = D.Rank(placesForIds(D.questInfo[id].npcs, D.questInfo[id].objects, true))[1]
                if best and best.spawn and best.spawn.uiMapId == zone then loot = loot + 1 end
            end
        end
        if loot > 0 then
            say("  " .. GREY .. "Also " .. loot .. " with mob drops to collect:|r "
                .. makeLink("kill and loot quests", function() AskBot.Ask("kill and loot quests") end))
        end
    end
    if list[1] then autoPin(list[1].r.place, list[1].r.spawn, "quests") end
end

--------------------------------------------------------------------------------------------
-- Quests you can finish with auction house items: "cost to complete [quest]", "reagent quests"
--------------------------------------------------------------------------------------------

--- The game's class ID, type name and bind type for an item (nil until the client caches it).
local function gameItemInfo(itemId)
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if not getInfo then return nil end
    local r = { getInfo(itemId) }
    if not r[1] and C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(itemId) end
    return r[12], r[6], r[14]
end

--- Can it be bought on the AH? Not quest items (class 12) or bind-on-pickup/quest-bound ones.
local function auctionable(itemId)
    local cls = ItemDB.class and ItemDB.class(itemId)
    local gameCls, _, bind = gameItemInfo(itemId)
    return (cls or gameCls) ~= 12 and bind ~= 1 and bind ~= 4
end

--- A crafting reagent: Trade Goods (class 7).
local function tradeGood(itemId)
    local cls = ItemDB.class and ItemDB.class(itemId)
    if cls then return cls == 7 end
    local gameCls, typeName = gameItemInfo(itemId)
    return gameCls == 7 or typeName == "Trade Goods"
end

--- A quest whose only objectives are items that mobs drop: "full" if the AH sells every one as a
--- trade good, "partial" if it sells some (Westfall Stew: three meats on the AH, Okra a quest item).
local function reagentQuest(id)
    local o = QuestDB.objectives(id) or {}
    if not (o[3] and #o[3] > 0) then return false end
    for _, i in ipairs({ 1, 2, 4, 5, 6 }) do
        if type(o[i]) == "table" and #o[i] > 0 then return false end
    end
    if QuestDB.triggerEnd and QuestDB.triggerEnd(id) then return false end
    local items, buyable = {}, 0
    for _, c in ipairs(o[3]) do
        local drops = ItemDB.npcDrops(c[1])
        if not (drops and #drops > 0) then return false end
        if tradeGood(c[1]) and auctionable(c[1]) then buyable = buyable + 1 end
        items[c[1]] = true
    end
    for _, itemId in ipairs((QuestDB.requiredSourceItems and QuestDB.requiredSourceItems(id)) or {}) do
        if not items[itemId] then return false end
    end
    if buyable == 0 then return false end
    return buyable == #o[3] and "full" or "partial"
end

--- Cheapest known price for one: the AH, or a vendor when Questie lists one and it's cheaper.
local function unitPrice(itemId)
    local P = AskBot.Prices
    if not P.Available() then return nil end
    local ah = P.Auction(itemId)
    local sold = ItemDB.vendors(itemId)
    local vendor = sold and #sold > 0 and P.VendorBuy(itemId)
    if vendor and (not ah or vendor <= ah) then return vendor, "vendor" end
    return ah
end

--- The items a quest asks for: { id, name, count, have, need, price, from, buyable }, and the
--- total cost of what's missing (nil if a missing item has no price).
local function questShopping(id)
    local o = QuestDB.objectives(id) or {}
    local logObjectives = C_QuestLog and C_QuestLog.GetQuestObjectives and C_QuestLog.GetQuestObjectives(id)
    local list, total = {}, 0
    for _, c in ipairs(o[3] or {}) do
        local itemId = c[1]
        local name = ItemDB.name(itemId) or ("item " .. itemId)
        local count = objectiveCount(id, name)
        for _, lo in ipairs(logObjectives or {}) do
            if lo.text and lo.numRequired and lo.text:lower():find(name:lower(), 1, true) then count = lo.numRequired; break end
        end
        local have = AskBot.Quests.bagCount(itemId, true)
        local e = { id = itemId, name = name, count = count, have = have, need = math.max(0, count - have),
            buyable = auctionable(itemId) }
        if e.buyable then e.price, e.from = unitPrice(itemId) end
        if e.need > 0 and e.buyable then -- quest items aren't counted: there's nothing to pay
            if e.price and total then total = total + e.price * e.need else total = nil end
        end
        list[#list + 1] = e
    end
    return list, total
end

--- "6 Linen Cloth" for what's still needed, then "(farm 3 Okra)" for what can't be bought.
local function shoppingText(list)
    local parts, farm = {}, {}
    for _, e in ipairs(list) do
        if e.need > 0 then
            local t = e.buyable and parts or farm
            t[#t + 1] = e.need .. " " .. e.name
        end
    end
    local text = #parts > 0 and table.concat(parts, ", ") or (#farm > 0 and "nothing to buy" or "you have them all")
    if #farm > 0 then text = text .. GREY .. " (farm " .. table.concat(farm, ", ") .. ")|r" end
    return text
end

--- Where to go: the giver (if it's not in your log yet) and the turn-in.
local function shoppingPlaces(id, inLog)
    local giver
    if not inLog then
        local info = D.questInfo[id]
        giver = info and D.Rank(placesForIds(info.npcs, info.objects, true))[1]
    end
    local turnIn = D.Rank(turnInPlaces(id))[1]
    if giver and turnIn and giver.place.name == turnIn.place.name then giver = nil end
    return giver, turnIn
end

local function placeText(r, label)
    return GOLD .. r.place.name .. "|r, " .. shortHow(r) .. " " .. pinLink(r.place, r.spawn, label)
end

--- "cost to complete [quest]": what's left to buy, at what price, and where to hand it in.
local function answerQuestCost(query, questId)
    local P = AskBot.Prices
    local id, inLog = resolveQuest(query, questId)
    if not id then return say("I couldn't find a quest called \"" .. tostring(query) .. "\".") end
    local o = QuestDB.objectives(id) or {}
    if not (o[3] and #o[3] > 0) then
        return say(questLabel(id) .. " doesn't ask for items, so there's nothing to buy.")
    end
    if questStatus(id, inLog) == "done" then return say("You've already done " .. questLabel(id) .. ".") end
    local list, total = questShopping(id)
    local xp = questXP(id)
    local head = questLabel(id) .. (xp and (GREY .. " (" .. xp .. "xp)|r") or "")
    local missing, lines = 0, {}
    for _, e in ipairs(list) do
        local have = e.have > 0 and (GREY .. " (have " .. e.have .. ")|r") or ""
        local text
        if e.need == 0 then
            text = e.name .. ": got all " .. e.count
        elseif not e.buyable then
            text = e.need .. " " .. e.name .. have .. ": can't be bought, it's a quest item"
        elseif e.price then
            text = e.need .. " " .. e.name .. have .. " x " .. P.Format(e.price)
                .. (e.from == "vendor" and (GREY .. " (vendor)|r") or P.BuyNote(e.id, e.price))
                .. " = " .. P.Format(e.price * e.need)
        else
            text = e.need .. " " .. e.name .. have .. ": " .. (P.Available() and "no AH price yet" or "no price (install Auctionator)")
        end
        if e.need > 0 then missing = missing + 1 end
        lines[#lines + 1] = text
    end
    local extra = ""
    for _, i in ipairs({ 1, 2, 4, 5, 6 }) do
        if type(o[i]) == "table" and #o[i] > 0 then extra = GREY .. " (plus objectives you can't buy)|r"; break end
    end
    if missing == 0 then
        say(head .. ": you have everything" .. extra .. ".")
    elseif #lines == 1 then
        say(head .. ": " .. lines[1] .. extra)
    else
        say(head .. (total and (": ~" .. P.Format(total) .. " to buy") or "") .. extra)
        for _, l in ipairs(lines) do say("  " .. l) end
    end
    local giver, turnIn = shoppingPlaces(id, inLog[id])
    if giver then say("  Get it from " .. placeText(giver, QuestDB.name(id))) end
    if turnIn then say("  Hand in: " .. placeText(turnIn, QuestDB.name(id))) end
    local first = giver or turnIn
    if first then autoPin(first.place, first.spawn, QuestDB.name(id)) end
end

--- "cost to complete X", "how much would it cost to finish X" -> "X".
local COST_VERBS = { complete = true, finish = true, ["do"] = true, buy = true }
local function costSubject(q)
    local verb, s = q:match("cost to (%a+) (.+)$")
    if not verb then verb, s = q:match("^how much to (%a+) (.+)$") end
    if not verb then verb, s = q:match("^price to (%a+) (.+)$") end
    if verb and COST_VERBS[verb] then return (s:gsub("^quest ", "")) end
end

--- Words beside a quest link that ask what it costs: "cost to complete", "how much to buy".
local function costWords(q)
    for w in q:gmatch("%a+") do
        if w == "cost" or w == "costs" or w == "price" then return true end
    end
    return q:find("how much to", 1, true) ~= nil
end

--- "what reagent quests are in my level range", "ah quests", "quests i can buy".
--- "log" anywhere ("ah quests in my log", "log ah quests") keeps it to your quest log.
local function reagentLogOnly(q)
    for x in q:gmatch("%a+") do if x == "log" then return true end end
    return false
end

local function reagentQuestsQuestion(q)
    local w = {}
    for x in q:gmatch("%a+") do w[x] = true end
    if not (w.quest or w.quests) then return false end
    return (w.reagent or w.reagents or w.ah or w.auction or w.buyable or (w.buy and w.quests)) and true or false
end

--- One list of what to buy for the first n quests: counts added up per item, what you hold
--- taken off once, priced each and in total.
local function sayShoppingList(rows, n)
    local P = AskBot.Prices
    local items, order = {}, {}
    for i = 1, n do
        for _, e in ipairs(rows[i].list) do
            local t = items[e.id]
            if not t then
                t = { name = e.name, count = 0, have = e.have, price = e.price, from = e.from, buyable = e.buyable }
                items[e.id] = t
                order[#order + 1] = e.id
            end
            t.count = t.count + e.count
        end
    end
    local lines, total, farm = {}, 0, {}
    for _, itemId in ipairs(order) do
        local t = items[itemId]
        local need = math.max(0, t.count - t.have)
        if need > 0 and not t.buyable then
            farm[#farm + 1] = need .. " " .. t.name
        elseif need > 0 then
            local have = t.have > 0 and (GREY .. " (have " .. t.have .. ")|r") or ""
            if t.price then
                lines[#lines + 1] = need .. " " .. t.name .. have .. " x " .. P.Format(t.price)
                    .. (t.from == "vendor" and (GREY .. " (vendor)|r") or P.BuyNote(itemId, t.price))
                    .. " = " .. P.Format(t.price * need)
                if total then total = total + t.price * need end
            else
                lines[#lines + 1] = need .. " " .. t.name .. have .. GREY .. " (no price)|r"
                total = nil
            end
        end
    end
    local these = n == 1 and "this quest" or ("these " .. n)
    if #lines == 0 then
        say("Nothing to buy for " .. these .. (#farm > 0 and "." or ": you have everything."))
    else
        say("To buy for " .. these .. (total and (", ~" .. P.Format(total) .. " in all") or "") .. ":")
        for _, l in ipairs(lines) do say("  " .. l) end
    end
    if #farm > 0 then say(GREY .. "  Farm yourself (not on the AH): " .. table.concat(farm, ", ") .. "|r") end
end

--- Quests you can take (or have) that only want mob-dropped items, some or all of them reagents
--- the AH sells: your log first, then the ones the AH covers fully, each best XP per gold first.
local function answerReagentQuests(logOnly)
    local P = AskBot.Prices
    local maxLevel = askerLevel() + 5 -- not the level-60 war-effort quests anyone can take
    local rows, seen = {}, {}
    local function add(id, inLog)
        local kind = not seen[id] and (QuestDB.questLevel(id) or 0) <= maxLevel and reagentQuest(id)
        if not kind then return end
        seen[id] = true
        local list, total = questShopping(id)
        local xp = questXP(id) or 0
        rows[#rows + 1] = { id = id, inLog = inLog, list = list, total = total, xp = xp,
            group = inLog and 1 or kind == "full" and 2 or 3,
            value = total and xp / math.max(total, 1) or -1 }
    end
    for _, q in ipairs(questLogEntries()) do
        if not questComplete(q.id) then add(q.id, true) end
    end
    if not logOnly then
        for _, id in ipairs(doableQuests()) do add(id, false) end
    end
    if #rows == 0 then
        if logOnly then return say("No quests in your log that the auction house can help with.") end
        return say("No quests near your level that only want reagents from the auction house, as far as Questie knows.")
    end
    table.sort(rows, function(a, b)
        if a.group ~= b.group then return a.group < b.group end
        if a.value ~= b.value then return a.value > b.value end
        return a.xp > b.xp
    end)
    say(logOnly and ("AH reagent quests in your log (" .. #rows .. "), best xp per gold first:")
        or ("AH reagent quests (" .. #rows .. "), your log first, then best xp per gold:"))
    local first
    for i = 1, math.min(6, #rows) do
        local r = rows[i]
        local cost = r.total and (r.total > 0 and (" ~" .. P.Format(r.total)) or "")
            or (GREY .. " (no price)|r")
        local giver, turnIn = shoppingPlaces(r.id, r.inLog)
        local where = ""
        if turnIn then where = " - hand in " .. placeText(turnIn, QuestDB.name(r.id)) end
        if giver then where = where .. GREY .. " (from " .. giver.place.name .. ")|r" end
        say("  " .. questLabel(r.id) .. (r.xp > 0 and (GREY .. " " .. r.xp .. "xp|r") or "")
            .. (r.inLog and not logOnly and (GREY .. " [in log]|r") or "") .. ": " .. shoppingText(r.list) .. cost .. where)
        first = first or giver or turnIn
    end
    sayShoppingList(rows, math.min(6, #rows))
    if not P.Available() then say(GREY .. "  Install Auctionator for prices.|r") end
    if first then autoPin(first.place, first.spawn, "quest") end
end

--- "best quests": quests near you and in your log, by XP per minute of rough effort.
local function bestQuestsQuestion(q)
    if q:find("how much", 1, true) then return false end
    local w = {}
    for x in q:gmatch("%a+") do w[x] = true end
    if not (w.quest or w.quests) then return q == "best xp" or q == "xp per minute" end
    return (w.xp or w.experience or w.efficient or w.quickest or w.fastest or w.best) and true or false
end

local function answerBestQuests()
    local rows = {}
    for _, c in ipairs(nearbyCandidates(25)) do
        local xp = questXP(c.id)
        local secs, summary, first = nil, nil, nil
        if xp then secs, summary, first = questEffort(c.id, c.inLog) end
        if secs then
            rows[#rows + 1] = { id = c.id, inLog = c.inLog, xp = xp, secs = math.max(secs, 60), summary = summary,
                first = first, tag = questTag(c.id) }
        end
    end
    if #rows == 0 then
        return say("I couldn't rate any quests near you (no XP data or locations for them).")
    end
    table.sort(rows, function(a, b)
        if (a.tag ~= nil) ~= (b.tag ~= nil) then return b.tag ~= nil end
        return a.xp / a.secs > b.xp / b.secs
    end)
    say("Best XP per minute near you (level " .. askerLevel() .. "):")
    for i = 1, math.min(6, #rows) do
        local r = rows[i]
        say("  " .. questLabel(r.id) .. " - " .. r.xp .. " xp, " .. formatTime(r.secs) .. " (" .. r.summary .. ")"
            .. (r.inLog and (GREY .. " in your log|r") or "") .. (r.tag and (" |cffff8040" .. r.tag .. "|r") or "")
            .. " " .. pinLink(r.first.place, r.first.spawn, QuestDB.name(r.id) or "quest"))
    end
    say(GREY .. "  Rough estimates: travel, ~30 s a kill, quest items dropping 40% of the time.|r")
    autoPin(rows[1].first.place, rows[1].first.spawn, QuestDB.name(rows[1].id) or "quest")
end

--- Resolved spawns where quest `id`'s objectives happen (at most 60, spread out).
local function objectiveSpawns(id)
    local all = {}
    for _, o in ipairs(questObjectives(id)) do
        for _, p in ipairs(o[3]) do
            if not p.via then
                for _, s in ipairs(p.spawns or {}) do
                    if s.wx then all[#all + 1] = s end
                end
            end
        end
    end
    if #all <= 60 then return all end
    local out, step = {}, #all / 60
    for i = 1, 60 do out[i] = all[math.floor((i - 1) * step) + 1] end
    return out
end

--- Closest yards between two spawn lists, or nil if none are on the same continent.
local function closestYards(a, b)
    local best
    for _, s in ipairs(a) do
        for _, t in ipairs(b) do
            if s.inst == t.inst then
                local d = D.SpawnDistance(s, t)
                if d and (not best or d < best) then best = d end
            end
        end
    end
    return best
end

--- Quests near you or in your log whose objectives are within NEAR_YARDS of quest `id`'s,
--- closest first: { id, inLog, yards }.
local function sameAreaQuests(id)
    local mine = objectiveSpawns(id)
    if #mine == 0 then return {} end
    local out = {}
    for _, c in ipairs(nearbyCandidates(40)) do
        if c.id ~= id then
            local d = closestYards(mine, objectiveSpawns(c.id))
            if d and d <= NEAR_YARDS then c.yards = d; out[#out + 1] = c end
        end
    end
    table.sort(out, function(a, b) return a.yards < b.yards end)
    return out
end

local answerQuestsNear

--- One line for a quest answer: "Same area: [11] Stocking Jetsteam, [12] ... [list]", or nil.
local function sameAreaLine(id)
    if AskBot.asker then return nil end
    local list = sameAreaQuests(id)
    if #list == 0 then return nil end
    local labels = {}
    for i, c in ipairs(list) do labels[i] = questLabel(c.id) end
    return GREY .. "  Same area:|r " .. joinSome(labels, 3) .. " "
        .. makeLink("list", function() answerQuestsNear(nil, id) end)
end

--- "quests near The Grizzled Den": quests to take (or already have) with objectives in the
--- same spot, each with its XP and where to get it.
function answerQuestsNear(query, questId)
    local id = questId or resolveQuest(query)
    if not id then return say("I couldn't find a quest called \"" .. tostring(query) .. "\".") end
    local name = QuestDB.name(id) or ("quest " .. id)
    if #objectiveSpawns(id) == 0 then
        if #questObjectives(id) == 0 then
            return say(GOLD .. name .. "|r has nothing to do out in the world (talk or deliver), so nothing shares its spot.")
        end
        return say("Questie doesn't place " .. GOLD .. name .. "|r's objectives, so I can't tell what's near them.")
    end
    local list = sameAreaQuests(id)
    if #list == 0 then return say("No other quests you can do have objectives near " .. GOLD .. name .. "|r.") end
    say("Quests with objectives near " .. GOLD .. name .. "|r:")
    for i = 1, math.min(6, #list) do
        local c = list[i]
        local xp = questXP(c.id)
        local where
        if c.inLog then
            where = GREY .. "in your log|r"
        else
            local info = D.questInfo[c.id]
            local giver = info and D.Rank(placesForIds(info.npcs, info.objects, true))[1]
            where = giver and (GREY .. "from|r " .. GOLD .. giver.place.name .. "|r, " .. shortHow(giver) .. " "
                .. pinLink(giver.place, giver.spawn, QuestDB.name(c.id) or "quest")) or GREY .. "giver unknown|r"
        end
        say("  " .. questLabel(c.id) .. (xp and (" - " .. xp .. " xp") or "") .. ", " .. where)
    end
    if #list > 6 then say(GREY .. "  ...and " .. (#list - 6) .. " more.|r") end
end

-- "quests near X" (not "quests near me", which is "quests here").
local NEAR_PATTERNS = { "^quests near (.+)$", "^quests around (.+)$", "^quests close to (.+)$",
    "^other quests near (.+)$", "^what else is near (.+)$", "^what else is around (.+)$",
    "^what else can i do near (.+)$", "^what else can i do with (.+)$", "^what goes with (.+)$",
    "^quests to do with (.+)$", "^quests that go with (.+)$", "^what can i do with (.+)$" }
local NOT_A_QUEST = { me = true, here = true, you = true, us = true, xp = true }
local function questsNearSubject(q)
    for _, pattern in ipairs(NEAR_PATTERNS) do
        local s = q:match(pattern)
        if s and not NOT_A_QUEST[s] then return s end
    end
end

--------------------------------------------------------------------------------------------
-- Quests that take you somewhere: "what quests take me to Ironforge"
--------------------------------------------------------------------------------------------

local TO_PATTERNS = { "^what quests take me to (.+)$", "^which quests take me to (.+)$", "^quests that take me to (.+)$",
    "^quests taking me to (.+)$", "^what quests send me to (.+)$", "^which quests send me to (.+)$",
    "^quests that send me to (.+)$", "^what quests go to (.+)$", "^which quests go to (.+)$", "^quests that go to (.+)$",
    "^any quests that take me to (.+)$", "^any quests to (.+)$", "^quests to (.+)$" }
-- (Not "what quests are in X": that means a dungeon, "what quests are in Deadmines".)
local function questsToSubject(q)
    for _, pattern in ipairs(TO_PATTERNS) do
        local s = q:match(pattern)
        if s then return (s:gsub("^the ", "")) end
    end
end

--- Does the zone on `uiMapId` go by `key` (a NameKey)? "ironforge", "stormwind" (City), "stv"...
local zoneMatch = {}
local function zoneIs(uiMapId, key)
    local cacheKey = uiMapId .. "|" .. key
    if zoneMatch[cacheKey] == nil then
        local name = D.NameKey(D.ZoneName(uiMapId))
        zoneMatch[cacheKey] = name == key or name:sub(1, #key + 1) == key .. " "
    end
    return zoneMatch[cacheKey]
end

--- The first spawn of `places` in a zone matching `key`, or nil.
local function spawnIn(places, key)
    for _, p in ipairs(places) do
        for _, s in ipairs(p.spawns or {}) do
            if s.uiMapId and zoneIs(s.uiMapId, key) then return p, s end
        end
    end
end

--------------------------------------------------------------------------------------------
-- "quickest route to Loch Modan": travel to a zone
--------------------------------------------------------------------------------------------

local ROUTE_PATTERNS = {
    "^quickest route to (.+)$", "^fastest route to (.+)$", "^best route to (.+)$", "^route to (.+)$",
    "^quickest way to (.+)$", "^fastest way to (.+)$", "^best way to (.+)$", "^how do i get to (.+)$",
    "^how to get to (.+)$", "^how do i go to (.+)$", "^how do i travel to (.+)$", "^directions to (.+)$",
    "^take me to (.+)$", "^travel to (.+)$", "^way to (.+)$", "^go to (.+)$",
}

--- Where to aim for in a zone: its friendly flight masters (the town), else its innkeepers,
--- else quest givers there. Returns the places and the zone's map ID, or nil.
local function zoneDestinations(key)
    local mine = D.PlayerFaction()
    for _, target in ipairs({ "flight", "inn" }) do
        local out, map = {}, nil
        for _, p in ipairs(D.byTarget[target] or {}) do
            if D.IsFriendly(p, mine) then
                for _, s in ipairs(p.spawns or {}) do
                    if s.uiMapId and zoneIs(s.uiMapId, key) then
                        out[#out + 1] = { kind = p.kind, id = p.id, name = p.name, sub = p.sub, spawns = { s } }
                        map = map or s.uiMapId
                        break
                    end
                end
            end
        end
        if #out > 0 then return out, map, target end
    end
    local out, map, seen = {}, nil, {}
    for _, info in pairs(D.questInfo) do
        for _, npc in ipairs(info.npcs or {}) do
            if not seen[npc] then
                seen[npc] = true
                local p = D.NpcPlace(npc)
                if p and D.IsFriendly(p, mine) then
                    for _, s in ipairs(p.spawns or {}) do
                        if s.uiMapId and zoneIs(s.uiMapId, key) then
                            out[#out + 1] = { kind = p.kind, id = p.id, name = p.name, sub = p.sub, spawns = { s } }
                            map = map or s.uiMapId
                            break
                        end
                    end
                end
            end
        end
        if #out >= 10 then break end
    end
    if #out > 0 then return out, map, "quest" end
end

--- The zone a route question names (only when it is a zone you can get to), or nil.
local function routeSubject(q)
    for _, pattern in ipairs(ROUTE_PATTERNS) do
        local s = q:match(pattern)
        if s then
            s = s:gsub("^get to ", ""):gsub("^go to ", ""):gsub("^the ", ""):gsub(" from here$", ""):gsub(" now$", "")
            if zoneDestinations(D.NameKey(s)) then return s end
            return nil
        end
    end
end

local function answerRouteTo(subject)
    local places, map, kind = zoneDestinations(D.NameKey(subject))
    local zoneName = D.ZoneName(map)
    local r = D.Rank(places)[1]
    if not r or not r.time then
        return say("I can't work out a way to " .. GOLD .. zoneName .. "|r from here.")
    end
    local steps = r.steps or {}
    local route = #steps > 0 and D.RouteText(steps) or (r.dist and ("ride " .. formatTime(r.time))) or ""
    say("Quickest way to " .. GOLD .. zoneName .. "|r, " .. formatTime(r.time) .. ":")
    local known = AskBotCharDB and AskBotCharDB.knownTaxi
    local notLearned = kind == "flight" and known and next(known) and not known[r.place.id]
    say("  " .. (route ~= "" and (route .. " - ") or "") .. GOLD .. r.place.name .. "|r "
        .. (r.place.sub and (GREY .. "<" .. r.place.sub .. ">|r ") or "")
        .. pinLink(r.place, r.spawn, zoneName)
        .. (notLearned and (GREY .. " (flight path not learned yet: talk to them when you arrive)|r") or ""))
    autoPin(r.place, r.spawn, zoneName)
end

--- Does quest `id` take you to the zone `key`: its turn-in there, or an objective whose nearest
--- source is there? Returns what you'd do ("hand in to X", "kill Y", "buy Z") and the spawn.
--- Only where you'd actually go: Shiny Baubles are sold in Ironforge, but also in Kharanos.
local function destinationIn(id, key)
    local p, s = spawnIn(turnInPlaces(id), key)
    if p then return "hand in to " .. GOLD .. (p.name or "?") .. "|r", s end
    for _, obj in ipairs(questObjectives(id)) do
        local best = #obj[3] > 0 and D.Rank(obj[3])[1]
        if best and best.spawn and best.spawn.uiMapId and zoneIs(best.spawn.uiMapId, key) then
            local verb = best.place.via == "sells it" and "buy" or obj[1]:lower()
            return verb .. " " .. GOLD .. obj[2] .. "|r", best.spawn
        end
    end
end

--- Quests near you that will take you to the zone once open: for your race and class, not
--- done, needing at most 2 more levels or an earlier quest. { id, why = "at 10" / "after X" }
local SOON_LEVELS = 2
local function comingUpTo(key, skip)
    local level = askerLevel()
    local inLog = {}
    for _, q in ipairs(questLogEntries()) do inLog[q.id] = true end
    local out = {}
    for id, info in pairs(D.questInfo) do
        local req = (info.req and info.req > 0) and info.req or info.level or 1
        if not skip[id] and not inLog[id] and req <= level + SOON_LEVELS and (info.level or 0) <= level + 5
            and forMyClass(id) and questForMe(id) then
            local status = questStatus(id, inLog)
            local why
            if status == "level" then
                why = "at " .. req
            elseif status == "locked" then
                local steps = missingSteps(id, inLog, {}, {}, 0)
                local before = steps[#steps - 1] -- the quest right before this one
                if before then why = "after " .. (QuestDB.name(before) or ("quest " .. before)) end
            end
            if why then
                local givers = placesForIds(info.npcs, info.objects, true)
                local giver = not spawnIn(givers, key) and D.Rank(givers)[1]
                if giver and giver.dist and destinationIn(id, key) then
                    out[#out + 1] = { id = id, why = why, time = giver.time or math.huge }
                end
            end
        end
    end
    table.sort(out, function(x, y) return x.time < y.time end)
    return out
end

--- Quests you have or can take (not given in that zone) whose objectives or turn-in are in a
--- zone, then the ones near you that open up soon.
local function answerQuestsTo(subject)
    local key = D.NameKey(subject)
    local found, zoneName, seen = {}, nil, {}
    local cands = {}
    for _, q in ipairs(questLogEntries()) do cands[#cands + 1] = { id = q.id, inLog = true } end
    local maxLevel = askerLevel() + 5
    for _, id in ipairs(doableQuests()) do
        if (QuestDB.questLevel(id) or 0) <= maxLevel then cands[#cands + 1] = { id = id } end
    end
    for _, c in ipairs(cands) do
        if not seen[c.id] then
            seen[c.id] = true
            local info = D.questInfo[c.id]
            local givers = info and placesForIds(info.npcs, info.objects, true) or {}
            -- New quests handed out in that zone don't take you there: you'd already be there.
            if c.inLog or not spawnIn(givers, key) then
                local why, s = destinationIn(c.id, key)
                if why then
                    zoneName = zoneName or D.ZoneName(s.uiMapId)
                    c.why = why
                    if not c.inLog then c.giver = D.Rank(givers)[1] end
                    found[#found + 1] = c
                end
            end
        end
    end
    local soon = comingUpTo(key, seen)
    if not zoneName and soon[1] then
        local _, s = destinationIn(soon[1].id, key)
        zoneName = s and D.ZoneName(s.uiMapId)
    end
    if #found == 0 and #soon == 0 then
        return say("None of your quests, or ones you can pick up, take you to \"" .. subject .. "\""
            .. GREY .. " (or I don't know a zone by that name).|r")
    end
    if #found == 0 then
        say("None of the quests you can pick up now take you to " .. GOLD .. (zoneName or subject) .. "|r.")
    else
        table.sort(found, function(x, y)
            if x.inLog ~= y.inLog then return x.inLog == true end
            local xt, yt = x.giver and x.giver.time, y.giver and y.giver.time
            if xt and yt then return xt < yt end
            return xt ~= nil
        end)
        say("Quests that take you to " .. GOLD .. zoneName .. "|r (" .. #found .. "):")
        for i = 1, math.min(6, #found) do
            local c = found[i]
            local xp = questXP(c.id)
            local where
            if c.inLog then
                where = GREY .. "in your log|r"
            elseif c.giver then
                where = GREY .. "from|r " .. GOLD .. c.giver.place.name .. "|r, " .. shortHow(c.giver) .. " "
                    .. pinLink(c.giver.place, c.giver.spawn, QuestDB.name(c.id) or "quest")
            else
                where = GREY .. "giver unknown|r"
            end
            say("  " .. questLabel(c.id) .. (xp and (GREY .. " " .. xp .. "xp|r") or "") .. ": " .. c.why .. "; " .. where)
        end
        if #found > 6 then say(GREY .. "  ...and " .. (#found - 6) .. " more.|r") end
    end
    if #soon > 0 then
        local labels = {}
        for i, c in ipairs(soon) do labels[i] = questLabel(c.id) .. GREY .. " (" .. c.why .. ")|r" end
        say(GREY .. "  Coming up:|r " .. joinSome(labels, 4))
    end
end

--------------------------------------------------------------------------------------------
-- Rogue lockpicking quests
--------------------------------------------------------------------------------------------

-- Rogue class quests with a locked box to open (Questie has no lockpicking tag, so by ID):
-- Alther's Mill (Lucius's Lockbox), Tools of the Trade (Ambermill Strongbox), Plundering the
-- Plunderers (Southsea treasure), Klaven's Tower (Duskwood Chest), Mission: Possible But Not
-- Probable (Gallywix's Lockbox). questForMe leaves out the other faction's and races'.
Levelling.LOCKPICK_QUESTS = { 2282, 1999, 2381, 2359, 2478 }

--- "rogue lockpicking quests", "pick lock quests", "lock picking quests".
function Levelling.lockpickQuestsQuestion(q)
    if not (q:find("quest", 1, true)) then return false end
    return (q:find("lockpick", 1, true) or q:find("lock pick", 1, true) or q:find("pick lock", 1, true)
        or q:find("picklock", 1, true)) ~= nil
end

function Levelling.answerLockpickQuests()
    if AskBot.asker then return say("That depends on which quests you've done, so it needs your own AskBot.") end
    local inLog = {}
    for _, q in ipairs(questLogEntries()) do inLog[q.id] = true end
    local mine = {}
    for _, id in ipairs(Levelling.LOCKPICK_QUESTS) do
        if QuestDB.name(id) and questForMe(id) then mine[#mine + 1] = id end
    end
    table.sort(mine, function(a, b) return (QuestDB.questLevel(a) or 0) < (QuestDB.questLevel(b) or 0) end)
    if #mine == 0 then return say("I don't know any lockpicking quests for your faction.") end
    say("Rogue lockpicking quests" .. (askerClass() ~= "ROGUE" and (GREY .. " (rogues only)|r") or "") .. ":")
    local firstPin
    for _, id in ipairs(mine) do
        local status = questStatus(id, inLog)
        local line
        if status == "done" or status == "inLog" then
            line = AskBot.Quests.stepText(id, status)
        else
            -- The first quest still to do in its chain (it may be this one).
            local first = missingSteps(id, inLog, {}, {}, 0)[1]
            local st = first == id and status or questStatus(first, inLog)
            line = (first ~= id and ("first " .. questLabel(first) .. ": ") or "")
                .. (st == "locked" and (GREY .. "not available to you yet|r") or AskBot.Quests.stepText(first, st))
            if not firstPin and st == "ready" then
                local _, best = AskBot.Quests.giverText(first)
                if best then firstPin = { best = best, name = QuestDB.name(first) } end
            end
        end
        say("  " .. questLabel(id) .. " - " .. line)
    end
    if firstPin then autoPin(firstPin.best.place, firstPin.best.spawn, firstPin.name) end
end

-- For the files loaded after this one.
Levelling.answerQuestLog, Levelling.doableQuests = answerQuestLog, doableQuests
Levelling.answerQuestsHere, Levelling.currentZoneMap = answerQuestsHere, currentZoneMap
Levelling.answerZones, Levelling.answerWhereToQuest = answerZones, answerWhereToQuest
Levelling.answerDungeons, Levelling.answerPlan, Levelling.answerTidy = answerDungeons, answerPlan, answerTidy
Levelling.answerHandInRoute, Levelling.answerRares = answerHandInRoute, answerRares
Levelling.answerGroup, Levelling.answerPerson = answerGroup, answerPerson
Levelling.HEARTH_QUESTIONS, Levelling.answerHearth = HEARTH_QUESTIONS, answerHearth
Levelling.trainingQuestion, Levelling.answerTraining = trainingQuestion, answerTraining
Levelling.bestQuestsQuestion, Levelling.answerBestQuests = bestQuestsQuestion, answerBestQuests
Levelling.killQuestsQuestion, Levelling.answerKillQuests = killQuestsQuestion, answerKillQuests
Levelling.costSubject, Levelling.costWords, Levelling.answerQuestCost = costSubject, costWords, answerQuestCost
Levelling.reagentQuestsQuestion, Levelling.answerReagentQuests = reagentQuestsQuestion, answerReagentQuests
Levelling.reagentLogOnly = reagentLogOnly
Levelling.routeSubject, Levelling.answerRouteTo = routeSubject, answerRouteTo
Levelling.questsNearSubject, Levelling.answerQuestsNear = questsNearSubject, answerQuestsNear
Levelling.sameAreaLine = sameAreaLine
Levelling.questsToSubject, Levelling.answerQuestsTo = questsToSubject, answerQuestsTo
