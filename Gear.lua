-- Gear.lua
-- The engine behind "/ab upgrades": your spec (from talents, or named in the question), stat
-- weights per spec, which items your class can use (and what training they still need), your
-- equipped items, candidate items from quests, dungeons and the auction house, and scoring.
-- No chat output here; the answer lives in AskBot.lua.

local _, AskBot = ...
local D = AskBot.Data

local Gear = {}
AskBot.Gear = Gear

--------------------------------------------------------------------------------------------
-- Stat weights
--------------------------------------------------------------------------------------------

-- Stat names as C_Item.GetItemStats reports them -> the short keys used in the weights.
local STAT_KEYS = {
    ITEM_MOD_STRENGTH_SHORT = "STR", ITEM_MOD_AGILITY_SHORT = "AGI", ITEM_MOD_STAMINA_SHORT = "STA",
    ITEM_MOD_INTELLECT_SHORT = "INT", ITEM_MOD_SPIRIT_SHORT = "SPI", RESISTANCE0_NAME = "ARMOR",
    ITEM_MOD_DAMAGE_PER_SECOND_SHORT = "DPS", ITEM_MOD_ATTACK_POWER_SHORT = "AP",
    ITEM_MOD_RANGED_ATTACK_POWER_SHORT = "RAP", ITEM_MOD_SPELL_POWER_SHORT = "SP",
    ITEM_MOD_SPELL_DAMAGE_DONE_SHORT = "SP", ITEM_MOD_SPELL_HEALING_DONE_SHORT = "HEAL",
    ITEM_MOD_HIT_RATING_SHORT = "HIT", ITEM_MOD_CRIT_RATING_SHORT = "CRIT",
    ITEM_MOD_HIT_SPELL_RATING_SHORT = "SPELLHIT", ITEM_MOD_CRIT_SPELL_RATING_SHORT = "SPELLCRIT",
    ITEM_MOD_DEFENSE_SKILL_RATING_SHORT = "DEF", ITEM_MOD_BLOCK_VALUE_SHORT = "BLOCK",
    ITEM_MOD_POWER_REGEN0_SHORT = "MP5", ITEM_MOD_MANA_REGENERATION_SHORT = "MP5",
}
Gear.STAT_KEYS = STAT_KEYS

-- Levelling-oriented weights per stat point (hit/crit are per 1%). DPS is melee weapon DPS,
-- RDPS is the ranged slot's DPS. Rough on purpose: good enough to rank gear while levelling.
local W = {
    strMelee = { STR = 1, AGI = 0.5, STA = 0.4, AP = 0.45, CRIT = 10, HIT = 10, ARMOR = 0.02, SPI = 0.05, DPS = 5, RDPS = 0.5 },
    ret      = { STR = 1, AGI = 0.4, STA = 0.5, INT = 0.25, AP = 0.45, CRIT = 9, HIT = 9, ARMOR = 0.02, SP = 0.3, DPS = 5, RDPS = 0 },
    enh      = { STR = 1, AGI = 0.6, STA = 0.4, INT = 0.3, AP = 0.45, CRIT = 9, HIT = 9, ARMOR = 0.02, DPS = 5, RDPS = 0 },
    tank     = { STA = 1, ARMOR = 0.08, DEF = 1.5, AGI = 0.6, STR = 0.5, BLOCK = 0.3, AP = 0.2, HIT = 5, DPS = 2, RDPS = 0.3 },
    tankPal  = { STA = 1, ARMOR = 0.08, DEF = 1.5, AGI = 0.4, STR = 0.5, INT = 0.3, BLOCK = 0.3, SP = 0.4, DPS = 2, RDPS = 0 },
    bear     = { STA = 1, ARMOR = 0.1, AGI = 0.7, STR = 0.6, DEF = 1.5, AP = 0.2, DPS = 0, RDPS = 0 },
    feral    = { STR = 1, AGI = 1, STA = 0.5, AP = 0.5, CRIT = 10, HIT = 10, ARMOR = 0.02, INT = 0.1, DPS = 0, RDPS = 0 },
    rogue    = { AGI = 1, STR = 0.5, STA = 0.4, AP = 0.5, CRIT = 10, HIT = 12, ARMOR = 0.01, DPS = 5, RDPS = 0.5 },
    hunter   = { AGI = 1, STA = 0.4, INT = 0.25, AP = 0.2, RAP = 0.45, CRIT = 10, HIT = 10, ARMOR = 0.01, SPI = 0.05, DPS = 0.5, RDPS = 6 },
    caster   = { INT = 0.8, SPI = 0.4, STA = 0.5, SP = 1, SPELLCRIT = 8, SPELLHIT = 8, CRIT = 0, MP5 = 1, ARMOR = 0.005, DPS = 0, RDPS = 1 },
    lock     = { INT = 0.6, SPI = 0.5, STA = 0.8, SP = 1, SPELLCRIT = 6, SPELLHIT = 8, MP5 = 0.8, ARMOR = 0.005, DPS = 0, RDPS = 1 },
    healer   = { INT = 1, SPI = 0.6, STA = 0.3, HEAL = 0.8, SP = 0.6, MP5 = 1.5, SPELLCRIT = 6, ARMOR = 0.005, DPS = 0, RDPS = 0.5 },
}

