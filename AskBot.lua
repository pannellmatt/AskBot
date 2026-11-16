-- AskBot.lua
-- /askbot <question> (also /ab, /ask): answers "where is" questions from QuestieDB's data,
-- in chat, with clickable [pin] links and a TomTom (or built-in) waypoint for the best answer.
-- This file: start-up, events, slash commands, help and debug commands. The answers live in
-- the files before it in AskBot.toc.

local _, AskBot = ...
local D = AskBot.Data
local Out = AskBot.Out
local QUESTIEDB_CONTRACT, GOLD, GREY, say = Out.QUESTIEDB_CONTRACT, Out.GOLD, Out.GREY, Out.say
local useChatFrameOf, askerClass, askerLevel = Out.useChatFrameOf, Out.askerClass, Out.askerLevel
local clearPins, makeLink = Out.clearPins, Out.makeLink
local itemName, bagCount = AskBot.Quests.itemName, AskBot.Quests.bagCount
local itemLinkText, refreshPrices = AskBot.Quests.itemLinkText, AskBot.Quests.refreshPrices
local groupUnits = AskBot.Quests.groupUnits
local checkRares = AskBot.GearAnswers.checkRares
local professionSkill, recordRecipes = AskBot.Professions.professionSkill, AskBot.Professions.recordRecipes

--------------------------------------------------------------------------------------------
-- Startup
--------------------------------------------------------------------------------------------

--- Run `fn` as a coroutine, one step per frame; then call onDone(ok, err).
local function runInBackground(fn, onDone)
    local co = coroutine.create(fn)
    local driver = CreateFrame("Frame")
    driver:SetScript("OnUpdate", function(self)
        local ok, err = coroutine.resume(co)
        if not ok or coroutine.status(co) == "dead" then
            self:SetScript("OnUpdate", nil)
            onDone(ok, err)
        end
    end)
end

local function startIndexing()
    D.status = "indexing"
    if _G.AtlasLoot then AskBot.Loot.status = "loading" end
    runInBackground(D.BuildIndex, function(ok, err)
        if not ok then
            D.status = "failed"
            say("Indexing failed: " .. tostring(err))
            return
        end
        D.status = "ready"
        D.progress = 1
        if Out.pendingQuestion then
            local q = Out.pendingQuestion
            Out.pendingQuestion = nil
            AskBot.Ask(q)
        end
        -- Optional: AtlasLoot loot tables (they also add gear names to the item index).
        if _G.AtlasLoot then
            runInBackground(AskBot.Loot.Build, function(lootOk, lootErr)
                if not lootOk then
                    AskBot.Loot.status = "absent"
                    say("Couldn't read AtlasLoot's data: " .. tostring(lootErr))
                    if geterrorhandler then geterrorhandler()(lootErr) end
                end
                -- Then its crafting tables (professions answers fall back to your recipe window).
                runInBackground(AskBot.Crafts.Build, function(craftOk, craftErr)
                    if not craftOk then
                        AskBot.Crafts.status = "absent"
                        if geterrorhandler then geterrorhandler()(craftErr) end
                    end
                end)
            end)
        end
    end)
end

