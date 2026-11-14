-- tools/qdb.lua
-- Offline reader for QuestieDB's baked data (the CBOR rows stored in its .toc metadata), for
-- finding gaps in Questie's data without starting the game. Development tool only; not
-- packaged.
--
--   local qdb = dofile("tools/qdb.lua")("<path to>/QuestieDB_Forever.toc")
--   qdb.quest(id).name, qdb.item(id).npcDrops, qdb.npc(id).spawns, qdb.object(id).spawns
--   qdb.ids("Quest") -- every quest ID that has a row

local FIELDS = {
    Quest = { "name", "startedBy", "finishedBy", "requiredLevel", "questLevel", "requiredRaces",
        "requiredClasses", "objectivesText", "triggerEnd", "objectives", "sourceItemId", "preQuestGroup",
        "preQuestSingle", "childQuests", "inGroupWith", "exclusiveTo", "zoneOrSort", "requiredSkill",
        "requiredMinRep", "requiredMaxRep", "requiredSourceItems", "nextQuestInChain", "questFlags",
        "specialFlags", "parentQuest", "reputationReward", "breadcrumbForQuestId", "breadcrumbs",
        "extraObjectives", "requiredSpell", "requiredSpecialization", "requiredMaxLevel" },
    Item = { "name", "npcDrops", "objectDrops", "itemDrops", "startQuest", "questRewards", "flags",
        "foodType", "itemLevel", "requiredLevel", "ammoType", "class", "subClass", "vendors",
        "relatedQuests", "teachesSpell" },
    Npc = { "name", "minLevelHealth", "maxLevelHealth", "minLevel", "maxLevel", "rank", "spawns",
        "waypoints", "zoneID", "questStarts", "questEnds", "factionID", "friendlyToFaction", "subName",
        "npcFlags" },
    Object = { "name", "questStarts", "questEnds", "spawns", "zoneID", "factionID", "waypoints" },
}

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local dec = {}
for i = 1, 64 do dec[B64:byte(i)] = i - 1 end
local function unbase64(s)
    local out, bits, n = {}, 0, 0
    for i = 1, #s do
        local v = dec[s:byte(i)]
        if v then
            bits = bits * 64 + v
            n = n + 6
            if n >= 8 then
                n = n - 8
                local p = 2 ^ n
                out[#out + 1] = string.char(math.floor(bits / p))
                bits = bits % p
            end
        end
    end
    return table.concat(out)
end

-- Minimal CBOR: ints, strings, arrays, maps, floats, true/false/nil.
local function cbor(b)
    local pos = 1
    local item
    local function arg(info)
        if info < 24 then return info end
        local n = ({ [24] = 1, [25] = 2, [26] = 4, [27] = 8 })[info]
        local v = 0
        for i = 0, n - 1 do v = v * 256 + b:byte(pos + i) end
        pos = pos + n
        return v
    end
    function item()
        local h = b:byte(pos); pos = pos + 1
        local major, info = math.floor(h / 32), h % 32
        if major == 0 then return arg(info)
        elseif major == 1 then return -1 - arg(info)
        elseif major == 2 or major == 3 then
            local n = arg(info); local s = b:sub(pos, pos + n - 1); pos = pos + n; return s
        elseif major == 4 then
            local n, t = arg(info), {}
            for i = 1, n do t[i] = item() end
            return t
        elseif major == 5 then
            local n, t = arg(info), {}
            for _ = 1, n do local k = item(); t[k] = item() end
            return t
        elseif major == 6 then arg(info); return item()
        else
            if info == 20 then return false elseif info == 21 then return true
            elseif info == 22 or info == 23 then return nil
            elseif info == 25 then -- half float
                local v = b:byte(pos) * 256 + b:byte(pos + 1); pos = pos + 2
                local e, m = math.floor(v / 1024) % 32, v % 1024
                local s = v >= 32768 and -1 or 1
                if e == 0 then return s * m * 2 ^ -24 end
                return s * (1 + m / 1024) * 2 ^ (e - 15)
            elseif info == 26 or info == 27 then
                local n = info == 26 and 4 or 8
                local bytes = { b:byte(pos, pos + n - 1) }; pos = pos + n
                local sign = bytes[1] >= 128 and -1 or 1
                if n == 4 then
                    local e = (bytes[1] % 128) * 2 + math.floor(bytes[2] / 128)
                    local m = ((bytes[2] % 128) * 256 + bytes[3]) * 256 + bytes[4]
                    if e == 0 then return sign * m * 2 ^ -149 end
                    return sign * (1 + m / 2 ^ 23) * 2 ^ (e - 127)
                end
                local e = (bytes[1] % 128) * 16 + math.floor(bytes[2] / 16)
                local m = bytes[2] % 16
                for i = 3, 8 do m = m * 256 + bytes[i] end
                if e == 0 then return sign * m * 2 ^ -1074 end
                return sign * (1 + m / 2 ^ 52) * 2 ^ (e - 1023)
            end
            return nil
        end
    end
    return item()
end

return function(tocPath)
    local store = {}
    for line in io.lines(tocPath) do
        local k, v = line:match("^## (X%-%S+): (.*)$")
        if k then store[k] = v end
    end
    local function get(key)
        local v = store[key]
        if not v then return nil end
        local parts = v:match("^~(%d+)~$")
        if parts then
            local buf = {}
            for i = 1, tonumber(parts) do buf[i] = store[key .. "-" .. i] end
            v = table.concat(buf)
        end
        return v
    end
    local cache = {}
    local function entity(kind, id)
        local ck = kind .. id
        if cache[ck] ~= nil then return cache[ck] or nil end
        local prefix = "X-" .. kind .. "-" .. id .. "-"
        local s = get(prefix .. "S")
        if not s then cache[ck] = false; return nil end
        local row = cbor(unbase64(s))
        local out = { id = id }
        for i, name in ipairs(FIELDS[kind]) do
            local t = get(prefix .. i)
            if t then out[name] = cbor(unbase64(t)) else out[name] = row[i] end
        end
        cache[ck] = out
        return out
    end
    local qdb = {}
    function qdb.quest(id) return entity("Quest", id) end
    function qdb.item(id) return entity("Item", id) end
    function qdb.npc(id) return entity("Npc", id) end
    function qdb.object(id) return entity("Object", id) end
    function qdb.ids(kind)
        local out = {}
        for k in pairs(store) do
            local id = k:match("^X%-" .. kind .. "%-(%d+)%-S$")
            if id then out[#out + 1] = tonumber(id) end
        end
        table.sort(out)
        return out
    end
    return qdb
end