-- Specs per class, in talent tab order, plus extra specs that share a tab (bear and cat are
-- both Feral). `default` is the levelling spec used before talents say otherwise.
local SPECS = {
    WARRIOR = { default = 1,
        { name = "Arms", weights = W.strMelee, words = { "arms" } },
        { name = "Fury", weights = W.strMelee, words = { "fury" } },
        { name = "Protection", weights = W.tank, words = { "prot", "protection", "tank" } } },
    PALADIN = { default = 3,
        { name = "Holy", weights = W.healer, words = { "holy", "heal", "healer", "healing" } },
        { name = "Protection", weights = W.tankPal, words = { "prot", "protection", "tank" } },
        { name = "Retribution", weights = W.ret, words = { "ret", "retri", "retribution", "dps" } } },
    HUNTER = { default = 1,
        { name = "Beast Mastery", weights = W.hunter, words = { "bm", "beast", "beastmastery" } },
        { name = "Marksmanship", weights = W.hunter, words = { "mm", "marks", "marksman", "marksmanship" } },
        { name = "Survival", weights = W.hunter, words = { "surv", "survival" } } },
    ROGUE = { default = 2,
        { name = "Assassination", weights = W.rogue, words = { "assa", "assassin", "assassination" } },
        { name = "Combat", weights = W.rogue, words = { "combat" } },
        { name = "Subtlety", weights = W.rogue, words = { "sub", "subtlety" } } },
    PRIEST = { default = 3,
        { name = "Discipline", weights = W.healer, words = { "disc", "discipline" } },
        { name = "Holy", weights = W.healer, words = { "holy", "heal", "healer", "healing" } },
        { name = "Shadow", weights = W.caster, words = { "shadow", "spriest", "dps" } } },
    SHAMAN = { default = 2,
        { name = "Elemental", weights = W.caster, words = { "ele", "elemental", "caster" } },
        { name = "Enhancement", weights = W.enh, words = { "enh", "enhance", "enhancement", "melee" } },
        { name = "Restoration", weights = W.healer, words = { "resto", "restoration", "heal", "healer", "healing" } } },
    MAGE = { default = 3,
        { name = "Arcane", weights = W.caster, words = { "arcane" } },
        { name = "Fire", weights = W.caster, words = { "fire" } },
        { name = "Frost", weights = W.caster, words = { "frost" } } },
    WARLOCK = { default = 1,
        { name = "Affliction", weights = W.lock, words = { "affli", "affliction" } },
        { name = "Demonology", weights = W.lock, words = { "demo", "demonology" } },
        { name = "Destruction", weights = W.lock, words = { "destro", "destruction" } } },
    DRUID = { default = 2,
        { name = "Balance", weights = W.caster, words = { "balance", "boomkin", "moonkin", "owl", "caster" } },
        { name = "Feral", weights = W.feral, words = { "feral", "cat", "kitty", "dps" } },
        { name = "Restoration", weights = W.healer, words = { "resto", "restoration", "tree", "heal", "healer", "healing" } },
        { name = "Feral (bear)", tab = 2, weights = W.bear, words = { "bear", "tank", "guardian" } } },
}
Gear.SPECS = SPECS

