-- AskBot.lua
-- /askbot <question> (also /ab, /ask): answers "where is" questions from QuestieDB's data,
-- in chat, with clickable [pin] links and a TomTom (or built-in) waypoint for the best answer.

local ADDON_NAME, AskBot = ...
local D = AskBot.Data

local QUESTIEDB_CONTRACT = 4 -- the QuestieDB API contract this addon was written against
local PREFIX = "|cff33ccffAskBot|r: "
local GOLD, GREY = "|cffffd100", "|cffaaaaaa"

-- Answers go to the chat window the last /askbot was typed in (remembered per character),
-- falling back to the default chat window.
local outputFrame
local outputSink -- when answering someone else in chat, lines are collected here instead

local function say(msg)
    if outputSink then
        outputSink[#outputSink + 1] = msg
        return
    end
    local frame = outputFrame
    if not frame and AskBotCharDB and AskBotCharDB.chatFrame then
        frame = _G["ChatFrame" .. AskBotCharDB.chatFrame]
    end
    (frame or DEFAULT_CHAT_FRAME):AddMessage(PREFIX .. msg)
end

local function useChatFrameOf(editBox)
    local frame = editBox and editBox.chatFrame
    if frame and frame.AddMessage then
        outputFrame = frame
        local id = frame.GetID and frame:GetID()
        if AskBotCharDB and id and _G["ChatFrame" .. id] == frame then AskBotCharDB.chatFrame = id end
    end
end

local targetsById = {}
for _, t in ipairs(AskBot.targets) do targetsById[t.id] = t end

-- Who's asking: AskBot.asker is set while answering someone else's "!ask" in chat.
local function askerClass()
    if AskBot.asker and AskBot.asker.class then return AskBot.asker.class end
    local _, classFile = UnitClass("player")
    return classFile
end

local function askerLevel()
    return (AskBot.asker and AskBot.asker.level) or UnitLevel("player") or 1
end

local pendingQuestion -- asked before the index was ready

--------------------------------------------------------------------------------------------
-- Pins and clickable links
--------------------------------------------------------------------------------------------

local lastTomTomWaypoint

local function clearPins()
    if lastTomTomWaypoint and TomTom and TomTom.RemoveWaypoint then
        pcall(TomTom.RemoveWaypoint, TomTom, lastTomTomWaypoint)
    end
    lastTomTomWaypoint = nil
    if C_Map and C_Map.ClearUserWaypoint then pcall(C_Map.ClearUserWaypoint) end
end

local function placePin(place, spawn, label)
    local title = place.name .. (label and (" (" .. label .. ")") or "")
    local x, y = spawn.x / 100, spawn.y / 100

    if TomTom and TomTom.AddWaypoint then
        if lastTomTomWaypoint and TomTom.RemoveWaypoint then
            pcall(TomTom.RemoveWaypoint, TomTom, lastTomTomWaypoint)
        end
        local ok, uid = pcall(TomTom.AddWaypoint, TomTom, spawn.uiMapId, x, y, {
            title = title, from = ADDON_NAME, persistent = false,
            minimap = true, world = true, crazy = true,
        })
        if ok and uid then
            lastTomTomWaypoint = uid
            return "TomTom waypoint set"
        end
    end

    if C_Map and C_Map.SetUserWaypoint and UiMapPoint then
        local ok = pcall(function()
            if C_Map.CanSetUserWaypointOnMap and not C_Map.CanSetUserWaypointOnMap(spawn.uiMapId) then
                error("map does not allow waypoints")
            end
            C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(spawn.uiMapId, x, y))
            if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
                C_SuperTrack.SetSuperTrackedUserWaypoint(true)
            end
        end)
        if ok then return "map pin set" end
    end
end

--- Pins placed by answers (not clicks): only for your own questions, and only when the
--- "Pin the best answer" setting is on.
local function autoPin(place, spawn, label)
    if AskBot.asker or not AskBot.Option("autoPin") then return end
    placePin(place, spawn, label)
end

-- Clickable chat links: each stores a function to run when clicked.
local links, linkCount = {}, 0

local function makeLink(text, run)
    linkCount = linkCount + 1
    links[linkCount] = run
    return "|cff71d5ff|Haddon:askbot:" .. linkCount .. "|h[" .. text .. "]|h|r"
end

local function pinLink(place, spawn, label)
    return makeLink("pin", function()
        if not placePin(place, spawn, label) then say("Couldn't set a pin for " .. GOLD .. place.name .. "|r.") end
    end)
end

local function onLinkClicked(link)
    local n = type(link) == "string" and link:match("^addon:askbot:(%d+)")
    local run = n and links[tonumber(n)]
    if run then run() end
