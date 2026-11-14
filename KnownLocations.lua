-- KnownLocations.lua
-- Places Questie's database doesn't have (or has wrong for Forever), gathered from public
-- sources: Questie's own data for other game versions, Warcraft Wiki, Wowhead, and Forever
-- guide sites. Answers using these are marked as community info, since Forever may have moved
-- things.
--
-- A location is { note = "what you're looking for", A = points, H = points, N = points }:
--   A / H are per faction, N is for both. Points are { uiMapId, x, y } in map percent.
--   Instead of points, `object = id` or `npc = id` borrows a Questie object's or NPC's spawns
--   (handy for Forever's new zones, whose map IDs aren't listed here).
--
-- AskBot.KNOWN.items[itemId]   where to get an item; used instead of Questie's sources (for items
--                              Questie can't place, or places wrongly).
-- AskBot.KNOWN.npcs[npcId]     where an NPC appears when Questie has no spawns (summoned ones).
-- AskBot.KNOWN.quests[questId] for one quest:
--   steps = { location, ... }  extra things to do, shown before the quest's own objectives
--   items = { [itemId] = location }, npcs = { [npcId] = location }   overrides for this quest
--   turnIn = location          where to hand it in, when Questie doesn't say
--
-- `/ab debug quest <quest>` shows what Questie has; `tools/classgaps.lua` lists class quests
-- with gaps.

local _, AskBot = ...

-- uiMapIds
local WESTFALL, REDRIDGE, WETLANDS, SILVERPINE = 1436, 1433, 1437, 1421
local DARKSHORE, ASHENVALE, BARRENS = 1439, 1440, 1413
local STORMWIND, UNDERCITY = 1453, 1458

-- The Moonkin Stones from Body and Heart. Questie's Era data places them; Forever's doesn't.
local MOONKIN_STONE_A = { { DARKSHORE, 43.5, 46.0 } } -- in the moonkin cave east of Auberdine
local MOONKIN_STONE_H = { { BARRENS, 42.0, 60.9 } }   -- west of Camp Taurajo, near the Mulgore border
-- Alliance shaman Call of Water: the Forgotten Shrine at Stendel's Pond, Westfall.
local STENDELS_POND = { { WESTFALL, 45.6, 59.9 } }

-- Warlock demon quests: use the item at the summoning circle, then fight the demon there.
local function binding(item, demonId, demon, circleObject)
    return {
        steps = { { note = "Use the " .. item .. " at the summoning circle", object = circleObject } },
        npcs = { [demonId] = { note = "Summoned " .. demon .. " (at the summoning circle)", object = circleObject } },
    }
end

AskBot.KNOWN = {
    items = {
        -- Druid aquatic form, Trial of the Sea Lion: each half is in a Strange Lockbox. Checked
        -- in-game. Questie links each half to the other half's lockboxes, so these win over it.
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
    },

    npcs = {
        -- Druid bear form: Lunaclaw appears at the Moonkin Stone when you use the moondust.
        [12144] = { note = "Lunaclaw (use the moondust at the Moonkin Stone)", A = MOONKIN_STONE_A, H = MOONKIN_STONE_H },
    },

    quests = {
        -- Druid: Body and Heart (bear form)
        [6001] = { steps = { { note = "Use the Cenarion Moondust at the Moonkin Stone", A = MOONKIN_STONE_A } } },
        [6002] = { steps = { { note = "Use the Cenarion Lunardust at the Moonkin Stone", H = MOONKIN_STONE_H } } },

        -- Shaman (Forever, Alliance): Call of Water. Waterskin spots from bindonforever.com.
        [94497] = { items = { [265734] = { note = "Use the waterskin at the foot of the falls", N = { { WETLANDS, 64.8, 74.8 } } } } },
        [94499] = { items = { [265748] = { note = "Use the waterskin at Stonewatch Falls", N = { { REDRIDGE, 66.3, 62.9 } } } } },
        [94500] = { items = { [265773] = { note = "Use the waterskin in Astranaar's lake", N = { { ASHENVALE, 34.2, 47.8 } } } } },
        -- Questie reuses the Horde version's Silverpine spots; the Alliance one is in Westfall.
        [94502] = {
            steps = { { note = "Drink the Water Sapta by the Forgotten Shrine", N = STENDELS_POND } },
            npcs = { [5894] = { note = "Corrupt Minor Manifestation of Water", N = STENDELS_POND } },
        },
        [94503] = { npcs = { [5895] = { note = "Minor Manifestation of Water", N = STENDELS_POND } } },

        -- Shaman (Forever): Call of Fire on Zephras Isle. Questie has the stump, but not on the quest.
        [97245] = { steps = { { note = "Knock on Kuramaa's Stump", object = 660848 } } },

        -- Paladin (Forever, Horde): A Moon-Kissed Blade
        [95036] = { items = {
            [267361] = { note = "Enchanted Silver Ingot (on the table by Arugal, end of Shadowfang Keep)", dungeon = 209 },
            [267454] = { note = "Trevan Rol (ask him for his notes)", npc = 248840 },
        } },

        -- Warlock: The Binding. The demon appears at the city's summoning circle (Questie has the
        -- circles, but not on these quests).
        [1689] = binding("Bloodstone Choker", 5676, "Voidwalker", 92015),  -- Stormwind
        [1739] = binding("Heartswood Core", 5677, "Succubus", 92015),
        [1471] = binding("Runes of Summoning", 5676, "Voidwalker", 37097), -- Undercity
        [1474] = binding("Pure Hearts", 5677, "Succubus", 37097),
        [1504] = binding("Glyphs of Summoning", 5676, "Voidwalker", 105576), -- Orgrimmar
        [1513] = binding("Dogran's Pendant", 5677, "Succubus", 105576),

        -- Mage: the Rift Spawn hide in the Blue Recluse (Stormwind) and the alchemist shop (Undercity).
        [1920] = { items = { [7292] = { note = "Rift Spawn (reveal with the Cantation, then use the coffers)", N = { { STORMWIND, 51.3, 93.3 } } } } },
        [1960] = { items = { [7292] = { note = "Rift Spawn (reveal with the Cantation, then use the coffers)", N = { { UNDERCITY, 53.3, 74.6 } } } } },

        -- Priest (Forever): Questie has no turn-in for these.
        [94778] = { turnIn = { note = "High Priestess Laurena", npc = 376 } },
        [94779] = { turnIn = { note = "High Priestess Laurena", npc = 376 } },
        [94823] = { turnIn = { note = "High Priestess Mims", npc = 258785 } },
        [94825] = { turnIn = { note = "High Priestess Mims", npc = 258785 } },
        [94826] = { turnIn = { note = "High Priestess Mims", npc = 258785 } },
    },
}
