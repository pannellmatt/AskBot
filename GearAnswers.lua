-- GearAnswers.lua
-- Gear answers: upgrades, "is it an upgrade", and rare alerts. The engine is Gear.lua.

local _, AskBot = ...
local D = AskBot.Data
local Out = AskBot.Out
local GearAnswers = {}
AskBot.GearAnswers = GearAnswers
local GOLD, GREY, say, askerClass, askerLevel = Out.GOLD, Out.GREY, Out.say, Out.askerClass, Out.askerLevel
local autoPin, makeLink, pinLink, shortHow = Out.autoPin, Out.makeLink, Out.pinLink, Out.shortHow
local formatRate = Out.formatRate
local questPlaces, turnInPlaces = AskBot.Quests.questPlaces, AskBot.Quests.turnInPlaces
local itemLinkText, questLogEntries = AskBot.Quests.itemLinkText, AskBot.Quests.questLogEntries
local doableQuests, currentZoneMap = AskBot.Levelling.doableQuests, AskBot.Levelling.currentZoneMap

--------------------------------------------------------------------------------------------
-- Gear upgrades: "/ab upgrades", "/ab upgrades legs", "I'm a feral druid, what gear..."
--------------------------------------------------------------------------------------------

local function wordSet(q)
    local w = {}
    for word in q:gmatch("%S+") do w[word] = true end
    return w
end