local function talentPoints()
    if not GetNumTalentTabs or not GetTalentTabInfo then return nil end
    local ok, n = pcall(GetNumTalentTabs)
    if not ok or type(n) ~= "number" or n == 0 then return nil end
    local points = {}
    for i = 1, n do
        local r = { pcall(GetTalentTabInfo, i) }
        if not r[1] then return nil end
        -- Era: name, icon, pointsSpent.  Modern: id, name, description, icon, pointsSpent.
        points[i] = (type(r[2]) == "number" and r[6] or r[4]) or 0
        if type(points[i]) ~= "number" then points[i] = 0 end
    end
    return points
end

--- Your spec. `words` is the set of words in the question; a spec named there wins.
--- Returns spec ({ name, weights }), how it was chosen ("named" | "talents" | "guess"), and a
--- talent summary like "12/10/0" (or nil).
function Gear.Spec(classFile, words)
    local specs = SPECS[classFile]
    if not specs then return nil end
    words = words or {}
    for _, s in ipairs(specs) do
        for _, w in ipairs(s.words) do
            if words[w] then return s, "named" end
        end
    end
    local points = not AskBot.asker and talentPoints()
    local summary = points and table.concat(points, "/")
    if points then
        local best, top, second = 1, 0, 0
        for i, p in ipairs(points) do
            if p > top then second, top, best = top, p, i
            elseif p > second then second = p end
        end
        if top > 0 then
            -- Close trees (e.g. 12/10/0) are a guess; the answer says how to name another spec.
            return specs[best], (top - second >= 5) and "talents" or "guess", summary
        end
    end
    return specs[specs.default], "guess", summary
end

--------------------------------------------------------------------------------------------
-- What your class can use
--------------------------------------------------------------------------------------------

local ARMOR_NAMES = { [1] = "Cloth", [2] = "Leather", [3] = "Mail", [4] = "Plate Mail", [6] = "Shield" }
-- Best armour type now, and from level 40.
local ARMOR = { WARRIOR = { 3, 4 }, PALADIN = { 3, 4 }, HUNTER = { 2, 3 }, SHAMAN = { 2, 3 }, ROGUE = { 2, 2 },
    DRUID = { 2, 2 }, PRIEST = { 1, 1 }, MAGE = { 1, 1 }, WARLOCK = { 1, 1 } }
local SHIELDS = { WARRIOR = true, PALADIN = true, SHAMAN = true }

local WEAPON_NAMES = { [0] = "Axes", [1] = "Two-Handed Axes", [2] = "Bows", [3] = "Guns", [4] = "Maces",
    [5] = "Two-Handed Maces", [6] = "Polearms", [7] = "Swords", [8] = "Two-Handed Swords", [10] = "Staves",
    [13] = "Fist Weapons", [15] = "Daggers", [16] = "Thrown", [18] = "Crossbows", [19] = "Wands" }
local function set(list) local t = {} for _, v in ipairs(list) do t[v] = true end return t end
-- Weapon types each class can learn (from its trainer or a weapon master).
local WEAPONS = {
    WARRIOR = set({ 0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 13, 15, 16, 18 }),
    PALADIN = set({ 0, 1, 4, 5, 6, 7, 8 }),
    HUNTER = set({ 0, 1, 2, 3, 6, 7, 8, 10, 13, 15, 16, 18 }),
    ROGUE = set({ 2, 3, 4, 7, 13, 15, 16, 18 }),
    PRIEST = set({ 4, 10, 15, 19 }),
    SHAMAN = set({ 0, 1, 4, 5, 10, 13, 15 }),
    MAGE = set({ 7, 10, 15, 19 }),
    WARLOCK = set({ 7, 10, 15, 19 }),
    DRUID = set({ 4, 5, 10, 13, 15 }),
}
local DUAL_WIELD = { WARRIOR = true, ROGUE = true, HUNTER = true }

