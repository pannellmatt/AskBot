-- Data.lua
-- Everything that reads QuestieDB: the NPC service index, name indexes for quests, items and
-- NPCs, spawn resolution to world positions, and travel-time ranking.

local _, AskBot = ...

local D = {
    status = "waiting", -- waiting -> indexing -> ready | failed
    progress = 0,
    npcCount = 0,
    byTarget = {},      -- target id -> list of places
    questNames = {},    -- list of { key, id, displayName }
    itemNames = {},
    itemIds = {},       -- item IDs present in itemNames
    npcNames = {},
    questInfo = {},     -- quest id -> { level, req, max, npcs, objects } for quests with a giver
    rares = {},         -- npc id -> rank (2 = rare elite, 4 = rare)
}
AskBot.Data = D

local HBD, ZoneDB, flagValues

function D.Init(hbd, zoneDB, flags)
    HBD, ZoneDB, flagValues = hbd, zoneDB, flags
end

--------------------------------------------------------------------------------------------
-- Bit helpers. Forever uses bits above 32 (race masks, some NPC flags), which the client's
-- 32-bit `bit` library would truncate, so these work arithmetically.
--------------------------------------------------------------------------------------------

function D.HasBit(mask, value)
    if not mask or not value or value <= 0 then return false end
    return math.floor(mask / value) % 2 == 1
end

function D.MasksOverlap(a, b)
    if not a or not b then return false end
    local v = 1
    while v <= a and v <= b do
        if math.floor(a / v) % 2 == 1 and math.floor(b / v) % 2 == 1 then return true end
        v = v * 2
    end
    return false
end

--------------------------------------------------------------------------------------------
-- Names
--------------------------------------------------------------------------------------------

-- Lower-case, apostrophes dropped ("Mor'Ladim" -> "morladim"), other punctuation as spaces.
function D.NameKey(s)
    s = s:lower():gsub("'", ""):gsub("[^%w]", " "):gsub("%s+", " ")
    return (s:match("^%s*(.-)%s*$"))
end

