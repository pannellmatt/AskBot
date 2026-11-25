-- AskBot: Compat.lua
-- What AskBot once borrowed from Questie's code, rebuilt on QuestieDB's own data so that
-- Questie itself is optional: area ID -> map ID, dungeon entrances, quest XP, grey quests and
-- whether you can take a quest. QuestieDB ships the tables (LibQuestieDB.Support); Questie's
-- modules only wrap them. While Questie is running, its quest check is used instead of ours,
-- because it also knows the quests it hides (removed, event-only, not in the game).

local _, AskBot = ...
local C = {}
AskBot.Compat = C

local floor, max, min, abs = math.floor, math.max, math.min, math.abs

--- One of Questie's modules ("QuestieDB", "QuestieComms"...), only once Questie has started.
function C.QuestieModule(name)
    local q, loader = _G.Questie, _G.QuestieLoader
    if not (q and q.started and loader and loader.ImportModule) then return nil end
    local ok, module = pcall(loader.ImportModule, loader, name)
    return ok and type(module) == "table" and module or nil
end

local function support(name)
    local lib = _G.LibQuestieDB
    local s = lib and lib.Support
    if not (s and s.Get) then return nil end
    local ok, t = pcall(s.Get, name)
    return ok and type(t) == "table" and t or nil
end

-- Some support tables ship as Lua source ("return { ... }") to keep load time down.
local function decode(src)
    if type(src) == "table" then return src end
    if type(src) ~= "string" then return nil end
    local chunk = loadstring(src)
    if not chunk then return nil end
    local ok, t = pcall(chunk)
    return ok and type(t) == "table" and t or nil
end

--------------------------------------------------------------------------------------------
-- Zones and dungeons
--------------------------------------------------------------------------------------------

local areaToMap
local function zonePrivate()
    local z = support("ZoneDB")
    return z and type(z.private) == "table" and z.private or nil
end

--- The UI map ID for a zone's area ID, or nil.
function C.UiMapIdByAreaId(areaId)
    if not areaToMap then
        areaToMap = {}
        local p = zonePrivate()
        if p then
            for a, m in pairs(decode(p.areaIdToUiMapId) or {}) do areaToMap[a] = m end
            for a, m in pairs(decode(p.areaIdToUiMapIdOverride) or {}) do areaToMap[a] = m end
        end
    end
    if next(areaToMap) == nil then -- an older QuestieDB without support data: ask Questie
        local zoneDB = C.QuestieModule("ZoneDB")
        if zoneDB and zoneDB.GetUiMapIdByAreaId then
            local ok, m = pcall(zoneDB.GetUiMapIdByAreaId, zoneDB, areaId)
            return ok and m or nil
        end
    end
    return areaToMap[areaId]
end

--- Dungeons by area ID: { name, alternativeAreaIds, parentZone, { { areaId, x, y } } }.
function C.Dungeons()
    local p = zonePrivate()
    if p and type(p.dungeons) == "table" then return p.dungeons end
    local zoneDB = C.QuestieModule("ZoneDB")
    if zoneDB and zoneDB.GetDungeons then
        local ok, list = pcall(zoneDB.GetDungeons, zoneDB)
        if ok and type(list) == "table" then return list end
    end
    return {}
end

