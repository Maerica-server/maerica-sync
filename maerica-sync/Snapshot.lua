local _, ns = ...

local Json = ns.Json
local Snapshot = {}
ns.Snapshot = Snapshot

local UNSUPPORTED = "unsupported"
local FIRST_EQUIPPED_SLOT = 1
local LAST_EQUIPPED_SLOT = 23

local function round(n, places)
    local m = 10 ^ places
    return math.floor(n * m + 0.5) / m
end

-- Which API family this build exposes. Run once at login.
function Snapshot.Probe()
    local probe = {}

    if C_Container and C_Container.GetContainerItemInfo then
        probe.container = "C_Container"
    elseif GetContainerItemInfo then
        probe.container = "GetContainerItemInfo"
    else
        probe.container = UNSUPPORTED
    end

    -- Forever/Anniversary moved the skill panel under C_SkillInfo; Era keeps the globals.
    if C_SkillInfo and C_SkillInfo.GetNumSkillLines and C_SkillInfo.GetSkillLineInfo then
        probe.skills = "C_SkillInfo.GetSkillLineInfo"
    elseif GetNumSkillLines and GetSkillLineInfo then
        probe.skills = "GetSkillLineInfo"
    else
        probe.skills = UNSUPPORTED
    end

    -- Forever talent trees live in C_Traits (classic GetNumTalentTabs is gone).
    if C_ClassTalents and C_ClassTalents.GetActiveConfigID and C_Traits and C_Traits.GetTreeNodes and C_Traits.GetNodeInfo then
        probe.talents = "C_Traits"
    elseif C_SpecializationInfo and C_SpecializationInfo.GetTalentInfo then
        probe.talents = "C_SpecializationInfo.GetTalentInfo"
    elseif GetNumTalentTabs and GetNumTalents and GetTalentInfo then
        probe.talents = "GetTalentInfo"
    else
        probe.talents = UNSUPPORTED
    end
    if probe.talents == "C_Traits" and C_Traits.GetTreeCurrencyInfo then
        probe.unspent = "C_Traits.GetTreeCurrencyInfo"
    elseif GetUnspentTalentPoints then
        probe.unspent = "GetUnspentTalentPoints"
    elseif UnitCharacterPoints then
        probe.unspent = "UnitCharacterPoints"
    else
        -- Vanilla: one point per level after 9, minus points already spent.
        probe.unspent = "derived"
    end

    if C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo then
        probe.questLog = "C_QuestLog.GetInfo"
    elseif GetNumQuestLogEntries and GetQuestLogTitle then
        probe.questLog = "GetQuestLogTitle"
    else
        probe.questLog = UNSUPPORTED
    end

    if C_QuestLog and C_QuestLog.GetAllCompletedQuestIDs then
        probe.completed = "C_QuestLog.GetAllCompletedQuestIDs"
    elseif GetQuestsCompleted then
        probe.completed = "GetQuestsCompleted"
    else
        probe.completed = UNSUPPORTED
    end

    -- The Statistics window: categories, in-list headers, and the displayed value.
    if GetStatisticsCategoryList and GetCategoryInfo and GetCategoryNumAchievements
        and GetAchievementInfo and GetStatistic then
        probe.statistics = "GetStatisticsCategoryList"
    else
        probe.statistics = UNSUPPORTED
    end

    return probe
end

local function normalizeRealm(s)
    return (tostring(s):gsub("[%s'%-_]", "")):lower()
end

-- UnitName splits on "-". Names like Xub-Pally come back as ("Xub", "Pally").
-- Reattach the suffix when it is not the player's actual realm.
local function playerName()
    local name, unitRealm = UnitName("player")
    if type(name) ~= "string" then
        return name
    end
    if type(unitRealm) ~= "string" or unitRealm == "" then
        return name
    end
    local realm = GetRealmName()
    if type(realm) == "string" and normalizeRealm(unitRealm) == normalizeRealm(realm) then
        return name
    end
    return name .. "-" .. unitRealm
end

