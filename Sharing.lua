-- Sharing.lua
-- Answers "!ask <question>" typed by other players in guild, party/raid chat or whispers.
-- Opt-in per channel (see Options.lua), rate-limited, and coordinated so that when several
-- people in a guild run AskBot only one of them answers.

local _, AskBot = ...

local CHANNELS = {
    CHAT_MSG_GUILD = { option = "shareGuild", reply = "GUILD", sync = "GUILD" },
    CHAT_MSG_PARTY = { option = "shareParty", reply = "PARTY", sync = "PARTY" },
    CHAT_MSG_PARTY_LEADER = { option = "shareParty", reply = "PARTY", sync = "PARTY" },
    CHAT_MSG_RAID = { option = "shareParty", reply = "RAID", sync = "RAID" },
    CHAT_MSG_RAID_LEADER = { option = "shareParty", reply = "RAID", sync = "RAID" },
    CHAT_MSG_WHISPER = { option = "shareWhisper", reply = "WHISPER" },
}
local TRIGGERS = { "^!ask%s+(.+)$", "^!ab%s+(.+)$", "^!askbot%s+(.+)$" }
local SYNC_PREFIX = "AskBot"
local SENDER_COOLDOWN = 8 -- seconds between answers to the same person
local GLOBAL_COOLDOWN = 3 -- seconds between any two answers
local MAX_LINES = 4
local MAX_LENGTH = 250    -- chat messages are limited to 255 characters

local CLAIM_TIME = 30     -- seconds a question counts as answered
local claimed = {}        -- question key -> time someone's AskBot answered it
local lastBySender, lastAnswer = {}, -math.huge

local function shortName(name)
    return name and (name:match("^([^%-]+)") or name)
end

--------------------------------------------------------------------------------------------
-- Where is the asker?
--------------------------------------------------------------------------------------------

local zoneByName
--- The middle of a zone, by its name (guild members only tell us their zone).
local function zoneCenter(zoneName)
    local HBD = LibStub and LibStub("HereBeDragons-2.0", true)
    if not (HBD and zoneName and C_Map and C_Map.GetMapInfo) then return nil end
    if not zoneByName then
        zoneByName = {}
        for id in pairs(HBD.mapData or {}) do
            local info = C_Map.GetMapInfo(id)
            -- Prefer zones (3) over sub-maps (4+) with the same name.
            if info and info.name and info.mapType and info.mapType >= 3 then
                local current = zoneByName[info.name]
                if not current or info.mapType < current[2] then zoneByName[info.name] = { id, info.mapType } end
            end
        end
    end
    local entry = zoneByName[zoneName]
    if not entry then return nil end
    local x, y, inst = HBD:GetWorldCoordinatesFromZone(0.5, 0.5, entry[1])
    return x and { x = x, y = y, inst = inst } or nil
end

