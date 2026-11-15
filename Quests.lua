-- Quests.lua
-- Quest, item, NPC, loot and price answers: quest log and objectives, item sources, group quest
-- progress, quest chains, dungeon prep, reputation quests and quest starters.

local _, AskBot = ...
local D = AskBot.Data
local Out = AskBot.Out
local Quests = {}
AskBot.Quests = Quests
local GOLD, GREY, say, askerLevel = Out.GOLD, Out.GREY, Out.say, Out.askerLevel
local captureForMap, autoPin, makeLink, pinLink = Out.captureForMap, Out.autoPin, Out.makeLink, Out.pinLink
local whereText, shortHow, formatRate, describe = Out.whereText, Out.shortHow, Out.formatRate, Out.describe
local showRanked, pinBest, didYouMean = Out.showRanked, Out.pinBest, Out.didYouMean

local dropRateNoteShown = false

--------------------------------------------------------------------------------------------
-- Answers
--------------------------------------------------------------------------------------------

--- XP quest `id` gives you (Questie's Forever XP table, scaled to your level), or nil.
local function questXP(id)
    local QuestXP = QuestieLoader and QuestieLoader:ImportModule("QuestXP")
    if not (QuestXP and QuestXP.GetQuestLogRewardXP) then return nil end
    local ok, xp = pcall(QuestXP.GetQuestLogRewardXP, QuestXP, id)
    return ok and type(xp) == "number" and xp > 0 and xp or nil
end

local function friendlyPlaces(list)
    local mine = D.PlayerFaction()
    local out = {}
    for _, p in ipairs(list or {}) do
        if D.IsFriendly(p, mine) then out[#out + 1] = p end
    end
    return out
end

local function answerTarget(target)
    local places = friendlyPlaces(D.byTarget[target.id])
    if #places == 0 then
        say("I couldn't find a " .. target.label .. " friendly to you.")
        return
    end
    local best = showRanked(places, "Nearest " .. target.label .. ":", target.label, AskBot.Option("maxResults"))
    pinBest(best, target.label)
end

local function placesForIds(npcIds, objectIds, friendlyOnly)
    local mine = D.PlayerFaction()
    local out, seen = {}, {}
    for _, id in ipairs(npcIds or {}) do
        local p = not seen["n" .. id] and D.NpcPlace(id)
        seen["n" .. id] = true
        if p and #p.spawns > 0 and (not friendlyOnly or D.IsFriendly(p, mine)) then out[#out + 1] = p end
    end
    for _, id in ipairs(objectIds or {}) do
        local p = not seen["o" .. id] and D.ObjectPlace(id)
        seen["o" .. id] = true
        if p and #p.spawns > 0 then out[#out + 1] = p end
    end
    return out
end

local function questAvailable(id)
    local races = QuestDB.requiredRaces(id)
    if not races or races == 0 then return true end
    local masks = LibQuestieDB.Enum.factionRaceMasks
    local mask = masks and masks[UnitFactionGroup("player") or ""]
    return not mask or D.MasksOverlap(races, mask)
end

local function itemName(id)
    return ItemDB.name(id) or (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)) or ("item " .. id)
end

--------------------------------------------------------------------------------------------
-- Quests in the player's log: objectives and turn-in
--------------------------------------------------------------------------------------------

local function questInLog(id)
    if C_QuestLog and C_QuestLog.GetLogIndexForQuestID then
        return C_QuestLog.GetLogIndexForQuestID(id) ~= nil
    end
    if GetQuestLogIndexByID then
        local i = GetQuestLogIndexByID(id)
        return i ~= nil and i > 0
    end
    return false
end

local function questComplete(id)
    if C_QuestLog and C_QuestLog.IsComplete then return C_QuestLog.IsComplete(id) end
    if IsQuestComplete then return IsQuestComplete(id) end
    return false
end

-- Lower-cased text of the objectives the game says are finished ("defias thug slain: 15/15").
local function finishedObjectiveTexts(id)
    local out = {}
    local objectives = C_QuestLog and C_QuestLog.GetQuestObjectives and C_QuestLog.GetQuestObjectives(id)
    for _, o in ipairs(objectives or {}) do
        if o.finished and o.text then out[#out + 1] = o.text:lower() end
    end
    return out
end

--- The quest's objectives as { verb, name, places, showLevel }.
--- Where an item comes from: Questie's drops, else items that contain it, else AskBot's
--- community locations. Returns places and whether they are community info.
local function anyCommunity(places)
    for _, p in ipairs(places) do if p.community then return true end end
    return false
end

--- Places for NPCs and objects, for one quest (`questId` may be nil): community locations
--- from KnownLocations.lua replace Questie's for that quest, and fill in NPCs Questie has no
--- spawns for. Community places carry `community = true`.
local function questPlaces(questId, npcIds, objectIds, friendlyOnly)
    local quest = questId and AskBot.KNOWN.quests[questId]
    local overrides = quest and quest.npcs or {}
    local out, plain = {}, {}
    for _, id in ipairs(npcIds or {}) do
        local p = overrides[id] and D.KnownPlace(overrides[id], NpcDB.name(id))
        if not p and AskBot.KNOWN.npcs[id] then
            local np = D.NpcPlace(id)
            if np and #np.spawns == 0 then p = D.KnownPlace(AskBot.KNOWN.npcs[id], np.name) end
        end
        if p then
            p.community = true
            out[#out + 1] = p
        else
            plain[#plain + 1] = id
        end
    end
    for _, p in ipairs(placesForIds(plain, objectIds, friendlyOnly)) do out[#out + 1] = p end
    return out
end

--- Where to hand a quest in: Questie's turn-in, else a community one.
local function turnInPlaces(questId)
    local who = QuestDB.finishedBy(questId) or {}
    local places = questPlaces(questId, who[1], who[2])
    local quest = AskBot.KNOWN.quests[questId]
    if #places == 0 and quest and quest.turnIn then
        local p = D.KnownPlace(quest.turnIn)
        if p then
            p.community = true
            places[1] = p
        end
    end
    return places
end

--- Friendly NPCs from quests' givers (`field` = "startedBy") or turn-ins ("finishedBy"),
--- each copied with `via` text, e.g. "reward for The Symbol of Life".
local function questNpcPlaces(questIds, field, viaText, out)
    for _, q in ipairs(questIds or {}) do
        local who = QuestDB[field](q) or {}
        for _, p in ipairs(placesForIds(who[1], who[2], true)) do
            local copy = {}
            for k, v in pairs(p) do copy[k] = v end
            copy.via = viaText .. " " .. (QuestDB.name(q) or "?")
            out[#out + 1] = copy
        end
    end
    return out
end

--- Where to get an item, for a quest (`questId` may be nil). Returns the places and whether
--- they're community info. Order: this quest's community location, Questie's drops (and the
--- containers it comes in), a community location, then the quests that reward or hand it out.
local function itemSources(itemId, questId)
    local quest = questId and AskBot.KNOWN.quests[questId]
    local override = quest and quest.items and quest.items[itemId]
    local place = D.KnownPlace(override or AskBot.KNOWN.items[itemId], itemName(itemId))
    if place then return { place }, true end

    local drops = questPlaces(questId, ItemDB.npcDrops(itemId), ItemDB.objectDrops(itemId))
    if #drops > 0 then return drops, anyCommunity(drops) end
    for _, container in ipairs(ItemDB.itemDrops(itemId) or {}) do
        for _, p in ipairs(questPlaces(questId, ItemDB.npcDrops(container), ItemDB.objectDrops(container))) do
            drops[#drops + 1] = p
        end
    end
    if #drops > 0 then return drops, anyCommunity(drops) end

    for _, p in ipairs(placesForIds(ItemDB.vendors and ItemDB.vendors(itemId), nil, true)) do
        local copy = {}
        for k, v in pairs(p) do copy[k] = v end
        copy.via = "sells it"
        drops[#drops + 1] = copy
    end
    if #drops > 0 then return drops, false end

    -- Quest items: who rewards it, or hands it out (ask them again if you lost it).
    questNpcPlaces(ItemDB.questRewards and ItemDB.questRewards(itemId), "finishedBy", "reward for", drops)
    questNpcPlaces(D.givenBy[itemId], "startedBy", "given with", drops)
    return drops, false
end

--- How many of an item are in your bags.
--- How many of an item you carry; includeBank counts the bank too.
local function bagCount(itemId, includeBank)
    if not itemId then return 0 end
    local count = (C_Item and C_Item.GetItemCount) or GetItemCount
    return count and (count(itemId, includeBank) or 0) or 0
end

local function questObjectives(id)
    local list = {}
    local o = QuestDB.objectives(id) or {}

    -- Items the quest needs you to bring (e.g. two halves to combine into the objective item).
    -- One you're carrying shows as "Got"; the rest get directions.
    -- Community steps Questie doesn't have ("use the moondust at the Moonkin Stone") come first.
    local known = AskBot.KNOWN.quests[id]
    for _, step in ipairs(known and known.steps or {}) do
        local p = D.KnownPlace(step)
        if p then list[#list + 1] = { "Do", step.note, { p }, false, true } end
    end

    local objectiveItems = {}
    for _, c in ipairs(o[3] or {}) do objectiveItems[c[1]] = true end
    local sourceItems = QuestDB.requiredSourceItems and QuestDB.requiredSourceItems(id) or {}
    local needsSources = false
    for _, itemId in ipairs(sourceItems) do
        if not objectiveItems[itemId] then
            needsSources = true
            if bagCount(itemId) > 0 then
                list[#list + 1] = { "Got", itemName(itemId), {}, false, false, true, true }
            else
                local places, community = itemSources(itemId, id)
                list[#list + 1] = { "Collect", itemName(itemId), places, true, community, false, true }
            end
        end
    end

    for _, c in ipairs(o[1] or {}) do -- creatures to kill
        local p = D.NpcPlace(c[1])
        if p then
            local places = questPlaces(id, { c[1] })
            list[#list + 1] = { "Kill", c[2] or p.name, places, true, anyCommunity(places) }
        end
    end
    for _, c in ipairs(o[2] or {}) do -- objects to use
        local p = D.ObjectPlace(c[1])
        if p then list[#list + 1] = { "Use", c[2] or p.name, placesForIds(nil, { c[1] }) } end
    end
    for _, c in ipairs(o[3] or {}) do -- items to collect
        local places, community = itemSources(c[1], id)
        -- With items to bring, the objective item is made from them ("Make X at: shrine").
        list[#list + 1] = { needsSources and "Make" or "Collect", c[2] or itemName(c[1]), places, true, community }
    end
    for _, c in ipairs(o[5] or {}) do -- kill credit (any of several NPCs counts)
        local places = questPlaces(id, c[1])
        list[#list + 1] = { "Kill", c[3] or NpcDB.name(c[2]) or "target", places, true, anyCommunity(places) }
    end
    local trigger = QuestDB.triggerEnd(id) -- "explore X" style objectives
    if trigger and trigger[1] then
        local spawns = D.ResolveSpawns(trigger[2])
        list[#list + 1] = { "Go to", trigger[1], #spawns > 0 and { { kind = "area", name = trigger[1], spawns = spawns } } or {} }
    end
    -- Questie's hidden "extra" objectives: places to use an item, talk, look around...
    local extras = QuestDB.extraObjectives and QuestDB.extraObjectives(id)
    for _, e in ipairs(type(extras) == "table" and extras or {}) do
        local spawns = type(e[1]) == "table" and D.ResolveSpawns(e[1]) or {}
        if #spawns > 0 and e[3] then
            list[#list + 1] = { "Do", e[3], { { kind = "area", name = e[3], spawns = spawns } } }
        end
    end
    return list
end

--- Sort helper: ranked results by travel time, unknown times last.
local function quicker(a, b)
    if a.time and b.time then return a.time < b.time end
    return a.time ~= nil and b.time == nil
end

--- What's left to do for a quest in the log: complete?, unfinished objectives
--- ({ verb, name, best = ranked result or nil, showLevel }), and the turn-in result.
local function questTasks(id)
    local complete = questComplete(id)
    local objectives = {}
    if not complete then
        local done = finishedObjectiveTexts(id)
        for _, obj in ipairs(questObjectives(id)) do
            local objName = obj[2]
            local finished = false
            for _, t in ipairs(done) do
                if t:find(objName:lower(), 1, true) then finished = true; break end
            end
            if not finished then
                objectives[#objectives + 1] = {
                    verb = obj[1], name = objName, showLevel = obj[4], community = obj[5], have = obj[6], source = obj[7],
                    best = #obj[3] > 0 and D.Rank(obj[3])[1] or nil,
                }
            end
        end
    end
    -- While an item to bring is still missing, making the objective item comes later.
    local waiting = false
    for _, o in ipairs(objectives) do
        if o.source and not o.have then waiting = true end
    end
    for _, o in ipairs(objectives) do
        if waiting and o.verb == "Make" then o.later = true end
    end
    return complete, objectives, D.Rank(turnInPlaces(id))[1]
end

--- "Collect Linen Cloth from: Defias Thug lvl 9-10 - Westfall ... [pin]"
local function objectiveText(o)
    if o.have then return "|cff66cc33Got|r " .. GOLD .. o.name .. "|r" end
    if o.verb == "Make" and o.best then
        return "Then make " .. GOLD .. o.name .. "|r at: " .. describe(o.best, o.name)
    end
    if not o.best then
        return o.verb .. " " .. GOLD .. o.name .. "|r " .. GREY .. "(Questie doesn't know where)|r"
    end
    local prefix = o.verb == "Collect" and ("Collect " .. GOLD .. o.name .. "|r from: ") or (o.verb .. ": ")
    local via = o.best.place.via and (GREY .. " (" .. o.best.place.via .. ")|r") or ""
    return prefix .. describe(o.best, o.name, o.showLevel) .. via .. (o.community and (GREY .. " (community info)|r") or "")
end

--------------------------------------------------------------------------------------------
-- Group quest progress, from Questie's party sync (members who run Questie share their log)
--------------------------------------------------------------------------------------------

local function questieComms()
    local comms = QuestieLoader and QuestieLoader:ImportModule("QuestieComms")
    return comms and comms.GetQuest and comms or nil
end

--- "2/6", "2/6 0/1", or green "ready" when every objective is done.
local function progressText(objectives)
    local parts, all = {}, true
    for _, o in pairs(type(objectives) == "table" and objectives or {}) do
        if type(o) == "table" and o.required and not o.finished then
            all = false
            parts[#parts + 1] = (o.fulfilled or 0) .. "/" .. o.required
        end
    end
    if all then return "|cff66cc33ready|r" end
    return table.concat(parts, " ")
end

--- Party members (by Questie's sync) who have any of the quest IDs: { { name, text } },
--- sorted by name. Excludes you.
local function groupQuestProgress(ids)
    local comms = questieComms()
    if not comms then return {} end
    local me = UnitName("player")
    local out, seen = {}, {}
    for _, id in ipairs(ids) do
        local ok, players = pcall(comms.GetQuest, comms, id)
        for name, objectives in pairs(ok and type(players) == "table" and players or {}) do
            local short = tostring(name):match("^([^%-]+)") or tostring(name)
            if not seen[short] and not D.SameName(short, me) then
                seen[short] = true
                out[#out + 1] = { short, progressText(objectives) }
            end
        end
    end
    table.sort(out, function(a, b) return a[1] < b[1] end)
    return out
end

--- "  Group: Buddy 2/6, Holy ready" or nil.
local function groupLine(ids)
    local list = groupQuestProgress(ids)
    if #list == 0 then return nil end
    local parts = {}
    for i, p in ipairs(list) do parts[i] = p[1] .. " " .. p[2] end
    return "  Group: " .. table.concat(parts, ", ")
end

local function answerQuestInLog(id, name)
    local complete, objectives, turnIn = questTasks(id)
    say("Quest " .. GOLD .. name .. "|r " .. (complete and "is complete:" or "is in progress:"))

    -- Pin the nearest step; items you still need to bring come first.
    local nearest, nearestSource
    for _, o in ipairs(objectives) do
        say("  " .. objectiveText(o))
        if o.best and not o.later and (not nearest or quicker(o.best, nearest)) then nearest = o.best end
        if o.best and o.source and not o.have and (not nearestSource or quicker(o.best, nearestSource)) then
            nearestSource = o.best
        end
    end
    nearest = nearestSource or nearest
    if turnIn then
        say("  Turn in: " .. describe(turnIn, "turn in"))
    else
        say("  Turn in: " .. GREY .. "Questie doesn't know where.|r")
    end
    local group = groupLine({ id })
    if group then say(group) end

    local target = (complete or not nearest) and turnIn or nearest
    if target then autoPin(target.place, target.spawn, name) end
end

--- mode: "start", "end" or "auto" (a quest in your log shows its progress, else its start).
local function answerQuest(query, mode, questIds)
    local finish = mode == "end"
    local hits, others
    if questIds then
        hits = {}
        for _, id in ipairs(questIds) do hits[#hits + 1] = { nil, id, QuestDB.name(id) or ("quest " .. id) } end
    else
        hits, others = D.FindByName(D.questNames, query)
    end
    if not hits then
        say("I couldn't find a quest called \"" .. query .. "\".")
        return
    end

    if mode == "auto" then
        for _, e in ipairs(hits) do
            if questInLog(e[2]) then return answerQuestInLog(e[2], e[3]) end
        end
    end

    local quests = {}
    for _, e in ipairs(hits) do
        if questAvailable(e[2]) then quests[#quests + 1] = e end
    end
    if #quests == 0 then
        say("\"" .. hits[1][3] .. "\" isn't available to your faction.")
        return
    end
    table.sort(quests, function(a, b) return (QuestDB.questLevel(a[2]) or 0) < (QuestDB.questLevel(b[2]) or 0) end)

    local firstBest
    for i = 1, math.min(3, #quests) do
        local id, name = quests[i][2], quests[i][3]
        local level, req = QuestDB.questLevel(id), QuestDB.requiredLevel(id)
        local xp = questXP(id)
        local info = level and level > 0 and (" (level " .. level .. (req and req > 0 and (", needs " .. req) or "")
            .. (xp and (", " .. xp .. " xp") or "") .. ")") or ""
        local who
        if finish then who = QuestDB.finishedBy(id) else who = QuestDB.startedBy(id) end
        who = who or {}
        local places = finish and turnInPlaces(id) or questPlaces(id, who[1], who[2])
        local verb = finish and "is handed in to" or "starts at"
        local best = showRanked(places, "Quest " .. GOLD .. name .. "|r" .. info .. " " .. verb .. ":", name, 2)
        firstBest = firstBest or best
        if not finish and who[3] then
            for _, itemId in ipairs(who[3]) do
                say("  starts from the item " .. GOLD .. itemName(itemId) .. "|r " ..
                    GREY .. "(/askbot where does " .. itemName(itemId) .. " drop)|r")
            end
        end
        if not best and not (not finish and who[3]) then
            say("Quest " .. GOLD .. name .. "|r" .. info .. ": Questie doesn't know where it " ..
                (finish and "ends." or "starts."))
        end
    end
    if #quests > 3 then say(GREY .. "  ...plus " .. (#quests - 3) .. " more quests with that name.|r") end
    local ids = {}
    for i, e in ipairs(quests) do ids[i] = e[2] end
    local group = groupLine(ids)
    if group then say(group) end
    -- Other quests whose objectives are in the same spot (Levelling.lua, loaded later).
    local sameArea = not finish and AskBot.Levelling and AskBot.Levelling.sameAreaLine
    local line = sameArea and sameArea(quests[1][2])
    if line then say(line) end
    didYouMean(others, finish and "who do i turn in %s to" or "who gives %s")
    pinBest(firstBest, finish and "turn in" or "quest")
end

local function collectItem(hits, field)
    local out, seen = {}, {}
    for _, e in ipairs(hits) do
        for _, v in ipairs(ItemDB[field](e[2]) or {}) do
            if not seen[v] then seen[v] = true; out[#out + 1] = v end
        end
    end
    return out
end

--- mode: "buy", "drop" or "get" (everything we know).
local function answerItem(query, mode, hits, others)
    if not hits then
        -- For partial names, prefer items that fit the question ("linen" + drop -> Linen Cloth).
        -- (Items named only by AtlasLoot aren't in Questie's ItemDB, so guard every read.)
        local function has(field) return function(e) local v = ItemDB[field](e[2]); return v ~= nil and #v > 0 end end
        local function bossLoot(e)
            return AskBot.Loot.byItem[e[2]] ~= nil or (AskBot.KNOWN.items[e[2]] ~= nil)
        end
        local accept
        if mode == "buy" then
            accept = has("vendors")
        elseif mode == "drop" then
            local npc, obj = has("npcDrops"), has("objectDrops")
            accept = function(e) return npc(e) or obj(e) or bossLoot(e) end
        else
            local sources = { has("vendors"), has("npcDrops"), has("objectDrops"), has("questRewards"), has("itemDrops"), bossLoot }
            accept = function(e)
                for _, f in ipairs(sources) do if f(e) then return true end end
                return false
            end
        end
        hits, others = D.FindByName(D.itemNames, query, accept)
        if not hits and query:sub(-1) == "s" then
            hits, others = D.FindByName(D.itemNames, query:sub(1, -2), accept)
        end
    end
    if not hits then
        say("I couldn't find an item called \"" .. query .. "\".")
        return
    end
    local name = hits[1][3]
    local best, anything, shownDrops, ratesShown

    if mode == "buy" or mode == "get" then
        local vendors = placesForIds(collectItem(hits, "vendors"), nil, true)
        if #vendors > 0 then
            anything = true
            best = showRanked(vendors, GOLD .. name .. "|r is sold by:", name, mode == "buy" and AskBot.Option("maxResults") or 2,
                { countNoun = "vendors" })
        elseif mode == "buy" then
            say("No vendor friendly to you sells " .. GOLD .. name .. "|r, as far as Questie knows.")
        end
    end

    if mode == "drop" or mode == "get" or (mode == "buy" and not anything) then
        local droppers = placesForIds(collectItem(hits, "npcDrops"), collectItem(hits, "objectDrops"))
        -- A community location replaces Questie's drops (Questie has some wrong, e.g. the Sea Lion halves).
        if AskBot.KNOWN.items[hits[1][2]] then droppers = {} end
        local questieNpcs = {}
        for _, p in ipairs(droppers) do if p.kind == "npc" then questieNpcs[p.id] = true end end
        local function rateFor(place)
            if place.kind ~= "npc" then return nil end
            for _, e in ipairs(hits) do
                local r = AskBot.Loot.DropRate(place.id, e[2])
                if r then return r end
            end
        end
        if #droppers > 0 then
            anything, shownDrops = true, true
            local b = showRanked(droppers, GOLD .. name .. "|r drops from:", name, AskBot.Option("maxResults"), {
                showLevel = true, countNoun = "sources",
                extra = function(place)
                    local r = rateFor(place)
                    if r then ratesShown = true end
                    return formatRate(r)
                end,
            })
            best = best or b
        end

        -- Dungeon and raid bosses from AtlasLoot that Questie didn't already list.
        local bossSources = {}
        for _, e in ipairs(hits) do
            for _, src in ipairs(AskBot.Loot.byItem[e[2]] or {}) do
                if not (src.boss.npcId and questieNpcs[src.boss.npcId]) then bossSources[#bossSources + 1] = src end
            end
        end
        if #bossSources > 0 then
            anything = true
            table.sort(bossSources, function(a, b) return (a.rate or -1) > (b.rate or -1) end)
            say(#droppers > 0 and "  also from:" or (GOLD .. name .. "|r drops from:"))
            for i = 1, math.min(AskBot.Option("maxResults"), #bossSources) do
                local src = bossSources[i]
                if src.rate then ratesShown = true end
                local line = "  " .. GOLD .. src.boss.name .. "|r" .. formatRate(src.rate) .. " - " .. src.boss.instance.name
                local entrance = AskBot.Loot.EntrancePlace(src.boss.instance)
                local r = entrance and D.Rank({ entrance })[1]
                if r then
                    line = line .. ", entrance " .. whereText(r, src.boss.instance.name)
                    best = best or r
                end
                say(line)
            end
        end

        if #droppers == 0 and #bossSources == 0 then
            -- Not in Questie or AtlasLoot: AskBot's community locations.
            local places, community = itemSources(hits[1][2])
            if community then
                anything = true
                local b = showRanked(places, GOLD .. name .. "|r is found in:", name, 1)
                say(GREY .. "  (community info)|r")
                best = best or b
            elseif mode == "drop" then
                say("Neither Questie nor AtlasLoot lists anything that drops " .. GOLD .. name .. "|r.")
            end
        end
    end

    if mode ~= "buy" then
        local rewards = collectItem(hits, "questRewards")
        for i = 1, math.min(2, #rewards) do
            anything = true
            say(GOLD .. name .. "|r is a reward from quest " .. GOLD .. (QuestDB.name(rewards[i]) or rewards[i]) .. "|r " ..
                GREY .. "(/askbot who gives " .. (QuestDB.name(rewards[i]) or "") .. ")|r")
        end
        local containers = collectItem(hits, "itemDrops")
        for i = 1, math.min(2, #containers) do
            anything = true
            say(GOLD .. name .. "|r is found inside " .. GOLD .. itemName(containers[i]) .. "|r")
        end
    end

    if not anything and mode ~= "buy" and mode ~= "drop" then
        say("Questie doesn't know where to get " .. GOLD .. name .. "|r.")
    end
    if mode == "get" then
        local price = AskBot.Prices.Auction(hits[1][2])
        if price then say("  AH price: " .. AskBot.Prices.Format(price)) end
    end
    local starts = D.startItems[hits[1][2]]
    if starts then
        say("  Starts quest " .. makeLink(QuestDB.name(starts) or ("quest " .. starts), function() AskBot.Ask("quest " .. starts) end)
            .. GREY .. " (right-click it to begin)|r")
    end
    if shownDrops and not ratesShown and not dropRateNoteShown then
        dropRateNoteShown = true
        say(GREY .. "  (No drop rates known for these.)|r")
    end
    local templates = { buy = "where can i buy %s", drop = "where does %s drop", get = "where can i get %s" }
    didYouMean(others, templates[mode])
    pinBest(best, name)
end

local function answerNpcName(hits, others)
    local places = {}
    for _, e in ipairs(hits) do
        local p = D.NpcPlace(e[2])
        if p and #p.spawns > 0 then places[#places + 1] = p end
    end
    if #places == 0 then
        say("Questie doesn't know where " .. GOLD .. hits[1][3] .. "|r is.")
        return
    end
    local best = showRanked(places, nil, nil, AskBot.Option("maxResults"), { showLevel = true })
    didYouMean(others, "where is %s")
    pinBest(best)
end

--------------------------------------------------------------------------------------------
-- Loot tables (AtlasLoot) and prices (Auctionator)
--------------------------------------------------------------------------------------------

--- A clickable item link if the game has the item cached, else its name in brackets.
local function itemLinkText(id)
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    local link = getInfo and select(2, getInfo(id))
    if link then return link end
    if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
    local name = (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)) or ItemDB.name(id) or ("item " .. id)
    return "|cffffffff[" .. name .. "]|r"
end

local function lootUnavailable()
    local status = AskBot.Loot.status
    if status == "absent" then
        say("I need AtlasLoot (Forever) installed to answer loot questions.")
    elseif status == "loading" then
        say("Still reading AtlasLoot's loot tables, try again in a moment.")
    else
        return false
    end
    return true
end

local function sayEntrance(instance)
    local entrance = AskBot.Loot.EntrancePlace(instance)
    local r = entrance and D.Rank({ entrance })[1]
    if r then
        say("  Entrance: " .. whereText(r, instance.name))
        autoPin(r.place, r.spawn, instance.name)
    end
end

local function answerBossLoot(boss)
    local inst = boss.instance
    say(GOLD .. boss.name .. "|r (" .. inst.name .. ") drops:")
    local parts = {}
    for _, id in ipairs(boss.items) do
        parts[#parts + 1] = itemLinkText(id) .. (boss.npcId and formatRate(AskBot.Loot.DropRate(boss.npcId, id)) or "")
        if #parts == 3 then say("  " .. table.concat(parts, ", ")); parts = {} end
    end
    if #parts > 0 then say("  " .. table.concat(parts, ", ")) end
    sayEntrance(inst)
end

local function answerInstanceLoot(instance)
    local range = instance.levelRange
    local levels = range and (" (levels " .. range[1] .. "-" .. range[#range] .. ")") or ""
    say(GOLD .. instance.name .. "|r" .. levels .. ", bosses:")
    local parts = {}
    for _, boss in ipairs(instance.bosses) do
        parts[#parts + 1] = makeLink(boss.name, function() AskBot.Ask("what does " .. boss.name .. " drop") end)
        if #parts == 4 then say("  " .. table.concat(parts, " ")); parts = {} end
    end
    if #parts > 0 then say("  " .. table.concat(parts, " ")) end
    sayEntrance(instance)
end

--- "what does X drop": X is a boss or an instance. Returns false if nothing matched.
local function answerLoot(subject, quietIfMissing)
    if AskBot.Loot.status ~= "ready" then
        if quietIfMissing then return false end
        lootUnavailable()
        return true
    end
    local key = D.NameKey(subject)
    local bosses, bossOthers = D.FindByName(AskBot.Loot.bossNames, subject)
    local insts, instOthers = D.FindByName(AskBot.Loot.instanceNames, subject)
    -- Prefer an exact name; otherwise a boss over an instance.
    if insts and insts[1][1] == key and not (bosses and bosses[1][1] == key) then
        answerInstanceLoot(insts[1][2])
        didYouMean(instOthers, "what does %s drop")
        return true
    end
    if bosses then
        answerBossLoot(bosses[1][2])
        didYouMean(bossOthers, "what does %s drop")
        return true
    end
    if insts then
        answerInstanceLoot(insts[1][2])
        didYouMean(instOthers, "what does %s drop")
        return true
    end
    if quietIfMissing then return false end
    say("AtlasLoot has no loot table for \"" .. subject .. "\". It covers dungeon and raid bosses.")
    return true
end

--- "[Linen Cloth]: AH 12s 50c (seen today), vendors pay 13c"
local function priceLine(id)
    local P = AskBot.Prices
    local parts = {}
    if P.Available() then
        local price, age = P.Auction(id), P.AgeDays(id)
        if price then
            local when = age == 0 and "seen today" or age == 1 and "seen yesterday" or age and ("seen " .. age .. " days ago")
                or "over 3 weeks old"
            parts[#parts + 1] = "AH " .. P.Format(price) .. " " .. GREY .. "(" .. when .. ")|r"
        else
            parts[#parts + 1] = "no AH price yet " .. GREY .. "(ask again at the auction house)|r"
        end
        local vendorBuy = P.VendorBuy(id)
        if vendorBuy then parts[#parts + 1] = "vendors sell it for " .. P.Format(vendorBuy) end
    else
        parts[#parts + 1] = GREY .. "install Auctionator for auction prices|r"
    end
    local sell = P.VendorSell(id)
    if sell then parts[#parts + 1] = "vendors pay " .. P.Format(sell) end
    return itemLinkText(id) .. ": " .. table.concat(parts, ", ")
end

local function answerPrice(query, hits)
    local P = AskBot.Prices
    local others
    if not hits then
        local accept = P.Available() and function(e) return P.Auction(e[2]) ~= nil end or nil
        hits, others = D.FindByName(D.itemNames, query, accept)
        if not hits and query:sub(-1) == "s" then hits, others = D.FindByName(D.itemNames, query:sub(1, -2), accept) end
    end
    if not hits then
        say("I couldn't find an item called \"" .. query .. "\".")
        return
    end
    local id = hits[1][2]
    didYouMean(others, "price of %s")
    if not P.Available() then return say(priceLine(id)) end

    if AskBot.asker then return say(priceLine(id)) end -- someone else asking: last known price
    P.Watch(id) -- remembered for /ab refresh prices
    if not P.IsAHOpen() then return say(priceLine(id)) end

    -- At the auction house: look it up live, then answer with the fresh price.
    say(GREY .. "Checking the auction house for|r " .. itemLinkText(id) .. GREY .. "...|r")
    P.Refresh({ id }, function(results, reason)
        local r = results[1]
        local fresh = r and r.age == 0
        say(priceLine(id) .. ((reason ~= "done" or not fresh) and (GREY .. " (not listed right now)|r") or ""))
    end)
end

--- /ab refresh prices: search the AH now if it's open, else at the next visit.
local function refreshPrices(automatic)
    local P = AskBot.Prices
    if not P.Available() then return say("I need Auctionator installed to refresh prices.") end
    local ids = P.WatchedIds()
    if #ids == 0 then
        return say("Ask me some prices first (" .. GOLD .. "/ab price of Linen Cloth|r) and I'll keep a list to refresh.")
    end
    if not P.IsAHOpen() then
        AskBotCharDB.refreshPending = true
        return say("I'll refresh " .. #ids .. " price" .. (#ids == 1 and "" or "s") .. " next time you open the auction house.")
    end

    AskBotCharDB.refreshPending = nil
    say((automatic and "Auction house open: refreshing " or "Refreshing ") .. #ids .. " price" .. (#ids == 1 and "" or "s") .. "...")
    P.Refresh(ids, function(results, reason)
        local changed, same, missing = {}, 0, 0
        for _, r in ipairs(results) do
            if not (r.after and r.age == 0) then
                missing = missing + 1
            elseif r.before and r.before ~= r.after then
                local arrow = r.after < r.before and "|cff66cc33" or "|cffff6060"
                changed[#changed + 1] = itemLinkText(r.id) .. " " .. P.Format(r.before) .. " > " .. arrow .. P.Format(r.after) .. "|r"
            elseif not r.before then
                changed[#changed + 1] = itemLinkText(r.id) .. " now " .. P.Format(r.after)
            else
                same = same + 1
            end
        end
        say(#changed > 0 and "Price changes:" or "No price changes.")
        for _, line in ipairs(changed) do say("  " .. line) end
        local notes = {}
        if same > 0 then notes[#notes + 1] = same .. " unchanged" end
        if missing > 0 then notes[#notes + 1] = missing .. " not listed right now" end
        if reason ~= "done" then notes[#notes + 1] = "the search didn't finish (" .. reason .. ")" end
        if #notes > 0 then say(GREY .. "  (" .. table.concat(notes, ", ") .. ")|r") end
    end)
end

--------------------------------------------------------------------------------------------
-- Quest log, quest givers and group helpers (also used by the files after this one)
--------------------------------------------------------------------------------------------

local function questLogEntries()
    local out = {}
    if C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo then
        for i = 1, (C_QuestLog.GetNumQuestLogEntries()) do
            local info = C_QuestLog.GetInfo(i)
            if info and not info.isHeader and info.questID and info.questID > 0 then
                out[#out + 1] = { id = info.questID, name = info.title, group = info.suggestedGroup }
            end
        end
    elseif GetNumQuestLogEntries and GetQuestLogTitle then
        for i = 1, (GetNumQuestLogEntries()) do
            local title, _, group, isHeader, _, _, _, questID = GetQuestLogTitle(i)
            if not isHeader and questID and questID > 0 then out[#out + 1] = { id = questID, name = title, group = group } end
        end
    end
    return out
end

--- Quest name coloured by difficulty for the player, with its level: "[12] Bounty on Murlocs"
local function questLabel(id, name)
    local level = QuestDB.questLevel(id)
    local color = GOLD
    if level and level > 0 and GetQuestDifficultyColor then
        local c = GetQuestDifficultyColor(level)
        if c and c.r then color = string.format("|cff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255) end
    end
    return color .. (level and level > 0 and ("[" .. level .. "] ") or "") .. (name or QuestDB.name(id) or ("quest " .. id)) .. "|r"
end

--- Quest givers on your continent with quests you can take, nearest first:
--- a list of { r = ranked result, quests = { ids } }, and the number of quests.
local function questGivers(ids)
    local groups, count = {}, 0
    for _, id in ipairs(ids) do
        local info = D.questInfo[id]
        local best = D.Rank(placesForIds(info.npcs, info.objects, true))[1]
        if best and best.dist then -- same continent only
            local key = best.place.kind .. best.place.id
            local g = groups[key]
            if not g then g = { r = best, quests = {} }; groups[key] = g end
            g.quests[#g.quests + 1] = id
            count = count + 1
        end
    end

    local list = {}
    for _, g in pairs(groups) do
        table.sort(g.quests, function(a, b) return (QuestDB.questLevel(a) or 0) < (QuestDB.questLevel(b) or 0) end)
        list[#list + 1] = g
    end
    table.sort(list, function(a, b) return quicker(a.r, b.r) end)
    return list, count
end

--- Up to `max` labels joined with commas, then "+N".
local function joinSome(labels, max)
    local shown = {}
    for i = 1, math.min(max, #labels) do shown[i] = labels[i] end
    return table.concat(shown, ", ") .. (#labels > max and (GREY .. " +" .. (#labels - max) .. "|r") or "")
end

--- Unit IDs for you and your party or raid.
local function groupUnits()
    local units = { "player" }
    if IsInRaid and IsInRaid() then
        for i = 1, 40 do units[#units + 1] = "raid" .. i end
    elseif IsInGroup and IsInGroup() then
        for i = 1, 4 do units[#units + 1] = "party" .. i end
    end
    return units
end

--------------------------------------------------------------------------------------------
-- Quest chains: what comes before and after a quest
--------------------------------------------------------------------------------------------

--- done | inLog | level | ready | locked, for this character.
local function questStatus(id, inLog)
    local isCompleted = (C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted) or IsQuestFlaggedCompleted
    if isCompleted and isCompleted(id) then return "done" end
    if inLog[id] then return "inLog" end
    if (QuestDB.requiredLevel(id) or 0) > askerLevel() then return "level" end
    local QuestieDBModule = QuestieLoader and QuestieLoader:ImportModule("QuestieDB")
    if QuestieDBModule and QuestieDBModule.IsDoable then
        local ok, doable = pcall(QuestieDBModule.IsDoable, id)
        if ok and doable then return "ready" end
    end
    return "locked"
end

--- Could this character ever take the quest? (Race rules, and a giver that isn't hostile.)
local function questForMe(id)
    if not questAvailable(id) then return false end
    local by = QuestDB.startedBy(id) or {}
    if (by[2] and #by[2] > 0) or (by[3] and #by[3] > 0) or not (by[1] and #by[1] > 0) then return true end
    local mine = D.PlayerFaction()
    for _, npc in ipairs(by[1]) do
        local f = NpcDB.friendlyToFaction(npc)
        if f and mine and f:find(mine, 1, true) then return true end
    end
    return false
end

local STATUS_ORDER = { inLog = 1, ready = 2, level = 3, locked = 4, done = 5 }

--- The quests still to do before `id`, earliest first, ending with `id` itself.
--- For "any one of" prerequisites, follows the one you're closest to.
local function missingSteps(id, inLog, seen, out, depth)
    seen[id] = true
    if depth < 20 then
        for _, pre in ipairs(QuestDB.preQuestGroup(id) or {}) do -- all of these
            if pre > 0 and not seen[pre] and questForMe(pre) and questStatus(pre, inLog) ~= "done" then
                missingSteps(pre, inLog, seen, out, depth + 1)
            end
        end
        local options, anyDone = {}, false -- any one of these
        for _, pre in ipairs(QuestDB.preQuestSingle(id) or {}) do
            if pre > 0 and questForMe(pre) then
                local status = questStatus(pre, inLog)
                if status == "done" then anyDone = true end
                options[#options + 1] = { id = pre, order = STATUS_ORDER[status] }
            end
        end
        if not anyDone and #options > 0 then
            table.sort(options, function(a, b) return a.order < b.order end)
            if not seen[options[1].id] then missingSteps(options[1].id, inLog, seen, out, depth + 1) end
        end
    end
    out[#out + 1] = id
    return out
end

--- "pick up from Gryan Stoutmantle, 68 yds [pin]", with the result for pinning.
local function giverText(id)
    local by = QuestDB.startedBy(id) or {}
    local best = D.Rank(placesForIds(by[1], by[2], true))[1]
    if best then
        return "from " .. GOLD .. best.place.name .. "|r, " .. shortHow(best) .. " " .. pinLink(best.place, best.spawn, QuestDB.name(id)), best
    end
    if by[3] and by[3][1] then return "starts from the item " .. GOLD .. itemName(by[3][1]) .. "|r" end
    return GREY .. "giver unknown|r"
end

local function stepText(id, status)
    if status == "done" then return "|cff66cc33done|r" end
    if status == "inLog" then return "in your log" end
    if status == "level" then return "needs level " .. (QuestDB.requiredLevel(id) or "?") .. ", " .. (giverText(id)) end
    if status == "ready" then return "pick up " .. (giverText(id)) end
    return GREY .. "after the step above|r"
end

--- Choose among quests sharing a name: for "before", one you haven't done; for "after",
--- the furthest one you've done or have.
local function pickQuest(hits, after)
    local inLog = {}
    for _, q in ipairs(questLogEntries()) do inLog[q.id] = true end
    local best, bestScore
    for _, e in ipairs(hits) do
        local id = e[2]
        if questForMe(id) then
            local status = questStatus(id, inLog)
            local level = QuestDB.questLevel(id) or 0
            local score
            if after then
                score = (status == "done" or status == "inLog") and (1000 + level) or -level
            else
                score = (status ~= "done") and (1000 - level) or -level
            end
            if not bestScore or score > bestScore then best, bestScore = id, score end
        end
    end
    return best, inLog
end

local function resolveQuest(query, questId, after)
    if questId then
        local inLog = {}
        for _, q in ipairs(questLogEntries()) do inLog[q.id] = true end
        return questId, inLog
    end
    local hits = D.FindByName(D.questNames, query)
    if not hits then return nil end
    return pickQuest(hits, after)
end

--- "What do I need before X?" / "How do I unlock X?"
local function answerChain(query, questId)
    if AskBot.asker then return say("That depends on which quests you've done, so it needs your own AskBot.") end
    local id, inLog = resolveQuest(query, questId, false)
    if not id then return say("I couldn't find a quest called \"" .. tostring(query) .. "\" for you.") end
    local name = QuestDB.name(id) or ("quest " .. id)
    local status = questStatus(id, inLog)

    if status == "done" then
        return say("You've already done " .. questLabel(id) .. ". " .. GREY .. "(/ab what comes after " .. name .. ")|r")
    end
    if status == "inLog" then
        return answerQuestInLog(id, name)
    end

    local steps = missingSteps(id, inLog, {}, {}, 0)
    if #steps == 1 then
        local text, best = giverText(id)
        if status == "ready" then
            say(questLabel(id) .. " is ready to pick up " .. text)
        elseif status == "level" then
            say(questLabel(id) .. " needs level " .. (QuestDB.requiredLevel(id) or "?") .. ". It's " .. text)
        else
            say(questLabel(id) .. " has no earlier quests left that Questie knows of, but isn't available to you yet"
                .. " (it may need a reputation, a profession or another class). It's " .. text)
        end
        if best then autoPin(best.place, best.spawn, name) end
        return
    end

    say("To get " .. questLabel(id) .. ", first:")
    local shown, firstPin = 0, nil
    for i = 1, #steps - 1 do
        local s = steps[i]
        local st = questStatus(s, inLog)
        if shown < 6 then
            say("  " .. i .. ". " .. questLabel(s) .. " - " .. stepText(s, st))
            shown = shown + 1
        end
        if not firstPin and st == "ready" then
            local _, best = giverText(s)
            firstPin = best
        end
    end
    if #steps - 1 > shown then say(GREY .. "  ...and " .. (#steps - 1 - shown) .. " more steps.|r") end
    local crumbs = {}
    for _, b in ipairs(QuestDB.breadcrumbs and QuestDB.breadcrumbs(id) or {}) do
        if questForMe(b) and questStatus(b, inLog) ~= "done" then crumbs[#crumbs + 1] = questLabel(b) end
    end
    if #crumbs > 0 then say(GREY .. "  Optional lead-in:|r " .. table.concat(crumbs, ", ")) end
    if firstPin then autoPin(firstPin.place, firstPin.spawn, "first step") end
end

--- "What comes after X?"
local function answerAfter(query, questId)
    if AskBot.asker then return say("That depends on which quests you've done, so it needs your own AskBot.") end
    local id, inLog = resolveQuest(query, questId, true)
    if not id then return say("I couldn't find a quest called \"" .. tostring(query) .. "\" for you.") end

    local nexts, seen = {}, {}
    local function add(n)
        if n and n > 0 and n ~= id and not seen[n] and questForMe(n) then seen[n] = true; nexts[#nexts + 1] = n end
    end
    add(QuestDB.nextQuestInChain and QuestDB.nextQuestInChain(id))
    for _, n in ipairs(D.unlocks[id] or {}) do add(n) end
    if #nexts == 0 then return say("Nothing follows " .. questLabel(id) .. ", as far as Questie knows.") end
    table.sort(nexts, function(a, b) return (QuestDB.questLevel(a) or 0) < (QuestDB.questLevel(b) or 0) end)

    say("After " .. questLabel(id) .. ":")
    local pinned
    for i = 1, math.min(5, #nexts) do
        local n = nexts[i]
        local st = questStatus(n, inLog)
        local text = stepText(n, st)
        if st == "locked" then
            -- Say what else it's waiting for.
            local steps = missingSteps(n, inLog, { [id] = true }, {}, 0)
            text = #steps > 1 and ("also needs " .. questLabel(steps[1])) or (GREY .. "opens when you finish it|r")
        end
        say("  " .. questLabel(n) .. " - " .. text)
        if not pinned and st == "ready" then
            local _, best = giverText(n)
            pinned = best
        end
    end
    if #nexts > 5 then say(GREY .. "  ...and " .. (#nexts - 5) .. " more.|r") end
    if pinned then autoPin(pinned.place, pinned.spawn, "next quest") end
end

--------------------------------------------------------------------------------------------
-- Dungeon prep: "what do I need before Deadmines"
--------------------------------------------------------------------------------------------

-- Short names players use, as one or more name searches (first found wins).
local DUNGEON_ALIASES = {
    rfc = { "ragefire chasm" }, wc = { "wailing caverns" }, vc = { "deadmines" }, dm = { "deadmines" },
    sfk = { "shadowfang keep" }, stocks = { "stockade" }, stockades = { "stockade" }, bfd = { "blackfathom deeps" },
    gnomer = { "gnomeregan" }, rfk = { "razorfen kraul" }, sm = { "scarlet monastery" }, rfd = { "razorfen downs" },
    ulda = { "uldaman" }, zf = { "zulfarrak" }, mara = { "maraudon" }, st = { "sunken temple", "atalhakkar" },
    ["sunken temple"] = { "sunken temple", "atalhakkar" }, brd = { "blackrock depths" }, lbrs = { "blackrock spire" },
    ubrs = { "blackrock spire" }, strat = { "stratholme" }, scholo = { "scholomance" },
}

--- A dungeon from Questie's table by name or short name. `exactOnly`: the whole name
--- (with or without "The") or a short name, nothing partial.
local function findDungeon(subject, exactOnly)
    local key = D.NameKey(subject):gsub("^the ", ""):gsub(" dungeon$", ""):gsub(" instance$", "")
    local list = D.DungeonNames()
    for _, cand in ipairs(DUNGEON_ALIASES[key] or { key }) do
        for _, e in ipairs(list) do
            if e[1] == cand or e[1] == "the " .. cand then return e[2] end
        end
    end
    if exactOnly then return nil end
    for _, cand in ipairs(DUNGEON_ALIASES[key] or { key }) do
        local hits = D.FindByName(list, cand)
        if hits then return hits[1][2] end
    end
end

local CLASS_IDS = { WARRIOR = 1, PALADIN = 2, HUNTER = 3, ROGUE = 4, PRIEST = 5, DEATHKNIGHT = 6, SHAMAN = 7,
    MAGE = 8, WARLOCK = 9, MONK = 10, DRUID = 11 }

--- Is the quest open to your class? (Questie's requiredClasses is a class bit mask.)
local function forMyClass(id)
    local mask = QuestDB.requiredClasses and QuestDB.requiredClasses(id)
    if not mask or mask == 0 then return true end
    local classId = CLASS_IDS[select(2, UnitClass("player")) or ""]
    return not classId or D.HasBit(mask, 2 ^ (classId - 1))
end

--- Does the quest belong to the dungeon? Questie files dungeon quests under the dungeon's
--- area; class quests are filed under the class, so for those, an objective inside counts.
local function questInDungeon(id, areas)
    local zone = QuestDB.zoneOrSort and QuestDB.zoneOrSort(id)
    if zone and areas[zone] then return true end
    local classes = QuestDB.requiredClasses and QuestDB.requiredClasses(id)
    if not classes or classes == 0 then return false end
    local function inside(npc)
        local spawns = NpcDB.spawns(npc)
        for area in pairs(type(spawns) == "table" and spawns or {}) do
            if areas[area] then return true end
        end
        return false
    end
    local o = QuestDB.objectives(id) or {}
    for _, c in ipairs(o[1] or {}) do
        if inside(c[1]) then return true end
    end
    for _, c in ipairs(o[3] or {}) do
        for _, npc in ipairs(ItemDB.npcDrops(c[1]) or {}) do
            if inside(npc) then return true end
        end
    end
    for _, c in ipairs(o[5] or {}) do
        for _, npc in ipairs(type(c[1]) == "table" and c[1] or {}) do
            if inside(npc) then return true end
        end
    end
    return false
end

--- "The Deadmines (lvl 10-26): entrance ~3 min [pin] [loot]", then the dungeon's quests you
--- haven't done: in your log, to pick up first (with givers), for later levels, and those
--- not available yet (links to what they need).
local function answerDungeonPrep(d)
    if AskBot.asker then return say("That depends on which quests you've done, so it needs your own AskBot.") end
    if not d.quests then
        local areas = {}
        for _, a in ipairs(d.areaIds) do areas[a] = true end
        d.quests = {}
        for id in pairs(D.questInfo) do
            if questInDungeon(id, areas) then d.quests[#d.quests + 1] = id end
        end
        table.sort(d.quests, function(a, b) return (QuestDB.questLevel(a) or 0) < (QuestDB.questLevel(b) or 0) end)
    end

    local inLog = {}
    for _, q in ipairs(questLogEntries()) do inLog[q.id] = true end
    local byStatus, done = { inLog = {}, ready = {}, level = {}, locked = {} }, 0
    for _, id in ipairs(d.quests) do
        if questForMe(id) and forMyClass(id) then
            local status = questStatus(id, inLog)
            if status == "done" then done = done + 1 else table.insert(byStatus[status], id) end
        end
    end

    -- Heading: level range (AtlasLoot), entrance, loot link.
    local inst
    if AskBot.Loot.status == "ready" then
        for _, i in ipairs(AskBot.Loot.instances) do
            for _, a in ipairs(d.areaIds) do
                if i.areaId == a then inst = i end
            end
        end
    end
    local range = inst and inst.levelRange
    local heading = GOLD .. d.name .. "|r" .. (range and range[1] and (" (lvl " .. range[1] .. "-" .. range[#range] .. ")") or "")
    local spawns = D.DungeonEntranceSpawns(d.areaId)
    local entrance = spawns and D.Rank({ { kind = "entrance", name = d.name .. " entrance", spawns = spawns } })[1]
    if entrance then
        heading = heading .. ": entrance " .. shortHow(entrance) .. " " .. pinLink(entrance.place, entrance.spawn, d.name)
    end
    if inst then
        local i = inst
        heading = heading .. " " .. makeLink("loot", function() AskBot.Ask("what does " .. i.name .. " drop") end)
    end
    say(heading)

    local open = #byStatus.inLog + #byStatus.ready + #byStatus.level + #byStatus.locked
    if open == 0 then
        say("  " .. (done > 0 and ("You've done all " .. done .. " of its quests for you.")
            or "Questie knows no quests for you there."))
    end
    if #byStatus.inLog > 0 then
        local labels = {}
        for i, id in ipairs(byStatus.inLog) do labels[i] = questLabel(id) end
        say("  In your log: " .. joinSome(labels, 4))
    end
    -- Quests to pick up, one line per giver, nearest giver first.
    local givers, byGiver = {}, {}
    for _, id in ipairs(byStatus.ready) do
        local by = QuestDB.startedBy(id) or {}
        local r = D.Rank(placesForIds(by[1], by[2], true))[1]
        local key = r and (r.place.kind .. r.place.id) or ("quest" .. id)
        local g = byGiver[key]
        if not g then
            g = { r = r, quests = {}, id = id }
            byGiver[key] = g
            givers[#givers + 1] = g
        end
        g.quests[#g.quests + 1] = questLabel(id)
    end
    table.sort(givers, function(a, b)
        if a.r and b.r then return quicker(a.r, b.r) end
        return a.r ~= nil
    end)
    local firstGiver = givers[1] and givers[1].r
    for i, g in ipairs(givers) do
        if i > 4 then say(GREY .. "  +" .. (#givers - 4) .. " more quest givers|r"); break end
        local from = g.r and (GOLD .. g.r.place.name .. "|r, " .. shortHow(g.r) .. " " .. pinLink(g.r.place, g.r.spawn, g.r.place.name))
            or (giverText(g.id))
        say("  Pick up from " .. from .. ": " .. joinSome(g.quests, 3))
    end
    if #byStatus.level > 0 then
        local labels = {}
        for i, id in ipairs(byStatus.level) do
            labels[i] = questLabel(id) .. GREY .. " (needs " .. (QuestDB.requiredLevel(id) or "?") .. ")|r"
        end
        say("  Later: " .. joinSome(labels, 3))
    end
    if #byStatus.locked > 0 then
        local links = {}
        for i, id in ipairs(byStatus.locked) do
            local name = QuestDB.name(id) or ("quest " .. id)
            links[i] = makeLink(name, function() AskBot.Ask("what do i need before " .. name) end)
        end
        say("  Not available yet: " .. joinSome(links, 3))
    end
    -- Dungeon quests your group has (they may be able to share them).
    local groupHas = {}
    for _, id in ipairs(d.quests) do
        if questForMe(id) then
            local names = {}
            for _, p in ipairs(groupQuestProgress({ id })) do names[#names + 1] = p[1] end
            if #names > 0 then groupHas[#groupHas + 1] = questLabel(id) .. GREY .. " (" .. table.concat(names, ", ") .. ")|r" end
        end
    end
    if #groupHas > 0 then say("  Group has: " .. joinSome(groupHas, 3)) end
    local pin = firstGiver or entrance
    if pin then autoPin(pin.place, pin.spawn, pin.place.name) end
end

--- Your own progress on a quest: "ready", "2/6", "done" or "not taken".
local function myQuestProgress(id)
    if questComplete(id) then return "|cff66cc33ready|r" end
    if questInLog(id) then
        local list = {}
        for i, o in ipairs(C_QuestLog.GetQuestObjectives and C_QuestLog.GetQuestObjectives(id) or {}) do
            list[i] = { fulfilled = o.numFulfilled, required = o.numRequired, finished = o.finished }
        end
        local text = progressText(list)
        return text ~= "|cff66cc33ready|r" and text or "in log"
    end
    local isCompleted = (C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted) or IsQuestFlaggedCompleted
    if isCompleted and isCompleted(id) then return GREY .. "done|r" end
    return GREY .. "not taken|r"
end

--- "Who has Red Linen Goods?": you and each group member, from Questie's party sync.
local function answerWhoHas(query, questId)
    local ids, name = {}, nil
    if questId then
        ids[1], name = questId, QuestDB.name(questId)
    else
        local hits = D.FindByName(D.questNames, query)
        for _, e in ipairs(hits or {}) do
            if questAvailable(e[2]) then ids[#ids + 1] = e[2]; name = e[3] end
        end
    end
    if #ids == 0 then return say("I couldn't find a quest called \"" .. tostring(query) .. "\".") end

    local parts = {}
    if not AskBot.asker then
        local mine = GREY .. "not taken|r"
        for _, id in ipairs(ids) do
            local p = myQuestProgress(id)
            if p ~= GREY .. "not taken|r" then mine = p end
        end
        parts[1] = "you " .. mine
    end
    local have = {}
    for _, p in ipairs(groupQuestProgress(ids)) do
        parts[#parts + 1] = p[1] .. " " .. p[2]
        have[p[1]] = true
    end

    -- Group members not listed: either they don't have it, or Questie has no data from them.
    local comms = questieComms()
    local known = comms and comms.remotePlayerClasses or {}
    local noData = {}
    for _, unit in ipairs(groupUnits()) do
        local n = unit ~= "player" and UnitName(unit)
        if n and not have[n] then
            local synced = false
            for k in pairs(known) do
                if D.SameName(tostring(k), n) then synced = true; break end
            end
            if synced then parts[#parts + 1] = n .. " " .. GREY .. "not taken|r" else noData[#noData + 1] = n end
        end
    end

    say(questLabel(ids[1], name) .. ": " .. table.concat(parts, ", "))
    if #noData > 0 then
        say(GREY .. "  (No Questie party data from " .. table.concat(noData, ", ") .. ".)|r")
    elseif not (IsInGroup and IsInGroup()) then
        say(GREY .. "  (You're not in a group.)|r")
    end
end

--------------------------------------------------------------------------------------------
-- Reputation quests and items that start quests
--------------------------------------------------------------------------------------------

-- Names for factions the game can't name (no API, or not met yet).
local FACTION_NAMES = { [72] = "Stormwind", [47] = "Ironforge", [69] = "Darnassus", [54] = "Gnomeregan Exiles",
    [76] = "Orgrimmar", [68] = "Undercity", [81] = "Thunder Bluff", [530] = "Darkspear Trolls", [529] = "Argent Dawn",
    [21] = "Booty Bay", [369] = "Gadgetzan", [470] = "Ratchet", [577] = "Everlook", [87] = "Bloodsail Buccaneers",
    [270] = "Zandalar Tribe", [609] = "Cenarion Circle", [576] = "Timbermaw Hold", [59] = "Thorium Brotherhood",
    [349] = "Ravenholdt", [730] = "Stormpike Guard", [729] = "Frostwolf Clan", [509] = "The League of Arathor",
    [510] = "The Defilers", [889] = "Warsong Outriders", [890] = "Silverwing Sentinels", [93] = "Magram Clan Centaur",
    [92] = "Gelkis Clan Centaur", [809] = "Shen'dralar", [910] = "Brood of Nozdormu", [749] = "Hydraxian Waterlords",
    [589] = "Wintersaber Trainers", [471] = "Wildhammer Clan", [70] = "Syndicate" }
local FACTION_ALIASES = { sw = "stormwind", ["if"] = "ironforge", darn = "darnassus", gnomes = "gnomeregan exiles",
    org = "orgrimmar", og = "orgrimmar", uc = "undercity", tb = "thunder bluff", trolls = "darkspear trolls",
    ad = "argent dawn", cc = "cenarion circle", bb = "booty bay", timbermaw = "timbermaw hold", tb2 = "thunder bluff" }

local function factionName(id)
    if C_Reputation and C_Reputation.GetFactionDataByID then
        local ok, d = pcall(C_Reputation.GetFactionDataByID, id)
        if ok and type(d) == "table" and d.name then return d.name end
    end
    if GetFactionInfoByID then
        local ok, name = pcall(GetFactionInfoByID, id)
        if ok and name then return name end
    end
    return FACTION_NAMES[id]
end

--- "Friendly 1,200/6,000", or nil when the game doesn't say.
local function standingText(id)
    if not GetFactionInfoByID then return nil end
    local ok, name, _, standing, barMin, barMax, value = pcall(GetFactionInfoByID, id)
    if not ok or not name or not standing then return nil end
    local label = _G["FACTION_STANDING_LABEL" .. standing] or ("rank " .. standing)
    if barMin and barMax and value and barMax > barMin then
        return label .. " " .. (value - barMin) .. "/" .. (barMax - barMin)
    end
    return label
end

local factionList
local function factionNames()
    if not factionList then
        factionList = {}
        for id in pairs(D.repQuests) do
            local name = factionName(id)
            if name then factionList[#factionList + 1] = { D.NameKey(name), id, name } end
        end
    end
    return factionList
end

--- "quests for Stormwind rep": quests you can do that give reputation with a faction.
local function answerRep(query)
    query = query:gsub("^the ", ""):gsub(" faction$", "")
    query = FACTION_ALIASES[query] or query
    local hits = D.FindByName(factionNames(), query)
    if not hits then return say("I don't know a faction called \"" .. query .. "\" that quests give reputation with.") end
    local fid, fname = hits[1][2], hits[1][3]
    local inLog = {}
    for _, q in ipairs(questLogEntries()) do inLog[q.id] = true end
    local rep, ready, later, logged, done, total = {}, {}, {}, {}, 0, 0
    for _, e in ipairs(D.repQuests[fid]) do
        local q = e[1]
        if questForMe(q) then
            total = total + 1
            rep[q] = e[2]
            local status = questStatus(q, inLog)
            if status == "ready" then ready[#ready + 1] = q
            elseif status == "inLog" then logged[#logged + 1] = q
            elseif status == "level" then later[#later + 1] = q
            elseif status == "done" then done = done + 1 end
        end
    end
    local function label(q) return questLabel(q) .. " |cff66cc33+" .. rep[q] .. "|r" end
    local standing = standingText(fid)
    say(GOLD .. fname .. "|r" .. (standing and (" (" .. standing .. ")") or "") .. ": " .. total .. " quests give reputation"
        .. (done > 0 and (", " .. done .. " done") or "") .. ".")
    if #logged > 0 then
        local names = {}
        for i = 1, math.min(4, #logged) do names[i] = label(logged[i]) end
        say("  In your log: " .. table.concat(names, ", ") .. (#logged > 4 and (GREY .. " +" .. (#logged - 4) .. "|r") or ""))
    end
    local withGiver = {}
    for _, q in ipairs(ready) do if D.questInfo[q] then withGiver[#withGiver + 1] = q end end
    local list, count = questGivers(withGiver)
    for i = 1, math.min(4, #list) do
        local g = list[i]
        local names = {}
        for j, q in ipairs(g.quests) do
            if j > 3 then names[#names + 1] = GREY .. "+" .. (#g.quests - 3) .. "|r"; break end
            names[#names + 1] = label(q)
        end
        say("  " .. GOLD .. g.r.place.name .. "|r, " .. shortHow(g.r) .. " " .. pinLink(g.r.place, g.r.spawn, fname .. " rep")
            .. ": " .. table.concat(names, ", "))
    end
    if #ready > count then say(GREY .. "  +" .. (#ready - count) .. " more on other continents or from items.|r") end
    if #later > 0 then
        table.sort(later, function(a, b) return (QuestDB.requiredLevel(a) or 0) < (QuestDB.requiredLevel(b) or 0) end)
        local names = {}
        for i = 1, math.min(3, #later) do names[i] = label(later[i]) .. GREY .. " (needs " .. (QuestDB.requiredLevel(later[i]) or "?") .. ")|r" end
        say("  Later: " .. table.concat(names, ", ") .. (#later > 3 and (GREY .. " +" .. (#later - 3) .. "|r") or ""))
    end
    if #ready == 0 and #logged == 0 then say(GREY .. "  None you can take right now.|r") end
    if list[1] then autoPin(list[1].r.place, list[1].r.spawn, fname .. " rep") end
end

local REP_PATTERNS = { "^quests for (.+) rep$", "^quests for (.+) reputation$", "^(.+) rep quests$", "^(.+) reputation quests$",
    "^rep quests for (.+)$", "^reputation quests for (.+)$", "^how do i get (.+) rep$", "^how do i get (.+) reputation$",
    "^how do i get rep with (.+)$", "^how do i get reputation with (.+)$", "^how to get (.+) rep$",
    "^quests that give (.+) rep$", "^quests that give (.+) reputation$", "^where can i get (.+) rep$",
    "^how do i raise (.+) rep$", "^how do i raise (.+) reputation$" }

--- Bag items that start a quest you haven't done: list of { item, quest }.
local function bagQuestStarters()
    local numSlots = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
    local itemId = (C_Container and C_Container.GetContainerItemID) or GetContainerItemID
    local isCompleted = (C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted) or IsQuestFlaggedCompleted
    local out, seen = {}, {}
    if not numSlots or not itemId then return out end
    for bag = 0, 4 do
        for slot = 1, numSlots(bag) or 0 do
            local id = itemId(bag, slot)
            local q = id and D.startItems[id]
            if q and not seen[id] and not (isCompleted and isCompleted(q)) then
                seen[id] = true
                out[#out + 1] = { item = id, quest = q }
            end
        end
    end
    return out
end

--- "quest starters": items in your bags that start quests, and ones that drop near you
--- for quests at your level.
local function answerQuestStarters()
    local inBags = bagQuestStarters()
    if #inBags > 0 then
        local names = {}
        for i, e in ipairs(inBags) do names[i] = itemLinkText(e.item) .. " > " .. questLabel(e.quest) end
        say("In your bags (right-click to start): " .. table.concat(names, ", "))
    end
    local level, inLog = askerLevel(), {}
    for _, q in ipairs(questLogEntries()) do inLog[q.id] = true end
    for _, e in ipairs(inBags) do inLog[e.quest] = true end -- already have the item
    local isCompleted = (C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted) or IsQuestFlaggedCompleted
    local places, questFor = {}, {}
    for item, q in pairs(D.startItems) do
        local ql = QuestDB.questLevel(q) or 0
        if ql >= level - 3 and ql <= level + 4 and (QuestDB.requiredLevel(q) or 0) <= level and not inLog[q]
            and not (isCompleted and isCompleted(q)) and questForMe(q) then
            local sources = placesForIds(ItemDB.npcDrops(item), ItemDB.objectDrops(item), false)
            if #sources > 0 then
                local best = D.Rank(sources)[1]
                if best then
                    local p = { kind = best.place.kind, id = best.place.id, name = best.place.name, spawns = { best.spawn },
                        item = item, quest = q, from = best.place.name }
                    places[#places + 1] = p
                end
            end
        end
    end
    if #places == 0 then
        if #inBags == 0 then say("No quest-starting items in your bags, and none that drop near you at your level.") end
        return
    end
    captureForMap(places)
    local ranked = D.Rank(places)
    say("Items that start quests at your level, nearest first:")
    for i = 1, math.min(AskBot.Option("maxResults") + 2, #ranked) do
        local r = ranked[i]
        local p = r.place
        say("  " .. itemLinkText(p.item) .. " > " .. questLabel(p.quest) .. " - " .. (p.kind == "object" and "in " or "from ")
            .. GOLD .. p.from .. "|r (" .. D.ZoneName(r.spawn.uiMapId) .. ", " .. shortHow(r) .. ") " .. pinLink(p, r.spawn, itemName(p.item)))
    end
    if ranked[1] then autoPin(ranked[1].place, ranked[1].spawn, itemName(ranked[1].place.item)) end
end

local STARTER_QUESTIONS = {}
for _, s in ipairs({ "quest starters", "quest starter items", "quest starting items", "items that start quests",
    "what items start quests", "which items start quests", "do i have any quest starters", "quest items that start quests",
    "starter items", "items that start a quest" }) do STARTER_QUESTIONS[s] = true end

-- For the files loaded after this one.
Quests.friendlyPlaces, Quests.questXP, Quests.resolveQuest = friendlyPlaces, questXP, resolveQuest
Quests.questObjectives = questObjectives
Quests.answerTarget, Quests.placesForIds, Quests.questAvailable = answerTarget, placesForIds, questAvailable
Quests.itemName, Quests.questComplete, Quests.questPlaces = itemName, questComplete, questPlaces
Quests.turnInPlaces, Quests.bagCount, Quests.quicker = turnInPlaces, bagCount, quicker
Quests.questTasks, Quests.objectiveText, Quests.answerQuest = questTasks, objectiveText, answerQuest
Quests.answerItem, Quests.answerNpcName, Quests.itemLinkText = answerItem, answerNpcName, itemLinkText
Quests.lootUnavailable, Quests.answerLoot, Quests.answerPrice = lootUnavailable, answerLoot, answerPrice
Quests.refreshPrices, Quests.questLogEntries, Quests.questLabel = refreshPrices, questLogEntries, questLabel
Quests.questGivers, Quests.joinSome, Quests.groupUnits = questGivers, joinSome, groupUnits
Quests.answerChain, Quests.answerAfter, Quests.findDungeon = answerChain, answerAfter, findDungeon
Quests.answerDungeonPrep, Quests.answerWhoHas = answerDungeonPrep, answerWhoHas
Quests.REP_PATTERNS, Quests.answerRep, Quests.STARTER_QUESTIONS = REP_PATTERNS, answerRep, STARTER_QUESTIONS
Quests.answerQuestStarters = answerQuestStarters
