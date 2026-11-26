-- Questions.lua
-- Understanding the question: patterns, normalising, the answer() dispatch, and the entry
-- points AskBot.Ask, AskBot.IsPersonalQuestion and AskBot.AnswerFor.

local _, AskBot = ...
local D = AskBot.Data
local Out = AskBot.Out
local GOLD, GREY, say, targetsById, askerClass = Out.GOLD, Out.GREY, Out.say, Out.targetsById, Out.askerClass
local autoPin, showOnMap = Out.autoPin, Out.showOnMap
local answerTarget, itemName = AskBot.Quests.answerTarget, AskBot.Quests.itemName
local answerQuest, answerItem = AskBot.Quests.answerQuest, AskBot.Quests.answerItem
local answerNpcName, answerLoot = AskBot.Quests.answerNpcName, AskBot.Quests.answerLoot
local answerPrice, answerChain = AskBot.Quests.answerPrice, AskBot.Quests.answerChain
local answerAfter, findDungeon = AskBot.Quests.answerAfter, AskBot.Quests.findDungeon
local answerDungeonPrep, answerWhoHas = AskBot.Quests.answerDungeonPrep, AskBot.Quests.answerWhoHas
local answerQuestStarters, answerRep = AskBot.Quests.answerQuestStarters, AskBot.Quests.answerRep
local STARTER_QUESTIONS, REP_PATTERNS = AskBot.Quests.STARTER_QUESTIONS, AskBot.Quests.REP_PATTERNS
local answerQuestLog, answerQuestsHere = AskBot.Levelling.answerQuestLog, AskBot.Levelling.answerQuestsHere
local answerZones, answerWhereToQuest = AskBot.Levelling.answerZones, AskBot.Levelling.answerWhereToQuest
local answerDungeons, answerPlan = AskBot.Levelling.answerDungeons, AskBot.Levelling.answerPlan
local answerTidy, answerHandInRoute = AskBot.Levelling.answerTidy, AskBot.Levelling.answerHandInRoute
local answerRares, answerGroup = AskBot.Levelling.answerRares, AskBot.Levelling.answerGroup
local answerPerson, HEARTH_QUESTIONS = AskBot.Levelling.answerPerson, AskBot.Levelling.HEARTH_QUESTIONS
local answerHearth = AskBot.Levelling.answerHearth
local trainingQuestion, answerTraining = AskBot.Levelling.trainingQuestion, AskBot.Levelling.answerTraining
local wordSet, gearQuestion = AskBot.GearAnswers.wordSet, AskBot.GearAnswers.gearQuestion
local answerUpgrades, answerIsUpgrade = AskBot.GearAnswers.answerUpgrades, AskBot.GearAnswers.answerIsUpgrade
local isGear, asksUpgrade = AskBot.GearAnswers.isGear, AskBot.GearAnswers.asksUpgrade
local UPGRADE_NAME_PATTERNS = AskBot.GearAnswers.UPGRADE_NAME_PATTERNS
local bagUpgradeQuestion, answerBagUpgrades = AskBot.GearAnswers.bagUpgradeQuestion, AskBot.GearAnswers.answerBagUpgrades
local gatherLookup, answerGather = AskBot.Professions.gatherLookup, AskBot.Professions.answerGather
local answerGatherBest = AskBot.Professions.answerGatherBest
local professionQuestion = AskBot.Professions.professionQuestion
local personalProfession = AskBot.Professions.personalProfession

--------------------------------------------------------------------------------------------
-- Understanding the question
--------------------------------------------------------------------------------------------