-- Questie builds its zone tables during its own staged start-up, so wait for it.
local function waitForQuestie()
    local waited = 0
    local ticker
    ticker = C_Timer.NewTicker(1, function()
        waited = waited + 1
        local ready = Questie and Questie.started and QuestieLoader and _G.LibQuestieDB
            and _G.NpcDB and _G.QuestDB and _G.ItemDB and _G.ObjectDB
        if not ready then
            if waited >= 180 then
                ticker:Cancel()
                D.status = "failed"
                say("Gave up waiting for Questie to finish loading.")
            end
            return
        end
        ticker:Cancel()

        local ok, msg = LibQuestieDB.RequireContract(QUESTIEDB_CONTRACT)
        if not ok then
            D.status = "failed"
            say("This QuestieDB version isn't compatible: " .. tostring(msg))
            return
        end

        local hbd = LibStub and LibStub("HereBeDragons-2.0", true)
        local zoneDB = QuestieLoader:ImportModule("ZoneDB")
        local flags = LibQuestieDB.Enum and LibQuestieDB.Enum.npcFlags
        if not hbd or not zoneDB or not flags then
            D.status = "failed"
            say("Missing a piece from Questie (HereBeDragons, ZoneDB or NPC flags).")
            return
        end
        D.Init(hbd, zoneDB, flags)
        startIndexing()
    end)
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("TAXIMAP_OPENED")
events:RegisterEvent("AUCTION_HOUSE_SHOW")
events:RegisterEvent("ZONE_CHANGED_NEW_AREA")
-- Profession window events differ between clients (classic trade skills and crafts, or the
-- modern C_TradeSkillUI); registering one the client lacks is an error, so try each.
for _, event in ipairs({ "TRADE_SKILL_SHOW", "TRADE_SKILL_UPDATE", "TRADE_SKILL_LIST_UPDATE",
    "TRADE_SKILL_DATA_SOURCE_CHANGED", "CRAFT_SHOW", "CRAFT_UPDATE", "UPDATE_MOUSEOVER_UNIT", "PLAYER_TARGET_CHANGED",
    "UNIT_SPELLCAST_SUCCEEDED", "PLAYER_ENTERING_WORLD", "HEARTHSTONE_BOUND", "TRAINER_SHOW", "TRAINER_UPDATE",
    "LEARNED_SPELL_IN_TAB" }) do
    local valid = not (C_EventUtils and C_EventUtils.IsEventValid) or C_EventUtils.IsEventValid(event)
    if valid then pcall(events.RegisterEvent, events, event) end
end
local recordTimer, trainerTimer
local hearthPending

-- Questie has no creature types, so remember which NPCs the game calls beasts as you meet
-- them (account-wide: AskBotDB.creatureTypes[npcId] = 1 beast / 0 not). Skinning uses it.
local beastTypeName
local function learnCreature(unit)
    if not (UnitExists and UnitExists(unit)) or (UnitIsPlayer and UnitIsPlayer(unit)) or not UnitCreatureType then return end
    local guid = UnitGUID and UnitGUID(unit)
    local npcId = guid and tonumber(guid:match("^Creature%-%d+%-%d+%-%d+%-%d+%-(%d+)"))
    if not npcId then return end
    local ctype = UnitCreatureType(unit)
    if not ctype then return end
    if not beastTypeName then
        local info = C_CreatureInfo and C_CreatureInfo.GetCreatureTypeInfo and C_CreatureInfo.GetCreatureTypeInfo(1)
        beastTypeName = info and info.name or "Beast"
    end
    AskBotDB = AskBotDB or {}
    AskBotDB.creatureTypes = AskBotDB.creatureTypes or {}
    AskBotDB.creatureTypes[npcId] = (ctype == beastTypeName or ctype == "Beast") and 1 or 0