--- A gear question returns the slot groups it names (possibly none) and its words; else nil.
local function gearQuestion(q)
    local words = wordSet(q)
    local slots = {}
    for word in pairs(words) do
        for _, g in ipairs(AskBot.Gear.SLOT_WORDS[word] or {}) do slots[#slots + 1] = g end
    end
    for phrase, g in pairs({ ["off hand"] = "offhand", ["main hand"] = "onehand", ["two hand"] = "twohand",
        ["one hand"] = "onehand" }) do
        if q:find(phrase, 1, true) then slots[#slots + 1] = g end
    end
    local gearWord = words.upgrade or words.upgrades or words.gear or words.bis or words.equipment or words.wear
    local asksBetter = words.better or words.best or q:find("should i get", 1, true) or q:find("should i go for", 1, true)
        or q:find("should i use", 1, true)
    -- "what boss drops are good for me", "which dungeon loot should I get"
    local lootWord = words.drops or words.loot or words.boss or words.bosses or words.dungeon or words.dungeons
    local forMe = q:find("for me", 1, true) or q:find("good for", 1, true) or words.should or words.worth
    if gearWord or (asksBetter and #slots > 0) or (lootWord and forMe) then return slots, words end
end

--- Which source a gear question is limited to: "boss" (dungeon drops), "quest", "ah", or nil.
local function gearSourceFilter(words)
    if words.boss or words.bosses or words.dungeon or words.dungeons or words.drops or words.drop or words.loot
        or words.instance or words.instances then
        return "boss"
    end
    if words.quest or words.quests then return "quest" end
    if words.ah or words.auction then return "ah" end
end

local SOURCE_ORDER = { quest = 1, boss = 2, ah = 3 }

--- "quest Foo, from Gryan (Westfall, ~1 min) [pin]" for an upgrade's best source, and the
--- ranked place to pin.
local function upgradeSource(c)
    table.sort(c.sources, function(a, b)
        if a.kind ~= b.kind then return SOURCE_ORDER[a.kind] < SOURCE_ORDER[b.kind] end
        if a.kind == "quest" and (a.inLog or false) ~= (b.inLog or false) then return a.inLog or false end
        if a.kind == "boss" then return (a.rate or 0) > (b.rate or 0) end
        return false
    end)
    local s = c.sources[1]
    local text, best
    if s.kind == "quest" then
        local places
        if s.inLog then
            places = turnInPlaces(s.quest)
        else
            local who = QuestDB.startedBy(s.quest) or {}
            places = questPlaces(s.quest, who[1], who[2], true)
        end
        best = D.Rank(places)[1]
        text = "quest " .. GOLD .. (QuestDB.name(s.quest) or "?") .. "|r" .. (s.inLog and " (in your log)" or "")
        if best then
            text = text .. (s.inLog and ", hand in to " or ", from ") .. best.place.name .. " (" .. D.ZoneName(best.spawn.uiMapId)
                .. ", " .. shortHow(best) .. ") " .. pinLink(best.place, best.spawn, QuestDB.name(s.quest))
        end
    elseif s.kind == "boss" then
        local inst = s.boss.instance
        local entrance = AskBot.Loot.EntrancePlace(inst)
        best = entrance and D.Rank({ entrance })[1]
        text = GOLD .. s.boss.name .. "|r" .. formatRate(s.rate) .. ", " .. inst.name
        if best then text = text .. " (" .. shortHow(best) .. ") " .. pinLink(best.place, best.spawn, inst.name) end
    else
        text = "AH " .. AskBot.Prices.Format(s.price)
    end
    if #c.sources > 1 then text = text .. GREY .. " (+" .. (#c.sources - 1) .. " more)|r" end
    return text, best
end

local function answerUpgrades(slots, words)
    local G = AskBot.Gear
    local classFile = askerClass()
    local level = askerLevel()
    local spec, how, summary = G.Spec(classFile, words)
    if not spec then return say("I don't know that class's specs.") end
    local className = UnitClass("player") or classFile

    local quests, inLog = {}, {}
    for _, q in ipairs(questLogEntries()) do
        inLog[q.id] = true
        quests[#quests + 1] = q.id
    end
    for _, id in ipairs(doableQuests(level + G.LEVEL_AHEAD)) do quests[#quests + 1] = id end
    local only = gearSourceFilter(words)
    local candidates = G.Candidates({ classFile = classFile, level = level, quests = quests, inLog = inLog, only = only })
    if #slots > 0 then
        local wanted = {}
        for _, g in ipairs(slots) do wanted[g] = true end
        local kept = {}
        for _, c in ipairs(candidates) do if wanted[c.group] then kept[#kept + 1] = c end end
        candidates = kept
    end

    local function show()
        local current = G.Current(spec.weights, classFile)
        local results = {}
        for _, c in ipairs(candidates) do
            local cur = current[c.group]
            local score = cur and G.Score(c.id, spec.weights, c.group == "ranged")
            if score then
                local gain = score - cur.score
                if gain > math.max(0.5, cur.score * 0.03) then
                    c.gain, c.current = gain, cur.score
                    results[#results + 1] = c
                end
            end
        end
        table.sort(results, function(a, b) return a.gain > b.gain end)

        -- Best per slot (or the top few for the slot asked about).
        local perGroup = #slots > 0 and 3 or 1
        local shown, count = {}, {}
        for _, c in ipairs(results) do
            if (count[c.group] or 0) < perGroup then
                count[c.group] = (count[c.group] or 0) + 1
                shown[#shown + 1] = c
            end
        end

        local FROM = { boss = " from dungeons", quest = " from quests", ah = " on the auction house" }
        local where = #slots > 0 and (" (" .. G.GROUP_LABELS[slots[1]]:lower() .. ")") or ""
        say((only and "Upgrades" .. FROM[only] or "Upgrades") .. " for " .. spec.name .. " " .. className .. where
            .. ", level " .. level .. ":")
        if #shown == 0 then
            local places = { boss = "dungeons near your level", quest = "quests you can do", ah = "the auction house" }
            local list = only and places[only] or ("quests you can do, dungeons near your level"
                .. (AskBot.Prices.Available() and " or the auction house" or ""))
            say(GREY .. "  Nothing better from " .. list .. ", up to level " .. (level + G.LEVEL_AHEAD) .. ".|r")
        end
        local firstBest
        for i = 1, math.min(#shown, AskBot.Option("maxResults") + 3) do
            local c = shown[i]
            local gain = c.current > 0 and ("+" .. math.floor(c.gain / c.current * 100 + 0.5) .. "%") or "empty slot"
            local extra = ""
            if c.req and c.req > level then extra = extra .. GREY .. " (at " .. c.req .. ")|r" end
            if c.needs then
                extra = extra .. " |cffff8040(" .. c.needs .. ")|r"
                if c.needs:find("^train ") then
                    local isArmor = c.needs:find("Mail") or c.needs:find("Shield") or c.needs:find("Leather")
                    local question = isArmor and "my class trainer" or ("weapon master for " .. c.needs:sub(7))
                    extra = extra .. " " .. makeLink(isArmor and "trainer" or "weapon master", function() AskBot.Ask(question) end)
                end
            end
            local sourceText, best = upgradeSource(c)
            -- Pin the best upgrade you can use now (not one that needs training or levels).
            if not c.needs and not (c.req and c.req > level) then firstBest = firstBest or best end
            say("  " .. G.GROUP_LABELS[c.group] .. ": " .. itemLinkText(c.id) .. " " .. gain .. extra .. " - " .. sourceText)
        end
        -- Which dungeons hold the most upgrades (one per slot, counting every boss source).
        local byInst, instList = {}, {}
        for _, c in ipairs(results) do
            for _, s in ipairs(c.sources) do
                if s.kind == "boss" then
                    local inst = s.boss.instance
                    local e = byInst[inst]
                    if not e then
                        e = { inst = inst, groups = {}, labels = {}, gain = 0 }
                        byInst[inst] = e
                        instList[#instList + 1] = e
                    end
                    if not e.groups[c.group] then
                        e.groups[c.group] = true
                        e.labels[#e.labels + 1] = G.GROUP_LABELS[c.group]
                        e.gain = e.gain + c.gain / math.max(c.current, 1)
                    end
                end
            end
        end
        table.sort(instList, function(a, b)
            if #a.labels ~= #b.labels then return #a.labels > #b.labels end
            return a.gain > b.gain
        end)
        local function dungeonText(e)
            local lr = e.inst.levelRange
            local entrance = AskBot.Loot.EntrancePlace(e.inst)
            local r = entrance and D.Rank({ entrance })[1]
            return GOLD .. e.inst.name .. "|r" .. (lr and (" lvl " .. lr[1] .. "-" .. (lr[3] or lr[2])) or "") .. ": "
                .. #e.labels .. " upgrade" .. (#e.labels == 1 and "" or "s") .. " (" .. table.concat(e.labels, ", ") .. ")"
                .. (r and (" - " .. shortHow(r) .. " " .. pinLink(r.place, r.spawn, e.inst.name)) or "")
        end
        if only == "boss" and #instList > 0 then
            say("By dungeon:")
            for i = 1, math.min(3, #instList) do say("  " .. dungeonText(instList[i])) end
        elseif not only and instList[1] then
            say(GREY .. "  Best dungeon:|r " .. dungeonText(instList[1]))
        end

        if how == "guess" then
            local others = {}
            for _, s in ipairs(G.SPECS[classFile]) do
                if s ~= spec then others[#others + 1] = s.words[1] end
            end
            local why = ""
            if summary and summary:find("[1-9]") then why = " from your talents (" .. summary .. ")"
            elseif summary then why = " (no talent points spent yet)" end
            say(GREY .. "  Guessing " .. spec.name .. why
                .. ". For another spec: /ab upgrades as " .. table.concat(others, ", ") .. ".|r")
        end
        if firstBest then autoPin(firstBest.place, firstBest.spawn, "upgrade") end
    end

    local ids = {}
    for _, c in ipairs(candidates) do ids[#ids + 1] = c.id end
    local fetching = G.Load(ids, function()
        xpcall(show, function(err)
            say("Something went wrong answering that: " .. tostring(err))
            if geterrorhandler then geterrorhandler()(err) end
        end)
    end)
    if fetching > 0 then say(GREY .. "Checking " .. fetching .. " items with the server...|r") end
end

--- "+12%", "-5%" or "about the same" for a gain over a current score.
local function gainText(gain, current)
    if current <= 0 then return gain > 0 and "fills an empty slot" or "about the same" end
    local pct = math.floor(gain / current * 100 + 0.5)
    if pct == 0 then return "about the same" end
    return (pct > 0 and "+" or "") .. pct .. "%"
end

--- " (at 25) (train Plate Mail)": when you can use it and what you'd need to learn.
local function verdictExtra(r, level)
    local extra = ""
    if r.req and r.req > level and not (r.needs and r.needs:find(" at ")) then
        extra = extra .. GREY .. " (at " .. r.req .. ")|r"
    end
    if r.needs then extra = extra .. " |cffff8040(" .. r.needs .. ")|r" end
    return extra
end

--- "Arms Warrior", or when Gear.Spec only guessed: "Warrior (no talents yet, scored as Arms)".
local function specLabel(spec, how, summary, className, level)
    if how ~= "guess" then return spec.name .. " " .. className end
    -- Talents start at 10; below that the game may report no talent trees at all.
    local why = (summary and summary:find("[1-9]") and "talents unclear")
        or ((summary or (level and level < 10)) and "no talents yet") or "spec unknown"
    return className .. " (" .. why .. ", scored as " .. spec.name .. ")"
end

--- Does a Gear.Compare result beat what you wear by enough to matter? Half a point and 3%,
--- or 25% better even if the scores are tiny (low-level gear with only armour on it).
local function beatsWorn(r)
    return r.gain > math.max(0.5, r.current * 0.03) or (r.gain > 0 and r.gain >= r.current * 0.25)
end

--- One line on whether item `id` beats what you wear: "[Item] (Legs): upgrade, +35% over
--- [Worn Leggings] for Arms Warrior". Load the item first.
local function upgradeVerdict(id, words)
    local G = AskBot.Gear
    local classFile, level = askerClass(), askerLevel()
    local spec, how, summary = G.Spec(classFile, words or {})
    if not spec then return nil end
    local className = UnitClass("player") or classFile
    local r = G.Compare(id, spec, classFile, level)
    local item = itemLinkText(id)
    if not r.group then
        if r.cannot == "" or not r.cannot then return item .. " isn't something you can wear." end
        return item .. ": " .. className .. "s can't use " .. r.cannot .. "."
    end
    local head = item .. " (" .. G.GROUP_LABELS[r.group] .. "): "
    local extra = verdictExtra(r, level)
    if not r.score then return head .. "I couldn't read its stats yet, ask again in a moment." end
    if not r.gain then return head .. "you wield a two-hander, so an off hand doesn't fit." .. extra end
    local forWho = " for " .. specLabel(spec, how, summary, className, level)
    if r.currentLink and r.currentLink:find("item:" .. id .. ":", 1, true) then
        return head .. "you're wearing it."
    end
    local vs = r.currentLink and (" over " .. r.currentLink) or ""
    if beatsWorn(r) then
        if r.current <= 0 then return head .. "|cff40ff40upgrade|r" .. forWho .. ", fills an empty slot." .. extra end
        return head .. "|cff40ff40upgrade|r, " .. gainText(r.gain, r.current) .. vs .. forWho .. "." .. extra
    end
    return head .. "not an upgrade" .. forWho .. " (" .. gainText(r.gain, r.current)
        .. (r.currentLink and (" vs " .. r.currentLink) or "") .. ")." .. extra
end

--- "is [item] an upgrade?": loads the item, then says the verdict. `prefix` indents it when
--- it follows another answer.
local function answerIsUpgrade(id, words, prefix)
    if AskBot.asker then return end
    AskBot.Gear.Load({ id }, function()
        local ok, line = pcall(upgradeVerdict, id, words)
        if ok and line then say((prefix or "") .. line)
        elseif not ok and geterrorhandler then geterrorhandler()(line) end
    end)
end

--- Is item `id` gear (anything with an equip slot)?
local function isGear(id)
    local f = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    local loc = f and select(4, f(id))
    return loc ~= nil and loc ~= "" and loc ~= "INVTYPE_NON_EQUIP_IGNORE" and loc ~= "INVTYPE_BAG"
        and loc ~= "INVTYPE_AMMO" and loc ~= "INVTYPE_QUIVER" and loc ~= "INVTYPE_TABARD" and loc ~= "INVTYPE_BODY"
end

--- "anything in my bags an upgrade?": a bag word plus an upgrade word.
local function bagUpgradeQuestion(q)
    local w = wordSet(q)
    return (w.bag or w.bags or w.inventory) and (w.upgrade or w.upgrades or w.better or w.equip or w.wear) and true
end

--- Gear in your bags that beats what you wear, biggest gain first. `words` can name a spec.
local function answerBagUpgrades(words)
    if AskBot.asker then return end
    local numSlots = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
    local itemId = (C_Container and C_Container.GetContainerItemID) or GetContainerItemID
    if not numSlots or not itemId then return say("I can't read your bags on this client.") end
    local ids, seen = {}, {}
    for bag = 0, (NUM_BAG_SLOTS or 4) do
        for slot = 1, (numSlots(bag) or 0) do
            local id = itemId(bag, slot)
            if id and not seen[id] and isGear(id) then seen[id] = true; ids[#ids + 1] = id end
        end
    end
    if #ids == 0 then return say("There's no gear in your bags.") end
    local G = AskBot.Gear
    G.Load(ids, function()
        local ok, err = pcall(function()
            local classFile, level = askerClass(), askerLevel()
            local spec, how, summary = G.Spec(classFile, words or {})
            if not spec then return end
            local found = {}
            for _, id in ipairs(ids) do
                local r = G.Compare(id, spec, classFile, level)
                local wearing = r.currentLink and r.currentLink:find("item:" .. id .. ":", 1, true)
                if r.group and r.score and r.gain and not wearing and beatsWorn(r) then
                    found[#found + 1] = { id = id, r = r, pct = r.current > 0 and r.gain / r.current or math.huge }
                end
            end
            local forWho = specLabel(spec, how, summary, UnitClass("player") or classFile, level)
            if #found == 0 then
                return say("Nothing in your bags beats what you wear for " .. forWho .. GREY .. " (" .. #ids .. " item"
                    .. (#ids == 1 and "" or "s") .. " checked).|r")
            end
            table.sort(found, function(a, b) return a.pct > b.pct end)
            say("Upgrades in your bags for " .. forWho .. ":")
            for _, f in ipairs(found) do
                local r = f.r
                say("  " .. itemLinkText(f.id) .. " (" .. G.GROUP_LABELS[r.group] .. "): " .. gainText(r.gain, r.current)
                    .. (r.current > 0 and r.currentLink and (" over " .. r.currentLink) or "") .. verdictExtra(r, level))
            end
        end)
        if not ok and geterrorhandler then geterrorhandler()(err) end
    end)
end

--- Words that ask "is it better than mine?" (with the item's own name taken out).
local function asksUpgrade(rest)
    local w = wordSet(rest)
    return w.upgrade or w.upgrades or w.better or w.equip or w.wear or w.compare or w.bis or w.sidegrade
        or rest:find("worth it", 1, true) or rest:find("worth using", 1, true) or rest:find("should i use", 1, true)
end

local UPGRADE_NAME_PATTERNS = { "^is (.+) an upgrade", "^is (.+) a upgrade", "^is (.+) better", "^is (.+) worth it",
    "^is (.+) worth using", "^should i equip (.+)$", "^should i wear (.+)$", "^should i use (.+)$", "^compare (.+)$",
    "^would (.+) be an upgrade", "^(.+) upgrade$" }

--------------------------------------------------------------------------------------------
-- Rare alerts: entering a zone with a rare near your level that drops an upgrade
--------------------------------------------------------------------------------------------

local rareAlerted = {} -- uiMapId -> GetTime() of the last alert

local function checkRares()
    if D.status ~= "ready" or not AskBot.Option("rareAlerts") or AskBot.asker then return end
    local mapId = currentZoneMap()
    if not mapId then return end
    local now = GetTime and GetTime() or 0
    if rareAlerted[mapId] and now - rareAlerted[mapId] < 1800 then return end
    rareAlerted[mapId] = now
    local level = askerLevel()
    local found, ids = {}, {}
    for npc, items in pairs(D.rareDrops) do
        local lo, hi = NpcDB.minLevel(npc) or 0, NpcDB.maxLevel(npc) or NpcDB.minLevel(npc) or 0
        if hi >= level - 3 and lo <= level + 3 then
            local place = D.NpcPlace(npc)
            local here = {}
            for _, s in ipairs(place and place.spawns or {}) do
                if s.uiMapId == mapId then here[#here + 1] = s end
            end
            if #here > 0 then
                found[#found + 1] = { npc = npc, place = place, spawns = here, items = items, lo = lo, hi = hi }
                for _, id in ipairs(items) do ids[#ids + 1] = id end
            end
        end
    end
    if #found == 0 then return end
    local G = AskBot.Gear
    AskBot.Gear.Load(ids, function()
        local classFile = askerClass()
        local spec = G.Spec(classFile, {})
        if not spec then return end
        local alerts = {}
        for _, f in ipairs(found) do
            for _, id in ipairs(f.items) do
                local r = G.Compare(id, spec, classFile, level)
                if r.gain and not r.needs and (r.req or 0) <= level + 2
                    and r.gain > math.max(0.5, r.current * 0.03) then
                    local rel = r.current > 0 and r.gain / r.current or 1
                    if not f.best or rel > f.rel then f.best, f.rel, f.r = id, rel, r end
                end
            end
            if f.best then alerts[#alerts + 1] = f end
        end
        table.sort(alerts, function(a, b) return a.rel > b.rel end)
        for i = 1, math.min(2, #alerts) do
            local f = alerts[i]
            local place = { kind = f.place.kind, id = f.npc, name = f.place.name, spawns = f.spawns }
            local best = D.Rank({ place })[1]
            local lvl = f.lo == f.hi and f.lo or (f.lo .. "-" .. f.hi)
            say("Rare here: " .. GOLD .. f.place.name .. "|r (" .. lvl .. (D.rares[f.npc] == 2 and " elite" or "")
                .. ") can drop " .. itemLinkText(f.best)
                .. (f.r.current > 0 and (" " .. gainText(f.r.gain, f.r.current) .. " " .. G.GROUP_LABELS[f.r.group]:lower())
                    or (" for your empty " .. G.GROUP_LABELS[f.r.group]:lower() .. " slot"))
                .. (best and (" " .. pinLink(best.place, best.spawn, f.place.name)) or ""))
        end
    end)
end
AskBot.CheckRares = checkRares

-- For the files loaded after this one.
GearAnswers.wordSet, GearAnswers.gearQuestion = wordSet, gearQuestion
GearAnswers.answerUpgrades, GearAnswers.answerIsUpgrade = answerUpgrades, answerIsUpgrade
GearAnswers.isGear, GearAnswers.asksUpgrade = isGear, asksUpgrade
GearAnswers.bagUpgradeQuestion, GearAnswers.answerBagUpgrades = bagUpgradeQuestion, answerBagUpgrades
GearAnswers.UPGRADE_NAME_PATTERNS, GearAnswers.checkRares = UPGRADE_NAME_PATTERNS, checkRares
