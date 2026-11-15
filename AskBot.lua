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
    -- Answering someone else: a marker that Sharing.lua turns into a map pin link and /way.
    if AskBot.asker then return string.format("\003%d:%.1f:%.1f\004", spawn.uiMapId, spawn.x, spawn.y) end
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
    if s.dungeon then where = "in " .. s.dungeon .. ", entrance " .. where end
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

--- Compact travel for one-line answers: "75 yds", "~2 min", "~7 min flying", "~8 min by boat".
local function shortHow(r)
    if not r.time then return r.dist and formatYards(r.dist) or "other continent" end
    local by
    for _, s in ipairs(r.steps or {}) do
        if s.kind == "boat" or s.kind == "zeppelin" then by = " by " .. s.kind; break end
        if s.kind == "fly" then by = " flying" end
    end
    if not by and r.dist and r.dist < 1000 then return formatYards(r.dist) end
    return formatTime(r.time) .. (by or "")
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
local function bagCount(itemId)
    local count = (C_Item and C_Item.GetItemCount) or GetItemCount
    return count and (count(itemId) or 0) or 0
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
        local info = level and level > 0 and (" (level " .. level .. (req and req > 0 and (", needs " .. req) or "") .. ")") or ""
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
--- by Questie's own checks (completed, prerequisites, class, reputation, events...).
--- `level` defaults to yours; for another level, a simple grey-quest rule replaces Questie's.
local function doableQuests(level)
    local QuestieDBModule = QuestieLoader and QuestieLoader:ImportModule("QuestieDB")
    local isDoable = QuestieDBModule and QuestieDBModule.IsDoable
    local isTrivial = QuestieDBModule and QuestieDBModule.IsTrivial
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

