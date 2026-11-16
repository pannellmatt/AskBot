-- Output.lua
-- Chat output, who's asking, pins and clickable links, map icons, and formatting answers.
-- Shared helpers go on AskBot.Out; so does state other files change (outputSink, mapCapture,
-- pendingQuestion), which must be read as Out.<name>, never copied into a local.

local ADDON_NAME, AskBot = ...
local D = AskBot.Data
local Out = {} -- shared helpers and state for the other AskBot files
AskBot.Out = Out

local QUESTIEDB_CONTRACT = 4 -- the QuestieDB API contract this addon was written against
local PREFIX = "|cff33ccffAskBot|r: "
local GOLD, GREY = "|cffffd100", "|cffaaaaaa"

-- Answers go to the chat window the last /askbot was typed in (remembered per character),
-- falling back to the default chat window.
local outputFrame
Out.outputSink = nil -- when answering someone else in chat, lines are collected here instead

local function say(msg)
    if Out.outputSink then
        Out.outputSink[#Out.outputSink + 1] = msg
        return
    end
    local frame = outputFrame
    if not frame and AskBotCharDB and AskBotCharDB.chatFrame then
        frame = _G["ChatFrame" .. AskBotCharDB.chatFrame]
    end
    (frame or DEFAULT_CHAT_FRAME):AddMessage(PREFIX .. msg)
end

local function useChatFrameOf(editBox)
    local frame = editBox and editBox.chatFrame
    if frame and frame.AddMessage then
        outputFrame = frame
        local id = frame.GetID and frame:GetID()
        if AskBotCharDB and id and _G["ChatFrame" .. id] == frame then AskBotCharDB.chatFrame = id end
    end
end

local targetsById = {}
for _, t in ipairs(AskBot.targets) do targetsById[t.id] = t end

-- Who's asking: AskBot.asker is set while answering someone else's "!ask" in chat.
local function askerClass()
    if AskBot.asker and AskBot.asker.class then return AskBot.asker.class end
    local _, classFile = UnitClass("player")
    return classFile
end

local function askerLevel()
    return (AskBot.asker and AskBot.asker.level) or UnitLevel("player") or 1
end

Out.pendingQuestion = nil -- asked before the index was ready

--------------------------------------------------------------------------------------------
-- Pins and clickable links
--------------------------------------------------------------------------------------------

local lastTomTomWaypoint

-- "/ab show all ...": icons on the world map and minimap for every place an answer found.
local mapIcons, mapIconPool = {}, {}
Out.mapCapture = nil -- while answering "show all": list of places the answer showed

local function hbdPins()
    return LibStub and LibStub("HereBeDragons-Pins-2.0", true)
end

local function clearMapIcons()
    local pins = hbdPins()
    if pins then
        pcall(pins.RemoveAllWorldMapIcons, pins, AskBot)
        pcall(pins.RemoveAllMinimapIcons, pins, AskBot)
    end
    for _, icon in ipairs(mapIcons) do
        icon:Hide()
        mapIconPool[#mapIconPool + 1] = icon
    end
    mapIcons = {}
end

local function captureForMap(places)
    if not Out.mapCapture then return end
    for _, p in ipairs(places) do Out.mapCapture[#Out.mapCapture + 1] = p end
end

local function clearPins()
    clearMapIcons()
    if lastTomTomWaypoint and TomTom and TomTom.RemoveWaypoint then
        pcall(TomTom.RemoveWaypoint, TomTom, lastTomTomWaypoint)
    end
    lastTomTomWaypoint = nil
    if C_Map and C_Map.ClearUserWaypoint then pcall(C_Map.ClearUserWaypoint) end
end

local function placePin(place, spawn, label)
    local title = place.name .. (label and (" (" .. label .. ")") or "")
    local x, y = spawn.x / 100, spawn.y / 100

    if TomTom and TomTom.AddWaypoint then
        if lastTomTomWaypoint and TomTom.RemoveWaypoint then
            pcall(TomTom.RemoveWaypoint, TomTom, lastTomTomWaypoint)
        end
        local ok, uid = pcall(TomTom.AddWaypoint, TomTom, spawn.uiMapId, x, y, {
            title = title, from = ADDON_NAME, persistent = false,
            minimap = true, world = true, crazy = true,
        })
        if ok and uid then
            lastTomTomWaypoint = uid
            return "TomTom waypoint set"
        end
    end

    if C_Map and C_Map.SetUserWaypoint and UiMapPoint then
        local ok = pcall(function()
            if C_Map.CanSetUserWaypointOnMap and not C_Map.CanSetUserWaypointOnMap(spawn.uiMapId) then
                error("map does not allow waypoints")
            end
            C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(spawn.uiMapId, x, y))
            if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
                C_SuperTrack.SetSuperTrackedUserWaypoint(true)
            end
        end)
        if ok then return "map pin set" end
    end
end

--- Pins placed by answers (not clicks): only for your own questions, and only when the
--- "Pin the best answer" setting is on.
local function autoPin(place, spawn, label)
    if AskBot.asker or not AskBot.Option("autoPin") then return end
    placePin(place, spawn, label)
end

-- Clickable chat links: each stores a function to run when clicked.
local links, linkCount = {}, 0

--- A clickable "[text]" in link blue; with `color`, the text in that colour and no brackets.
local function makeLink(text, run, color)
    linkCount = linkCount + 1
    links[linkCount] = run
    if color then return color .. "|Haddon:askbot:" .. linkCount .. "|h" .. text .. "|h|r" end
    return "|cff71d5ff|Haddon:askbot:" .. linkCount .. "|h[" .. text .. "]|h|r"
end

local function pinLink(place, spawn, label)
    -- Answering someone else: a marker that Sharing.lua turns into a map pin link and /way.
    if AskBot.asker then return string.format("\003%d:%.1f:%.1f\004", spawn.uiMapId, spawn.x, spawn.y) end
    return makeLink("pin", function()
        if not placePin(place, spawn, label) then say("Couldn't set a pin for " .. GOLD .. place.name .. "|r.") end
    end)
end

local function onLinkClicked(link)
    local n = type(link) == "string" and link:match("^addon:askbot:(%d+)")
    local run = n and links[tonumber(n)]
    if run then run() end
end

if EventRegistry and EventRegistry.RegisterCallback then
    EventRegistry:RegisterCallback("SetItemRef", function(_, link) onLinkClicked(link) end)
elseif SetItemRef then
    hooksecurefunc("SetItemRef", onLinkClicked)
end

--------------------------------------------------------------------------------------------
-- Formatting
--------------------------------------------------------------------------------------------

local function formatYards(d)
    local n = math.floor(d + 0.5)
    return (BreakUpLargeNumbers and BreakUpLargeNumbers(n) or tostring(n)) .. " yds"
end

local function formatTime(t)
    if t < 60 then return "<1 min" end
    return "~" .. math.floor(t / 60 + 0.5) .. " min"
end

local function levelText(place)
    local lo, hi = place.minLevel, place.maxLevel
    if not lo or lo <= 0 then return "" end
    if hi and hi ~= lo then return " lvl " .. lo .. "-" .. hi end
    return " lvl " .. lo
end

--- One line describing a ranked result, with a [pin] link.
--- "Westfall 42.6, 71.8 (300 yds, ~1 min) [pin]" for a ranked result.
local function whereText(r, label)
    local p, s = r.place, r.spawn
    local where = string.format("%s %.1f, %.1f", D.ZoneName(s.uiMapId), s.x, s.y)
    if s.dungeon then where = "in " .. s.dungeon .. ", entrance " .. where end
    local how
    if r.time and r.steps and #r.steps > 0 then
        how = " (" .. formatTime(r.time) .. ", " .. D.RouteText(r.steps) .. ")"
    elseif r.dist then
        how = string.format(" (%s, %s)", formatYards(r.dist), formatTime(r.time))
    else
        how = " (other continent)"
    end
    return where .. how .. " " .. pinLink(p, s, label)
end

--- Compact travel for one-line answers: "75 yds", "~2 min", "~7 min flying", "~8 min by boat".
local function shortHow(r)
    if not r.time then return r.dist and formatYards(r.dist) or "other continent" end
    local by
    for _, s in ipairs(r.steps or {}) do
        if s.kind == "hearth" then by = " via hearth"; break end
        if s.kind == "boat" or s.kind == "zeppelin" then by = " by " .. s.kind; break end
        if s.kind == "fly" then by = " flying" end
    end
    if not by and r.dist and r.dist < 1000 then return formatYards(r.dist) end
    return formatTime(r.time) .. (by or "")
end

local function formatRate(rate)
    if not rate then return "" end
    local text = rate >= 10 and tostring(math.floor(rate + 0.5)) or string.format("%.1f", rate)
    return " |cff66cc33" .. text .. "%|r"
end

--- One line describing a ranked result, with a [pin] link. `extra(place)` may add text
--- after the name (e.g. a drop rate).
local function describe(r, label, showLevel, extra)
    local p = r.place
    local sub = p.sub and (" <" .. p.sub .. ">") or ""
    local lvl = showLevel and levelText(p) or ""
    local more = extra and extra(p) or ""
    return GOLD .. p.name .. "|r" .. sub .. lvl .. more .. " - " .. whereText(r, label)
end

--- Print up to `max` ranked results under a heading; pin the first if `pin` is set.
--- Returns the best result.
local function showRanked(places, heading, label, max, opts)
    opts = opts or {}
    captureForMap(places)
    local results, havePosition = D.Rank(places)
    if #results == 0 then return nil end
    if heading then
        if #results > max and opts.countNoun then
            heading = heading:gsub(":$", " (" .. #results .. " " .. opts.countNoun .. "):")
        end
        say(heading)
    end
    for i = 1, math.min(max, #results) do
        say("  " .. describe(results[i], label, opts.showLevel, opts.extra))
    end
    if not havePosition then
        say(GREY .. "  (No position known, so these aren't sorted by distance.)|r")
    end
    return results[1]
end

--- Put an icon on the world map and minimap for every spawn of every captured place.
--- Returns how many icons went up (at most `max`), or nil if the map library is missing.
local function showOnMap(places, label, max)
    local pins = hbdPins()
    if not pins or not CreateFrame then return nil end
    clearMapIcons()
    local n = 0
    for _, place in ipairs(places) do
        for _, s in ipairs(place.spawns or {}) do
            if n >= max then return n end
            if s.uiMapId and s.x then
                local icon = table.remove(mapIconPool)
                if not icon then
                    icon = CreateFrame("Button", nil, UIParent)
                    icon:SetSize(14, 14)
                    local tex = icon:CreateTexture(nil, "OVERLAY")
                    tex:SetAllPoints()
                    tex:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_1")
                    icon:SetScript("OnEnter", function(self)
                        if GameTooltip then
                            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                            GameTooltip:SetText(self.title or "")
                            GameTooltip:Show()
                        end
                    end)
                    icon:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
                    icon:SetScript("OnClick", function(self) placePin(self.place, self.spawn, self.label) end)
                end
                icon.place, icon.spawn, icon.label = place, s, label
                icon.title = place.name .. (place.sub and (" <" .. place.sub .. ">") or "")
                local ok = pcall(pins.AddWorldMapIconMap, pins, AskBot, icon, s.uiMapId, s.x / 100, s.y / 100,
                    HBD_PINS_WORLDMAP_SHOW_PARENT or 1)
                if ok then
                    local mini = table.remove(mapIconPool)
                    pcall(pins.AddMinimapIconMap, pins, AskBot, icon, s.uiMapId, s.x / 100, s.y / 100, true, false)
                    if mini then mapIconPool[#mapIconPool + 1] = mini end
                    mapIcons[#mapIcons + 1] = icon
                    n = n + 1
                else
                    mapIconPool[#mapIconPool + 1] = icon
                end
            end
        end
    end
    return n
end

local function pinBest(best, label)
    if best then autoPin(best.place, best.spawn, label) end
end

--- Offer alternative names as links; clicking one asks `template` (a format string) again.
local function didYouMean(others, template)
    if not others or #others == 0 then return end
    local parts = {}
    for i, name in ipairs(others) do
        local question = template:format(name)
        parts[i] = makeLink(name, function() AskBot.Ask(question) end)
    end
    say(GREY .. "Did you mean:|r " .. table.concat(parts, " ") .. GREY .. "?|r")
end

-- For the files loaded after this one.
Out.QUESTIEDB_CONTRACT, Out.GOLD, Out.GREY, Out.say = QUESTIEDB_CONTRACT, GOLD, GREY, say
Out.useChatFrameOf, Out.targetsById, Out.askerClass = useChatFrameOf, targetsById, askerClass
Out.askerLevel, Out.captureForMap, Out.clearPins, Out.autoPin = askerLevel, captureForMap, clearPins, autoPin
Out.makeLink, Out.pinLink, Out.formatTime, Out.whereText = makeLink, pinLink, formatTime, whereText
Out.shortHow, Out.formatRate, Out.describe, Out.showRanked = shortHow, formatRate, describe, showRanked
Out.showOnMap, Out.pinBest, Out.didYouMean = showOnMap, pinBest, didYouMean
