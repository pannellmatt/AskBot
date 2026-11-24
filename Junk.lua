-- Junk.lua
-- Sells junk when you open a merchant: grey items, and weapons and armour you can't use or have
-- outgrown, unless the auction house pays clearly more. The first 12 sell by themselves (the
-- merchant's buyback holds 12); a [sell] link in chat sells the next 12.

local _, AskBot = ...
local Out = AskBot.Out
local GREY, say, makeLink = Out.GREY, Out.say, Out.makeLink
local askerClass, askerLevel = Out.askerClass, Out.askerLevel
local itemLinkText = AskBot.Quests.itemLinkText
local isGear, beatsWorn = AskBot.GearAnswers.isGear, AskBot.GearAnswers.beatsWorn

local Junk = {}
AskBot.Junk = Junk

Junk.BUYBACK = 12          -- the merchant's buyback slots
Junk.AH_CUT = 0.05         -- the AH's cut of a sale (confirmed on Forever)
Junk.AH_RATIO = 1.5        -- keep for the AH only if it pays this many times the vendor price...
Junk.AH_MARGIN = 100       -- ...and at least this much more (1s), per item
Junk.LOW_LEVELS = 5        -- "outgrown": needs 5+ levels below yours and doesn't beat what you wear
Junk.LOW_CONSUMABLE = 10   -- food and drink needing 10+ levels below yours (Haunch of Meat, 5, at 15)

local POOR, EPIC = 0, 4
local QUEST_CLASS = 12
local WEAPON_CLASS, FISHING_POLE, CONSUMABLE_CLASS, FOOD_AND_DRINK, RARE = 2, 20, 0, 5, 3

-- Profession tools: never junk, even though some are weapons (Mining Pick, Blacksmith Hammer).
Junk.TOOLS = {
    [2901] = true,  -- Mining Pick
    [5956] = true,  -- Blacksmith Hammer
    [7005] = true,  -- Skinning Knife
    [6219] = true,  -- Arclight Spanner
    [10498] = true, -- Gyromatic Micro-Adjustor
    [4471] = true,  -- Flint and Tinder
    [9149] = true,  -- Philosopher's Stone
    [6218] = true, [6339] = true, [11130] = true, [11145] = true, [16207] = true, -- Runed enchanting rods
    [6256] = true, [6365] = true, [6366] = true, [6367] = true, [12225] = true, [19022] = true, [19970] = true, -- fishing poles
}

local function containerApi()
    local C = C_Container
    return (C and C.GetContainerNumSlots) or GetContainerNumSlots, (C and C.GetContainerItemID) or GetContainerItemID,
        (C and C.GetContainerItemInfo) or GetContainerItemInfo, (C and C.UseContainerItem) or UseContainerItem
end

local function itemInfo(id)
    local f = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if f then return f(id) end
end

--- Is the item in this bag slot soulbound? (It can't go on the AH then.)
local function slotBound(bag, slot)
    if not (C_Item and C_Item.IsBound and ItemLocation and ItemLocation.CreateFromBagAndSlot) then return nil end
    local ok, bound = pcall(function() return C_Item.IsBound(ItemLocation:CreateFromBagAndSlot(bag, slot)) end)
    return ok and bound or nil
end

--- Stack count, whether the slot is locked and whether it's soulbound, from either the table or
--- the old multi-value API.
local function slotInfo(getInfo, bag, slot)
    local a, b, c = getInfo(bag, slot)
    if type(a) == "table" then
        local bound = a.isBound
        if bound == nil then bound = slotBound(bag, slot) end
        return a.stackCount or 1, a.isLocked, bound
    end
    return b or 1, c, slotBound(bag, slot)
end

--- Why item `id` is junk ("grey", "unusable", "outgrown") or nil. Load the item first (Gear.Load).
local function junkReason(id, quality, ctx)
    if Junk.TOOLS[id] then return nil end
    local f = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    local _, _, _, _, _, classID, subClassID = f and f(id)
    classID = classID or select(12, itemInfo(id))
    if classID == WEAPON_CLASS and subClassID == FISHING_POLE then return nil end
    if quality == POOR then return "grey" end
    if classID == CONSUMABLE_CLASS then
        -- Food and drink only (potions, stones, scrolls and bandages stay), and only with a level
        -- requirement: without one there's no telling if it's outgrown.
        subClassID = subClassID or select(13, itemInfo(id))
        if subClassID ~= FOOD_AND_DRINK then return nil end
        local req = select(5, itemInfo(id)) or 0
        return (quality and quality < RARE and req > 0 and req + Junk.LOW_CONSUMABLE <= ctx.level) and "low consumable" or nil
    end
    if not quality or quality >= EPIC or not isGear(id) then return nil end
    local G = AskBot.Gear
    local req
    -- Kept if it beats what you wear for any of your class's specs (off-spec gear counts).
    for _, spec in ipairs(ctx.specs) do
        local r = G.Compare(id, spec, ctx.classFile, ctx.level)
        if not r.group then
            return (r.cannot and r.cannot ~= "") and "unusable" or nil
        end
        local wearing = r.currentLink and r.currentLink:find("item:" .. id .. ":", 1, true)
        if wearing or not (r.score and r.gain) or beatsWorn(r) then return nil end
        req = req or r.req
    end
    req = req or select(5, itemInfo(id)) or 0
    if req + Junk.LOW_LEVELS <= ctx.level then return "outgrown" end
end

--- Your junk: { sell = { { bag, slot, id, count, value } }, ah = { { id, ah, vendor } },
--- unpriced = { id } }. `value` is the vendor price of the whole stack.
function Junk.Scan(ids)
    local numSlots, itemId, getInfo = containerApi()
    local G = AskBot.Gear
    local classFile, level = askerClass(), askerLevel()
    local ctx = { classFile = classFile, level = level, spec = G.Spec(classFile, {}), specs = {} }
    -- Keep gear that's an upgrade for any of your class's specs, or (setting off) only yours.
    if AskBot.Option("junkOffSpec") then
        for _, s in ipairs(G.SPECS[classFile] or {}) do ctx.specs[#ctx.specs + 1] = s end
    end
    if #ctx.specs == 0 then ctx.specs[1] = ctx.spec end
    local out, seenAh, seenUnpriced = { sell = {}, ah = {}, unpriced = {} }, {}, {}
    local P = AskBot.Prices
    for bag = 0, (NUM_BAG_SLOTS or 4) do
        for slot = 1, (numSlots(bag) or 0) do
            local id = itemId(bag, slot)
            if id then
                local _, _, quality, _, _, _, _, _, _, _, vendor, classID = itemInfo(id)
                local count, locked, bound = slotInfo(getInfo, bag, slot)
                local reason = vendor and vendor > 0 and classID ~= QUEST_CLASS and not locked
                    and (not AskBot.Data.startItems or not AskBot.Data.startItems[id])
                    and ctx.spec and junkReason(id, quality, ctx)
                if reason then
                    -- Soulbound items can't be auctioned: vendor them whatever the AH says.
                    local ah = not bound and P and P.Sale(id) or nil
                    local net = ah and math.floor(ah * (1 - Junk.AH_CUT))
                    if net and net >= vendor * Junk.AH_RATIO and net - vendor >= Junk.AH_MARGIN then
                        if not seenAh[id] then seenAh[id] = true; out.ah[#out.ah + 1] = { id = id, ah = net, vendor = vendor } end
                    elseif not net and not bound and quality and quality >= 2 then
                        -- A green or blue with no AH price: could be worth a lot, so keep it.
                        if not seenUnpriced[id] then seenUnpriced[id] = true; out.unpriced[#out.unpriced + 1] = id end
                    else
                        out.sell[#out.sell + 1] = { bag = bag, slot = slot, id = id, count = count, value = vendor * count, reason = reason }
                    end
                end
            end
        end
    end
    return out
end

local function merchantOpen()
    return MerchantFrame and MerchantFrame.IsShown and MerchantFrame:IsShown()
end

local function total(list, from, to)
    local sum = 0
    for i = from, math.min(to, #list) do sum = sum + list[i].value end
    return sum
end

local function itemList(ids, max)
    local parts = {}
    for i, id in ipairs(ids) do
        if i > max then parts[#parts + 1] = GREY .. "+" .. (#ids - max) .. "|r"; break end
        parts[#parts + 1] = itemLinkText(id)
    end
    return table.concat(parts, ", ")
end

--- Sells up to 12 of `list` (still in the same slots), says what sold, and offers the rest.
local function sellBatch(list)
    if not merchantOpen() then return say(GREY .. "Open a merchant first.|r") end
    local _, itemId, _, use = containerApi()
    if not use then return end
    local sold, money = 0, 0
    local rest = {}
    for _, e in ipairs(list) do
        if sold < Junk.BUYBACK and itemId(e.bag, e.slot) == e.id then
            use(e.bag, e.slot)
            sold, money = sold + 1, money + e.value
        elseif itemId(e.bag, e.slot) == e.id then
            rest[#rest + 1] = e
        end
    end
    if sold > 0 then
        say("Sold " .. sold .. " junk item" .. (sold == 1 and "" or "s") .. " for " .. AskBot.Prices.Format(money) .. ".")
    end
    if #rest > 0 then
        say("  " .. #rest .. " more for " .. AskBot.Prices.Format(total(rest, 1, #rest)) .. GREY .. " (buyback holds "
            .. Junk.BUYBACK .. ")|r " .. makeLink("sell", function() sellBatch(rest) end))
    end
end

--- On opening a merchant: sell the first 12, list what's better on the AH or has no AH price.
function Junk.OnMerchant()
    if not AskBot.Option("autoVendor") or AskBot.asker then return end
    local numSlots, itemId = containerApi()
    if not (numSlots and itemId) then return end
    local ids, seen = {}, {}
    for bag = 0, (NUM_BAG_SLOTS or 4) do
        for slot = 1, (numSlots(bag) or 0) do
            local id = itemId(bag, slot)
            if id and not seen[id] then seen[id] = true; ids[#ids + 1] = id end
        end
    end
    if #ids == 0 then return end
    AskBot.Gear.Load(ids, function()
        local ok, err = pcall(function()
            local junk = Junk.Scan(ids)
            if #junk.sell > 0 then sellBatch(junk.sell) end
            if #junk.ah > 0 then
                local parts = {}
                for i, e in ipairs(junk.ah) do
                    if i > 3 then parts[#parts + 1] = GREY .. "+" .. (#junk.ah - 3) .. "|r"; break end
                    parts[#parts + 1] = itemLinkText(e.id) .. " ~" .. AskBot.Prices.Format(e.ah)
                        .. GREY .. " (vendor " .. AskBot.Prices.Format(e.vendor) .. ")|r"
                end
                say("  Better on the AH: " .. table.concat(parts, ", "))
            end
            if #junk.unpriced > 0 then
                say("  " .. GREY .. "Kept, no AH price yet:|r " .. itemList(junk.unpriced, 4))
            end
        end)
        if not ok and geterrorhandler then geterrorhandler()(err) end
    end)
end
