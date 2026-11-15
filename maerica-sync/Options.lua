local addonName, ns = ...

local DEFAULT_TIMER_MINUTES = 15
local MIN_TIMER_MINUTES = 1
local MAX_TIMER_MINUTES = 180

function ns.GetSettings()
    MaericaSyncDB = MaericaSyncDB or {}
    local settings = MaericaSyncDB.settings
    if type(settings) ~= "table" then
        settings = {}
        MaericaSyncDB.settings = settings
    end
    if settings.timerEnabled == nil then
        settings.timerEnabled = false
    end
    local minutes = settings.timerMinutes
    if type(minutes) ~= "number" then
        minutes = DEFAULT_TIMER_MINUTES
    end
    minutes = math.floor(minutes + 0.5)
    if minutes < MIN_TIMER_MINUTES then
        minutes = MIN_TIMER_MINUTES
    elseif minutes > MAX_TIMER_MINUTES then
        minutes = MAX_TIMER_MINUTES
    end
    settings.timerMinutes = minutes
    return settings
end

local panel
local timerCheck
local minutesBox
local statusText

local function setStatus(msg)
    if statusText then
        statusText:SetText(msg or "")
    end
end

local function applyFromControls()
    local settings = ns.GetSettings()
    settings.timerEnabled = timerCheck:GetChecked() and true or false
    local minutes = tonumber(minutesBox:GetText())
    if minutes then
        settings.timerMinutes = minutes
    end
    ns.GetSettings()
    minutesBox:SetText(tostring(settings.timerMinutes))
    if ns.RestartTimer then
        ns.RestartTimer()
    end
    if settings.timerEnabled then
        setStatus(string.format("Timer on: refresh every %d min. File still writes on logout or right-click.", settings.timerMinutes))
    else
        setStatus("Timer off. Snapshot still updates on game events; file writes on logout or right-click.")
    end
end

local function refreshControls()
    local settings = ns.GetSettings()
    timerCheck:SetChecked(settings.timerEnabled and true or false)
    minutesBox:SetText(tostring(settings.timerMinutes))
    applyFromControls()
end

local function createPanel()
    local f = CreateFrame("Frame", "MaericaSyncOptionsPanel")
    f.name = "Maerica Sync"
    f:Hide()

    local title = f:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Maerica Sync")

    local blurb = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    blurb:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    blurb:SetPoint("RIGHT", f, "RIGHT", -16, 0)
    blurb:SetJustifyH("LEFT")
    blurb:SetWordWrap(true)
    blurb:SetText(
        "Logout always writes the last good snapshot to this character's file. "
            .. "A timer only refreshes the snapshot in memory (WoW blocks timed UI reloads). "
            .. "Right-click the minimap icon to write the file while playing."
    )

    local checkOk
    checkOk, timerCheck = pcall(CreateFrame, "CheckButton", "MaericaSyncTimerCheck", f, "InterfaceOptionsCheckButtonTemplate")
    if not checkOk or not timerCheck then
        timerCheck = CreateFrame("CheckButton", "MaericaSyncTimerCheck", f)
        timerCheck:SetSize(24, 24)
        timerCheck:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
        timerCheck:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
        timerCheck:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
        timerCheck:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight")
    end
    timerCheck:SetPoint("TOPLEFT", blurb, "BOTTOMLEFT", -2, -16)
    local checkLabel = _G[timerCheck:GetName() .. "Text"]
    if checkLabel then
        checkLabel:SetText("Enable periodic memory refresh")
    else
        local label = f:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        label:SetPoint("LEFT", timerCheck, "RIGHT", 4, 0)
        label:SetText("Enable periodic memory refresh")
    end
    timerCheck:SetScript("OnClick", applyFromControls)

    local minutesLabel = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    minutesLabel:SetPoint("TOPLEFT", timerCheck, "BOTTOMLEFT", 4, -12)
    minutesLabel:SetText(string.format("Minutes (%d-%d)", MIN_TIMER_MINUTES, MAX_TIMER_MINUTES))

    local boxOk
    boxOk, minutesBox = pcall(CreateFrame, "EditBox", "MaericaSyncTimerMinutes", f, "InputBoxTemplate")
    if not boxOk or not minutesBox then
        minutesBox = CreateFrame("EditBox", "MaericaSyncTimerMinutes", f)
        minutesBox:SetFontObject(ChatFontNormal)
        minutesBox:SetBackdrop({
            bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true,
            tileSize = 8,
            edgeSize = 8,
            insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        if minutesBox.SetBackdropColor then
            minutesBox:SetBackdropColor(0, 0, 0, 0.8)
        end
    end
    minutesBox:SetSize(60, 20)
    minutesBox:SetPoint("LEFT", minutesLabel, "RIGHT", 12, 0)
    minutesBox:SetAutoFocus(false)
    minutesBox:SetMaxLetters(3)
    if minutesBox.SetNumeric then
        minutesBox:SetNumeric(true)
    end
    minutesBox:SetScript("OnEnterPressed", function(self)
        applyFromControls()
        self:ClearFocus()
    end)
    minutesBox:SetScript("OnEditFocusLost", applyFromControls)

    statusText = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    statusText:SetPoint("TOPLEFT", minutesLabel, "BOTTOMLEFT", 0, -18)
    statusText:SetPoint("RIGHT", f, "RIGHT", -16, 0)
    statusText:SetJustifyH("LEFT")
    statusText:SetWordWrap(true)

    f.OnCommit = applyFromControls
    f.okay = applyFromControls
    f.OnRefresh = refreshControls
    f.refresh = refreshControls
    f.OnDefault = function()
        local settings = ns.GetSettings()
        settings.timerEnabled = false
        settings.timerMinutes = DEFAULT_TIMER_MINUTES
        refreshControls()
    end
    f.default = f.OnDefault

    return f
end

function ns.OpenOptions()
    if not panel then
        return
    end
    refreshControls()
    if Settings and Settings.OpenToCategory then
        Settings.OpenToCategory(panel.name)
        return
    end
    if InterfaceOptionsFrame_OpenToCategory then
        InterfaceOptionsFrame_OpenToCategory(panel)
        InterfaceOptionsFrame_OpenToCategory(panel)
        return
    end
    panel:SetParent(UIParent)
    panel:ClearAllPoints()
    panel:SetSize(420, 260)
    panel:SetPoint("CENTER")
    if panel.SetBackdrop then
        panel:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true,
            tileSize = 32,
            edgeSize = 32,
            insets = { left = 8, right = 8, top = 8, bottom = 8 },
        })
    end
    panel:Show()
end

function ns.InitOptions()
    panel = createPanel()
    if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
        if category then
            category.ID = panel.name
            Settings.RegisterAddOnCategory(category)
        end
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end
end