--- Find entries by name: exact match first, else names containing the query, else names
--- containing every word. Among partial matches, names that `accept` (optional; given an
--- entry) approves win, then names starting with the query, then shorter names.
--- Returns the matching entries (all sharing one name) and up to three other candidate
--- names for a "did you mean" (empty when the match is exact or accepted).
function D.FindByName(list, query, accept)
    local q = D.NameKey(query)
    if q == "" then return nil end

    local exact, partial = {}, {}
    for _, e in ipairs(list) do
        if e[1] == q then
            exact[#exact + 1] = e
        elseif e[1]:find(q, 1, true) then
            partial[#partial + 1] = e
        end
    end
    if #exact > 0 then return exact, {} end

    if #partial == 0 then
        local words = {}
        for w in q:gmatch("%S+") do words[#words + 1] = w end
        if #words < 2 then return nil end
        for _, e in ipairs(list) do
            local all = true
            for _, w in ipairs(words) do
                if not e[1]:find(w, 1, true) then all = false; break end
            end
            if all then partial[#partial + 1] = e end
        end
        if #partial == 0 then return nil end
    end

    -- Score each distinct name once: accepted (any entry with that name) and prefix match.
    local accepted, prefix = {}, {}
    for _, e in ipairs(partial) do
        local k = e[1]
        if accept and not accepted[k] and accept(e) then accepted[k] = true end
        if prefix[k] == nil then prefix[k] = k:sub(1, #q) == q end
    end
    table.sort(partial, function(a, b)
        local ka, kb = a[1], b[1]
        if (accepted[ka] or false) ~= (accepted[kb] or false) then return accepted[ka] or false end
        if prefix[ka] ~= prefix[kb] then return prefix[ka] end
        if #ka ~= #kb then return #ka < #kb end
        if ka ~= kb then return ka < kb end
        -- Same name: order by ID when entries carry IDs (loot entries carry tables).
        if type(a[2]) == "number" and type(b[2]) == "number" then return a[2] < b[2] end
        return false
    end)
    local key = partial[1][1]
    local hits, others, seen = {}, {}, { [key] = true }
    for _, e in ipairs(partial) do
        if e[1] == key then
            hits[#hits + 1] = e
        elseif not seen[e[1]] and #others < 3 then
            seen[e[1]] = true
            others[#others + 1] = e[3]
        end
    end
    -- A partial match that fits the question is confident enough not to offer alternatives.
    if accepted[key] then others = {} end
    return hits, others
end

--------------------------------------------------------------------------------------------
-- Zones and spawns
--------------------------------------------------------------------------------------------

local mapCache = {}
local function uiMapFor(areaId)
    local m = mapCache[areaId]
    if m == nil then
        local ok, r = pcall(ZoneDB.GetUiMapIdByAreaId, ZoneDB, areaId)
        m = (ok and type(r) == "number" and r > 0) and r or false
        mapCache[areaId] = m
    end
    return m or nil
end

function D.ZoneName(uiMapId)
    local info = C_Map.GetMapInfo(uiMapId)
    return info and info.name or ("map " .. uiMapId)
end

function D.ResolveSpawns(spawnList)
    local out = {}
    if type(spawnList) ~= "table" then return out end
    for areaId, coords in pairs(spawnList) do
        local uiMapId = uiMapFor(areaId)
        if uiMapId and type(coords) == "table" then
            for _, c in ipairs(coords) do
                local x, y = c[1], c[2]
                if x and y and x >= 0 and y >= 0 then
                    local wx, wy, inst = HBD:GetWorldCoordinatesFromZone(x / 100, y / 100, uiMapId)
                    out[#out + 1] = { uiMapId = uiMapId, x = x, y = y, wx = wx, wy = wy, inst = inst }
                end
            end
        end
    end
    return out
end

--------------------------------------------------------------------------------------------
-- Places: an NPC or object with resolved spawns, cached.
--------------------------------------------------------------------------------------------

local npcPlaces, objectPlaces = {}, {}

function D.NpcPlace(id)
    local p = npcPlaces[id]
    if p == nil then
        local name = NpcDB.name(id)
        if name then
            p = {
                kind = "npc", id = id, name = name, sub = NpcDB.subName(id),
                faction = NpcDB.friendlyToFaction(id),
                minLevel = NpcDB.minLevel(id), maxLevel = NpcDB.maxLevel(id),
                spawns = D.ResolveSpawns(NpcDB.spawns(id)),
            }
        else
            p = false
        end
        npcPlaces[id] = p
    end
    return p or nil
end

function D.ObjectPlace(id)
    local p = objectPlaces[id]
    if p == nil then
        local name = ObjectDB.name(id)
        if name then
            p = { kind = "object", id = id, name = name, spawns = D.ResolveSpawns(ObjectDB.spawns(id)) }
        else
            p = false
        end
        objectPlaces[id] = p
    end
    return p or nil
end

function D.PlayerFaction()
    local f = UnitFactionGroup("player")
    if f == "Alliance" then return "A" elseif f == "Horde" then return "H" end
end

function D.IsFriendly(place, mine)
    return mine ~= nil and place.faction ~= nil and place.faction:find(mine, 1, true) ~= nil
end

--------------------------------------------------------------------------------------------
-- Index build (run as a coroutine; yields every few hundred records)
--------------------------------------------------------------------------------------------

local YIELD_EVERY = 400

function D.BuildIndex()
    local npcIds, questIds, itemIds = NpcDB.GetAllIds(), QuestDB.GetAllIds(), ItemDB.GetAllIds()
    local total = #npcIds * 2 + #questIds * 2 + #itemIds
    local done = 0
    local function step()
        done = done + 1
        if done % YIELD_EVERY == 0 then
            D.progress = done / total
            coroutine.yield()
        end
    end

    -- Services and trainers
    local targets = AskBot.targets
    for i = 1, #npcIds do
        local id = npcIds[i]
        local rank = NpcDB.rank(id)
        if rank == 2 or rank == 4 then D.rares[id] = rank end
        local flags = NpcDB.npcFlags(id)
        local sub = NpcDB.subName(id)
        if (flags and flags > 0) or sub then
            local subLower = sub and sub:lower()
            local hasFlag = function(name) return D.HasBit(flags, flagValues[name]) end
            local matched
            for _, t in ipairs(targets) do
                if t.test(subLower, hasFlag) then
                    matched = matched or {}
                    matched[#matched + 1] = t.id
                end
            end
            if matched then
                local place = D.NpcPlace(id)
                if place and #place.spawns > 0 then
                    for _, tid in ipairs(matched) do
                        local list = D.byTarget[tid]
                        if not list then list = {}; D.byTarget[tid] = list end
                        list[#list + 1] = place
                    end
                    D.npcCount = D.npcCount + 1
                end
            end
        end
        step()
    end

    -- Name indexes
    local function indexNames(db, ids, out, idSet)
        for i = 1, #ids do
            local name = db.name(ids[i])
            if name then
                out[#out + 1] = { D.NameKey(name), ids[i], name }
                if idSet then idSet[ids[i]] = true end
            end
            step()
        end
    end
    indexNames(NpcDB, npcIds, D.npcNames)
    indexNames(QuestDB, questIds, D.questNames)
    indexNames(ItemDB, itemIds, D.itemNames, D.itemIds)

    -- Quest givers and level ranges, for "quests near me"
    for i = 1, #questIds do
        local id = questIds[i]
        local by = QuestDB.startedBy(id)
        local npcs, objects = by and by[1], by and by[2]
        if (npcs and #npcs > 0) or (objects and #objects > 0) then
            D.questInfo[id] = {
                level = QuestDB.questLevel(id), req = QuestDB.requiredLevel(id),
                max = QuestDB.requiredMaxLevel(id), npcs = npcs, objects = objects,
            }
        end
        step()
    end
end

--------------------------------------------------------------------------------------------
-- Flight paths
--------------------------------------------------------------------------------------------

--- Friendly flight masters, limited to the ones this character is known to have when
--- AskBot has seen a flight map; otherwise all of them (and `assumed` is true).
function D.FlightMasters()
    local mine = D.PlayerFaction()
    local known = AskBotCharDB and AskBotCharDB.knownTaxi
    local useKnown = known and next(known) ~= nil
    local out = {}
    for _, p in ipairs(D.byTarget.flight or {}) do
        if D.IsFriendly(p, mine) and (not useKnown or known[p.id]) then
            out[#out + 1] = p
        end
    end
    return out, not useKnown
end

local function nearestFlightMaster(inst, x, y, fms)
    local bestPlace, bestSpawn, bestDist
    for _, p in ipairs(fms) do
        for _, s in ipairs(p.spawns) do
            if s.wx and s.inst == inst then
                local d = HBD:GetWorldDistance(inst, x, y, s.wx, s.wy)
                if d and (not bestDist or d < bestDist) then
                    bestPlace, bestSpawn, bestDist = p, s, d
                end
            end
        end
    end
    return bestPlace, bestSpawn, bestDist
end

--- Learn known flight paths from an open flight map, matching each taxi node to the
--- flight master NPC standing there.
function D.RecordTaxiNodes()
    if D.status ~= "ready" or not (C_TaxiMap and C_TaxiMap.GetAllTaxiNodes and GetTaxiMapID) then return 0 end
    local mapID = GetTaxiMapID()
    if not mapID then return 0 end
    local nodes = C_TaxiMap.GetAllTaxiNodes(mapID) or {}
    local unreachable = Enum and Enum.FlightPathState and Enum.FlightPathState.Unreachable or 2
    local mine = D.PlayerFaction()
    local all = {}
    for _, p in ipairs(D.byTarget.flight or {}) do
        if D.IsFriendly(p, mine) then all[#all + 1] = p end
    end
    AskBotCharDB.knownTaxi = AskBotCharDB.knownTaxi or {}
    local learned = 0
    for _, node in ipairs(nodes) do
        if node.state ~= unreachable and node.position then
            local wx, wy, inst = HBD:GetWorldCoordinatesFromZone(node.position.x, node.position.y, mapID)
            if wx then
                local fm, _, d = nearestFlightMaster(inst, wx, wy, all)
                if fm and d < 250 then
                    if not AskBotCharDB.knownTaxi[fm.id] then learned = learned + 1 end
                    AskBotCharDB.knownTaxi[fm.id] = true
                end
            end
        end
    end
    return learned
end

--------------------------------------------------------------------------------------------
-- Travel ranking
--------------------------------------------------------------------------------------------

local RUN_SPEED = 7          -- yards/second on foot
local MOUNT_MULTIPLIER = 1.6 -- level 40 mount
local FLY_SPEED = 30         -- yards/second on a flight path
local FLY_PATH_FACTOR = 1.25 -- flight routes aren't straight lines
local FLY_OVERHEAD = 15      -- seconds for take-off, landing, the flight map

local function runSpeed()
    local mounted = IsMounted and IsMounted()
    if mounted or (UnitLevel("player") or 1) >= 40 then
        return RUN_SPEED * MOUNT_MULTIPLIER
    end
    return RUN_SPEED
end

--- Rank places by estimated travel time from the player.
--- Each result: { place, spawn, dist (yards, same continent only), time (seconds), route }
--- where route = { from = spawn, to = spawn } when flying is quicker.
function D.Rank(places)
    local px, py, pinst = HBD:GetPlayerWorldPosition()
    local run = runSpeed()
    local fms = D.FlightMasters()
    local _, startFm, startFmDist
    if px then _, startFm, startFmDist = nearestFlightMaster(pinst, px, py, fms) end

    local results = {}
    for _, place in ipairs(places) do
        -- The spawn nearest in a straight line on the player's continent, else the first one.
        local spawn, dist
        for _, s in ipairs(place.spawns) do
            if px and s.wx and s.inst == pinst then
                local d = HBD:GetWorldDistance(pinst, px, py, s.wx, s.wy)
                if d and (not dist or d < dist) then spawn, dist = s, d end
            end
        end
        spawn = spawn or place.spawns[1]

        if spawn then
            local time, route
            if dist then time = dist / run end
            if startFm and spawn.wx then
                local _, endFm, endFmDist = nearestFlightMaster(spawn.inst, spawn.wx, spawn.wy, fms)
                if endFm and endFm ~= startFm and endFm.inst == startFm.inst then
                    local flight = HBD:GetWorldDistance(endFm.inst, startFm.wx, startFm.wy, endFm.wx, endFm.wy)
                    local t = startFmDist / run + flight * FLY_PATH_FACTOR / FLY_SPEED + endFmDist / run + FLY_OVERHEAD
                    if not time or t < time * 0.85 then
                        time, route = t, { from = startFm, to = endFm }
                    end
                end
            end
            results[#results + 1] = { place = place, spawn = spawn, dist = dist, time = time, route = route }
        end
    end

    table.sort(results, function(a, b)
        if a.time and b.time then return a.time < b.time end
        if a.time or b.time then return a.time ~= nil end
        return a.place.name < b.place.name
    end)
    return results, px ~= nil
end
