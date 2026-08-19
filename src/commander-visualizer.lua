local constants = require("constants")
local settings = require("settings")
local rgb = constants.rgb
local normalizeAngle = require("helpers").normalizeAngle --Load helper functions
local angularDistance = require("helpers").angularDistance --Load helper functions

local taskTypeNames = {}
for name, value in pairs(constants.taskTypes) do
    taskTypeNames[value] = name
end

-- Reconciles commander state (orders, dispositions, objectives, opscom tasking)
-- onto persistent map marks. Owns a registry of {signature, markIds} keyed by a
-- stable string per drawable thing, so unchanged state is a no-op and changed
-- state erases the old marks before drawing new ones.
local CommanderVisualizer = {}
CommanderVisualizer.__index = CommanderVisualizer

function CommanderVisualizer.new(map)
    local self = setmetatable({}, CommanderVisualizer)
    self.map = map
    self.registry = {}
    return self
end

-- Draw/update the marks for `key` only if `signature` differs from what's
-- currently registered. `drawFn` is called (with no args) only when a redraw
-- is needed, and must return a list of mark ids.
function CommanderVisualizer:upsert(key, signature, drawFn)
    local entry = self.registry[key]
    if entry and entry.signature == signature then
        return
    end
    if entry then
        self.map:removeMarks(entry.markIds)
    end
    local markIds = drawFn() or {}
    self.registry[key] = { signature = signature, markIds = markIds }
end

-- Erase any marks registered for `key`, if present.
function CommanderVisualizer:release(key)
    local entry = self.registry[key]
    if not entry then return end
    self.map:removeMarks(entry.markIds)
    self.registry[key] = nil
end

-- Draw/update a label at a group's position showing its current order type
-- and disposition, or threat assessment if the group has no active order.
function CommanderVisualizer:syncGroupOrder(gc, color)
    local key = "group:" .. gc.groupName

    local position = gc:getOwnPosition()
    if not position then
        self:release(key)
        return
    end

    local text
    local textColor
    local bgColor
    local signature
    local roundedPos = math.floor(position.x / 50) .. "," .. math.floor(position.z / 50)

    local threatCount = gc.threatAssessment.count
    local groupDoctrineName = (gc.doctrine and gc.doctrine.name .. ":" .. gc.doctrine.currentPhaseName) or "?"
    local condition = gc:getConditionSummary()
    if gc.orders then
        textColor = {1,1,1,0.8}
        bgColor   = {0,0,0,0.3}
        local orderTypeName = taskTypeNames[gc.orders.type] or tostring(gc.orders.type)
        signature = table.concat({orderTypeName, gc.disposition, gc.orders.status, threatCount, roundedPos, condition.level}, "|")
    else
        textColor = {0.8,0.8,0.8,0.35}
        bgColor   = {0.4,0.4,0.4,0.15}
        signature = table.concat({"default", gc.disposition, threatCount, roundedPos, condition.level}, "|")
    end

    -- Dire condition overrides the normal background so it's visually
    -- distinct from the coalition-colored default at a glance, independent
    -- of whatever order/disposition text says - this is the map-level
    -- confirmation that isConditionCritical's criteria are actually firing.
    if condition.level == "CRITICAL" then
        bgColor = {0.6, 0.05, 0.05, 0.55}
    elseif condition.level == "DEGRADED" then
        bgColor = {0.6, 0.4, 0.0, 0.4}
    end

    local doctrineText = groupDoctrineName .. " [" .. (gc.disposition or "__") .. "]"
    local threatText = threatCount and (threatCount .. "x threats for " .. math.floor(gc.threatAssessment.favorability * 10) / 10) or "no threat"
    local conditionText = string.format("%s HP:%s%% Fuel:%s%% Ammo:%s%%",
        condition.level, condition.healthPercent or "?", condition.fuelPercent or "?", condition.ammoPercent or "?")
    text = gc.groupName .. "\n" .. doctrineText .. "\n" .. threatText .. "\n" .. conditionText


    self:upsert(key, signature, function()
        return self.map:drawGroupOrder(text, color, position, textColor, bgColor)
    end)
end

-- Draw and persist arrows showing each time a group changes its intended destination 
function CommanderVisualizer:appendGroupMove(gc, color)
    local key = color .. "_movement"
    local entry = self.registry[key]
    local position = gc:getOwnPosition()
    if not position then
        -- not releasing key can helpfully show trace trail for groups
        -- that blunder unnoticed into bad situations and get obliterated
        -- self:release(key)
        return
    end

    local arrowColor = {0.3,0.3,0.3,0.04}
    if color == "red" then
        arrowColor[1] = 0.8
    end
    if color == "blue" then
        arrowColor[3] = 0.8
    end
    local arrowIds = self.map:drawMovementTrail(position, gc.destination, color, arrowColor)
    if arrowIds then
        if not entry then
            self:upsert(key, "_", function()
                return arrowIds
            end)
        else
            for _, mk in pairs(arrowIds) do
                table.insert(self.registry[key].markIds, mk)
            end
        end
    end
