-- tools/questinfo.lua: everything Questie's data says about some quests, offline.
--   luajit tools/questinfo.lua <QuestieDB_Forever.toc> <questId> [questId ...]
local qdb = dofile("tools/qdb.lua")(arg[1])
local function spawnText(s)
    if type(s) ~= "table" or not next(s) then return "NO SPAWNS" end
    local parts = {}
    for zone, pts in pairs(s) do
        local p1 = pts[1]
        parts[#parts + 1] = ("zone %s: %d pts%s"):format(zone, #pts, p1 and (" e.g. %.1f,%.1f"):format(p1[1] or -1, p1[2] or -1) or "")
    end
    return table.concat(parts, "; ")
end
local function npc(id) local n = qdb.npc(id); return n and ("%s (%d) [%s]"):format(n.name, id, spawnText(n.spawns)) or ("npc " .. id .. " missing") end
local function obj(id) local o = qdb.object(id); return o and ("%s (%d) [%s]"):format(o.name, id, spawnText(o.spawns)) or ("object " .. id .. " missing") end
local function item(id)
    local it = qdb.item(id)
    if not it then return "item " .. id .. " missing" end
    local src = {}
    for _, n in ipairs(it.npcDrops or {}) do src[#src + 1] = "drop " .. npc(n) end
    for _, o in ipairs(it.objectDrops or {}) do src[#src + 1] = "obj " .. obj(o) end
    for _, c in ipairs(it.itemDrops or {}) do src[#src + 1] = "in item " .. c end
    for _, v in ipairs(it.vendors or {}) do src[#src + 1] = "vendor " .. npc(v) end
    if #src > 6 then src = { src[1], src[2], src[3], "... " .. #src .. " sources" } end
    return ("%s (%d) {%s}"):format(it.name, id, table.concat(src, " | "))
end
for i = 2, #arg do
    local q = qdb.quest(tonumber(arg[i]))
    if not q then print("quest " .. arg[i] .. " missing") else
    print(("\n#%d %s  lvl %s req %s  races %s classes %s  pre %s/%s next %s"):format(q.id, q.name, tostring(q.questLevel),
        tostring(q.requiredLevel), tostring(q.requiredRaces), tostring(q.requiredClasses),
        q.preQuestSingle and table.concat(q.preQuestSingle, ",") or "-", q.preQuestGroup and table.concat(q.preQuestGroup, ",") or "-",
        tostring(q.nextQuestInChain)))
    print("  text: " .. table.concat(q.objectivesText or {}, " / "))
    local s, f = q.startedBy or {}, q.finishedBy or {}
    for _, id in ipairs(s[1] or {}) do print("  giver " .. npc(id)) end
    for _, id in ipairs(s[2] or {}) do print("  giver " .. obj(id)) end
    for _, id in ipairs(s[3] or {}) do print("  giver item " .. item(id)) end
    for _, id in ipairs(f[1] or {}) do print("  turn-in " .. npc(id)) end
    for _, id in ipairs(f[2] or {}) do print("  turn-in " .. obj(id)) end
    local o = q.objectives or {}
    for _, c in ipairs(o[1] or {}) do print("  kill/talk " .. npc(c[1]) .. " x" .. tostring(c[2]) .. " " .. tostring(c[3] or "")) end
    for _, c in ipairs(o[2] or {}) do print("  use " .. obj(c[1]) .. " " .. tostring(c[3] or "")) end
    for _, c in ipairs(o[3] or {}) do print("  collect " .. item(c[1]) .. " x" .. tostring(c[2])) end
    for _, c in ipairs(o[5] or {}) do print("  credit " .. tostring(c[3]) .. " via " .. table.concat(c[1] or {}, ",")) end
    if q.sourceItemId then print("  given item " .. item(q.sourceItemId)) end
    for _, id in ipairs(q.requiredSourceItems or {}) do print("  bring " .. item(id)) end
    if q.triggerEnd then print("  explore '" .. tostring(q.triggerEnd[1]) .. "' " .. spawnText(q.triggerEnd[2])) end
    for _, e in ipairs(q.extraObjectives or {}) do print("  extra '" .. tostring(e[3]) .. "' " .. spawnText(e[1])) end
    end
end