--- The asker's class, level and position: exact for group members, their zone for guild members.
local function findAsker(sender)
    local name = shortName(sender)
    local asker = { name = name }
    local HBD = LibStub and LibStub("HereBeDragons-2.0", true)

    local units = { "player" }
    if IsInRaid and IsInRaid() then
        for i = 1, 40 do units[#units + 1] = "raid" .. i end
    elseif IsInGroup and IsInGroup() then
        for i = 1, 4 do units[#units + 1] = "party" .. i end
    end
    for _, unit in ipairs(units) do
        if UnitExists(unit) and UnitName(unit) == name then
            local _, classFile = UnitClass(unit)
            asker.class, asker.level = classFile, UnitLevel(unit)
            local x, y, inst
            if HBD then x, y, inst = HBD:GetUnitWorldPosition(unit) end
            if x then asker.origin = { x = x, y = y, inst = inst } end
            return asker
        end
    end

    if IsInGuild and IsInGuild() and GetNumGuildMembers then
        for i = 1, GetNumGuildMembers() do
            local fullName, _, _, level, _, zone, _, _, _, _, classFile = GetGuildRosterInfo(i)
            if fullName and shortName(fullName) == name then
                asker.class, asker.level = classFile, level
                asker.origin = zoneCenter(zone)
                return asker
            end
        end
    end
    return asker
end

--------------------------------------------------------------------------------------------
-- Turning AskBot's chat lines into plain chat messages
--------------------------------------------------------------------------------------------

--- Strip colours, textures and AskBot's own links ([pin] etc.), keeping real item links.
function AskBot.ToChatText(line)
    local keep = {}
    line = line:gsub("|c%x%x%x%x%x%x%x%x|Hitem:.-|h.-|h|r", function(link)
        keep[#keep + 1] = link
        return "\001" .. #keep .. "\002"
    end)
    line = line:gsub("|Haddon:askbot:%d+|h%[(.-)%]|h", function(text)
        if text == "pin" or text == "loot" then return "" end
        return text
    end)
    line = line:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", ""):gsub("|H.-|h(.-)|h", "%1")
    line = line:gsub("\001(%d+)\002", function(n) return keep[tonumber(n)] end)
    line = line:gsub("%s+", " "):gsub("%s+([,%.%)])", "%1")
    return (line:match("^%s*(.-)%s*$"))
end

local function fitLength(line)
    if #line <= MAX_LENGTH then return line end
    -- Too long: drop item link codes (they can't be cut in half), then shorten.
    line = line:gsub("|c%x%x%x%x%x%x%x%x|Hitem:.-|h(.-)|h|r", "%1")
    if #line > MAX_LENGTH then line = line:sub(1, MAX_LENGTH - 3) .. "..." end
    return line
end

local function replyLines(question, sender)
    local out = {}
    if question:lower() == "help" then
        out[1] = "Ask me where things are, e.g. \"!ask nearest flight master\", \"!ask who gives <quest>\", "
            .. "\"!ask where does Linen Cloth drop\", \"!ask what does VanCleef drop\"."
    elseif AskBot.IsPersonalQuestion(question) then
        out[1] = "That one needs your own quest log or gear. Install AskBot and use /ab for it."
    else
        for _, line in ipairs(AskBot.AnswerFor(question, findAsker(sender))) do
            local text = AskBot.ToChatText(line)
            if text ~= "" then out[#out + 1] = text end
        end
    end
    if #out == 0 then out[1] = "Sorry, I don't know that one." end
    if #out > MAX_LINES then
        local extra = #out - MAX_LINES
        for i = #out, MAX_LINES + 1, -1 do out[i] = nil end
        out[MAX_LINES] = out[MAX_LINES] .. " (+" .. extra .. " more)"
    end
    out[1] = "[AskBot] " .. out[1]
    for i, line in ipairs(out) do out[i] = fitLength(line) end
    return out
end

--------------------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------------------

local function onChat(event, msg, sender)
    local channel = CHANNELS[event]
    if not channel or not AskBot.Option(channel.option) or type(msg) ~= "string" then return end
    local question
    for _, pattern in ipairs(TRIGGERS) do
        question = msg:match(pattern)
        if question then break end
    end
    if not question then return end
    question = question:match("^%s*(.-)%s*$")
    local name = shortName(sender)
    if lastBySender[name] and GetTime() - lastBySender[name] < SENDER_COOLDOWN then return end

    -- Several AskBots may hear the same question: wait a moment, and skip it if another
    -- one claims it first. The asker's own AskBot answers straight away.
    local key = (name .. ":" .. question):sub(1, 200)
    local isMe = name == UnitName("player")
    local delay = (channel.sync and not isMe) and (0.3 + math.random() * 1.2) or 0
    C_Timer.After(delay, function()
        if (claimed[key] and GetTime() - claimed[key] < CLAIM_TIME) or GetTime() - lastAnswer < GLOBAL_COOLDOWN then
            return
        end
        claimed[key] = GetTime()
        lastBySender[name], lastAnswer = GetTime(), GetTime()
        if channel.sync and C_ChatInfo and C_ChatInfo.SendAddonMessage then
            pcall(C_ChatInfo.SendAddonMessage, SYNC_PREFIX, "claim:" .. key, channel.sync)
        end
        local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
        for i, line in ipairs(replyLines(question, sender)) do
            C_Timer.After((i - 1) * 0.4, function()
                send(line, channel.reply, nil, channel.reply == "WHISPER" and sender or nil)
            end)
        end
    end)
end

local frame = CreateFrame("Frame")
for event in pairs(CHANNELS) do frame:RegisterEvent(event) end
frame:RegisterEvent("CHAT_MSG_ADDON")
if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
    C_ChatInfo.RegisterAddonMessagePrefix(SYNC_PREFIX)
end
frame:SetScript("OnEvent", function(_, event, ...)
    if event == "CHAT_MSG_ADDON" then
        local prefix, text, _, sender = ...
        if prefix == SYNC_PREFIX and shortName(sender) ~= UnitName("player") then
            local key = type(text) == "string" and text:match("^claim:(.+)$")
            if key then claimed[key] = GetTime() end
        end
        return
    end
    local ok, err = pcall(onChat, event, ...)
    if not ok and geterrorhandler then geterrorhandler()(err) end
end)