local INTENTS = {
    { "whoHas", {
        "^who has (.+)$", "^who needs (.+)$", "^who else has (.+)$", "^who else needs (.+)$",
        "^who in my group has (.+)$", "^who in my group needs (.+)$", "^who in the group has (.+)$",
        "^who is on (.+)$", "^who is doing (.+)$", "^does anyone have (.+)$", "^does anyone need (.+)$",
        "^group progress for (.+)$", "^group progress on (.+)$", "^party progress for (.+)$" } },
    { "prep", {
        "^prep for (.+)$", "^prepare for (.+)$", "^preparing for (.+)$", "^get ready for (.+)$", "^ready for (.+)$",
        "^am i ready for (.+)$", "^(.+) prep$", "^quests for (.+)$", "^quests in (.+)$", "^what quests are in (.+)$",
        "^what quests are there for (.+)$", "^what quests for (.+)$", "^which quests for (.+)$",
        "^dungeon quests for (.+)$", "^(.+) quests$" } },
    { "chain", {
        "^how do i unlock (.+)$", "^how to unlock (.+)$", "^how do i get to (.+)$", "^unlock (.+)$",
        "^why cant i get (.+)$", "^why can i not get (.+)$", "^why dont i have (.+)$", "^what do i need for (.+)$",
        "^what do i need to do before (.+)$", "^what do i need before (.+)$", "^what comes before (.+)$",
        "^what is before (.+)$", "^before (.+)$", "^prerequisites? for (.+)$", "^prereqs? for (.+)$",
        "^requirements for (.+)$", "^chain for (.+)$", "^quest chain for (.+)$", "^(.+) prerequisites?$",
        "^(.+) prereqs?$", "^(.+) chain$" } },
    { "after", {
        "^what comes after (.+)$", "^what is after (.+)$", "^what is next after (.+)$", "^next after (.+)$",
        "^what follows (.+)$", "^what does (.+) unlock$", "^what does (.+) lead to$", "^after (.+)$" } },
    { "loot", {
        "^what does (.+) drop$", "^what do (.+) drop$", "^what drops in (.+)$", "^what drops from (.+)$",
        "^what can i get from (.+)$", "^loot from (.+)$", "^drops from (.+)$", "^loot (.+)$",
        "^(.+) loot table$", "^(.+) loot$" } },
    { "price", {
        "^how much is (.+) worth$", "^how much are (.+) worth$", "^how much does (.+) sell for$",
        "^how much do (.+) sell for$", "^how much is (.+)$", "^how much are (.+)$", "^what is (.+) worth$",
        "^what are (.+) worth$", "^price of (.+)$", "^ah price of (.+)$", "^ah price (.+)$", "^value of (.+)$",
        "^price (.+)$", "^(.+) ah price$", "^(.+) price$", "^(.+) worth$" } },
    { "questEnd", {
        "^who do i turn in (.+) to$", "^who do i hand in (.+) to$", "^where do i turn in (.+)$",
        "^where do i hand in (.+)$", "^turn in (.+)$", "^hand in (.+)$", "^who ends (.+)$",
        "^who completes (.+)$", "^who finishes (.+)$", "^where does (.+) end$", "^where does (.+) finish$" } },
    { "questStart", {
        "^who gives (.+)$", "^who starts (.+)$", "^who offers (.+)$", "^where do i get the quest (.+)$",
        "^where do i get quest (.+)$", "^where can i get the quest (.+)$", "^where can i get quest (.+)$",
        "^where does the quest (.+) start$", "^where does quest (.+) start$", "^where does (.+) start$",
        "^where do i start (.+)$", "^start quest (.+)$", "^quest (.+)$" } },
    { "gather", {
        "^where can i mine (.+)$", "^where do i mine (.+)$", "^where to mine (.+)$", "^where should i mine (.+)$",
        "^where can i pick (.+)$", "^where do i pick (.+)$", "^where to pick (.+)$", "^where should i pick (.+)$",
        "^where can i gather (.+)$", "^where do i gather (.+)$", "^where to gather (.+)$", "^where can i herb (.+)$",
        "^where can i fish for (.+)$", "^where do i fish for (.+)$", "^where to fish for (.+)$", "^where can i fish (.+)$",
        "^mine (.+)$", "^pick (.+)$", "^gather (.+)$", "^fish for (.+)$",
        "^where are (.+) nodes?$", "^where is (.+) nodes?$", "^where are (.+) veins$", "^(.+) nodes?$" } },
    { "buy", {
        "^where can i buy (.+)$", "^where do i buy (.+)$", "^where to buy (.+)$", "^who sells (.+)$",
        "^where is (.+) sold$", "^where are (.+) sold$", "^what vendor sells (.+)$", "^buy (.+)$",
        "^vendor for (.+)$", "^sells (.+)$" } },
    { "drop", {
        "^where does (.+) drop$", "^where do (.+) drop$", "^what drops (.+)$", "^who drops (.+)$",
        "^what mob drops (.+)$", "^what mobs drop (.+)$", "^where can i farm (.+)$", "^where do i farm (.+)$",
        "^where to farm (.+)$", "^farm (.+)$", "^drops (.+)$", "^drop (.+)$" } },
    { "get", {
        "^where can i get (.+)$", "^where do i get (.+)$", "^where can i find (.+)$", "^where do i find (.+)$",
        "^how do i get (.+)$", "^how to get (.+)$", "^where to get (.+)$", "^where to find (.+)$",
        "^get (.+)$", "^find (.+)$", "^item (.+)$" } },
}

