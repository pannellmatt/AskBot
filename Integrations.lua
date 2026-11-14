-- Integrations.lua
-- Optional extras from other addons, each used only when installed:
--   AtlasLoot (Forever build): dungeon/raid boss loot tables and drop rates.
--   Auctionator: auction house and vendor prices.

local ADDON_NAME, AskBot = ...
local D = AskBot.Data

--------------------------------------------------------------------------------------------
-- AtlasLoot
--------------------------------------------------------------------------------------------

local Loot = {
    status = "absent", -- absent | loading | ready
    byItem = {},       -- itemID -> list of { boss = boss, rate = number? }
    bossNames = {},    -- list of { key, boss, displayName } for D.FindByName
    instanceNames = {},
    instances = {},
}
AskBot.Loot = Loot

local LOOT_MODULES = { "AtlasLootClassic_DungeonsAndRaids" }

local function stripCodes(s)
    s = tostring(s or ""):gsub("|T.-|t", ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    return (s:match("^%s*(.-)%s*$"))
end

local function firstNpcId(npcID)
    if type(npcID) == "table" then return npcID[1] end
    return npcID
end

--- Drop rate (percent) from AtlasLoot's table, or nil.
function Loot.DropRate(npcId, itemId)
    local dr = _G.AtlasLoot and AtlasLoot.Data and AtlasLoot.Data.Droprate
    if not dr or not dr.GetData then return nil end
    local ok, rate = pcall(dr.GetData, dr, npcId, itemId)
    return ok and rate or nil
end

-- Item names AtlasLoot knows but Questie doesn't arrive asynchronously from the server.
local pendingNames = {}
local function addItemName(id, name)
    if name and not D.itemIds[id] then
        D.itemIds[id] = true
        D.itemNames[#D.itemNames + 1] = { D.NameKey(name), id, name }
    end
end

local itemEvents = CreateFrame("Frame")
itemEvents:RegisterEvent("GET_ITEM_INFO_RECEIVED")
itemEvents:SetScript("OnEvent", function(_, _, itemId, success)
    if pendingNames[itemId] then
        pendingNames[itemId] = nil
        if success ~= false and C_Item and C_Item.GetItemNameByID then
            addItemName(itemId, C_Item.GetItemNameByID(itemId))
        end
    end
end)

local function requestName(id)
    if D.itemIds[id] or not C_Item then return end
    local name = C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)
    if name then
        addItemName(id, name)
    elseif C_Item.RequestLoadItemDataByID then
        pendingNames[id] = true
        C_Item.RequestLoadItemDataByID(id)
    end
end

--- Index AtlasLoot's loot modules. Runs as a coroutine (yields between instances).
function Loot.Build()
    local AL = _G.AtlasLoot
    if not (AL and AL.ItemDB and AL.ItemDB.Storage and AL.Loader) then
        Loot.status = "absent"
        return
    end
    Loot.status = "loading"

    -- Load the modules through AtlasLoot's own loader (it defers loading during combat).
    for _, name in ipairs(LOOT_MODULES) do
        local loaded = false
        local result = AL.Loader:LoadModule(name, function() loaded = true end)
        if result == true then loaded = true end
        if result == nil or result == "DISABLED" or result == "MISSING" then loaded = nil end
        while loaded == false do coroutine.yield() end
    end

    for _, moduleName in ipairs(LOOT_MODULES) do
        local mod = AL.ItemDB.Storage[moduleName]
        if type(mod) == "table" then
            for key, inst in pairs(mod) do
                if type(key) == "string" and key:sub(1, 2) ~= "__" and type(inst) == "table" and type(inst.items) == "table" then
                    local instance = {
                        key = key, name = stripCodes(inst.name or key), areaId = inst.MapID,
                        levelRange = type(inst.LevelRange) == "table" and inst.LevelRange or nil,
                        bosses = {},
                    }
                    for _, b in ipairs(inst.items) do
                        if type(b) == "table" and b.name then
                            local boss = { name = stripCodes(b.name), npcId = firstNpcId(b.npcID), instance = instance, items = {} }
                            local seen = {}
                            for difficulty, list in pairs(b) do
                                if type(difficulty) == "number" and type(list) == "table" then
                                    for _, entry in ipairs(list) do
                                        local id = type(entry) == "table" and entry[2]
                                        if type(id) == "number" and id > 0 and not seen[id] then
                                            seen[id] = true
                                            boss.items[#boss.items + 1] = id
                                            local sources = Loot.byItem[id]
                                            if not sources then sources = {}; Loot.byItem[id] = sources end
                                            sources[#sources + 1] = { boss = boss, rate = boss.npcId and Loot.DropRate(boss.npcId, id) }
                                            requestName(id)
                                        end
                                    end
                                end
                            end
                            if #boss.items > 0 then
                                instance.bosses[#instance.bosses + 1] = boss
                                Loot.bossNames[#Loot.bossNames + 1] = { D.NameKey(boss.name), boss, boss.name }
                            end
                        end
                    end
                    if #instance.bosses > 0 then
                        Loot.instances[#Loot.instances + 1] = instance
                        Loot.instanceNames[#Loot.instanceNames + 1] = { D.NameKey(instance.name), instance, instance.name }
                    end
                    coroutine.yield()
                end
            end
        end
    end
    Loot.status = "ready"
end

--- A place for the instance's entrance(s), from Questie's dungeon table, or nil.
function Loot.EntrancePlace(instance)
    if instance.entrance ~= nil then return instance.entrance or nil end
    instance.entrance = false
    local zoneDB = QuestieLoader and QuestieLoader:ImportModule("ZoneDB")
    local ok, dungeons = pcall(function() return zoneDB:GetDungeons() end)
    local d = ok and type(dungeons) == "table" and instance.areaId and dungeons[instance.areaId]
    if d and type(d[4]) == "table" then
        local spawnList = {}
        for _, e in ipairs(d[4]) do
            if type(e) == "table" and e[1] then
                spawnList[e[1]] = spawnList[e[1]] or {}
                table.insert(spawnList[e[1]], { e[2], e[3] })
            end
        end
        local spawns = D.ResolveSpawns(spawnList)
        if #spawns > 0 then
            instance.entrance = { kind = "entrance", name = instance.name .. " entrance", spawns = spawns }
        end
    end
    return instance.entrance or nil
end

--------------------------------------------------------------------------------------------
-- Auctionator
--------------------------------------------------------------------------------------------

local Prices = {}
AskBot.Prices = Prices

function Prices.Available()
    return _G.Auctionator ~= nil and Auctionator.API and Auctionator.API.v1 ~= nil
end

local function call(fn, id)
    if not Prices.Available() or not Auctionator.API.v1[fn] then return nil end
    local ok, v = pcall(Auctionator.API.v1[fn], ADDON_NAME, id)
    return ok and v or nil
end

function Prices.Auction(id) return call("GetAuctionPriceByItemID", id) end
function Prices.AgeDays(id) return call("GetAuctionAgeByItemID", id) end
function Prices.VendorBuy(id) return call("GetVendorPriceByItemID", id) end

--- What a vendor pays you for the item (from the game's item info), or nil.
function Prices.VendorSell(id)
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if not getInfo then return nil end
    local sell = select(11, getInfo(id))
    return (sell and sell > 0) and sell or nil
end

--- Is the auction house window open? (Searches only work then.)
function Prices.IsAHOpen()
    return (AuctionFrame and AuctionFrame:IsShown()) or (AuctionHouseFrame and AuctionHouseFrame:IsShown()) or false
end

-- Auctionator calls us back whenever new prices are stored (a search or a full scan).
local updateListeners = {}
local registeredForUpdates = false
local function listenForUpdates()
    if registeredForUpdates or not (Prices.Available() and Auctionator.API.v1.RegisterForDBUpdate) then return end
    registeredForUpdates = pcall(Auctionator.API.v1.RegisterForDBUpdate, ADDON_NAME, function()
        for token, fn in pairs(updateListeners) do fn(token) end
    end)
end

local function itemNameFor(id)
    return (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)) or (ItemDB and ItemDB.name(id))
end

--- Search the open auction house for these items through Auctionator, then call
--- onDone(results, reason) with results = { { id, before, after, age }, ... }.
--- reason is "done", "timeout", or an error message.
function Prices.Refresh(ids, onDone)
    local names, results = {}, {}
    for _, id in ipairs(ids) do
        local name = itemNameFor(id)
        if name then
            names[#names + 1] = name
            results[#results + 1] = { id = id, before = Prices.Auction(id) }
        end
    end
    if #names == 0 then return onDone(results, "no item names") end
    listenForUpdates()

    local token, finished, quietTimer, limitTimer = {}, false, nil, nil
    local function finish(reason)
        if finished then return end
        finished = true
        updateListeners[token] = nil
        if quietTimer then quietTimer:Cancel() end
        if limitTimer then limitTimer:Cancel() end
        for _, r in ipairs(results) do
            r.after, r.age = Prices.Auction(r.id), Prices.AgeDays(r.id)
        end
        onDone(results, reason)
    end
    -- Results can arrive in several batches; finish once they've been quiet for a moment.
    updateListeners[token] = function()
        if quietTimer then quietTimer:Cancel() end
        quietTimer = C_Timer.NewTimer(#names > 1 and 3 or 0.5, function() finish("done") end)
    end
    limitTimer = C_Timer.NewTimer(math.min(120, 10 + 3 * #names), function() finish("timeout") end)

    local ok, err = pcall(Auctionator.API.v1.MultiSearchExact, ADDON_NAME, names)
    if not ok then finish(tostring(err)) end
end

--- Items whose prices this character has asked about, for /ab refresh prices.
function Prices.Watch(id)
    if AskBotCharDB then
        AskBotCharDB.priceWatch = AskBotCharDB.priceWatch or {}
        AskBotCharDB.priceWatch[id] = true
    end
end

function Prices.WatchedIds()
    local ids = {}
    for id in pairs(AskBotCharDB and AskBotCharDB.priceWatch or {}) do ids[#ids + 1] = id end
    table.sort(ids)
    return ids
end

function Prices.Format(copper)
    if GetMoneyString then return GetMoneyString(copper, true) end
    local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
    local parts = {}
    if g > 0 then parts[#parts + 1] = g .. "g" end
    if s > 0 then parts[#parts + 1] = s .. "s" end
    if c > 0 or #parts == 0 then parts[#parts + 1] = c .. "c" end
    return table.concat(parts, " ")
end
