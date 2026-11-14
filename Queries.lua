-- Queries.lua
-- What AskBot knows how to look for. Each target says which words in a question select it
-- (`keys`, matched as word prefixes) and how to recognise a matching NPC from QuestieDB
-- (`test`, given the lower-cased subName and a helper that checks npcFlags by name).
--
-- Keys match at the start of a word ("skin" matches "skinning", "skinner"); keys of three
-- letters or fewer must match a whole word, so "ah" doesn't match "ahead".
--
-- Order matters: the first target whose key appears in the question wins, so specific
-- targets (professions, classes) come before broad ones (flight master, innkeeper).

local _, AskBot = ...

local function trainerFor(subPatterns)
    return function(sub, hasFlag)
        if not sub then return false end
        local isTrainer = hasFlag("TRAINER") or sub:find("trainer", 1, true)
        if not isTrainer then return false end
        for _, p in ipairs(subPatterns) do
            if sub:find(p, 1, true) then return true end
        end
        return false
    end
end

local function service(flagName, subPatterns)
    return function(sub, hasFlag)
        if hasFlag(flagName) then return true end
        if sub and subPatterns then
            for _, p in ipairs(subPatterns) do
                if sub:find(p, 1, true) then return true end
            end
        end
        return false
    end
end

AskBot.targets = {
    -- Professions
    { id = "alchemy",        label = "Alchemy trainer",        keys = { "alchem" },                  test = trainerFor({ "alchem" }) },
    { id = "blacksmithing",  label = "Blacksmithing trainer",  keys = { "blacksmith", "smithing" },  test = trainerFor({ "blacksmith" }) },
    { id = "enchanting",     label = "Enchanting trainer",     keys = { "enchant" },                 test = trainerFor({ "enchant" }) },
    { id = "engineering",    label = "Engineering trainer",    keys = { "engineer" },                test = trainerFor({ "engineer" }) },
    { id = "herbalism",      label = "Herbalism trainer",      keys = { "herb" },                    test = trainerFor({ "herbalis" }) },
    { id = "leatherworking", label = "Leatherworking trainer", keys = { "leather", "lw" },           test = trainerFor({ "leatherwork" }) },
    { id = "mining",         label = "Mining trainer",         keys = { "mining", "miner" },         test = trainerFor({ "mining", "miner" }) },
    { id = "skinning",       label = "Skinning trainer",       keys = { "skin" },                    test = trainerFor({ "skinn" }) },
    { id = "tailoring",      label = "Tailoring trainer",      keys = { "tailor" },                  test = trainerFor({ "tailor" }) },
    { id = "cooking",        label = "Cooking trainer",        keys = { "cook" },                    test = trainerFor({ "cook" }) },
    { id = "firstaid",       label = "First Aid trainer",      keys = { "first aid", "firstaid", "bandage" }, test = trainerFor({ "first aid" }) },
    { id = "fishing",        label = "Fishing trainer",        keys = { "fish" },                    test = trainerFor({ "fish" }) },
    { id = "weapon",         label = "Weapon Master",          keys = { "weapon" },                  test = trainerFor({ "weapon master" }) },
    { id = "pet",            label = "Pet trainer",            keys = { "pet trainer", "pet skill" }, test = trainerFor({ "pet trainer" }) },

    -- Classes (keys are class names; "class trainer" is resolved to the player's class)
    { id = "WARRIOR", label = "Warrior trainer", keys = { "warrior" }, test = trainerFor({ "warrior trainer" }) },
    { id = "PALADIN", label = "Paladin trainer", keys = { "paladin", "pally" }, test = trainerFor({ "paladin trainer" }) },
    { id = "HUNTER",  label = "Hunter trainer",  keys = { "hunter" },  test = trainerFor({ "hunter trainer" }) },
    { id = "ROGUE",   label = "Rogue trainer",   keys = { "rogue" },   test = trainerFor({ "rogue trainer" }) },
    { id = "PRIEST",  label = "Priest trainer",  keys = { "priest" },  test = trainerFor({ "priest trainer" }) },
    { id = "SHAMAN",  label = "Shaman trainer",  keys = { "shaman" },  test = trainerFor({ "shaman trainer" }) },
    { id = "MAGE",    label = "Mage trainer",    keys = { "mage" },    test = trainerFor({ "mage trainer" }) },
    { id = "WARLOCK", label = "Warlock trainer", keys = { "warlock", "lock" }, test = trainerFor({ "warlock trainer" }) },
    { id = "DRUID",   label = "Druid trainer",   keys = { "druid" },   test = trainerFor({ "druid trainer" }) },

    -- Services
    { id = "flight",  label = "Flight master", keys = { "flight", "fp", "fly", "gryphon", "wind rider", "windrider", "hippogryph", "bat handler", "taxi" },
      test = service("FLIGHT_MASTER", { "gryphon master", "wind rider master", "hippogryph master", "bat handler", "flight master" }) },
    { id = "inn",     label = "Innkeeper",     keys = { "innkeeper", "inn", "hearth" }, test = service("INNKEEPER", { "innkeeper" }) },
    { id = "bank",    label = "Banker",        keys = { "bank" },            test = service("BANKER", { "banker" }) },
    { id = "ah",      label = "Auctioneer",    keys = { "auction", "ah" },   test = service("AUCTIONEER", { "auctioneer" }) },
    { id = "stable",  label = "Stable master", keys = { "stable" },          test = service("STABLEMASTER", { "stable master" }) },
    { id = "repair",  label = "Repair vendor", keys = { "repair" },          test = service("REPAIR") },
}

-- Words that mean "my own class trainer".
AskBot.classTrainerKeys = { "class trainer", "my trainer", "class" }