end
events:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_LOGIN" then
        AskBotCharDB = AskBotCharDB or {}
        AskBotCharDB.knownTaxi = AskBotCharDB.knownTaxi or {}
        waitForQuestie()
    elseif event == "TAXIMAP_OPENED" then
        local ok, learned = pcall(D.RecordTaxiNodes)
        if ok and learned and learned > 0 then
            say("Learned " .. learned .. " flight path" .. (learned == 1 and "" or "s") .. " for route planning.")
        end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        -- Hearthstone used: where you arrive is where it goes (a loading screen may come first).
        local unit, _, spellId = ...
        if unit == "player" and spellId == 8690 then
            hearthPending = true
            C_Timer.After(3, function()
                if hearthPending then hearthPending = false; pcall(D.RecordBind) end
            end)
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        if hearthPending then
            C_Timer.After(1, function()
                if hearthPending then hearthPending = false; pcall(D.RecordBind) end
            end)
        end
    elseif event == "HEARTHSTONE_BOUND" then
        -- Set at an inn: you're standing next to it.
        C_Timer.After(0.5, function() pcall(D.RecordBind) end)
    elseif event == "UPDATE_MOUSEOVER_UNIT" or event == "PLAYER_TARGET_CHANGED" then
        pcall(learnCreature, event == "UPDATE_MOUSEOVER_UNIT" and "mouseover" or "target")
    elseif event:find("^TRADE_SKILL") or event:find("^CRAFT") then
        -- The window fires many updates; read it once things settle.
        local kind = event:find("^CRAFT") and "craft" or "trade"
        if recordTimer then recordTimer:Cancel() end
        recordTimer = C_Timer.NewTimer(0.5, function()
            local ok, err = pcall(recordRecipes, kind)
            if not ok and geterrorhandler then geterrorhandler()(err) end
        end)
    elseif event == "TRAINER_SHOW" or event == "TRAINER_UPDATE" then
        if trainerTimer then trainerTimer:Cancel() end
        trainerTimer = C_Timer.NewTimer(0.3, function()
            local ok, err = pcall(AskBot.RecordTraining)
            if not ok and geterrorhandler then geterrorhandler()(err) end
            ok, err = pcall(AskBot.WeaponMasters.Record)
            if not ok and geterrorhandler then geterrorhandler()(err) end
        end)
    elseif event == "LEARNED_SPELL_IN_TAB" then
        pcall(AskBot.LearnedSpell, (...))
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        -- Let the map settle before asking which zone this is.
        C_Timer.After(3, function()
            local ok, err = pcall(checkRares)
            if not ok and geterrorhandler then geterrorhandler()(err) end
        end)
    elseif event == "AUCTION_HOUSE_SHOW" then
        -- A refresh was asked for away from the AH; give Auctionator a moment to set up.
        if AskBotCharDB and AskBotCharDB.refreshPending then
            C_Timer.After(1.5, function() refreshPrices(true) end)
        end
    end
end)

--------------------------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------------------------

local function help()
    say("Ask me where things are. Levelling: " .. GOLD .. "/ab what should I do|r, " .. GOLD .. "/ab my quests|r, "
        .. GOLD .. "/ab where should I quest next|r, " .. GOLD .. "/ab quests here|r, " .. GOLD .. "/ab zones|r, " .. GOLD .. "/ab dungeons|r, " .. GOLD .. "/ab rares|r. Examples:")
    say("  /askbot hand in route    /askbot which quests should I abandon    /askbot where should I go at 24")
    say("  /askbot where is my nearest skinning trainer")
    say("  /askbot nearest flight master    /askbot where's my class trainer")
    say("  /askbot who gives The Defias Brotherhood    /askbot turn in Bounty on Murlocs")
    say("  /askbot where can I buy Coarse Thread    /askbot where does Linen Cloth drop")
    say("  /askbot where is Gryan Stoutmantle    /askbot [shift-click an item or quest]")
    say("  /askbot what does VanCleef drop    /askbot Deadmines loot    /askbot price of Linen Cloth")
    say("  /askbot what do I need before [quest]    /askbot what comes after [quest]")
    say("  /askbot what do I need before Deadmines    /askbot who has [quest]")
    say("  /askbot where can I mine copper    /askbot Peacebloom    /askbot where should I mine")
    say("  /askbot upgrades    /askbot upgrades legs    /askbot what gear should I get as a feral druid")
    say("  /askbot is [item] an upgrade    /askbot anything in my bags an upgrade    /askbot target")
    say("  /askbot what skills can I learn")
    say("  /askbot recipe for Linen Bag    /askbot mats for 5 Linen Bag    /askbot how do I level tailoring")
    say("  /askbot show all skinning trainers    /askbot hearth    /askbot again    /askbot history")
    say("  /askbot quests for Stormwind rep    /askbot quest starters")
    say("  /askbot where is my party    /askbot where is <name>")
    say("Click " .. "|cff71d5ff[pin]|r" .. " on any answer to put a pin on it.")
    say("/askbot clear - remove the pin.  /askbot status - index info.  Also /ab and /ask.")
    say("/askbot refresh prices - re-check prices you've asked about (now at the AH, or on your next visit).")
    say("/askbot options - settings.  /askbot share - let friends ask with \"!ask <question>\" in guild/party chat.")
end

