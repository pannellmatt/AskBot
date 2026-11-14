-- Gathering.lua
-- Mining veins, herbs and fishing schools: which profession and skill each node needs and
-- what it yields. QuestieDB's objects hold the spawn points; this table says which objects
-- are gathering nodes. Any other object named "... Vein" or "... Deposit" is treated as a
-- mining node of unknown skill (Forever adds a few).
--
-- `special` nodes are left out of "where should I mine?" suggestions: they're rare, in one
-- dungeon, or covered in ooze.

local _, AskBot = ...

local M, H, F = "Mining", "Herbalism", "Fishing"

AskBot.gatherNodes = {
    -- Mining
    ["Copper Vein"] = { M, 1, { "Copper Ore", "Rough Stone" } },
    ["Tin Vein"] = { M, 65, { "Tin Ore", "Coarse Stone" } },
    ["Incendicite Mineral Vein"] = { M, 65, { "Incendicite Ore" }, special = true },
    ["Silver Vein"] = { M, 75, { "Silver Ore" } },
    ["Ooze Covered Silver Vein"] = { M, 75, { "Silver Ore" }, special = true },
    ["Lesser Bloodstone Deposit"] = { M, 75, { "Lesser Bloodstone Ore" }, special = true },
    ["Iron Deposit"] = { M, 125, { "Iron Ore", "Heavy Stone" } },
    ["Indurium Mineral Vein"] = { M, 150, { "Indurium Ore" }, special = true },
    ["Gold Vein"] = { M, 155, { "Gold Ore" } },
    ["Ooze Covered Gold Vein"] = { M, 155, { "Gold Ore" }, special = true },
    ["Mithril Deposit"] = { M, 175, { "Mithril Ore", "Solid Stone" } },
    ["Ooze Covered Mithril Deposit"] = { M, 175, { "Mithril Ore" }, special = true },
    ["Truesilver Deposit"] = { M, 230, { "Truesilver Ore" } },
    ["Ooze Covered Truesilver Deposit"] = { M, 230, { "Truesilver Ore" }, special = true },
    ["Dark Iron Deposit"] = { M, 230, { "Dark Iron Ore" }, special = true },
    ["Small Thorium Vein"] = { M, 245, { "Thorium Ore", "Dense Stone" } },
    ["Ooze Covered Thorium Vein"] = { M, 245, { "Thorium Ore" }, special = true },
    ["Rich Thorium Vein"] = { M, 275, { "Thorium Ore", "Dense Stone" } },
    ["Ooze Covered Rich Thorium Vein"] = { M, 275, { "Thorium Ore" }, special = true },
    ["Hakkari Thorium Vein"] = { M, 275, { "Thorium Ore" }, special = true },

    -- Herbalism
    ["Peacebloom"] = { H, 1, { "Peacebloom" } },
    ["Silverleaf"] = { H, 1, { "Silverleaf" } },
    ["Earthroot"] = { H, 15, { "Earthroot" } },
    ["Mageroyal"] = { H, 50, { "Mageroyal", "Swiftthistle" } },
    ["Briarthorn"] = { H, 70, { "Briarthorn", "Swiftthistle" } },
    ["Stranglekelp"] = { H, 85, { "Stranglekelp" } },
    ["Bruiseweed"] = { H, 100, { "Bruiseweed" } },
    ["Wild Steelbloom"] = { H, 115, { "Wild Steelbloom" } },
    ["Grave Moss"] = { H, 120, { "Grave Moss" } },
    ["Kingsblood"] = { H, 125, { "Kingsblood" } },
    ["Liferoot"] = { H, 150, { "Liferoot" } },
    ["Fadeleaf"] = { H, 160, { "Fadeleaf" } },
    ["Goldthorn"] = { H, 170, { "Goldthorn" } },
    ["Khadgar's Whisker"] = { H, 185, { "Khadgar's Whisker" } },
    ["Wintersbite"] = { H, 195, { "Wintersbite" } },
    ["Firebloom"] = { H, 205, { "Firebloom" } },
    ["Purple Lotus"] = { H, 210, { "Purple Lotus" } },
    ["Arthas' Tears"] = { H, 220, { "Arthas' Tears" } },
    ["Sungrass"] = { H, 230, { "Sungrass" } },
    ["Blindweed"] = { H, 235, { "Blindweed" } },
    ["Ghost Mushroom"] = { H, 245, { "Ghost Mushroom" } },
    ["Gromsblood"] = { H, 250, { "Gromsblood" } },
    ["Golden Sansam"] = { H, 260, { "Golden Sansam" } },
    ["Dreamfoil"] = { H, 270, { "Dreamfoil" } },
    ["Mountain Silversage"] = { H, 280, { "Mountain Silversage" } },
    ["Plaguebloom"] = { H, 285, { "Plaguebloom" } },
    ["Icecap"] = { H, 290, { "Icecap" } },
    ["Black Lotus"] = { H, 300, { "Black Lotus" }, special = true },

    -- Fishing schools (any skill can fish them)
    ["Sagefish School"] = { F, nil, { "Raw Sagefish" } },
    ["Oily Blackmouth School"] = { F, nil, { "Oily Blackmouth" } },
    ["Firefin Snapper School"] = { F, nil, { "Firefin Snapper" } },
    ["School of Deviate Fish"] = { F, nil, { "Deviate Fish" } },
    ["School of Tastyfish"] = { F, nil, { "Speckled Tastyfish" } },
}

--- The node entry for an object name, or nil when it isn't a gathering node.
function AskBot.GatherNodeFor(name)
    local node = AskBot.gatherNodes[name]
    if node then return node end
    if name:match(" Vein$") or name:match(" Deposit$") then
        node = { M, nil, {} }
        AskBot.gatherNodes[name] = node
        return node
    end
end
