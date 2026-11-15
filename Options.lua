-- Options.lua
-- Account-wide settings (AskBotDB) and their panel in the game's Settings > AddOns.

local _, AskBot = ...

local DEFAULTS = {
    autoPin = true,       -- pin the best answer automatically
    maxResults = 3,       -- places listed for "nearest" questions
    shareGuild = false,   -- answer "!ask" questions in guild chat
    shareParty = false,   -- ... in party and raid chat
    shareWhisper = false, -- ... in whispers
    rareAlerts = true,    -- say when a zone you enter has a rare that drops an upgrade
}
AskBot.DEFAULTS = DEFAULTS

function AskBot.Option(key)
    local v = AskBotDB and AskBotDB[key]
    if v == nil then return DEFAULTS[key] end
    return v
end

function AskBot.SetOption(key, value)
    AskBotDB = AskBotDB or {}
    AskBotDB[key] = value
end

local category

local function registerPanel()
    if not (Settings and Settings.RegisterVerticalLayoutCategory and Settings.RegisterAddOnSetting) then return end
    category = Settings.RegisterVerticalLayoutCategory("AskBot")

    local function checkbox(key, name, tooltip)
        local setting = Settings.RegisterAddOnSetting(category, "ASKBOT_" .. key, key, AskBotDB,
            Settings.VarType.Boolean, name, DEFAULTS[key])
        Settings.CreateCheckbox(category, setting, tooltip)
    end

    checkbox("autoPin", "Pin the best answer",
        "Put a waypoint on the best answer automatically. You can always click [pin] on any answer.")

    local results = Settings.RegisterAddOnSetting(category, "ASKBOT_maxResults", "maxResults", AskBotDB,
        Settings.VarType.Number, "Results per answer", DEFAULTS.maxResults)
    local sliderOptions = Settings.CreateSliderOptions(1, 5, 1)
    if MinimalSliderWithSteppersMixin then
        sliderOptions:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right)
    end
    Settings.CreateSlider(category, results, sliderOptions,
        "How many places to list for questions like 'nearest skinning trainer'.")

    checkbox("rareAlerts", "Rare alerts",
        "When you enter a zone, say if a rare mob near your level there can drop an upgrade for you.")

    checkbox("shareGuild", "Answer !ask in guild chat",
        "When a guild member types '!ask <question>' in guild chat, AskBot answers there for them.")
    checkbox("shareParty", "Answer !ask in party and raid chat",
        "When someone in your group types '!ask <question>', AskBot answers in party or raid chat.")
    checkbox("shareWhisper", "Answer !ask in whispers",
        "When someone whispers you '!ask <question>', AskBot whispers the answer back.")

    Settings.RegisterAddOnCategory(category)
end

--- Open the settings panel; false if this client has no Settings panel API.
function AskBot.OpenOptions()
    if category and Settings and Settings.OpenToCategory then
        Settings.OpenToCategory(category:GetID())
        return true
    end
    return false
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function()
    AskBotDB = AskBotDB or {}
    for k, v in pairs(DEFAULTS) do
        if AskBotDB[k] == nil then AskBotDB[k] = v end
    end
    local ok, err = pcall(registerPanel)
    if not ok then
        category = nil
        if geterrorhandler then geterrorhandler()("AskBot settings panel: " .. tostring(err)) end
    end
end)
