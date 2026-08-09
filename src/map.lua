local rgb = require("constants").rgb
local settings = require("settings")
local Map = {}
Map.__index = Map

function Map.new()
    local self = setmetatable({}, Map)
    self.markerCounter = 5000
    self.markers = {
        front = {
            red = {},
            blue = {}
        },
        zones = {},
        zoneLabels = {},
        edges = {},
    }
    return self
end

function Map:getNewMarker()
    self.markerCounter = self.markerCounter + 1
    return self.markerCounter
end

function Map:getVisibility(color, feature)
    -- Return value will include '0' or '-1' to ensure that map marks are always
    -- drawn for neutrals (game commander and spectators), regardless of settings
    if settings.displayToAll[feature] then
        return {-1}
    else
        return {0, color == "red" and 1 or 2}
    end
end

function Map:removeMarks(markIds)
    if not markIds then return end
    for _, id in pairs(markIds) do
        trigger.action.removeMark(id)
    end
end

function Map:placeMarker(text, color, pt)
    if not settings.draw.zones then return end
    local sides = self:getVisibility(color, "zones")
    local labels = {}
    for _, side in pairs(sides) do
        -- local markerId = self:getNewMarker()
        -- trigger.action.circleToAll(side, zoneId, pt, 510, {0,0,0,0.2}, rgb[color], 1)
        local labelId = self:getNewMarker()
        table.insert(labels, labelId)
        trigger.action.textToAll(side, labelId, pt, {0.7,0,0.7,1}, {0,0,0,0.2}, 15, true, text)
    end
    return labels
end

function Map:drawGroupOrder(text, coalition, point, textColor, bgColor)
    if not settings.draw.groupOrders then return {} end
    local Ids = {}
    local sides = self:getVisibility(coalition, "groupOrders")
    for _, side in pairs(sides) do
        local labelId = self:getNewMarker()
        table.insert(Ids, labelId)
        trigger.action.textToAll(side, labelId, mist.projectPoint(point, 350, math.pi+0.5), textColor, bgColor, 12, true, text)
    end
    return Ids
end

function Map:drawPolygon(points)
    local mk = mist.marker.add({
        pos = points,
        -- name = "",
        markType = "freeform", --7
        markForCoa = -1, --?
        color = {1,1,0,0.3},
        fillColor = {1,1,0,0.1},
        lineType = 1 --1 Solid, 2 Dashed, 3 Dotted, 4 Dot Dash, 5 Long Dash
    })
    return mk.markId --mist helper returns whole table; we want ID only
end

function Map:drawZone(name, color, pt)
    if not settings.draw.zones then return end
    if not self.markers.zones[name] then self.markers.zones[name] = {} end
    local sides = self:getVisibility(color, "zones")
    for _, side in pairs(sides) do
        local zoneId = self:getNewMarker()
        table.insert(self.markers.zones[name], zoneId)
        trigger.action.circleToAll(side, zoneId, pt, 510, {0,0,0,0.2}, rgb[color], 1)
        local labelId = self:getNewMarker()
        trigger.action.textToAll(side, labelId, pt, {1,1,0,0.5}, {0,0,0,0}, 13, true, name)
    end
end

function Map:redrawZone(name, color, point)
    if not settings.draw.zones then return end
    if settings.displayToAll.zones then -- Change fill color of existing marker
        for _, id in pairs(self.markers.zones[name]) do
            trigger.action.setMarkupColorFill(id, rgb[color])
        end
    else -- Erase markers so new ones can be drawn with appropriate visibility
        for _, id in pairs(self.markers.zones[name]) do
            trigger.action.removeMark(id)
        end
        self.markers.zones[name] = {}
        self:drawZone(name, color, point)
    end
end

function Map:drawZones(zones)
    if not settings.draw.zones then return end
    for name, info in pairs(zones) do
        self:drawZone(name, info.color, info.point)
    end
end

function Map:drawEdges(edges)
    if not settings.draw.edges then return end
    for _, edge in pairs(edges) do
        local lineId = self:getNewMarker()
        table.insert(self.markers.edges, lineId)
        trigger.action.lineToAll(-1, lineId, edge.p1, edge.p2, {1,1,0.2,0.1}, 5)
    end
end