end

if EventRegistry and EventRegistry.RegisterCallback then
    EventRegistry:RegisterCallback("SetItemRef", function(_, link) onLinkClicked(link) end)
elseif SetItemRef then
    hooksecurefunc("SetItemRef", onLinkClicked)
end

--------------------------------------------------------------------------------------------
-- Formatting
--------------------------------------------------------------------------------------------

local function formatYards(d)
    local n = math.floor(d + 0.5)
    return (BreakUpLargeNumbers and BreakUpLargeNumbers(n) or tostring(n)) .. " yds"
end

local function formatTime(t)
    if t < 60 then return "<1 min" end
    return "~" .. math.floor(t / 60 + 0.5) .. " min"
end

local function levelText(place)
    local lo, hi = place.minLevel, place.maxLevel
    if not lo or lo <= 0 then return "" end
    if hi and hi ~= lo then return " lvl " .. lo .. "-" .. hi end
    return " lvl " .. lo
end

--- One line describing a ranked result, with a [pin] link.
--- "Westfall 42.6, 71.8 (300 yds, ~1 min) [pin]" for a ranked result.
local function whereText(r, label)
    local p, s = r.place, r.spawn
    local where = string.format("%s %.1f, %.1f", D.ZoneName(s.uiMapId), s.x, s.y)
    local how
    if r.time and r.steps and #r.steps > 0 then
        how = " (" .. formatTime(r.time) .. ", " .. D.RouteText(r.steps) .. ")"
    elseif r.dist then
        how = string.format(" (%s, %s)", formatYards(r.dist), formatTime(r.time))
    else
        how = " (other continent)"
    end
    return where .. how .. " " .. pinLink(p, s, label)
end

local function formatRate(rate)
    if not rate then return "" end
    local text = rate >= 10 and tostring(math.floor(rate + 0.5)) or string.format("%.1f", rate)
    return " |cff66cc33" .. text .. "%|r"
end

--- One line describing a ranked result, with a [pin] link. `extra(place)` may add text
--- after the name (e.g. a drop rate).
local function describe(r, label, showLevel, extra)
    local p = r.place
    local sub = p.sub and (" <" .. p.sub .. ">") or ""
    local lvl = showLevel and levelText(p) or ""
    local more = extra and extra(p) or ""
    return GOLD .. p.name .. "|r" .. sub .. lvl .. more .. " - " .. whereText(r, label)
end