-- Levelling-helper questions, checked before the patterns above.
local SPECIAL = {
    { "group", {
        "^where is my party", "^where are my party", "^where is my group", "^where are my group", "^where is my raid",
        "^where is everyone", "^where is everybody", "^where are my friends", "^where are my mates",
        "^find my party", "^find my group", "^where is the group", "^where is the party", "^party members?$" } },
    { "mineBest", {
        "^where can i mine$", "^where should i mine$", "^where do i mine$", "^where to mine$", "^what can i mine$",
        "^what should i mine$", "^where should i go mining$", "^where to go mining$", "^where can i go mining$",
        "^where should i level mining$", "^where to level mining$", "^where do i level mining$", "^levell?ing mining$",
        "^level mining$", "^mining nodes$", "^ore$", "^ores$" } },
    { "herbBest", {
        "^where can i herb$", "^where should i herb$", "^where do i herb$", "^where to herb$",
        "^where can i pick herbs$", "^where should i pick herbs$", "^where to pick herbs$", "^where can i find herbs$",
        "^where can i gather herbs$", "^where to gather herbs$", "^what herbs can i pick$", "^what herbs can i gather$",
        "^what should i pick$", "^where should i go herbing$", "^where to go herbing$", "^where should i level herbalism$",
        "^where to level herbalism$", "^where do i level herbalism$", "^levell?ing herbalism$", "^level herbalism$",
        "^herbs$", "^herb nodes$" } },
    { "questNext", {
        "^where should i quest", "^where can i quest", "^where to quest", "^where do i quest", "^where shall i quest",
        "^what should i quest", "^where should i go next", "^where should i go now", "^where next$", "^where now$",
        "^where to go next", "^where do i go next", "^quest next$", "^questing next$" } },
    { "handIn", {
        "^hand ?ins?$", "^turn ?ins?$", "^hand ?in route", "^turn ?in route", "^route to hand in", "^where do i hand in$",
        "^where do i turn in$", "^where do i hand in my quests", "^where do i turn in my quests", "^where to hand in$",
        "^where to turn in$", "^where can i hand in$", "^where can i turn in$", "^hand in my quests", "^turn in my quests",
        "^hand in everything", "^turn in everything", "^ready to hand in$", "^what can i hand in", "^what can i turn in" } },
    { "tidy", {
        "^tidy", "^clean ?up", "^clear ?up", "^sort out my quest", "^what should i abandon", "^what can i abandon",
        "^which quests should i abandon", "^what quests should i abandon", "^which quests can i abandon",
        "^what quests can i abandon", "^abandon", "^what should i drop", "^which quests should i drop",
        "^what quests should i drop", "^drop quests", "^my quest log is full", "^quest log full", "^log full",
        "^gr[ae]y quests" } },
    { "zones", {
        "^where should i go at (%d+)$", "^where do i go at (%d+)$", "^where to go at (%d+)$", "^where should i be at (%d+)$",
        "^where next at (%d+)$", "^next zone at (%d+)$", "^zones? debug$", "^zones? for level (%d+)$", "^level (%d+) zones?$", "^where should i level at (%d+)$", "^where to level at (%d+)$",
        "^where should i level", "^where to level", "^where do i level", "^where can i level", "^where should i go$",
        "^zones?$", "^zones? for me$", "^zones? for my level$", "^what zones?", "^which zones?", "^best zones?",
        "^levell?ing zones?", "^where to go$", "^which regions?", "^what regions?", "^best regions?",
        "^levell?ing regions?", "^which areas? should", "^what areas? should", "^which areas? to level",
        "^best places? to level", "^where is the best place to level", "^where is best to level",
        "^best areas? to level", "^best zones? to level" } },
    { "next", {
        "^what is next$", "^whats next$", "^what next$", "^next$", "^what now$", "^what should i do",
        "^what do i do", "^what can i do", "^what to do", "^what shall i do", "^im bored", "^next steps?$" } },
    { "questLog", {
        "^my quests$", "^quest log$", "^questlog$", "^my quest log$", "^todo$", "^to do$", "^my objectives$",
        "^quest objectives$", "^objectives$" } },
    { "questsHere", {
        "^quests$", "^quests here$", "^quests nearby$", "^quests near me$", "^quests around", "^nearby quests$",
        "^new quests", "^available quests", "^any quests", "^what quests", "^which quests", "^find quests",
        "^find me quests", "^find new quests", "^quests for me" } },
    { "dungeons", {
        "^dungeons? for level (%d+)$", "^dungeons? at level (%d+)$", "^level (%d+) dungeons?$",
        "^dungeons?$", "^dungeons? for me$", "^dungeons? for my level$", "^what dungeons?", "^which dungeons?",
        "^recommend a dungeon", "^suggest a dungeon", "^any dungeons" } },
    { "rares", {
        "^rares?$", "^rares? here$", "^rares? nearby$", "^rares? near me$", "^rares? around", "^nearby rares$",
        "^any rares", "^where are the rares", "^rare mobs?" } },
}

