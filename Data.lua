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
    unlocks = {},       -- quest id -> quests that list it as a prerequisite
    givenBy = {},       -- item id -> quests that hand it to you when you take them
    questRewardItems = {}, -- quest id -> items it rewards
    gearItems = {},     -- list of { itemId, requiredLevel } for weapons and armour
    rares = {},         -- npc id -> rank (2 = rare elite, 4 = rare)
    rareDrops = {},     -- rare npc id -> list of gear item ids it drops
    beasts = {},        -- npc ids of hostile, non-elite beasts (by name), for skinning
    recipeItems = {},   -- list of { key of what it teaches, item id, recipe name, kind ("Pattern") }
    gather = {},        -- node name -> { name, prof, skill, special, items, ids }
    gatherKeys = {},    -- name key (node or item) -> { display, nodes = { node names } }
    gatherNames = {},   -- list of { key, key, displayName } for FindByName
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
-- Recipe item prefixes -> the professions they can be for.
D.RECIPE_KINDS = {
    Pattern = { "Tailoring", "Leatherworking" }, Plans = { "Blacksmithing" }, Formula = { "Enchanting" },
    Recipe = { "Alchemy", "Cooking" }, Schematic = { "Engineering" }, Manual = { "First Aid" },
}

function D.NameKey(s)
    s = s:lower():gsub("'", ""):gsub("[^%w]", " "):gsub("%s+", " ")
    return (s:match("^%s*(.-)%s*$"))
end

--- Are these the same player's name? Ignores realms ("Name-Realm") and case, and accepts a
--- first name against a full one ("Holycell" vs "Holycell Elvendetta").
function D.SameName(a, b)
    if not a or not b then return false end
    a = (a:match("^([^%-]+)") or a):lower():match("^%s*(.-)%s*$")
    b = (b:match("^([^%-]+)") or b):lower():match("^%s*(.-)%s*$")
    if a == b then return true end
    local fa, fb = a:match("^(%S+)"), b:match("^(%S+)")
    return fa ~= nil and fa == fb and (fa == a or fb == b)
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

