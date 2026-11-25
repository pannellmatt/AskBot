-- WeaponMasters.lua
-- "What weapon master teaches bows?": which weapon masters teach which weapon skills.
-- Questie has no trainer lists, so this starts from Classic's lists and adds whatever the
-- weapon master windows you open show (account-wide, AskBotDB.weaponMasters[npcId]).

local _, AskBot = ...
local D = AskBot.Data
local Out = AskBot.Out
local WM = {}
AskBot.WeaponMasters = WM
local GREY, say, askerClass, showRanked, pinBest = Out.GREY, Out.say, Out.askerClass, Out.showRanked, Out.pinBest
local Gear = AskBot.Gear

-- Skill names are the skill-line names (what Gear and the skills window use): one-handed
-- weapons are plain "Swords", "Axes", "Maces".
local CLASSIC = {
    [11867] = { "Crossbows", "Daggers", "Swords", "Polearms", "Staves", "Two-Handed Swords" }, -- Woo Ping, Stormwind
    [11865] = { "Fist Weapons", "Guns", "Axes", "Maces", "Two-Handed Axes", "Two-Handed Maces" }, -- Buliwyf Stonehand, Ironforge
    [13084] = { "Crossbows", "Daggers", "Thrown" },                                    -- Bixi Wobblebonk, Ironforge
    [11866] = { "Bows", "Daggers", "Fist Weapons", "Staves", "Thrown" },              -- Ilyenia Moonfire, Darnassus
    [2704] = { "Bows", "Axes", "Staves", "Thrown", "Two-Handed Axes" },               -- Hanashi, Orgrimmar
    [11868] = { "Bows", "Daggers", "Fist Weapons", "Axes", "Thrown", "Two-Handed Axes" }, -- Sayoc, Orgrimmar
    [11869] = { "Guns", "Maces", "Staves", "Two-Handed Maces" },                      -- Ansekhwa, Thunder Bluff
    [11870] = { "Crossbows", "Daggers", "Swords", "Polearms", "Two-Handed Swords" },  -- Archibald, Undercity
}

local SHORT = { ["Two-Handed Swords"] = "2H Swords", ["Two-Handed Axes"] = "2H Axes", ["Two-Handed Maces"] = "2H Maces",
    ["Fist Weapons"] = "Fist" }

local function hasWord(q, w)
    return (" " .. q .. " "):find(" " .. w, 1, true) ~= nil
end

--- The weapon skill a (normalized, lower-case) question or trainer service names, or nil.
local function skillIn(q)
    local two = hasWord(q, "two hand") or hasWord(q, "2h") or hasWord(q, "2 hand") or hasWord(q, "twohand")
    if hasWord(q, "crossbow") or hasWord(q, "xbow") then return "Crossbows" end
    if hasWord(q, "bow") then return "Bows" end
    if hasWord(q, "gun") or hasWord(q, "rifle") then return "Guns" end
    if hasWord(q, "thrown") or hasWord(q, "throw") then return "Thrown" end
    if hasWord(q, "dagger") or hasWord(q, "knife") or hasWord(q, "knives") then return "Daggers" end
    if hasWord(q, "fist") then return "Fist Weapons" end
    if hasWord(q, "polearm") or hasWord(q, "pole arm") or hasWord(q, "spear") or hasWord(q, "halberd") then return "Polearms" end
    if hasWord(q, "staff") or hasWord(q, "stave") then return "Staves" end
    if hasWord(q, "wand") then return "Wands" end
    if hasWord(q, "sword") then return two and "Two-Handed Swords" or "Swords" end
    if hasWord(q, "axe") then return two and "Two-Handed Axes" or "Axes" end
    if hasWord(q, "mace") then return two and "Two-Handed Maces" or "Maces" end
end

local function normalize(s)
    return (s:lower():gsub("[^%w%s]", " "):gsub("%s+", " "):match("^%s*(.-)%s*$"))
end

--- Skills NPC `id` teaches (as a set), or nil when unknown.
local function teaches(id)
    local learned = AskBotDB and AskBotDB.weaponMasters and AskBotDB.weaponMasters[id]
    local base = CLASSIC[id]
    if not learned and not base then return nil end
    local set = {}
    if not (learned and learned.complete) then
        for _, s in ipairs(base or {}) do set[s] = true end
    end
    for s in pairs(learned and learned.skills or {}) do set[s] = true end
    return set
end