function Snapshot.Identity()
    local guid = UnitGUID and UnitGUID("player") or nil
    local name = playerName()
    local realm = GetRealmName()
    local _, race = UnitRace("player")
    local _, class = UnitClass("player")
    return {
        guid = guid or Json.null,
        name = name,
        realm = realm,
        faction = UnitFactionGroup("player") or Json.null,
        race = race or Json.null,
        class = class or Json.null,
        level = UnitLevel("player"),
    }, guid or (tostring(name) .. "-" .. tostring(realm))
end

function Snapshot.Location()
    local location = {
        zone = GetZoneText() or "",
        subzone = GetSubZoneText() or "",
    }
    if C_Map and C_Map.GetBestMapForUnit then
        local mapId = C_Map.GetBestMapForUnit("player")
        if mapId then
            location.mapId = mapId
            local info = C_Map.GetMapInfo and C_Map.GetMapInfo(mapId)
            if info and info.name then
                location.mapName = info.name
            end
            local pos = C_Map.GetPlayerMapPosition and C_Map.GetPlayerMapPosition(mapId, "player")
            if pos then
                local x, y = pos:GetXY()
                if x and y and (x ~= 0 or y ~= 0) then
                    location.x = round(x, 4)
                    location.y = round(y, 4)
                    -- World yards on the continent, so the dashboard can place
                    -- every character on one seamless map. Nil inside instances.
                    if C_Map.GetWorldPosFromMapPos then
                        local continentId, world = C_Map.GetWorldPosFromMapPos(mapId, pos)
                        if continentId and world then
                            local wx, wy = world:GetXY()
                            if wx and wy then
                                location.continentId = continentId
                                location.worldX = round(wx, 1)
                                location.worldY = round(wy, 1)
                            end
                        end
                    end
                end
            end
        end
    end
    return location
end

local function itemLevel(link)
    if GetDetailedItemLevelInfo then
        local level = GetDetailedItemLevelInfo(link)
        if level and level > 0 then
            return level
        end
    end
    if GetItemInfo then
        local level = select(4, GetItemInfo(link))
        if level and level > 0 then
            return level
        end
    end
end

local function itemRow(location, bag, slot, itemId, count, quality, link, name)
    if not link then
        return nil
    end
    itemId = itemId or tonumber(link:match("item:(%d+)"))
    return {
        location = location,
        bag = bag,
        slot = slot,
        itemId = itemId,
        name = name or link:match("|h%[(.-)%]|h") or "",
        count = count or 1,
        quality = quality or Json.null,
        link = link,
        itemLevel = itemLevel(link),
    }
end

local function numSlots(probe, bag)
    if probe.container == "C_Container" then
        return C_Container.GetContainerNumSlots(bag) or 0
    elseif probe.container == "GetContainerItemInfo" then
        return GetContainerNumSlots(bag) or 0
    end
    return 0
end

local function containerItem(probe, location, bag, slot)
    if probe.container == "C_Container" then
        local info = C_Container.GetContainerItemInfo(bag, slot)
        if info then
            return itemRow(location, bag, slot, info.itemID, info.stackCount, info.quality, info.hyperlink, info.itemName)
        end
    elseif probe.container == "GetContainerItemInfo" then
        local _, count, _, quality, _, _, link, _, _, itemId = GetContainerItemInfo(bag, slot)
        link = link or (GetContainerItemLink and GetContainerItemLink(bag, slot))
        return itemRow(location, bag, slot, itemId, count, quality, link)
    end
end