function Map:drawFrontline(points, color, erasePrevious, isLoop)
    local OFFSET = 1500
    -- first erase any existing lines
    if erasePrevious and self.markers.front[color] then
        for _, id in pairs(self.markers.front[color]) do
            trigger.action.removeMark(id)
        end
        self.markers.front[color] = {}
    end

    --then draw a line for each edge of the current color's front
    local sides = self:getVisibility(color, "frontlines")
    local prevPts = {}
    for _, side in pairs(sides) do
        local firstPass = true
        local lineColor = rgb[color]
        for _, data in pairs(points) do
            local lineId1 = self:getNewMarker()
            local lineId2 = self:getNewMarker()
            table.insert(self.markers.front[color], lineId1)
            table.insert(self.markers.front[color], lineId2)
            local point1 = mist.projectPoint(data.center, OFFSET, data.heading)
            local point2 = mist.projectPoint(data.center, OFFSET+200, data.heading)
            if firstPass then
                if not isLoop then
                    prevPts[1] = mist.projectPoint(point1, OFFSET, data.heading - math.pi/2)
                    prevPts[2] = mist.projectPoint(point2, OFFSET, data.heading - math.pi/2)
                    trigger.action.lineToAll(side, lineId1, prevPts[1], point1, lineColor, 1)
                    trigger.action.lineToAll(side, lineId2, prevPts[2], point2, lineColor, 1)
                end
            else
                trigger.action.lineToAll(side, lineId1, prevPts[1], point1, lineColor, 1)
                trigger.action.lineToAll(side, lineId2, prevPts[2], point2, lineColor, 1)
            end
            prevPts[1] = point1
            prevPts[2] = point2
            firstPass = false
        end
        if not isLoop then
            local finalPt1 = mist.projectPoint(prevPts[1], OFFSET, points[#points].heading + math.pi/2)
            local finalPt2 = mist.projectPoint(prevPts[2], OFFSET, points[#points].heading + math.pi/2)
            local lineId1 = self:getNewMarker()
            local lineId2 = self:getNewMarker()
            table.insert(self.markers.front[color], lineId1)
            table.insert(self.markers.front[color], lineId2)
            trigger.action.lineToAll(side, lineId1, prevPts[1], finalPt1, lineColor, 1)
            trigger.action.lineToAll(side, lineId2, prevPts[2], finalPt2, lineColor, 1)
        end
    end
end

function Map:drawArrow(originPoint, targetPoint, side, lineColor, fillColor)
    local nextId = self:getNewMarker()
    trigger.action.arrowToAll(side, nextId, targetPoint, originPoint, lineColor, fillColor, 1)
    return nextId
end

function Map:drawMovementTrail(originPoint, targetPoint, coalition, arrowColor)
    if not settings.draw.groupMovement then return end
    local Ids = {}

    local lineColor = arrowColor or {(0.7 + rgb[coalition][1])/2, (0.7 + rgb[coalition][2])/2, (0.7 + rgb[coalition][3])/2, 0.5}
    local fillColor = lineColor

    local sides = self:getVisibility(coalition, "groupMovement")
    for _, side in pairs(sides) do
        local id = self:drawArrow(originPoint, targetPoint, side, lineColor, fillColor)
        table.insert(Ids, id)
    end
    return Ids
end

function Map:drawDirective(originPoint, targetPoint, color)
    if not settings.draw.directives then return end
    local Ids = {}
    local lineColor = {rgb[color][1], rgb[color][2], rgb[color][3], 0.4}
    local fillColor = lineColor
    local distance = 1000
    local heading = mist.utils.getHeadingPoints(originPoint, targetPoint)
    local reciprocal = mist.utils.getHeadingPoints(targetPoint, originPoint)
    local lineStart = mist.projectPoint(originPoint, distance+200, heading)
    local arrowEnd = mist.projectPoint(targetPoint, distance, reciprocal)
    local sides = self:getVisibility(color, "directives")
    for _, side in pairs(sides) do
        local id = self:drawArrow(lineStart, arrowEnd, side, lineColor, fillColor)
        table.insert(Ids, id)
    end
    return Ids
end

function Map:drawObjective(objective, text, color)
    if not settings.draw.objectives then return {} end
    local sides = self:getVisibility(color, "objectives")
    local Ids = {}
    for _, side in pairs(sides) do
        local circleId = self:getNewMarker()
        table.insert(Ids, circleId)
        trigger.action.circleToAll(side, circleId, objective.position, objective.radius+300, rgb[color], {0,0,0,0}, 3)
        local labelId = self:getNewMarker()
        table.insert(Ids, labelId)
        trigger.action.textToAll(side, labelId, mist.projectPoint(objective.position, 850, math.pi/2), {1,1,1,1}, {0,0,0,0.3}, 13, true, text)
    end
    return Ids
end

return Map