--------------------------------------------------------------------------------------------
-- Quest XP (QuestieDB's Forever XP table, scaled to your level the way Questie does it)
--------------------------------------------------------------------------------------------

local function xpTable()
    local s = support("QuestXP")
    return s and type(s.db) == "table" and s.db or nil
end

function C.HasXPTable()
    return xpTable() ~= nil
end

-- Buffs that add quest XP: spell ID -> bonus (Well-Rested is per stack).
local XP_BUFFS = { [377749] = 0.5, [46668] = 0.1, [95987] = 0.1, [24705] = 0.1 }
local WELL_RESTED = 429959

local function buffBonus()
    -- Auras can't be read safely in combat or instances on Forever (Questie skips them too).
    if (InCombatLockdown and InCombatLockdown()) or (IsInInstance and IsInInstance()) then return 0 end
    local get = C_UnitAuras and C_UnitAuras.GetAuraDataByIndex
    if not get then return 0 end
    local bonus = 0
    for i = 1, 40 do
        local ok, aura = pcall(get, "player", i, "HELPFUL")
        if not (ok and aura and aura.spellId) then break end
        local ok2, b = pcall(function()
            if aura.spellId == WELL_RESTED then return 0.01 * (aura.applications or 0) end
            return XP_BUFFS[aura.spellId] or 0
        end)
        bonus = bonus + (ok2 and b or 0)
    end
    return bonus
end

--- XP quest `id` gives you at your level, or nil if none (or unknown, or you're max level).
function C.QuestXP(id)
    local db = xpTable()
    if not db then
        local QuestXP = C.QuestieModule("QuestXP")
        if not (QuestXP and QuestXP.GetQuestLogRewardXP) then return nil end
        local ok, xp = pcall(QuestXP.GetQuestLogRewardXP, QuestXP, id)
        return ok and type(xp) == "number" and xp > 0 and xp or nil
    end
    local row = db[id]
    local qLevel, xp = row and row[1], row and row[2]
    if not (qLevel and xp and qLevel > 0 and xp > 0) then return nil end
    local level = UnitLevel("player") or 1
    if GetMaxPlayerLevel and level >= GetMaxPlayerLevel() then return nil end
    -- The scaling is cmangos's, as Questie has it.
    xp = xp * min(10, max(1, 2 * (qLevel - level) + 20)) / 10
    if xp <= 100 then xp = 5 * floor((xp + 2) / 5)
    elseif xp <= 500 then xp = 10 * floor((xp + 5) / 10)
    elseif xp <= 1000 then xp = 25 * floor((xp + 12) / 25)
    else xp = 50 * floor((xp + 25) / 50) end
    xp = floor(xp * (1 + buffBonus()))
    return xp > 0 and xp or nil
end

--------------------------------------------------------------------------------------------
-- Grey quests and quests you can take
--------------------------------------------------------------------------------------------

--- Is a quest of this level grey (trivial) for you? Unknown and scaling (-1) quests aren't.
function C.IsTrivial(questLevel)
    if not questLevel or questLevel == -1 then return false end
    local diff = questLevel - (UnitLevel("player") or 1)
    if diff >= -2 then return false end
    local range = (C_QuestLog and C_QuestLog.GetTrivialRange and C_QuestLog.GetTrivialRange())
        or (GetQuestGreenRange and GetQuestGreenRange()) or 8
    return -diff > range
end

local function isDone(id)
    local f = (C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted) or IsQuestFlaggedCompleted
    return f ~= nil and f(id) == true
end

local function inLog(id)
    if C_QuestLog and C_QuestLog.GetLogIndexForQuestID then
        return C_QuestLog.GetLogIndexForQuestID(id) ~= nil
    end
    return GetQuestLogIndexByID ~= nil and (GetQuestLogIndexByID(id) or 0) > 0
end

local function field(name, id)
    local f = QuestDB[name]
    if not f then return nil end
    local ok, v = pcall(f, id)
    return ok and v or nil
end

local function anyOf(list, test)
    for _, q in ipairs(type(list) == "table" and list or {}) do
        if test(q) then return true end
    end
    return false
end

local function doneOrActive(id) return isDone(id) or inLog(id) end

local function myRaceMask()
    local enum = _G.LibQuestieDB and LibQuestieDB.Enum
    local raceId = UnitRace and select(3, UnitRace("player"))
    return enum and enum.raceMaskById and raceId and enum.raceMaskById[raceId]
end

local function myClassMask()
    local enum = _G.LibQuestieDB and LibQuestieDB.Enum
    local _, token, classId = UnitClass("player")
    local keys = enum and enum.classKeys
    return (keys and token and keys[token]) or (classId and 2 ^ (classId - 1)) or nil
end

local function overlaps(a, b) return AskBot.Data.MasksOverlap(a, b) end

-- Reputation with a faction (0 = neutral; nil if the game won't say).
local function repWith(factionId)
    if C_Reputation and C_Reputation.GetFactionDataByID then
        local ok, data = pcall(C_Reputation.GetFactionDataByID, factionId)
        if ok and data and data.currentStanding then return data.currentStanding end
    end
    if GetFactionInfoByID then
        local ok, name, _, _, _, _, value = pcall(GetFactionInfoByID, factionId)
        if ok and name then return value end
    end
    return nil
end

-- Skill line IDs of professions -> their English names, for requiredSkill.
local SKILLS = { [129] = "First Aid", [164] = "Blacksmithing", [165] = "Leatherworking", [171] = "Alchemy",
    [182] = "Herbalism", [185] = "Cooking", [186] = "Mining", [197] = "Tailoring", [202] = "Engineering",
    [333] = "Enchanting", [356] = "Fishing", [393] = "Skinning", [755] = "Jewelcrafting" }

-- Your rank in a skill, false if you don't have it, nil if the game won't say.
local function skillRank(skillId)
    local name = SKILLS[skillId]
    if not (name and GetNumSkillLines and GetSkillLineInfo) then return nil end
    for i = 1, GetNumSkillLines() do
        local n, isHeader, _, rank = GetSkillLineInfo(i)
        if n == name and not isHeader then return rank or 0 end
    end
    return false
end

local function knowsSpell(id)
    if IsPlayerSpell and IsPlayerSpell(id) then return true end
    return IsSpellKnown ~= nil and IsSpellKnown(id) == true
end

--- Our own version of Questie's IsDoable: completed, race, class, prerequisites, exclusive
--- and follow-up quests, breadcrumbs, reputation, profession and spell requirements.
local function ownIsDoable(id)
    if isDone(id) then return false end

    local races, raceMask = field("requiredRaces", id), myRaceMask()
    if races and races ~= 0 and raceMask and not overlaps(races, raceMask) then return false end
    local classes, classMask = field("requiredClasses", id), myClassMask()
    if classes and classes ~= 0 and classMask and not overlaps(classes, classMask) then return false end

    local single = field("preQuestSingle", id)
    if single and next(single) and not anyOf(single, isDone) then return false end
    if not single then
        for _, pre in ipairs(field("preQuestGroup", id) or {}) do
            if pre < 0 then
                if not isDone(-pre) then return false end
            elseif not isDone(pre) and not anyOf(field("exclusiveTo", pre), isDone) then
                return false
            end
        end
    end

    local parent = field("parentQuest", id)
    if parent and parent ~= 0 and not inLog(parent) then return false end
    local nextQuest = field("nextQuestInChain", id)
    if nextQuest and nextQuest ~= 0 and doneOrActive(nextQuest) then return false end
    if anyOf(field("exclusiveTo", id), doneOrActive) then return false end
    local target = field("breadcrumbForQuestId", id)
    if target and target ~= 0 and doneOrActive(target) then return false end
    if anyOf(field("breadcrumbs", id), inLog) then return false end
    local disabledBy = field("disabledByQuest", id)
    if disabledBy and disabledBy ~= 0 and inLog(disabledBy) then return false end
    local untilDone = field("availableUntilCompleted", id)
    if untilDone and untilDone ~= 0 and isDone(untilDone) then return false end
    local startingWith = field("availableStartingWith", id)
    if startingWith and startingWith ~= 0 and not doneOrActive(startingWith) then return false end

    local minRep, maxRep = field("requiredMinRep", id), field("requiredMaxRep", id)
    if minRep and minRep[1] and (repWith(minRep[1]) or 0) < (minRep[2] or 0) then return false end
    if maxRep and maxRep[1] and (repWith(maxRep[1]) or 0) >= (maxRep[2] or 0) then return false end

    local skill = field("requiredSkill", id)
    if skill and skill[1] then
        local rank = skillRank(skill[1])
        if rank == false or (rank and rank < (skill[2] or 0)) then return false end
    end

    local spell = field("requiredSpell", id)
    if spell and spell ~= 0 then
        local known = knowsSpell(abs(spell))
        if (spell > 0) ~= known then return false end
    end
    return true
end

--- Can you take quest `id` now? Questie's answer while it runs, else ours.
function C.IsDoable(id)
    local questieDB = C.QuestieModule("QuestieDB")
    if questieDB and questieDB.IsDoable then
        local ok, doable = pcall(questieDB.IsDoable, id)
        if ok then return doable == true end
    end
    local ok, doable = pcall(ownIsDoable, id)
    return ok and doable == true
end

C.OwnIsDoable = ownIsDoable -- for tests
