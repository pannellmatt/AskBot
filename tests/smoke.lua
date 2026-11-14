-- Smoke test: load AskBot with stubbed WoW/Questie APIs and ask some questions.
-- Run from the addon folder:  luajit tests\smoke.lua .
local dir = arg[1] or "."

local output = {}
DEFAULT_CHAT_FRAME = { AddMessage = function(_, m)
    output[#output + 1] = m
    print((m:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|Haddon:askbot:(%d+)|h", "<%1>"):gsub("|h", "")))
end }

-- Frames, timers, events -----------------------------------------------------------------
local frames, tickerFn = {}, nil
function CreateFrame()
    local f = { scripts = {} }
    function f:RegisterEvent() end
    function f:SetScript(k, fn) self.scripts[k] = fn end
    frames[#frames + 1] = f
    return f
end
-- Fake clock: timers run when the test calls advance(seconds).
local now, timers = 0, {}
local function newTimer(sec, fn)
    local t = { due = now + sec, fn = fn }
    function t:Cancel() self.cancelled = true end
    timers[#timers + 1] = t
    return t
end
local function advance(sec)
    now = now + sec
    local ran = true
    while ran do
        ran = false
        for _, t in ipairs(timers) do
            if not t.cancelled and not t.done and t.due <= now then t.done = true; ran = true; t.fn() end
        end
    end
end
C_Timer = {
    NewTicker = function(_, fn) tickerFn = fn; return { Cancel = function() tickerFn = nil end } end,
    NewTimer = newTimer,
    After = function(sec, fn) newTimer(sec, fn) end,
}
local linkCallback
EventRegistry = { RegisterCallback = function(_, event, fn) if event == "SetItemRef" then linkCallback = fn end end }
SlashCmdList = {}
function geterrorhandler() return function(e) print("ERROR HANDLER: " .. tostring(e)) end end

-- Player ---------------------------------------------------------------------------------
local faction = "Alliance"
function UnitFactionGroup() return faction end
local units = { player = { "Me", "Warrior", "WARRIOR", 20, 2500, 500 }, party1 = { "Buddy", "Hunter", "HUNTER", 30, 9350, 550 } }
local inGroup = false
function UnitClass(u) local d = units[u or "player"]; return d[2], d[3] end
function UnitName(u) local d = units[u]; return d and (u == "player" or inGroup) and d[1] or nil end
function UnitExists(u) return UnitName(u) ~= nil end
function IsInGroup() return inGroup end
function IsInRaid() return false end
function UnitLevel(u) return units[u or "player"][4] end
function GetTime() return now end
function IsInGuild() return true end
function GetNumGuildMembers() return 1 end
function GetGuildRosterInfo(i) return "Guildie-Realm", "Member", 1, 20, "Mage", "Stormwind City", "", "", true, 0, "MAGE" end
local sentChat, sentAddon = {}, {}
C_ChatInfo = {
    RegisterAddonMessagePrefix = function() end,
    SendAddonMessage = function(prefix, text, dist) sentAddon[#sentAddon + 1] = { prefix, text, dist } end,
    SendChatMessage = function(text, chatType, _, target) sentChat[#sentChat + 1] = { text, chatType, target } end,
}
function IsMounted() return false end

-- Maps: each zone is 1000x1000 yards; Eastern Kingdoms = instance 0, Kalimdor = 1 ----------
local maps = {
    [1453] = { "Stormwind City", 0, 0, 0 }, [1436] = { "Westfall", 2000, 0, 0 },
    [1426] = { "Dun Morogh", 5000, 0, 0 }, [1433] = { "Redridge Mountains", 9000, 0, 0 },
    [1454] = { "Orgrimmar", 0, 0, 1 },
    [1434] = { "Stranglethorn Vale", 2000, 2000, 0 }, [1411] = { "Durotar", 1000, 0, 1 },
    [1439] = { "Darkshore", 3000, 0, 1 }, [1438] = { "Teldrassil", 3000, -2000, 1 },
}
C_Map = { GetMapInfo = function(id) return maps[id] and { name = maps[id][1], mapType = 3 } end }
local hbd = {
    GetWorldCoordinatesFromZone = function(_, x, y, map)
        local m = maps[map]
        if not m then return nil end
        return m[2] + x * 1000, m[3] + y * 1000, m[4]
    end,
    GetPlayerWorldPosition = function() return 2500, 500, 0 end, -- middle of Westfall
    GetUnitWorldPosition = function(_, u) local d = units[u]; if d then return d[5], d[6], 0 end end,
    mapData = maps,
    GetWorldDistance = function(_, _, x1, y1, x2, y2) return math.sqrt((x1 - x2) ^ 2 + (y1 - y2) ^ 2) end,
}
LibStub = function() return hbd end

local tomtomWaypoints = 0
TomTom = {
    AddWaypoint = function(_, map, x, y, opts)
        tomtomWaypoints = tomtomWaypoints + 1
        print(string.format("   [TomTom] %s at %s %.3f,%.3f", opts.title, maps[map][1], x, y))
        return tomtomWaypoints
    end,
    RemoveWaypoint = function() end,
}

-- QuestieDB data -------------------------------------------------------------------------
local W, SW, DM, RR, OG = 40, 1519, 1, 44, 1637 -- area ids
local TD = 141
local areaToMap = { [SW] = 1453, [W] = 1436, [DM] = 1426, [RR] = 1433, [OG] = 1454, [TD] = 1438 }
local npcs = {
    [1] = { "Helene Peltskinner", "Skinning Trainer", 16, "A", { [SW] = { { 71.6, 62.8 } } } },
    [2] = { "Far Skinner", "Skinning Trainer", 16, "A", { [DM] = { { 50, 50 } } } },
    [3] = { "Horde Skinner", "Skinning Trainer", 16, "H", { [W] = { { 55, 50 } } } },
    [4] = { "Thor", "Gryphon Master", 8, "A", { [W] = { { 56.6, 52.6 } } } },
    [5] = { "Innkeeper Heather", "Innkeeper", 128, "A", { [W] = { { 52.9, 53.6 } } } },
    [6] = { "Ander Germaine", "Warrior Trainer", 16, "A", { [SW] = { { 79, 70 } } } },
    [7] = { "Orc Skinner", "Skinning Trainer", 16, "H", { [OG] = { { 63, 45 } } } },
    [8] = { "Dungeon Guy", "Skinning Trainer", 16, "A", { [W] = { { -1, -1 } } } },
    [9] = { "Gryan Stoutmantle", "People's Militia", 2, "A", { [W] = { { 56.3, 47.5 } } } },
    [10] = { "Defias Thug", nil, 0, nil, { [W] = { { 40, 40 }, { 45, 45 } } }, 9, 10 },
    [11] = { "Kobold Vermin", nil, 0, nil, { [DM] = { { 30, 30 } } }, 2, 3 },
    [12] = { "Thread Seller", "Trade Supplies", 4, "A", { [SW] = { { 60, 70 } } } },
    [13] = { "Horde Vendor", "Trade Supplies", 4, "H", { [OG] = { { 50, 50 } } } },
    [14] = { "Dungar Longdrink", "Gryphon Master", 8, "A", { [SW] = { { 66, 62 } } } },
    [15] = { "Ariena Stormfeather", "Gryphon Master", 8, "A", { [RR] = { { 30, 60 } } } },
    [16] = { "Martie Jainrose", nil, 0, "A", { [RR] = { { 35, 55 } } } },
    [17] = { "Defias Pillager", nil, 0, nil, { [W] = { { 60, 30 } } }, 14, 15 },
    [18] = { "Defias Cutpurse", nil, 0, nil, { [W] = { { 30, 70 } } }, 9, 10 },
    [19] = { "Leprithus", nil, 0, nil, { [W] = { { 45, 35 } } }, 19, 19, 4 },       -- rare
    [20] = { "Foreman Grills", nil, 0, nil, { [W] = { { 30, 30 } } }, 21, 21, 2 },  -- rare elite
    [21] = { "Far Rare", nil, 0, nil, { [DM] = { { 50, 50 } } }, 10, 10, 4 },
    [22] = { "Jannok Breezesong", nil, 0, "A", { [TD] = { { 56, 60 } } } },
}
local quests = {
    [100] = { "The Defias Brotherhood", 1, { { 9 } }, { { 9 } }, 18, 14 },
    [101] = { "The Defias Brotherhood", 2, { { 13 } }, { { 13 } }, 18, 14 },
    [102] = { "Bounty on Murlocs", 0, { nil, { 500 } }, { { 5 } }, 12, 10 },
    [103] = { "Red Linen Goods", 1, { { 9 } }, { { 9 } }, 10, 8,
        { { { 10 } }, nil, { { 2589 } } } },                                  -- kill thugs, collect linen
    [104] = { "Scout Redridge", 1, { { 9 } }, { { 16 } }, 15, 12, {},
        { "Scout the Redridge camp", { [RR] = { { 50, 50 } } } } },          -- explore objective
    [105] = { "Patrolling Westfall", 1, { { 9 } }, { { 9 } }, 14, 10 },     -- available at Gryan
    [106] = { "Too Easy", 1, { { 9 } }, { { 9 } }, 3, 1 },                  -- grey for a level 20
    [107] = { "Too Hard", 1, { { 9 } }, { { 9 } }, 30, 28 },                -- level 28 needed
    [108] = { "Already Done", 1, { { 5 } }, { { 5 } }, 15, 10 },            -- Questie says not doable
}
-- What Questie's IsDoable would say (completed quests, prerequisites, etc.)
local doable = { [102] = true, [105] = true, [106] = true, [107] = true }
-- Quest log: 100 complete, 103 half done (thugs killed), 104 in progress; 102 not taken.
local questLog = {
    [100] = { complete = true, objectives = {} },
    [103] = { complete = false, objectives = {
        { text = "Defias Thug slain: 10/10", finished = true },
        { text = "Linen Cloth: 2/6", finished = false } } },
    [104] = { complete = false, objectives = { { text = "Scout the Redridge camp", finished = false } } },
}
C_QuestLog = {
    GetLogIndexForQuestID = function(id) return questLog[id] and 1 or nil end,
    IsComplete = function(id) return questLog[id] and questLog[id].complete or false end,
    GetQuestObjectives = function(id) return questLog[id] and questLog[id].objectives end,
    GetNumQuestLogEntries = function() return 4 end,
    GetInfo = function(i)
        return ({ { isHeader = true, title = "Westfall" }, { questID = 100, title = "The Defias Brotherhood" },
            { questID = 103, title = "Red Linen Goods" }, { questID = 104, title = "Scout Redridge" } })[i]
    end,
}
local items = {
    [2589] = { name = "Linen Cloth", npcDrops = { 10, 11, 17, 18 } },
    [2320] = { name = "Coarse Thread", vendors = { 12 } },
    [999] = { name = "Horde Goods", vendors = { 13 } },
    [3000] = { name = "Gryan's Medal", questRewards = { 100 } },
    [4238] = { name = "Linen Bag" },
    [2570] = { name = "Linen Shirt", vendors = { 12 } },
    [2996] = { name = "Bolt of Linen Cloth" },
}
local objects = { [500] = { "Wanted Poster", { [W] = { { 53, 52 } } } } }

local function ids(t) local out = {} for id in pairs(t) do out[#out + 1] = id end table.sort(out) return out end
NpcDB = {
    GetAllIds = function() return ids(npcs) end,
    name = function(id) return npcs[id] and npcs[id][1] end,
    subName = function(id) return npcs[id][2] end,
    npcFlags = function(id) return npcs[id][3] end,
    friendlyToFaction = function(id) return npcs[id][4] end,
    spawns = function(id) return npcs[id][5] end,
    minLevel = function(id) return npcs[id][6] end,
    maxLevel = function(id) return npcs[id][7] end,
    rank = function(id) return npcs[id][8] or 0 end,
}
QuestDB = {
    GetAllIds = function() return ids(quests) end,
    name = function(id) return quests[id] and quests[id][1] end,
    requiredRaces = function(id) return quests[id][2] end,
    startedBy = function(id) return quests[id][3] end,
    finishedBy = function(id) return quests[id][4] end,
    questLevel = function(id) return quests[id][5] end,
    requiredLevel = function(id) return quests[id][6] end,
    requiredMaxLevel = function() return 0 end,
    objectives = function(id) return quests[id][7] end,
    triggerEnd = function(id) return quests[id][8] end,
}
ItemDB = { GetAllIds = function() return ids(items) end }
for _, field in ipairs({ "name", "npcDrops", "objectDrops", "vendors", "questRewards", "itemDrops" }) do
    ItemDB[field] = function(id) return items[id] and items[id][field] end
end
ObjectDB = {
    name = function(id) return objects[id] and objects[id][1] end,
    spawns = function(id) return objects[id][2] end,
}
LibQuestieDB = {
    RequireContract = function() return true end,
    Enum = {
        npcFlags = { QUEST_GIVER = 2, VENDOR = 4, FLIGHT_MASTER = 8, TRAINER = 16, INNKEEPER = 128,
            BANKER = 256, AUCTIONEER = 4096, STABLEMASTER = 8192, REPAIR = 16384 },
        factionRaceMasks = { Alliance = 1, Horde = 2 },
    },
}
Questie = { started = true }
QuestieLoader = { ImportModule = function() return {
    IsDoable = function(id) return doable[id] == true end,
    IsTrivial = function(level) return level ~= nil and level < 20 - 8 end,
    GetUiMapIdByAreaId = function(_, a) return areaToMap[a] end,
    GetDungeons = function() return { [1581] = { "The Deadmines", {}, W, { { W, 42.6, 71.8 } } } } end,
} end }

-- Game item cache: names for gear Questie doesn't know; 2589 has a link and vendor price.
local itemCache = { [5193] = "Cape of the Brotherhood", [5202] = "Corsair's Overshirt",
    [10399] = "Blackened Defias Armor", [872] = "Rockslicer", [2589] = "Linen Cloth" }
C_Item = {
    GetItemNameByID = function(id) return itemCache[id] end,
    RequestLoadItemDataByID = function() end,
    GetItemInfo = function(id)
        if id == 2589 then return "Linen Cloth", "|cffffffff|Hitem:2589::|h[Linen Cloth]|h|r", 1, 5, 0, "Trade Goods", "Cloth", 20, "", 0, 13 end
    end,
}

-- AtlasLoot (Forever): Deadmines with two bosses, plus drop rates
local rates = { [639] = { [5193] = 23.08, [5202] = 23.19 }, [644] = { [872] = 3.91 }, [10] = { [2589] = 12.6 } }
AtlasLoot = {
    ItemDB = { Storage = { AtlasLootClassic_DungeonsAndRaids = {
        __atlaslootdata = {},
        BlackrockDepths = {
            name = "Blackrock Depths", MapID = 1584, LevelRange = { 48, 52, 60 },
            items = { { name = "Emperor Dagran Thaurissan", npcID = 9019, [1] = { { 1, 11684 } } } },
        },
        TheDeadmines = {
            name = "The Deadmines|cffffffff|TInterface\\AddOns\\AtlasLootClassic\\ltn4.tga:18:18:2:0|t|r",
            MapID = 1581, LevelRange = { 10, 17, 26 },
            items = {
                { name = "Rhahk'Zor", npcID = 644, [1] = { { 1, 872 }, { 16, "INV_Box_01", nil, "Forever" } } },
                { name = "Edwin VanCleef", npcID = 639, [1] = { { 1, 5193 }, { 2, 5202 }, { 3, 10399 } } },
            },
        },
    } } },
    Loader = { LoadModule = function(_, name, onLoad) onLoad(name); return true end },
    Data = { Droprate = { GetData = function(_, npc, item) return rates[npc] and rates[npc][item] end } },
}

-- Auctionator: a price database, and a search that finds `ahListings` while the AH is open
local ahPrices, ahAges = { [2589] = 1250 }, { [2589] = 0 }
local ahListings = {}   -- item name -> price the next search will find
local searches = 0
local dbUpdated
AuctionFrame = { shown = false, IsShown = function(self) return self.shown end }
Auctionator = { API = { v1 = {
    GetAuctionPriceByItemID = function(caller, id) assert(caller == "AskBot"); return ahPrices[id] end,
    GetAuctionAgeByItemID = function(_, id) return ahAges[id] end,
    GetVendorPriceByItemID = function() return nil end,
    RegisterForDBUpdate = function(_, fn) dbUpdated = fn end,
    MultiSearchExact = function(_, names)
        if not AuctionFrame.shown then error("Auction house is not open") end
        searches = searches + 1
        for _, name in ipairs(names) do
            for id, n in pairs(itemCache) do
                if n == name and ahListings[name] then ahPrices[id], ahAges[id] = ahListings[name], 0 end
            end
        end
        if dbUpdated then dbUpdated() end
    end,
} } }

-- Load the addon in .toc order ------------------------------------------------------------
local AskBot = {}
for line in io.lines(dir .. "/AskBot.toc") do
    if line:match("%.lua%s*$") then assert(loadfile(dir .. "/" .. line:match("^%s*(.-)%s*$")))("AskBot", AskBot) end
end

-- Events go to every frame, as in the game.
local function fire(event, ...)
    for _, f in ipairs(frames) do if f.scripts.OnEvent then f.scripts.OnEvent(f, event, ...) end end
end
fire("PLAYER_LOGIN")
SlashCmdList.ASKBOT("where is my nearest skinning trainer") -- asked before ready -> queued
tickerFn()                                                   -- Questie ready -> start indexing
for _ = 1, 10 do
    for _, f in ipairs(frames) do if f.scripts.OnUpdate then f.scripts.OnUpdate(f) end end
end

-- Questions --------------------------------------------------------------------------------
local failures = 0
local function ask(q, expect, reject)
    local from = #output + 1
    print("\n> /askbot " .. q)
    SlashCmdList.ASKBOT(q)
    local text = table.concat(output, "\n", from)
    for _, e in ipairs(type(expect) == "table" and expect or { expect }) do
        if not text:find(e, 1, true) then failures = failures + 1; print("   !! FAIL: expected " .. e) end
    end
    for _, r in ipairs(reject or {}) do
        if text:find(r, 1, true) then failures = failures + 1; print("   !! FAIL: did not expect " .. r) end
    end
end

ask("status", "ready")
ask("where is my nearest skinning trainer", "Helene Peltskinner", { "Horde Skinner" })
ask("nearest fp?", "Thor")
ask("closest inn", "Innkeeper Heather")
ask("where's my class trainer", "Ander Germaine")
ask("where is the nearest ahead", "Sorry")
ask("who gives The Defias Brotherhood", { "Gryan Stoutmantle", "level 18, needs 14" }, { "Horde Vendor" })
ask("who do i turn in bounty on murlocs to", "Innkeeper Heather")
ask("where does bounty on murlocs start", "Wanted Poster")
ask("where can i buy coarse thread", "Thread Seller")
ask("where can i buy horde goods", "No vendor friendly")
ask("where does linen cloth drop", { "Linen Cloth|r drops from (4 sources):", "Defias Thug", "lvl 9-10", "13%" },
    { "more sources", "TomTom waypoint set", "No drop rates" })
ask("where do linen cloths drop", "Defias Thug")

-- AtlasLoot: boss loot, instance loot, gear drops; Auctionator: prices
ask("what does vancleef drop", { "Edwin VanCleef|r (The Deadmines) drops:", "Cape of the Brotherhood", "23%",
    "Entrance: Westfall 42.6, 71.8" })
ask("deadmines loot", { "The Deadmines|r (levels 10-26), bosses:", "[Rhahk'Zor]", "[Edwin VanCleef]", "Entrance:" })
ask("vancleef", "Edwin VanCleef|r (The Deadmines) drops:")
ask("where does rockslicer drop", { "Rhahk'Zor|r", "3.9%", "The Deadmines, entrance Westfall 42.6, 71.8" })
ask("what does hogger drop", "AtlasLoot has no loot table")
ask("price of linen cloth", { "AH 12s 50c", "seen today", "vendors pay 13c" })
ask("how much is rockslicer worth", "no AH price yet")
ask("|cffffffff|Hitem:2589::|h[Linen Cloth]|h|r price", "AH 12s 50c")

-- Refreshing prices: away from the AH it waits for the next visit, then reports changes
ask("refresh prices", "I'll refresh 2 prices next time you open the auction house")
ahListings["Linen Cloth"] = 1080
AuctionFrame.shown = true
do
    local from = #output + 1
    print("\n> (open the auction house)")
    fire("AUCTION_HOUSE_SHOW")
    advance(2)  -- AskBot starts the search
    advance(4)  -- results settle
    local text = table.concat(output, "\n", from)
    for _, e in ipairs({ "refreshing 2 prices", "Price changes:", "12s 50c > ", "10s 80c", "1 not listed right now" }) do
        if not text:find(e, 1, true) then failures = failures + 1; print("   !! FAIL: expected " .. e) end
    end
end
-- At the AH, a price question is answered live
ahListings["Linen Cloth"] = 900
ask("price of linen cloth", "Checking the auction house")
do
    local from = #output + 1
    advance(1)
    if not table.concat(output, "\n", from):find("AH 9s |cffaaaaaa(seen today)", 1, true) then
        failures = failures + 1; print("   !! FAIL: expected live price AH 9s")
    end
end
ask("refresh prices", { "Refreshing 2 prices" })
advance(4)
AuctionFrame.shown = false
ask("where does linen drop", { "Linen Cloth|r drops from", "Defias Thug" }, { "Linen Bag|r", "Did you mean" })
ask("where can i buy linen", "Linen Shirt|r is sold by", { "Did you mean" })
ask("where can i get linen", "Linen Cloth|r", { "Linen Bag|r" })
ask("where is defias", { "Defias Thug", "Did you mean:" })

-- Clicking a "did you mean" name asks again with that name
local suggestion
for _, m in ipairs(output) do suggestion = m:match("|H(addon:askbot:%d+)|h%[Defias Pillager%]") or suggestion end
print("\n> click suggestion " .. tostring(suggestion))
local from = #output + 1
linkCallback(nil, suggestion)
if not table.concat(output, "\n", from):find("Defias Pillager|r lvl 14-15", 1, true) then
    failures = failures + 1; print("   !! FAIL: suggestion click did not ask again")
end
ask("where can i get gryans medal", "Gryan's Medal|r is a reward from quest")
ask("where is gryan stoutmantle", "Gryan Stoutmantle")
ask("where is martie jainrose", { "Martie Jainrose", "fly Westfall > Redridge Mountains" })
ask("defias brotherhood", "Gryan Stoutmantle")
ask("|cffffffff|Hitem:2589::::::::|h[Linen Cloth]|h|r", "Defias Thug")
ask("who gives |cffffff00|Hquest:100:18|h[The Defias Brotherhood]|h|r", { "starts at", "Gryan Stoutmantle" })
-- Bare quest links: in your log -> progress and turn-in; not in your log -> where it starts
ask("|cffffff00|Hquest:100:18|h[The Defias Brotherhood]|h|r", { "is complete:", "Turn in: ", "Gryan Stoutmantle" })
ask("|cffffff00|Hquest:103:10|h[Red Linen Goods]|h|r",
    { "is in progress:", "Collect ", "Linen Cloth|r from: ", "Turn in: " }, { "Kill: " })
ask("|cffffff00|Hquest:104:15|h[Scout Redridge]|h|r", { "Go to: ", "Scout the Redridge camp", "Turn in: ", "Martie Jainrose" })
ask("|cffffff00|Hquest:102:12|h[Bounty on Murlocs]|h|r", { "starts at", "Wanted Poster" })
ask("turn in |cffffff00|Hquest:103:10|h[Red Linen Goods]|h|r", { "is handed in to", "Gryan Stoutmantle" })
ask("red linen goods", "is in progress:")
-- Questie's quest links, as plain text (how they reached /ab in-game) and as real links
ask("[[10] Red Linen Goods (103)]", { "Red Linen Goods", "is in progress:" })
ask("[[10+] Red Linen Goods]", { "Red Linen Goods", "is in progress:" })
ask("who gives [[18D] The Defias Brotherhood (100)]", { "starts at", "Gryan Stoutmantle" })
ask("|Hquestie:103:Player-1-0001|h|cffffff00[|r|cffffff00[10] Red Linen Goods (103)|r|cffffff00]|r|h",
    "is in progress:")
ask("where can i find an innkeeper", "Innkeeper Heather")
ask("what is the meaning of life", "Sorry")

-- Clicking a [pin] link
local lastLink
for _, m in ipairs(output) do lastLink = m:match("|H(addon:askbot:%d+)|h%[pin%]") or lastLink end
print("\n> click " .. tostring(lastLink))
local before = tomtomWaypoints
linkCallback(nil, lastLink)
if tomtomWaypoints ~= before + 1 then failures = failures + 1; print("   !! FAIL: link click did not pin") end

-- Output follows the chat window the command was typed in
local tabMessages = {}
ChatFrame3 = { GetID = function() return 3 end, AddMessage = function(_, m) tabMessages[#tabMessages + 1] = m end }
SlashCmdList.ASKBOT("closest inn", { chatFrame = ChatFrame3 })
if not (tabMessages[1] and tabMessages[1]:find("Innkeeper", 1, true)) then
    failures = failures + 1; print("   !! FAIL: answer did not go to the typed-in chat window")
else
    print("\n> answer went to ChatFrame3 (" .. #tabMessages .. " lines)")
end
if AskBotCharDB.chatFrame ~= 3 then failures = failures + 1; print("   !! FAIL: chat window not remembered") end
ChatFrame3 = nil
SlashCmdList.ASKBOT("status", { chatFrame = DEFAULT_CHAT_FRAME }) -- switch back for the rest

-- Levelling helper
ask("what's next", { "Ready to hand in:", "The Defias Brotherhood", "Gryan Stoutmantle", "Nearest objectives:",
    "Linen Cloth|r from: ", "Scout the Redridge camp" }, { "Kill: " })
ask("quests here", { "Quests you can pick up (2 on this continent)", "Gryan Stoutmantle", "Patrolling Westfall",
    "Wanted Poster", "Bounty on Murlocs" }, { "Too Easy", "Too Hard", "Already Done", "Defias Brotherhood" })
ask("what quests can i get", "Patrolling Westfall")
ask("dungeons", { "Dungeons for level 20:", "The Deadmines|r (10-26)", "[loot]", "entrance Westfall 42.6, 71.8" },
    { "Blackrock Depths" })
ask("dungeons for level 55", "Blackrock Depths|r (48-60)", { "Deadmines" })
ask("rares near me", { "Rare mobs nearest you:", "Leprithus|r lvl 19 |cffc0c0c0(rare)", "Foreman Grills", "(rare elite)" })

-- Another continent, two boats: Westfall > Stormwind > Auberdine > Rut'theran
ask("where is jannok breezesong", { "Jannok Breezesong", "boat Stormwind Harbor > Auberdine",
    "boat Auberdine > Rut'theran Village" }, { "other continent" })

faction = "Horde"
ask("skinner please", { "Horde Skinner", "Orc Skinner|r <Skinning Trainer> - Orgrimmar", "zeppelin Grom'gol > Orgrimmar" },
    { "Helene", "other continent" })
faction = "Alliance"

-- Settings and "!ask" from other players --------------------------------------------------
local function expectChat(label, fn, expect, reject)
    local from = #sentChat + 1
    print("\n> " .. label)
    fn()
    for _ = 1, 50 do advance(0.1) end -- small steps, so timers started by timers run too
    local lines = {}
    for i = from, #sentChat do
        local m = sentChat[i]
        lines[#lines + 1] = m[2] .. (m[3] and (" to " .. m[3]) or "") .. ": " .. m[1]
        print("   " .. lines[#lines])
    end
    local text = table.concat(lines, "\n")
    for _, e in ipairs(expect or {}) do
        if not text:find(e, 1, true) then failures = failures + 1; print("   !! FAIL: expected " .. e) end
    end
    for _, r in ipairs(reject or {}) do
        if text:find(r, 1, true) then failures = failures + 1; print("   !! FAIL: did not expect " .. r) end
    end
    if not expect and #lines > 0 then failures = failures + 1; print("   !! FAIL: expected no reply") end
end

ask("share", { "guild |cffff6060off|r", "party/raid |cffff6060off|r", "whispers |cffff6060off|r" })
expectChat("guild !ask while sharing is off", function()
    fire("CHAT_MSG_GUILD", "!ask nearest skinning trainer", "Guildie-Realm")
end)
ask("share guild on", "guild |cff66cc33on|r")

-- A guild member in Stormwind: answered from the middle of their zone, as plain chat
local pinsBefore = tomtomWaypoints
expectChat("guild: !ask nearest skinning trainer", function()
    fire("CHAT_MSG_GUILD", "!ask nearest skinning trainer", "Guildie-Realm")
end, { "GUILD: [AskBot] Nearest Skinning trainer:", "Helene Peltskinner <Skinning Trainer> - Stormwind City 71.6, 62.8 (" },
    { "|c", "[pin]", "AskBot:" })
if tomtomWaypoints ~= pinsBefore then failures = failures + 1; print("   !! FAIL: answering someone else placed a pin") end
expectChat("same guild member again within the cooldown", function()
    fire("CHAT_MSG_GUILD", "!ask closest inn", "Guildie-Realm")
end)
advance(10)
expectChat("guild: their class trainer (they're a mage, I'm a warrior)", function()
    fire("CHAT_MSG_GUILD", "!ask where's my class trainer", "Guildie-Realm")
end, { "Mage trainer" }, { "Warrior" })
advance(10)
expectChat("guild: quest log questions need their own AskBot", function()
    fire("CHAT_MSG_GUILD", "!ask what's next", "Guildie-Realm")
end, { "[AskBot] I can't see your quest log" })
advance(10)
expectChat("guild: real item links survive", function()
    fire("CHAT_MSG_GUILD", "!ask price of linen cloth", "Guildie-Realm")
end, { "|cffffffff|Hitem:2589::|h[Linen Cloth]|h|r: AH" })
advance(10)
expectChat("guild: another player's AskBot claimed it first", function()
    fire("CHAT_MSG_GUILD", "!ask closest inn", "Guildie-Realm")
    fire("CHAT_MSG_ADDON", "AskBot", "claim:Guildie:closest inn", "GUILD", "Other-Realm")
end)
if not (sentAddon[1] and sentAddon[1][1] == "AskBot" and sentAddon[1][2]:find("^claim:Guildie:")) then
    failures = failures + 1; print("   !! FAIL: no claim message sent")
end

-- A party member in Redridge: answered from their exact position, routed back to Westfall
AskBot.SetOption("shareParty", true)
inGroup = true
expectChat("party: !ask closest inn", function()
    fire("CHAT_MSG_PARTY", "!ask closest inn", "Buddy")
end, { "PARTY: [AskBot] Nearest Innkeeper:", "Innkeeper Heather", "fly Redridge Mountains > Westfall" })
inGroup = false
expectChat("whisper while whisper sharing is off", function()
    fire("CHAT_MSG_WHISPER", "!ask closest inn", "Stranger")
end)

-- Settings: fewer results, no automatic pin
AskBot.SetOption("maxResults", 1)
AskBot.SetOption("autoPin", false)
pinsBefore = tomtomWaypoints
ask("nearest fp", "Thor", { "Dungar Longdrink" })
if tomtomWaypoints ~= pinsBefore then failures = failures + 1; print("   !! FAIL: pinned with auto-pin off") end
AskBot.SetOption("maxResults", 3)
AskBot.SetOption("autoPin", true)

print(failures == 0 and "\nALL PASSED" or ("\n" .. failures .. " FAILURE(S)"))
os.exit(failures == 0 and 0 or 1)