--- "Gryan Stoutmantle, 68 yds [pin]: [14] Patrolling Westfall, [15] Westfall Stew +1"
local function giverLine(g, maxQuests)
    local names = {}
    for j, id in ipairs(g.quests) do
        if j > maxQuests then names[#names + 1] = GREY .. "+" .. (#g.quests - maxQuests) .. "|r"; break end
        names[#names + 1] = questLabel(id)
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

    local QuestieDBModule = QuestieLoader and QuestieLoader:ImportModule("QuestieDB")
    local isDoable = QuestieDBModule and QuestieDBModule.IsDoable
    local isTrivial = QuestieDBModule and QuestieDBModule.IsTrivial
    local isCompleted = (C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted) or IsQuestFlaggedCompleted
    local inLog = {}
    for _, q in ipairs(questLogEntries()) do inLog[q.id] = true end

    local order = { "counted", "done", "inLog", "tooHigh", "grey", "hostile", "unavailable" }
    local labels = {
        counted = "counted", done = "already done", inLog = "in your log", tooHigh = "need a higher level",
        grey = "too easy (grey)", hostile = "from NPCs hostile to you",
        unavailable = "not available yet (Questie: prerequisites, class, reputation...)",
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

--- Zones worth questing in, best first: the most quests you can take near your level,
--- weighed by how far away the zone is. Each is { map, active = your quests there,
--- levels = new quests' levels, r = where to start (ranked result) }, or nil if none.
local function rankZones(level, ids)
    local zones = {}
    local function zoneFor(map)
        local z = zones[map]
        if not z then
            z = { map = map, quests = {}, levels = {}, givers = {}, fit = 0, active = {} }
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
            end
        end
    end

    for _, id in ipairs(ids) do
        local info = D.questInfo[id]
        local giver = placesForIds(info.npcs, info.objects, true)[1]
        local spawn = giver and giver.spawns[1]
        if spawn and not CAPITALS[spawn.uiMapId] then
            local z = zoneFor(spawn.uiMapId)
            local ql = info.level or 0
            z.quests[#z.quests + 1] = id
            z.levels[#z.levels + 1] = ql
            if ql >= level - 3 and ql <= level + 4 then z.fit = z.fit + 1 end
            local key = giver.kind .. giver.id
            local g = z.givers[key]
            if not g then g = { place = giver, n = 0 }; z.givers[key] = g end
            g.n = g.n + 1
        end
    end

    -- Score: your current quests count 3, new quests near your level 2, other new quests 1.
    -- Then weigh the best few by travel time: 5 minutes away halves a zone's score.
    local list = {}
    for _, z in pairs(zones) do
        if #z.levels + #z.active >= 3 then
            z.questScore = #z.active * 3 + z.fit * 2 + (#z.levels - z.fit)
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
        z.score = z.questScore / (1 + minutes / 5)
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
        if z.r then
            line = line .. " - " .. z.r.place.name .. ", " .. shortHow(z.r) .. " " .. pinLink(z.r.place, z.r.spawn, zoneName)
        end
        line = line .. townFlightText(z)
        say("  " .. line)
        firstHub = firstHub or z.r
    end

    if debug then
        explainCurrentZone(level)
        say(GREY .. "How these were ranked (your quests count 3, new ones near your level 2, others 1;"
            .. " 5 min of travel halves the score):|r")
        for i = 1, math.min(8, #list) do
            local z = list[i]
            local names = {}
            for _, a in ipairs(z.active) do names[#names + 1] = questLabel(a.id) .. GREY .. " (yours)|r" end
            table.sort(z.quests, function(a, b) return (QuestDB.questLevel(a) or 0) < (QuestDB.questLevel(b) or 0) end)
            for _, id in ipairs(z.quests) do names[#names + 1] = questLabel(id) end
            local shown = {}
            for j = 1, math.min(4, #names) do shown[j] = names[j] end
            say(string.format("  %s: %d of yours, %d new (%d near your level), %s away, score %.1f", D.ZoneName(z.map),
                #z.active, #z.levels, z.fit, z.r and z.r.time and formatTime(z.r.time) or "unknown", z.score))
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

--- Up to `max` labels joined with commas, then "+N".
local function joinSome(labels, max)
    local shown = {}
    for i = 1, math.min(max, #labels) do shown[i] = labels[i] end
    return table.concat(shown, ", ") .. (#labels > max and (GREY .. " +" .. (#labels - max) .. "|r") or "")
end

--- Too easy to be worth much XP: Questie's grey rule, else 8+ levels below you.
local function questIsGrey(level)
    if not level or level <= 0 then return false end
    local QuestieDBModule = QuestieLoader and QuestieLoader:ImportModule("QuestieDB")
    if QuestieDBModule and QuestieDBModule.IsTrivial then
        local ok, trivial = pcall(QuestieDBModule.IsTrivial, level)
        if ok then return trivial == true end
    end
    return level < askerLevel() - 7
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

local function groupUnits()
    local units = { "player" }
    if IsInRaid and IsInRaid() then
        for i = 1, 40 do units[#units + 1] = "raid" .. i end
    elseif IsInGroup and IsInGroup() then
        for i = 1, 4 do units[#units + 1] = "party" .. i end
    end
    return units
end

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
-- Gear upgrades: "/ab upgrades", "/ab upgrades legs", "I'm a feral druid, what gear..."
--------------------------------------------------------------------------------------------

local function wordSet(q)
    local w = {}
    for word in q:gmatch("%S+") do w[word] = true end
    return w
end

--- A gear question returns the slot groups it names (possibly none) and its words; else nil.
local function gearQuestion(q)
    local words = wordSet(q)
    local slots = {}
    for word in pairs(words) do
        for _, g in ipairs(AskBot.Gear.SLOT_WORDS[word] or {}) do slots[#slots + 1] = g end
    end
    for phrase, g in pairs({ ["off hand"] = "offhand", ["main hand"] = "onehand", ["two hand"] = "twohand",
        ["one hand"] = "onehand" }) do
        if q:find(phrase, 1, true) then slots[#slots + 1] = g end
    end
    local gearWord = words.upgrade or words.upgrades or words.gear or words.bis or words.equipment or words.wear
    local asksBetter = words.better or words.best or q:find("should i get", 1, true) or q:find("should i go for", 1, true)
        or q:find("should i use", 1, true)
    -- "what boss drops are good for me", "which dungeon loot should I get"
    local lootWord = words.drops or words.loot or words.boss or words.bosses or words.dungeon or words.dungeons
    local forMe = q:find("for me", 1, true) or q:find("good for", 1, true) or words.should or words.worth
    if gearWord or (asksBetter and #slots > 0) or (lootWord and forMe) then return slots, words end
end

--- Which source a gear question is limited to: "boss" (dungeon drops), "quest", "ah", or nil.
local function gearSourceFilter(words)
    if words.boss or words.bosses or words.dungeon or words.dungeons or words.drops or words.drop or words.loot
        or words.instance or words.instances then
        return "boss"
    end
    if words.quest or words.quests then return "quest" end
    if words.ah or words.auction then return "ah" end
end

local SOURCE_ORDER = { quest = 1, boss = 2, ah = 3 }

--- "quest Foo, from Gryan (Westfall, ~1 min) [pin]" for an upgrade's best source, and the
--- ranked place to pin.
local function upgradeSource(c)
    table.sort(c.sources, function(a, b)
        if a.kind ~= b.kind then return SOURCE_ORDER[a.kind] < SOURCE_ORDER[b.kind] end
        if a.kind == "quest" and (a.inLog or false) ~= (b.inLog or false) then return a.inLog or false end
        if a.kind == "boss" then return (a.rate or 0) > (b.rate or 0) end
        return false
    end)
    local s = c.sources[1]
    local text, best
    if s.kind == "quest" then
        local places
        if s.inLog then
            places = turnInPlaces(s.quest)
        else
            local who = QuestDB.startedBy(s.quest) or {}
            places = questPlaces(s.quest, who[1], who[2], true)
        end
        best = D.Rank(places)[1]
        text = "quest " .. GOLD .. (QuestDB.name(s.quest) or "?") .. "|r" .. (s.inLog and " (in your log)" or "")
        if best then
            text = text .. (s.inLog and ", hand in to " or ", from ") .. best.place.name .. " (" .. D.ZoneName(best.spawn.uiMapId)
                .. ", " .. shortHow(best) .. ") " .. pinLink(best.place, best.spawn, QuestDB.name(s.quest))
        end
    elseif s.kind == "boss" then
        local inst = s.boss.instance
        local entrance = AskBot.Loot.EntrancePlace(inst)
        best = entrance and D.Rank({ entrance })[1]
        text = GOLD .. s.boss.name .. "|r" .. formatRate(s.rate) .. ", " .. inst.name
        if best then text = text .. " (" .. shortHow(best) .. ") " .. pinLink(best.place, best.spawn, inst.name) end
    else
        text = "AH " .. AskBot.Prices.Format(s.price)
    end
    if #c.sources > 1 then text = text .. GREY .. " (+" .. (#c.sources - 1) .. " more)|r" end
    return text, best
end

local function answerUpgrades(slots, words)
    local G = AskBot.Gear
    local classFile = askerClass()
    local level = askerLevel()
    local spec, how, summary = G.Spec(classFile, words)
    if not spec then return say("I don't know that class's specs.") end
    local className = UnitClass("player") or classFile

    local quests, inLog = {}, {}
    for _, q in ipairs(questLogEntries()) do
        inLog[q.id] = true
        quests[#quests + 1] = q.id
    end
    for _, id in ipairs(doableQuests(level + 5)) do quests[#quests + 1] = id end
    local only = gearSourceFilter(words)
    local candidates = G.Candidates({ classFile = classFile, level = level, quests = quests, inLog = inLog, only = only })
    if #slots > 0 then
        local wanted = {}
        for _, g in ipairs(slots) do wanted[g] = true end
        local kept = {}
        for _, c in ipairs(candidates) do if wanted[c.group] then kept[#kept + 1] = c end end
        candidates = kept
    end

    local function show()
        local current = G.Current(spec.weights, classFile)
        local results = {}
        for _, c in ipairs(candidates) do
            local cur = current[c.group]
            local score = cur and G.Score(c.id, spec.weights, c.group == "ranged")
            if score then
                local gain = score - cur.score
                if gain > math.max(0.5, cur.score * 0.03) then
                    c.gain, c.current = gain, cur.score
                    results[#results + 1] = c
                end
            end
        end
        table.sort(results, function(a, b) return a.gain > b.gain end)

        -- Best per slot (or the top few for the slot asked about).
        local perGroup = #slots > 0 and 3 or 1
        local shown, count = {}, {}
        for _, c in ipairs(results) do
            if (count[c.group] or 0) < perGroup then
                count[c.group] = (count[c.group] or 0) + 1
                shown[#shown + 1] = c
            end
        end

        local FROM = { boss = " from dungeons", quest = " from quests", ah = " on the auction house" }
        local where = #slots > 0 and (" (" .. G.GROUP_LABELS[slots[1]]:lower() .. ")") or ""
        say((only and "Upgrades" .. FROM[only] or "Upgrades") .. " for " .. spec.name .. " " .. className .. where
            .. ", level " .. level .. ":")
        if #shown == 0 then
            local places = { boss = "dungeons near your level", quest = "quests you can do", ah = "the auction house" }
            local list = only and places[only] or ("quests you can do, dungeons near your level"
                .. (AskBot.Prices.Available() and " or the auction house" or ""))
            say(GREY .. "  Nothing better from " .. list .. ", up to level " .. (level + 5) .. ".|r")
        end
        local firstBest
        for i = 1, math.min(#shown, AskBot.Option("maxResults") + 3) do
            local c = shown[i]
            local gain = c.current > 0 and ("+" .. math.floor(c.gain / c.current * 100 + 0.5) .. "%") or "empty slot"
            local extra = ""
            if c.req and c.req > level then extra = extra .. GREY .. " (at " .. c.req .. ")|r" end
            if c.needs then
                extra = extra .. " |cffff8040(" .. c.needs .. ")|r"
                if c.needs:find("^train ") then
                    local isArmor = c.needs:find("Mail") or c.needs:find("Shield") or c.needs:find("Leather")
                    local question = isArmor and "my class trainer" or "nearest weapon master"
                    extra = extra .. " " .. makeLink(isArmor and "trainer" or "weapon master", function() AskBot.Ask(question) end)
                end
            end
            local sourceText, best = upgradeSource(c)
            -- Pin the best upgrade you can use now (not one that needs training or levels).
            if not c.needs and not (c.req and c.req > level) then firstBest = firstBest or best end
            say("  " .. G.GROUP_LABELS[c.group] .. ": " .. itemLinkText(c.id) .. " " .. gain .. extra .. " - " .. sourceText)
        end
        -- Which dungeons hold the most upgrades (one per slot, counting every boss source).
        local byInst, instList = {}, {}
        for _, c in ipairs(results) do
            for _, s in ipairs(c.sources) do
                if s.kind == "boss" then
                    local inst = s.boss.instance
                    local e = byInst[inst]
                    if not e then
                        e = { inst = inst, groups = {}, labels = {}, gain = 0 }
                        byInst[inst] = e
                        instList[#instList + 1] = e
                    end
                    if not e.groups[c.group] then
                        e.groups[c.group] = true
                        e.labels[#e.labels + 1] = G.GROUP_LABELS[c.group]
                        e.gain = e.gain + c.gain / math.max(c.current, 1)
                    end
                end
            end
        end
        table.sort(instList, function(a, b)
            if #a.labels ~= #b.labels then return #a.labels > #b.labels end
            return a.gain > b.gain
        end)
        local function dungeonText(e)
            local lr = e.inst.levelRange
            local entrance = AskBot.Loot.EntrancePlace(e.inst)
            local r = entrance and D.Rank({ entrance })[1]
            return GOLD .. e.inst.name .. "|r" .. (lr and (" lvl " .. lr[1] .. "-" .. (lr[3] or lr[2])) or "") .. ": "
                .. #e.labels .. " upgrade" .. (#e.labels == 1 and "" or "s") .. " (" .. table.concat(e.labels, ", ") .. ")"
                .. (r and (" - " .. shortHow(r) .. " " .. pinLink(r.place, r.spawn, e.inst.name)) or "")
        end
        if only == "boss" and #instList > 0 then
            say("By dungeon:")
            for i = 1, math.min(3, #instList) do say("  " .. dungeonText(instList[i])) end
        elseif not only and instList[1] then
            say(GREY .. "  Best dungeon:|r " .. dungeonText(instList[1]))
        end

        if how == "guess" then
            local others = {}
            for _, s in ipairs(G.SPECS[classFile]) do
                if s ~= spec then others[#others + 1] = s.words[1] end
            end
            local why = ""
            if summary and summary:find("[1-9]") then why = " from your talents (" .. summary .. ")"
            elseif summary then why = " (no talent points spent yet)" end
            say(GREY .. "  Guessing " .. spec.name .. why
                .. ". For another spec: /ab upgrades as " .. table.concat(others, ", ") .. ".|r")
        end
        if firstBest then autoPin(firstBest.place, firstBest.spawn, "upgrade") end
    end

    local ids = {}
    for _, c in ipairs(candidates) do ids[#ids + 1] = c.id end
    local fetching = G.Load(ids, function()
        xpcall(show, function(err)
            say("Something went wrong answering that: " .. tostring(err))
            if geterrorhandler then geterrorhandler()(err) end
        end)
    end)
    if fetching > 0 then say(GREY .. "Checking " .. fetching .. " items with the server...|r") end
end

--- "+12%", "-5%" or "about the same" for a gain over a current score.
local function gainText(gain, current)
    if current <= 0 then return gain > 0 and "fills an empty slot" or "about the same" end
    local pct = math.floor(gain / current * 100 + 0.5)
    if pct == 0 then return "about the same" end
    return (pct > 0 and "+" or "") .. pct .. "%"
end

--- One line on whether item `id` beats what you wear: "[Item] (Legs): upgrade, +35% over
--- [Worn Leggings] for Arms Warrior". Load the item first.
local function upgradeVerdict(id, words)
    local G = AskBot.Gear
    local classFile, level = askerClass(), askerLevel()
    local spec = G.Spec(classFile, words or {})
    if not spec then return nil end
    local className = UnitClass("player") or classFile
    local r = G.Compare(id, spec, classFile, level)
    local item = itemLinkText(id)
    if not r.group then
        if r.cannot == "" or not r.cannot then return item .. " isn't something you can wear." end
        return item .. ": " .. className .. "s can't use " .. r.cannot .. "."
    end
    local head = item .. " (" .. G.GROUP_LABELS[r.group] .. "): "
    local extra = ""
    if r.req and r.req > level and not (r.needs and r.needs:find(" at ")) then
        extra = extra .. GREY .. " (at " .. r.req .. ")|r"
    end
    if r.needs then extra = extra .. " |cffff8040(" .. r.needs .. ")|r" end
    if not r.score then return head .. "I couldn't read its stats yet, ask again in a moment." end
    if not r.gain then return head .. "you wield a two-hander, so an off hand doesn't fit." .. extra end
    local forWho = " for " .. spec.name .. " " .. className
    if r.currentLink and r.currentLink:find("item:" .. id .. ":", 1, true) then
        return head .. "you're wearing it."
    end
    local vs = r.currentLink and (" over " .. r.currentLink) or ""
    if r.gain > math.max(0.5, r.current * 0.03) then
        if r.current <= 0 then return head .. "|cff40ff40upgrade|r" .. forWho .. ", fills an empty slot." .. extra end
        return head .. "|cff40ff40upgrade|r, " .. gainText(r.gain, r.current) .. vs .. forWho .. "." .. extra
    end
    return head .. "not an upgrade" .. forWho .. " (" .. gainText(r.gain, r.current)
        .. (r.currentLink and (" vs " .. r.currentLink) or "") .. ")." .. extra
end

--- "is [item] an upgrade?": loads the item, then says the verdict. `prefix` indents it when
--- it follows another answer.
local function answerIsUpgrade(id, words, prefix)
    if AskBot.asker then return end
    AskBot.Gear.Load({ id }, function()
        local ok, line = pcall(upgradeVerdict, id, words)
        if ok and line then say((prefix or "") .. line)
        elseif not ok and geterrorhandler then geterrorhandler()(line) end
    end)
end

--- Is item `id` gear (anything with an equip slot)?
local function isGear(id)
    local f = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    local loc = f and select(4, f(id))
    return loc ~= nil and loc ~= "" and loc ~= "INVTYPE_NON_EQUIP_IGNORE" and loc ~= "INVTYPE_BAG"
        and loc ~= "INVTYPE_AMMO" and loc ~= "INVTYPE_QUIVER" and loc ~= "INVTYPE_TABARD" and loc ~= "INVTYPE_BODY"
end

--- Words that ask "is it better than mine?" (with the item's own name taken out).
local function asksUpgrade(rest)
    local w = wordSet(rest)
    return w.upgrade or w.upgrades or w.better or w.equip or w.wear or w.compare or w.bis or w.sidegrade
        or rest:find("worth it", 1, true) or rest:find("worth using", 1, true) or rest:find("should i use", 1, true)
end

local UPGRADE_NAME_PATTERNS = { "^is (.+) an upgrade", "^is (.+) a upgrade", "^is (.+) better", "^is (.+) worth it",
    "^is (.+) worth using", "^should i equip (.+)$", "^should i wear (.+)$", "^should i use (.+)$", "^compare (.+)$",
    "^would (.+) be an upgrade", "^(.+) upgrade$" }

--------------------------------------------------------------------------------------------
-- Rare alerts: entering a zone with a rare near your level that drops an upgrade
--------------------------------------------------------------------------------------------

local rareAlerted = {} -- uiMapId -> GetTime() of the last alert

local function checkRares()
    if D.status ~= "ready" or not AskBot.Option("rareAlerts") or AskBot.asker then return end
    local mapId = currentZoneMap()
    if not mapId then return end
    local now = GetTime and GetTime() or 0
    if rareAlerted[mapId] and now - rareAlerted[mapId] < 1800 then return end
    rareAlerted[mapId] = now
    local level = askerLevel()
    local found, ids = {}, {}
    for npc, items in pairs(D.rareDrops) do
        local lo, hi = NpcDB.minLevel(npc) or 0, NpcDB.maxLevel(npc) or NpcDB.minLevel(npc) or 0
        if hi >= level - 3 and lo <= level + 3 then
            local place = D.NpcPlace(npc)
            local here = {}
            for _, s in ipairs(place and place.spawns or {}) do
                if s.uiMapId == mapId then here[#here + 1] = s end
            end
            if #here > 0 then
                found[#found + 1] = { npc = npc, place = place, spawns = here, items = items, lo = lo, hi = hi }
                for _, id in ipairs(items) do ids[#ids + 1] = id end
            end
        end
    end
    if #found == 0 then return end
    local G = AskBot.Gear
    AskBot.Gear.Load(ids, function()
        local classFile = askerClass()
        local spec = G.Spec(classFile, {})
        if not spec then return end
        local alerts = {}
        for _, f in ipairs(found) do
            for _, id in ipairs(f.items) do
                local r = G.Compare(id, spec, classFile, level)
                if r.gain and not r.needs and (r.req or 0) <= level + 2
                    and r.gain > math.max(0.5, r.current * 0.03) then
                    local rel = r.current > 0 and r.gain / r.current or 1
                    if not f.best or rel > f.rel then f.best, f.rel, f.r = id, rel, r end
                end
            end
            if f.best then alerts[#alerts + 1] = f end
        end
        table.sort(alerts, function(a, b) return a.rel > b.rel end)
        for i = 1, math.min(2, #alerts) do
            local f = alerts[i]
            local place = { kind = f.place.kind, id = f.npc, name = f.place.name, spawns = f.spawns }
            local best = D.Rank({ place })[1]
            local lvl = f.lo == f.hi and f.lo or (f.lo .. "-" .. f.hi)
            say("Rare here: " .. GOLD .. f.place.name .. "|r (" .. lvl .. (D.rares[f.npc] == 2 and " elite" or "")
                .. ") can drop " .. itemLinkText(f.best)
                .. (f.r.current > 0 and (" " .. gainText(f.r.gain, f.r.current) .. " " .. G.GROUP_LABELS[f.r.group]:lower())
                    or (" for your empty " .. G.GROUP_LABELS[f.r.group]:lower() .. " slot"))
                .. (best and (" " .. pinLink(best.place, best.spawn, f.place.name)) or ""))
        end
    end)
end
AskBot.CheckRares = checkRares

--------------------------------------------------------------------------------------------
-- Gathering: mining veins, herbs, fishing schools
--------------------------------------------------------------------------------------------

--- Your rank in a profession: a number, false if you don't have it, nil if unknown
--- (answering someone else, or the skill API is missing).
local function professionSkill(prof)
    if AskBot.asker then return nil end
    if GetNumSkillLines and GetSkillLineInfo then
        for i = 1, GetNumSkillLines() do
            local name, isHeader, _, rank = GetSkillLineInfo(i)
            if name == prof and not isHeader then return rank end
        end
        return false
    end
    -- Modern clients: GetProfessions() gives indexes for GetProfessionInfo().
    if GetProfessions and GetProfessionInfo then
        local list = { GetProfessions() }
        for i = 1, 5 do
            local index = list[i]
            if index then
                local name, _, rank = GetProfessionInfo(index)
                if name == prof then return rank end
            end
        end
        return false
    end
    return nil
end
AskBot.ProfessionSkill = professionSkill

-- Vanilla gathering colours: orange until skill+25, yellow until +50, green until +100.
local function skillColour(rank, req)
    if not rank or not req then return "|cffc0c0c0" end
    if rank < req then return "|cffff4040" end
    if rank < req + 25 then return "|cffff8040" end
    if rank < req + 50 then return "|cffffff00" end
    if rank < req + 100 then return "|cff40c040" end
    return "|cff808080"
end

local function skillLabel(node, rank)
    if not node.skill then return node.prof end
    return skillColour(rank, node.skill) .. node.prof .. " " .. node.skill .. "|r"
end

--- Node names for a gathering subject ("copper", "copper ore", "peacebloom", "tin vein").
--- `mode`: nil for the exact name only; "suffix" also tries adding " ore", " vein" etc.;
--- "fuzzy" also accepts partial names. Returns the node names and the display name matched.
local function gatherLookup(subject, mode)
    subject = subject:gsub("^the ", "")
    local tries = { subject }
    if mode then
        for _, suffix in ipairs({ " ore", " vein", " deposit", " school" }) do tries[#tries + 1] = subject .. suffix end
    end
    for _, t in ipairs(tries) do
        local e = D.gatherKeys[D.NameKey(t)]
        if e then return e.nodes, e.display end
    end
    if mode == "fuzzy" then
        local hits = D.FindByName(D.gatherNames, subject)
        if hits then
            local e = D.gatherKeys[hits[1][1]]
            return e.nodes, e.display
        end
    end
end

--- Nearest node of each type, then the zones with the most spawn points, then a skill check.
local function answerGather(nodeNames, heading, noSkillNote)
    local places, all = {}, {}
    for _, name in ipairs(nodeNames) do
        local p = D.GatherPlace(name)
        if p and #p.spawns > 0 then
            places[#places + 1] = p
            for _, s in ipairs(p.spawns) do all[#all + 1] = s end
        end
    end
    if #places == 0 then
        return say("Questie has no spawn points for " .. GOLD .. table.concat(nodeNames, ", ") .. "|r.")
    end
    if heading then say(heading) end

    local prof = places[1].node.prof
    local rank = professionSkill(prof)
    for _, p in ipairs(places) do p.sub = skillLabel(p.node, rank) end
    local results, havePosition = D.Rank(places)
    for i = 1, math.min(3, #results) do
        say((heading and "  " or "") .. describe(results[i]))
    end

    -- Where the nodes are thickest: the top zones by spawn points, with travel to each.
    local byZone, zones = {}, {}
    for _, s in ipairs(all) do
        local z = byZone[s.uiMapId]
        if not z then
            z = { spawns = {}, uiMapId = s.uiMapId }
            byZone[s.uiMapId] = z
            zones[#zones + 1] = z
        end
        z.spawns[#z.spawns + 1] = s
    end
    if #zones > 1 then
        table.sort(zones, function(a, b) return #a.spawns > #b.spawns end)
        local parts = {}
        for i = 1, math.min(3, #zones) do
            local z = zones[i]
            local zp = { kind = "object", name = results[1].place.name, spawns = z.spawns }
            local r = D.Rank({ zp })[1]
            local how = r.time and (" (" .. shortHow(r) .. ")") or ""
            parts[#parts + 1] = D.ZoneName(z.uiMapId) .. " " .. #z.spawns .. how .. " " .. pinLink(zp, r.spawn)
        end
        say(GREY .. "  Most nodes:|r " .. table.concat(parts, ", "))
    end

    -- Can you gather it?
    local lowest
    for _, p in ipairs(places) do
        if p.node.skill and (not lowest or p.node.skill < lowest) then lowest = p.node.skill end
    end
    if noSkillNote or prof == "Fishing" then
        -- nothing to add (a "where should I mine" heading already says it)
    elseif rank == false then
        say(GREY .. "  You don't have " .. prof .. ".|r")
    elseif rank and lowest and rank < lowest then
        say(GREY .. "  You need " .. prof .. " " .. lowest .. " (you have " .. rank .. ").|r")
    end
    if not havePosition then
        say(GREY .. "  (No position known, so these aren't sorted by distance.)|r")
    end
    pinBest(results[1])
end

--- "Where should I mine?": the best node type for your skill, and what opens up next.
local function answerGatherBest(prof)
    local rank = professionSkill(prof)
    local best, nextUp = {}, nil
    local target = rank or 1
    local bestSkill
    for name, node in pairs(D.gather) do
        if node.prof == prof and node.skill and not node.special then
            if node.skill <= target and (not bestSkill or node.skill > bestSkill) then bestSkill = node.skill end
        end
    end
    for name, node in pairs(D.gather) do
        if node.prof == prof and node.skill and not node.special then
            if node.skill == bestSkill then best[#best + 1] = name end
            if node.skill > target and (not nextUp or node.skill < nextUp.skill) then nextUp = node end
        end
    end
    if #best == 0 then return say("Questie doesn't list any " .. prof .. " nodes.") end
    table.sort(best)
    local heading
    if rank then
        heading = prof .. " " .. rank .. ": best for skill-ups"
            .. (nextUp and (GREY .. " (" .. nextUp.name .. " at " .. nextUp.skill .. ")|r") or "") .. ":"
    elseif rank == false then
        heading = "You don't have " .. prof .. " yet. Starter nodes:"
    else
        heading = "I can't see your " .. prof .. " skill, so here are the starter nodes:"
    end
    answerGather(best, heading, true)
end

--------------------------------------------------------------------------------------------
-- Professions: recipe sources, mats shopping lists, skill-up plans
--------------------------------------------------------------------------------------------

-- Words for each profession, and whether it's a crafting one (its recipes are recorded
-- from the profession window).
local PROFESSIONS = {
    { "Tailoring", { "tailoring", "tailor" }, craft = true },
    { "Leatherworking", { "leatherworking", "lw", "leatherwork" }, craft = true },
    { "Blacksmithing", { "blacksmithing", "bs", "blacksmith" }, craft = true },
    { "Alchemy", { "alchemy", "alch" }, craft = true },
    { "Enchanting", { "enchanting", "ench", "enchant" }, craft = true },
    { "Engineering", { "engineering", "engi", "eng" }, craft = true },
    { "Cooking", { "cooking", "cook" }, craft = true },
    { "First Aid", { "first aid", "firstaid" }, craft = true },
    { "Mining", { "mining", "mine" } },
    { "Herbalism", { "herbalism", "herb", "herbing" } },
    { "Skinning", { "skinning", "skin" } },
    { "Fishing", { "fishing", "fish" } },
}
local TRAINER_QUESTION = { Tailoring = "nearest tailoring trainer", Leatherworking = "nearest leatherworking trainer",
    Blacksmithing = "nearest blacksmithing trainer", Alchemy = "nearest alchemy trainer",
    Enchanting = "nearest enchanting trainer", Engineering = "nearest engineering trainer",
    Cooking = "nearest cooking trainer", ["First Aid"] = "nearest first aid trainer",
    Mining = "nearest mining trainer", Herbalism = "nearest herbalism trainer",
    Skinning = "nearest skinning trainer", Fishing = "nearest fishing trainer" }

local function professionNamed(text)
    text = " " .. text .. " "
    for _, p in ipairs(PROFESSIONS) do
        for _, w in ipairs(p[2]) do
            if text:find(" " .. w .. " ", 1, true) then return p[1], p.craft end
        end
    end
end

local function trainerLink(prof)
    local question = TRAINER_QUESTION[prof]
    return question and makeLink(prof .. " trainer", function() AskBot.Ask(question) end) or ""
end

--- Recorded recipes: AskBotCharDB.professions[prof] = { rank, max, recipes = { [key] = recipe } },
--- recipe = { name, item (id or nil), made, diff ("optimal"|"medium"|"easy"|"trivial"),
--- reagents = { { id, name, count } } }. Filled whenever a profession window opens.
local function recordedProfessions()
    return AskBotCharDB and AskBotCharDB.professions or {}
end

local function itemIdOf(link)
    return link and tonumber(link:match("|Hitem:(%d+)"))
end

local DIFFICULTY = { [0] = "optimal", [1] = "medium", [2] = "easy", [3] = "trivial" }

--- The modern profession API (C_TradeSkillUI): profession, rank, max, recipes; or nil.
local function readModernRecipes()
    local T = C_TradeSkillUI
    if not (T and T.GetAllRecipeIDs and T.GetRecipeInfo) then return nil end
    local info = (T.GetChildProfessionInfo and T.GetChildProfessionInfo())
    if not (info and info.professionName and info.professionName ~= "") then
        info = T.GetBaseProfessionInfo and T.GetBaseProfessionInfo()
    end
    local prof = info and (info.parentProfessionName or info.professionName)
    if not prof or prof == "" then
        if T.GetTradeSkillLine then prof = T.GetTradeSkillLine() end
        if not prof then return nil end
    end
    local recipes = {}
    for _, rid in ipairs(T.GetAllRecipeIDs() or {}) do
        local ri = T.GetRecipeInfo(rid)
        if ri and ri.learned and ri.name then
            local r = { name = ri.name, diff = DIFFICULTY[ri.relativeDifficulty] or "easy", reagents = {} }
            local schematic = T.GetRecipeSchematic and T.GetRecipeSchematic(rid, false)
            if schematic then
                r.item = schematic.outputItemID
                r.made = schematic.quantityMin
                for _, slot in ipairs(schematic.reagentSlotSchematics or {}) do
                    local reagent = slot.reagents and slot.reagents[1]
                    local id = reagent and reagent.itemID
                    if id then
                        local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)
                        r.reagents[#r.reagents + 1] = { id = id, name = name, count = slot.quantityRequired or 1 }
                    end
                end
            end
            recipes[D.NameKey(ri.name)] = r
        end
    end
    return prof, info and info.skillLevel, info and info.maxSkillLevel, recipes
end

local function recordRecipes(kind)
    local api
    if kind == "craft" then
        api = { line = GetCraftDisplaySkillLine, num = GetNumCrafts, info = GetCraftInfo, link = GetCraftItemLink,
            nReag = GetCraftNumReagents, reag = GetCraftReagentInfo, reagLink = GetCraftReagentItemLink }
    else
        api = { line = GetTradeSkillLine, num = GetNumTradeSkills, info = GetTradeSkillInfo, link = GetTradeSkillItemLink,
            nReag = GetTradeSkillNumReagents, reag = GetTradeSkillReagentInfo, reagLink = GetTradeSkillReagentItemLink,
            made = GetTradeSkillNumMade }
    end
    local prof, rank, max
    local recipes = {}
    if api.line and api.num and api.info then
        prof, rank, max = api.line()
    elseif kind ~= "craft" then
        prof, rank, max, recipes = readModernRecipes()
        recipes = recipes or {}
    end
    if not prof or prof == "UNKNOWN" then return end
    for i = 1, (api.line and api.num and api.info and api.num()) or 0 do
        local name, kindOrSub, diffOrNil = api.info(i)
        -- Trade skills: name, type. Crafts (enchanting): name, subSpellName, type.
        local diff = (kind == "craft") and diffOrNil or kindOrSub
        if name and diff and diff ~= "header" and diff ~= "subheader" then
            local r = { name = name, diff = diff, reagents = {} }
            r.item = api.link and itemIdOf(api.link(i))
            if api.made then r.made = api.made(i) end
            for j = 1, (api.nReag and api.nReag(i)) or 0 do
                local rName, _, count = api.reag(i, j)
                local id = api.reagLink and itemIdOf(api.reagLink(i, j))
                if rName or id then r.reagents[#r.reagents + 1] = { id = id, name = rName, count = count or 1 } end
            end
            recipes[D.NameKey(name)] = r
        end
    end
    if not next(recipes) then return end
    AskBotCharDB = AskBotCharDB or {}
    AskBotCharDB.professions = AskBotCharDB.professions or {}
    -- Merge: collapsed categories and filters hide recipes, and recipes are never unlearned.
    local old = AskBotCharDB.professions[prof]
    if old then for k, r in pairs(old.recipes or {}) do if not recipes[k] then recipes[k] = r end end end
    AskBotCharDB.professions[prof] = { rank = rank, max = max, recipes = recipes, seen = time and time() or 0 }
end
AskBot.RecordRecipes = recordRecipes

--- A recipe you know by (crafted) name: recipe, profession.
local function knownRecipe(name)
    local key = D.NameKey(name)
    for prof, p in pairs(recordedProfessions()) do
        if p.recipes[key] then return p.recipes[key], prof end
    end
    for prof, p in pairs(recordedProfessions()) do
        for k, r in pairs(p.recipes) do
            if k:find(key, 1, true) then return r, prof end
        end
    end
end

--- Price of one reagent: copper, and where ("AH" / "vendor"), or nil.
local function reagentPrice(id)
    local P = AskBot.Prices
    if not id then return nil end
    local vendor = ItemDB.vendors and ItemDB.vendors(id)
    local vb = P and P.VendorBuy and P.VendorBuy(id)
    if vendor and #vendor > 0 and vb then return vb, "vendor" end
    local ah = P and P.Available() and P.Auction(id)
    if ah then return ah, "AH" end
    if vendor and #vendor > 0 then return nil, "vendor" end
end

local function bagCount(id)
    if not id then return 0 end
    local f = (C_Item and C_Item.GetItemCount) or GetItemCount
    return f and f(id, true) or 0
end

--- Mats for `count` crafts: lines with what you have and what to buy, and the cost.
local function answerMats(recipe, prof, count)
    count = math.max(1, count or 1)
    local made = recipe.made or 1
    local itemText = recipe.item and itemLinkText(recipe.item) or (GOLD .. recipe.name .. "|r")
    say(itemText .. (count > 1 and (" x" .. count) or "") .. " (" .. prof .. "):"
        .. (made > 1 and (GREY .. " makes " .. made * count .. "|r") or ""))
    local total, unknown, haveAll = 0, false, true
    for _, r in ipairs(recipe.reagents) do
        local need = r.count * count
        local have = bagCount(r.id)
        local buy = math.max(0, need - have)
        local name = r.id and itemLinkText(r.id) or r.name or "?"
        local line = "  " .. need .. " " .. name .. ": "
        if buy == 0 then
            line = line .. "|cff40ff40have " .. have .. "|r"
        else
            haveAll = false
            local price, where = reagentPrice(r.id)
            line = line .. (have > 0 and ("have " .. have .. ", ") or "") .. "buy " .. buy
            if price then
                total = total + price * buy
                line = line .. GREY .. " (" .. where .. " " .. AskBot.Prices.Format(price) .. " each)|r"
            elseif where == "vendor" then
                line = line .. GREY .. " (vendors)|r"; unknown = true
            else
                unknown = true
            end
        end
        say(line)
    end
    if haveAll then return say("  You have everything for " .. count .. ".") end
    local summary = "  To buy: " .. (total > 0 and AskBot.Prices.Format(total) or "?") .. (unknown and total > 0 and "+" or "")
    local P = AskBot.Prices
    local sells = recipe.item and P.Available() and P.Auction(recipe.item)
    if sells and total > 0 and not unknown then
        local fullCost = 0
        for _, r in ipairs(recipe.reagents) do fullCost = fullCost + (reagentPrice(r.id) or 0) * r.count end
        local perItem = fullCost / made
        summary = summary .. ". On the AH it sells for " .. P.Format(sells) .. " each, "
            .. (sells > perItem and ("so crafting saves " .. P.Format(math.floor(sells - perItem)) .. " each")
                or ("so buying it is " .. P.Format(math.floor(perItem - sells)) .. " cheaper each"))
    end
    say(summary .. ".")
end

--- Where to get the recipe for `name`: recipe item sources, or the trainer.
local function answerRecipe(name)
    local known, prof
    if not AskBot.asker then known, prof = knownRecipe(name) end
    if known then
        say("You already know " .. (known.item and itemLinkText(known.item) or (GOLD .. known.name .. "|r")) .. " (" .. prof .. "). "
            .. makeLink("mats", function() answerMats(known, prof, 1) end))
        return
    end
    local key = D.NameKey(name)
    local hits = {}
    for _, e in ipairs(D.recipeItems) do
        if e[1] == key then hits[#hits + 1] = { nil, e[2], e[3] } end
    end
    if #hits == 0 then
        for _, e in ipairs(D.recipeItems) do
            if e[1]:find(key, 1, true) and #hits < 3 then hits[#hits + 1] = { nil, e[2], e[3] } end
        end
    end
    if #hits > 0 then
        answerItem(nil, "get", { hits[1] })
        if #hits > 1 then
            local more = {}
            for i = 2, #hits do
                local h = hits[i]
                more[#more + 1] = makeLink(h[3], function() answerItem(nil, "get", { h }) end)
            end
            say(GREY .. "  Also: |r" .. table.concat(more, ", "))
        end
        return
    end
    -- No recipe item: a trainer teaches it (if it's craftable at all).
    local mine = {}
    for _, p in ipairs(PROFESSIONS) do
        if p.craft and (professionSkill(p[1]) or recordedProfessions()[p[1]]) then mine[#mine + 1] = trainerLink(p[1]) end
    end
    say("No pattern, plan or recipe item teaches \"" .. name .. "\", so if it's craftable a trainer teaches it."
        .. (#mine > 0 and (" " .. table.concat(mine, " ")) or ""))
end

-- Skinning: skill needed for a mob of `level` (vanilla).
local function skinLevelFor(skill)
    if skill < 100 then return 10 + math.floor(skill / 10) end
    return math.floor(skill / 5)
end

local DIFF_LABEL = { optimal = "|cffff8040orange|r", medium = "|cffffff00yellow|r", easy = "|cff40c040green|r" }

--- How to level a profession.
local function answerSkillUp(prof)
    if prof == "Mining" or prof == "Herbalism" then return answerGatherBest(prof) end
    local rank = professionSkill(prof)
    if prof == "Skinning" then
        if rank == false then return say("You don't have Skinning. " .. trainerLink(prof)) end
        if not rank then
            return say("I can't read your Skinning skill here. You can skin beasts up to level 10 + skill/10 (skill/5 from"
                .. " 100), so skill 50 skins level 15 and 150 skins level 30; the highest you can skin give the most skill-ups.")
        end
        local top = skinLevelFor(rank)
        say("Skinning " .. rank .. ": you can skin beasts up to level " .. top .. "; the closest to that give the most skill-ups. "
            .. makeLink("zones for level " .. top, function() AskBot.Ask("where should i go at " .. top) end))
        return
    end
    if prof == "Fishing" then
        if rank == false then return say("You don't have Fishing. " .. trainerLink(prof)) end
        return say("Fishing " .. (rank or "?") .. ": every catch can give a skill-up; fish where the zone's fish don't get away. "
            .. trainerLink(prof))
    end
    local p = recordedProfessions()[prof]
    if not p then
        if rank == false then return say("You don't have " .. prof .. ". " .. trainerLink(prof)) end
        return say("Open your " .. prof .. " window once so I can read your recipes, then ask again.")
    end
    rank = rank or p.rank
    local list = {}
    for _, r in pairs(p.recipes) do
        if r.diff == "optimal" or r.diff == "medium" then
            local cost, unknown = 0, false
            for _, g in ipairs(r.reagents) do
                local price = reagentPrice(g.id)
                local short = math.max(0, g.count - bagCount(g.id))
                if short > 0 then
                    if price then cost = cost + price * short else unknown = true end
                end
            end
            list[#list + 1] = { r = r, cost = cost, unknown = unknown }
        end
    end
    table.sort(list, function(a, b)
        if a.r.diff ~= b.r.diff then return a.r.diff == "optimal" end
        if a.unknown ~= b.unknown then return not a.unknown end
        if a.cost ~= b.cost then return a.cost < b.cost end
        return a.r.name < b.r.name
    end)
    local atCap = p.max and rank and rank >= p.max
    say(prof .. " " .. (rank or "?") .. (p.max and ("/" .. p.max) or "") .. ": cheapest skill-ups"
        .. (atCap and (" |cffff8040(at your cap: train the next rank)|r " .. trainerLink(prof)) or "") .. ":")
    if #list == 0 then
        return say(GREY .. "  Nothing orange or yellow. Learn new recipes: |r" .. trainerLink(prof))
    end
    for i = 1, math.min(4, #list) do
        local e = list[i]
        local r = e.r
        local cost = e.cost == 0 and not e.unknown and "|cff40ff40mats in bags|r"
            or ("mats " .. (e.cost > 0 and AskBot.Prices.Format(e.cost) or "?") .. (e.unknown and e.cost > 0 and "+" or ""))
        say("  " .. (r.item and itemLinkText(r.item) or (GOLD .. r.name .. "|r")) .. " " .. DIFF_LABEL[r.diff] .. " - " .. cost
            .. " " .. makeLink("list", function() answerMats(r, prof, 1) end))
    end
    if p.seen and time and time() - p.seen > 3 * 86400 then
        say(GREY .. "  (From when you last opened your " .. prof .. " window.)|r")
    end
end

-- "mats for 3 linen bag", "what do I need to make Linen Bag", "recipe for X", "how do I level tailoring"
local MATS_PATTERNS = { "^mats for (.+)$", "^materials for (.+)$", "^reagents for (.+)$", "^what do i need to make (.+)$",
    "^what does it take to make (.+)$", "^shopping list for (.+)$", "^how much to make (.+)$", "^cost to make (.+)$",
    "^cost of making (.+)$", "^(.+) mats$", "^(.+) materials$", "^how do i make (.+)$", "^how to make (.+)$",
    "^can i make (.+)$" }
local RECIPE_PATTERNS = { "^recipe for (.+)$", "^pattern for (.+)$", "^plans for (.+)$", "^formula for (.+)$",
    "^schematic for (.+)$", "^where do i get the recipe for (.+)$", "^where do i get the pattern for (.+)$",
    "^where do i get the plans for (.+)$", "^where do i get the formula for (.+)$", "^where do i get the schematic for (.+)$",
    "^where can i get the recipe for (.+)$", "^where can i learn (.+)$", "^how do i learn (.+)$", "^where do i learn (.+)$",
    "^who teaches (.+)$", "^where is the recipe for (.+)$" }
local SKILLUP_PATTERNS = { "^how do i level (.+)$", "^how to level (.+)$", "^how should i level (.+)$", "^level up (.+)$",
    "^levelling (.+)$", "^leveling (.+)$", "^skill up (.+)$", "^(.+) skill ?ups?$", "^(.+) skill up plan$",
    "^(.+) levelling$", "^(.+) leveling$", "^(.+) guide$", "^best (.+) skill ?ups$", "^what (.+) should i craft$",
    "^what should i craft for (.+)$" }

--- Is `q` a profession question that needs your own recipes or skills? (For "!ask".)
local function personalProfession(q)
    for _, list in ipairs({ MATS_PATTERNS, SKILLUP_PATTERNS }) do
        for _, pattern in ipairs(list) do
            local s = q:match(pattern)
            if s and (list == MATS_PATTERNS or professionNamed(s)) then return true end
        end
    end
    return q == "what should i craft"
end

--- Answers profession questions; returns true if it did.
local function professionQuestion(q, isServiceQuestion)
    -- Skill-ups need a profession named.
    for _, pattern in ipairs(SKILLUP_PATTERNS) do
        local s = q:match(pattern)
        local prof = s and professionNamed(s)
        if prof then answerSkillUp(prof); return true end
    end
    if q == "what should i craft" then
        local any
        for prof in pairs(recordedProfessions()) do any = true; answerSkillUp(prof) end
        if not any then say("Open a profession window once so I can read your recipes, then ask again.") end
        return true
    end
    for _, pattern in ipairs(MATS_PATTERNS) do
        local s = q:match(pattern)
        if s and not professionNamed(s) then
            local count = tonumber(s:match("^(%d+) ")) or tonumber(s:match(" x ?(%d+)$")) or tonumber(s:match(" (%d+)$"))
            s = s:gsub("^%d+ ", ""):gsub(" x ?%d+$", ""):gsub(" %d+$", ""):gsub("^an? ", ""):gsub("^the ", "")
            local recipe, prof
            if not AskBot.asker then recipe, prof = knownRecipe(s) end
            if recipe then answerMats(recipe, prof, count); return true end
            -- Not one of yours: where to learn it (or how to let AskBot read your recipes).
            local isRecipe = false
            local key = D.NameKey(s)
            for _, e in ipairs(D.recipeItems) do if e[1] == key then isRecipe = true; break end end
            if isRecipe then
                if not next(recordedProfessions()) then
                    say(GREY .. "I haven't seen your recipes yet: open your profession window once.|r")
                end
                say("You don't know how to make that yet.")
                answerRecipe(s)
                return true
            end
            if pattern ~= "^how do i make (.+)$" and pattern ~= "^how to make (.+)$" and pattern ~= "^can i make (.+)$" then
                say(next(recordedProfessions()) and ("None of your recipes makes \"" .. s .. "\".")
                    or "Open your profession window once so I can read your recipes, then ask again.")
                return true
            end
        end
    end
    for _, pattern in ipairs(RECIPE_PATTERNS) do
        local s = q:match(pattern)
        if s and not professionNamed(s) and not isServiceQuestion() then
            s = s:gsub("^an? ", ""):gsub("^the ", "")
            answerRecipe(s)
            return true
        end
    end
    return false
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
-- Understanding the question
--------------------------------------------------------------------------------------------

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

local INTENTS = {
    { "whoHas", {
        "^who has (.+)$", "^who needs (.+)$", "^who else has (.+)$", "^who else needs (.+)$",
        "^who in my group has (.+)$", "^who in my group needs (.+)$", "^who in the group has (.+)$",
        "^who is on (.+)$", "^who is doing (.+)$", "^does anyone have (.+)$", "^does anyone need (.+)$",
        "^group progress for (.+)$", "^group progress on (.+)$", "^party progress for (.+)$" } },
    { "prep", {
        "^prep for (.+)$", "^prepare for (.+)$", "^preparing for (.+)$", "^get ready for (.+)$", "^ready for (.+)$",
        "^am i ready for (.+)$", "^(.+) prep$", "^quests for (.+)$", "^quests in (.+)$", "^what quests are in (.+)$",
        "^what quests are there for (.+)$", "^what quests for (.+)$", "^which quests for (.+)$",
        "^dungeon quests for (.+)$", "^(.+) quests$" } },
    { "chain", {
        "^how do i unlock (.+)$", "^how to unlock (.+)$", "^how do i get to (.+)$", "^unlock (.+)$",
        "^why cant i get (.+)$", "^why can i not get (.+)$", "^why dont i have (.+)$", "^what do i need for (.+)$",
        "^what do i need to do before (.+)$", "^what do i need before (.+)$", "^what comes before (.+)$",
        "^what is before (.+)$", "^before (.+)$", "^prerequisites? for (.+)$", "^prereqs? for (.+)$",
        "^requirements for (.+)$", "^chain for (.+)$", "^quest chain for (.+)$", "^(.+) prerequisites?$",
        "^(.+) prereqs?$", "^(.+) chain$" } },
    { "after", {
        "^what comes after (.+)$", "^what is after (.+)$", "^what is next after (.+)$", "^next after (.+)$",
        "^what follows (.+)$", "^what does (.+) unlock$", "^what does (.+) lead to$", "^after (.+)$" } },
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
    { "gather", {
        "^where can i mine (.+)$", "^where do i mine (.+)$", "^where to mine (.+)$", "^where should i mine (.+)$",
        "^where can i pick (.+)$", "^where do i pick (.+)$", "^where to pick (.+)$", "^where should i pick (.+)$",
        "^where can i gather (.+)$", "^where do i gather (.+)$", "^where to gather (.+)$", "^where can i herb (.+)$",
        "^where can i fish for (.+)$", "^where do i fish for (.+)$", "^where to fish for (.+)$", "^where can i fish (.+)$",
        "^mine (.+)$", "^pick (.+)$", "^gather (.+)$", "^fish for (.+)$",
        "^where are (.+) nodes?$", "^where is (.+) nodes?$", "^where are (.+) veins$", "^(.+) nodes?$" } },
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
    { "group", {
        "^where is my party", "^where are my party", "^where is my group", "^where are my group", "^where is my raid",
        "^where is everyone", "^where is everybody", "^where are my friends", "^where are my mates",
        "^find my party", "^find my group", "^where is the group", "^where is the party", "^party members?$" } },
    { "mineBest", {
        "^where can i mine$", "^where should i mine$", "^where do i mine$", "^where to mine$", "^what can i mine$",
        "^what should i mine$", "^where should i go mining$", "^where to go mining$", "^where can i go mining$",
        "^where should i level mining$", "^where to level mining$", "^where do i level mining$", "^levell?ing mining$",
        "^level mining$", "^mining nodes$", "^ore$", "^ores$" } },
    { "herbBest", {
        "^where can i herb$", "^where should i herb$", "^where do i herb$", "^where to herb$",
        "^where can i pick herbs$", "^where should i pick herbs$", "^where to pick herbs$", "^where can i find herbs$",
        "^where can i gather herbs$", "^where to gather herbs$", "^what herbs can i pick$", "^what herbs can i gather$",
        "^what should i pick$", "^where should i go herbing$", "^where to go herbing$", "^where should i level herbalism$",
        "^where to level herbalism$", "^where do i level herbalism$", "^levell?ing herbalism$", "^level herbalism$",
        "^herbs$", "^herb nodes$" } },
    { "questNext", {
        "^where should i quest", "^where can i quest", "^where to quest", "^where do i quest", "^where shall i quest",
        "^what should i quest", "^where should i go next", "^where should i go now", "^where next$", "^where now$",
        "^where to go next", "^where do i go next", "^quest next$", "^questing next$" } },
    { "handIn", {
        "^hand ?ins?$", "^turn ?ins?$", "^hand ?in route", "^turn ?in route", "^route to hand in", "^where do i hand in$",
        "^where do i turn in$", "^where do i hand in my quests", "^where do i turn in my quests", "^where to hand in$",
        "^where to turn in$", "^where can i hand in$", "^where can i turn in$", "^hand in my quests", "^turn in my quests",
        "^hand in everything", "^turn in everything", "^ready to hand in$", "^what can i hand in", "^what can i turn in" } },
    { "tidy", {
        "^tidy", "^clean ?up", "^clear ?up", "^sort out my quest", "^what should i abandon", "^what can i abandon",
        "^which quests should i abandon", "^what quests should i abandon", "^which quests can i abandon",
        "^what quests can i abandon", "^abandon", "^what should i drop", "^which quests should i drop",
        "^what quests should i drop", "^drop quests", "^my quest log is full", "^quest log full", "^log full",
        "^gr[ae]y quests" } },
    { "zones", {
        "^where should i go at (%d+)$", "^where do i go at (%d+)$", "^where to go at (%d+)$", "^where should i be at (%d+)$",
        "^where next at (%d+)$", "^next zone at (%d+)$", "^zones? debug$", "^zones? for level (%d+)$", "^level (%d+) zones?$", "^where should i level at (%d+)$", "^where to level at (%d+)$",
        "^where should i level", "^where to level", "^where do i level", "^where can i level", "^where should i go$",
        "^zones?$", "^zones? for me$", "^zones? for my level$", "^what zones?", "^which zones?", "^best zones?",
        "^levell?ing zones?", "^where to go$" } },
    { "next", {
        "^what is next$", "^whats next$", "^what next$", "^next$", "^what now$", "^what should i do",
        "^what do i do", "^what can i do", "^what to do", "^what shall i do", "^im bored", "^next steps?$" } },
    { "questLog", {
        "^my quests$", "^quest log$", "^questlog$", "^my quest log$", "^todo$", "^to do$", "^my objectives$",
        "^quest objectives$", "^objectives$" } },
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
        if intent == "whoHas" then return answerWhoHas(nil, tonumber(questId)) end
        if intent == "chain" then return answerChain(nil, tonumber(questId)) end
        if intent == "after" then return answerAfter(nil, tonumber(questId)) end
        return answerQuest(nil, intent == "questEnd" and "end" or intent == "questStart" and "start" or "auto", { tonumber(questId) })
    end
    -- Professions: "mats for Linen Bag", "recipe for X", "how do I level tailoring"
    if professionQuestion(q, function() return findTarget(q) ~= nil end) then return end

    if itemId then
        local id = tonumber(itemId)
        local hits = { { nil, id, itemName(id) } }
        -- "is [item] an upgrade?", "[item] better for tank?" (the item's name doesn't count)
        local rest = normalize((question:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|H.-|h.-|h", " "):gsub("|r", "")))
        if asksUpgrade(rest) and isGear(id) and not AskBot.asker then return answerIsUpgrade(id, wordSet(rest)) end
        if intent == "price" then return answerPrice(nil, hits) end
        local mode = (intent == "buy" or intent == "drop") and intent or "get"
        answerItem(nil, mode, hits)
        -- A bare shift-clicked piece of gear also says whether it's an upgrade.
        if not intent and rest == "" and isGear(id) then answerIsUpgrade(id, {}, "  ") end
        return
    end

    -- "/ab target": whatever you have targeted, as if you'd typed its name.
    if q == "target" or q == "my target" or q == "this" or q == "who is this" or q == "who is my target" then
        local name = UnitExists and UnitExists("target") and UnitName("target")
        if not name then return say("Target something first, then ask " .. GOLD .. "/ab target|r.") end
        if UnitIsPlayer and UnitIsPlayer("target") then return answerPerson(name:lower()) or say(name .. " is a player.") end
        return answer(name)
    end

    -- "is Militia Leggings an upgrade?" by name
    for _, pattern in ipairs(UPGRADE_NAME_PATTERNS) do
        local name = q:match(pattern)
        if name then
            name = name:gsub("^the ", ""):gsub("^my ", "")
            local hits = exactHits(D.itemNames, name)
            if hits and isGear(hits[1][2]) and not AskBot.asker then return answerIsUpgrade(hits[1][2], wordSet(q)) end
        end
    end

    local gearSlots, gearWords = gearQuestion(q)
    if gearSlots then return answerUpgrades(gearSlots, gearWords) end

    for _, entry in ipairs(SPECIAL) do
        for _, pattern in ipairs(entry[2]) do
            local found, _, arg = q:find(pattern)
            if found then
                if entry[1] == "group" then return answerGroup() end
                if entry[1] == "mineBest" then return answerGatherBest("Mining") end
                if entry[1] == "herbBest" then return answerGatherBest("Herbalism") end
                if entry[1] == "next" then return answerPlan() end
                if entry[1] == "questLog" then return answerQuestLog() end
                if entry[1] == "handIn" then return answerHandInRoute() end
                if entry[1] == "tidy" then return answerTidy() end
                if entry[1] == "questNext" then return answerWhereToQuest() end
                if entry[1] == "questsHere" then
                    local r = answerQuestsHere()
                    if r then autoPin(r.place, r.spawn, "quests") end
                    return
                end
                if entry[1] == "zones" then
                    local r = answerZones(tonumber(arg), nil, nil, q:find("debug") ~= nil)
                    if r then autoPin(r.place, r.spawn, "quests") end
                    return
                end
                if entry[1] == "dungeons" then return answerDungeons(tonumber(arg)) end
                if entry[1] == "rares" then return answerRares() end
            end
        end
    end

    -- "where is Buddy": a group or guild member by name
    local person = q:match("^where is (.+)$") or q:match("^where are (.+)$") or q:match("^find (.+)$")
        or q:match("^locate (.+)$")
    if person and answerPerson(person) then return end

    -- "what do I need before Deadmines", "SFK quests": a dungeon. Quest chains need the
    -- dungeon's whole name or short name; anything else is a quest.
    if intent == "whoHas" then return answerWhoHas(subject) end
    if intent == "prep" or intent == "chain" then
        local d = findDungeon(subject, intent == "chain")
        if d then return answerDungeonPrep(d) end
        if intent == "prep" then intent = nil end
    end

    if intent == "gather" or intent == "get" then
        -- "where can I mine copper", "where do I get Peacebloom": a gathering node beats the
        -- item's other sources. Unknown names fall through to the item/NPC/quest search.
        local nodes = gatherLookup(subject, intent == "gather" and "fuzzy" or "suffix")
        if nodes then return answerGather(nodes) end
        intent = "get"
    end

    if intent == "chain" then
        return answerChain(subject)
    elseif intent == "after" then
        return answerAfter(subject)
    elseif intent == "loot" then
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
    local nodes = gatherLookup(subject2)
    if nodes then return answerGather(nodes) end
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

    say("Sorry, I don't know how to answer that yet. Try " .. GOLD .. (AskBot.asker and "!ask help" or "/askbot help") .. "|r.")
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
events:RegisterEvent("ZONE_CHANGED_NEW_AREA")
-- Profession window events differ between clients (classic trade skills and crafts, or the
-- modern C_TradeSkillUI); registering one the client lacks is an error, so try each.
for _, event in ipairs({ "TRADE_SKILL_SHOW", "TRADE_SKILL_UPDATE", "TRADE_SKILL_LIST_UPDATE",
    "TRADE_SKILL_DATA_SOURCE_CHANGED", "CRAFT_SHOW", "CRAFT_UPDATE" }) do
    local valid = not (C_EventUtils and C_EventUtils.IsEventValid) or C_EventUtils.IsEventValid(event)
    if valid then pcall(events.RegisterEvent, events, event) end
end
local recordTimer
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
    elseif event:find("^TRADE_SKILL") or event:find("^CRAFT") then
        -- The window fires many updates; read it once things settle.
        local kind = event:find("^CRAFT") and "craft" or "trade"
        if recordTimer then recordTimer:Cancel() end
        recordTimer = C_Timer.NewTimer(0.5, function()
            local ok, err = pcall(recordRecipes, kind)
            if not ok and geterrorhandler then geterrorhandler()(err) end
        end)
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        -- Let the map settle before asking which zone this is.
        C_Timer.After(3, function()
            local ok, err = pcall(checkRares)
            if not ok and geterrorhandler then geterrorhandler()(err) end
        end)
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
    say("Ask me where things are. Levelling: " .. GOLD .. "/ab what should I do|r, " .. GOLD .. "/ab my quests|r, "
        .. GOLD .. "/ab where should I quest next|r, " .. GOLD .. "/ab quests here|r, " .. GOLD .. "/ab zones|r, " .. GOLD .. "/ab dungeons|r, " .. GOLD .. "/ab rares|r. Examples:")
    say("  /askbot hand in route    /askbot which quests should I abandon    /askbot where should I go at 24")
    say("  /askbot where is my nearest skinning trainer")
    say("  /askbot nearest flight master    /askbot where's my class trainer")
    say("  /askbot who gives The Defias Brotherhood    /askbot turn in Bounty on Murlocs")
    say("  /askbot where can I buy Coarse Thread    /askbot where does Linen Cloth drop")
    say("  /askbot where is Gryan Stoutmantle    /askbot [shift-click an item or quest]")
    say("  /askbot what does VanCleef drop    /askbot Deadmines loot    /askbot price of Linen Cloth")
    say("  /askbot what do I need before [quest]    /askbot what comes after [quest]")
    say("  /askbot what do I need before Deadmines    /askbot who has [quest]")
    say("  /askbot where can I mine copper    /askbot Peacebloom    /askbot where should I mine")
    say("  /askbot upgrades    /askbot upgrades legs    /askbot what gear should I get as a feral druid")
    say("  /askbot is [item] an upgrade    /askbot target")
    say("  /askbot recipe for Linen Bag    /askbot mats for 5 Linen Bag    /askbot how do I level tailoring")
    say("  /askbot where is my party    /askbot where is <name>")
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


--- /ab debug item <link or ID>: the stats the game reports for an item, and how AskBot scores it.
local function debugItem(text)
    local id = tonumber(text:match("|Hitem:(%d+)") or text:match("^%s*(%d+)%s*$"))
    if not id then return say("Which item? /ab debug item [item link or ID]") end
    local G = AskBot.Gear
    AskBot.Gear.Load({ id }, function()
        local classFile = askerClass()
        local spec = G.Spec(classFile, {})
        local group, req, needs = G.Check(id, classFile, askerLevel(), G.Skills())
        local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
        local link = getInfo and select(2, getInfo(id))
        say("Item " .. id .. " " .. itemLinkText(id) .. ": slot " .. tostring(group) .. ", needs level " .. tostring(req)
            .. (needs and (", " .. needs) or ""))
        local parts = {}
        local getStats = (C_Item and C_Item.GetItemStats) or GetItemStats
        local ok, stats = pcall(getStats, link)
        for stat, value in pairs(ok and type(stats) == "table" and stats or {}) do
            parts[#parts + 1] = stat .. (G.STAT_KEYS[stat] and "" or "(?)") .. "=" .. tostring(value)
        end
        table.sort(parts)
        say("  stats: " .. (#parts > 0 and table.concat(parts, ", ") or "none reported"))
        if link then
            local merged, fromTooltip = G.Stats(link)
            local extra = {}
            for key in pairs(fromTooltip) do extra[#extra + 1] = key .. "=" .. merged[key] end
            table.sort(extra)
            if #extra > 0 then say("  from Equip: lines: " .. table.concat(extra, ", ")) end
        end
        say("  score for " .. (spec and spec.name or "?") .. ": " .. tostring(spec and link and G.Score(link, spec.weights, group == "ranged")))
    end)
end

--- /ab debug quest <link or name>: what Questie's data holds for a quest's objectives.
local function debugQuest(text)
    local id = tonumber(text:match("|Hquest:(%d+)") or text:match("|Hquestie:(%d+)") or text:match("%((%d+)%)%]")
        or text:match("^%s*(%d+)%s*$"))
    if not id then
        local plain = text:gsub("|H.-|h%[?(.-)%]?|h", "%1"):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
        plain = plain:gsub("%[%[[^%]]*%]%s*", ""):gsub("[%[%]]", "")
        local hits = D.FindByName(D.questNames, plain)
        id = hits and hits[1][2]
    end
    if not id or not QuestDB.name(id) then return say("Which quest? /ab debug quest [quest link, name or ID]") end

    say("Quest " .. id .. " " .. GOLD .. QuestDB.name(id) .. "|r, level " .. tostring(QuestDB.questLevel(id)))
    local o = QuestDB.objectives(id) or {}
    local function count(list) return list and #list or 0 end
    for _, c in ipairs(o[1] or {}) do
        local p = D.NpcPlace(c[1])
        say("  kill npc " .. c[1] .. " " .. tostring(p and p.name) .. ": " .. (p and #p.spawns or 0) .. " spawns")
    end
    for _, c in ipairs(o[2] or {}) do
        local p = D.ObjectPlace(c[1])
        say("  use object " .. c[1] .. " " .. tostring(p and p.name) .. ": " .. (p and #p.spawns or 0) .. " spawns")
    end
    for _, c in ipairs(o[3] or {}) do
        say("  collect item " .. c[1] .. " " .. itemName(c[1]) .. ": dropped by " .. count(ItemDB.npcDrops(c[1]))
            .. " npcs, " .. count(ItemDB.objectDrops(c[1])) .. " objects, inside " .. count(ItemDB.itemDrops(c[1]))
            .. " items" .. (AskBot.KNOWN.items[c[1]] and ", has a community location" or ""))
    end
    for _, c in ipairs(o[5] or {}) do
        say("  kill credit " .. tostring(c[2]) .. " from " .. count(c[1]) .. " npcs")
    end
    for _, itemId in ipairs(QuestDB.requiredSourceItems and QuestDB.requiredSourceItems(id) or {}) do
        say("  bring item " .. itemId .. " " .. itemName(itemId) .. ": " .. bagCount(itemId) .. " in your bags, dropped by "
            .. count(ItemDB.npcDrops(itemId)) .. " npcs, " .. count(ItemDB.objectDrops(itemId)) .. " objects"
            .. (AskBot.KNOWN.items[itemId] and ", has a community location" or ""))
    end
    local trigger = QuestDB.triggerEnd(id)
    if trigger then say("  explore: " .. tostring(trigger[1]) .. ", " .. #D.ResolveSpawns(trigger[2]) .. " spots") end
    local extras = QuestDB.extraObjectives and QuestDB.extraObjectives(id)
    for _, e in ipairs(type(extras) == "table" and extras or {}) do
        say("  extra: " .. tostring(e[3]) .. ", " .. #D.ResolveSpawns(e[1]) .. " spots")
    end
end

local SHARE_OPTIONS ={ guild = "shareGuild", party = "shareParty", raid = "shareParty", whisper = "shareWhisper",
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
    elseif cmd == "debug share" then
        local last = AskBot.lastAsk
        say("Last !ask: " .. (last and (tostring(last.sender) .. " (GUID " .. tostring(last.guid) .. ") asked \""
            .. tostring(last.question) .. "\", matched " .. tostring(last.unit or "no group member")) or "none yet"))
        for _, unit in ipairs(groupUnits()) do
            if UnitExists(unit) then
                say("  " .. unit .. ": " .. tostring(UnitName(unit)) .. " (GUID " .. tostring(UnitGUID and UnitGUID(unit)) .. ")")
            end
        end
    elseif cmd:match("^debug skills") then
        say("Skill APIs: GetSkillLineInfo " .. (GetSkillLineInfo and "yes" or "no") .. ", GetProfessions "
            .. (GetProfessions and "yes" or "no") .. ", GetTradeSkillLine " .. (GetTradeSkillLine and "yes" or "no")
            .. ", C_TradeSkillUI " .. (C_TradeSkillUI and "yes" or "no") .. ", GetCraftInfo " .. (GetCraftInfo and "yes" or "no") .. ".")
        local found = {}
        for _, p in ipairs({ "Tailoring", "Leatherworking", "Blacksmithing", "Alchemy", "Enchanting", "Engineering",
            "Cooking", "First Aid", "Mining", "Herbalism", "Skinning", "Fishing" }) do
            local r = professionSkill(p)
            if r ~= false then found[#found + 1] = p .. " " .. tostring(r) end
        end
        say("  Skills seen: " .. (#found > 0 and table.concat(found, ", ") or "none"))
        local rec = {}
        for prof, p in pairs(AskBotCharDB and AskBotCharDB.professions or {}) do
            local n = 0
            for _ in pairs(p.recipes or {}) do n = n + 1 end
            rec[#rec + 1] = prof .. " " .. tostring(p.rank) .. "/" .. tostring(p.max) .. " (" .. n .. " recipes)"
        end
        say("  Recipes read: " .. (#rec > 0 and table.concat(rec, ", ") or "none yet (open a profession window)"))
    elseif cmd:match("^debug item") then
        if D.status ~= "ready" then return say("Still loading, try again in a moment.") end
        debugItem(msg:sub(11))
    elseif cmd:match("^debug quest") then
        if D.status ~= "ready" then return say("Still loading, try again in a moment.") end
        debugQuest(msg:sub(12))
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


--- Questions only the asker's own AskBot can answer (they need their quest log or gear).
function AskBot.IsPersonalQuestion(question)
    local q = normalize(question)
    if gearQuestion(q) then return true end
    if personalProfession(q) then return true end
    if question:find("|Hitem:") then
        local rest = normalize((question:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|H.-|h.-|h", " "):gsub("|r", "")))
        if asksUpgrade(rest) then return true end
    end
    for _, pattern in ipairs(UPGRADE_NAME_PATTERNS) do
        if q:find(pattern) then return true end
    end
    for _, entry in ipairs(SPECIAL) do
        if entry[1] == "next" or entry[1] == "questLog" or entry[1] == "handIn" or entry[1] == "tidy"
            or entry[1] == "questsHere" or entry[1] == "questNext" or entry[1] == "zones" then
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