-- Equip slot -> slot group.
local GROUP_OF = {
    INVTYPE_HEAD = "head", INVTYPE_NECK = "neck", INVTYPE_SHOULDER = "shoulder", INVTYPE_CHEST = "chest",
    INVTYPE_ROBE = "chest", INVTYPE_WAIST = "waist", INVTYPE_LEGS = "legs", INVTYPE_FEET = "feet",
    INVTYPE_WRIST = "wrist", INVTYPE_HAND = "hands", INVTYPE_FINGER = "ring", INVTYPE_TRINKET = "trinket",
    INVTYPE_CLOAK = "back", INVTYPE_WEAPON = "onehand", INVTYPE_WEAPONMAINHAND = "onehand",
    INVTYPE_2HWEAPON = "twohand", INVTYPE_WEAPONOFFHAND = "offhand", INVTYPE_SHIELD = "offhand",
    INVTYPE_HOLDABLE = "offhand", INVTYPE_RANGED = "ranged", INVTYPE_RANGEDRIGHT = "ranged", INVTYPE_THROWN = "ranged",
}
Gear.GROUP_LABELS = { head = "Head", neck = "Neck", shoulder = "Shoulders", chest = "Chest", waist = "Waist",
    legs = "Legs", feet = "Feet", wrist = "Wrists", hands = "Hands", ring = "Ring", trinket = "Trinket", back = "Back",
    onehand = "Weapon", twohand = "Two-hander", offhand = "Off hand", ranged = "Ranged" }
-- Words in a question -> slot groups.
Gear.SLOT_WORDS = {
    head = { "head" }, helm = { "head" }, helmet = { "head" }, neck = { "neck" }, necklace = { "neck" },
    amulet = { "neck" }, shoulder = { "shoulder" }, shoulders = { "shoulder" }, chest = { "chest" }, robe = { "chest" },
    waist = { "waist" }, belt = { "waist" }, legs = { "legs" }, pants = { "legs" }, leggings = { "legs" },
    feet = { "feet" }, boots = { "feet" }, wrist = { "wrist" }, wrists = { "wrist" }, bracers = { "wrist" },
    hands = { "hands" }, gloves = { "hands" }, ring = { "ring" }, rings = { "ring" }, trinket = { "trinket" },
    trinkets = { "trinket" }, back = { "back" }, cloak = { "back" }, cape = { "back" },
    weapon = { "onehand", "twohand" }, weapons = { "onehand", "twohand" }, ["2h"] = { "twohand" },
    offhand = { "offhand" }, shield = { "offhand" }, ranged = { "ranged" }, bow = { "ranged" }, gun = { "ranged" },
    wand = { "ranged" },
}

local function itemInfoInstant(id)
    local f = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not f then return nil end
    local _, _, _, equipLoc, _, classID, subclassID = f(id)
    return equipLoc, classID, subclassID
end

--- Skills you have (weapon and armour skills included), or nil when unknown.
function Gear.Skills()
    if AskBot.asker or not GetNumSkillLines or not GetSkillLineInfo then return nil end
    local have = {}
    for i = 1, GetNumSkillLines() do
        local name, isHeader = GetSkillLineInfo(i)
        if name and not isHeader then have[name] = true end
    end
    return have
end