local LEADING_NOISE ={ "a ", "an ", "some ", "my ", "the quest ", "quest " }
local TRAILING_NOISE = { " quest", " please", " from" }

local function cleanSubject(s)
    local changed = true
    while changed do
        changed = false
        for _, w in ipairs(LEADING_NOISE) do
            if s:sub(1, #w) == w and #s > #w then s = s:sub(#w + 1); changed = true end
        end
        for _, w in ipairs(TRAILING_NOISE) do
            if s:sub(-#w) == w and #s > #w then s = s:sub(1, -#w - 1); changed = true end
        end
    end
    return s
end

local function normalize(s)
    s = " " .. s:lower() .. " "
    s = s:gsub("(%a)'s ", "%1 is "):gsub("'", ""):gsub("[^%w%s]", " "):gsub("%s+", " ")
    s = s:match("^%s*(.-)%s*$")
    s = s:gsub("^please ", ""):gsub("^askbot ", "")
    return s
end

--- The question's own words around any item links ("is [X] better for tank" -> "is better for tank").
local function wordsOutsideLinks(question)
    return normalize((question:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|H.-|h.-|h", " "):gsub("|r", "")))
end

-- SPECIAL answers that read the asker's own quest log or position, so "!ask" can't use them.
local PERSONAL_SPECIAL = { next = true, questLog = true, handIn = true, tidy = true, questsHere = true,
    questNext = true, zones = true }

local function hasKey(q, key)
    q = " " .. q .. " "
    if #key <= 3 then
        return q:find(" " .. key .. " ", 1, true) ~= nil
    end
    return q:find(" " .. key, 1, true) ~= nil
end

local function findTarget(q)
    for _, t in ipairs(AskBot.targets) do
        for _, key in ipairs(t.keys) do
            if hasKey(q, key) then return t end
        end
    end
    for _, key in ipairs(AskBot.classTrainerKeys) do
        if hasKey(q, key) then
            local classFile = askerClass()
            return targetsById[classFile]
        end
    end
end

local function exactHits(list, query)
    local hits, others = D.FindByName(list, query)
    if hits and hits[1][1] == D.NameKey(query) then return hits, others end
end

local NPC_PREFIXES = { "where is ", "where are ", "who is ", "find ", "where can i find ", "where do i find " }

-- Answers for each SPECIAL entry, given the pattern's capture and the question. (A table, not
-- an if-chain in answer(): Lua allows a function at most 60 upvalues.)
local SPECIAL_ANSWERS = {
    group = function() return answerGroup() end,
    mineBest = function() return answerGatherBest("Mining") end,
    herbBest = function() return answerGatherBest("Herbalism") end,
    next = function() return answerPlan() end,
    questLog = function() return answerQuestLog() end,
    handIn = function() return answerHandInRoute() end,
    tidy = function() return answerTidy() end,
    questNext = function() return answerWhereToQuest() end,
    questsHere = function()
        local r = answerQuestsHere()
        if r then autoPin(r.place, r.spawn, "quests") end
    end,
    zones = function(arg, q)
        local r = answerZones(tonumber(arg), nil, nil, q:find("debug") ~= nil)
        if r then autoPin(r.place, r.spawn, "quests") end
    end,
    dungeons = function(arg) return answerDungeons(tonumber(arg)) end,
    rares = function() return answerRares() end,
}

local function answer(question)
    -- A recipe from a profession window, "[Blacksmithing: Bronze Shortsword]": mats and profit.
    local craftQ = AskBot.Professions.craftLinkQuestion(question)
    if craftQ then return answer(craftQ) end
    -- Shift-clicked item or quest links carry their IDs.
    local itemId = question:match("|Hitem:(%d+)")
    local questId = question:match("|Hquest:(%d+)") or question:match("|Hquestie:(%d+)")
    local plain = question:gsub("|H.-|h%[?(.-)%]?|h", "%1"):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    -- Questie quest links can arrive as plain text, "[[15] Hilary's Necklace (3741)]": the
    -- level may read "15+", "60D" etc., and the "(id)" only shows if Questie is set to show IDs.
    questId = questId or plain:match("%[%[[^%]]*%][^%[%]]-%((%d+)%)%]")
    plain = plain:gsub("%[%[[^%]]*%]%s*([^%[%]]-)%s*%(%d+%)%]", "%1"):gsub("%[%[[^%]]*%]%s*([^%[%]]-)%]", "%1")
    local q = normalize(plain)

    local intent, subject
    for _, entry in ipairs(INTENTS) do
        for _, pattern in ipairs(entry[2]) do
            local cap = q:match(pattern)
            if cap then intent, subject = entry[1], cleanSubject(cap); break end
        end
        if intent then break end
    end

    -- "cost to complete [quest]", "what reagent quests are in my level range"
    if questId and AskBot.Levelling.costWords(wordsOutsideLinks(question)) then
        return AskBot.Levelling.answerQuestCost(nil, tonumber(questId))
    end
    local costOf = not questId and AskBot.Levelling.costSubject(q)
    if costOf then return AskBot.Levelling.answerQuestCost(costOf) end
    if not questId and AskBot.Levelling.lockpickQuestsQuestion(q) then return AskBot.Levelling.answerLockpickQuests() end
    if not questId and AskBot.Levelling.reagentQuestsQuestion(q) then
        return AskBot.Levelling.answerReagentQuests(AskBot.Levelling.reagentLogOnly(q))
    end

    if questId then
        if intent == "whoHas" then return answerWhoHas(nil, tonumber(questId)) end
        if intent == "chain" then return answerChain(nil, tonumber(questId)) end
        if intent == "after" then return answerAfter(nil, tonumber(questId)) end
        return answerQuest(nil, intent == "questEnd" and "end" or intent == "questStart" and "start" or "auto", { tonumber(questId) })
    end
    if HEARTH_QUESTIONS[q] then return answerHearth() end
    if STARTER_QUESTIONS[q] then return answerQuestStarters() end
    for _, pattern in ipairs(REP_PATTERNS) do
        local faction = q:match(pattern)
        if faction then return answerRep(faction) end
    end

    -- "show all skinning trainers": answer as usual, then put every place on the map.
    local showAll = q:match("^show all (.+)$") or q:match("^show (.+) on the map$") or q:match("^show (.+) on map$")
        or q:match("^map all (.+)$") or q:match("^put (.+) on the map$") or q:match("^put (.+) on map$")
    if showAll and not AskBot.asker then
        Out.mapCapture = {}
        local ok, err = pcall(answer, showAll)
        local places = Out.mapCapture
        Out.mapCapture = nil
        if not ok then error(err, 0) end
        if #places == 0 then return say(GREY .. "Nothing to put on the map for that.|r") end
        local MAX = 200
        local n = showOnMap(places, showAll, MAX)
        if not n then return say("I need HereBeDragons to put icons on the map.") end
        local total = 0
        for _, p in ipairs(places) do total = total + #(p.spawns or {}) end
        return say("Put " .. n .. " icon" .. (n == 1 and "" or "s") .. " on your map" .. (total > n and (" (first " .. n .. " of " .. total .. ")") or "")
            .. GREY .. ". Click one to pin it; /ab clear removes them.|r")
    end

    -- "what weapon master teaches bows", "where do I learn daggers"
    local wmKind, wmSkill = AskBot.WeaponMasters.Question(q)
    if wmKind and not itemId then return AskBot.WeaponMasters.Answer(wmKind, wmSkill) end

    -- "kill only quests here", "kill and loot quests"
    local killMode = AskBot.Levelling.killQuestsQuestion(q)
    if killMode then return AskBot.Levelling.answerKillQuests(killMode) end

    -- "what skills can I learn": class spells (unless it names a profession or service).
    if trainingQuestion(q) then
        local t = findTarget(q)
        if not t or t.id == askerClass() then return answerTraining() end
    end

    -- Professions: "mats for Linen Bag", "recipe for X", "how do I level tailoring"
    if professionQuestion(q, function() return findTarget(q) ~= nil end) then return end

    if itemId then
        local id = tonumber(itemId)
        local hits = { { nil, id, itemName(id) } }
        -- "is [item] an upgrade?", "[item] better for tank?" (the item's name doesn't count)
        local rest = wordsOutsideLinks(question)
        if asksUpgrade(rest) and isGear(id) and not AskBot.asker then return answerIsUpgrade(id, wordSet(rest)) end
        if intent == "price" then return answerPrice(nil, hits) end
        local mode = (intent == "buy" or intent == "drop") and intent or "get"
        answerItem(nil, mode, hits)
        -- A bare shift-clicked piece of gear also says whether it's an upgrade.
        if not intent and rest == "" and isGear(id) then answerIsUpgrade(id, {}, "  ") end
        return
    end

    -- "/ab target": whatever you have targeted, as if you'd typed its name.
    if q == "target" or q == "my target" or q == "this" or q == "who is this" or q == "who is my target" then
        local name = UnitExists and UnitExists("target") and UnitName("target")
        if not name then return say("Target something first, then ask " .. GOLD .. "/ab target|r.") end
        if UnitIsPlayer and UnitIsPlayer("target") then return answerPerson(name:lower()) or say(name .. " is a player.") end
        return answer(name)
    end

    -- "anything in my bags an upgrade?"
    if bagUpgradeQuestion(q) then return answerBagUpgrades(wordSet(q)) end

    -- "is Militia Leggings an upgrade?" by name
    for _, pattern in ipairs(UPGRADE_NAME_PATTERNS) do
        local name = q:match(pattern)
        if name then
            name = name:gsub("^the ", ""):gsub("^my ", "")
            local hits = exactHits(D.itemNames, name)
            if hits and isGear(hits[1][2]) and not AskBot.asker then return answerIsUpgrade(hits[1][2], wordSet(q)) end
        end
    end

    local gearSlots, gearWords = gearQuestion(q)
    if gearSlots then return answerUpgrades(gearSlots, gearWords) end

    -- "best quests" (XP per minute), "quests near The Grizzled Den" (same spot). Looked up on
    -- AskBot.Levelling here: answer() is at Lua's 60-upvalue limit.
    if AskBot.Levelling.bestQuestsQuestion(q) then return AskBot.Levelling.answerBestQuests() end
    local nearQuest = AskBot.Levelling.questsNearSubject(q)
    if nearQuest then return AskBot.Levelling.answerQuestsNear(cleanSubject(nearQuest)) end
    local routeZone = AskBot.Levelling.routeSubject(q)
    if routeZone then return AskBot.Levelling.answerRouteTo(routeZone) end
    local toZone = AskBot.Levelling.questsToSubject(q)
    if toZone then return AskBot.Levelling.answerQuestsTo(toZone) end

    for _, entry in ipairs(SPECIAL) do
        for _, pattern in ipairs(entry[2]) do
            local found, _, arg = q:find(pattern)
            local handler = found and SPECIAL_ANSWERS[entry[1]]
            if handler then return handler(arg, q) end
        end
    end

    -- "where is Buddy": a group or guild member by name
    local person = q:match("^where is (.+)$") or q:match("^where are (.+)$") or q:match("^find (.+)$")
        or q:match("^locate (.+)$")
    if person and answerPerson(person) then return end

    -- "what do I need before Deadmines", "SFK quests": a dungeon. Quest chains need the
    -- dungeon's whole name or short name; anything else is a quest.
    if intent == "whoHas" then return answerWhoHas(subject) end
    if intent == "prep" or intent == "chain" then
        local d = findDungeon(subject, intent == "chain")
        if d then return answerDungeonPrep(d) end
        if intent == "prep" then intent = nil end
    end

    if intent == "gather" or intent == "get" then
        -- "where can I mine copper", "where do I get Peacebloom": a gathering node beats the
        -- item's other sources. Unknown names fall through to the item/NPC/quest search.
        local nodes, _, zone = gatherLookup(subject, intent == "gather" and "fuzzy" or "suffix")
        if nodes then return answerGather(nodes, nil, nil, zone) end
        intent = "get"
    end

    if intent == "chain" then
        return answerChain(subject)
    elseif intent == "after" then
        return answerAfter(subject)
    elseif intent == "loot" then
        return answerLoot(subject)
    elseif intent == "price" then
        return answerPrice(subject)
    elseif intent == "questStart" or intent == "questEnd" then
        return answerQuest(subject, intent == "questEnd" and "end" or "start")
    elseif intent == "buy" or intent == "drop" then
        return answerItem(subject, intent)
    elseif intent == "get" then
        -- "where can I get X": an item with exactly that name, else a service, else anything.
        local hits, others = exactHits(D.itemNames, subject)
        if hits then return answerItem(subject, "get", hits, others) end
        local target = findTarget(subject)
        if target then return answerTarget(target) end
        hits, others = exactHits(D.npcNames, subject)
        if hits then return answerNpcName(hits, others) end
        -- Partial item names: let answerItem pick the candidate that has a known source.
        if D.FindByName(D.itemNames, subject) then return answerItem(subject, "get") end
        return answerQuest(subject, "auto")
    end

    -- No question pattern: a service ("nearest flight master"), an NPC by name, an item, a quest.
    local target = findTarget(q)
    if target then return answerTarget(target) end

    local subject2 = q
    for _, prefix in ipairs(NPC_PREFIXES) do
        if subject2:sub(1, #prefix) == prefix then subject2 = subject2:sub(#prefix + 1); break end
    end
    subject2 = cleanSubject(subject2)
    -- A boss or dungeon name on its own most likely means "what does it drop".
    if AskBot.Loot.status == "ready" and (exactHits(AskBot.Loot.bossNames, subject2) or exactHits(AskBot.Loot.instanceNames, subject2)) then
        return answerLoot(subject2)
    end
    local nodes, _, zone = gatherLookup(subject2)
    if nodes then return answerGather(nodes, nil, nil, zone) end
    local hits, others = exactHits(D.npcNames, subject2)
    if hits then return answerNpcName(hits, others) end
    hits, others = exactHits(D.itemNames, subject2)
    if hits then return answerItem(subject2, "get", hits, others) end
    hits, others = exactHits(D.questNames, subject2)
    if hits then return answerQuest(subject2, "auto") end
    hits, others = D.FindByName(D.npcNames, subject2)
    if hits then return answerNpcName(hits, others) end
    hits, others = D.FindByName(D.questNames, subject2)
    if hits then return answerQuest(subject2, "auto") end
    if D.FindByName(D.itemNames, subject2) then return answerItem(subject2, "get") end
    if answerLoot(subject2, true) then return end

    say("Sorry, I don't know how to answer that yet. Try " .. GOLD .. (AskBot.asker and "!ask help" or "/askbot help") .. "|r.")
end

function AskBot.Ask(msg)
    if D.status == "ready" then
        -- Report errors in chat but still hand them to the error handler, so BugSack sees them.
        xpcall(function() answer(msg) end, function(err)
            say("Something went wrong answering that: " .. tostring(err))
            if geterrorhandler then geterrorhandler()(err) end
        end)
    elseif D.status == "failed" then
        say("I'm not working right now; see the earlier error message.")
    else
        Out.pendingQuestion = msg
        say(string.format("Still reading QuestieDB's data (%d%%), I'll answer in a moment.",
            math.floor(D.progress * 100)))
    end
end

--- Questions only the asker's own AskBot can answer (they need their quest log or gear).
function AskBot.IsPersonalQuestion(question)
    local q = normalize(question)
    if gearQuestion(q) or bagUpgradeQuestion(q) or trainingQuestion(q) then return true end
    if AskBot.Levelling.bestQuestsQuestion(q) or AskBot.Levelling.killQuestsQuestion(q) or AskBot.Levelling.questsNearSubject(q)
        or AskBot.Levelling.questsToSubject(q) or AskBot.Levelling.reagentQuestsQuestion(q)
        or AskBot.Levelling.costSubject(q) or AskBot.Levelling.lockpickQuestsQuestion(q) then return true end
    if question:find("|Hquest") and AskBot.Levelling.costWords(wordsOutsideLinks(question)) then return true end
    if personalProfession(q) then return true end
    if HEARTH_QUESTIONS[q] then return true end
    if STARTER_QUESTIONS[q] then return true end
    if question:find("|Hitem:") and asksUpgrade(wordsOutsideLinks(question)) then return true end
    for _, pattern in ipairs(UPGRADE_NAME_PATTERNS) do
        if q:find(pattern) then return true end
    end
    for _, entry in ipairs(SPECIAL) do
        if PERSONAL_SPECIAL[entry[1]] then
            for _, pattern in ipairs(entry[2]) do
                if q:find(pattern) then return true end
            end
        end
    end
    return false
end

--- Answer a question for someone else (an "!ask" in chat). asker = { name, class, level,
--- origin = { x, y, inst } or nil }. Returns the answer's lines (with AskBot's formatting).
function AskBot.AnswerFor(question, asker)
    if D.status ~= "ready" then return { "I'm still starting up, ask again in a moment." } end
    local lines = {}
    Out.outputSink, AskBot.asker, D.originOverride = lines, asker, asker.origin or false
    local ok, err = pcall(answer, question)
    Out.outputSink, AskBot.asker, D.originOverride = nil, nil, nil
    if not ok then
        if geterrorhandler then geterrorhandler()(err) end
        return { "Something went wrong answering that." }
    end
    return lines
end
