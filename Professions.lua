-- Professions.lua
-- Gathering and professions: nodes, recipe sources, mats, skill-up plans, skinning, and
-- recording recipes from the profession window.

local _, AskBot = ...
local D = AskBot.Data
local Out = AskBot.Out
local Professions = {}
AskBot.Professions = Professions
local GOLD, GREY, say, captureForMap, autoPin = Out.GOLD, Out.GREY, Out.say, Out.captureForMap, Out.autoPin
local makeLink, pinLink, shortHow, describe = Out.makeLink, Out.pinLink, Out.shortHow, Out.describe
local pinBest = Out.pinBest
local itemName, answerItem = AskBot.Quests.itemName, AskBot.Quests.answerItem
local itemLinkText, bagCount = AskBot.Quests.itemLinkText, AskBot.Quests.bagCount

--------------------------------------------------------------------------------------------
-- Gathering: mining veins, herbs, fishing schools
--------------------------------------------------------------------------------------------

--- Your rank in a profession: a number, false if you don't have it, nil if unknown
--- (answering someone else, or the skill API is missing).
local function professionSkill(prof)
    if AskBot.asker then return nil end
    if GetNumSkillLines and GetSkillLineInfo then
        for i = 1, GetNumSkillLines() do
            local name, isHeader, _, rank = GetSkillLineInfo(i)
            if name == prof and not isHeader then return rank end
        end
        return false
    end
    -- Modern clients: GetProfessions() gives indexes for GetProfessionInfo().
    if GetProfessions and GetProfessionInfo then
        local list = { GetProfessions() }
        for i = 1, 5 do
            local index = list[i]
            if index then
                local name, _, rank = GetProfessionInfo(index)
                if name == prof then return rank end
            end
        end
        return false
    end
    return nil
end
AskBot.ProfessionSkill = professionSkill

-- Vanilla gathering colours: orange until skill+25, yellow until +50, green until +100.
local function skillColour(rank, req)
    if not rank or not req then return "|cffc0c0c0" end
    if rank < req then return "|cffff4040" end
    if rank < req + 25 then return "|cffff8040" end
    if rank < req + 50 then return "|cffffff00" end
    if rank < req + 100 then return "|cff40c040" end
    return "|cff808080"
end

local function skillLabel(node, rank)
    if not node.skill then return node.prof end
    return skillColour(rank, node.skill) .. node.prof .. " " .. node.skill .. "|r"
end