--- Can `classFile` use item `id` at `level` + 5? Returns the slot group (nil if not), the
--- required level, and what's still needed ("train Two-Handed Swords", "Plate Mail at 40").
function Gear.Check(id, classFile, level, skills)
    local equipLoc, classID, sub = itemInfoInstant(id)
    local group = equipLoc and GROUP_OF[equipLoc]
    if not group then return nil end
    classID = (ItemDB.class and ItemDB.class(id)) or classID
    sub = (ItemDB.subClass and ItemDB.subClass(id)) or sub
    local req = (ItemDB.requiredLevel and ItemDB.requiredLevel(id)) or 0
    if req > level + 5 then return nil end
    local needs
    if classID == 4 then
        if sub == 6 then
            if not SHIELDS[classFile] then return nil end
            if skills and not skills.Shield then needs = "train Shield" end
        elseif sub and sub >= 1 and sub <= 4 and equipLoc ~= "INVTYPE_CLOAK" then
            local armor = ARMOR[classFile]
            if not armor or sub > armor[2] then return nil end
            if sub > armor[1] then
                if math.max(level, req) < 40 then
                    needs = ARMOR_NAMES[sub] .. " at 40"
                    req = math.max(req, 40)
                    if req > level + 5 then return nil end
                elseif skills and not skills[ARMOR_NAMES[sub]] then
                    needs = "train " .. ARMOR_NAMES[sub]
                end
            end
        elseif sub and sub > 6 then
            return nil -- librams, idols, totems
        end
    elseif classID == 2 then
        local can = WEAPONS[classFile]
        if not can or not can[sub] then return nil end
        local skill = WEAPON_NAMES[sub]
        if skills and skill and not skills[skill] then needs = "train " .. skill end
    end
    return group, req, needs
end

--------------------------------------------------------------------------------------------
-- Item data and scores
--------------------------------------------------------------------------------------------

local function getInfo(id)
    local f = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if f then return f(id) end
end

local pendingLoads, loadWaiters = {}, {}
local loadFrame = CreateFrame("Frame")
loadFrame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
loadFrame:SetScript("OnEvent", function(_, _, itemId)
    if not pendingLoads[itemId] then return end
    pendingLoads[itemId] = nil
    for _, w in ipairs(loadWaiters) do
        if w.missing[itemId] then
            w.missing[itemId] = nil
            w.left = w.left - 1
            if w.left == 0 and not w.done then w.done = true; w.onReady() end
        end
    end
end)