local function teachList(set)
    local list = {}
    for s in pairs(set) do list[#list + 1] = s end
    table.sort(list)
    for i, s in ipairs(list) do list[i] = SHORT[s] or s end
    return table.concat(list, ", ")
end

local function isWeaponMasterSub(sub)
    sub = sub and sub:lower()
    return sub ~= nil and (sub:find("weapon master", 1, true) or sub:find("weapons trainer", 1, true)) ~= nil
end

local function friendlyMasters()
    local mine, out = D.PlayerFaction(), {}
    for _, p in ipairs(D.byTarget.weapon or {}) do
        if D.IsFriendly(p, mine) then out[#out + 1] = p end
    end
    return out
end

local function classCanLearn(skill)
    local classFile = askerClass()
    if Gear.ClassCanLearn and Gear.ClassCanLearn(classFile, skill) then return true end
    local skills = Gear.Skills and Gear.Skills()
    if skills and skills[skill] then return true end
    local can = Gear.WEAPONS and Gear.WEAPONS[classFile]
    if not can then return true end
    for sub, name in pairs(Gear.WEAPON_NAMES or {}) do
        if name == skill then return can[sub] == true end
    end
    return true
end

--- Is this a question about weapon masters / learning a weapon skill? Returns kind, skill.
function WM.Question(q)
    local master = hasWord(q, "weapon master") or hasWord(q, "weaponmaster") or hasWord(q, "weapons trainer")
        or hasWord(q, "weapon trainer")
    local skill = skillIn(q)
    if skill then
        if master or hasWord(q, "teach") or hasWord(q, "learn") or hasWord(q, "train") then return "skill", skill end
        return nil
    end
    if master then return "list" end
end

function WM.Answer(kind, skill)
    local places = friendlyMasters()
    if kind == "list" then
        if #places == 0 then return say("I couldn't find a Weapon Master friendly to you.") end
        local best = showRanked(places, "Nearest Weapon Master:", "Weapon Master", AskBot.Option("maxResults"), {
            extra = function(p)
                local set = teaches(p.id)
                return set and next(set) and (GREY .. " (" .. teachList(set) .. ")|r") or ""
            end })
        return pinBest(best, "Weapon Master")
    end
    if skill == "Wands" then
        return say("No one teaches Wands: mages, priests and warlocks know them from the start.")
    end
    local can = classCanLearn(skill)
    local skills = Gear.Skills and Gear.Skills()
    local note = ""
    if not can then
        local classFile = askerClass()
        note = GREY .. " (" .. classFile:sub(1, 1) .. classFile:sub(2):lower() .. "s can't use them)|r"
    elseif skills and skills[skill] then
        note = GREY .. " (you already know it)|r"
    end
    local matching, unknown = {}, {}
    for _, p in ipairs(places) do
        local set = teaches(p.id)
        if set == nil then unknown[#unknown + 1] = p.name
        elseif set[skill] then matching[#matching + 1] = p end
    end
    if #matching == 0 then
        say("I don't know a Weapon Master friendly to you who teaches " .. skill .. "." .. note)
        if #unknown > 0 then
            say(GREY .. "  Not known yet: " .. table.concat(unknown, ", ") .. ". Open their training window once and I'll remember.|r")
        end
        return
    end
    local best = showRanked(matching, "Nearest Weapon Master for " .. skill .. note .. ":", "Weapon Master", AskBot.Option("maxResults"))
    pinBest(best, "Weapon Master")
end

--- Records what the open weapon master's window teaches (TRAINER_SHOW/UPDATE).
function WM.Record()
    if not (GetNumTrainerServices and GetTrainerServiceInfo and NpcDB) then return end
    local guid = UnitGUID and UnitGUID("npc")
    local npcId = guid and tonumber(guid:match("^Creature%-%d+%-%d+%-%d+%-%d+%-(%d+)"))
    if not npcId or not isWeaponMasterSub(NpcDB.subName(npcId)) then return end
    local found = {}
    for i = 1, (GetNumTrainerServices() or 0) do
        local name, a, b = GetTrainerServiceInfo(i)
        if name and a ~= "header" and b ~= "header" then
            local skill = skillIn(normalize(name))
            if skill then found[skill] = true end
        end
    end
    if not next(found) then return end
    AskBotDB = AskBotDB or {}
    -- The window only lists what your class can learn: remember that per class, so gear and
    -- junk checks know (e.g. axes for rogues on Forever).
    local classFile = UnitClass and select(2, UnitClass("player"))
    if classFile then
        AskBotDB.classWeapons = AskBotDB.classWeapons or {}
        local cw = AskBotDB.classWeapons[classFile] or {}
        for s in pairs(found) do cw[s] = true end
        AskBotDB.classWeapons[classFile] = cw
    end
    -- With every filter on, the list is everything this trainer teaches.
    local filter = GetTrainerServiceTypeFilter
    local complete = filter and filter("available") and filter("unavailable") and filter("used") or false
    AskBotDB = AskBotDB or {}
    AskBotDB.weaponMasters = AskBotDB.weaponMasters or {}
    local e = AskBotDB.weaponMasters[npcId] or { skills = {} }
    if complete then e.skills = {} end
    for s in pairs(found) do e.skills[s] = true end
    e.complete = e.complete or complete
    AskBotDB.weaponMasters[npcId] = e
end

WM.skillIn = skillIn