--- Print up to `max` ranked results under a heading; pin the first if `pin` is set.
--- Returns the best result.
local function showRanked(places, heading, label, max, opts)
    opts = opts or {}
    local results, havePosition = D.Rank(places)
    if #results == 0 then return nil end
    if heading then
        if #results > max and opts.countNoun then
            heading = heading:gsub(":$", " (" .. #results .. " " .. opts.countNoun .. "):")
        end
        say(heading)
    end
    for i = 1, math.min(max, #results) do
        say("  " .. describe(results[i], label, opts.showLevel, opts.extra))
    end
    if not havePosition then
        say(GREY .. "  (No position known, so these aren't sorted by distance.)|r")
    end
    return results[1]
end

local function pinBest(best, label)
    if best then autoPin(best.place, best.spawn, label) end
end

--- Offer alternative names as links; clicking one asks `template` (a format string) again.
local function didYouMean(others, template)
    if not others or #others == 0 then return end
    local parts = {}
    for i, name in ipairs(others) do
        local question = template:format(name)
        parts[i] = makeLink(name, function() AskBot.Ask(question) end)
    end
    say(GREY .. "Did you mean:|r " .. table.concat(parts, " ") .. GREY .. "?|r")
end

local dropRateNoteShown = false

--------------------------------------------------------------------------------------------
-- Answers
--------------------------------------------------------------------------------------------

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
local function questObjectives(id)
    local list = {}
    local o = QuestDB.objectives(id) or {}
    for _, c in ipairs(o[1] or {}) do -- creatures to kill
        local p = D.NpcPlace(c[1])
        if p then list[#list + 1] = { "Kill", c[2] or p.name, placesForIds({ c[1] }), true } end
    end
    for _, c in ipairs(o[2] or {}) do -- objects to use
        local p = D.ObjectPlace(c[1])
        if p then list[#list + 1] = { "Use", c[2] or p.name, placesForIds(nil, { c[1] }) } end
    end
    for _, c in ipairs(o[3] or {}) do -- items to collect
        local drops = placesForIds(ItemDB.npcDrops(c[1]), ItemDB.objectDrops(c[1]))
        list[#list + 1] = { "Collect", c[2] or itemName(c[1]), drops, true }
    end
    for _, c in ipairs(o[5] or {}) do -- kill credit (any of several NPCs counts)
        list[#list + 1] = { "Kill", c[3] or NpcDB.name(c[2]) or "target", placesForIds(c[1]), true }
    end
    local trigger = QuestDB.triggerEnd(id) -- "explore X" style objectives
    if trigger and trigger[1] then
        local spawns = D.ResolveSpawns(trigger[2])
        list[#list + 1] = { "Go to", trigger[1], #spawns > 0 and { { kind = "area", name = trigger[1], spawns = spawns } } or {} }
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
                    verb = obj[1], name = objName, showLevel = obj[4],
                    best = #obj[3] > 0 and D.Rank(obj[3])[1] or nil,
                }
            end
        end
    end
    local who = QuestDB.finishedBy(id) or {}
    return complete, objectives, D.Rank(placesForIds(who[1], who[2]))[1]
end

--- "Collect Linen Cloth from: Defias Thug lvl 9-10 - Westfall ... [pin]"
local function objectiveText(o)
    if not o.best then
        return o.verb .. " " .. GOLD .. o.name .. "|r " .. GREY .. "(Questie doesn't know where)|r"
    end
    local prefix = o.verb == "Collect" and ("Collect " .. GOLD .. o.name .. "|r from: ") or (o.verb .. ": ")
    return prefix .. describe(o.best, o.name, o.showLevel)
end

local function answerQuestInLog(id, name)
    local complete, objectives, turnIn = questTasks(id)
    say("Quest " .. GOLD .. name .. "|r " .. (complete and "is complete:" or "is in progress:"))

    local nearest
    for _, o in ipairs(objectives) do
        say("  " .. objectiveText(o))
        if o.best and (not nearest or quicker(o.best, nearest)) then nearest = o.best end
    end
    if turnIn then
        say("  Turn in: " .. describe(turnIn, "turn in"))
    else
        say("  Turn in: " .. GREY .. "Questie doesn't know where.|r")
    end

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
        local info = level and level > 0 and (" (level " .. level .. (req and req > 0 and (", needs " .. req) or "") .. ")") or ""
        local who
        if finish then who = QuestDB.finishedBy(id) else who = QuestDB.startedBy(id) end
        who = who or {}
        local places = placesForIds(who[1], who[2])
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
        local function bossLoot(e) return AskBot.Loot.byItem[e[2]] ~= nil end
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

        if #droppers == 0 and #bossSources == 0 and mode == "drop" then
            say("Neither Questie nor AtlasLoot lists anything that drops " .. GOLD .. name .. "|r.")
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
-- Levelling helper: what's next, quests near me, dungeons for my level, rares
--------------------------------------------------------------------------------------------

local function questLogEntries()
    local out = {}
    if C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo then
        for i = 1, (C_QuestLog.GetNumQuestLogEntries()) do
            local info = C_QuestLog.GetInfo(i)
            if info and not info.isHeader and info.questID and info.questID > 0 then
                out[#out + 1] = { id = info.questID, name = info.title }
            end
        end
    elseif GetNumQuestLogEntries and GetQuestLogTitle then
        for i = 1, (GetNumQuestLogEntries()) do
            local title, _, _, isHeader, _, _, _, questID = GetQuestLogTitle(i)
            if not isHeader and questID and questID > 0 then out[#out + 1] = { id = questID, name = title } end
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

local function answerWhatsNext()
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
                if o.best then objectives[#objectives + 1] = { quest = q.id, name = name, o = o, r = o.best } end
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

local function answerQuestsHere()
    local QuestieDBModule = QuestieLoader and QuestieLoader:ImportModule("QuestieDB")
    local isDoable = QuestieDBModule and QuestieDBModule.IsDoable
    local isTrivial = QuestieDBModule and QuestieDBModule.IsTrivial
    local level = askerLevel()
    local inLog = {}
    for _, q in ipairs(questLogEntries()) do inLog[q.id] = true end

    -- Group the quests you can take by the NPC or object that gives them.
    local groups, count = {}, 0
    for id, info in pairs(D.questInfo) do
        local req = (info.req and info.req > 0) and info.req or info.level or 1
        local fitsLevel = req <= level and not (info.max and info.max > 0 and level > info.max)
        if fitsLevel and not inLog[id] then
            local trivialOk, trivial = true, false
            if isTrivial then trivialOk, trivial = pcall(isTrivial, info.level) end
            local doableOk, doable = false, nil
            if not (trivialOk and trivial) then
                if isDoable then doableOk, doable = pcall(isDoable, id) end
                if not doableOk then doable = questAvailable(id) end -- fallback: faction only
            end
            if doable then
                local best = D.Rank(placesForIds(info.npcs, info.objects))[1]
                if best and best.dist then -- same continent only
                    local key = best.place.kind .. best.place.id
                    local g = groups[key]
                    if not g then g = { r = best, quests = {} }; groups[key] = g end
                    g.quests[#g.quests + 1] = id
                    count = count + 1
                end
            end
        end
    end

    local list = {}
    for _, g in pairs(groups) do list[#list + 1] = g end
    if #list == 0 then
        return say("No new quests for you on this continent, as far as Questie knows.")
    end
    table.sort(list, function(a, b) return quicker(a.r, b.r) end)

    say("Quests you can pick up (" .. count .. " on this continent), nearest first:")
    for i = 1, math.min(5, #list) do
        local g = list[i]
        table.sort(g.quests, function(a, b) return (QuestDB.questLevel(a) or 0) < (QuestDB.questLevel(b) or 0) end)
        local names = {}
        for j, id in ipairs(g.quests) do
            if j > 4 then names[#names + 1] = GREY .. "+" .. (#g.quests - 4) .. " more|r"; break end
            names[#names + 1] = questLabel(id)
        end
        say("  " .. describe(g.r, "quests"))
        say("      " .. table.concat(names, ", "))
    end
    autoPin(list[1].r.place, list[1].r.spawn, "quests")
end

local function answerDungeons(level)
    if lootUnavailable() then return end
    level = level or askerLevel()
    local fits = {}
    for _, inst in ipairs(AskBot.Loot.instances) do
        local range = inst.levelRange
        if range and range[1] then
            local lo, hi = range[1], range[#range]
            local best = #range >= 3 and range[2] or (lo + hi) / 2
            if level >= lo and level <= hi then fits[#fits + 1] = { inst = inst, lo = lo, hi = hi, best = best } end
        end
    end
    if #fits == 0 then return say("AtlasLoot has no dungeons for level " .. level .. ".") end
    table.sort(fits, function(a, b) return math.abs(a.best - level) < math.abs(b.best - level) end)

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
-- Understanding the question
--------------------------------------------------------------------------------------------

local INTENTS = {
    { "loot", {
        "^what does (.+) drop$", "^what do (.+) drop$", "^what drops in (.+)$", "^what drops from (.+)$",
        "^what can i get from (.+)$", "^loot from (.+)$", "^drops from (.+)$", "^loot (.+)$",
        "^(.+) loot table$", "^(.+) loot$" } },
    { "price", {
        "^how much is (.+) worth$", "^how much are (.+) worth$", "^how much does (.+) sell for$",
        "^how much do (.+) sell for$", "^how much is (.+)$", "^how much are (.+)$", "^what is (.+) worth$",
        "^what are (.+) worth$", "^price of (.+)$", "^ah price of (.+)$", "^ah price (.+)$", "^value of (.+)$",
        "^price (.+)$", "^(.+) ah price$", "^(.+) price$", "^(.+) worth$" } },
    { "questEnd", {
        "^who do i turn in (.+) to$", "^who do i hand in (.+) to$", "^where do i turn in (.+)$",
        "^where do i hand in (.+)$", "^turn in (.+)$", "^hand in (.+)$", "^who ends (.+)$",
        "^who completes (.+)$", "^who finishes (.+)$", "^where does (.+) end$", "^where does (.+) finish$" } },
    { "questStart", {
        "^who gives (.+)$", "^who starts (.+)$", "^who offers (.+)$", "^where do i get the quest (.+)$",
        "^where do i get quest (.+)$", "^where can i get the quest (.+)$", "^where can i get quest (.+)$",
        "^where does the quest (.+) start$", "^where does quest (.+) start$", "^where does (.+) start$",
        "^where do i start (.+)$", "^start quest (.+)$", "^quest (.+)$" } },
    { "buy", {
        "^where can i buy (.+)$", "^where do i buy (.+)$", "^where to buy (.+)$", "^who sells (.+)$",
        "^where is (.+) sold$", "^where are (.+) sold$", "^what vendor sells (.+)$", "^buy (.+)$",
        "^vendor for (.+)$", "^sells (.+)$" } },
    { "drop", {
        "^where does (.+) drop$", "^where do (.+) drop$", "^what drops (.+)$", "^who drops (.+)$",
        "^what mob drops (.+)$", "^what mobs drop (.+)$", "^where can i farm (.+)$", "^where do i farm (.+)$",
        "^where to farm (.+)$", "^farm (.+)$", "^drops (.+)$", "^drop (.+)$" } },
    { "get", {
        "^where can i get (.+)$", "^where do i get (.+)$", "^where can i find (.+)$", "^where do i find (.+)$",
        "^how do i get (.+)$", "^how to get (.+)$", "^where to get (.+)$", "^where to find (.+)$",
        "^get (.+)$", "^find (.+)$", "^item (.+)$" } },
}

-- Levelling-helper questions, checked before the patterns above.
local SPECIAL = {
    { "next", {
        "^what is next$", "^whats next$", "^what next$", "^next$", "^what now$", "^what should i do",
        "^what do i do", "^my quests$", "^quest log$", "^questlog$", "^todo$", "^to do$", "^next steps?$" } },
    { "questsHere", {
        "^quests$", "^quests here$", "^quests nearby$", "^quests near me$", "^quests around", "^nearby quests$",
        "^new quests", "^available quests", "^any quests", "^what quests", "^which quests", "^find quests",
        "^find me quests", "^find new quests", "^quests for me" } },
    { "dungeons", {
        "^dungeons? for level (%d+)$", "^dungeons? at level (%d+)$", "^level (%d+) dungeons?$",
        "^dungeons?$", "^dungeons? for me$", "^dungeons? for my level$", "^what dungeons?", "^which dungeons?",
        "^recommend a dungeon", "^suggest a dungeon", "^any dungeons" } },
    { "rares", {
        "^rares?$", "^rares? here$", "^rares? nearby$", "^rares? near me$", "^rares? around", "^nearby rares$",
        "^any rares", "^where are the rares", "^rare mobs?" } },
}

local LEADING_NOISE ={ "a ", "an ", "some ", "my ", "the quest ", "quest " }
local TRAILING_NOISE = { " quest", " please", " from" }

local function cleanSubject(s)
    local changed = true
    while changed do
        changed = false
        for _, w in ipairs(LEADING_NOISE) do
            if s:sub(1, #w) == w and #s > #w then s = s:sub(#w + 1); changed = true end
        end
        for _, w in ipairs(TRAILING_NOISE) do
            if s:sub(-#w) == w and #s > #w then s = s:sub(1, -#w - 1); changed = true end
        end
    end
    return s
end

local function normalize(s)
    s = " " .. s:lower() .. " "
    s = s:gsub("(%a)'s ", "%1 is "):gsub("'", ""):gsub("[^%w%s]", " "):gsub("%s+", " ")
    s = s:match("^%s*(.-)%s*$")
    s = s:gsub("^please ", ""):gsub("^askbot ", "")
    return s
end

local function hasKey(q, key)
    q = " " .. q .. " "
    if #key <= 3 then
        return q:find(" " .. key .. " ", 1, true) ~= nil
    end
    return q:find(" " .. key, 1, true) ~= nil
end

local function findTarget(q)
    for _, t in ipairs(AskBot.targets) do
        for _, key in ipairs(t.keys) do
            if hasKey(q, key) then return t end
        end
    end
    for _, key in ipairs(AskBot.classTrainerKeys) do
        if hasKey(q, key) then
            local classFile = askerClass()
            return targetsById[classFile]
        end
    end
end

local function exactHits(list, query)
    local hits, others = D.FindByName(list, query)
    if hits and hits[1][1] == D.NameKey(query) then return hits, others end
end

local NPC_PREFIXES = { "where is ", "where are ", "who is ", "find ", "where can i find ", "where do i find " }

local function answer(question)
    -- Shift-clicked item or quest links carry their IDs.
    local itemId = question:match("|Hitem:(%d+)")
    local questId = question:match("|Hquest:(%d+)") or question:match("|Hquestie:(%d+)")
    local plain = question:gsub("|H.-|h%[?(.-)%]?|h", "%1"):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    -- Questie quest links can arrive as plain text, "[[15] Hilary's Necklace (3741)]": the
    -- level may read "15+", "60D" etc., and the "(id)" only shows if Questie is set to show IDs.
    questId = questId or plain:match("%[%[[^%]]*%][^%[%]]-%((%d+)%)%]")
    plain = plain:gsub("%[%[[^%]]*%]%s*([^%[%]]-)%s*%(%d+%)%]", "%1"):gsub("%[%[[^%]]*%]%s*([^%[%]]-)%]", "%1")
    local q = normalize(plain)

    local intent, subject
    for _, entry in ipairs(INTENTS) do
        for _, pattern in ipairs(entry[2]) do
            local cap = q:match(pattern)
            if cap then intent, subject = entry[1], cleanSubject(cap); break end
        end
        if intent then break end
    end

    if questId then
        return answerQuest(nil, intent == "questEnd" and "end" or intent == "questStart" and "start" or "auto", { tonumber(questId) })
    end
    if itemId then
        local id = tonumber(itemId)
        local hits = { { nil, id, itemName(id) } }
        if intent == "price" then return answerPrice(nil, hits) end
        local mode = (intent == "buy" or intent == "drop") and intent or "get"
        return answerItem(nil, mode, hits)
    end

    for _, entry in ipairs(SPECIAL) do
        for _, pattern in ipairs(entry[2]) do
            local found, _, arg = q:find(pattern)
            if found then
                if entry[1] == "next" then return answerWhatsNext() end
                if entry[1] == "questsHere" then return answerQuestsHere() end
                if entry[1] == "dungeons" then return answerDungeons(tonumber(arg)) end
                if entry[1] == "rares" then return answerRares() end
            end
        end
    end

    if intent == "loot" then
        return answerLoot(subject)
    elseif intent == "price" then
        return answerPrice(subject)
    elseif intent == "questStart" or intent == "questEnd" then
        return answerQuest(subject, intent == "questEnd" and "end" or "start")
    elseif intent == "buy" or intent == "drop" then
        return answerItem(subject, intent)
    elseif intent == "get" then
        -- "where can I get X": an item with exactly that name, else a service, else anything.
        local hits, others = exactHits(D.itemNames, subject)
        if hits then return answerItem(subject, "get", hits, others) end
        local target = findTarget(subject)
        if target then return answerTarget(target) end
        hits, others = exactHits(D.npcNames, subject)
        if hits then return answerNpcName(hits, others) end
        -- Partial item names: let answerItem pick the candidate that has a known source.
        if D.FindByName(D.itemNames, subject) then return answerItem(subject, "get") end
        return answerQuest(subject, "auto")
    end

    -- No question pattern: a service ("nearest flight master"), an NPC by name, an item, a quest.
    local target = findTarget(q)
    if target then return answerTarget(target) end

    local subject2 = q
    for _, prefix in ipairs(NPC_PREFIXES) do
        if subject2:sub(1, #prefix) == prefix then subject2 = subject2:sub(#prefix + 1); break end
    end
    subject2 = cleanSubject(subject2)
    -- A boss or dungeon name on its own most likely means "what does it drop".
    if AskBot.Loot.status == "ready" and (exactHits(AskBot.Loot.bossNames, subject2) or exactHits(AskBot.Loot.instanceNames, subject2)) then
        return answerLoot(subject2)
    end
    local hits, others = exactHits(D.npcNames, subject2)
    if hits then return answerNpcName(hits, others) end
    hits, others = exactHits(D.itemNames, subject2)
    if hits then return answerItem(subject2, "get", hits, others) end
    hits, others = exactHits(D.questNames, subject2)
    if hits then return answerQuest(subject2, "auto") end
    hits, others = D.FindByName(D.npcNames, subject2)
    if hits then return answerNpcName(hits, others) end
    hits, others = D.FindByName(D.questNames, subject2)
    if hits then return answerQuest(subject2, "auto") end
    if D.FindByName(D.itemNames, subject2) then return answerItem(subject2, "get") end
    if answerLoot(subject2, true) then return end

    say("Sorry, I don't know how to answer that yet. Try " .. GOLD .. "/askbot help|r.")
end

--------------------------------------------------------------------------------------------
-- Startup
--------------------------------------------------------------------------------------------

--- Run `fn` as a coroutine, one step per frame; then call onDone(ok, err).
local function runInBackground(fn, onDone)
    local co = coroutine.create(fn)
    local driver = CreateFrame("Frame")
    driver:SetScript("OnUpdate", function(self)
        local ok, err = coroutine.resume(co)
        if not ok or coroutine.status(co) == "dead" then
            self:SetScript("OnUpdate", nil)
            onDone(ok, err)
        end
    end)
end

local function startIndexing()
    D.status = "indexing"
    if _G.AtlasLoot then AskBot.Loot.status = "loading" end
    runInBackground(D.BuildIndex, function(ok, err)
        if not ok then
            D.status = "failed"
            say("Indexing failed: " .. tostring(err))
            return
        end
        D.status = "ready"
        D.progress = 1
        if pendingQuestion then
            local q = pendingQuestion
            pendingQuestion = nil
            AskBot.Ask(q)
        end
        -- Optional: AtlasLoot loot tables (they also add gear names to the item index).
        if _G.AtlasLoot then
            runInBackground(AskBot.Loot.Build, function(lootOk, lootErr)
                if not lootOk then
                    AskBot.Loot.status = "absent"
                    say("Couldn't read AtlasLoot's data: " .. tostring(lootErr))
                    if geterrorhandler then geterrorhandler()(lootErr) end
                end
            end)
        end
    end)
end

-- Questie builds its zone tables during its own staged start-up, so wait for it.
local function waitForQuestie()
    local waited = 0
    local ticker
    ticker = C_Timer.NewTicker(1, function()
        waited = waited + 1
        local ready = Questie and Questie.started and QuestieLoader and _G.LibQuestieDB
            and _G.NpcDB and _G.QuestDB and _G.ItemDB and _G.ObjectDB
        if not ready then
            if waited >= 180 then
                ticker:Cancel()
                D.status = "failed"
                say("Gave up waiting for Questie to finish loading.")
            end
            return
        end
        ticker:Cancel()

        local ok, msg = LibQuestieDB.RequireContract(QUESTIEDB_CONTRACT)
        if not ok then
            D.status = "failed"
            say("This QuestieDB version isn't compatible: " .. tostring(msg))
            return
        end

        local hbd = LibStub and LibStub("HereBeDragons-2.0", true)
        local zoneDB = QuestieLoader:ImportModule("ZoneDB")
        local flags = LibQuestieDB.Enum and LibQuestieDB.Enum.npcFlags
        if not hbd or not zoneDB or not flags then
            D.status = "failed"
            say("Missing a piece from Questie (HereBeDragons, ZoneDB or NPC flags).")
            return
        end
        D.Init(hbd, zoneDB, flags)
        startIndexing()
    end)
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("TAXIMAP_OPENED")
events:RegisterEvent("AUCTION_HOUSE_SHOW")
events:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        AskBotCharDB = AskBotCharDB or {}
        AskBotCharDB.knownTaxi = AskBotCharDB.knownTaxi or {}
        waitForQuestie()
    elseif event == "TAXIMAP_OPENED" then
        local ok, learned = pcall(D.RecordTaxiNodes)
        if ok and learned and learned > 0 then
            say("Learned " .. learned .. " flight path" .. (learned == 1 and "" or "s") .. " for route planning.")
        end
    elseif event == "AUCTION_HOUSE_SHOW" then
        -- A refresh was asked for away from the AH; give Auctionator a moment to set up.
        if AskBotCharDB and AskBotCharDB.refreshPending then
            C_Timer.After(1.5, function() refreshPrices(true) end)
        end
    end
end)

--------------------------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------------------------

local function help()
    say("Ask me where things are. Levelling: " .. GOLD .. "/ab what's next|r, " .. GOLD .. "/ab quests here|r, "
        .. GOLD .. "/ab dungeons|r, " .. GOLD .. "/ab rares|r. Examples:")
    say("  /askbot where is my nearest skinning trainer")
    say("  /askbot nearest flight master    /askbot where's my class trainer")
    say("  /askbot who gives The Defias Brotherhood    /askbot turn in Bounty on Murlocs")
    say("  /askbot where can I buy Coarse Thread    /askbot where does Linen Cloth drop")
    say("  /askbot where is Gryan Stoutmantle    /askbot [shift-click an item or quest]")
    say("  /askbot what does VanCleef drop    /askbot Deadmines loot    /askbot price of Linen Cloth")
    say("Click " .. "|cff71d5ff[pin]|r" .. " on any answer to put a pin on it.")
    say("/askbot clear - remove the pin.  /askbot status - index info.  Also /ab and /ask.")
    say("/askbot refresh prices - re-check prices you've asked about (now at the AH, or on your next visit).")
    say("/askbot options - settings.  /askbot share - let friends ask with \"!ask <question>\" in guild/party chat.")
end

local function status()
    local _, assumed = D.FlightMasters()
    local known = 0
    for _ in pairs(AskBotCharDB and AskBotCharDB.knownTaxi or {}) do known = known + 1 end
    say(string.format("Status: %s (%d%%). %d services/trainers, %d NPC, %d quest and %d item names.",
        D.status, math.floor(D.progress * 100), D.npcCount, #D.npcNames, #D.questNames, #D.itemNames))
    say(assumed and "Flight paths: none learned yet, so I assume you have them all. Open a flight map to teach me."
        or ("Flight paths: " .. known .. " known."))
    local L = AskBot.Loot
    local loot = L.status == "absent" and "not installed" or L.status == "loading" and "loading..."
        or string.format("%d dungeons/raids, %d bosses", #L.instances, #L.bossNames)
    local watched = #AskBot.Prices.WatchedIds()
    say("AtlasLoot: " .. loot .. ".  Auctionator: " .. (AskBot.Prices.Available()
        and ("yes, " .. watched .. " price" .. (watched == 1 and "" or "s") .. " on your refresh list"
            .. (AskBotCharDB.refreshPending and " (refresh at next AH visit)" or ""))
        or "not installed") .. ".")
    if D.status == "ready" then
        local parts = {}
        for _, t in ipairs(AskBot.targets) do
            parts[#parts + 1] = t.label .. " " .. (D.byTarget[t.id] and #D.byTarget[t.id] or 0)
        end
        say(GREY .. table.concat(parts, ", ") .. "|r")
    end
end

local SHARE_OPTIONS = { guild = "shareGuild", party = "shareParty", raid = "shareParty", whisper = "shareWhisper",
    whispers = "shareWhisper" }

--- /ab share [guild|party|whisper] [on|off]
local function shareCommand(cmd)
    local where, onoff = cmd:match("^share%s*(%a*)%s*(%a*)$")
    local key = SHARE_OPTIONS[where or ""]
    if key and (onoff == "on" or onoff == "off") then
        AskBot.SetOption(key, onoff == "on")
    elseif where ~= "" and where ~= nil then
        return say("Usage: /ab share guild|party|whisper on|off")
    end
    local function state(k) return AskBot.Option(k) and "|cff66cc33on|r" or "|cffff6060off|r" end
    say("Answering \"!ask <question>\" from others: guild " .. state("shareGuild") .. ", party/raid "
        .. state("shareParty") .. ", whispers " .. state("shareWhisper") .. ".")
    say(GREY .. "  Change with /ab share guild on (or party, whisper; on/off), or in /ab options.|r")
end

local function onSlash(msg, editBox)
    useChatFrameOf(editBox)
    msg = (msg or ""):match("^%s*(.-)%s*$")
    local cmd = msg:lower()
    if cmd == "" or cmd == "help" then
        help()
    elseif cmd == "clear" then
        clearPins()
        say("Pin cleared.")
    elseif cmd == "status" then
        status()
    elseif cmd == "forget flights" then
        AskBotCharDB.knownTaxi = {}
        say("Forgot known flight paths.")
    elseif cmd == "refresh" or cmd == "refresh prices" or cmd == "refresh ah" or cmd == "refresh auction"
        or cmd == "refresh auctions" or cmd == "refresh auction house" then
        refreshPrices(false)
    elseif cmd == "forget prices" then
        AskBotCharDB.priceWatch, AskBotCharDB.refreshPending = {}, nil
        say("Forgot the price list.")
    elseif cmd == "options" or cmd == "settings" or cmd == "config" then
        if not AskBot.OpenOptions() then
            say("Settings: pin best answer " .. (AskBot.Option("autoPin") and "on" or "off")
                .. ", " .. AskBot.Option("maxResults") .. " results per answer. Sharing: /ab share")
        end
    elseif cmd:match("^share") then
        shareCommand(cmd)
    else
        AskBot.Ask(msg)
    end
end

function AskBot.Ask(msg)
    if D.status == "ready" then
        -- Report errors in chat but still hand them to the error handler, so BugSack sees them.
        xpcall(function() answer(msg) end, function(err)
            say("Something went wrong answering that: " .. tostring(err))
            if geterrorhandler then geterrorhandler()(err) end
        end)
    elseif D.status == "failed" then
        say("I'm not working right now; see the earlier error message.")
    else
        pendingQuestion = msg
        say(string.format("Still reading Questie's data (%d%%), I'll answer in a moment.",
            math.floor(D.progress * 100)))
    end
end

--- Questions only the asker's own AskBot can answer (they need their quest log).
function AskBot.IsPersonalQuestion(question)
    local q = normalize(question)
    for _, entry in ipairs(SPECIAL) do
        if entry[1] == "next" or entry[1] == "questsHere" then
            for _, pattern in ipairs(entry[2]) do
                if q:find(pattern) then return true end
            end
        end
    end
    return false
end

--- Answer a question for someone else (an "!ask" in chat). asker = { name, class, level,
--- origin = { x, y, inst } or nil }. Returns the answer's lines (with AskBot's formatting).
function AskBot.AnswerFor(question, asker)
    if D.status ~= "ready" then return { "I'm still starting up, ask again in a moment." } end
    local lines = {}
    outputSink, AskBot.asker, D.originOverride = lines, asker, asker.origin or false
    local ok, err = pcall(answer, question)
    outputSink, AskBot.asker, D.originOverride = nil, nil, nil
    if not ok then
        if geterrorhandler then geterrorhandler()(err) end
        return { "Something went wrong answering that." }
    end
    return lines
end

SLASH_ASKBOT1 = "/askbot"
SLASH_ASKBOT2 = "/ab"
SLASH_ASKBOT3 = "/ask"
SlashCmdList.ASKBOT = onSlash