-- Dungeons by area ID (main and alternative IDs), from Questie's dungeon table.
-- Each entry: { name, areaId, areaIds = { main and alternatives }, entrances }.
local dungeonByArea, dungeonNames
local function loadDungeons()
    if dungeonByArea then return end
    dungeonByArea, dungeonNames = {}, {}
    local ok, list = pcall(function() return ZoneDB:GetDungeons() end)
    if ok and type(list) == "table" then
        for id, d in pairs(list) do
            if type(d) == "table" and type(d[1]) == "string" then
                local entry = { name = d[1], areaId = id, areaIds = { id }, entrances = d[4] }
                dungeonByArea[id] = entry
                for _, alt in ipairs(type(d[2]) == "table" and d[2] or {}) do
                    dungeonByArea[alt] = dungeonByArea[alt] or entry
                    entry.areaIds[#entry.areaIds + 1] = alt
                end
                dungeonNames[#dungeonNames + 1] = { D.NameKey(d[1]), entry, d[1] }
            end
        end
    end
end

local function dungeonFor(areaId)
    loadDungeons()
    return dungeonByArea[areaId]
end

--- Questie's dungeons as a name list for D.FindByName: { key, entry, name }.
function D.DungeonNames()
    loadDungeons()
    return dungeonNames
end

--- Spawns at a dungeon's entrance(s), each marked with the dungeon's name; nil if the area
--- isn't a dungeon Questie knows the entrance of.
function D.DungeonEntranceSpawns(areaId)
    local d = dungeonFor(areaId)
    if not d then return nil end
    if not d.spawns then
        d.spawns = {}
        for _, e in ipairs(type(d.entrances) == "table" and d.entrances or {}) do
            local uiMapId = uiMapFor(e[1])
            if uiMapId then
                local wx, wy, inst = HBD:GetWorldCoordinatesFromZone(e[2] / 100, e[3] / 100, uiMapId)
                d.spawns[#d.spawns + 1] = { uiMapId = uiMapId, x = e[2], y = e[3], wx = wx, wy = wy, inst = inst, dungeon = d.name }
            end
        end
    end
    return #d.spawns > 0 and d.spawns or nil
end

function D.ResolveSpawns(spawnList)
    local out = {}
    if type(spawnList) ~= "table" then return out end
    for areaId, coords in pairs(spawnList) do
        local uiMapId = uiMapFor(areaId)
        local inside = not uiMapId
        if type(coords) == "table" then
            for _, c in ipairs(coords) do
                local x, y = c[1], c[2]
                if uiMapId and x and y and x >= 0 and y >= 0 then
                    local wx, wy, inst = HBD:GetWorldCoordinatesFromZone(x / 100, y / 100, uiMapId)
                    out[#out + 1] = { uiMapId = uiMapId, x = x, y = y, wx = wx, wy = wy, inst = inst }
                else
                    inside = true -- Questie writes -1, -1 for spawns inside dungeons
                end
            end
        end
        if inside then
            for _, s in ipairs(D.DungeonEntranceSpawns(areaId) or {}) do out[#out + 1] = s end
        end
    end
    return out
end

--- Spawns from map points { { uiMapId, x, y }, ... } (x, y in percent).
function D.SpawnsFromMapPoints(points)
    local out = {}
    for _, p in ipairs(points or {}) do
        local wx, wy, inst = HBD:GetWorldCoordinatesFromZone(p[2] / 100, p[3] / 100, p[1])
        out[#out + 1] = { uiMapId = p[1], x = p[2], y = p[3], wx = wx, wy = wy, inst = inst }
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

--- A gathering node type (all objects sharing a name) as one place, with every spawn point
--- of every object, duplicates removed. Cached.
local gatherPlaces = {}
function D.GatherPlace(name)
    local p = gatherPlaces[name]
    if p then return p end
    local node = D.gather[name]
    if not node then return nil end
    p = { kind = "object", id = node.ids[1], name = name, spawns = {}, node = node }
    local seen = {}
    for _, id in ipairs(node.ids) do
        local op = D.ObjectPlace(id)
        for _, s in ipairs(op and op.spawns or {}) do
            local k = s.uiMapId .. ":" .. math.floor(s.x * 10 + 0.5) .. ":" .. math.floor(s.y * 10 + 0.5)
            if not seen[k] then
                seen[k] = true
                p.spawns[#p.spawns + 1] = s
            end
        end
    end
    gatherPlaces[name] = p
    return p
end

local function addGatherKey(name, node)
    local key = D.NameKey(name)
    local e = D.gatherKeys[key]
    if not e then
        e = { display = name, nodes = {} }
        D.gatherKeys[key] = e
        D.gatherNames[#D.gatherNames + 1] = { key, key, name }
    end
    for _, n in ipairs(e.nodes) do if n == node then return end end
    e.nodes[#e.nodes + 1] = node
end

function D.PlayerFaction()
    local f = UnitFactionGroup("player")
    if f == "Alliance" then return "A" elseif f == "Horde" then return "H" end
end

--- Where a group member is right now, as a spawn; nil when unknown. The second value is
--- the map they're on when there's no exact position (e.g. inside a dungeon).
function D.UnitSpawn(unit)
    local uiMapId = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit(unit)
    local wx, wy, inst = HBD:GetUnitWorldPosition(unit)
    if not (wx and uiMapId) then return nil, uiMapId end
    local zx, zy = HBD:GetZoneCoordinatesFromWorld(wx, wy, uiMapId)
    if not zx then return nil, uiMapId end
    return { uiMapId = uiMapId, x = zx * 100, y = zy * 100, wx = wx, wy = wy, inst = inst }
end

--- Spawns for a community location from KnownLocations.lua (see the format there), for
--- your faction. Empty when it has nothing for you.
function D.KnownSpawns(loc)
    if not loc then return {} end
    if loc.object then local p = D.ObjectPlace(loc.object); return p and p.spawns or {} end
    if loc.npc then local p = D.NpcPlace(loc.npc); return p and p.spawns or {} end
    if loc.dungeon then return D.DungeonEntranceSpawns(loc.dungeon) or {} end
    return D.SpawnsFromMapPoints(loc[D.PlayerFaction() or ""] or loc.N)
end

--- A place for a community location, named by its note (or `name`); nil when it has nothing
--- for you.
function D.KnownPlace(loc, name)
    local spawns = D.KnownSpawns(loc)
    if #spawns == 0 then return nil end
    return { kind = "known", name = loc.note or name or "?", spawns = spawns }
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
    local objectIds = ObjectDB.GetAllIds and ObjectDB.GetAllIds() or {}
    local total = #npcIds * 2 + #questIds * 2 + #itemIds * 2 + #objectIds
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
        if rank == 0 and not NpcDB.friendlyToFaction(id) then
            local name = NpcDB.name(id)
            if name and AskBot.IsBeastName(name) then D.beasts[#D.beasts + 1] = id end
        end
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

    -- Recipe items ("Pattern: Linen Bag"), keyed by what they teach
    for _, e in ipairs(D.itemNames) do
        local kind, taught = e[3]:match("^(%a+): (.+)$")
        if kind and D.RECIPE_KINDS[kind] then
            D.recipeItems[#D.recipeItems + 1] = { D.NameKey(taught), e[2], e[3], kind }
        end
    end

    -- Gear and quest rewards, for "/ab upgrades"
    local classOf, reqOf = ItemDB.class, ItemDB.requiredLevel
    for i = 1, #itemIds do
        local id = itemIds[i]
        local cls = classOf and classOf(id)
        if cls == 2 or cls == 4 then
            D.gearItems[#D.gearItems + 1] = { id, (reqOf and reqOf(id)) or 0 }
            for _, npc in ipairs(ItemDB.npcDrops(id) or {}) do
                if D.rares[npc] then
                    local list = D.rareDrops[npc]
                    if not list then list = {}; D.rareDrops[npc] = list end
                    list[#list + 1] = id
                end
            end
            for _, q in ipairs(ItemDB.questRewards(id) or {}) do
                local list = D.questRewardItems[q]
                if not list then list = {}; D.questRewardItems[q] = list end
                list[#list + 1] = id
            end
        end
        step()
    end

    -- Gathering nodes: mining veins, herbs, fishing schools
    for i = 1, #objectIds do
        local id = objectIds[i]
        local name = ObjectDB.name(id)
        local def = name and AskBot.GatherNodeFor(name)
        if def then
            local node = D.gather[name]
            if not node then
                node = { name = name, prof = def[1], skill = def[2], items = def[3], special = def.special, ids = {} }
                D.gather[name] = node
                addGatherKey(name, name)
                for _, item in ipairs(def[3]) do addGatherKey(item, name) end
            end
            node.ids[#node.ids + 1] = id
        end
        step()
    end

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
        -- Items a quest hands you when you take it, for "where do I get another one?"
        local given = QuestDB.sourceItemId and QuestDB.sourceItemId(id)
        if type(given) == "number" and given > 0 then
            local list = D.givenBy[given]
            if not list then list = {}; D.givenBy[given] = list end
            list[#list + 1] = id
        end
        -- Reverse the prerequisite links, for "what comes after X?"
        for _, field in ipairs({ "preQuestSingle", "preQuestGroup" }) do
            for _, pre in ipairs(QuestDB[field] and QuestDB[field](id) or {}) do
                if pre > 0 then
                    local list = D.unlocks[pre]
                    if not list then list = {}; D.unlocks[pre] = list end
                    list[#list + 1] = id
                end
            end
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
    -- Town names ("Lakeshire, Redridge" -> "Lakeshire") are the same for everyone: account-wide.
    local names = AskBotDB and AskBotDB.taxiNames
    if AskBotDB and not names then names = {}; AskBotDB.taxiNames = names end
    local learned = 0
    for _, node in ipairs(nodes) do
        if node.position then
            local wx, wy, inst = HBD:GetWorldCoordinatesFromZone(node.position.x, node.position.y, mapID)
            if wx then
                local fm, _, d = nearestFlightMaster(inst, wx, wy, all)
                if fm and d < 250 then
                    if names and node.name then names[fm.id] = node.name:match("^%s*([^,]+)") end
                    if node.state ~= unreachable then
                        if not AskBotCharDB.knownTaxi[fm.id] then learned = learned + 1 end
                        AskBotCharDB.knownTaxi[fm.id] = true
                    end
                end
            end
        end
    end
    return learned
end

--- Yards between two resolved spawns on the same continent, or nil.
function D.SpawnDistance(a, b)
    if not (a and b and a.wx and b.wx) or a.inst ~= b.inst then return nil end
    return HBD:GetWorldDistance(a.inst, a.wx, a.wy, b.wx, b.wy)
end

--- The friendly flight master serving the town around `spawn` (within 600 yards):
--- the flight master's place, its town name if a flight map has shown it, and whether
--- you have that flight path (nil when AskBot hasn't learned your flight paths yet).
function D.TownFlight(spawn)
    if not (spawn and spawn.wx) then return nil end
    local mine = D.PlayerFaction()
    local all = {}
    for _, p in ipairs(D.byTarget.flight or {}) do
        if D.IsFriendly(p, mine) then all[#all + 1] = p end
    end
    local fm, _, d = nearestFlightMaster(spawn.inst, spawn.wx, spawn.wy, all)
    if not fm or d > 600 then return nil end
    local known = AskBotCharDB and AskBotCharDB.knownTaxi
    local learned
    if known and next(known) ~= nil then learned = known[fm.id] == true end
    return fm, AskBotDB and AskBotDB.taxiNames and AskBotDB.taxiNames[fm.id], learned
end

--------------------------------------------------------------------------------------------
-- Travel ranking
--------------------------------------------------------------------------------------------


local RUN_SPEED = 7          -- yards/second on foot
local MOUNT_MULTIPLIER = 1.6 -- level 40 mount
local FLY_SPEED = 30         -- yards/second on a flight path
local FLY_PATH_FACTOR = 1.25 -- flight routes aren't straight lines
local FLY_OVERHEAD = 15      -- seconds for take-off, landing, the flight map
local TRANSPORT_TIME = { boat = 180, zeppelin = 150 } -- average wait plus crossing, seconds

-- Boats and zeppelins: { faction ("A", "H" or "N" for both), kind, dock, dock },
-- each dock { uiMapId, x, y, name }. Every route runs both ways.
local TRANSPORTS = {
    { "A", "boat", { 1424, 50.7, 70.4, "Southshore" }, { 1439, 32.3, 44.1, "Auberdine" } },
    { "A", "boat", { 1439, 32.3, 44.1, "Auberdine" }, { 1437, 4.5, 56.7, "Menethil Harbor" } },
    { "A", "boat", { 1437, 4.5, 56.7, "Menethil Harbor" }, { 1424, 50.7, 70.4, "Southshore" } },
    { "A", "boat", { 1437, 4.7, 63.8, "Menethil Harbor" }, { 1445, 71.7, 56.7, "Theramore" } },
    { "A", "boat", { 1453, 21.8, 56.9, "Stormwind Harbor" }, { 1439, 30.5, 40.9, "Auberdine" } },
    { "A", "boat", { 1439, 33.3, 39.8, "Auberdine" }, { 1438, 54.8, 97.2, "Rut'theran Village" } },
    { "A", "boat", { 1416, 12.8, 51.2, "Alterac Mountains" }, { 2521, 65.8, 83.8, "Zephras Isle" } },
    { "H", "zeppelin", { 1420, 60.6, 58.9, "Undercity" }, { 1411, 51.0, 13.9, "Orgrimmar" } },
    { "H", "zeppelin", { 1420, 61.9, 58.9, "Undercity" }, { 1434, 31.5, 29.1, "Grom'gol" } },
    { "H", "zeppelin", { 1411, 50.5, 12.7, "Orgrimmar" }, { 1434, 31.2, 30.4, "Grom'gol" } },
    { "H", "zeppelin", { 1412, 34.3, 26.1, "Mulgore" }, { 2521, 57.7, 81.0, "Zephras Isle" } },
    { "H", "boat", { 2548, 80.6, 54.6, "Riverglades" }, { 1446, 68.6, 23.0, "Tanaris" } },
    { "N", "boat", { 1434, 25.7, 73.1, "Booty Bay" }, { 1413, 63.8, 38.8, "Ratchet" } },
}

local function runSpeed()
    local mounted = IsMounted and IsMounted()
    if mounted or (UnitLevel("player") or 1) >= 40 then
        return RUN_SPEED * MOUNT_MULTIPLIER
    end
    return RUN_SPEED
end

local graphs = {}
--- The docks and crossings usable by a faction, with docks resolved to world positions.
local function transportGraph(faction)
    local key = faction or "N"
    if graphs[key] then return graphs[key] end
    local nodes, edges = {}, {}
    local function dock(d)
        local wx, wy, inst = HBD:GetWorldCoordinatesFromZone(d[2] / 100, d[3] / 100, d[1])
        if not wx then return nil end
        local n = { x = wx, y = wy, inst = inst, name = d[4], uiMapId = d[1] }
        nodes[#nodes + 1] = n
        return n
    end
    for _, t in ipairs(TRANSPORTS) do
        if t[1] == "N" or t[1] == faction then
            local a, b = dock(t[3]), dock(t[4])
            if a and b then edges[#edges + 1] = { a = a, b = b, kind = t[2], time = TRANSPORT_TIME[t[2]] } end
        end
    end
    graphs[key] = { nodes = nodes, edges = edges }
    return graphs[key]
end

--- Walking or flying between two points on one continent: time, a fly step if flying
--- is quicker, and the straight-line distance.
local function leg(ctx, a, b)
    if not (a.x and b.x) or a.inst ~= b.inst then return nil end
    local d = HBD:GetWorldDistance(a.inst, a.x, a.y, b.x, b.y)
    if not d then return nil end
    local t, step = d / ctx.run, nil
    local fa, da = ctx.nearestFm(a)
    local fb, db = ctx.nearestFm(b)
    if fa and fb and fa ~= fb then
        local flight = HBD:GetWorldDistance(a.inst, fa.wx, fa.wy, fb.wx, fb.wy)
        local tf = da / ctx.run + flight * FLY_PATH_FACTOR / FLY_SPEED + db / ctx.run + FLY_OVERHEAD
        if tf < t * 0.85 then t, step = tf, { kind = "fly", from = fa, to = fb } end
    end
    return t, step, d
end

local function withStep(steps, step)
    local out = {}
    for i, s in ipairs(steps) do out[i] = s end
    if step then out[#out + 1] = step end
    return out
end

--- Quickest way from the origin to every dock (Dijkstra over docks and crossings).
local function reachDocks(ctx, origin, graph)
    local cost, steps, done = {}, {}, {}
    for _, n in ipairs(graph.nodes) do
        local t, step = leg(ctx, origin, n)
        if t then cost[n], steps[n] = t, withStep({}, step) end
    end
    while true do
        local u
        for _, n in ipairs(graph.nodes) do
            if cost[n] and not done[n] and (not u or cost[n] < cost[u]) then u = n end
        end
        if not u then break end
        done[u] = true
        for _, e in ipairs(graph.edges) do
            local v = (e.a == u and e.b) or (e.b == u and e.a) or nil
            if v and not done[v] and (not cost[v] or cost[u] + e.time < cost[v]) then
                cost[v], steps[v] = cost[u] + e.time, withStep(steps[u], { kind = e.kind, from = u, to = v })
            end
        end
        for _, v in ipairs(graph.nodes) do
            if v ~= u and not done[v] and v.inst == u.inst then
                local t, step = leg(ctx, u, v)
                if t and (not cost[v] or cost[u] + t < cost[v]) then
                    cost[v], steps[v] = cost[u] + t, withStep(steps[u], step)
                end
            end
        end
    end
    return cost, steps
end

--- "fly Westfall > Stormwind City, boat Stormwind Harbor > Auberdine"
function D.RouteText(steps)
    local parts = {}
    for _, s in ipairs(steps or {}) do
        if s.kind == "fly" then
            parts[#parts + 1] = "fly " .. D.ZoneName(s.from.uiMapId) .. " > " .. D.ZoneName(s.to.uiMapId)
        else
            parts[#parts + 1] = s.kind .. " " .. s.from.name .. " > " .. s.to.name
        end
    end
    return table.concat(parts, ", ")
end

--- Rank places by estimated travel time from `origin` ({ x, y, inst } in world
--- coordinates; default: the player). Routes can use flight paths, boats and zeppelins.
--- Each result: { place, spawn, dist (yards, same continent only), time (seconds), steps }.
--- Also returns whether a starting position was known.
function D.Rank(places, origin)
    if not origin then
        if D.originOverride ~= nil then
            -- Answering someone else: their position, or false when it isn't known.
            origin = D.originOverride or nil
        else
            local px, py, pinst = HBD:GetPlayerWorldPosition()
            if px then origin = { x = px, y = py, inst = pinst } end
        end
    end
    local fms = D.FlightMasters()
    local fmMemo = {}
    local ctx = { run = runSpeed() }
    function ctx.nearestFm(p)
        local m = fmMemo[p]
        if not m then
            local _, s, d = nearestFlightMaster(p.inst, p.x, p.y, fms)
            m = { s, d }
            fmMemo[p] = m
        end
        return m[1], m[2]
    end

    local dockCost, dockSteps
    local function docks()
        if not dockCost then dockCost, dockSteps = reachDocks(ctx, origin, transportGraph(D.PlayerFaction())) end
        return dockCost, dockSteps
    end

    local results = {}
    for _, place in ipairs(places) do
        local best
        if origin then
            -- Same continent: the nearest spawn in a straight line, walking or flying.
            local spawn, dist
            for _, s in ipairs(place.spawns) do
                if s.wx and s.inst == origin.inst then
                    local d = HBD:GetWorldDistance(origin.inst, origin.x, origin.y, s.wx, s.wy)
                    if d and (not dist or d < dist) then spawn, dist = s, d end
                end
            end
            if spawn then
                spawn.point = spawn.point or { x = spawn.wx, y = spawn.wy, inst = spawn.inst }
                local t, step = leg(ctx, origin, spawn.point)
                best = { place = place, spawn = spawn, dist = dist, time = t, steps = withStep({}, step) }
            else
                -- Another continent: via the dock that gets there soonest.
                local cost, steps = docks()
                local bestSpawn, bestDock, bestGuess
                for _, s in ipairs(place.spawns) do
                    if s.wx then
                        for n, c in pairs(cost) do
                            if n.inst == s.inst then
                                local guess = c + HBD:GetWorldDistance(n.inst, n.x, n.y, s.wx, s.wy) / ctx.run
                                if not bestGuess or guess < bestGuess then bestSpawn, bestDock, bestGuess = s, n, guess end
                            end
                        end
                    end
                end
                if bestSpawn then
                    bestSpawn.point = bestSpawn.point or { x = bestSpawn.wx, y = bestSpawn.wy, inst = bestSpawn.inst }
                    local t, step = leg(ctx, bestDock, bestSpawn.point)
                    best = { place = place, spawn = bestSpawn, time = cost[bestDock] + (t or 0),
                        steps = withStep(steps[bestDock], step) }
                end
            end
        end
        if not best and place.spawns[1] then best = { place = place, spawn = place.spawns[1] } end
        if best then results[#results + 1] = best end
    end

    table.sort(results, function(a, b)
        if a.time and b.time then return a.time < b.time end
        if a.time or b.time then return a.time ~= nil end
        return a.place.name < b.place.name
    end)
    return results, origin ~= nil
end
