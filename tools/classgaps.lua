-- tools/classgaps.lua
-- Lists class quests whose objectives AskBot can't place from Questie's data, so they can be
-- filled in KnownLocations.lua. Development tool only.
--   luajit tools/classgaps.lua <QuestieDB_Forever.toc> [ClassName ...]
local qdb = dofile("tools/qdb.lua")(arg[1])
local CLASSES = { Warrior = 1, Paladin = 2, Hunter = 4, Rogue = 8, Priest = 16, Shaman = 64, Mage = 128,
    Warlock = 256, Druid = 1024 }
local wanted = {}
for i = 2, #arg do wanted[#wanted + 1] = arg[i] end
if #wanted == 0 then for k in pairs(CLASSES) do wanted[#wanted + 1] = k end; table.sort(wanted) end

-- AskBot's community locations count as placed.
local AB = {}
assert(loadfile("KnownLocations.lua"))("AskBot", AB)
local KNOWN = AB.KNOWN

-- Items quests hand you when you take them (AskBot points to the giver).
local givenBy = {}
for _, id in ipairs(qdb.ids("Quest")) do
    local q = qdb.quest(id)
    if q.sourceItemId and q.sourceItemId > 0 then givenBy[q.sourceItemId] = true end
end

-- Spawns at -1,-1 are inside dungeons; AskBot points to the entrance.
local function hasSpawns(s) return type(s) == "table" and next(s) ~= nil end
local function npcPlaced(id) local n = qdb.npc(id); return (n and hasSpawns(n.spawns)) or KNOWN.npcs[id] ~= nil end
local function objPlaced(id) local o = qdb.object(id); return o and hasSpawns(o.spawns) end
local function anyPlaced(npcs, objs)
    for _, id in ipairs(npcs or {}) do if npcPlaced(id) then return true end end
    for _, id in ipairs(objs or {}) do if objPlaced(id) then return true end end
    return false
end
local function itemPlaced(id, depth)
    local it = qdb.item(id)
    if not it then return false, "no item row" end
    if anyPlaced(it.npcDrops, it.objectDrops) then return true end
    for _, c in ipairs(it.itemDrops or {}) do
        local ci = qdb.item(c)
        if ci and anyPlaced(ci.npcDrops, ci.objectDrops) then return true end
    end
    if it.vendors and anyPlaced(it.vendors) then return true, "vendor only" end
    if KNOWN.items[id] then return true end
    if it.questRewards or givenBy[id] then return true end
    local why = {}
    if it.npcDrops then why[#why + 1] = "npcDrops w/o spawns" end
    if it.objectDrops then why[#why + 1] = "objectDrops " .. table.concat(it.objectDrops, ",") .. " w/o spawns" end
    if it.startQuest then why[#why + 1] = "starts quest" end
    return false, #why > 0 and table.concat(why, "; ") or "no source"
end
local function iname(id) local it = qdb.item(id); return (it and it.name or "?") .. " (" .. id .. ")" end
local function nname(id) local n = qdb.npc(id); return (n and n.name or "?") .. " (" .. id .. ")" end
local function oname(id) local o = qdb.object(id); return (o and o.name or "?") .. " (" .. id .. ")" end

local function sideOf(q)
    local r = q.requiredRaces or 0
    -- Alliance races: 1,4,8,64,1024(dr) ; Horde: 2,16,32,128,512
    local a, h = false, false
    for _, b in ipairs({ 1, 4, 8, 64, 1024 }) do if math.floor(r / b) % 2 == 1 then a = true end end
    for _, b in ipairs({ 2, 16, 32, 128, 512 }) do if math.floor(r / b) % 2 == 1 then h = true end end
    if r == 0 or (a and h) then return "both" end
    return a and "A" or h and "H" or ("races " .. r)
end

local all = qdb.ids("Quest")
for _, cls in ipairs(wanted) do
    local bit = CLASSES[cls]
    local list = {}
    for _, id in ipairs(all) do
        local q = qdb.quest(id)
        if q.requiredClasses and math.floor(q.requiredClasses / bit) % 2 == 1 and q.requiredClasses < 2047 then
            list[#list + 1] = q
        end
    end
    table.sort(list, function(a, b) return (a.questLevel or 0) < (b.questLevel or 0) or ((a.questLevel or 0) == (b.questLevel or 0) and a.id < b.id) end)
    print(("\n==== %s: %d quests"):format(cls, #list))
    local gapCount = 0
    for _, q in ipairs(list) do
        local gaps = {}
        local s, f = q.startedBy or {}, q.finishedBy or {}
        if not anyPlaced(s[1], s[2]) then
            local items = s[3] and #s[3] > 0
            if not items then gaps[#gaps + 1] = "giver not placed" end
        end
        if not anyPlaced(f[1], f[2]) and not (KNOWN.quests[q.id] and KNOWN.quests[q.id].turnIn) then gaps[#gaps + 1] = "turn-in not placed" end
        local o = q.objectives or {}
        local nObj = 0
        local kq = KNOWN.quests[q.id] or {}
        if kq.steps then nObj = nObj + #kq.steps end
        local function itemOk(itemId)
            if kq.items and kq.items[itemId] then return true end
            return itemPlaced(itemId)
        end
        local function npcOk(npcId) return (kq.npcs and kq.npcs[npcId]) or npcPlaced(npcId) end
        for _, c in ipairs(o[1] or {}) do nObj = nObj + 1; if not npcOk(c[1]) then gaps[#gaps + 1] = "kill/talk " .. nname(c[1]) end end
        for _, c in ipairs(o[2] or {}) do nObj = nObj + 1; if not objPlaced(c[1]) then gaps[#gaps + 1] = "object " .. oname(c[1]) end end
        for _, c in ipairs(o[3] or {}) do
            nObj = nObj + 1
            local ok, why = itemOk(c[1])
            if not ok then gaps[#gaps + 1] = "item " .. iname(c[1]) .. ": " .. why end
        end
        for _, c in ipairs(o[5] or {}) do nObj = nObj + 1; if not anyPlaced(c[1]) then gaps[#gaps + 1] = "killcredit " .. tostring(c[3]) end end
        local objItems = {}
        for _, c in ipairs(o[3] or {}) do objItems[c[1]] = true end
        for _, itemId in ipairs(q.requiredSourceItems or {}) do
            if not objItems[itemId] then
                local ok, why = itemOk(itemId)
                if not ok and itemId ~= q.sourceItemId then gaps[#gaps + 1] = "bring " .. iname(itemId) .. ": " .. why end
            end
        end
        if q.triggerEnd then
            nObj = nObj + 1
            if not hasSpawns(q.triggerEnd[2]) then gaps[#gaps + 1] = "explore '" .. tostring(q.triggerEnd[1]) .. "' no coords" end
        end
        local extras = q.extraObjectives and #q.extraObjectives or 0
        if nObj == 0 and extras == 0 and not anyPlaced(f[1], f[2]) and not (KNOWN.quests[q.id] and KNOWN.quests[q.id].turnIn) then
            local txt = q.objectivesText and q.objectivesText[1] or ""
            gaps[#gaps + 1] = "no objectives: " .. txt:sub(1, 110)
        end
        if #gaps > 0 then gapCount = gapCount + 1 end
        local mark = #gaps > 0 and "!!" or "ok"
        print(("%s [%d] %s (%d) %s"):format(mark, q.questLevel or 0, q.name, q.id, sideOf(q)))
        for _, g in ipairs(gaps) do print("      - " .. g) end
    end
    print(("  %d of %d have gaps"):format(gapCount, #list))
end