-- Backpack, equipped bags, and equipped gear (paper doll slots 1-23, which
-- include the equipped bag items themselves).
function Snapshot.Inventory(probe)
    local items = Json.array()
    local used, free = 0, 0
    local lastBag = NUM_BAG_SLOTS or 4

    for bag = 0, lastBag do
        for slot = 1, numSlots(probe, bag) do
            local row = containerItem(probe, "bag", bag, slot)
            if row then
                items[#items + 1] = row
                used = used + 1
            else
                free = free + 1
            end
        end
    end

    for slot = FIRST_EQUIPPED_SLOT, LAST_EQUIPPED_SLOT do
        local link = GetInventoryItemLink("player", slot)
        if link then
            local itemId = GetInventoryItemID and GetInventoryItemID("player", slot)
            local quality = GetInventoryItemQuality and GetInventoryItemQuality("player", slot)
            local count = GetInventoryItemCount and GetInventoryItemCount("player", slot)
            local row = itemRow("equipped", nil, slot, itemId, count, quality, link)
            if row then
                if not row.count or row.count < 1 then
                    row.count = 1
                end
                items[#items + 1] = row
            end
        end
    end

    return items, { used = used, free = free }
end

-- Only valid while the bank frame is open. Main bank plus classic bank bags.
function Snapshot.Bank(probe, now)
    local items = Json.array()
    local bankContainer = BANK_CONTAINER or -1
    local firstBankBag = (NUM_BAG_SLOTS or 4) + 1
    local lastBankBag = (NUM_BAG_SLOTS or 4) + (NUM_BANKBAGSLOTS or 6)

    local function scan(bag)
        for slot = 1, numSlots(probe, bag) do
            local row = containerItem(probe, "bank", bag, slot)
            if row then
                row.scannedAt = now
                items[#items + 1] = row
            end
        end
    end

    scan(bankContainer)
    for bag = firstBankBag, lastBankBag do
        scan(bag)
    end

    return { scanned = true, scannedAt = now, items = items }
end

function Snapshot.EmptyBank()
    return { scanned = false, scannedAt = Json.null, items = Json.array() }
end

local function skillLineCount(probe)
    if probe.skills == "C_SkillInfo.GetSkillLineInfo" then
        return C_SkillInfo.GetNumSkillLines() or 0
    end
    return GetNumSkillLines() or 0
end

-- Normalize Era multi-returns and Forever table returns into one shape.
local function skillLineInfo(probe, index)
    if probe.skills == "C_SkillInfo.GetSkillLineInfo" then
        local a, b, _, d, _, _, g = C_SkillInfo.GetSkillLineInfo(index)
        if type(a) == "table" then
            local name = a.skillName or a.name
            local isHeader = a.isHeader or a.header
            return name, isHeader and true or false, a.skillRank or a.rank or 0, a.skillMaxRank or a.maxRank or 0
        end
        return a, b and true or false, d or 0, g or 0
    end
    local name, isHeader, _, rank, _, _, maxRank = GetSkillLineInfo(index)
    return name, isHeader and true or false, rank or 0, maxRank or 0
end

-- Reads only what the skills panel currently shows; collapsed headers stay
-- collapsed so the addon never changes the player's UI. The Forever client
-- lists professions and secondary skills twice (its skills frame has its own
-- profession section above the main list), so each category/name pair is
-- kept once.
function Snapshot.Skills(probe)
    if probe.skills == UNSUPPORTED then
        return nil
    end
    local skills = Json.array()
    local seen = {}
    local category = ""
    for i = 1, skillLineCount(probe) do
        local name, isHeader, rank, maxRank = skillLineInfo(probe, i)
        if name then
            if isHeader then
                category = name
            else
                local key = category .. "\n" .. name
                if not seen[key] then
                    seen[key] = true
                    skills[#skills + 1] = {
                        category = category,
                        name = name,
                        rank = rank or 0,
                        maxRank = maxRank or 0,
                    }
                end
            end
        end
    end
    return skills
end

-- One row per statistic the Statistics window would show. A nil GetStatistic
-- is a header inside the category (Wealth, and so on), not a value.
function Snapshot.Statistics(probe)
    if probe.statistics == UNSUPPORTED then
        return nil
    end
    local stats = Json.array()
    local categories = GetStatisticsCategoryList()
    if type(categories) ~= "table" then
        return stats
    end

    local titles = {}
    for _, categoryId in ipairs(categories) do
        local title = GetCategoryInfo(categoryId)
        if type(title) == "string" and title ~= "" then
            titles[categoryId] = title
        end
    end

    for _, categoryId in ipairs(categories) do
        local title, parent = GetCategoryInfo(categoryId)
        if type(title) == "string" and title ~= "" then
            local category = title
            if type(parent) == "number" and parent > 0 and titles[parent] then
                category = titles[parent] .. " / " .. title
            end
            local group = ""
            local count = GetCategoryNumAchievements(categoryId) or 0
            for index = 1, count do
                local statId, name = GetAchievementInfo(categoryId, index)
                if statId and type(name) == "string" and name ~= "" then
                    local value, skip = GetStatistic(statId)
                    if not skip then
                        if value == nil then
                            group = name
                        else
                            stats[#stats + 1] = {
                                category = category,
                                group = group,
                                id = statId,
                                name = name,
                                value = tostring(value),
                            }
                        end
                    end
                end
            end
        end
    end
    return stats
end

local function playerClassId()
    local _, _, classId = UnitClass("player")
    return classId
end

local function activeTalentGroup()
    if C_SpecializationInfo and C_SpecializationInfo.GetActiveSpecGroup then
        return C_SpecializationInfo.GetActiveSpecGroup() or 1
    end
    if GetActiveTalentGroup then
        return GetActiveTalentGroup() or 1
    end
    if GetActiveSpecGroup then
        return GetActiveSpecGroup() or 1
    end
    return 1
end

local function parseTabReturns(a, b, c, d, e)
    -- id, name, ..., pointsSpent
    if type(a) == "number" and type(b) == "string" and b ~= "" then
        return b, e or d or c
    end
    -- name, icon, pointsSpent, background
    if type(a) == "string" and a ~= "" then
        return a, c
    end
    return nil, nil
end

local function tabInfo(tab, group)
    local classId = playerClassId()

    if GetTalentTabInfo then
        local ok, a, b, c, d, e = pcall(GetTalentTabInfo, tab)
        if ok then
            local name, points = parseTabReturns(a, b, c, d, e)
            if name then
                return name, points
            end
        end
        ok, a, b, c, d, e = pcall(GetTalentTabInfo, tab, false, false, group)
        if ok then
            local name, points = parseTabReturns(a, b, c, d, e)
            if name then
                return name, points
            end
        end
    end

    -- Class-scoped specs (Assassination/Combat/…), not GetSpecialization() which is often the class.
    if classId and GetSpecializationInfoForClassID then
        local ok, specId, name = pcall(GetSpecializationInfoForClassID, classId, tab)
        if ok and type(name) == "string" and name ~= "" then
            return name, nil
        end
        if ok and type(specId) == "string" and specId ~= "" then
            return specId, nil
        end
    end
    if classId and C_SpecializationInfo and C_SpecializationInfo.GetSpecializationInfo then
        local ok, _, name, _, _, _, _, pointsSpent =
            pcall(C_SpecializationInfo.GetSpecializationInfo, tab, false, false, nil, nil, group, classId)
        if ok and type(name) == "string" and name ~= "" then
            return name, pointsSpent
        end
    end

    return nil, nil
end

local function numTalentTabs()
    if GetNumTalentTabs then
        local n = GetNumTalentTabs()
        if type(n) == "number" and n >= 2 then
            return n
        end
    end
    local classId = playerClassId()
    if classId and GetNumSpecializationsForClassID then
        local n = GetNumSpecializationsForClassID(classId)
        if type(n) == "number" and n >= 2 then
            return n
        end
    end
    if classId and C_SpecializationInfo and C_SpecializationInfo.GetNumSpecializationsForClassID then
        local n = C_SpecializationInfo.GetNumSpecializationsForClassID(classId)
        if type(n) == "number" and n >= 2 then
            return n
        end
    end
    return 3
end

local function classicTalentInfo(tab, index)
    local name, _, tier, column, rank, maxRank = GetTalentInfo(tab, index)
    return name, tier, column, rank, maxRank
end

local function unpackTalentResult(result, tier, column)
    if type(result) ~= "table" or type(result.name) ~= "string" or result.name == "" then
        return nil
    end
    local rank = result.rank
    if rank == nil and result.selected then
        rank = 1
    end
    return result.name, result.tier or tier, result.column or column, rank or 0, result.maxRank or 0
end

local function foreverTalentInfo(tab, tier, column, group)
    if not (C_SpecializationInfo and C_SpecializationInfo.GetTalentInfo) then
        return nil
    end
    local queries = {
        { specializationIndex = tab, tier = tier, column = column, groupIndex = group, isInspect = false },
        { specializationIndex = tab, tier = tier, column = column, isInspect = false },
    }
    for _, query in ipairs(queries) do
        local ok, result = pcall(C_SpecializationInfo.GetTalentInfo, query)
        if ok then
            local name, t, c, rank, maxRank = unpackTalentResult(result, tier, column)
            if name then
                return name, t, c, rank, maxRank
            end
        end
    end
    return nil
end

local function spellName(spellID)
    if not spellID then
        return nil
    end
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(spellID)
        if type(info) == "table" and type(info.name) == "string" and info.name ~= "" then
            return info.name
        end
    end
    if GetSpellInfo then
        local name = GetSpellInfo(spellID)
        if type(name) == "string" and name ~= "" then
            return name
        end
    end
    return nil
end

local function traitTalentName(configID, nodeInfo)
    local entryID = nodeInfo.activeEntry and nodeInfo.activeEntry.entryID
    if not entryID and type(nodeInfo.entryIDs) == "table" then
        entryID = nodeInfo.entryIDs[1]
    end
    if not entryID then
        return nil
    end
    local entryInfo = C_Traits.GetEntryInfo(configID, entryID)
    if not entryInfo or not entryInfo.definitionID then
        return nil
    end
    local defInfo = C_Traits.GetDefinitionInfo(entryInfo.definitionID)
    if not defInfo then
        return nil
    end
    if type(defInfo.overrideName) == "string" and defInfo.overrideName ~= "" then
        return defInfo.overrideName
    end
    return spellName(defInfo.spellID or defInfo.overriddenSpellID)
end

local function sortByOrderIndex(a, b)
    return (a.orderIndex or 0) < (b.orderIndex or 0)
end

-- Forever: one class trait tree, three display groups (Assassination / Combat / …).
local function readTraitsTalents()
    local configID = C_ClassTalents.GetActiveConfigID()
    if not configID then
        return {
            source = "C_Traits",
            unspentSource = UNSUPPORTED,
            unspent = Json.null,
            trees = Json.array(),
            talents = Json.array(),
        }
    end

    local configInfo = C_Traits.GetConfigInfo(configID)
    local treeIDs = configInfo and configInfo.treeIDs or nil
    if type(treeIDs) ~= "table" or #treeIDs == 0 then
        return {
            source = "C_Traits",
            unspentSource = UNSUPPORTED,
            unspent = Json.null,
            trees = Json.array(),
            talents = Json.array(),
        }
    end

    local trees = Json.array()
    local talents = Json.array()
    local groupIndexById = {}
    local allGroupIDs = {}
    local pointsSpent = 0
    local unspent = Json.null

    for _, treeID in ipairs(treeIDs) do
        local groups = nil
        if C_Traits.GetGroupDisplayInfoByTreeID then
            groups = C_Traits.GetGroupDisplayInfoByTreeID(treeID)
        end
        if type(groups) == "table" and #groups > 0 then
            table.sort(groups, sortByOrderIndex)
            for _, g in ipairs(groups) do
                local idx = #trees + 1
                groupIndexById[g.groupID] = idx
                allGroupIDs[#allGroupIDs + 1] = g.groupID
                trees[idx] = {
                    index = idx,
                    name = g.displayName or Json.null,
                    pointsSpent = 0,
                }
            end
        else
            -- One tree with no group metadata: treat the whole tree as a single tab.
            local idx = #trees + 1
            trees[idx] = { index = idx, name = Json.null, pointsSpent = 0 }
        end

        if C_Traits.GetTreeCurrencyInfo then
            local currency = C_Traits.GetTreeCurrencyInfo(configID, treeID, true)
            if type(currency) == "table" and currency[1] then
                if type(currency[1].quantity) == "number" then
                    unspent = currency[1].quantity
                end
            end
        end

        local nodes = C_Traits.GetTreeNodes(treeID) or {}
        for _, nodeID in ipairs(nodes) do
            local nodeInfo = C_Traits.GetNodeInfo(configID, nodeID)
            if nodeInfo and nodeInfo.ID and nodeInfo.ID > 0 and nodeInfo.isVisible ~= false then
                local name = traitTalentName(configID, nodeInfo)
                if name then
                    local tab = 1
                    if type(nodeInfo.groupIDs) == "table" and nodeInfo.groupIDs[1] then
                        tab = groupIndexById[nodeInfo.groupIDs[1]] or 1
                    elseif #trees > 0 then
                        tab = #trees
                    end
                    local treeName = trees[tab] and trees[tab].name or Json.null
                    local rank = nodeInfo.currentRank or 0
                    local maxRank = nodeInfo.maxRanks or 0
                    talents[#talents + 1] = {
                        tab = tab,
                        tree = treeName,
                        name = name,
                        tier = Json.null,
                        column = Json.null,
                        rank = rank,
                        maxRank = maxRank,
                    }
                    if trees[tab] then
                        trees[tab].pointsSpent = (trees[tab].pointsSpent or 0) + rank
                    end
                end
            end
        end
    end

    -- Prefer committed group currency when Forever exposes it (matches the talent UI headers).
    if C_Traits.GetGroupCurrencyInfo and #allGroupIDs > 0 then
        local groupCurrency = C_Traits.GetGroupCurrencyInfo(configID, allGroupIDs)
        if type(groupCurrency) == "table" then
            for _, info in ipairs(groupCurrency) do
                local idx = groupIndexById[info.traitNodeGroupID]
                local spent = info.currencyInfos and info.currencyInfos[1] and info.currencyInfos[1].spent
                if idx and type(spent) == "number" then
                    trees[idx].pointsSpent = spent
                end
            end
        end
    end

    for _, tree in ipairs(trees) do
        pointsSpent = pointsSpent + (tree.pointsSpent or 0)
    end

    local unspentSource = "C_Traits.GetTreeCurrencyInfo"
    if unspent == Json.null then
        unspentSource = "derived"
        local level = UnitLevel("player") or 0
        unspent = math.max(0, math.max(0, level - 9) - pointsSpent)
    end

    return {
        source = "C_Traits",
        unspentSource = unspentSource,
        unspent = unspent,
        trees = trees,
        talents = talents,
    }
end

local function readTalentTree(probe, tab, trees, talents, group)
    local treeName, metaPoints = tabInfo(tab, group)
    local summed = 0

    if probe.talents == "GetTalentInfo" and GetNumTalents then
        for index = 1, GetNumTalents(tab) do
            local name, tier, column, rank, maxRank = classicTalentInfo(tab, index)
            if name then
                rank = rank or 0
                summed = summed + rank
                talents[#talents + 1] = {
                    tab = tab,
                    tree = treeName or Json.null,
                    name = name,
                    tier = tier,
                    column = column,
                    rank = rank,
                    maxRank = maxRank or 0,
                }
            end
        end
    else
        local maxTier = MAX_TALENT_TIERS or 7
        local maxCols = NUM_TALENT_COLUMNS or 4
        for tier = 1, maxTier do
            for column = 1, maxCols do
                local name, t, c, rank, maxRank = foreverTalentInfo(tab, tier, column, group)
                if name then
                    rank = rank or 0
                    summed = summed + rank
                    talents[#talents + 1] = {
                        tab = tab,
                        tree = treeName or Json.null,
                        name = name,
                        tier = t,
                        column = c,
                        rank = rank,
                        maxRank = maxRank or 0,
                    }
                end
            end
        end
    end

    local spent = tonumber(metaPoints)
    if spent == nil then
        spent = summed
    end

    trees[#trees + 1] = {
        index = tab,
        name = treeName or Json.null,
        pointsSpent = spent,
    }
    return spent
end

function Snapshot.Talents(probe)
    if probe.talents == UNSUPPORTED then
        return { source = UNSUPPORTED }
    end

    if probe.talents == "C_Traits" then
        return readTraitsTalents()
    end

    local trees = Json.array()
    local talents = Json.array()
    local pointsSpent = 0
    local group = activeTalentGroup()
    local tabs = numTalentTabs()
    for tab = 1, tabs do
        pointsSpent = pointsSpent + readTalentTree(probe, tab, trees, talents, group)
    end

    local unspent = Json.null
    local unspentSource = probe.unspent or UNSUPPORTED
    if unspentSource == "GetUnspentTalentPoints" then
        unspent = GetUnspentTalentPoints() or Json.null
    elseif unspentSource == "UnitCharacterPoints" then
        unspent = UnitCharacterPoints("player") or Json.null
    elseif unspentSource == "derived" then
        local level = UnitLevel("player") or 0
        local earned = math.max(0, level - 9)
        unspent = math.max(0, earned - pointsSpent)
    end

    return {
        source = probe.talents,
        unspentSource = unspentSource,
        unspent = unspent,
        trees = trees,
        talents = talents,
    }
end

local function joinObjectives(lines)
    if #lines == 0 then
        return ""
    end
    return table.concat(lines, "\n")
end

-- Quests visible in the log. Collapsed headers are left alone.
function Snapshot.QuestsInProgress(probe)
    local quests = Json.array()

    if probe.questLog == "C_QuestLog.GetInfo" then
        for i = 1, C_QuestLog.GetNumQuestLogEntries() do
            local info = C_QuestLog.GetInfo(i)
            if info and not info.isHeader and not info.isHidden and info.questID and info.questID > 0 then
                local lines = {}
                local objectives = C_QuestLog.GetQuestObjectives and C_QuestLog.GetQuestObjectives(info.questID)
                for _, objective in ipairs(objectives or {}) do
                    if objective.text and objective.text ~= "" then
                        lines[#lines + 1] = objective.text
                    end
                end
                quests[#quests + 1] = {
                    id = info.questID,
                    title = info.title or "",
                    objectives = joinObjectives(lines),
                }
            end
        end
    elseif probe.questLog == "GetQuestLogTitle" then
        for i = 1, (GetNumQuestLogEntries()) do
            local title, _, _, isHeader, _, _, _, questId = GetQuestLogTitle(i)
            if title and not isHeader then
                local lines = {}
                if GetNumQuestLeaderBoards and GetQuestLogLeaderBoard then
                    for j = 1, GetNumQuestLeaderBoards(i) or 0 do
                        local text = GetQuestLogLeaderBoard(j, i)
                        if text and text ~= "" then
                            lines[#lines + 1] = text
                        end
                    end
                end
                quests[#quests + 1] = {
                    id = questId or Json.null,
                    title = title,
                    objectives = joinObjectives(lines),
                }
            end
        end
    end

    return quests
end

-- Titles only when the client already has them cached; no load requests.
function Snapshot.QuestsCompleted(probe)
    if probe.completed == UNSUPPORTED then
        return nil
    end

    local ids = {}
    if probe.completed == "C_QuestLog.GetAllCompletedQuestIDs" then
        for _, id in ipairs(C_QuestLog.GetAllCompletedQuestIDs() or {}) do
            ids[#ids + 1] = id
        end
    else
        for id, done in pairs(GetQuestsCompleted() or {}) do
            if done then
                ids[#ids + 1] = id
            end
        end
    end
    table.sort(ids)

    local getTitle = C_QuestLog and C_QuestLog.GetTitleForQuestID
    local completed = Json.array()
    for _, id in ipairs(ids) do
        local row = { id = id }
        if getTitle then
            local title = getTitle(id)
            if title and title ~= "" then
                row.title = title
            end
        end
        completed[#completed + 1] = row
    end
    return completed
end

Snapshot.UNSUPPORTED = UNSUPPORTED