--- Node names for a gathering subject ("copper", "copper ore", "peacebloom", "tin vein").
--- `mode`: nil for the exact name only; "suffix" also tries adding " ore", " vein" etc.;
--- "fuzzy" also accepts partial names. Returns the node names and the display name matched.
local function gatherLookup(subject, mode)
    subject = subject:gsub("^the ", "")
    local tries = { subject }
    if mode then
        for _, suffix in ipairs({ " ore", " vein", " deposit", " school" }) do tries[#tries + 1] = subject .. suffix end
    end
    for _, t in ipairs(tries) do
        local e = D.gatherKeys[D.NameKey(t)]
        if e then return e.nodes, e.display end
    end
    if mode == "fuzzy" then
        local hits = D.FindByName(D.gatherNames, subject)
        if hits then
            local e = D.gatherKeys[hits[1][1]]
            return e.nodes, e.display
        end
    end
end

--- Nearest node of each type, then the zones with the most spawn points, then a skill check.
local function answerGather(nodeNames, heading, noSkillNote)
    local places, all = {}, {}
    for _, name in ipairs(nodeNames) do
        local p = D.GatherPlace(name)
        if p and #p.spawns > 0 then
            places[#places + 1] = p
            for _, s in ipairs(p.spawns) do all[#all + 1] = s end
        end
    end
    if #places == 0 then
        return say("Questie has no spawn points for " .. GOLD .. table.concat(nodeNames, ", ") .. "|r.")
    end
    if heading then say(heading) end

    local prof = places[1].node.prof
    local rank = professionSkill(prof)
    for _, p in ipairs(places) do p.sub = skillLabel(p.node, rank) end
    captureForMap(places)
    local results, havePosition = D.Rank(places)
    for i = 1, math.min(3, #results) do
        say((heading and "  " or "") .. describe(results[i]))
    end

    -- Where the nodes are thickest: the top zones by spawn points, with travel to each.
    local byZone, zones = {}, {}
    for _, s in ipairs(all) do
        local z = byZone[s.uiMapId]
        if not z then
            z = { spawns = {}, uiMapId = s.uiMapId }
            byZone[s.uiMapId] = z
            zones[#zones + 1] = z
        end
        z.spawns[#z.spawns + 1] = s
    end
    if #zones > 1 then
        table.sort(zones, function(a, b) return #a.spawns > #b.spawns end)
        local parts = {}
        for i = 1, math.min(3, #zones) do
            local z = zones[i]
            local zp = { kind = "object", name = results[1].place.name, spawns = z.spawns }
            local r = D.Rank({ zp })[1]
            local how = r.time and (" (" .. shortHow(r) .. ")") or ""
            parts[#parts + 1] = D.ZoneName(z.uiMapId) .. " " .. #z.spawns .. how .. " " .. pinLink(zp, r.spawn)
        end
        say(GREY .. "  Most nodes:|r " .. table.concat(parts, ", "))
    end

    -- Can you gather it?
    local lowest
    for _, p in ipairs(places) do
        if p.node.skill and (not lowest or p.node.skill < lowest) then lowest = p.node.skill end
    end
    if noSkillNote or prof == "Fishing" then
        -- nothing to add (a "where should I mine" heading already says it)
    elseif rank == false then
        say(GREY .. "  You don't have " .. prof .. ".|r")
    elseif rank and lowest and rank < lowest then
        say(GREY .. "  You need " .. prof .. " " .. lowest .. " (you have " .. rank .. ").|r")
    end
    if not havePosition then
        say(GREY .. "  (No position known, so these aren't sorted by distance.)|r")
    end
    pinBest(results[1])
end

--- "Where should I mine?": the best node type for your skill, and what opens up next.
local function answerGatherBest(prof)
    local rank = professionSkill(prof)
    local best, nextUp = {}, nil
    local target = rank or 1
    local bestSkill
    for name, node in pairs(D.gather) do
        if node.prof == prof and node.skill and not node.special then
            if node.skill <= target and (not bestSkill or node.skill > bestSkill) then bestSkill = node.skill end
        end
    end
    for name, node in pairs(D.gather) do
        if node.prof == prof and node.skill and not node.special then
            if node.skill == bestSkill then best[#best + 1] = name end
            if node.skill > target and (not nextUp or node.skill < nextUp.skill) then nextUp = node end
        end
    end
    if #best == 0 then return say("Questie doesn't list any " .. prof .. " nodes.") end
    table.sort(best)
    local heading
    if rank then
        heading = prof .. " " .. rank .. ": best for skill-ups"
            .. (nextUp and (GREY .. " (" .. nextUp.name .. " at " .. nextUp.skill .. ")|r") or "") .. ":"
    elseif rank == false then
        heading = "You don't have " .. prof .. " yet. Starter nodes:"
    else
        heading = "I can't see your " .. prof .. " skill, so here are the starter nodes:"
    end
    answerGather(best, heading, true)
end

--------------------------------------------------------------------------------------------
-- Professions: recipe sources, mats shopping lists, skill-up plans
--------------------------------------------------------------------------------------------

-- Words for each profession, and whether it's a crafting one (its recipes are recorded
-- from the profession window).
local PROFESSIONS = {
    { "Tailoring", { "tailoring", "tailor" }, craft = true },
    { "Leatherworking", { "leatherworking", "lw", "leatherwork" }, craft = true },
    { "Blacksmithing", { "blacksmithing", "bs", "blacksmith" }, craft = true },
    { "Alchemy", { "alchemy", "alch" }, craft = true },
    { "Enchanting", { "enchanting", "ench", "enchant" }, craft = true },
    { "Engineering", { "engineering", "engi", "eng" }, craft = true },
    { "Cooking", { "cooking", "cook" }, craft = true },
    { "First Aid", { "first aid", "firstaid" }, craft = true },
    { "Mining", { "mining", "mine" } },
    { "Herbalism", { "herbalism", "herb", "herbing" } },
    { "Skinning", { "skinning", "skin" } },
    { "Fishing", { "fishing", "fish" } },
}
local TRAINER_QUESTION = { Tailoring = "nearest tailoring trainer", Leatherworking = "nearest leatherworking trainer",
    Blacksmithing = "nearest blacksmithing trainer", Alchemy = "nearest alchemy trainer",
    Enchanting = "nearest enchanting trainer", Engineering = "nearest engineering trainer",
    Cooking = "nearest cooking trainer", ["First Aid"] = "nearest first aid trainer",
    Mining = "nearest mining trainer", Herbalism = "nearest herbalism trainer",
    Skinning = "nearest skinning trainer", Fishing = "nearest fishing trainer" }

local function professionNamed(text)
    text = " " .. text .. " "
    for _, p in ipairs(PROFESSIONS) do
        for _, w in ipairs(p[2]) do
            if text:find(" " .. w .. " ", 1, true) then return p[1], p.craft end
        end
    end
end

local function trainerLink(prof)
    local question = TRAINER_QUESTION[prof]
    return question and makeLink(prof .. " trainer", function() AskBot.Ask(question) end) or ""
end

--- Recorded recipes: AskBotCharDB.professions[prof] = { rank, max, recipes = { [key] = recipe } },
--- recipe = { name, item (id or nil), made, diff ("optimal"|"medium"|"easy"|"trivial"),
--- reagents = { { id, name, count } } }. Filled whenever a profession window opens.
local function recordedProfessions()
    return AskBotCharDB and AskBotCharDB.professions or {}
end

local function itemIdOf(link)
    return link and tonumber(link:match("|Hitem:(%d+)"))
end

local DIFFICULTY = { [0] = "optimal", [1] = "medium", [2] = "easy", [3] = "trivial" }

--- The modern profession API (C_TradeSkillUI): profession, rank, max, recipes; or nil.
local function readModernRecipes()
    local T = C_TradeSkillUI
    if not (T and T.GetAllRecipeIDs and T.GetRecipeInfo) then return nil end
    local info = (T.GetChildProfessionInfo and T.GetChildProfessionInfo())
    if not (info and info.professionName and info.professionName ~= "") then
        info = T.GetBaseProfessionInfo and T.GetBaseProfessionInfo()
    end
    local prof = info and (info.parentProfessionName or info.professionName)
    if not prof or prof == "" then
        if T.GetTradeSkillLine then prof = T.GetTradeSkillLine() end
        if not prof then return nil end
    end
    local recipes = {}
    for _, rid in ipairs(T.GetAllRecipeIDs() or {}) do
        local ri = T.GetRecipeInfo(rid)
        if ri and ri.learned and ri.name then
            local r = { name = ri.name, diff = DIFFICULTY[ri.relativeDifficulty] or "easy", reagents = {} }
            local schematic = T.GetRecipeSchematic and T.GetRecipeSchematic(rid, false)
            if schematic then
                r.item = schematic.outputItemID
                r.made = schematic.quantityMin
                for _, slot in ipairs(schematic.reagentSlotSchematics or {}) do
                    local reagent = slot.reagents and slot.reagents[1]
                    local id = reagent and reagent.itemID
                    if id then
                        local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)
                        r.reagents[#r.reagents + 1] = { id = id, name = name, count = slot.quantityRequired or 1 }
                    end
                end
            end
            recipes[D.NameKey(ri.name)] = r
        end
    end
    return prof, info and info.skillLevel, info and info.maxSkillLevel, recipes
end

local function recordRecipes(kind)
    local api
    if kind == "craft" then
        api = { line = GetCraftDisplaySkillLine, num = GetNumCrafts, info = GetCraftInfo, link = GetCraftItemLink,
            nReag = GetCraftNumReagents, reag = GetCraftReagentInfo, reagLink = GetCraftReagentItemLink }
    else
        api = { line = GetTradeSkillLine, num = GetNumTradeSkills, info = GetTradeSkillInfo, link = GetTradeSkillItemLink,
            nReag = GetTradeSkillNumReagents, reag = GetTradeSkillReagentInfo, reagLink = GetTradeSkillReagentItemLink,
            made = GetTradeSkillNumMade }
    end
    local prof, rank, max
    local recipes = {}
    if api.line and api.num and api.info then
        prof, rank, max = api.line()
    elseif kind ~= "craft" then
        prof, rank, max, recipes = readModernRecipes()
        recipes = recipes or {}
    end
    if not prof or prof == "UNKNOWN" then return end
    for i = 1, (api.line and api.num and api.info and api.num()) or 0 do
        local name, kindOrSub, diffOrNil = api.info(i)
        -- Trade skills: name, type. Crafts (enchanting): name, subSpellName, type.
        local diff = (kind == "craft") and diffOrNil or kindOrSub
        if name and diff and diff ~= "header" and diff ~= "subheader" then
            local r = { name = name, diff = diff, reagents = {} }
            r.item = api.link and itemIdOf(api.link(i))
            if api.made then r.made = api.made(i) end
            for j = 1, (api.nReag and api.nReag(i)) or 0 do
                local rName, _, count = api.reag(i, j)
                local id = api.reagLink and itemIdOf(api.reagLink(i, j))
                if rName or id then r.reagents[#r.reagents + 1] = { id = id, name = rName, count = count or 1 } end
            end
            recipes[D.NameKey(name)] = r
        end
    end
    if not next(recipes) then return end
    AskBotCharDB = AskBotCharDB or {}
    AskBotCharDB.professions = AskBotCharDB.professions or {}
    -- Merge: collapsed categories and filters hide recipes, and recipes are never unlearned.
    local old = AskBotCharDB.professions[prof]
    if old then for k, r in pairs(old.recipes or {}) do if not recipes[k] then recipes[k] = r end end end
    AskBotCharDB.professions[prof] = { rank = rank, max = max, recipes = recipes, seen = time and time() or 0 }
end
AskBot.RecordRecipes = recordRecipes

--- A recipe you know by (crafted) name: recipe, profession.
local function knownRecipe(name)
    local key = D.NameKey(name)
    for prof, p in pairs(recordedProfessions()) do
        if p.recipes[key] then return p.recipes[key], prof end
    end
    for prof, p in pairs(recordedProfessions()) do
        for k, r in pairs(p.recipes) do
            if k:find(key, 1, true) then return r, prof end
        end
    end
end

--- Price of one reagent: copper, and where ("AH" / "vendor"), or nil.
local function reagentPrice(id)
    local P = AskBot.Prices
    if not id then return nil end
    local vendor = ItemDB.vendors and ItemDB.vendors(id)
    local vb = P and P.VendorBuy and P.VendorBuy(id)
    if vendor and #vendor > 0 and vb then return vb, "vendor" end
    local ah = P and P.Available() and P.Auction(id)
    if ah then return ah, "AH" end
    if vendor and #vendor > 0 then return nil, "vendor" end
end

--- Mats for `count` crafts: lines with what you have and what to buy, and the cost.
local function answerMats(recipe, prof, count)
    count = math.max(1, count or 1)
    local made = recipe.made or 1
    local itemText = recipe.item and itemLinkText(recipe.item) or (GOLD .. recipe.name .. "|r")
    say(itemText .. (count > 1 and (" x" .. count) or "") .. " (" .. prof .. "):"
        .. (made > 1 and (GREY .. " makes " .. made * count .. "|r") or ""))
    local total, unknown, haveAll = 0, false, true
    for _, r in ipairs(recipe.reagents) do
        local need = r.count * count
        local have = bagCount(r.id, true)
        local buy = math.max(0, need - have)
        local name = r.id and itemLinkText(r.id) or r.name or "?"
        local line = "  " .. need .. " " .. name .. ": "
        if buy == 0 then
            line = line .. "|cff40ff40have " .. have .. "|r"
        else
            haveAll = false
            local price, where = reagentPrice(r.id)
            line = line .. (have > 0 and ("have " .. have .. ", ") or "") .. "buy " .. buy
            if price then
                total = total + price * buy
                line = line .. GREY .. " (" .. where .. " " .. AskBot.Prices.Format(price) .. " each)|r"
            elseif where == "vendor" then
                line = line .. GREY .. " (vendors)|r"; unknown = true
            else
                unknown = true
            end
        end
        say(line)
    end
    if haveAll then return say("  You have everything for " .. count .. ".") end
    local summary = "  To buy: " .. (total > 0 and AskBot.Prices.Format(total) or "?") .. (unknown and total > 0 and "+" or "")
    local P = AskBot.Prices
    local sells = recipe.item and P.Available() and P.Auction(recipe.item)
    if sells and total > 0 and not unknown then
        local fullCost = 0
        for _, r in ipairs(recipe.reagents) do fullCost = fullCost + (reagentPrice(r.id) or 0) * r.count end
        local perItem = fullCost / made
        summary = summary .. ". On the AH it sells for " .. P.Format(sells) .. " each, "
            .. (sells > perItem and ("so crafting saves " .. P.Format(math.floor(sells - perItem)) .. " each")
                or ("so buying it is " .. P.Format(math.floor(perItem - sells)) .. " cheaper each"))
    end
    say(summary .. ".")
end

--- AtlasLoot's craft called `name` (one of your professions first), or nil.
local function craftFor(name)
    local C = AskBot.Crafts
    if not C or C.status ~= "ready" then return nil end
    local found = C.Find(name)
    if not found then return nil end
    for _, c in ipairs(found) do
        if professionSkill(c.prof) or recordedProfessions()[c.prof] then return c end
    end
    return found[1]
end

--- A craft in the shape answerMats takes.
local function craftAsRecipe(c)
    local r = { name = AskBot.Crafts.Name(c) or ("spell " .. c.spell), item = c.item, made = c.made, reagents = {} }
    for _, g in ipairs(c.reagents) do r.reagents[#r.reagents + 1] = { id = g.id, count = g.count } end
    return r
end

--- "[Pattern: X]" (a link to where it comes from) or "[Tailoring trainer]".
local function learnFrom(c)
    if c.recipe then
        local id = c.recipe
        return makeLink(itemName(id) or ("recipe " .. id), function() answerItem(nil, "get", { { nil, id, itemName(id) } }) end)
    end
    return trainerLink(c.prof)
end

--- Where to get the recipe for `name`: recipe item sources, or the trainer.
local function answerRecipe(name)
    local known, prof
    if not AskBot.asker then known, prof = knownRecipe(name) end
    if known then
        say("You already know " .. (known.item and itemLinkText(known.item) or (GOLD .. known.name .. "|r")) .. " (" .. prof .. "). "
            .. makeLink("mats", function() answerMats(known, prof, 1) end))
        return
    end
    local c = craftFor(name)
    if c then
        local what = (c.item and itemLinkText(c.item) or (GOLD .. (AskBot.Crafts.Name(c) or name) .. "|r"))
            .. " (" .. c.prof .. " " .. c.learn .. ")"
        local mats = makeLink("mats", function() answerMats(craftAsRecipe(c), c.prof, 1) end)
        if c.recipe then
            say(what .. ": learn it from " .. itemLinkText(c.recipe) .. ". " .. mats)
            answerItem(nil, "get", { { nil, c.recipe, itemName(c.recipe) } })
        else
            say(what .. ": taught by trainers. " .. trainerLink(c.prof) .. " " .. mats)
        end
        return
    end
    local key = D.NameKey(name)
    local hits = {}
    for _, e in ipairs(D.recipeItems) do
        if e[1] == key then hits[#hits + 1] = { nil, e[2], e[3] } end
    end
    if #hits == 0 then
        for _, e in ipairs(D.recipeItems) do
            if e[1]:find(key, 1, true) and #hits < 3 then hits[#hits + 1] = { nil, e[2], e[3] } end
        end
    end
    if #hits > 0 then
        answerItem(nil, "get", { hits[1] })
        if #hits > 1 then
            local more = {}
            for i = 2, #hits do
                local h = hits[i]
                more[#more + 1] = makeLink(h[3], function() answerItem(nil, "get", { h }) end)
            end
            say(GREY .. "  Also: |r" .. table.concat(more, ", "))
        end
        return
    end
    -- No recipe item: a trainer teaches it (if it's craftable at all).
    local mine = {}
    for _, p in ipairs(PROFESSIONS) do
        if p.craft and (professionSkill(p[1]) or recordedProfessions()[p[1]]) then mine[#mine + 1] = trainerLink(p[1]) end
    end
    say("No pattern, plan or recipe item teaches \"" .. name .. "\", so if it's craftable a trainer teaches it."
        .. (#mine > 0 and (" " .. table.concat(mine, " ")) or ""))
end

-- Skinning: skill needed for a mob of `level` (vanilla).
local function skinLevelFor(skill)
    if skill < 100 then return 10 + math.floor(skill / 10) end
    return math.floor(skill / 5)
end

local DIFF_LABEL = { optimal = "|cffff8040orange|r", medium = "|cffffff00yellow|r", easy = "|cff40c040green|r" }

--- How to level a profession.
--- Profession trainer windows: what each recipe costs to train, account-wide (the same for
--- every character): AskBotDB.recipeTraining[NameKey(recipe)] = copper, and the skill it
--- needs: AskBotDB.recipeTrainingLevel[NameKey(recipe)] (Forever moved some: Heavy Grinding
--- Stone is 100, Classic 125).
--- What one craft's mats are worth (AH or vendor price, whether or not you have them),
--- whether a needed mat has no price, and whether your bags and bank hold them all.
-- The auction house's cut of a sale: 5% at the faction AHs (confirmed on Forever from an
-- "Auction successful" mail: 3x 1s 47c sold, 22c cut). Set in Junk.lua.
local AH_CUT = AskBot.Junk.AH_CUT

--- What a mat you already hold is worth to you: what you'd get selling it on the AH (after the
--- cut), or what it costs from a vendor (you'd only buy it again). nil if neither is known.
local function holdValue(id)
    local price, source = reagentPrice(id)
    if source == "AH" then return math.floor(price * (1 - AH_CUT)) end
    return price
end

--- One craft's mats: ones you hold at holdValue, the rest at the buy price. `stock` (item id ->
--- count) overrides your bags and bank. Returns cost, unknown (a mat to buy has no price), inBags.
local function matsValue(reagents, stock)
    local cost, unknown, inBags = 0, false, true
    for _, g in ipairs(reagents) do
        local have = stock and (stock[g.id] or 0) or bagCount(g.id, true)
        local held, buy = math.min(have, g.count), math.max(0, g.count - have)
        if buy > 0 then inBags = false end
        local price, hv = reagentPrice(g.id), holdValue(g.id)
        if held > 0 and hv then cost = cost + hv * held end
        if buy > 0 then
            if price then cost = cost + price * buy else unknown = true end
        end
    end
    return cost, unknown, inBags
end

--- Skill-up chance of one craft at `skill`: 1 for orange, (grey - skill) / (grey - yellow) after.
local function craftChance(c, skill)
    if skill < c.yellow then return 1 end
    return math.max(0.05, (c.grey - skill) / math.max(1, c.grey - c.yellow))
end

--- AtlasLoot's colour thresholds are Classic's; Forever changed some (Coarse Grinding Stone is
--- green at 75, Classic yellow). For a recipe you know, your window recorded its colour at your
--- skill then (p.rank): move the thresholds just enough to agree. Returns the craft (a copy with
--- fitted yellow/green/grey when they moved) and whether your window agrees with AtlasLoot's
--- numbers (only then is the yellow % more than an estimate: a moved threshold is a guess).
local WINDOW_COLOUR = { optimal = "orange", medium = "yellow", easy = "green", trivial = "grey" }
local function fitToWindow(c, p)
    local name = AskBot.Crafts.Name(c)
    local r = name and p and p.recipes and p.recipes[D.NameKey(name)]
    local at = p and p.rank
    if not (r and WINDOW_COLOUR[r.diff] and at) then return c, false end
    local y, g, gr = c.yellow, c.green, c.grey
    if r.diff == "optimal" then
        y = math.max(y, at + 1); g = math.max(g, y); gr = math.max(gr, g)
    elseif r.diff == "medium" then
        y = math.min(y, at); g = math.max(g, at + 1); gr = math.max(gr, g)
    elseif r.diff == "easy" then
        g = math.min(g, at); y = math.min(y, g); gr = math.max(gr, at + 1)
    else
        gr = math.min(gr, at); g = math.min(g, gr); y = math.min(y, g)
    end
    if y == c.yellow and g == c.green and gr == c.grey then return c, true end
    return setmetatable({ yellow = y, green = g, grey = gr }, { __index = c }), false
end

--- Your profession's crafts with thresholds fitted to your window: list of crafts, and a set of
--- the ones whose numbers your window confirms.
local function fittedCrafts(prof, p)
    local list, vouched = {}, {}
    local levels = AskBotDB and AskBotDB.recipeTrainingLevel or {}
    for _, c in ipairs(AskBot.Crafts.byProf[prof]) do
        -- Your trainer said what skill it needs: where it differs from AtlasLoot, move the
        -- colours by the same amount (an estimate until your window shows the recipe).
        local name = AskBot.Crafts.Name(c)
        local lv = name and levels[D.NameKey(name)]
        if lv and lv ~= c.learn then
            local d = lv - c.learn
            c = setmetatable({ learn = lv, yellow = c.yellow + d, green = c.green + d, grey = c.grey + d }, { __index = c })
        end
        local f, ok = fitToWindow(c, p)
        list[#list + 1] = f
        if ok then vouched[f] = true end
    end
    return list, vouched
end

--- What one craft's output sells for: the AH price less the cut, or a vendor's price if that's
--- more. Returns copper (for all `made`) and "AH" / "vendor", or nil.
local function saleValue(item, made)
    local P = AskBot.Prices
    if not (item and P) then return nil end
    local ah = P.Available() and P.Auction(item)
    local net = ah and math.floor(ah * (1 - AH_CUT)) or nil
    local vendor = P.VendorSell and P.VendorSell(item)
    if vendor and (not net or vendor > net) then return vendor * (made or 1), "vendor" end
    if net then return net * (made or 1), "AH" end
end

--- Has a profession trainer window shown any of `prof`'s recipes? (Their costs are recorded.)
local function trainerSeen(prof, trainCosts)
    for _, c in ipairs(AskBot.Crafts.byProf[prof] or {}) do
        local name = AskBot.Crafts.Name(c)
        if name and trainCosts[D.NameKey(name)] then return true end
    end
    return false
end

--- Can a trainer teach craft `c`? Not if a recipe item teaches it. With no recipe item, AtlasLoot
--- can't say (Forever's Sterling Silver Boots come from elsewhere), so once your trainer's window
--- has been seen (`seen`), only what it listed counts; before that, assume a trainer does.
local function trainerTeaches(c, trainCosts, seen)
    if c.recipe then return false end
    if not seen then return true end
    local name = AskBot.Crafts.Name(c)
    return name ~= nil and trainCosts[D.NameKey(name)] ~= nil
end

--- Plays out levelling from `rank` to `target`: each point goes to the craft with the cheapest
--- expected cost per point (mats you hold at their sale value, the rest bought, training paid
--- once), using up your stock as it goes. Orange and yellow crafts you know or a trainer teaches.
--- Returns { steps = { { c, from, to, crafts } }, buy = { [id] = n }, cost, spare = { [id] = n },
--- reached } or nil.
local function planSkillUps(prof, rank, target, known, trainCosts, crafts, withProfit)
    local C = AskBot.Crafts
    local sales = 0
    local function sale(c) return withProfit and saleValue(c.item, c.made) or 0 end
    local stock, startStock, buy, learned = {}, {}, {}, {}
    local function have(id)
        if stock[id] == nil then stock[id] = bagCount(id, true); startStock[id] = stock[id] end
        return stock[id]
    end
    local function isKnown(c)
        local name = C.Name(c)
        return name and known[D.NameKey(name)]
    end
    local function trainCost(c)
        local name = C.Name(c)
        return name and trainCosts[D.NameKey(name)] or 0
    end
    local seen = trainerSeen(prof, trainCosts)
    local steps, cost, skill = {}, 0, rank
    while skill < target do
        local best, bestCost
        for _, c in ipairs(crafts) do
            local colour = C.Colour(c, skill)
            if (colour == "orange" or colour == "yellow") and (isKnown(c) or trainerTeaches(c, trainCosts, seen)) then
                for _, g in ipairs(c.reagents) do have(g.id) end
                local mats, unknown = matsValue(c.reagents, stock)
                if not unknown then
                    local train = (isKnown(c) or learned[c]) and 0 or trainCost(c)
                    local perPoint = (mats - sale(c)) / craftChance(c, skill) + train / math.max(1, c.grey - skill)
                    if not bestCost or perPoint < bestCost then best, bestCost = c, perPoint end
                end
            end
        end
        if not best then break end
        local crafts = 1 / craftChance(best, skill)
        sales = sales + sale(best) * crafts
        if not learned[best] and not isKnown(best) then
            learned[best] = true
            cost = cost + trainCost(best)
        end
        for _, g in ipairs(best.reagents) do
            local need = g.count * crafts
            local fromStock = math.min(have(g.id), need)
            stock[g.id] = stock[g.id] - fromStock
            if need > fromStock then
                buy[g.id] = (buy[g.id] or 0) + need - fromStock
                cost = cost + (reagentPrice(g.id) or 0) * (need - fromStock)
            end
        end
        local last = steps[#steps]
        if last and last.c == best then last.to, last.crafts = skill + 1, last.crafts + crafts
        else steps[#steps + 1] = { c = best, from = skill, to = skill + 1, crafts = crafts } end
        skill = skill + 1
    end
    if #steps == 0 then return nil end
    local spare = {}
    for id, n in pairs(startStock) do
        local left = math.floor(stock[id] + 0.001)
        if left > 0 and n > 0 then spare[id] = left end
    end
    return { steps = steps, buy = buy, cost = cost, spare = spare, reached = skill, sales = sales }
end

--- "Plan to 150: ~28 crafts, ~1g 20s to buy" + recipe ranges, what to buy, what's left to sell.
local function sayPlan(plan, target)
    local C = AskBot.Crafts
    local crafts = 0
    for _, s in ipairs(plan.steps) do crafts = crafts + s.crafts end
    say("  " .. GOLD .. "Plan to " .. plan.reached .. "|r"
        .. (plan.reached < target and (GREY .. " (then nothing orange or yellow I can price)|r") or "")
        .. ": ~" .. math.ceil(crafts - 0.001) .. " crafts, ~" .. AskBot.Prices.Format(math.floor(plan.cost)) .. " to buy"
        .. (plan.sales > 0 and (", sell what you make for ~" .. AskBot.Prices.Format(math.floor(plan.sales))
            .. (plan.sales >= plan.cost and (" |cff40ff40(+" .. AskBot.Prices.Format(math.floor(plan.sales - plan.cost)) .. ")|r")
                or (GREY .. " (costs ~" .. AskBot.Prices.Format(math.floor(plan.cost - plan.sales)) .. ")|r"))) or ""))
    local parts = {}
    for i, s in ipairs(plan.steps) do
        if i > 4 then parts[#parts + 1] = GREY .. "+" .. (#plan.steps - 4) .. " more|r"; break end
        local name = C.Name(s.c) or "?"
        parts[#parts + 1] = s.from .. "-" .. s.to .. " " .. (s.c.item and itemLinkText(s.c.item) or (GOLD .. name .. "|r"))
            .. " x" .. math.ceil(s.crafts - 0.001)
    end
    say("    " .. table.concat(parts, ", "))
    local list = {}
    for id, n in pairs(plan.buy) do list[#list + 1] = { id = id, n = math.ceil(n - 0.001) } end
    table.sort(list, function(a, b) return a.id < b.id end)
    if #list > 0 then
        local p = {}
        for _, e in ipairs(list) do p[#p + 1] = e.n .. " " .. itemLinkText(e.id) end
        say("    Buy: " .. table.concat(p, ", "))
    end
    local spare, value = {}, 0
    for id, n in pairs(plan.spare) do
        local price, source = reagentPrice(id)
        if source == "AH" then
            spare[#spare + 1] = { id = id, n = n }
            value = value + math.floor(price * (1 - AH_CUT)) * n
        end
    end
    table.sort(spare, function(a, b) return a.id < b.id end)
    if #spare > 0 then
        local p = {}
        for _, e in ipairs(spare) do p[#p + 1] = e.n .. " " .. itemLinkText(e.id) end
        say("    " .. GREY .. "Not needed, sell for ~" .. AskBot.Prices.Format(value) .. ":|r " .. table.concat(p, ", "))
    end
end

--- "mats 1s 20c (in bags)", "mats 10c+", "mats ?"
local function matsLabel(e)
    return "mats " .. (e.cost > 0 and AskBot.Prices.Format(e.cost) or (e.unknown and "?" or "free"))
        .. (e.unknown and e.cost > 0 and "+" or "") .. (e.inBags and " |cff40ff40(in bags)|r" or "")
end

local function recordTradeTraining()
    if not (IsTradeskillTrainer and IsTradeskillTrainer() and GetNumTrainerServices and GetTrainerServiceInfo) then return end
    AskBotDB = AskBotDB or {}
    local costs = AskBotDB.recipeTraining or {}
    AskBotDB.recipeTraining = costs
    for i = 1, (GetNumTrainerServices() or 0) do
        local name, a, b = GetTrainerServiceInfo(i)
        local cost = GetTrainerServiceCost and GetTrainerServiceCost(i)
        if name and a ~= "header" and b ~= "header" and type(cost) == "number" then
            costs[D.NameKey(name)] = cost
            local level
            if GetTrainerServiceSkillReq then level = select(2, GetTrainerServiceSkillReq(i)) end
            if type(level) == "number" and level > 0 then
                AskBotDB.recipeTrainingLevel = AskBotDB.recipeTrainingLevel or {}
                AskBotDB.recipeTrainingLevel[D.NameKey(name)] = level
            end
        end
    end
end

local function answerSkillUp(prof, withProfit)
    if prof == "Mining" or prof == "Herbalism" then return answerGatherBest(prof) end
    local rank = professionSkill(prof)
    if prof == "Skinning" then
        if rank == false then return say("You don't have Skinning. " .. trainerLink(prof)) end
        if not rank then
            return say("I can't read your Skinning skill here. You can skin beasts up to level 10 + skill/10 (skill/5 from"
                .. " 100), so skill 50 skins level 15 and 150 skins level 30; the highest you can skin give the most skill-ups.")
        end
        local top = skinLevelFor(rank)
        local lo = math.max(1, top - 4)
        -- Zones with the most beasts in [top - 4, top]: the best skill-up chances.
        local zones = {}
        -- Beasts by name, corrected by what you've seen in game (AskBotDB.creatureTypes).
        local seen = AskBotDB and AskBotDB.creatureTypes or {}
        local ids, inList = {}, {}
        for _, id in ipairs(D.beasts) do
            inList[id] = true
            if seen[id] ~= 0 then ids[#ids + 1] = id end
        end
        for id, v in pairs(seen) do
            if v == 1 and not inList[id] and NpcDB.name(id) then ids[#ids + 1] = id end
        end
        for _, id in ipairs(ids) do
            local minL, maxL = NpcDB.minLevel(id) or 0, NpcDB.maxLevel(id) or NpcDB.minLevel(id) or 0
            if maxL >= lo and minL <= top then
                local place = D.NpcPlace(id)
                for _, s in ipairs(place and place.spawns or {}) do
                    if s.uiMapId and s.wx then
                        local z = zones[s.uiMapId]
                        if not z then z = { mapId = s.uiMapId, count = 0, names = {}, nameList = {}, spawns = {} }; zones[s.uiMapId] = z end
                        z.count = z.count + 1
                        z.spawns[#z.spawns + 1] = s
                        if not z.names[place.name] then z.names[place.name] = true; z.nameList[#z.nameList + 1] = place.name end
                    end
                end
            end
        end
        local list = {}
        for _, z in pairs(zones) do list[#list + 1] = z end
        table.sort(list, function(a, b) return a.count > b.count end)
        say("Skinning " .. rank .. ": you can skin beasts up to level " .. top .. ". Most skill-ups from level " .. lo .. "-" .. top
            .. (#list > 0 and ":" or "."))
        local firstBest
        for i = 1, math.min(3, #list) do
            local z = list[i]
            local best = D.Rank({ { kind = "beasts", name = z.nameList[1], spawns = z.spawns } })[1]
            firstBest = firstBest or best
            say("  " .. i .. ". " .. GOLD .. D.ZoneName(z.mapId) .. "|r: " .. table.concat(z.nameList, ", ", 1, math.min(3, #z.nameList))
                .. (#z.nameList > 3 and GREY .. " +" .. (#z.nameList - 3) .. "|r" or "")
                .. (best and (" - " .. shortHow(best) .. " " .. pinLink(best.place, best.spawn, "skinning")) or ""))
        end
        if firstBest then autoPin(firstBest.place, firstBest.spawn, "skinning") end
        return
    end
    if prof == "Fishing" then
        if rank == false then return say("You don't have Fishing. " .. trainerLink(prof)) end
        return say("Fishing " .. (rank or "?") .. ": every catch can give a skill-up; fish where the zone's fish don't get away. "
            .. trainerLink(prof))
    end
    local p = recordedProfessions()[prof]
    local C = AskBot.Crafts
    if C and C.status == "ready" and C.byProf[prof] then
        if rank == false and not p then return say("You don't have " .. prof .. ". " .. trainerLink(prof)) end
        rank = (rank ~= false and rank) or (p and p.rank)
        if not rank then return say("Open your " .. prof .. " window once so I can see your skill, then ask again.") end
        local known = {}
        for k in pairs(p and p.recipes or {}) do known[k] = true end
        local trainCosts = AskBotDB and AskBotDB.recipeTraining or {}
        local list, nextAt = {}, nil
        local crafts, vouched = fittedCrafts(prof, p)
        local seen = trainerSeen(prof, trainCosts)
        for _, c in ipairs(crafts) do
            local colour = C.Colour(c, rank)
            local name = C.Name(c)
            local isKnown = name and known[D.NameKey(name)]
            -- Not known, no recipe item, and your trainer didn't list it: it comes from somewhere
            -- AskBot can't tell you, so leave it out.
            if not isKnown and not c.recipe and not trainerTeaches(c, trainCosts, seen) then
                colour = nil
            end
            if colour == "orange" or colour == "yellow" then
                local cost, unknown, inBags = matsValue(c.reagents)
                -- "with profit": what the craft sells for comes off its cost.
                local sale = withProfit and c.item and saleValue(c.item, c.made) or nil
                local how = (name and known[D.NameKey(name)]) and 1 or (c.recipe and 3 or 2)
                -- A trainer recipe you haven't learned: add what it costs to train (once a profession
                -- trainer window has shown it), so it ranks fairly against the ones you know.
                local train = how == 2 and name and trainCosts[D.NameKey(name)] or nil
                -- Cost per skill point: orange always gives one, yellow only with chance
                -- (grey - skill) / (grey - yellow); training is paid once, so spread it over the
                -- points the recipe can give before it goes grey.
                local chance = colour == "orange" and 1 or math.max(0.05, (c.grey - rank) / math.max(1, c.grey - c.yellow))
                local perPoint = (cost - (sale or 0)) / chance + (train or 0) / math.max(1, c.grey - rank)
                list[#list + 1] = { c = c, name = name or "?", colour = colour, how = how, cost = cost, unknown = unknown,
                    train = train, chance = chance, perPoint = perPoint, inBags = inBags, vouched = vouched[c], sale = sale }
            elseif colour == "unlearnable" and trainerTeaches(c, trainCosts, seen) and (not nextAt or c.learn < nextAt) then
                nextAt = c.learn
            end
        end
        table.sort(list, function(a, b)
            -- Recipes you know and trainer recipes compete on cost per skill point (orange beats
            -- yellow only when it's no dearer per point); recipe items to hunt down go last.
            if (a.how == 3) ~= (b.how == 3) then return b.how == 3 end
            if a.unknown ~= b.unknown then return not a.unknown end
            if a.perPoint ~= b.perPoint then return a.perPoint < b.perPoint end
            if a.colour ~= b.colour then return a.colour == "orange" end
            if a.how ~= b.how then return a.how < b.how end
            return a.name < b.name
        end)
        local atCap = p and p.max and rank >= p.max
        say(prof .. " " .. rank .. (p and p.max and ("/" .. p.max) or "") .. ": cheapest skill-ups"
            .. (withProfit and (GREY .. " (counting what you can sell them for)|r") or "")
            .. (atCap and (" |cffff8040(at your cap: train the next rank)|r " .. trainerLink(prof)) or "") .. ":")
        if #list == 0 then say(GREY .. "  Nothing orange or yellow at " .. rank .. ".|r") end
        local COLOUR = { orange = "|cffff8040orange|r", yellow = "|cffffff00yellow|r" }
        for i = 1, math.min(5, #list) do
            local e = list[i]
            local c = e.c
            local cost = matsLabel(e)
            if e.sale then
                local net = e.sale - e.cost
                cost = cost .. ", sells " .. AskBot.Prices.Format(e.sale) .. " "
                    .. (net >= 0 and ("|cff40ff40(+" .. AskBot.Prices.Format(net) .. ")|r")
                        or (GREY .. "(-" .. AskBot.Prices.Format(-net) .. ")|r"))
            end
            local how = e.how == 1 and GREY .. "(known)|r" or ("learn: " .. learnFrom(c)
                .. (e.train and (e.train == 0 and " free" or (" " .. AskBot.Prices.Format(e.train))) or ""))
            -- Recipes your window hasn't shown use Classic's thresholds: an estimate ("~").
            local odds = e.colour == "yellow" and (GREY .. " " .. (e.vouched and "" or "~") .. math.floor(e.chance * 100 + 0.5) .. "%|r") or ""
            say("  " .. (c.item and itemLinkText(c.item) or (GOLD .. e.name .. "|r")) .. " " .. COLOUR[e.colour] .. odds .. " - " .. cost
                .. " " .. how .. " " .. makeLink("list", function() answerMats(craftAsRecipe(c), prof, 1) end))
        end
        if p and p.max and rank < p.max then
            local plan = planSkillUps(prof, rank, p.max, known, trainCosts, crafts, withProfit)
            if plan then sayPlan(plan, p.max) end
        end
        if nextAt then say(GREY .. "  New trainer recipes at " .. nextAt .. ".|r " .. trainerLink(prof)) end
        return
    end
    if C and C.status == "loading" then
        say(GREY .. "(Still reading AtlasLoot's recipes: ask again in a few seconds to include trainer recipes.)|r")
    elseif p then
        say(GREY .. "(Only recipes you know: " .. (C and C.status == "ready" and ("AtlasLoot has no " .. prof .. " recipes")
            or (C and C.why) or "AtlasLoot's crafting data isn't loaded") .. ". /ab status shows why.)|r")
    end
    if not p then
        if rank == false then return say("You don't have " .. prof .. ". " .. trainerLink(prof)) end
        return say("Open your " .. prof .. " window once so I can read your recipes, then ask again.")
    end
    rank = rank or p.rank
    local list = {}
    for _, r in pairs(p.recipes) do
        if r.diff == "optimal" or r.diff == "medium" then
            local cost, unknown, inBags = matsValue(r.reagents)
            list[#list + 1] = { r = r, cost = cost, unknown = unknown, inBags = inBags }
        end
    end
    table.sort(list, function(a, b)
        if a.r.diff ~= b.r.diff then return a.r.diff == "optimal" end
        if a.unknown ~= b.unknown then return not a.unknown end
        if a.cost ~= b.cost then return a.cost < b.cost end
        return a.r.name < b.r.name
    end)
    local atCap = p.max and rank and rank >= p.max
    say(prof .. " " .. (rank or "?") .. (p.max and ("/" .. p.max) or "") .. ": cheapest skill-ups"
        .. (atCap and (" |cffff8040(at your cap: train the next rank)|r " .. trainerLink(prof)) or "") .. ":")
    if #list == 0 then
        return say(GREY .. "  Nothing orange or yellow. Learn new recipes: |r" .. trainerLink(prof))
    end
    for i = 1, math.min(4, #list) do
        local e = list[i]
        local r = e.r
        local cost = matsLabel(e)
        say("  " .. (r.item and itemLinkText(r.item) or (GOLD .. r.name .. "|r")) .. " " .. DIFF_LABEL[r.diff] .. " - " .. cost
            .. " " .. makeLink("list", function() answerMats(r, prof, 1) end))
    end
    if p.seen and time and time() - p.seen > 3 * 86400 then
        say(GREY .. "  (From when you last opened your " .. prof .. " window.)|r")
    end
end

--- "blacksmithing for profit": crafts you know (or a trainer teaches at your skill) whose output
--- sells for more than its mats bought now. Mats are priced at what you'd pay, so the profit
--- holds craft after craft, not just while your bags last.
local function answerProfit(prof)
    local p = recordedProfessions()[prof]
    local rank = professionSkill(prof)
    if rank == false and not p then return say("You don't have " .. prof .. ". " .. trainerLink(prof)) end
    rank = (rank ~= false and rank) or (p and p.rank)
    local P = AskBot.Prices
    if not (P and P.Available()) then return say("I need Auctionator's prices for that: install it and scan the AH.") end
    local C = AskBot.Crafts
    local entries, unpriced = {}, 0
    local function add(name, item, made, reagents, colour, learn)
        local sale, where = saleValue(item, made)
        local cost, unknown = matsValue(reagents, {})
        if not sale or unknown then unpriced = unpriced + 1; return end
        if sale > cost then
            entries[#entries + 1] = { name = name, item = item, made = made or 1, sale = sale, where = where, cost = cost,
                profit = sale - cost, colour = colour, learn = learn, reagents = reagents }
        end
    end
    local known = p and p.recipes or {}
    local trainCosts, seenTrainer
    if C and C.status == "ready" and C.byProf[prof] and rank then
        local crafts = fittedCrafts(prof, p)
        trainCosts = AskBotDB and AskBotDB.recipeTraining or {}
        seenTrainer = trainerSeen(prof, trainCosts)
        for _, c in ipairs(crafts) do
            local name = C.Name(c)
            local isKnown = name and known[D.NameKey(name)]
            local colour = C.Colour(c, rank)
            if c.item and (isKnown or (trainerTeaches(c, trainCosts, seenTrainer) and colour ~= "unlearnable")) then
                add(name or "?", c.item, c.made, c.reagents, colour, not isKnown and c or nil)
            end
        end
    elseif p then
        local COLOUR = { optimal = "orange", medium = "yellow", easy = "green", trivial = "grey" }
        for _, r in pairs(p.recipes) do
            if r.item then add(r.name, r.item, r.made, r.reagents, COLOUR[r.diff]) end
        end
    else
        return say("Open your " .. prof .. " window once so I can read your recipes, then ask again.")
    end
    table.sort(entries, function(a, b)
        if a.profit ~= b.profit then return a.profit > b.profit end
        return a.name < b.name
    end)
    say(prof .. (rank and (" " .. rank) or "") .. ": most profitable crafts" .. GREY .. " (sale less the AH cut, mats bought)|r"
        .. (#entries > 0 and ":" or "."))
    if #entries == 0 then say("  Nothing sells for more than its mats cost right now.") end
    local TAG = { orange = " |cffff8040(skill-up)|r", yellow = " |cffffff00(skill-up)|r" }
    for i = 1, math.min(5, #entries) do
        local e = entries[i]
        local each = e.made > 1 and (" x" .. e.made) or ""
        say("  " .. itemLinkText(e.item) .. each .. " |cff40ff40+" .. AskBot.Prices.Format(e.profit) .. "|r"
            .. GREY .. " (sells " .. AskBot.Prices.Format(e.sale) .. (e.where == "vendor" and " to a vendor" or "")
            .. ", mats " .. AskBot.Prices.Format(e.cost) .. ")|r" .. (TAG[e.colour] or "")
            .. (e.learn and (" learn: " .. learnFrom(e.learn)) or "")
            .. " " .. makeLink("list", function()
                answerMats({ name = e.name, item = e.item, made = e.made, reagents = e.reagents }, prof, 1)
            end))
    end
    if unpriced > 0 then
        say(GREY .. "  " .. unpriced .. " more with no price for the item or a mat: scan the AH to include them.|r")
    end
    if trainCosts and not seenTrainer then
        say(GREY .. "  Open your " .. prof .. " trainer once so I only suggest recipes it really teaches.|r " .. trainerLink(prof))
    end
end

-- "mats for 3 linen bag", "what do I need to make Linen Bag", "recipe for X", "how do I level tailoring"
local MATS_PATTERNS = { "^mats for (.+)$", "^materials for (.+)$", "^reagents for (.+)$", "^what do i need to make (.+)$",
    "^what does it take to make (.+)$", "^shopping list for (.+)$", "^how much to make (.+)$", "^cost to make (.+)$",
    "^cost of making (.+)$", "^(.+) mats$", "^(.+) materials$", "^how do i make (.+)$", "^how to make (.+)$",
    "^can i make (.+)$" }
local RECIPE_PATTERNS = { "^recipe for (.+)$", "^pattern for (.+)$", "^plans for (.+)$", "^formula for (.+)$",
    "^schematic for (.+)$", "^where do i get the recipe for (.+)$", "^where do i get the pattern for (.+)$",
    "^where do i get the plans for (.+)$", "^where do i get the formula for (.+)$", "^where do i get the schematic for (.+)$",
    "^where can i get the recipe for (.+)$", "^where can i learn (.+)$", "^how do i learn (.+)$", "^where do i learn (.+)$",
    "^who teaches (.+)$", "^where is the recipe for (.+)$" }
local SKILLUP_PATTERNS = { "^how do i level (.+)$", "^how to level (.+)$", "^how should i level (.+)$", "^level up (.+)$",
    "^levelling (.+)$", "^leveling (.+)$", "^skill up (.+)$", "^(.+) skill ?ups?$", "^(.+) skill up plan$", "^plan (.+)$", "^(.+) plan$", "^plan for (.+)$",
    "^(.+) levelling$", "^(.+) leveling$", "^(.+) guide$", "^best (.+) skill ?ups$", "^what (.+) should i craft$",
    "^what should i craft for (.+)$" }
-- Looser: a levelling word anywhere plus a profession ("cheapest leveling [Blacksmithing (Apprentice)]").
local SKILLUP_WORDS = { " leveling ", " levelling ", " level up ", " skill up ", " skill ups ", " skillup ", " skillups ",
    " to level ", " i level " }
local SKILLUP_FILLER = { cheapest = true, way = true, to = true, the = true, a = true, my = true, up = true,
    apprentice = true, journeyman = true, expert = true, artisan = true, master = true }

-- "[Blacksmithing] for profit", "profit tailoring", "most profitable tailoring"
local PROFIT_PATTERNS = { "^(.+) for profit$", "^(.+) for money$", "^profit (.+)$", "^profit from (.+)$",
    "^(.+) profits?$", "^most profitable (.+)$", "^profitable (.+)$", "^(.+) to sell$", "^make money with (.+)$",
    "^make money from (.+)$" }
local function profitProfession(q)
    for _, pattern in ipairs(PROFIT_PATTERNS) do
        local s = q:match(pattern)
        s = s and s:gsub("^what ", ""):gsub(" crafts?$", ""):gsub("^crafting ", "")
        local prof = s and professionNamed(s)
        if prof then return prof end
    end
end

--- The profession a skill-up question names, or nil.
local function skillUpProfession(q)
    for _, pattern in ipairs(SKILLUP_PATTERNS) do
        local s = q:match(pattern)
        local prof = s and professionNamed(s)
        if prof then return prof end
    end
    local padded = " " .. q .. " "
    if padded:find(" trainers? ") then return nil end
    for _, w in ipairs(SKILLUP_WORDS) do
        if padded:find(w, 1, true) then return (professionNamed(q)) end
    end
    -- Misspellings (levling, lvling, leveing, lvl) and "cheapest [Blacksmithing]" with nothing else.
    local others = false
    for word in q:gmatch("%S+") do
        if word:match("^l[ev]*l+i?n?g?$") or word:match("^l[ev]*l+i?n?g?up$") or word:match("^lv?l+$") then
            return (professionNamed(q))
        end
        if not (SKILLUP_FILLER[word] or professionNamed(word)) then others = true end
    end
    if not others and padded:find(" cheapest ", 1, true) then return (professionNamed(q)) end
end

--- "level [Blacksmithing] with profit": the profession, for skill-ups that count what crafts sell for.
local function withProfitProfession(q)
    local base = q:gsub(" with profits?$", ""):gsub(" profitably$", ""):gsub(" and profit$", "")
    if base == q then return nil end
    return skillUpProfession(base) or professionNamed(base)
end

--- Is `q` a profession question that needs your own recipes or skills? (For "!ask".)
local function personalProfession(q)
    for _, pattern in ipairs(MATS_PATTERNS) do
        if q:match(pattern) then return true end
    end
    if skillUpProfession(q) or profitProfession(q) or withProfitProfession(q) then return true end
    return q == "what should i craft"
end

--- Answers profession questions; returns true if it did.
local function professionQuestion(q, isServiceQuestion)
    local withProfit = withProfitProfession(q)
    if withProfit then answerSkillUp(withProfit, true); return true end
    local forProfit = profitProfession(q)
    if forProfit then answerProfit(forProfit); return true end
    -- Skill-ups need a profession named.
    local skillUp = skillUpProfession(q)
    if skillUp then answerSkillUp(skillUp); return true end
    if q == "what should i craft" then
        local any, done = false, {}
        for prof in pairs(recordedProfessions()) do any = true; done[prof] = true; answerSkillUp(prof) end
        for _, p in ipairs(PROFESSIONS) do
            if p.craft and not done[p[1]] and professionSkill(p[1]) then any = true; answerSkillUp(p[1]) end
        end
        if not any then say("Open a profession window once so I can read your recipes, then ask again.") end
        return true
    end
    for _, pattern in ipairs(MATS_PATTERNS) do
        local s = q:match(pattern)
        if s and not professionNamed(s) then
            local count = tonumber(s:match("^(%d+) ")) or tonumber(s:match(" x ?(%d+)$")) or tonumber(s:match(" (%d+)$"))
            s = s:gsub("^%d+ ", ""):gsub(" x ?%d+$", ""):gsub(" %d+$", ""):gsub("^an? ", ""):gsub("^the ", "")
            local recipe, prof
            if not AskBot.asker then recipe, prof = knownRecipe(s) end
            if recipe then answerMats(recipe, prof, count); return true end
            local c = craftFor(s)
            if c then
                answerMats(craftAsRecipe(c), c.prof, count)
                if not AskBot.asker then
                    say(GREY .. "  You don't know it yet (" .. c.prof .. " " .. c.learn .. "), learn: |r" .. learnFrom(c))
                end
                return true
            end
            -- Not one of yours: where to learn it (or how to let AskBot read your recipes).
            local isRecipe = false
            local key = D.NameKey(s)
            for _, e in ipairs(D.recipeItems) do if e[1] == key then isRecipe = true; break end end
            if isRecipe then
                if not next(recordedProfessions()) then
                    say(GREY .. "I haven't seen your recipes yet: open your profession window once.|r")
                end
                say("You don't know how to make that yet.")
                answerRecipe(s)
                return true
            end
            if pattern ~= "^how do i make (.+)$" and pattern ~= "^how to make (.+)$" and pattern ~= "^can i make (.+)$" then
                say(next(recordedProfessions()) and ("None of your recipes makes \"" .. s .. "\".")
                    or "Open your profession window once so I can read your recipes, then ask again.")
                return true
            end
        end
    end
    for _, pattern in ipairs(RECIPE_PATTERNS) do
        local s = q:match(pattern)
        if s and not professionNamed(s) then
            s = s:gsub("^an? ", ""):gsub("^the ", "")
        end
        -- A real recipe wins over a service word in its name ("fine *leather* boots").
        local isRecipe = false
        if s and not professionNamed(s) then
            isRecipe = craftFor(s) ~= nil or (not AskBot.asker and knownRecipe(s) ~= nil)
            if not isRecipe then
                local key = D.NameKey(s)
                for _, e in ipairs(D.recipeItems) do if e[1] == key then isRecipe = true; break end end
            end
        end
        if s and not professionNamed(s) and (isRecipe or not isServiceQuestion()) then
            answerRecipe(s)
            return true
        end
    end
    return false
end

-- For the files loaded after this one.
Professions.professionSkill, Professions.gatherLookup = professionSkill, gatherLookup
Professions.answerGather, Professions.answerGatherBest = answerGather, answerGatherBest
Professions.professionQuestion, Professions.recordRecipes = professionQuestion, recordRecipes
Professions.personalProfession = personalProfession
Professions.recordTradeTraining = recordTradeTraining
