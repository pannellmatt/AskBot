-- Smoke test: load AskBot with stubbed WoW/Questie APIs and ask some questions.
-- Run from the addon folder:  luajit tests\smoke.lua .
local dir = arg[1] or "."

local output = {}
-- Quest names are coloured AskBot links; tests match them as plain coloured text too.
local function withPlainQuestLinks(text)
    local plain = text:gsub("(|c%x%x%x%x%x%x%x%x)|Haddon:askbot:%d+|h(.-)|h|r", function(color, t)
        if color:lower() == "|cff71d5ff" then return nil end
        return color .. t .. "|r"
    end)
    return text .. "\n" .. plain
end
DEFAULT_CHAT_FRAME = { AddMessage = function(_, m)
    output[#output + 1] = m
    print((m:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|Haddon:askbot:(%d+)|h", "<%1>"):gsub("|h", "")))
end }

-- Frames, timers, events -----------------------------------------------------------------
local frames, tickerFn = {}, nil
function CreateFrame()
    local f = { scripts = {} }
    -- Forever's client has no TRADE_SKILL_UPDATE (registering it errors in the game).
    function f:RegisterEvent(event)
        if event == "TRADE_SKILL_UPDATE" then error("Attempt to register unknown event \"" .. event .. "\"") end
    end
    function f:SetScript(k, fn) self.scripts[k] = fn end
    function f:SetSize() end
    function f:Hide() end
    function f:CreateTexture() return { SetAllPoints = function() end, SetTexture = function() end } end
    frames[#frames + 1] = f
    return f
end
UIParent = {}
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
function UnitGUID(u) return UnitExists(u) and ({ player = "Player-1-0001", party1 = "Player-1-0002" })[u] or nil end
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
    [1413] = { "The Barrens", 3000, 2000, 1 },
}
-- The game's map pin (one at a time) and its chat link
local userWaypoint
UiMapPoint = { CreateFromCoordinates = function(map, x, y) return { uiMapID = map, position = { x = x, y = y } } end }
C_Map = {
    GetBestMapForUnit = function(unit) return ({ player = 1436, party1 = 1433 })[unit] end,
    GetMapInfo = function(id) return maps[id] and { name = maps[id][1], mapType = 3 } end,
    CanSetUserWaypointOnMap = function(id) return maps[id] ~= nil end,
    SetUserWaypoint = function(p) userWaypoint = p end,
    ClearUserWaypoint = function() userWaypoint = nil end,
    HasUserWaypoint = function() return userWaypoint ~= nil end,
    GetUserWaypoint = function() return userWaypoint end,
    GetUserWaypointHyperlink = function()
        local p = userWaypoint
        return p and string.format("|cffffff00|Hworldmap:%d:%d:%d|h[Map Pin Location]|h|r", p.uiMapID,
            math.floor(p.position.x * 10000 + 0.5), math.floor(p.position.y * 10000 + 0.5))
    end,
}
local hbd = {
    GetWorldCoordinatesFromZone = function(_, x, y, map)
        local m = maps[map]
        if not m then return nil end
        return m[2] + x * 1000, m[3] + y * 1000, m[4]
    end,
    GetPlayerWorldPosition = function() return 2500, 500, 0 end, -- middle of Westfall
    GetZoneCoordinatesFromWorld = function(_, x, y, map)
        local m = maps[map]
        if m then return (x - m[2]) / 1000, (y - m[3]) / 1000 end
    end,
    GetUnitWorldPosition = function(_, u) local d = units[u]; if d then return d[5], d[6], 0 end end,
    mapData = maps,
    GetWorldDistance = function(_, _, x1, y1, x2, y2) return math.sqrt((x1 - x2) ^ 2 + (y1 - y2) ^ 2) end,
    -- HereBeDragons-Pins (LibStub returns this one object for every library)
    worldIcons = 0,
    AddWorldMapIconMap = function(self) self.worldIcons = self.worldIcons + 1 end,
    AddMinimapIconMap = function() end,
    RemoveAllWorldMapIcons = function(self) self.worldIcons = 0 end,
    RemoveAllMinimapIcons = function() end,
}
LibStub = function() return hbd end

local tomtomWaypoints, lastPinTitle = 0, nil
TomTom = {
    AddWaypoint = function(_, map, x, y, opts)
        tomtomWaypoints = tomtomWaypoints + 1
        lastPinTitle = opts.title
        print(string.format("   [TomTom] %s at %s %.3f,%.3f", opts.title, maps[map][1], x, y))
        return tomtomWaypoints
    end,
    RemoveWaypoint = function() end,
}

-- QuestieDB data -------------------------------------------------------------------------
local W, SW, DM, RR, OG = 40, 1519, 1, 44, 1637 -- area ids
local TD, DS, BAR = 141, 148, 17
local areaToMap = { [SW] = 1453, [W] = 1436, [DM] = 1426, [RR] = 1433, [OG] = 1454, [TD] = 1438, [DS] = 1439, [BAR] = 1413 }
local npcs = {
    [11867] = { "Woo Ping", "Weapon Master", 16, "A", { [SW] = { { 63.9, 69.1 } } } },
    [11866] = { "Ilyenia Moonfire", "Weapon Master", 16, "A", { [DM] = { { 40, 40 } } } },
    [2704] = { "Hanashi", "Weapon Master", 16, "H", { [OG] = { { 50, 50 } } } },
    [260080] = { "Ember Bladewhisper", "Weapons Trainer", 16, "A", { [DM] = { { 45, 45 } } } },
    [1] = { "Helene Peltskinner", "Skinning Trainer", 16, "A", { [SW] = { { 71.6, 62.8 } } } },
    [2] = { "Far Skinner", "Skinning Trainer", 16, "A", { [DM] = { { 50, 50 } } } },
    [3] = { "Horde Skinner", "Skinning Trainer", 16, "H", { [W] = { { 55, 50 } } } },
    [4] = { "Thor", "Gryphon Master", 8, "A", { [W] = { { 56.6, 52.6 } } } },
    [5] = { "Innkeeper Heather", "Innkeeper", 128, "A", { [W] = { { 52.9, 53.6 } } } },
    [6] = { "Ander Germaine", "Warrior Trainer", 16, "A", { [SW] = { { 79, 70 } } } },
    [7] = { "Orc Skinner", "Skinning Trainer", 16, "H", { [OG] = { { 63, 45 } } } },
    [8] = { "Dungeon Guy", "Skinning Trainer", 16, "A", { [W] = { { -1, -1 } } } },
    [9] = { "Gryan Stoutmantle", "People's Militia", 2, "A", { [W] = { { 56.3, 47.5 } } } },
    [36] = { "Rune Broker", nil, 4, "A", { [W] = { { 50, 50 } } } },  -- in Questie's data, not in the game
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
    [23] = { "Auberdine Quester", nil, 2, "A", { [DS] = { { 37, 44 } } } },
    [24] = { "Thork", nil, 2, "H", { [BAR] = { { 51, 30 } } } },                -- Horde quest giver
    [25] = { "Chain Giver", nil, 2, "A", { [DM] = { { 40, 40 } } } },
    [12144] = { "Lunaclaw Spirit", nil, 0, nil, {} },                           -- summoned: no spawns
    -- Beasts for skinning (by name); the Pathstalker is a Defias, not a beast
    [31] = { "Coyote", nil, 0, nil, { [W] = { { 60, 20 }, { 62, 22 }, { 64, 24 } } }, 14, 15 },
    [32] = { "Black Bear", nil, 0, nil, { [RR] = { { 30, 30 } } }, 15, 16 },
    [33] = { "Defias Pathstalker", nil, 0, nil, { [RR] = { { 31, 31 }, { 32, 32 }, { 33, 33 }, { 34, 34 } } }, 15, 16 },
    [34] = { "Elder Wolf", nil, 0, nil, { [W] = { { 50, 50 } } }, 40, 41 },     -- too high to skin
    [35] = { "Grey Thing", nil, 0, nil, { [W] = { { 70, 30 } } }, 14, 15 },      -- a beast only the game knows
    [641] = { "Goblin Woodcarver", nil, 0, nil, { [1581] = { { -1, -1 } } }, 18, 19 }, -- inside the Deadmines
    [5676] = { "Summoned Voidwalker", nil, 0, nil, {} },
    [376] = { "High Priestess Laurena", "Priest Trainer", 16, "A", { [SW] = { { 49.5, 44.6 } } } },
}
local quests = {
    [100] = { "The Defias Brotherhood", 1, { { 9 } }, { { 9 } }, 18, 14 },
    [101] = { "The Defias Brotherhood", 2, { { 13 } }, { { 13 } }, 18, 14 },
    [102] = { "Bounty on Murlocs", 0, { nil, { 500 } }, { { 5 } }, 12, 10 },
    [103] = { "Red Linen Goods", 1, { { 9 } }, { { 9 } }, 10, 8,
        { { { 10 } }, nil, { { 2589 } } }, nil, nil, nil,                    -- kill thugs, collect linen
        { "Kill 10 Defias Thugs and bring 6 Linen Cloth to Gryan." } },
    [104] = { "Scout Redridge", 1, { { 9 } }, { { 16 } }, 15, 12, {},
        { "Scout the Redridge camp", { [RR] = { { 50, 50 } } } } },          -- explore objective
    [105] = { "Patrolling Westfall", 1, { { 9 } }, { { 9 } }, 14, 10 },     -- available at Gryan
    [106] = { "Too Easy", 1, { { 9 } }, { { 9 } }, 3, 1 },                  -- grey for a level 20
    [107] = { "Too Hard", 1, { { 9 } }, { { 9 } }, 30, 28 },                -- level 28 needed
    [108] = { "Already Done", 1, { { 5 } }, { { 5 } }, 15, 10 },            -- Questie says not doable
    [109] = { "Westfall Stew", 1, { { 9 } }, { { 9 } }, 15, 12,           -- loot linen from thugs
        { nil, nil, { { 2589 } } }, nil, nil, nil, { "Bring 6 Linen Cloth to Gryan Stoutmantle." } },
    [110] = { "Goretusk Liver Pie", 1, { { 9 } }, { { 9 } }, 16, 12,      -- kill thugs
        { { { 10 } } }, nil, nil, nil, { "Kill 10 Defias Thugs, then return to Gryan." } },
    [160] = { "Thug Cull", 1, { { 9 } }, { { 9 } }, 23, 21,               -- kill thugs, opens at 21
        { { { 10 } } }, nil, nil, nil, { "Kill 15 Defias Thugs." } },
    [111] = { "Redridge Goulash", 1, { { 16 } }, { { 16 } }, 18, 15 },
    [112] = { "Blackrock Menace", 1, { { 16 } }, { { 16 } }, 19, 16 },
    [113] = { "Shadowhide Gnolls", 1, { { 16 } }, { { 16 } }, 22, 18 },
    [114] = { "Horde Errand 1", 0, { { 24 } }, { { 24 } }, 19, 15 },   -- no race rule, but the giver is Horde
    [115] = { "Horde Errand 2", 0, { { 24 } }, { { 24 } }, 19, 15 },
    [116] = { "Horde Errand 3", 0, { { 24 } }, { { 24 } }, 20, 15 },
    [117] = { "City Errand 1", 1, { { 6 } }, { { 6 } }, 19, 15 },      -- given in Stormwind
    [118] = { "City Errand 2", 1, { { 6 } }, { { 6 } }, 19, 15 },
    [119] = { "City Errand 3", 1, { { 6 } }, { { 6 } }, 20, 15 },
    [120] = { "Darkshore Task 1", 1, { { 23 } }, { { 23 } }, 19, 15 }, -- across the sea
    [121] = { "Darkshore Task 2", 1, { { 23 } }, { { 23 } }, 20, 15 },
    [122] = { "Darkshore Task 3", 1, { { 23 } }, { { 23 } }, 21, 15 },
    [125] = { "Far Errand", 1, { { 22 } }, { { 22 } }, 20, 15 },         -- handed in on Teldrassil
    -- Deadmines quests (filed under the dungeon, area 1581), given in Stormwind so they don't
    -- change the Westfall counts; only doable during the dungeon prep test.
    [142] = { "Red Silk Bandanas", 1, { { 6 } }, { { 6 } }, 17, 14 },
    [143] = { "Oh Brother", 1, { { 6 } }, { { 6 } }, 20, 15 },             -- after 142
    [144] = { "Underground Assault", 1, { { 6 } }, { { 6 } }, 24, 22 },    -- needs level 22
    [145] = { "Test of Righteousness", 1, { { 6 } }, { { 6 } }, 22, 20,   -- paladin: lumber from inside
        { nil, nil, { { 6994 } } } },
    [146] = { "Warrior Errand", 1, { { 6 } }, { { 6 } }, 20, 18, { { { 641 } } } }, -- warrior: kill inside
    [147] = { "The Defias Note", 1, { nil, nil, { 9030 } }, { { 9 } }, 20, 15 },  -- started by an item
    -- Handed in at Redridge, given in Stormwind: one needs level 21, one comes after another quest,
    -- one is for paladins
    [148] = { "Redridge Summons", 1, { { 6 } }, { { 16 } }, 21, 21 },
    [149] = { "Redridge Orders", 1, { { 6 } }, { { 16 } }, 18, 15 },
    [150] = { "Paladin Summons", 1, { { 6 } }, { { 16 } }, 18, 15 },
    [151] = { "Lead-in Orders", 1, { { 6 } }, { { 6 } }, 15, 12 },
    [130] = { "Chain Part 1", 1, { { 25 } }, { { 25 } }, 14, 10 },
    [131] = { "Chain Part 2", 1, { { 25 } }, { { 25 } }, 16, 12 },
    [132] = { "Chain Part 3", 1, { { 25 } }, { { 25 } }, 18, 15 },
    [133] = { "Side Errand", 1, { { 25 } }, { { 25 } }, 15, 12 },
    [134] = { "Horde Version", 2, { { 24 } }, { { 24 } }, 14, 10 },
    [135] = { "Done Earlier", 1, { { 25 } }, { { 25 } }, 12, 10 },
    [136] = { "After Done", 1, { { 25 } }, { { 25 } }, 13, 10 },
    [137] = { "Lead-in", 1, { { 25 } }, { { 25 } }, 12, 10 },
    -- Class quests with community locations (real IDs, so KnownLocations.lua applies)
    [6001] = { "Body and Heart", 1, { { 9 } }, { { 9 } }, 10, 10, { { { 12144, "Lunaclaw Spirit" } } } },
    [1786] = { "The Tome of Divinity", 1, { { 9 } }, { { 16 } }, 13, 12, { { { 16 } } }, nil, nil, { 6866 } },
    [1789] = { "The Symbol of Life", 1, { { 6 } }, { { 6 } }, 12, 12 },
    [1689] = { "The Binding", 1, { { 6 } }, { { 6 } }, 10, 10, { { { 5676 } } } },
    [94778] = { "Divine Grace", 1, {}, {}, 10, 10 },
    [141] = { "Thread Run", 1, { { 9 } }, { { 9 } }, 12, 10, { nil, nil, { { 2320 } } } },
    [124] = { "Trial of the Sea Lion", 1, { { 9 } }, { { 9 } }, 16, 16,          -- items Questie cannot place
        { nil, nil, { { 15885 } } }, nil,                                  -- objective: the combined pendant
        { { { [W] = { { 30, 30 } } }, 0, "Speak with the spirit" } }, { 15882, 15883 } },  -- halves to bring
}
-- What Questie's IsDoable would say (completed quests, prerequisites, etc.)
local doable = { [102] = true, [105] = true, [106] = true, [107] = true, [109] = true, [110] = true,
    [111] = true, [112] = true, [113] = true, [114] = true, [115] = true, [116] = true,
    [117] = true, [118] = true, [119] = true, [120] = true, [121] = true, [122] = true }
-- Quest log: 100 complete, 103 half done (thugs killed), 104 in progress; 102 not taken.
local questLog = {
    [100] = { complete = true, objectives = {} },
    [103] = { complete = false, objectives = {
        { text = "Defias Thug slain: 10/10", finished = true, numFulfilled = 10, numRequired = 10 },
        { text = "Linen Cloth: 2/6", finished = false, numFulfilled = 2, numRequired = 6 } } },
    [104] = { complete = false, objectives = { { text = "Scout the Redridge camp", finished = false } } },
}
-- Quest chains: 132 needs all of {131, 133}; 131 needs any one of {130, 134 (Horde only)};
-- 136 follows 135, which is done; 137 is an optional lead-in to 132.
local chain = {
    [131] = { single = { 130, 134 } }, [132] = { group = { 131, 133 }, crumbs = { 137 } },
    [136] = { single = { 135 } }, [130] = { nextQuest = 131 },
    [143] = { single = { 142 } }, [149] = { single = { 151 } },
}
local questZone = { [142] = 1581, [143] = 1581, [144] = 1581 }
-- Reputation rewards: Stormwind (72)
local questRep = { [100] = { { 72, 75 } }, [105] = { { 72, 250 } }, [109] = { { 72, 150 } }, [107] = { { 72, 500 } } }
local questClasses = { [145] = 2, [146] = 1, [150] = 2 } -- paladin, warrior
local completed = { [135] = true }
C_QuestLog = {
    IsQuestFlaggedCompleted = function(id) return completed[id] == true end,
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
    [15883] = { name = "Half Pendant of Aquatic Agility" },
    [15882] = { name = "Half Pendant of Aquatic Endurance", objectDrops = { 502 } },
    [15885] = { name = "Pendant of the Sea Lion", objectDrops = { 501 } },
    [4238] = { name = "Linen Bag" },
    [2570] = { name = "Linen Shirt", vendors = { 12 } },
    [2996] = { name = "Bolt of Linen Cloth" },
    [6866] = { name = "Symbol of Life", questRewards = { 1789 } },
    [6994] = { name = "Whitestone Oak Lumber", npcDrops = { 641 } },
    [9001] = { name = "Militia Leggings", questRewards = { 112 } },
    [9005] = { name = "Apprentice Wand", questRewards = { 112 } },
    [9020] = { name = "Grills' Girdle", npcDrops = { 20 } },               -- dropped by a rare in Westfall
    [9022] = { name = "Spell Ring" },
    [5771] = { name = "Pattern: Red Linen Bag", vendors = { 12 } },          -- a recipe sold by the Thread Seller
    [2406] = { name = "Pattern: Fine Leather Boots", vendors = { 12 } },
    [9030] = { name = "Strange Note", npcDrops = { 10 } },                   -- starts The Defias Note
    [9004] = { name = "Silver Ring" },
}
local objects = { [500] = { "Wanted Poster", { [W] = { { 53, 52 } } } }, [501] = { "Shrine of Remulos", { [W] = { { 20, 80 } } } },
    -- Gathering: copper in Westfall (2 points; 2055 repeats one) and Dun Morogh (3)
    [1731] = { "Copper Vein", { [W] = { { 40, 50 }, { 60, 50 } }, [DM] = { { 10, 10 }, { 20, 20 }, { 30, 30 } } } },
    [2055] = { "Copper Vein", { [W] = { { 40, 50 } } } },
    [1732] = { "Tin Vein", { [RR] = { { 50, 50 } } } },
    [1733] = { "Silver Vein", { [RR] = { { 60, 60 } } } },
    [1618] = { "Peacebloom", { [W] = { { 55, 45 } } } },
    [439558] = { "Cold Iron Deposit", { [RR] = { { 10, 90 } } } },
    [92015] = { "Summoning Circle", { [SW] = { { 25, 77 } } } },
    [502] = { "Strange Lockbox", { [W] = { { 20, 20 } } } },    -- Questie links the wrong half to it
}
-- Skills: Mining 70, no Herbalism
local skillLines = { { "Professions", true }, { "Mining", false, 70 }, { "Secondary Skills", true }, { "Fishing", false, 20 },
    { "Weapon Skills", true }, { "Axes", false, 100 }, { "Swords", false, 100 }, { "Maces", false, 100 },
    { "Armor Proficiencies", true }, { "Cloth", false, 1 }, { "Leather", false, 1 }, { "Mail", false, 1 }, { "Shield", false, 1 } }
function GetNumSkillLines() return #skillLines end
function GetSkillLineInfo(i) local s = skillLines[i]; return s[1], s[2], true, s[3] end

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
    extraObjectives = function(id) return quests[id][9] end,
    requiredSourceItems = function(id) return quests[id][10] end,
    objectivesText = function(id) return quests[id][11] end,
    preQuestSingle = function(id) return chain[id] and chain[id].single end,
    preQuestGroup = function(id) return chain[id] and chain[id].group end,
    nextQuestInChain = function(id) return chain[id] and chain[id].nextQuest end,
    breadcrumbs = function(id) return chain[id] and chain[id].crumbs end,
    zoneOrSort = function(id) return questZone[id] end,
    requiredClasses = function(id) return questClasses[id] end,
    reputationReward = function(id) return questRep[id] end,
}
ItemDB = { GetAllIds = function() return ids(items) end }
for _, field in ipairs({ "name", "npcDrops", "objectDrops", "vendors", "questRewards", "itemDrops" }) do
    ItemDB[field] = function(id) return items[id] and items[id][field] end
end
local gear -- filled in with the game item stubs below
ItemDB.class = function(id) return gear[id] and gear[id][3] end
ItemDB.subClass = function(id) return gear[id] and gear[id][4] end
ItemDB.requiredLevel = function(id) return gear[id] and gear[id][5] end
ItemDB.itemLevel = function(id) return gear[id] and gear[id][6] end
ObjectDB = {
    GetAllIds = function() return ids(objects) end,
    name = function(id) return objects[id] and objects[id][1] end,
    spawns = function(id) return objects[id][2] end,
}
LibQuestieDB = {
    RequireContract = function() return true end,
    Enum = {
        npcFlags = { QUEST_GIVER = 2, VENDOR = 4, FLIGHT_MASTER = 8, TRAINER = 16, INNKEEPER = 128,
            BANKER = 256, AUCTIONEER = 4096, STABLEMASTER = 8192, REPAIR = 16384 },
        factionRaceMasks = { Alliance = 1, Horde = 2 },
        classKeys = { WARRIOR = 1, PALADIN = 2, HUNTER = 4 },
    },
}
Questie = { started = true }
-- Questie's party sync: quest id -> { player name -> objectives }, and players who sent data
local remoteLogs, remoteClasses = {}, {}
-- QuestieDB's quest XP: { quest level, base XP }; level 60 so it isn't scaled down for you.
local questXp = { [100] = 2000, [103] = 900, [105] = 1050, [109] = 850, [110] = 1200, [104] = 1100, [111] = 1400,
    [112] = 1500, [113] = 1700, [120] = 1400, [121] = 1500, [122] = 1600 }
local xpDb = setmetatable({}, { __index = function(_, id) return questXp[id] and { 60, questXp[id] } end })
-- QuestieDB's support tables (zone maps ship as Lua source, as in the real data)
local areaSource = {}
for a, m in pairs(areaToMap) do areaSource[#areaSource + 1] = "[" .. a .. "]=" .. m end
local supportData = {
    ZoneDB = { private = { areaIdToUiMapId = "return {" .. table.concat(areaSource, ",") .. "}",
        areaIdToUiMapIdOverride = "return { [0] = 0 }",
        dungeons = { [1581] = { "The Deadmines", {}, W, { { W, 42.6, 71.8 } } } } } },
    QuestXP = { db = xpDb },
}
LibQuestieDB.Support = { Get = function(name) return supportData[name] end }
-- Questie's own modules: its quest check and party sync (all AskBot still takes from Questie)
QuestieLoader = { ImportModule = function() return {
    GetQuest = function(_, id) return remoteLogs[id] end,
    remotePlayerClasses = remoteClasses,
    IsDoable = function(id) return doable[id] == true end,
} end }

-- Game item cache: names for gear Questie doesn't know; 2589 has a link and vendor price.
local bags = {}  -- item id -> count in your bags
local itemCache = { [5193] = "Cape of the Brotherhood", [5202] = "Corsair's Overshirt",
    [10399] = "Blackened Defias Armor", [872] = "Rockslicer", [2589] = "Linen Cloth" }
-- Gear: { name, equipLoc, classID, subclassID, requiredLevel, itemLevel, stats, loaded }
gear = {
    [9010] = { "Worn Leggings", "INVTYPE_LEGS", 4, 3, 10, 15, { ITEM_MOD_STRENGTH_SHORT = 1, ITEM_MOD_STAMINA_SHORT = 1 } },
    [9011] = { "Old Tunic", "INVTYPE_CHEST", 4, 3, 10, 15, { ITEM_MOD_STAMINA_SHORT = 2 } },
    [9012] = { "Worn Mace", "INVTYPE_WEAPON", 2, 4, 10, 15, { ITEM_MOD_DAMAGE_PER_SECOND_SHORT = 5, ITEM_MOD_STRENGTH_SHORT = 1 } },
    [9001] = { "Militia Leggings", "INVTYPE_LEGS", 4, 3, 18, 23, { ITEM_MOD_STRENGTH_SHORT = 5, ITEM_MOD_STAMINA_SHORT = 4, RESISTANCE0_NAME = 100 }, false },
    [9005] = { "Apprentice Wand", "INVTYPE_RANGEDRIGHT", 2, 19, 15, 20, { ITEM_MOD_DAMAGE_PER_SECOND_SHORT = 10 } },
    [9004] = { "Silver Ring", "INVTYPE_FINGER", 4, 0, 18, 22, { ITEM_MOD_STRENGTH_SHORT = 3 } },
    [5193] = { "Cape of the Brotherhood", "INVTYPE_CLOAK", 4, 1, 19, 24, { ITEM_MOD_AGILITY_SHORT = 3, ITEM_MOD_STAMINA_SHORT = 3 } },
    [10399] = { "Blackened Defias Armor", "INVTYPE_CHEST", 4, 2, 21, 26, { ITEM_MOD_AGILITY_SHORT = 8, ITEM_MOD_STAMINA_SHORT = 8, RESISTANCE0_NAME = 80 } },
    [872] = { "Rockslicer", "INVTYPE_2HWEAPON", 2, 1, 19, 24, { ITEM_MOD_DAMAGE_PER_SECOND_SHORT = 15, ITEM_MOD_STRENGTH_SHORT = 10 } },
    [9020] = { "Grills' Girdle", "INVTYPE_WAIST", 4, 3, 19, 24, { ITEM_MOD_STRENGTH_SHORT = 4 } },
    [9021] = { "Heavy Plate Helm", "INVTYPE_HEAD", 4, 4, 20, 25, { ITEM_MOD_STAMINA_SHORT = 6 } },
    [9022] = { "Spell Ring", "INVTYPE_FINGER", 4, 0, 18, 22, {} },          -- its only stat is an Equip: line
    [9014] = { "Ragged Leather Boots", "INVTYPE_FEET", 4, 2, 1, 5, { RESISTANCE0_NAME = 16 } },
    [9015] = { "Flimsy Chain Boots", "INVTYPE_FEET", 4, 3, 1, 5, { RESISTANCE0_NAME = 34 } },
}
-- Tooltip lines (C_TooltipInfo) for items whose bonuses only show as "Equip:" text
local tooltips = { [9022] = { "Spell Ring", "Equip: Increases damage and healing done by magical spells and effects by up to 7." } }
C_TooltipInfo = { GetHyperlink = function(link)
    local id = tonumber(tostring(link):match("item:(%d+)"))
    local lines = {}
    for _, t in ipairs(tooltips[id] or {}) do lines[#lines + 1] = { leftText = t } end
    return { lines = lines }
end }
for id, g in pairs(gear) do
    if g[8] == nil then g[8] = true end
    itemCache[id] = itemCache[id] or g[1]
end
local function gearLink(id) return "|cff1eff00|Hitem:" .. id .. "::|h[" .. gear[id][1] .. "]|h|r" end
local equipped = { [7] = 9010, [5] = 9011, [16] = 9012 }
function GetInventoryItemLink(_, slot) return equipped[slot] and gearLink(equipped[slot]) end
local talents = { 11, 0, 0 }
function GetNumTalentTabs() return 3 end
function GetTalentTabInfo(i) return ({ "Arms", "Fury", "Protection" })[i], "icon", talents[i] end
C_Item = {
    GetItemNameByID = function(id) return itemCache[id] end,
    RequestLoadItemDataByID = function() end,
    GetItemCount = function(id) return bags[id] or 0 end,
    GetItemInfo = function(id)
        if type(id) == "string" then id = tonumber(id:match("item:(%d+)")) end
        if id == 2589 then return "Linen Cloth", "|cffffffff|Hitem:2589::|h[Linen Cloth]|h|r", 1, 5, 0, "Trade Goods", "Cloth", 20, "", 0, 13 end
        local g = gear[id]
        if g and g[8] then return g[1], gearLink(id), 2, g[6], g[5] end
    end,
    GetItemInfoInstant = function(id)
        if type(id) == "string" then id = tonumber(id:match("item:(%d+)")) end
        local g = gear[id]
        if g then return id, nil, nil, g[2], nil, g[3], g[4] end
    end,
    GetItemStats = function(link)
        local id = tonumber(tostring(link):match("item:(%d+)"))
        return gear[id] and gear[id][7] or {}
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
    },
        AtlasLootClassic_Crafting = {
            Leatherworking = { name = "Leatherworking", items = {
                { name = "Armor", [1] = { { 1, 2149 }, { 2, 2153 }, { 3, 2158 }, { 4, 2161 } } } } },
        },
    } },
    Loader = { LoadModule = function(_, name, onLoad) onLoad(name) end },
    Data = {
        Droprate = { GetData = function(_, npc, item) return rates[npc] and rates[npc][item] end },
        -- [spell] = { createdItem, profession (3 = Leatherworking), learn, yellow, grey, reagents, counts }
        Profession = { GetProfessionData = function(spell) return ({
            [2149] = { 2302, 3, 1, 40, 70, { 2318, 2320 }, { 2, 1 } },     -- Handstitched Leather Boots (trainer)
            [2153] = { 2303, 3, 30, 45, 75, { 2318, 2320 }, { 4, 1 } },    -- Handstitched Leather Pants (trainer)
            [2158] = { 2307, 3, 90, 120, 160, { 2318, 2320 }, { 5, 2 } },  -- Fine Leather Boots (pattern)
            [2161] = { 2309, 3, 55, 85, 125, { 2318 }, { 6 } },           -- Embossed Leather Boots (trainer, later)
        })[spell] end },
        Recipe = { GetRecipeForSpell = function(spell) return ({ [2158] = 2406 })[spell] end },
    },
}

-- Auctionator: a price database, and a search that finds `ahListings` while the AH is open
local ahPrices, ahAges = { [2589] = 1250, [9004] = 5000 }, { [2589] = 0, [9004] = 0 }
-- Eight auction chests with a higher item level but weaker stats than the Deadmines chest:
-- they mustn't crowd it out of the items AskBot scores.
for i = 0, 7 do
    local id = 9100 + i
    gear[id] = { "Market Tunic " .. i, "INVTYPE_CHEST", 4, 3, 20, 30, { ITEM_MOD_STAMINA_SHORT = 3 }, true }
    items[id] = { name = "Market Tunic " .. i }
    itemCache[id] = gear[id][1]
    ahPrices[id], ahAges[id] = 2000, 0
end
local ahListings = {}   -- item name -> price the next search will find
local searches = 0
local dbUpdated
AuctionFrame = { shown = false, IsShown = function(self) return self.shown end }
Auctionator = { API = { v1 = {
    GetAuctionPriceByItemID = function(caller, id) assert(caller == "AskBot"); return ahPrices[id] end,
    GetAuctionAgeByItemID = function(_, id) return ahAges[id] end,
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
    local text = withPlainQuestLinks(table.concat(output, "\n", from))
    for _, e in ipairs(type(expect) == "table" and expect or { expect }) do
        if not text:find(e, 1, true) then failures = failures + 1; print("   !! FAIL: expected " .. e) end
    end
    for _, r in ipairs(reject or {}) do
        if text:find(r, 1, true) then failures = failures + 1; print("   !! FAIL: did not expect " .. r) end
    end
    return text
end

ask("status", "ready")
ask("where is my nearest skinning trainer", "Helene Peltskinner", { "Horde Skinner" })
ask("nearest fp?", "Thor")
ask("closest inn", "Innkeeper Heather")
ask("where is my nearest vendor", "Thread Seller", { "Horde Vendor", "Rune Broker", "Sorry" })
ask("nearest merchant", "Thread Seller")
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
    local text = withPlainQuestLinks(table.concat(output, "\n", from))
    for _, e in ipairs({ "refreshing 2 prices", "Price changes:", "12s 50c > ", "10s 80c", "1 not listed right now" }) do
        if not text:find(e, 1, true) then failures = failures + 1; print("   !! FAIL: expected " .. e) end
    end
end
-- At the AH, a price question is answered live
GetServerTime = os.time
ahListings["Linen Cloth"] = 900
ask("price of linen cloth", "Checking the auction house")
do
    local from = #output + 1
    advance(1)
    if not table.concat(output, "\n", from):find("AH 9s |cffaaaaaa(seen today)", 1, true) then
        failures = failures + 1; print("   !! FAIL: expected live price AH 9s")
    end
end
-- AHDB's full scans: AskBot takes the newer of its last scan (7s) and Auctionator's price (9s).
-- Auctionator only knows "today", so a refresh through AskBot counts as newer than a scan before it.
do
    AuctionFrame.shown = false
    local scanTs
    AuctionDB = { PlayerHouse = function() return "Alliance" end, Typical = function() return 0, 0, 0 end,
        LastPrice = function(_, id) if id == 2589 then return { scanTs, 700, 800, 40 } end end }
    scanTs = os.time() - 600   -- scanned before the live search just now
    ask("price of linen cloth", "AH 9s", { "AH 7s" })
    scanTs = os.time() + 60    -- a later scan
    ask("price of linen cloth", { "AH 7s", "seen today" })
    ahAges[2589] = 1           -- Auctionator's price is from yesterday, the scan today
    scanTs = os.time() - 3 * 86400
    ask("price of linen cloth", { "AH 9s", "seen yesterday" })   -- the scan is older
    ahAges[2589], AuctionDB, AuctionFrame.shown = 0, nil, true
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
ask("my quests", { "Ready to hand in:", "The Defias Brotherhood", "Gryan Stoutmantle", "Nearest objectives:",
    "Linen Cloth|r from: ", "Scout the Redridge camp" }, { "Kill: " })
ask("what should i do next", { "What to do next (level 20):", "Hand in: ", "Objective: ", "New quests: ",
    "Dungeon: ", "[my quests]", "Best zone: |cffffd100Redridge Mountains|r (1 yours + 3 new)" })
ask("quests here", { "Quests you can pick up (10 on this continent)", "Gryan Stoutmantle", "Patrolling Westfall",
    "Wanted Poster", "Bounty on Murlocs" }, { "Too Easy", "Too Hard", "Already Done", "Defias Brotherhood" })
ask("what quests can i get", "Patrolling Westfall")
-- Kill-only quests: Goretusk Liver Pie (kill thugs) yes; Westfall Stew (loot linen), Red Linen
-- Goods (kill + linen) and Bounty on Murlocs (no objectives) only with loot / not at all.
ask("what are all the kill only quests in the area that i can get", { "Kill-only quests to pick up in Westfall",
    "Goretusk Liver Pie", "Coming up:|r |cffffd100[23] Thug Cull|r|cffaaaaaa (at 21)",
    "Also 1 with mob drops to collect:" }, { "Westfall Stew", "Patrolling Westfall", "Bounty on Murlocs", "Wanted Poster" })
ask("kill and loot quests", { "Kill and loot quests to pick up in Westfall", "Goretusk Liver Pie", "Westfall Stew" },
    { "Patrolling Westfall", "Bounty on Murlocs" })
-- Quests finished with AH reagents: Westfall Stew (6 Linen Cloth, a mob-dropped trade good, 9s
-- on the AH by now) yes; Red Linen Goods (also kills) and Goretusk Liver Pie (kills only) no.
ask("what reagent quests are in my level range", { "AH reagent quests (1)",
    "Westfall Stew", "6 Linen Cloth ~54s", "hand in |cffffd100Gryan Stoutmantle" },
    { "Red Linen Goods", "Goretusk Liver Pie", "Bounty on Murlocs" })
ask("ah quests", { "To buy for this quest, ~54s in all:", "6 Linen Cloth x 9s = 54s" })
-- Forever's real Westfall Stew also wants Okra, a quest item (class 12) mobs drop: still listed,
-- the Okra to farm, only the linen to buy.
do
    local saved = { quests[109][7], quests[109][11] }
    quests[109][7] = { nil, nil, { { 2589 }, { 732 } } }
    quests[109][11] = { "Bring 6 Linen Cloth and 3 Okra to Gryan Stoutmantle." }
    items[732], gear[732] = { name = "Okra", npcDrops = { 10 } }, { "Okra", "", 12, 0, 0, 1 }
    ask("ah quests", { "Westfall Stew", "6 Linen Cloth|cffaaaaaa (farm 3 Okra)|r ~54s",
        "To buy for this quest, ~54s in all:", "6 Linen Cloth x 9s = 54s", "Farm yourself (not on the AH): 3 Okra" })
    ask("cost to complete westfall stew", { "~54s to buy", "3 Okra: can't be bought" })
    -- "log" limits it to your quest log: nothing there until Westfall Stew is taken.
    ask("ah quests in my log", "No quests in your log that the auction house can help with.", { "Westfall Stew" })
    local savedInfo, savedNum = C_QuestLog.GetInfo, C_QuestLog.GetNumQuestLogEntries
    C_QuestLog.GetNumQuestLogEntries = function() return 1 end
    C_QuestLog.GetInfo = function(n) return n == 1 and { questID = 109, title = "Westfall Stew" } or nil end
    questLog[109] = { complete = false, objectives = {} }
    ask("log ah quests", { "AH reagent quests in your log (1)", "Westfall Stew", "Farm yourself" }, { "[in log]" })
    C_QuestLog.GetInfo, C_QuestLog.GetNumQuestLogEntries, questLog[109] = savedInfo, savedNum, nil
    quests[109][7], quests[109][11] = saved[1], saved[2]
    items[732], gear[732] = nil, nil
end
bags[2589] = 2
ask("ah quests", { "To buy for this quest, ~36s in all:", "4 Linen Cloth|cffaaaaaa (have 2)|r x 9s = 36s" })
ask("cost to complete westfall stew", { "Westfall Stew", "4 Linen Cloth", "(have 2)", "x 9s = 36s",
    "Hand in: |cffffd100Gryan Stoutmantle" })
ask("|cffffff00|Hquest:109:15|h[Westfall Stew]|h|r cost to complete", { "4 Linen Cloth", "= 36s" }, { "starts at" })
ask("|cffffff00|Hquest:103:10|h[Red Linen Goods]|h|r how much would it cost", { "4 Linen Cloth",
    "plus objectives you can't buy" })
ask("|cffffff00|Hquest:110:16|h[Goretusk Liver Pie]|h|r cost", "doesn't ask for items")
-- AHDB says Linen Cloth is usually 5s: buying at 9s now is flagged.
AuctionDB = { PlayerHouse = function() return "Alliance" end,
    Typical = function(_, id) if id == 2589 then return 500, 600, 10 end return 0, 0, 0 end }
ask("cost to complete westfall stew", "x 9s |cffff8040usually 5s|r = 36s")
ask("ah quests", "x 9s |cffff8040usually 5s|r = 36s")
AuctionDB = nil
bags[2589] = nil
-- Quest names are links: clicking one asks about that quest.
do
    local questLink
    for _, m in ipairs(output) do questLink = m:match("|H(addon:askbot:%d+)|h%[16%] Goretusk Liver Pie|h") or questLink end
    print("\n> click " .. tostring(questLink))
    local from = #output + 1
    linkCallback(nil, questLink)
    local text = table.concat(output, "\n", from)
    if not text:find("Gryan Stoutmantle", 1, true) then failures = failures + 1; print("   !! FAIL: quest link click") end
end
-- Zones at level 20, standing in Westfall with two Westfall quests in the log: Redridge first
-- (the most XP: new quests 18-22 plus one of yours, 6 min away), then Darkshore (more XP than
-- Westfall; 20 min of travel would halve it, 6 min doesn't), then Westfall (only your two). Quests more than 2 levels from yours, Horde givers' quests and
-- capitals never count.
do
    local from = #output + 1
    ask("where should i level", { "Where to quest at level 20:",
        "3. |cffffd100Westfall|r: 2 yours, lvl 10-18, 2900 xp", "Gryan Stoutmantle, 68 yds",
        "1. |cffffd100Redridge Mountains|r: 1 yours + 3 new, lvl 15-22, 5700 xp", "Scout the Redridge camp",
        "2. |cffffd100Darkshore|r: 3 new, lvl 19-21, 4500 xp", "~6 min by boat" },
        { "The Barrens", "Stormwind City|r:", "Horde Errand" })
    local text = withPlainQuestLinks(table.concat(output, "\n", from))
    local function pos(s) return text:find(s, 1, true) or math.huge end
    if not (pos("Redridge Mountains|r:") < pos("Darkshore|r:") and pos("Darkshore|r:") < pos("Westfall|r:")) then
        failures = failures + 1; print("   !! FAIL: expected Redridge, then Darkshore, then Westfall")
    end
end
-- Debug: explains the zone you're in (Westfall) and the ranking
C_Map.GetBestMapForUnit = function(unit) return ({ player = 1436, party1 = 1433 })[unit] end
ask("zones debug", { "|cffffd100Westfall|r|cffaaaaaa: 15", "counted", "in your log", "too easy (grey)",
    "How these were ranked", "of yours", "away, score" }, { "The Barrens" })
-- "What now" while the map says you're in the best zone (Redridge): no "Best zone" line
do
    local saved = C_Map.GetBestMapForUnit
    C_Map.GetBestMapForUnit = function(unit) return ({ player = 1433 })[unit] end
    ask("what now", "What to do next", { "Best zone" })
    C_Map.GetBestMapForUnit = saved
end
ask("quests here", "Quests you can pick up", { "Thork", "Horde Errand" })

-- Quest picks: XP per minute, and quests whose objectives share a spot
-- (Best quests was written before the Redridge and Darkshore quests had XP.)
local zoneXp = {}
for _, id in ipairs({ 111, 112, 113, 120, 121, 122 }) do zoneXp[id], questXp[id] = questXp[id], nil end
ask("best quests", { "Best XP per minute near you (level 20):", "Patrolling Westfall", "1050 xp", "(talk)",
    "Goretusk Liver Pie", "1200 xp", "(kill 10)", "Westfall Stew", "(loot 6)", "Red Linen Goods", "(loot 4)",
    "in your log", "Rough estimates" })
ask("which quests give the most xp", "Best XP per minute near you")
-- A level-60 quest anyone can take (event / war effort) isn't a pick at level 20
quests[105][5] = 60
ask("best quests", "Goretusk Liver Pie", { "Patrolling Westfall" })
for id, xp in pairs(zoneXp) do questXp[id] = xp end
quests[105][5] = 14
ask("quests near red linen goods", { "Quests with objectives near |cffffd100Red Linen Goods|r:", "Goretusk Liver Pie",
    "1200 xp", "from|r |cffffd100Gryan Stoutmantle", "Westfall Stew" }, { "Patrolling Westfall" })
ask("what else can i do near goretusk liver pie", { "Westfall Stew", "Red Linen Goods", "in your log" })
ask("who gives goretusk liver pie", { "Goretusk Liver Pie|r (level 16, needs 12, 1200 xp)", "Same area:", "Westfall Stew" })
ask("quests near me", "Quests you can pick up")
ask("quests near patrolling westfall", "has nothing to do out in the world")
-- Quests that take you to a zone: Scout Redridge (in your log) and a new quest handed in there
doable[1786] = true
ask("what quests take me to redridge", { "Quests that take you to |cffffd100Redridge Mountains|r (2):",
    "Scout Redridge", "in your log", "The Tome of Divinity", "hand in to |cffffd100Martie Jainrose",
    "from|r |cffffd100Gryan Stoutmantle" }, { "Redridge Goulash", "Blackrock Menace" })
doable[1786] = nil
ask("quests that take me to narnia", "None of your quests")
ask("what quests take me to redridge", { "Coming up:|r ", "Redridge Summons|r|cffaaaaaa (at 21)",
    "Redridge Orders|r|cffaaaaaa (after Lead-in Orders)" }, { "Paladin Summons", "Lead-in Orders|r|cffaaaaaa" })
-- Linen Cloth also drops from Kobold Vermin in Dun Morogh, but the nearest source is Westfall's thugs
ask("what quests take me to dun morogh", "None of your quests", { "Westfall Stew", "Red Linen Goods" })

-- Next town: zones you're not in name their town's flight path, once a flight map has
-- shown its name; "not learned" when AskBot knows your flight paths and it isn't one.
C_TaxiMap = { GetAllTaxiNodes = function()
    return { { name = "Lakeshire, Redridge", position = { x = 0.30, y = 0.60 }, state = 2 } }
end }
GetTaxiMapID = function() return 1433 end
fire("TAXIMAP_OPENED")
do
    local savedKnown = AskBotCharDB.knownTaxi
    AskBotCharDB.knownTaxi = { [4] = true, [14] = true } -- Westfall and Stormwind, not Lakeshire
    ask("where should i go at 18", { "Where to quest at level 18:",
        "Redridge Mountains|r: 1 yours + 2 new", ", FP |cffffd100Lakeshire|r|cffaaaaaa (not learned)" },
        { "Westfall|r, " })
    AskBotCharDB.knownTaxi = savedKnown
end

-- Quest log tidy-up and the hand-in route, with a bigger quest log: 100 (complete, tagged
-- elite), 103 (level 10: grey), 104 (complete: hand in at Martie in Redridge) and 125
-- (complete: hand in on Teldrassil, two boats away).
do
    local savedInfo, savedNum = C_QuestLog.GetInfo, C_QuestLog.GetNumQuestLogEntries
    local log = { { questID = 100, title = "The Defias Brotherhood" }, { questID = 103, title = "Red Linen Goods" },
        { questID = 104, title = "Scout Redridge" }, { questID = 125, title = "Far Errand" } }
    C_QuestLog.GetInfo = function(i) return log[i] end
    C_QuestLog.GetNumQuestLogEntries = function() return #log end
    C_QuestLog.GetQuestTagInfo = function(id) return id == 100 and { tagID = 1, tagName = "Elite" } or nil end
    questLog[104].complete, questLog[125] = true, { complete = true, objectives = {} }

    ask("which quests should i abandon", { "Quest log: 4 of 20. Could drop:", "Grey (little XP): ", "Red Linen Goods",
        "Need a group: ", "The Defias Brotherhood|r|cffaaaaaa (elite)", "Far away: ", "Far Errand|r|cffaaaaaa (Teldrassil" },
        { "Scout Redridge" })
    local from = #output + 1
    ask("hand in route", { "Hand-in route (3 quests, ", "1. |cffffd100Gryan Stoutmantle|r, 68 yds",
        "2. |cffffd100Martie Jainrose|r", "3. |cffffd100Jannok Breezesong|r", "by boat" })
    ask("turn in bounty on murlocs", "Bounty on Murlocs", { "Hand-in route" }) -- still a quest question
    ask("what now", "[+2 more]")

    questLog[104].complete, questLog[125] = false, nil
    C_QuestLog.GetInfo, C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetQuestTagInfo = savedInfo, savedNum, nil
end
ask("tidy quest log", { "Quest log: 3 of 20. Could drop:", "Grey (little XP): " }, { "Need a group", "Far away" })
ask("zones for level 14", { "Where to quest at level 14:", "Westfall|r: 2 yours + 3 new, lvl 10-18, 6000 xp" },
    { "Too Easy" })
ask("which region should i level in now", { "Where to quest at level 20:", "Redridge Mountains|r: 1 yours + 3 new" })
ask("best place to level", "Where to quest at level 20:")
-- Travel to a zone: its flight master, else inn, else a quest giver there
ask("quickest route to redridge", { "Quickest way to |cffffd100Redridge Mountains|r, ",
    "fly Westfall > Redridge Mountains - |cffffd100Ariena Stormfeather" }, { "Where to quest" })
ask("how do i get to darkshore", { "Quickest way to |cffffd100Darkshore|r", "boat" })
ask("route to hand in", "Hand-in route", { "Quickest way" })
ask("how do i get to the defias brotherhood", "Defias Brotherhood", { "Quickest way" })
ask("where should i quest next?", { "Where to quest at level 20:", "Redridge Mountains", "Quests you can pick up",
    "Wanted Poster" })
ask("dungeons", { "Dungeons for level 20:", "The Deadmines|r (10-26)", "[loot]", "entrance Westfall 42.6, 71.8" },
    { "Blackrock Depths" })
ask("dungeons for level 55", "Blackrock Depths|r (48-60)", { "Deadmines" })

-- Dungeon prep: the Deadmines' quests for a level 20 warrior. 142 to pick up, 143 after it,
-- 144 at level 22, the warrior quest (objective inside) yes, the paladin one no.
doable[142], doable[146] = true, true
ask("what do i need before deadmines", { "The Deadmines|r (lvl 10-26): entrance 230 yds", "[loot]",
    "Pick up from |cffffd100Ander Germaine|r, ~2 min flying", "Red Silk Bandanas",
    "[20] Warrior Errand", "Later: ", "Underground Assault|r|cffaaaaaa (needs 22)",
    "Not available yet: |cff71d5ff|Haddon:askbot:" }, { "Test of Righteousness", "Bounty on Murlocs" })
ask("vc quests", "The Deadmines|r (lvl 10-26)")
ask("prep for the deadmines", "Red Silk Bandanas")
ask("what do i need before oh brother", { "Red Silk Bandanas" }, { "entrance" }) -- a quest, not the dungeon
doable[142], doable[146] = nil, nil
ask("rares near me", { "Rare mobs nearest you:", "Leprithus|r lvl 19 |cffc0c0c0(rare)", "Foreman Grills", "(rare elite)" })

-- Another continent, two boats: Westfall > Stormwind > Auberdine > Rut'theran
ask("where is jannok breezesong", { "Jannok Breezesong", "boat Stormwind Harbor > Auberdine",
    "boat Auberdine > Rut'theran Village" }, { "other continent" })

faction = "Horde"
ask("skinner please", { "Horde Skinner", "Orc Skinner|r <Skinning Trainer> - Orgrimmar", "zeppelin Grom'gol > Orgrimmar" },
    { "Helene", "other continent" })
faction = "Alliance"

-- Quest items Questie can't place, modelled as Questie has Trial of the Sea Lion: the objective
-- is the combined pendant (made at a shrine); the two halves are items the quest needs you to
-- bring. Questie links the Endurance half to the wrong lockbox (object 502, Westfall); the
-- community locations in KnownLocations.lua win. You already carry the Agility half.
questLog[124] = { complete = false, objectives = {} }
bags[15883] = 1
do
    local pins = tomtomWaypoints
    ask("[[16] Trial of the Sea Lion (124)]", { "is in progress:",
        "|cff66cc33Got|r |cffffd100Half Pendant of Aquatic Agility",
        "Collect |cffffd100Half Pendant of Aquatic Endurance|r from: |cffffd100Strange Lockbox|r - Darkshore 48.9, 11.3",
        "(community info)", "Then make |cffffd100Pendant of the Sea Lion|r at: |cffffd100Shrine of Remulos",
        "Do: |cffffd100Speak with the spirit" }, { "doesn't know where", "Westfall 17.9", "Westfall 20.0, 20.0" })
    -- The pin goes to the missing half, not the shrine (making the pendant comes later).
    if not (tomtomWaypoints == pins + 1 and lastPinTitle and lastPinTitle:find("Strange Lockbox", 1, true)) then
        failures = failures + 1; print("   !! FAIL: expected the pin on the missing half, got " .. tostring(lastPinTitle))
    end
end
bags[15883] = nil
ask("[[16] Trial of the Sea Lion (124)]", { "Collect |cffffd100Half Pendant of Aquatic Agility|r from: "
    .. "|cffffd100Strange Lockbox (underwater)|r - Westfall 17.9, 33.0" })
faction = "Horde"
ask("[[16] Trial of the Sea Lion (124)]", { "The Barrens 56.7, 8.3", "29.6, 29.5" }, { "Darkshore 48.9" })
faction = "Alliance"
ask("debug quest [[16] Trial of the Sea Lion (124)]", { "Quest 124", "collect item 15885 Pendant of the Sea Lion",
    "0 npcs, 1 objects", "bring item 15882 Half Pendant of Aquatic Endurance", "has a community location",
    "extra: Speak with the spirit, 1 spots" })
questLog[124] = nil
-- Asking about a half directly also uses the community location
ask("where can i get half pendant of aquatic endurance", { "Half Pendant of Aquatic Endurance|r is found in:",
    "Darkshore 48.9, 11.3", "(community info)" })

-- Class quests: a community step and a summoned NPC (Body and Heart), per faction
questLog[6001] = { complete = false, objectives = {} }
ask("[[10] Body and Heart (6001)]", { "Do: |cffffd100Use the Cenarion Moondust at the Moonkin Stone|r - Darkshore 43.5, 46.0",
    "Kill: |cffffd100Lunaclaw (use the moondust at the Moonkin Stone)|r - Darkshore 43.5, 46.0", "(community info)" },
    { "doesn't know where", "Barrens" })
questLog[6001] = nil
-- An item an earlier quest rewarded: who gives it (Symbol of Life)
questLog[1786] = { complete = false, objectives = {} }
ask("[[13] The Tome of Divinity (1786)]", { "Collect |cffffd100Symbol of Life|r from: |cffffd100Ander Germaine",
    "(reward for The Symbol of Life)" }, { "doesn't know where" })
bags[6866] = 1
ask("[[13] The Tome of Divinity (1786)]", { "|cff66cc33Got|r |cffffd100Symbol of Life" })
bags[6866] = nil
questLog[1786] = nil
-- Mobs inside dungeons point at the entrance
ask("where does whitestone oak lumber drop", { "Goblin Woodcarver", "in The Deadmines, entrance Westfall 42.6, 71.8" })
-- Warlock demon: summon it at the city's summoning circle (a Questie object borrowed for the quest)
questLog[1689] = { complete = false, objectives = {} }
ask("[[10] The Binding (1689)]", { "Do: |cffffd100Use the Bloodstone Choker at the summoning circle|r - Stormwind City 25.0, 77.0",
    "Kill: |cffffd100Summoned Voidwalker (at the summoning circle)|r - Stormwind City 25.0, 77.0" }, { "doesn't know where" })
questLog[1689] = nil
-- A turn-in Questie doesn't list
ask("turn in divine grace", { "Divine Grace", "High Priestess Laurena", "Stormwind City 49.5, 44.6" }, { "doesn't know where" })
-- A quest item sold by a vendor
questLog[141] = { complete = false, objectives = {} }
ask("[[12] Thread Run (141)]", { "Collect |cffffd100Coarse Thread|r from: |cffffd100Thread Seller", "(sells it)" })
questLog[141] = nil

-- Quest chains (Questie would say Part 1, Side Errand, After Done and Lead-in can be taken now)
for _, id in ipairs({ 130, 133, 136, 137 }) do doable[id] = true end
ask("what do i need before chain part 3", { "To get ", "Chain Part 3", "first:",
    "1. |cffffd100[14] Chain Part 1|r - pick up from |cffffd100Chain Giver",
    "2. |cffffd100[16] Chain Part 2|r - |cffaaaaaaafter the step above",
    "3. |cffffd100[15] Side Errand|r - pick up from", "Optional lead-in:|r |cffffd100[12] Lead-in" },
    { "Horde Version" })
ask("[[16] Chain Part 2 (131)] prereqs", { "To get ", "1. |cffffd100[14] Chain Part 1|r - pick up" }, { "Side Errand" })
ask("how do i unlock side errand", { "[15] Side Errand|r is ready to pick up from |cffffd100Chain Giver" })
ask("what comes after chain part 1", { "After ", "Chain Part 1", "Chain Part 2|r - |cffaaaaaaopens when you finish it" })
ask("what comes after done earlier", { "After ", "[13] After Done|r - pick up from |cffffd100Chain Giver" })
ask("what do i need before done earlier", "You've already done")
ask("what comes after chain part 3", "Nothing follows")
for _, id in ipairs({ 130, 133, 136, 137 }) do doable[id] = nil end

-- Without Questie: AskBot's own quest check gives the same chain answers.
Questie.started = false
ask("what do i need before chain part 3", { "1. |cffffd100[14] Chain Part 1|r - pick up from |cffffd100Chain Giver",
    "3. |cffffd100[15] Side Errand|r - pick up from" }, { "Horde Version" })
ask("what comes after done earlier", "[13] After Done|r - pick up from |cffffd100Chain Giver")
local Compat = AskBot.Compat
for id, want in pairs({ [130] = true, [131] = false, [132] = false, [135] = false, [136] = true,
    [145] = false, [146] = true }) do
    if Compat.IsDoable(id) ~= want then
        failures = failures + 1; print("   !! FAIL: own IsDoable(" .. id .. ") should be " .. tostring(want))
    end
end
if Compat.QuestXP(109) ~= 850 or Compat.UiMapIdByAreaId(W) ~= 1436 or not Compat.IsTrivial(10) or Compat.IsTrivial(15) then
    failures = failures + 1; print("   !! FAIL: Compat XP, zone map or grey quests")
end
Questie.started = true

-- Gathering
ask("where can i mine copper", { "Copper Vein|r <", "Mining 1|r> - Westfall 40.0, 50.0", "Most nodes:|r Dun Morogh 3",
    "Westfall 2 (" }, { "You need", "Westfall 3" })
if lastPinTitle ~= "Copper Vein" then
    failures = failures + 1; print("   !! FAIL: pin title " .. tostring(lastPinTitle))
end
ask("where can i get copper ore", "Copper Vein|r <")
-- A zone after the node limits it to that zone ("tin loch modan", as typed in-game).
ask("copper dun morogh", { "Copper Vein|r <", "Dun Morogh 10.0, 10.0" }, { "Westfall", "Most nodes", "Sorry" })
ask("copper in westfall", { "Copper Vein|r <", "- Westfall 40.0, 50.0" }, { "Dun Morogh" })
ask("where can i mine tin in redridge", { "Tin Vein|r <", "Redridge Mountains 50.0, 50.0" })
ask("copper ore westfall", "Westfall 40.0, 50.0", { "Dun Morogh" })
ask("tin westfall", "Questie has no |cffffd100Tin Vein|r spawn points in Westfall.", { "Redridge" })
ask("copper nodes", "Copper Vein|r <")
ask("where to mine silver", { "Silver Vein|r <", "You need Mining 75 (you have 70)" })
ask("peacebloom", { "Peacebloom|r <", "Herbalism 1", "You don't have Herbalism." }, { "Most nodes" })
ask("where can i find peacebloom", "Peacebloom|r <")
ask("where should i mine", { "Mining 70: best for skill-ups", "(Silver Vein at 75)", "Tin Vein|r <" }, { "Copper Vein|r <" })
ask("where should i level herbalism", { "You don't have Herbalism yet. Starter nodes:", "Peacebloom|r <" },
    { "You don't have Herbalism.", "zone" })
ask("where are cold iron deposit nodes", { "Cold Iron Deposit|r <Mining> - Redridge" })
ask("where can i get linen cloth", "Linen Cloth", { "Vein", "Peacebloom" })

-- Gear upgrades -----------------------------------------------------------------------------
-- You wear weak legs, an old tunic and a 1H mace; no rings or cloak. Talents: Arms (11/0/0).
-- The quest reward legs aren't in the item cache yet, so the answer waits for the server.
ask("upgrades", { "Checking 1 items" }, { "Upgrades for" })
gear[9001][8] = true
do
    local from = #output + 1
    fire("GET_ITEM_INFO_RECEIVED", 9001, true)
    local text = withPlainQuestLinks(table.concat(output, "\n", from))
    for _, e in ipairs({ "Upgrades for Arms Warrior, level 20:", "Legs: ", "Militia Leggings", "+514%",
        "quest |cffffd100Blackrock Menace|r, from Martie Jainrose (Redridge Mountains",
        "Two-hander: ", "Rockslicer", "(train Two-Handed Axes)", "[weapon master]",
        "Chest: ", "Blackened Defias Armor", "(at 21)", "The Deadmines",
        "Back: ", "Cape of the Brotherhood", "empty slot", "Edwin VanCleef|r |cff66cc3323%",
        "Ring: ", "Silver Ring", "AH ",
        "Best dungeon:|r |cffffd100The Deadmines|r lvl 10-26: 3 upgrades (" }) do
        if not text:find(e, 1, true) then failures = failures + 1; print("   !! FAIL: expected " .. e) end
    end
    for _, r in ipairs({ "Apprentice Wand", "Guessing", "Checking" }) do
        if text:find(r, 1, true) then failures = failures + 1; print("   !! FAIL: did not expect " .. r) end
    end
end
if lastPinTitle ~= "Martie Jainrose (upgrade)" then failures = failures + 1; print("   !! FAIL: pinned " .. tostring(lastPinTitle)) end
ask("upgrades legs", { "(legs)", "Militia Leggings" }, { "Rockslicer", "Silver Ring" })
-- Only gear you can use within two levels: the same chest needing level 23 is left out
gear[10399][5] = 23
ask("upgrades chest", "Upgrades for", { "Blackened Defias Armor" })
gear[10399][5] = 21
-- Dungeon drops only, with the dungeons ranked
ask("what boss drops are good for me?", { "Upgrades from dungeons for Arms Warrior", "Chest: ", "Blackened Defias Armor",
    "Back: ", "Two-hander: ", "By dungeon:", "The Deadmines|r lvl 10-26: 3 upgrades (" },
    { "Silver Ring", "Militia", "Market Tunic", "Sorry" })
ask("upgrades from quests", { "Upgrades from quests for", "Militia Leggings" }, { "Rockslicer", "Silver Ring" })
ask("what does vancleef drop", "Edwin VanCleef", { "Upgrades" })
ask("better weapon", { "Two-hander: ", "Rockslicer" }, { "Militia" })
-- A weapon type: Rockslicer is an axe, not a dagger.
ask("upgrade axes", { "(axes)", "Rockslicer" }, { "Militia" })
ask("upgrade daggers", { "Upgrades for Arms Warrior (daggers)", "Nothing better" }, { "Rockslicer" })
ask("upgrades as tank", { "Upgrades for Protection Warrior" }, { "Guessing" })
talents = { 0, 0, 0 }
ask("what gear should i get", { "Upgrades for Arms Warrior", "Guessing Arms (no talent points spent yet)",
    "/ab upgrades as fury, prot" })
talents = { 11, 0, 0 }
ask("debug item 9001", { "slot legs", "needs level 18", "ITEM_MOD_STRENGTH_SHORT=5", "score for Arms: 8.6" })
ask("nearest weapon master", "Weapon Master", { "Upgrades for" })
ask("nearest weapon master", { "Woo Ping", "(Crossbows, Daggers, Polearms, Staves, Swords, 2H Swords)" }, { "Hanashi" })
ask("what weapon master teaches bow", { "Nearest Weapon Master for Bows:", "Ilyenia Moonfire" }, { "Woo Ping", "Hanashi", "Crossbows" })
ask("where can i learn two handed swords", { "Weapon Master for Two-Handed Swords:", "Woo Ping" }, { "Ilyenia" })
ask("who teaches swords", { "Weapon Master for Swords", "(you already know it)", "Woo Ping" })
ask("where do i train wands", "No one teaches Wands")
ask("weapon master for guns", { "I don't know a Weapon Master friendly to you who teaches Guns",
    "Not known yet: Ember Bladewhisper" })
ask("when do i learn hammer of wrath", nil, { "Weapon Master" })

-- One item against what you wear
local function link(id) return "|cff1eff00|Hitem:" .. id .. "::|h[" .. gear[id][1] .. "]|h|r" end
ask("is " .. link(9001) .. " an upgrade?", { "[Militia Leggings]|h|r (Legs): ", "upgrade|r, +514% over",
    "[Worn Leggings]", "for Arms Warrior." }, { "not an upgrade", "drops from" })
ask("is militia leggings an upgrade", { "(Legs): ", "upgrade|r, +514%" })
ask("is " .. link(9012) .. " better as tank", { "(Weapon): you're wearing it." })
ask(link(9021) .. " upgrade?", { "(Head): ", "upgrade|r for Arms Warrior, fills an empty slot.", "(Plate Mail at 40)" }, { "(at 40)" })
ask("should i use " .. link(9005), "[Apprentice Wand]|h|r: Warriors can't use Wands.")
-- A bare shift-clicked piece of gear: where it comes from, then the verdict
ask(link(872), { "Rockslicer", "  |cff1eff00|Hitem:872::|h[Rockslicer]|h|r (Two-hander): ", "(train Two-Handed Axes)" })
-- "Equip:" bonuses the game's stat list leaves out are read from the tooltip
ask("debug item 9022", { "stats: none reported", "from Equip: lines: SP=7" })
ask("is " .. link(9022) .. " an upgrade as healer", "not an upgrade for Arms Warrior")  -- no healer spec: talents decide
-- "/ab target"
ask("target", "Target something first")

-- Class training ---------------------------------------------------------------------------
-- Ander Germaine's window (Warrior Trainer, NPC 6): two spells learned, two ready at 20, two later
ask("what skills can i learn", { "Open your class trainer once", "Warrior trainer: ", "Ander Germaine" })
local trainerList = {
    { "Arms", nil, "header", true },
    { "Rend", "Rank 3", "available", nil, 20, 1800 },
    { "Hamstring", "Rank 1", "available", nil, 8, 200 },
    { "Rend", "Rank 4", "unavailable", nil, 30, 6000 },
    { "Mocking Blow", "Rank 2", "unavailable", nil, 30, 6000 },
    { "Overpower", "Rank 2", "unavailable", nil, 28, 5000 },
}
local realGuid = UnitGUID
function IsTradeskillTrainer() return false end
function GetNumTrainerServices() return #trainerList end
function GetTrainerServiceInfo(i) local s = trainerList[i]; return s[1], s[2], s[3], s[4] end
function GetTrainerServiceLevelReq(i) return trainerList[i][5] end
function GetTrainerServiceCost(i) return trainerList[i][6] end
function GetTrainerServiceTypeFilter(kind) return kind ~= "used" end
UnitGUID = function(u) if u == "npc" then return "Creature-0-1-1-1-6-0000" end return realGuid(u) end
fire("TRAINER_SHOW")
advance(1)
ask("what skills can i learn right now", { "Ready to train (2): |cffffd100Hamstring|r 1, |cffffd100Rend|r 3", " - 20s",
    "Warrior trainer: |cffffd100Ander Germaine", "Next at level 28:|r |cffffd100Overpower|r 2" }, { "Rank 4", "Mocking" })
-- Hamstring learned: it leaves the list
table.remove(trainerList, 3)
fire("TRAINER_UPDATE")
advance(1)
ask("what can i train", { "Ready to train (1): |cffffd100Rend|r 3", " - 18s" }, { "Hamstring" })
-- A profession or service named means that, not class spells
ask("where can i learn skinning skills", "Skinning trainer", { "Ready to train" })
-- A pet trainer's window isn't recorded
UnitGUID = function(u) if u == "npc" then return "Creature-0-1-1-1-3-0000" end return realGuid(u) end
trainerList = { { "Growl", "Rank 2", "available", nil, 10, 100 } }
fire("TRAINER_SHOW")
advance(1)
ask("spells i can learn", "Ready to train (1): |cffffd100Rend|r 3", { "Growl" })
ask("skills available", "Ready to train (1): |cffffd100Rend|r 3")
ask("available spells", "Ready to train (1): |cffffd100Rend|r 3")
-- Forever's rows: name, type, no rank. Each rank of a spell is its own entry (by level), and
-- an old list that stored the type as the rank is dropped.
AskBotCharDB.training.spells["Heroic Strike|unavailable"] = { name = "Heroic Strike", rank = "unavailable", level = 56 }
UnitGUID = function(u) if u == "npc" then return "Creature-0-1-1-1-6-0000" end return realGuid(u) end
trainerList = {
    { "Heroic Strike", "available", nil, nil, 8, 60 },
    { "Hamstring", "available", nil, nil, 8, 100 },
    { "Heroic Strike", "unavailable", nil, nil, 24, 1000 },
    { "Heroic Strike", "unavailable", nil, nil, 56, 42000 },
}
GetTrainerServiceInfo = function(i) local s = trainerList[i]; return s[1], s[2], s[3], s[4] end
fire("TRAINER_SHOW")
advance(1)
ask("what skills can i learn", { "Ready to train (2): |cffffd100Hamstring|r, |cffffd100Heroic Strike|r", " - 1s 60c",
    "Next at level 24:|r |cffffd100Heroic Strike" }, { "Rend", "unavailable", "56" })
-- A weapon master's window (Forever rows: name, type) is remembered account-wide.
UnitGUID = function(u) if u == "npc" then return "Creature-0-1-1-1-260080-0000" end return realGuid(u) end
trainerList = { { "Guns", "available", nil, nil, 1, 1000 }, { "One-Handed Maces", "unavailable", nil, nil, 1, 1000 } }
fire("TRAINER_SHOW")
advance(1)
ask("weapon master for guns", { "Weapon Master for Guns:", "Ember Bladewhisper" }, { "Not known yet" })
ask("nearest weapon master", "Guns, Maces")
-- ...and what it offers your class counts as usable gear, even against Classic's rules.
if not (AskBotDB.classWeapons and AskBotDB.classWeapons.WARRIOR and AskBotDB.classWeapons.WARRIOR.Guns) then
    failures = failures + 1; print("   !! FAIL: weapon master's skills not recorded for the class")
end
do
    gear[9198] = { "Test Wand", "INVTYPE_RANGEDRIGHT", 2, 19, 5, 8, { ITEM_MOD_DAMAGE_PER_SECOND_SHORT = 2 }, true }
    local g1, _, _, cannot = AskBot.Gear.Check(9198, "WARRIOR", 20, AskBot.Gear.Skills(), true)
    AskBotDB.classWeapons.WARRIOR.Wands = true
    local g2, _, needs = AskBot.Gear.Check(9198, "WARRIOR", 20, AskBot.Gear.Skills(), true)
    AskBotDB.classWeapons.WARRIOR.Wands = nil
    if g1 or cannot ~= "Wands" or g2 ~= "ranged" or needs ~= "train Wands" then
        failures = failures + 1; print("   !! FAIL: class-learnable weapon check: " .. tostring(g1) .. " " .. tostring(cannot) .. " " .. tostring(g2) .. " " .. tostring(needs))
    end
    gear[9198] = nil
end
UnitGUID = realGuid
GetNumTrainerServices = nil

-- Professions -------------------------------------------------------------------------------
-- Your Tailoring window (75/75): pants are orange, the bag yellow, bolts grey.
for id, name in pairs({ [2996] = "Bolt of Linen Cloth", [4238] = "Linen Bag", [4343] = "Brown Linen Pants",
    [2320] = "Coarse Thread" }) do
    itemCache[id] = name
end
local function il(id) return "|cffffffff|Hitem:" .. id .. "::|h[" .. itemCache[id] .. "]|h|r" end
local tradeSkills = {
    { "Pants", "header" },
    { "Brown Linen Pants", "optimal", 4343, { { 2996, 2 }, { 2320, 1 } } },
    { "Linen Bag", "medium", 4238, { { 2996, 3 }, { 2320, 3 } } },
    { "Bolt of Linen Cloth", "trivial", 2996, { { 2589, 2 } } },
}
function GetTradeSkillLine() return "Tailoring", 75, 75 end
function GetNumTradeSkills() return #tradeSkills end
function GetTradeSkillInfo(i) return tradeSkills[i][1], tradeSkills[i][2] end
function GetTradeSkillItemLink(i) return tradeSkills[i][3] and il(tradeSkills[i][3]) end
function GetTradeSkillNumMade() return 1, 1 end
function GetTradeSkillNumReagents(i) return #(tradeSkills[i][4] or {}) end
function GetTradeSkillReagentInfo(i, j) local r = tradeSkills[i][4][j]; return itemCache[r[1]], "icon", r[2], bags[r[1]] or 0 end
function GetTradeSkillReagentItemLink(i, j) return il(tradeSkills[i][4][j][1]) end
ahPrices[2996], ahAges[2996] = 400, 0
ahPrices[4238], ahAges[4238] = 5000, 0
bags[2996] = 1
ask("mats for linen bag", "Open your profession window once")
fire("TRADE_SKILL_SHOW")
advance(1)
-- What vendors charge: Auctionator's "vendor price" is what a vendor pays you, so AskBot records
-- merchants' prices itself. Before a visit: ~4x what a vendor pays (2c) for an item Questie lists
-- a vendor for; afterwards the merchant's price for one (5 for 50c), token items left out.
do
    local realInfo = C_Item.GetItemInfo
    C_Item.GetItemInfo = function(id)
        if id == 2320 then return "Coarse Thread", il(2320), 1, 5, 0, "Trade Goods", "Cloth", 20, "", 0, 2 end
        return realInfo(id)
    end
    ask("price of " .. il(2320), "vendors sell it for ~8c", { "vendors sell it for 10c" })
    local goods = { { 2320, 50, 5 }, { 2589, 0, 1, true } }
    function GetMerchantNumItems() return #goods end
    function GetMerchantItemID(i) return goods[i][1] end
    function GetMerchantItemInfo(i) local g = goods[i]; return itemCache[g[1]], "icon", g[2], g[3], -1, true, true, g[4] end
    AskBot.Prices.RecordMerchant()
    assert(AskBotDB.vendorPrices[2320] == 10 and AskBotDB.vendorPrices[2589] == nil, "merchant prices recorded")
    ask("price of " .. il(2320), "vendors sell it for 10c", { "~" })
    C_Item.GetItemInfo = realInfo
end
ask("mats for 2 linen bag", { "[Linen Bag]|r x2 (Tailoring):", "  6 |cffffffff[Bolt of Linen Cloth]|r: have 1, buy 5",
    "(AH 4s each)", "  6 |cffffffff[Coarse Thread]|r: buy 6", "(vendor 10c each)", "To buy: 20s 60c",
    "sells for 50s each, so crafting saves 37s 70c each" })
ask("what do i need to make brown linen pants", { "Brown Linen Pants", "have 1, buy 1" })
-- A recipe shift-clicked from the profession window: mats, cost and profit.
local craftLink = "|cffffd000|Henchant:3755|h[Tailoring: Linen Bag]|h|r"
ask(craftLink, { "[Linen Bag]|r (Tailoring):", "have 1, buy 2", "sells for 50s each, so crafting saves" })
ask(craftLink .. " x2", { "[Linen Bag]|r x2 (Tailoring):", "have 1, buy 5" })
ask(craftLink .. " from scratch", { "buying everything", "[Bolt of Linen Cloth]|r: buy 3" }, { "have 1" })
ask("[Tailoring: Linen Bag]", "[Linen Bag]|r (Tailoring):")
ask("recipe " .. craftLink, { "You already know", "(Tailoring)" })
-- Holding every mat still shows the profit.
bags[2996], bags[2320] = 3, 3
ask(craftLink, { "You have everything for 1. Mats worth 12s 30c each. On the AH it sells for 50s each, so crafting saves 37s 70c each." })
bags[2996], bags[2320] = 1, nil
ask("cost to craft " .. il(4238), { "[Linen Bag]|r", "To buy: ", "sells for 50s each" })
ask("how much does it cost to craft linen bag", { "[Linen Bag]|r", "To buy: " })
-- "from scratch": the bolt in your bags is bought too (3 x 4s + 3 x 10c).
ask("cost to craft " .. il(4238) .. " from scratch", { "buying everything", "[Bolt of Linen Cloth]|r: buy 3", "To buy: 12s 30c" },
    { "have 1" })
ask("mats for 2 linen bag ignoring bags", { "[Linen Bag]|r x2 (Tailoring):", "buy 6", "To buy: 24s 60c" })
ask("how do i level tailoring", { "Tailoring 75/75: cheapest skill-ups", "at your cap", "[Tailoring trainer]",
    "Brown Linen Pants]|r |cffff8040orange|r - mats 7s 90c", "Linen Bag]|r |cffffff00yellow|r - mats 12s 10c", "[list]" },
    { "Bolt of Linen Cloth]|r |c" })
-- A profession link with words around it ("cheapest leveling [Blacksmithing (Apprentice)]")
ask("cheapest leveling |cffffd000|Htrade:Player-1:2018:164|h[Tailoring (Apprentice)]|h|r", "Tailoring 75/75: cheapest skill-ups",
    { "Nearest" })
ask("cheapest tailoring levelling", "Tailoring 75/75: cheapest skill-ups")
ask("cheapest levling |cffffd000|Htrade:Player-1:2018:164|h[Tailoring]|h|r", "Tailoring 75/75: cheapest skill-ups")
ask("lvl tailoring", "Tailoring 75/75: cheapest skill-ups")
ask("plan |cffffd000|Htrade:Player-1:2018:164|h[Tailoring]|h|r", "Tailoring 75/75: cheapest skill-ups")
ask("plan for tailoring", "Tailoring 75/75: cheapest skill-ups")
ask("plans for red linen bag", "Pattern: Red Linen Bag", { "cheapest skill-ups" })
ask("cheapest tailoring", "Tailoring 75/75: cheapest skill-ups")
ask("cheapest way to level tailoring", "Tailoring 75/75: cheapest skill-ups")
-- For profit: the bag sells for 47s 50c after the cut, mats 12s 30c bought; bolts need unpriced cloth.
ask("|cffffd000|Htrade:Player-1:2018:164|h[Tailoring]|h|r for profit", { "Tailoring 75: most profitable crafts",
    "[Linen Bag]|r |cff40ff40+35s 20c|r", "(sells 47s 50c, mats 12s 30c)", "|cffffff00(skill-up)", "[list]",
    "no price for the item or a mat" }, { "cheapest skill-ups", "Bolt of Linen Cloth]|r |c" })
ask("most profitable tailoring", "Tailoring 75: most profitable crafts")
-- AHDB's history: the bag usually sells for 20s, so the 50s listing is a spike. Selling is valued
-- at the lower price (19s after the cut); buying mats still uses the live price.
GetServerTime = os.time
AuctionDB = { PlayerHouse = function() return "Alliance" end,
    Typical = function(_, id, house, days)
        assert(house == "Alliance" and days == 30)
        if id == 4238 then return 2000, 2600, 10 end
        if id == 2589 then return 500, 600, 2 end   -- too few days to trust
        if id == 2996 then return 200, 250, 10 end  -- the bolts are usually 2s: 4s now is a spike
        return 0, 0, 0
    end,
    -- last scan {ts, min, median, listed}: one bag up (one seller sets its price), plenty of cloth
    LastPrice = function(_, id)
        if id == 4238 then return { GetServerTime() - 3600, 5000, 5000, 1 } end
        if id == 2589 then return { GetServerTime() - 3600, 900, 1000, 40 } end
        if id == 2996 then return { GetServerTime() - 5 * 86400, 400, 400, 1 } end   -- too old to count
    end }
ask("tailoring for profit", { "[Linen Bag]|r |cff40ff40+6s 70c|r", "mats 12s 30c)|r |cffff8040only 1 listed|r" },
    { "+35s 20c" })
ask("mats for linen bag", { "sells for 20s each", "(usual price; listed at 50s now)|r |cffff8040only 1 listed|r",
    "(AH 4s each)|r |cffff8040usually 2s|r" }, { "Thread]|r: buy 3 (vendor 10c each)|r |cffff8040" })
ask("price of " .. il(4238), { "AH 50s", "only 1 listed", "usually 20s", "(10 days)" })
ask("price of linen cloth", { "seen today", "40 listed" }, { "usually", "only" })
ask("price of " .. il(2996), "AH 4s", { "listed" })
-- Only today's scans so far (AHDB's Typical has 1 day): the median of the scans' lowest buyouts
-- stands in. The bag's swung 50s -> 20s between scans: valued at 22s and flagged unstable.
do
    local now = GetServerTime()
    local function scans(...)
        local list = {}
        for i, min in ipairs({ ... }) do list[i] = { now - (4 - i) * 1200, min, min, 10 } end
        return list
    end
    AuctionDB = { PlayerHouse = function() return "Alliance" end,
        Typical = function() return 0, 0, 1 end,
        RecentHistory = function(_, id, house)
            assert(house == "Alliance")
            if id == 4238 then return scans(5000, 2000, 2200) end
            if id == 2589 then return scans(900, 880, 850) end
            if id == 2996 then return scans(400, 390) end    -- too few scans to go on
            return {}
        end }
    ask("tailoring for profit", { "[Linen Bag]|r |cff40ff40+8s 60c|r", "|cffff8040price unstable|r" }, { "+35s 20c" })
    ask("mats for linen bag", { "sells for 22s each", "(usual price; listed at 50s now)|r |cffff8040price unstable|r" })
    ask("price of " .. il(4238), { "AH 50s", "price unstable", "usually 22s", "(3 scans)" })
    ask("price of linen cloth", { "usually 8s 80c", "(3 scans)" }, { "unstable" })
    ask("price of " .. il(2996), "AH 4s", { "usually", "unstable" })
end
AuctionDB, GetServerTime = nil, nil
ask("nearest tailoring trainer for levelling up", "Tailoring trainer", { "cheapest skill-ups" })
ask("recipe for red linen bag", { "Pattern: Red Linen Bag", "Thread Seller" })
ask("recipe for linen bag", { "You already know", "(Tailoring)", "[mats]" })
ask("how do i learn flying carpet", "No pattern, plan or recipe item teaches \"flying carpet\"")
ask("mats for flying carpet", "None of your recipes makes \"flying carpet\"")
ask("how do i level mining", "Mining 70: best for skill-ups")
ask("skinning skill ups", "You don't have Skinning")
ask("who teaches skinning", "Helene Peltskinner", { "No pattern" })
ask("debug skills", { "GetSkillLineInfo yes", "Skills seen: Mining 70, Fishing 20", "Recipes read: Tailoring 75/75 (3 recipes)" })
-- Without the classic skill list: modern GetProfessions, or an honest "can't read it"
do
    local getInfo, getNum = GetSkillLineInfo, GetNumSkillLines
    GetSkillLineInfo, GetNumSkillLines = nil, nil
    ask("how do i level skinning", "I can't read your Skinning skill here", { "You don't have" })
    function GetProfessions() return 1, nil, nil, nil, nil end
    function GetProfessionInfo(i) return "Skinning", "icon", 60, 75 end
    ask("how do i level skinning", { "Skinning 60: you can skin beasts up to level 16. Most skill-ups from level 12-16:",
        "1. |cffffd100Westfall|r: Coyote - ", "2. |cffffd100Redridge Mountains|r: Black Bear" }, { "Pathstalker", "Elder Wolf" })
    GetProfessions, GetProfessionInfo = nil, nil
    GetSkillLineInfo, GetNumSkillLines = getInfo, getNum
end
-- AtlasLoot's crafting data: every recipe, known or not
for id, name in pairs({ [2302] = "Handstitched Leather Boots", [2303] = "Handstitched Leather Pants",
    [2307] = "Fine Leather Boots", [2309] = "Embossed Leather Boots", [2318] = "Light Leather" }) do
    itemCache[id] = name
end
if AskBot.Crafts.status ~= "ready" then failures = failures + 1; print("   !! FAIL: crafts " .. AskBot.Crafts.status) end
skillLines[#skillLines + 1] = { "Leatherworking", false, 35 }
ask("how do i level leatherworking", { "Leatherworking 35: cheapest skill-ups:",
    "[Handstitched Leather Boots]|r |cffff8040orange|r - mats 10c+ learn: ", "[Leatherworking trainer]",
    "[Handstitched Leather Pants]|r |cffff8040orange|r", "New trainer recipes at 55." }, { "Fine Leather Boots", "Embossed" })
-- A profession trainer window: training costs join the ranking (Pants 50c beats Boots 5s).
do
    local tsList = { { "Leatherworking", "header", true }, { "Handstitched Leather Boots", "available", 500 },
        { "Handstitched Leather Pants", "available", 50 }, { "Embossed Leather Boots", "unavailable", 300, 55 } }
    local saved = { IsTradeskillTrainer, GetNumTrainerServices, GetTrainerServiceInfo, GetTrainerServiceCost }
    function GetTrainerServiceSkillReq(i) return "Leatherworking", tsList[i][4] or 0, true end
    function IsTradeskillTrainer() return true end
    function GetNumTrainerServices() return #tsList end
    function GetTrainerServiceInfo(i) return tsList[i][1], tsList[i][2] end
    function GetTrainerServiceCost(i) return tsList[i][3] end
    fire("TRAINER_SHOW")
    advance(1)
    IsTradeskillTrainer, GetNumTrainerServices, GetTrainerServiceInfo, GetTrainerServiceCost = saved[1], saved[2], saved[3], saved[4]
    GetTrainerServiceSkillReq = nil
    if AskBotDB.recipeTrainingLevel[AskBot.Data.NameKey("Embossed Leather Boots")] ~= 55 then
        failures = failures + 1; print("   !! FAIL: trainer skill level not recorded")
    end
    ask("how do i level leatherworking", { "[Handstitched Leather Pants]|r |cffff8040orange|r - mats 10c+ learn: ",
        " 50c ", " 5s " })
    -- Orange only wins when it's no dearer per point: at 42 the Boots are yellow (93%) but free
    -- to train, the orange Pants cost 50s to train (~1s 50c a point over the 33 points left).
    local lw = skillLines[#skillLines]
    lw[3] = 42
    AskBotDB.recipeTraining[AskBot.Data.NameKey("Handstitched Leather Boots")] = 0
    AskBotDB.recipeTraining[AskBot.Data.NameKey("Handstitched Leather Pants")] = 5000
    ask("how do i level leatherworking", { "Leatherworking 42: cheapest skill-ups:",
        "[Handstitched Leather Boots]|r |cffffff00yellow|r", " ~93%|r - mats 10c+ learn: ", " free ",
        "[Handstitched Leather Pants]|r |cffff8040orange|r - mats 10c+ learn: ", " 50s " })
    lw[3] = 35
    -- A plan to your cap: priced Light Leather (1s on the AH), 40 in your bags.
    ahPrices[2318], ahAges[2318] = 100, 0
    bags[2318] = 40
    AskBotCharDB.professions.Leatherworking = { rank = 35, max = 75, recipes = {} }
    ask("how do i level leatherworking", { "Plan to 75", " crafts, ~", "Buy: " })
    -- For profit with AtlasLoot: Boots a trainer teaches sell for 19s after the cut, mats 2s 10c.
    ahPrices[2302], ahAges[2302] = 2000, 0
    ask("leatherworking for profit", { "Leatherworking 35: most profitable crafts",
        "[Handstitched Leather Boots]|r |cff40ff40+16s 90c|r", "(sells 19s, mats 2s 10c)", "learn: " },
        { "Fine Leather Boots", "Open your Leatherworking trainer" })
    -- Levelling with profit: sales come off each craft's cost, and the plan says what they bring.
    ask("level leatherworking with profit", { "Leatherworking 35/75: cheapest skill-ups", "counting what you can sell them for",
        "[Handstitched Leather Boots]|r |cffff8040orange|r - mats 2s, sells 19s |cff40ff40(+17s)|r",
        "sell what you make for ~" }, { "for profit" })
    ask("|cffffd000|Htrade:Player-1:2018:165|h[Leatherworking]|h|r skill ups profitably", "counting what you can sell them for")
    ask("how do i level leatherworking", "Leatherworking 35/75: cheapest skill-ups", { "counting what", "sells 19s" })
    -- Levelling by vendoring: only what vendors pay counts (Boots 25c, Pants 3s), so the Pants
    -- (mats 3s 90c, free to train here) now beat the Boots (mats 2s) that win on AH prices.
    local pantsKey = AskBot.Data.NameKey("Handstitched Leather Pants")
    local pantsTraining = AskBotDB.recipeTraining[pantsKey]
    AskBotDB.recipeTraining[pantsKey] = 0
    local itemInfo = C_Item.GetItemInfo
    local vendorPays = { [2302] = 25, [2303] = 300 }
    C_Item.GetItemInfo = function(id)
        if vendorPays[id] then return itemCache[id], nil, 1, 10, 5, "Armor", "Leather", 1, "", 0, vendorPays[id] end
        return itemInfo(id)
    end
    local vendorText = ask("level leatherworking vendor", { "Leatherworking 35/75: cheapest skill-ups",
        "(vendoring what you make; AH mats at their usual price)", "vendors 3s", "vendors 25c",
        "back from vendors, ~", " net", "35-60 |cffffffff[Handstitched Leather Pants]|r x31" },
        { "sells 19s", "sell what you make for" })
    if not (vendorText:find("Pants]", 1, true) < vendorText:find("Boots]", 1, true)) then
        failures = failures + 1; print("   !! FAIL: vendoring should rank the Pants first")
    end
    ask("how do i level leatherworking and vendor everything", "(vendoring what you make")
    -- With AHDB history, AH mats count at their usual price (Light Leather 2s, not 1s today).
    AuctionDB = { PlayerHouse = function() return "Alliance" end,
        Typical = function(_, id) if id == 2318 then return 200, 250, 5 end return 0, 0, 0 end }
    ask("level leatherworking vendor", "[Handstitched Leather Boots]|r |cffff8040orange|r - mats 3s 90c, vendors 25c")
    ask("level leatherworking with profit", "[Handstitched Leather Boots]|r |cffff8040orange|r - mats 2s, sells")
    AuctionDB = nil
    ask("leatherworking vendor", nil, { "cheapest skill-ups" })
    C_Item.GetItemInfo = itemInfo
    AskBotDB.recipeTraining[pantsKey] = pantsTraining
    -- Embossed Leather Boots with no recipe item and not on your trainer's list (Forever's
    -- Sterling Silver Boots): left out of profit and skill-ups even when you could make them.
    ahPrices[2309], ahAges[2309] = 9000, 0
    local lw = skillLines[#skillLines]
    lw[3] = 60
    local embossed = AskBot.Data.NameKey("Embossed Leather Boots")
    local embossedCost = AskBotDB.recipeTraining[embossed]
    ask("leatherworking for profit", "[Embossed Leather Boots]")
    AskBotDB.recipeTraining[embossed] = nil
    ask("leatherworking for profit", "Handstitched Leather Boots", { "Embossed" })
    ask("how do i level leatherworking", "Leatherworking 60/75: cheapest skill-ups", { "Embossed" })
    AskBotDB.recipeTraining[embossed] = embossedCost
    -- Before any trainer window: assumed taught, with a nudge to open the trainer.
    local savedCosts = AskBotDB.recipeTraining
    AskBotDB.recipeTraining = nil
    ask("leatherworking for profit", { "Embossed Leather Boots", "Open your Leatherworking trainer once" })
    AskBotDB.recipeTraining = savedCosts
    -- Your trainer teaches Embossed at 30, not AtlasLoot's 55 (Forever's Heavy Grinding Stone:
    -- 100, not 125): learnable at 35, orange with the colours moved down too.
    lw[3] = 35
    AskBotDB.recipeTrainingLevel[embossed] = 30
    ask("leatherworking for profit", "[Embossed Leather Boots]|r |cff40ff40+79s 50c|r")
    ask("how do i level leatherworking", "[Embossed Leather Boots]|r |cffff8040orange|r")
    AskBotDB.recipeTrainingLevel[embossed] = 55
    lw[3] = 35
    ahPrices[2302], ahPrices[2309] = nil, nil
    -- More than the plan uses: the rest is worth selling (1s less the 5% cut each).
    bags[2318] = 200
    ask("how do i level leatherworking", { "Not needed, sell for ~27s 55c:", "29 |cffffffff[Light Leather]" }, { "Buy: 1" })
    -- Your window beats AtlasLoot: it showed the Boots green at 35 (AtlasLoot: orange), so they're
    -- out; it showed the Pants yellow (AtlasLoot: orange), so they show a chance with no "~".
    local NK = AskBot.Data.NameKey
    AskBotCharDB.professions.Leatherworking = { rank = 35, max = 75, recipes = {
        [NK("Handstitched Leather Boots")] = { name = "Handstitched Leather Boots", diff = "easy", reagents = {} },
        [NK("Handstitched Leather Pants")] = { name = "Handstitched Leather Pants", diff = "medium", reagents = {} } } }
    ask("how do i level leatherworking", { "[Handstitched Leather Pants]|r |cffffff00yellow|r|cffaaaaaa ~100%" },
        { "Handstitched Leather Boots]|r |c" })
    AskBotCharDB.professions.Leatherworking = nil
    bags[2318] = nil
end
ask("recipe for fine leather boots", { "[Fine Leather Boots]|r (Leatherworking 90): learn it from",
    "Pattern: Fine Leather Boots", "Thread Seller" })
ask("how do i learn handstitched leather pants", "(Leatherworking 30): taught by trainers. |cff40ff40You can learn it now (35).")
-- "when can I learn [item]": the skill it needs and how far you are.
ask("when can i learn " .. il(2309), { "[Embossed Leather Boots]|r (Leatherworking 55): taught by trainers. You're at 35: 20 to go.",
    "[Leatherworking trainer]" })
ask("when can i learn fine leather boots", { "(Leatherworking 90): learn it from", "You're at 35: 55 to go." })
ask("mats for 2 fine leather boots", { "[Fine Leather Boots]|r x2 (Leatherworking):", "10 |cffffffff[Light Leather]|r: buy 10",
    "You don't know it yet (Leatherworking 90), learn: " })
ask("cost to craft " .. il(2307) .. " from scratch", { "[Fine Leather Boots]|r (Leatherworking):", "buying everything",
    "You don't know it yet" })
-- Straight after a /reload, AtlasLoot's recipes are still loading: say so, not "none of your recipes".
AskBot.Crafts.status = "loading"
ask("cost to craft " .. il(2309) .. " from scratch", "Still reading AtlasLoot's recipes", { "None of your recipes" })
AskBot.Crafts.status = "ready"
table.remove(skillLines)

-- Beasts you meet: the game says "Coyote" isn't one here, and "Grey Thing" is
do
    local saved = { UnitExists, UnitGUID, UnitIsPlayer, UnitCreatureType }
    local targetGuid, targetType
    UnitExists = function(u) if u == "target" then return targetGuid ~= nil end return saved[1](u) end
    UnitGUID = function(u) if u == "target" then return targetGuid end return saved[2](u) end
    UnitIsPlayer = function() return false end
    UnitCreatureType = function() return targetType end
    targetGuid, targetType = "Creature-0-1-0-1-31-0000AAAA", "Humanoid"
    fire("PLAYER_TARGET_CHANGED")
    targetGuid, targetType = "Creature-0-1-0-1-35-0000BBBB", "Beast"
    fire("PLAYER_TARGET_CHANGED")
    targetGuid = nil
    skillLines[#skillLines + 1] = { "Skinning", false, 60 }
    ask("how do i level skinning", { "|cffffd100Westfall|r: Grey Thing" }, { "Coyote" })
    table.remove(skillLines)
    UnitExists, UnitGUID, UnitIsPlayer, UnitCreatureType = saved[1], saved[2], saved[3], saved[4]
    AskBotDB.creatureTypes = nil
end

-- The modern profession API (no classic trade skill functions): a Cooking window
do
    local classic = { GetTradeSkillLine, GetNumTradeSkills, GetTradeSkillInfo }
    GetTradeSkillLine, GetNumTradeSkills, GetTradeSkillInfo = nil, nil, nil
    itemCache[2680] = "Spiced Wolf Meat"; itemCache[2672] = "Stringy Wolf Meat"
    C_TradeSkillUI = {
        GetBaseProfessionInfo = function() return { professionName = "Cooking", skillLevel = 40, maxSkillLevel = 75 } end,
        GetAllRecipeIDs = function() return { 2538, 2539 } end,
        GetRecipeInfo = function(id)
            if id == 2538 then return { name = "Spiced Wolf Meat", learned = true, relativeDifficulty = 0 } end
            return { name = "Unlearned Stew", learned = false, relativeDifficulty = 0 }
        end,
        GetRecipeSchematic = function(id)
            return { outputItemID = 2680, quantityMin = 1,
                reagentSlotSchematics = { { reagents = { { itemID = 2672 } }, quantityRequired = 1 } } }
        end,
    }
    fire("TRADE_SKILL_LIST_UPDATE")
    advance(1)
    ask("how do i level cooking", { "Cooking 40/75: cheapest skill-ups", "[Spiced Wolf Meat]|r |cffff8040orange" },
        { "Unlearned Stew" })
    ask("mats for spiced wolf meat", { "[Spiced Wolf Meat]|r (Cooking):", "1 |cffffffff[Stringy Wolf Meat]|r: buy 1" })
    GetTradeSkillLine, GetNumTradeSkills, GetTradeSkillInfo = classic[1], classic[2], classic[3]
    C_TradeSkillUI = nil
end

-- Rare alerts: Foreman Grills (rare elite, Westfall, level 21) drops a belt; your waist is empty
do
    local from = #output + 1
    fire("ZONE_CHANGED_NEW_AREA")
    advance(1)
    advance(2)
    local text = withPlainQuestLinks(table.concat(output, "\n", from))
    for _, e in ipairs({ "Rare here: |cffffd100Foreman Grills|r (21 elite) can drop", "[Grills' Girdle]",
        "for your empty waist slot", "[pin]" }) do
        if not text:find(e, 1, true) and not text:find(e:gsub("%[pin%]", "|Haddon:askbot:"), 1, true) then
            failures = failures + 1; print("   !! FAIL: expected " .. e)
        end
    end
    from = #output + 1
    fire("ZONE_CHANGED_NEW_AREA")
    advance(1)
    advance(2)
    if #output >= from then failures = failures + 1; print("   !! FAIL: rare alert repeated") end
    AskBot.SetOption("rareAlerts", false)
end

-- Travel and map ---------------------------------------------------------------------------
-- History: /ab again and /ab history
ask("closest inn", "Innkeeper Heather")
ask("again", { "Again: closest inn", "Innkeeper Heather" })
ask("history", { "Recent questions: ", "[closest inn]" }, { "[again]" })
-- Every skinning trainer on the map
ask("show all skinning trainers", { "Nearest Skinning trainer", "Put 2 icons on your map" })
if hbd.worldIcons ~= 2 then failures = failures + 1; print("   !! FAIL: world icons " .. hbd.worldIcons) end
ask("clear", "Pin cleared")
if hbd.worldIcons ~= 0 then failures = failures + 1; print("   !! FAIL: icons not cleared") end
ask("show all flying carpets", "Nothing to put on the map")

-- Hearthstone: learned by using it (you arrive in Auberdine), then used for travel times
do
    local hearthCd = { 0, 0 }
    function GetBindLocation() return "Auberdine" end
    function GetItemCooldown() return hearthCd[1], hearthCd[2] end
    bags[6948] = 1
    ask("hearth", "Your hearthstone is set to |cffffd100Auberdine|r. Use it once")
    local pos, best = hbd.GetPlayerWorldPosition, C_Map.GetBestMapForUnit
    hbd.GetPlayerWorldPosition = function() return 3370, 440, 1 end           -- Darkshore 37, 44
    C_Map.GetBestMapForUnit = function() return 1439 end
    fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-1", 8690)
    advance(1)
    advance(2)
    hbd.GetPlayerWorldPosition, C_Map.GetBestMapForUnit = pos, best
    ask("hearth", { "Hearthstone: |cffffd100Auberdine|r (Darkshore), |cff40ff40ready|r", "[pin]" })
    ask("where is auberdine quester", "hearth to Auberdine", { "boat" })
    hearthCd[1], hearthCd[2] = now, 3600                                        -- just used
    ask("hearth", "ready in 60 min")
    ask("where is auberdine quester", "boat", { "hearth to" })
    bags[6948], AskBotCharDB.bind, GetBindLocation, GetItemCooldown = nil, nil, nil, nil
end

-- More Questie data ------------------------------------------------------------------------
-- Reputation: Stormwind quests in your log, to pick up, and for later
ask("quests for stormwind rep", { "Stormwind|r: 4 quests give reputation.", "In your log: ", "The Defias Brotherhood|r |cff66cc33+75",
    "Gryan Stoutmantle|r", "Patrolling Westfall|r |cff66cc33+250", "Westfall Stew|r |cff66cc33+150",
    "Later: ", "Too Hard|r |cff66cc33+500|r|cffaaaaaa (needs 28)" })
ask("sw rep quests", "Stormwind|r: 4 quests give reputation")
ask("how do i get rep with timbuktu", "I don't know a faction called \"timbuktu\"")
-- Items that start quests: the item answer says so, and "quest starters" lists them
itemCache[9030] = "Strange Note"
ask("where can i get strange note", { "Defias Thug", "Starts quest ", "[The Defias Note]", "right-click it to begin" })
ask("quest starters", { "Items that start quests at your level, nearest first:", "[Strange Note]|r > ", "The Defias Note",
    "from |cffffd100Defias Thug|r (Westfall" }, { "In your bags" })
C_Container = { GetContainerNumSlots = function(bag) return bag == 0 and 1 or 0 end,
    GetContainerItemID = function() return 9030 end }
ask("quest starters", "In your bags (right-click to start): ", { "nearest first" })
-- "anything in my bags an upgrade?": leggings beat the worn ones; a wand and a note don't count
local bagItems = { 9005, 9001, 9030, 9010 }
C_Container = { GetContainerNumSlots = function(bag) return bag == 0 and #bagItems or 0 end,
    GetContainerItemID = function(_, slot) return bagItems[slot] end }
ask("anything in my bag an upgrade", { "Upgrades in your bags for Arms Warrior:", "[Militia Leggings]|h|r (Legs): +514% over",
    "[Worn Leggings]" }, { "Apprentice Wand", "Strange Note", "Sorry" })
-- No talents yet: say the spec is a guess
local savedTalents = talents
talents = { 0, 0, 0 }
ask("anything in my bag an upgrade", "Upgrades in your bags for Warrior (no talents yet, scored as Arms):")
ask("is militia leggings an upgrade", "for Warrior (no talents yet, scored as Arms).")
talents = { 6, 4, 0 }
ask("bag upgrades", "for Warrior (talents unclear, scored as Arms)")
ask("bag upgrades as fury", "Upgrades in your bags for Fury Warrior:")
talents = savedTalents
-- Armour-only boots: a tiny score, but more than twice as good
equipped[8] = 9014
bagItems = { 9015 }
ask("anything in my bag an upgrade", { "[Flimsy Chain Boots]", "(Feet): +113% over", "[Ragged Leather Boots]" })
-- Level 5: the game reports no talent trees yet
local realTabs, realLevel = GetNumTalentTabs, units.player[4]
GetNumTalentTabs, units.player[4] = function() return 0 end, 5
ask("anything in my bag an upgrade", "for Warrior (no talents yet, scored as Arms)", { "spec unknown" })
GetNumTalentTabs, units.player[4] = realTabs, realLevel
equipped[8] = nil
bagItems = { 9005, 9030 }
ask("any upgrades in my bags?", "Nothing in your bags beats what you wear for Arms Warrior")
bagItems = { 9030 }
ask("is anything in my inventory better", "There's no gear in your bags.")
-- Selling junk at a merchant: 13 grey items (12 sell, then a [sell] link for the last), a wand a
-- warrior can't use (AH barely more: vendor it), an outgrown tunic, a tunic better sold on the AH,
-- a green wand with no AH price (kept), and gear you'd still use (kept quietly).
do
    gear[9016] = { "Frayed Tunic", "INVTYPE_CHEST", 4, 3, 5, 8, { ITEM_MOD_STAMINA_SHORT = 1 }, true }
    gear[9017] = { "Fine Tunic", "INVTYPE_CHEST", 4, 3, 5, 8, { ITEM_MOD_STAMINA_SHORT = 1 }, true }
    gear[9018] = { "Cracked Wand", "INVTYPE_RANGEDRIGHT", 2, 19, 5, 8, { ITEM_MOD_DAMAGE_PER_SECOND_SHORT = 2 }, true }
    -- The Mining Pick is a low white one-hander, but a profession tool: never sold.
    gear[2901] = { "Mining Pick", "INVTYPE_WEAPON", 2, 0, 0, 4, { ITEM_MOD_DAMAGE_PER_SECOND_SHORT = 1 }, true }
    -- Worse than the worn leggings for Arms (your spec), better for Protection: off-spec, kept.
    gear[9019] = { "Bulky Leggings", "INVTYPE_LEGS", 4, 3, 5, 8, { ITEM_MOD_STAMINA_SHORT = 3 }, true }
    for _, id in ipairs({ 9016, 9017, 9018, 2901, 9019 }) do itemCache[id] = gear[id][1] end
    itemCache[9190] = "Broken Fang"
    -- id -> { quality, vendor price }
    local junkInfo = { [9190] = { 0, 50 }, [9005] = { 2, 100 }, [9016] = { 1, 30 }, [9017] = { 2, 40 },
        [9018] = { 2, 60 }, [9001] = { 2, 500 }, [2901] = { 1, 2 }, [9019] = { 1, 20 } }
    local realInfo = C_Item.GetItemInfo
    C_Item.GetItemInfo = function(id)
        local n = tonumber(id) or tonumber(tostring(id):match("item:(%d+)"))
        local j = junkInfo[n]
        if not j then return realInfo(id) end
        local name, link, _, ilvl, req = realInfo(id)
        name = name or itemCache[n]
        link = link or ("|cff9d9d9d|Hitem:" .. n .. "::|h[" .. name .. "]|h|r")
        return name, link, j[1], ilvl or 1, req or 0, nil, nil, nil, nil, nil, j[2], gear[n] and gear[n][3] or 15
    end
    ahPrices[9005], ahAges[9005] = 120, 0     -- 114 after the cut: not worth listing
    ahPrices[9017], ahAges[9017] = 5000, 0    -- 47s 50c after the cut vs 40c: list it
    local slots = {}
    for i = 1, 13 do slots[i] = 9190 end
    for _, id in ipairs({ 9005, 9016, 9017, 9018, 9001, 2901, 9019 }) do slots[#slots + 1] = id end
    local soldIds = {}
    C_Container = { GetContainerNumSlots = function(bag) return bag == 0 and #slots or 0 end,
        GetContainerItemID = function(_, slot) return slots[slot] end,
        GetContainerItemInfo = function(_, slot) return slots[slot] and { stackCount = 1, isLocked = false } end,
        UseContainerItem = function(_, slot) soldIds[#soldIds + 1] = slots[slot]; slots[slot] = false end }
    MerchantFrame = { IsShown = function() return true end }
    local from = #output + 1
    print("\n> MERCHANT_SHOW")
    fire("MERCHANT_SHOW")
    advance(1)
    local text = table.concat(output, "\n", from)
    for _, e in ipairs({ "Sold 12 junk items for 6s", "3 more for 1s 80c", "Better on the AH: ", "Fine Tunic",
        "~47s 50c", "(vendor 40c)", "Kept, no AH price yet:", "Cracked Wand" }) do
        if not text:find(e, 1, true) then failures = failures + 1; print("   !! FAIL: expected " .. e) end
    end
    if #soldIds ~= 12 then failures = failures + 1; print("   !! FAIL: sold " .. #soldIds .. ", expected 12") end
    for _, id in ipairs(soldIds) do
        if id ~= 9190 then failures = failures + 1; print("   !! FAIL: sold " .. tostring(id) .. " in the first 12") end
    end
    -- Click [sell]: the grey, the wand and the outgrown tunic go; the leggings never do.
    local sellLink
    for i = from, #output do sellLink = output[i]:match("|H(addon:askbot:%d+)|h%[sell%]") or sellLink end
    print("\n> click [sell]")
    linkCallback(nil, sellLink)
    local sold = {}
    for _, id in ipairs(soldIds) do sold[id] = (sold[id] or 0) + 1 end
    if sold[9190] ~= 13 or sold[9005] ~= 1 or sold[9016] ~= 1 or sold[9017] or sold[9018] or sold[9001] or sold[2901] or sold[9019] then
        failures = failures + 1; print("   !! FAIL: [sell] sold the wrong items")
    end
    -- Soulbound: the AH can't take it, so the unpriced green wand sells after all.
    slots = { 9018 }
    soldIds = {}
    C_Container.GetContainerItemInfo = function(_, slot) return slots[slot] and { stackCount = 1, isLocked = false, isBound = true } end
    fire("MERCHANT_SHOW")
    advance(1)
    if soldIds[1] ~= 9018 then failures = failures + 1; print("   !! FAIL: soulbound unpriced green not sold") end
    C_Container.GetContainerItemInfo = function(_, slot) return slots[slot] and { stackCount = 1, isLocked = false } end
    -- Food: Haunch of Meat (level 5) sells at 20; a level-15 snack doesn't yet; a level-3 potion
    -- never does (food and drink only). A grey worth 1s 31c on the AH vs 15c at the vendor stays.
    itemCache[9191], itemCache[9192], itemCache[9195], itemCache[9196] = "Haunch of Meat", "Hearty Snack",
        "Lesser Healing Potion", "Odd Trinket"
    junkInfo[9191], junkInfo[9192], junkInfo[9195], junkInfo[9196] = { 1, 12 }, { 1, 25 }, { 1, 100 }, { 0, 15 }
    ahPrices[9196], ahAges[9196] = 138, 0
    local consumableReq = { [9191] = 5, [9192] = 15, [9195] = 3 }
    local consumableSub = { [9191] = 5, [9192] = 5, [9195] = 1 }
    local withJunk = C_Item.GetItemInfo
    C_Item.GetItemInfo = function(id)
        local n = tonumber(id) or tonumber(tostring(id):match("item:(%d+)"))
        if consumableReq[n] then
            return itemCache[n], "|cffffffff|Hitem:" .. n .. "::|h[" .. itemCache[n] .. "]|h|r", 1, 5, consumableReq[n],
                nil, nil, nil, "", nil, junkInfo[n][2], 0, consumableSub[n]
        end
        return withJunk(id)
    end
    slots, soldIds = { 9191, 9192, 9195, 9196 }, {}
    local junkFrom = #output + 1
    fire("MERCHANT_SHOW")
    advance(1)
    if not table.concat(output, "\n", junkFrom):find("Odd Trinket", 1, true) then
        failures = failures + 1; print("   !! FAIL: cheap grey worth 9x on the AH not listed")
    end
    if soldIds[1] ~= 9191 or soldIds[2] then failures = failures + 1; print("   !! FAIL: food: sold " .. table.concat(soldIds, ",")) end
    C_Item.GetItemInfo = withJunk
    -- Sword and shield vs a two-hander: the shield's armour doesn't count for Arms, so the
    -- two-handed damage upgrade is kept (it lost to the shield's armour before).
    gear[9193] = { "Test Shield", "INVTYPE_SHIELD", 4, 6, 10, 15, { RESISTANCE0_NAME = 400, ITEM_MOD_STRENGTH_SHORT = 2, ITEM_MOD_STAMINA_SHORT = 3 }, true }
    gear[9194] = { "Test Greataxe", "INVTYPE_2HWEAPON", 2, 1, 5, 10, { ITEM_MOD_DAMAGE_PER_SECOND_SHORT = 6, ITEM_MOD_STRENGTH_SHORT = 3, ITEM_MOD_STAMINA_SHORT = 4 }, true }
    itemCache[9193], itemCache[9194] = "Test Shield", "Test Greataxe"
    junkInfo[9194] = { 2, 100 }
    equipped[17] = 9193
    slots, soldIds = { 9194 }, {}
    C_Container.GetContainerItemInfo = function(_, slot) return slots[slot] and { stackCount = 1, isLocked = false, isBound = true } end
    fire("MERCHANT_SHOW")
    advance(1)
    if soldIds[1] then failures = failures + 1; print("   !! FAIL: sold the two-handed upgrade") end
    equipped[17] = nil
    -- "Keep gear for other specs" off: leggings only Protection wants are sold.
    AskBotDB.junkOffSpec = false
    slots, soldIds = { 9019 }, {}
    fire("MERCHANT_SHOW")
    advance(1)
    if soldIds[1] ~= 9019 then failures = failures + 1; print("   !! FAIL: off-spec leggings kept with the setting off") end
    AskBotDB.junkOffSpec = nil
    -- An outgrown dagger you haven't trained Daggers for: kept (you'll skill up with it). Once
    -- Daggers is trained, it's outgrown junk again.
    gear[9197] = { "Dull Dagger", "INVTYPE_WEAPON", 2, 15, 5, 8, { ITEM_MOD_DAMAGE_PER_SECOND_SHORT = 1 }, true }
    itemCache[9197], junkInfo[9197] = "Dull Dagger", { 1, 30 }
    slots, soldIds = { 9197 }, {}
    fire("MERCHANT_SHOW")
    advance(1)
    if soldIds[1] then failures = failures + 1; print("   !! FAIL: sold a weapon whose skill isn't trained") end
    skillLines[#skillLines + 1] = { "Daggers", false, 1 }
    slots, soldIds = { 9197 }, {}
    -- It's damaged, so the vendor pays 25c, not its listed 30c: the message says what came in.
    local wallet, use = 1000, C_Container.UseContainerItem
    GetMoney = function() return wallet end
    C_Container.UseContainerItem = function(b, s) wallet = wallet + 25; use(b, s) end
    local moneyFrom = #output + 1
    fire("MERCHANT_SHOW")
    advance(1)
    advance(2)
    if soldIds[1] ~= 9197 then failures = failures + 1; print("   !! FAIL: outgrown trained dagger kept") end
    if not table.concat(output, "\n", moneyFrom):find("Sold 1 junk item for 25c", 1, true) then
        failures = failures + 1; print("   !! FAIL: sale message didn't use the money received")
    end
    GetMoney, C_Container.UseContainerItem = nil, use
    table.remove(skillLines)
    gear[9197] = nil
    C_Container.GetContainerItemInfo = function(_, slot) return slots[slot] and { stackCount = 1, isLocked = false } end
    gear[9193], gear[9194] = nil, nil
    -- Turned off: nothing sells.
    AskBotDB.autoVendor = false
    slots = { 9190 }
    soldIds = {}
    fire("MERCHANT_SHOW")
    advance(1)
    if #soldIds ~= 0 then failures = failures + 1; print("   !! FAIL: sold with autoVendor off") end
    AskBotDB.autoVendor = nil
    C_Item.GetItemInfo, MerchantFrame = realInfo, nil
    for _, id in ipairs({ 9016, 9017, 9018, 2901, 9019 }) do gear[id] = nil end
end
C_Container = nil

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
-- Pins become the game's map pin links (clickable without AskBot);
-- your own map pin is put back afterwards.
local pinsBefore = tomtomWaypoints
local myWaypoint = UiMapPoint.CreateFromCoordinates(1436, 0.5, 0.5)
userWaypoint = myWaypoint
expectChat("guild: !ask nearest skinning trainer", function()
    fire("CHAT_MSG_GUILD", "!ask nearest skinning trainer", "Guildie-Realm")
end, { "GUILD: [AskBot] Nearest Skinning trainer:", "Helene Peltskinner <Skinning Trainer> - Stormwind City 71.6, 62.8 (",
    "|cffffff00|Hworldmap:1453:7160:6280|h[Map Pin Location]|h|r" },
    { "|Haddon", "[pin]", "AskBot:", "/way" })
if tomtomWaypoints ~= pinsBefore then failures = failures + 1; print("   !! FAIL: answering someone else placed a pin") end
if userWaypoint ~= myWaypoint then failures = failures + 1; print("   !! FAIL: your own map pin wasn't put back") end
userWaypoint = nil
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
end, { "[AskBot] That one needs your own quest log or gear" })
advance(10)
expectChat("guild: gear questions need their own AskBot too", function()
    fire("CHAT_MSG_GUILD", "!ask what gear should i get", "Guildie-Realm")
end, { "[AskBot] That one needs your own quest log or gear" })
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
-- Group members: from your side, and from Buddy's (his group includes you)
ask("where is my party member", { "Your group:", "Buddy|r <30 Hunter> - Redridge Mountains 35.0, 55.0" }, { "Me|r" })
ask("where is buddy", { "Buddy|r <30 Hunter> - Redridge Mountains 35.0, 55.0" }, { "Your group:" })
advance(10)
expectChat("party: !ask where is my party member", function()
    fire("CHAT_MSG_PARTY", "!ask where is my party member", "Buddy")
end, { "PARTY: [AskBot] Your group:", "Me <20 Warrior> - Westfall 50.0, 50.0", "|Hworldmap:1436:5000:5000|h",
    }, { "Buddy <", "/way" })
advance(10)
-- Forever shows names differently in chat ("Buddy Hunterson"): the chat event's GUID decides,
-- and without one, a first name matches a full one.
expectChat("party: !ask from a differently written name, with the sender's GUID", function()
    fire("CHAT_MSG_PARTY", "!ask where is everyone", "Buddy Hunterson-Realm", "", "", "", "", 0, 0, "", 0, 1, "Player-1-0002")
end, { "PARTY: [AskBot] Your group:", "Me <20 Warrior> - Westfall 50.0, 50.0" }, { "you're not in it", "Buddy <" })
advance(10)
-- Secret values (CHAT_MSG_PARTY_LEADER in an instance): type() says "string", but comparing or
-- reading one errors. A secret GUID falls back to the name; a secret message is skipped.
do
    local realType = type
    local function secret() return setmetatable({}, { __index = function() error("attempt to index a secret value") end,
        __concat = function() error("attempt to concatenate a secret value") end }) end
    local secrets = {}
    local function mark(v) secrets[v] = true; return v end
    type = function(v) if secrets[v] then return "string" end return realType(v) end
    issecretvalue = function(v) return secrets[v] == true end
    local errors = 0
    local realHandler = geterrorhandler
    geterrorhandler = function() return function(e) errors = errors + 1; print("ERROR HANDLER: " .. tostring(e)) end end
    advance(10)
    expectChat("party leader: !ask with a secret GUID", function()
        fire("CHAT_MSG_PARTY_LEADER", "!ask where is my party", "Buddy Hunterson-Realm", "", "", "", "", 0, 0, "", 0, 1,
            mark(secret()))
    end, { "PARTY: [AskBot] Your group:", "Me <20 Warrior>" }, { "you're not in it", "Buddy <" })
    advance(10)
    expectChat("party leader: a secret message", function()
        fire("CHAT_MSG_PARTY_LEADER", mark(secret()), "Buddy")
    end)
    advance(10)
    if errors > 0 then failures = failures + 1; print("   !! FAIL: secret values raised " .. errors .. " error(s)") end
    type, issecretvalue, geterrorhandler = realType, nil, realHandler
end
expectChat("party: !ask from a full name without a GUID", function()
    fire("CHAT_MSG_PARTY", "!ask where is my group", "Buddy Hunterson")
end, { "PARTY: [AskBot] Your group:", "Me <20 Warrior>" }, { "you're not in it", "Buddy <" })
advance(10)
inGroup = true
ask("debug share", { "Last !ask: Buddy Hunterson", "matched party1", "party1: Buddy (GUID Player-1-0002)" })
expectChat("party: a question AskBot doesn't know", function()
    fire("CHAT_MSG_PARTY", "!ask what is the meaning of life", "Buddy")
end, { "Try !ask help" }, { "/askbot help" })
advance(10)
-- Group quest progress, from Questie's party sync
ask("who has red linen goods", { "Red Linen Goods|r: you 2/6", "(No Questie party data from Buddy.)" }, { "Buddy " })
remoteLogs[103] = { ["Buddy-Realm"] = { { fulfilled = 10, required = 10, finished = true },
    { fulfilled = 3, required = 6, finished = false } } }
remoteLogs[142] = { Buddy = { { fulfilled = 1, required = 1, finished = true } } }
remoteClasses.Buddy = "HUNTER"
ask("who has red linen goods", "Red Linen Goods|r: you 2/6, Buddy 3/6", { "No Questie" })
ask("who needs bounty on murlocs", "you |cffaaaaaanot taken|r, Buddy |cffaaaaaanot taken")
ask("red linen goods", "  Group: Buddy 3/6")
ask("who gives red silk bandanas", "  Group: Buddy |cff66cc33ready")
ask("deadmines quests", "Group has: |cffffd100[17] Red Silk Bandanas|r|cffaaaaaa (Buddy)")
remoteLogs[103], remoteLogs[142], remoteClasses.Buddy = nil, nil, nil
inGroup = false
ask("where is my party", "You're not in a group.")
ask("where is guildie", { "Guildie|r (level 20 Mage) is in Stormwind City", "guild roster" })
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