end

-- Used to erase and reset movement trail upon new orders for group
function CommanderVisualizer:syncGroupMove(gc, color)
    local key = color .. "_movement"
    self:release(key)
end

-- Key for an objective's map mark, shared with releaseObjective below so
-- whoever tears down the opscom owning this objective can clean up its
-- mark directly - syncObjective's own isComplete() check only fires if
-- syncObjective gets called again, which requires the opscom's act() to
-- still be running, but the opscom is usually disbanded (its OODA schedule
-- cancelled) in the very same moment its objective resolves.
function CommanderVisualizer:objectiveKey(objective)
    return "objective:" .. tostring(objective)
end

function CommanderVisualizer:releaseObjective(objective)
    self:release(self:objectiveKey(objective))
end

-- Draw/update a circle + label at an objective's position showing its task
-- type and status.
function CommanderVisualizer:syncObjective(objective, doctrine, color)
    local key = self:objectiveKey(objective)

    if objective:isComplete() then
        self:releaseObjective(objective)
        return
    end

    local typeName = taskTypeNames[objective.type] or tostring(objective.type)
    local orderCounts = {}
    for k, v in pairs(objective:getOrderStatusCounts()) do
        orderCounts[k] = tostring(v)
    end
    local objectiveOrders = "Assg:" .. orderCounts.assigned .. " Act:" .. orderCounts.inProgress .. " Dn:" .. orderCounts.completed .. " X:" .. orderCounts.aborted
    local text = doctrine.name .. ":" ..  doctrine.currentPhaseName .. "\n" .. typeName .. " (" .. objective.status .. ") [" .. objectiveOrders .. "]"
    local signature = table.concat({typeName, objective.status, objective.radius, doctrine.name, doctrine.currentPhaseName, objectiveOrders}, "|")

    self:upsert(key, signature, function()
        return self.map:drawObjective(objective, text, color)
    end)
end

-- Draw/update the outline of tasked groups and directive arrows from each
-- group to the opscom's objective.
function CommanderVisualizer:syncOpscom(opscom, color)
    local key = "opscom:" .. opscom.name

    local objective = opscom.orderCoordinator.objectives[1]
    if not objective then
        self:release(key)
        return
    end

    local groupNames = {}
    local points = {}
    local polygon = {}
    -- Calculate centroid of allied positions
    local alliedCenterX = 0
    local alliedCenterZ = 0
    local center = { x = 0, y = 0, z = 0 }
    local validCount = 0
    for _, gc in ipairs(opscom.groupCommanders) do
        local position = gc:getOwnPosition()
        if position then
            table.insert(groupNames, gc.groupName)
            table.insert(points, position)
            alliedCenterX = alliedCenterX + position.x
            alliedCenterZ = alliedCenterZ + position.z
            validCount = validCount + 1
        end
    end
    table.sort(groupNames)

    center.x = alliedCenterX / validCount
    center.z = alliedCenterZ / validCount
    -- project points from center to form enclosing polygon
    -- for each point project 2 points away from center +/- 45deg
    for i, data in pairs(points) do
        -- get heading center to data
        local heading = mist.utils.getHeadingPoints(center, data)
        local projectedPoint1 = mist.projectPoint(data, 800, heading + math.pi/4)
        local projectedPoint2 = mist.projectPoint(data, 800, heading - math.pi/4)
        table.insert(polygon, projectedPoint1)
        table.insert(polygon, projectedPoint2)
    end
    -- table.insert(polygon, lastPoint)
    -- sort points
    local initialHeading = 0
    table.sort(polygon, function(a, b)
        local headingA = normalizeAngle(mist.utils.getHeadingPoints(center, a))
        local headingB = normalizeAngle(mist.utils.getHeadingPoints(center, b))
        local arcA = angularDistance(initialHeading, headingA)
        local arcB = angularDistance(initialHeading, headingB)
        return arcA < arcB
    end)

    local signature = table.concat(groupNames, ",") .. "|" .. objective.status

    self:upsert(key, signature, function()
        if #polygon == 0 then return {} end
        local markIds = {}
        -- for _, gc in ipairs(opscom.groupCommanders) do
        -- single arrow for whole operation
            local origin = center --gc:getOwnPosition()
            if origin then
                local arrowIds = self.map:drawDirective(origin, objective.position, color)
                if arrowIds then
                    for _, mk in pairs(arrowIds) do
                        table.insert(markIds, mk)
                    end
                end
            end
        -- end
        local polygonId = self.map:drawPolygon(polygon)
        if polygonId then
            table.insert(markIds, polygonId)
        end
        return markIds
    end)
end

return CommanderVisualizer