--- Make sure the client has these items' data, then call onReady() (after at most 3 seconds;
--- items still missing then are skipped). Returns how many items had to be fetched.
function Gear.Load(ids, onReady)
    local waiter = { missing = {}, left = 0, onReady = onReady }
    for _, id in ipairs(ids) do
        if not getInfo(id) and not waiter.missing[id] then
            waiter.missing[id] = true
            waiter.left = waiter.left + 1
            pendingLoads[id] = true
            if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
        end
    end
    if waiter.left == 0 then onReady(); return 0 end
    loadWaiters[#loadWaiters + 1] = waiter
    C_Timer.After(3, function()
        if not waiter.done then waiter.done = true; onReady() end
    end)
    return waiter.left
end

local function itemStats(link)
    local f = (C_Item and C_Item.GetItemStats) or GetItemStats
    local ok, stats = pcall(f, link)
    return ok and type(stats) == "table" and stats or {}
end

--- Score an item (link or ID) with spec weights; `ranged` uses the ranged-DPS weight.
function Gear.Score(item, weights, ranged)
    local link = type(item) == "string" and item or select(2, getInfo(item))
    if not link then return nil end
    local score = 0
    for stat, value in pairs(itemStats(link)) do
        local key = STAT_KEYS[stat]
        if key == "DPS" and ranged then key = "RDPS" end
        local w = key and weights[key]
        if w and type(value) == "number" then score = score + w * value end
    end
    return score
end

--- Your equipped items' scores per slot group: { [group] = { score, link } }. Paired slots
--- count the weaker item; a two-hander counts both hands. An off hand isn't compared while
--- you wield a two-hander (group missing).
function Gear.Current(weights, classFile)
    local function slot(n)
        local link = GetInventoryItemLink and GetInventoryItemLink("player", n)
        return link and (Gear.Score(link, weights, n == 18) or 0) or 0, link
    end
    local out = {}
    for group, n in pairs({ head = 1, neck = 2, shoulder = 3, chest = 5, waist = 6, legs = 7, feet = 8,
        wrist = 9, hands = 10, back = 15, ranged = 18 }) do
        local s, link = slot(n)
        out[group] = { score = s, link = link }
    end
    for group, pair in pairs({ ring = { 11, 12 }, trinket = { 13, 14 } }) do
        local a, la = slot(pair[1])
        local b, lb = slot(pair[2])
        if a <= b then out[group] = { score = a, link = la } else out[group] = { score = b, link = lb } end
    end
    local mh, mhLink = slot(16)
    local oh, ohLink = slot(17)
    local mhLoc = mhLink and itemInfoInstant(mhLink)
    local twoHanded = mhLoc == "INVTYPE_2HWEAPON"
    out.twohand = { score = mh + oh, link = mhLink }
    out.onehand = { score = mh, link = mhLink }
    if not twoHanded then
        local ohLoc = ohLink and itemInfoInstant(ohLink)
        if DUAL_WIELD[classFile] and ohLoc == "INVTYPE_WEAPON" and oh < mh then
            out.onehand = { score = oh, link = ohLink }
        end
        out.offhand = { score = oh, link = ohLink }
    end
    return out
end

--------------------------------------------------------------------------------------------
-- Candidates
--------------------------------------------------------------------------------------------

--- Items worth scoring: { [itemId] = { group, req, needs, sources = { ... } } }.
--- opts: { classFile, level, quests = { questId, ... }, inLog = { [questId] = true } }.
--- Sources: { kind = "quest", quest } / { kind = "boss", boss, rate } / { kind = "ah", price }.
--- At most `perGroup` items per slot group are kept (highest item level first).
function Gear.Candidates(opts, perGroup)
    local level, classFile = opts.level, opts.classFile
    local skills = Gear.Skills()
    local found = {}
    local function add(id, source)
        local c = found[id]
        if c == nil then
            local group, req, needs = Gear.Check(id, classFile, level, skills)
            c = group and { id = id, group = group, req = req, needs = needs, sources = {} } or false
            found[id] = c
        end
        if c then c.sources[#c.sources + 1] = source end
    end

    for _, q in ipairs(opts.quests or {}) do
        for _, id in ipairs(D.questRewardItems[q] or {}) do add(id, { kind = "quest", quest = q, inLog = opts.inLog[q] }) end
    end
    local L = AskBot.Loot
    if L and L.status == "ready" then
        for _, inst in ipairs(L.instances) do
            local lr = inst.levelRange
            local lo, hi = lr and lr[1], lr and (lr[3] or lr[2])
            if lo and hi and lo <= level + 5 and hi >= level then
                for _, boss in ipairs(inst.bosses) do
                    for _, id in ipairs(boss.items) do
                        add(id, { kind = "boss", boss = boss, rate = boss.npcId and L.DropRate(boss.npcId, id) })
                    end
                end
            end
        end
    end
    local P = AskBot.Prices
    if P and P.Available() then
        -- Anything Questie knows with a recent auction price (BoE gear, crafted or world drops).
        for _, g in ipairs(D.gearItems) do
            if g[2] >= level - 8 and g[2] <= level + 5 then
                local price = P.Auction(g[1])
                if price then add(g[1], { kind = "ah", price = price }) end
            end
        end
        for id, c in pairs(found) do
            if c then
                local hasAh = false
                for _, s in ipairs(c.sources) do if s.kind == "ah" then hasAh = true end end
                local price = not hasAh and P.Auction(id)
                if price then c.sources[#c.sources + 1] = { kind = "ah", price = price } end
            end
        end
    end

    -- Keep the most promising few per slot group, by item level.
    local byGroup = {}
    for _, c in pairs(found) do
        if c then
            local list = byGroup[c.group]
            if not list then list = {}; byGroup[c.group] = list end
            c.ilvl = (ItemDB.itemLevel and ItemDB.itemLevel(c.id)) or 0
            list[#list + 1] = c
        end
    end
    local out = {}
    for _, list in pairs(byGroup) do
        table.sort(list, function(a, b) if a.ilvl ~= b.ilvl then return a.ilvl > b.ilvl end return a.id < b.id end)
        for i = 1, math.min(perGroup or 8, #list) do out[#out + 1] = list[i] end
    end
    return out
end