local function status()
    local _, assumed = D.FlightMasters()
    local known = 0
    for _ in pairs(AskBotCharDB and AskBotCharDB.knownTaxi or {}) do known = known + 1 end
    say(string.format("Status: %s (%d%%). %d services/trainers, %d NPC, %d quest and %d item names.",
        D.status, math.floor(D.progress * 100), D.npcCount, #D.npcNames, #D.questNames, #D.itemNames))
    say(assumed and "Flight paths: none learned yet, so I assume you have them all. Open a flight map to teach me."
        or ("Flight paths: " .. known .. " known."))
    local L = AskBot.Loot
    local loot = L.status == "absent" and "not installed" or L.status == "loading" and "loading..."
        or string.format("%d dungeons/raids, %d bosses", #L.instances, #L.bossNames)
    local watched = #AskBot.Prices.WatchedIds()
    say("AtlasLoot: " .. loot .. ".  Auctionator: " .. (AskBot.Prices.Available()
        and ("yes, " .. watched .. " price" .. (watched == 1 and "" or "s") .. " on your refresh list"
            .. (AskBotCharDB.refreshPending and " (refresh at next AH visit)" or ""))
        or "not installed") .. ".")
    if D.status == "ready" then
        local parts = {}
        for _, t in ipairs(AskBot.targets) do
            parts[#parts + 1] = t.label .. " " .. (D.byTarget[t.id] and #D.byTarget[t.id] or 0)
        end
        say(GREY .. table.concat(parts, ", ") .. "|r")
    end
end


--- /ab debug item <link or ID>: the stats the game reports for an item, and how AskBot scores it.
local function debugItem(text)
    local id = tonumber(text:match("|Hitem:(%d+)") or text:match("^%s*(%d+)%s*$"))
    if not id then return say("Which item? /ab debug item [item link or ID]") end
    local G = AskBot.Gear
    AskBot.Gear.Load({ id }, function()
        local classFile = askerClass()
        local spec = G.Spec(classFile, {})
        local group, req, needs = G.Check(id, classFile, askerLevel(), G.Skills())
        local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
        local link = getInfo and select(2, getInfo(id))
        say("Item " .. id .. " " .. itemLinkText(id) .. ": slot " .. tostring(group) .. ", needs level " .. tostring(req)
            .. (needs and (", " .. needs) or ""))
        local parts = {}
        local getStats = (C_Item and C_Item.GetItemStats) or GetItemStats
        local ok, stats = pcall(getStats, link)
        for stat, value in pairs(ok and type(stats) == "table" and stats or {}) do
            parts[#parts + 1] = stat .. (G.STAT_KEYS[stat] and "" or "(?)") .. "=" .. tostring(value)
        end
        table.sort(parts)
        say("  stats: " .. (#parts > 0 and table.concat(parts, ", ") or "none reported"))
        if link then
            local merged, fromTooltip = G.Stats(link)
            local extra = {}
            for key in pairs(fromTooltip) do extra[#extra + 1] = key .. "=" .. merged[key] end
            table.sort(extra)
            if #extra > 0 then say("  from Equip: lines: " .. table.concat(extra, ", ")) end
        end
        say("  score for " .. (spec and spec.name or "?") .. ": " .. tostring(spec and link and G.Score(link, spec.weights, group == "ranged")))
    end)
end

--- /ab debug quest <link or name>: what Questie's data holds for a quest's objectives.
local function debugQuest(text)
    local id = tonumber(text:match("|Hquest:(%d+)") or text:match("|Hquestie:(%d+)") or text:match("%((%d+)%)%]")
        or text:match("^%s*(%d+)%s*$"))
    if not id then
        local plain = text:gsub("|H.-|h%[?(.-)%]?|h", "%1"):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
        plain = plain:gsub("%[%[[^%]]*%]%s*", ""):gsub("[%[%]]", "")
        local hits = D.FindByName(D.questNames, plain)
        id = hits and hits[1][2]
    end
    if not id or not QuestDB.name(id) then return say("Which quest? /ab debug quest [quest link, name or ID]") end

    say("Quest " .. id .. " " .. GOLD .. QuestDB.name(id) .. "|r, level " .. tostring(QuestDB.questLevel(id)))
    local o = QuestDB.objectives(id) or {}
    local function count(list) return list and #list or 0 end
    for _, c in ipairs(o[1] or {}) do
        local p = D.NpcPlace(c[1])
        say("  kill npc " .. c[1] .. " " .. tostring(p and p.name) .. ": " .. (p and #p.spawns or 0) .. " spawns")
    end
    for _, c in ipairs(o[2] or {}) do
        local p = D.ObjectPlace(c[1])
        say("  use object " .. c[1] .. " " .. tostring(p and p.name) .. ": " .. (p and #p.spawns or 0) .. " spawns")
    end
    for _, c in ipairs(o[3] or {}) do
        say("  collect item " .. c[1] .. " " .. itemName(c[1]) .. ": dropped by " .. count(ItemDB.npcDrops(c[1]))
            .. " npcs, " .. count(ItemDB.objectDrops(c[1])) .. " objects, inside " .. count(ItemDB.itemDrops(c[1]))
            .. " items" .. (AskBot.KNOWN.items[c[1]] and ", has a community location" or ""))
    end
    for _, c in ipairs(o[5] or {}) do
        say("  kill credit " .. tostring(c[2]) .. " from " .. count(c[1]) .. " npcs")
    end
    for _, itemId in ipairs(QuestDB.requiredSourceItems and QuestDB.requiredSourceItems(id) or {}) do
        say("  bring item " .. itemId .. " " .. itemName(itemId) .. ": " .. bagCount(itemId) .. " in your bags, dropped by "
            .. count(ItemDB.npcDrops(itemId)) .. " npcs, " .. count(ItemDB.objectDrops(itemId)) .. " objects"
            .. (AskBot.KNOWN.items[itemId] and ", has a community location" or ""))
    end
    local trigger = QuestDB.triggerEnd(id)
    if trigger then say("  explore: " .. tostring(trigger[1]) .. ", " .. #D.ResolveSpawns(trigger[2]) .. " spots") end
    local extras = QuestDB.extraObjectives and QuestDB.extraObjectives(id)
    for _, e in ipairs(type(extras) == "table" and extras or {}) do
        say("  extra: " .. tostring(e[3]) .. ", " .. #D.ResolveSpawns(e[1]) .. " spots")
    end
end

local SHARE_OPTIONS ={ guild = "shareGuild", party = "shareParty", raid = "shareParty", whisper = "shareWhisper",
    whispers = "shareWhisper" }

--- /ab share [guild|party|whisper] [on|off]
local function shareCommand(cmd)
    local where, onoff = cmd:match("^share%s*(%a*)%s*(%a*)$")
    local key = SHARE_OPTIONS[where or ""]
    if key and (onoff == "on" or onoff == "off") then
        AskBot.SetOption(key, onoff == "on")
    elseif where ~= "" and where ~= nil then
        return say("Usage: /ab share guild|party|whisper on|off")
    end
    local function state(k) return AskBot.Option(k) and "|cff66cc33on|r" or "|cffff6060off|r" end
    say("Answering \"!ask <question>\" from others: guild " .. state("shareGuild") .. ", party/raid "
        .. state("shareParty") .. ", whispers " .. state("shareWhisper") .. ".")
    say(GREY .. "  Change with /ab share guild on (or party, whisper; on/off), or in /ab options.|r")
end

local function onSlash(msg, editBox)
    useChatFrameOf(editBox)
    msg = (msg or ""):match("^%s*(.-)%s*$")
    local cmd = msg:lower()
    if cmd == "" or cmd == "help" then
        help()
    elseif cmd == "clear" then
        clearPins()
        say("Pin cleared.")
    elseif cmd == "status" then
        status()
    elseif cmd == "forget flights" then
        AskBotCharDB.knownTaxi = {}
        say("Forgot known flight paths.")
    elseif cmd == "refresh" or cmd == "refresh prices" or cmd == "refresh ah" or cmd == "refresh auction"
        or cmd == "refresh auctions" or cmd == "refresh auction house" then
        refreshPrices(false)
    elseif cmd == "forget prices" then
        AskBotCharDB.priceWatch, AskBotCharDB.refreshPending = {}, nil
        say("Forgot the price list.")
    elseif cmd == "options" or cmd == "settings" or cmd == "config" then
        if not AskBot.OpenOptions() then
            say("Settings: pin best answer " .. (AskBot.Option("autoPin") and "on" or "off")
                .. ", " .. AskBot.Option("maxResults") .. " results per answer. Sharing: /ab share")
        end
    elseif cmd:match("^share") then
        shareCommand(cmd)
    elseif cmd == "debug share" then
        local last = AskBot.lastAsk
        say("Last !ask: " .. (last and (tostring(last.sender) .. " (GUID " .. tostring(last.guid) .. ") asked \""
            .. tostring(last.question) .. "\", matched " .. tostring(last.unit or "no group member")) or "none yet"))
        for _, unit in ipairs(groupUnits()) do
            if UnitExists(unit) then
                say("  " .. unit .. ": " .. tostring(UnitName(unit)) .. " (GUID " .. tostring(UnitGUID and UnitGUID(unit)) .. ")")
            end
        end
    elseif cmd == "again" or cmd == "repeat" or cmd == "last" then
        local h = AskBotCharDB and AskBotCharDB.history
        if not h or not h[1] then return say("Nothing to ask again yet.") end
        say(GREY .. "Again: " .. h[1] .. "|r")
        AskBot.Ask(h[1])
    elseif cmd == "history" or cmd == "recent" then
        local h = AskBotCharDB and AskBotCharDB.history or {}
        if not h[1] then return say("No questions yet.") end
        local parts = {}
        for i = 1, math.min(10, #h) do
            local question = h[i]
            parts[#parts + 1] = makeLink(question, function() AskBot.Ask(question) end)
        end
        say("Recent questions: " .. table.concat(parts, " "))
    elseif cmd:match("^debug skills") then
        say("Skill APIs: GetSkillLineInfo " .. (GetSkillLineInfo and "yes" or "no") .. ", GetProfessions "
            .. (GetProfessions and "yes" or "no") .. ", GetTradeSkillLine " .. (GetTradeSkillLine and "yes" or "no")
            .. ", C_TradeSkillUI " .. (C_TradeSkillUI and "yes" or "no") .. ", GetCraftInfo " .. (GetCraftInfo and "yes" or "no") .. ".")
        local found = {}
        for _, p in ipairs({ "Tailoring", "Leatherworking", "Blacksmithing", "Alchemy", "Enchanting", "Engineering",
            "Cooking", "First Aid", "Mining", "Herbalism", "Skinning", "Fishing" }) do
            local r = professionSkill(p)
            if r ~= false then found[#found + 1] = p .. " " .. tostring(r) end
        end
        say("  Skills seen: " .. (#found > 0 and table.concat(found, ", ") or "none"))
        local rec = {}
        for prof, p in pairs(AskBotCharDB and AskBotCharDB.professions or {}) do
            local n = 0
            for _ in pairs(p.recipes or {}) do n = n + 1 end
            rec[#rec + 1] = prof .. " " .. tostring(p.rank) .. "/" .. tostring(p.max) .. " (" .. n .. " recipes)"
        end
        say("  Recipes read: " .. (#rec > 0 and table.concat(rec, ", ") or "none yet (open a profession window)"))
    elseif cmd:match("^debug item") then
        if D.status ~= "ready" then return say("Still loading, try again in a moment.") end
        debugItem(msg:sub(11))
    elseif cmd:match("^debug quest") then
        if D.status ~= "ready" then return say("Still loading, try again in a moment.") end
        debugQuest(msg:sub(12))
    else
        -- Remember it for /ab again and /ab history (newest first, no repeats).
        AskBotCharDB = AskBotCharDB or {}
        local h = AskBotCharDB.history or {}
        for i = #h, 1, -1 do if h[i]:lower() == msg:lower() then table.remove(h, i) end end
        table.insert(h, 1, msg)
        while #h > 15 do table.remove(h) end
        AskBotCharDB.history = h
        AskBot.Ask(msg)
    end
end

SLASH_ASKBOT1 = "/askbot"
SLASH_ASKBOT2 = "/ab"
SLASH_ASKBOT3 = "/ask"
SlashCmdList.ASKBOT = onSlash
