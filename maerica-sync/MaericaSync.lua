local addonName, ns = ...

local Json = ns.Json
local Snapshot = ns.Snapshot

local SCHEMA = 1
local REFRESH_DELAY = 0.3

local state = {
    ready = false,
    bankOpen = false,
    bankScan = nil,
    completed = nil,
    completedDirty = true,
    turnedIn = {},
    refreshPending = false,
    timer = nil,
}
ns.state = state

local function say(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99Maerica Sync|r: " .. msg)
end
ns.say = say

local function loadDocument()
    MaericaSyncDB = MaericaSyncDB or {}
    MaericaSyncDB.schema = SCHEMA
    MaericaSyncDB.minimap = MaericaSyncDB.minimap or {}
    if ns.GetSettings then
        ns.GetSettings()
    end

    local saved = MaericaSyncDB.json
    if type(saved) ~= "string" or saved == "" then
        ns.doc = { schema = SCHEMA, character = nil }
        return
    end

    local ok, doc = pcall(Json.decode, saved)
    if not ok or type(doc) ~= "table" then
        ns.loadError = ok and "saved document is not an object" or tostring(doc)
        say("|cffff4040could not read saved data (" .. ns.loadError .. "). Snapshots are paused this session; the existing file is kept.|r")
        return
    end

    -- This file is per-character. Migrate the old multi-character map if present.
    local character = doc.character
    if type(character) ~= "table" and type(doc.characters) == "table" then
        for _, row in pairs(doc.characters) do
            if type(row) == "table" then
                character = row
                break
            end
        end
    end
    ns.doc = { schema = SCHEMA, character = character }
end

local function completedQuests()
    if state.completedDirty or not state.completed then
        state.completed = Snapshot.QuestsCompleted(state.probe)
        state.completedDirty = false
    end
    local completed = state.completed
    if not completed then
        return nil
    end

    -- QUEST_TURNED_IN can fire before the completed flag is set.
    local seen = {}
    for _, row in ipairs(completed) do
        seen[row.id] = true
    end
    for id in pairs(state.turnedIn) do
        if not seen[id] then
            completed[#completed + 1] = { id = id }
        end
    end
    table.sort(completed, function(a, b) return a.id < b.id end)
    return completed
end

local function buildCharacter()
    local probe = state.probe
    local now = time()
    local char, key = Snapshot.Identity()
    local previous = ns.doc.character
    if type(previous) ~= "table" or previous.guid ~= key then
        previous = nil
    end

    char.snapshotTime = now
    char.location = Snapshot.Location()
    char.moneyCopper = GetMoney()
    char.items, char.bags = Snapshot.Inventory(probe)

    if state.bankOpen then
        state.bankScan = Snapshot.Bank(probe, now)
    end
    char.bank = state.bankScan or (previous and previous.bank) or Snapshot.EmptyBank()

    local skills = Snapshot.Skills(probe)
    char.skillsSource = probe.skills
    if skills then
        char.skills = skills
    end

    local statistics = Snapshot.Statistics(probe)
    char.statisticsSource = probe.statistics
    if statistics then
        char.statistics = statistics
    end

    char.talents = Snapshot.Talents(probe)

    char.quests = {
        inProgressSource = probe.questLog,
        inProgress = Snapshot.QuestsInProgress(probe),
        completedSource = probe.completed,
        completed = completedQuests(),
    }

    return key, char
end

-- Rebuilds the logged-in character and re-encodes MaericaSyncDB.json.
-- Each character has their own SavedVariables file; this one never holds alts.
function ns.Refresh()
    if not state.ready or not ns.doc then
        return false
    end
    local ok, key, char = pcall(buildCharacter)
    if not ok then
        if ns.lastError ~= key then
            ns.lastError = key
            say("|cffff4040snapshot failed: " .. tostring(key) .. "|r")
        end
        return false
    end
    ns.doc = { schema = SCHEMA, character = char }
    ns.current = char
    MaericaSyncDB.json = Json.encode(ns.doc)
    return true
end

local function scheduleRefresh()
    if not (C_Timer and C_Timer.After) then
        ns.Refresh()
        return
    end
    if state.refreshPending then
        return
    end
    state.refreshPending = true
    C_Timer.After(REFRESH_DELAY, function()
        state.refreshPending = false
        ns.Refresh()
    end)
end

function ns.Status()
    if ns.loadError then
        return "saved data unreadable: " .. ns.loadError
    end
    local char = ns.current
    if not char then
        return "no snapshot yet"
    end
    local quests = char.quests or {}
    return string.format(
        "%s-%s, %d items, talents: %s, completed quests: %s (%d), bank scanned: %s",
        tostring(char.name),
        tostring(char.realm),
        #char.items,
        tostring(char.talents and char.talents.source),
        tostring(quests.completedSource),
        quests.completed and #quests.completed or 0,
        char.bank and char.bank.scanned and "yes" or "no"
    )
end

local frame = CreateFrame("Frame")
local handlers = {}

function ns.RestartTimer()
    if state.timer then
        state.timer:Cancel()
        state.timer = nil
    end
    if not state.ready or not ns.GetSettings then
        return
    end
    local settings = ns.GetSettings()
    if not settings.timerEnabled then
        return
    end
    if not (C_Timer and C_Timer.NewTicker) then
        return
    end
    local seconds = math.max(60, math.floor(settings.timerMinutes * 60))
    state.timer = C_Timer.NewTicker(seconds, function()
        if state.ready then
            ns.Refresh()
        end
    end)
end

function handlers.ADDON_LOADED(name)
    if name ~= addonName then
        return
    end
    frame:UnregisterEvent("ADDON_LOADED")
    loadDocument()
    if ns.InitOptions then
        ns.InitOptions()
    end
    if ns.InitFrame then
        ns.InitFrame()
    end
end

local function reloadUI()
    if C_UI and C_UI.Reload then
        C_UI.Reload()
    elseif ReloadUI then
        ReloadUI()
    end
end

-- Refresh and write maerica-sync.lua. WoW only flushes SavedVariables on
-- logout, quit, or UI reload, so writing the file requires a reload.
-- Must run from a click or keypress; a timer cannot call ReloadUI.
function ns.WriteToDisk()
    if not ns.Refresh() then
        say("|cffff4040snapshot not ready|r")
        return false
    end
    say("writing snapshot to file")
    reloadUI()
    return true
end

-- Encode the last good in-memory snapshot. Do not re-query unit APIs here;
-- at logout GetMoney and bags are often already empty.
local function persistCurrent()
    local char = ns.current
    if type(char) ~= "table" then
        return false
    end
    char.snapshotTime = time()
    ns.doc = { schema = SCHEMA, character = char }
    MaericaSyncDB.json = Json.encode(ns.doc)
    return true
end

function handlers.PLAYER_ENTERING_WORLD()
    if not state.probe then
        state.probe = Snapshot.Probe()
    end
    state.ready = true
    state.completedDirty = true
    ns.Refresh()
    ns.RestartTimer()
end

handlers.ZONE_CHANGED = scheduleRefresh
handlers.ZONE_CHANGED_INDOORS = scheduleRefresh
handlers.ZONE_CHANGED_NEW_AREA = scheduleRefresh
handlers.BAG_UPDATE = scheduleRefresh
handlers.PLAYER_MONEY = scheduleRefresh
handlers.PLAYER_LEVEL_UP = scheduleRefresh
handlers.SKILL_LINES_CHANGED = scheduleRefresh
handlers.CHARACTER_POINTS_CHANGED = scheduleRefresh
handlers.QUEST_LOG_UPDATE = scheduleRefresh
handlers.PLAYERBANKSLOTS_CHANGED = scheduleRefresh

function handlers.QUEST_TURNED_IN(questId)
    if type(questId) == "number" then
        state.turnedIn[questId] = true
    end
    state.completedDirty = true
    scheduleRefresh()
end

function handlers.BANKFRAME_OPENED()
    state.bankOpen = true
    scheduleRefresh()
end

function handlers.BANKFRAME_CLOSED()
    if state.bankOpen then
        ns.Refresh()
    end
    state.bankOpen = false
end

function handlers.PLAYER_LOGOUT()
    persistCurrent()
end

frame:SetScript("OnEvent", function(_, event, ...)
    local handler = handlers[event]
    if handler then
        handler(...)
    end
end)

-- Some events may not exist on this beta build; registering an unknown one errors.
for event in pairs(handlers) do
    pcall(frame.RegisterEvent, frame, event)
end

SLASH_MAERICASYNC1 = "/maericasync"
SlashCmdList.MAERICASYNC = function(msg)
    local cmd = type(msg) == "string" and msg:match("^%s*(%S*)") or ""
    cmd = cmd:lower()
    if cmd == "write" or cmd == "resync" then
        ns.WriteToDisk()
        return
    end
    if cmd == "options" or cmd == "config" or cmd == "settings" then
        if ns.OpenOptions then
            ns.OpenOptions()
        end
        return
    end
    ns.Refresh()
    say(ns.Status())
end
