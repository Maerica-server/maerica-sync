local _, ns = ...

local ICON = "Interface\\AddOns\\maerica-sync\\icon"
local DEFAULT_ANGLE = 210

local minimapButton

local function placeMinimapButton(angle)
    local radians = math.rad(angle)
    local radius = (Minimap:GetWidth() / 2) + 10
    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(radians) * radius, math.sin(radians) * radius)
end

local function cursorAngle()
    local mx, my = Minimap:GetCenter()
    local scale = Minimap:GetEffectiveScale()
    local px, py = GetCursorPosition()
    px, py = px / scale, py / scale
    return math.deg(math.atan2(py - my, px - mx)) % 360
end

local function createMinimapButton()
    local b = CreateFrame("Button", "MaericaSyncMinimapButton", Minimap)
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local background = b:CreateTexture(nil, "BACKGROUND")
    background:SetSize(20, 20)
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    background:SetPoint("TOPLEFT", 7, -5)

    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetSize(17, 17)
    icon:SetTexture(ICON)
    icon:SetPoint("TOPLEFT", 7, -6)

    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetPoint("TOPLEFT")

    b:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            ns.WriteToDisk()
            return
        end
        if IsShiftKeyDown and IsShiftKeyDown() and ns.OpenOptions then
            ns.OpenOptions()
            return
        end
        ns.Refresh()
        ns.say(ns.Status())
    end)

    b:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local angle = cursorAngle()
            MaericaSyncDB.minimap.angle = angle
            placeMinimapButton(angle)
        end)
    end)
    b:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)

    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Maerica Sync")
        GameTooltip:AddLine("Left-click: status in chat.", 1, 1, 1)
        GameTooltip:AddLine("Right-click: write snapshot file (reloads UI).", 1, 1, 1)
        GameTooltip:AddLine("Shift-click: options.", 1, 1, 1)
        GameTooltip:AddLine("Drag to move this button.", 1, 1, 1)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    return b
end

function ns.InitFrame()
    minimapButton = createMinimapButton()
    placeMinimapButton(MaericaSyncDB.minimap.angle or DEFAULT_ANGLE)
end
