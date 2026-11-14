-- KnownLocations.lua
-- Where to find quest items that Questie's database doesn't place, gathered from public
-- sources (Warcraft Wiki, Wowhead comments). Answers using these are marked as community
-- info, since Forever may have moved things.
--
-- [itemId] = { note = "what you're looking for", A = { points }, H = { points } }
-- Each point is { uiMapId, x, y } in map percent. Use N for points both factions share.
-- To add one: find the item ID (Wowhead URL) and the zone coordinates, then add a line.

local _, AskBot = ...

-- uiMapIds
local WESTFALL, DARKSHORE, SILVERPINE, BARRENS = 1436, 1439, 1421, 1413

AskBot.KNOWN_ITEM_LOCATIONS = {
    -- Druid aquatic form quest, Trial of the Sea Lion: each half is in a Strange Lockbox.
    [15883] = { -- Half Pendant of Aquatic Agility
        note = "Strange Lockbox (underwater)",
        A = { { WESTFALL, 17.9, 33.0 } },    -- off the coast west of the Gold Coast Quarry, by a sunken boat
        H = { { SILVERPINE, 29.6, 29.5 } },  -- ocean floor west of North Tide's Run
    },
    [15882] = { -- Half Pendant of Aquatic Endurance
        note = "Strange Lockbox",
        A = { { DARKSHORE, 48.9, 11.3 } },   -- at the Stone Claw, north of where the Cliffspring River meets the sea
        H = { { BARRENS, 56.7, 8.3 } },      -- in the middle of the Sludge Fen
    },
}
