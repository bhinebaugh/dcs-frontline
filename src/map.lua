local rgb = require("constants").rgb
local settings = require("settings")
local Map = {}
Map.__index = Map

function Map.new(blueCenter, redCenter)
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
    self.center = {
        blue = blueCenter,
        red = redCenter
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

    trigger.action.circleToAll(-1, 9998, mist.utils.makeVec3GL(self.center["red"]), 420, {1,0,0,1}, {1,0,0,0.2}, 1)
    trigger.action.circleToAll(-1, 9999, mist.utils.makeVec3GL(self.center["blue"]), 420, {0,0,1,1}, {0,0,1,0.2}, 1)
end

function Map:drawEdges(edges)
    if not settings.draw.edges then return end
    for _, edge in pairs(edges) do
        local lineId = self:getNewMarker()
        table.insert(self.markers.edges, lineId)
        trigger.action.lineToAll(-1, lineId, edge.p1, edge.p2, {1,1,0.2,0.1}, 5)
    end
end

function Map:drawFrontline(edges, color)
    local opponentColor = color == "blue" and "red" or "blue"
    local heading = mist.utils.getHeadingPoints(self.center[color], self.center[opponentColor])

    --first erase any existing lines
    if self.markers.front[color] then
        for _, id in pairs(self.markers.front[color]) do
            trigger.action.removeMark(id)
        end
        self.markers.front[color] = {}
    end
    --then draw a line for each edge of the current color's front
    local sides = self:getVisibility(color, "frontlines")
    for _, side in pairs(sides) do
        for _, zonePoints in pairs(edges) do
            local lineId1 = self:getNewMarker()
            local lineId2 = self:getNewMarker()
            table.insert(self.markers.front[color], lineId1)
            table.insert(self.markers.front[color], lineId2)
            local lineColor = rgb[color]
            --need zone points
            local z1, z2 = zonePoints.p1, zonePoints.p2
            local p1A, p1B = mist.projectPoint(z1, 2000, heading), mist.projectPoint(z1, 2200, heading)
            local p2A, p2B = mist.projectPoint(z2, 2000, heading), mist.projectPoint(z2, 2200, heading)
            trigger.action.lineToAll(side, lineId1, p1A, p2A, lineColor, 1)
            trigger.action.lineToAll(side, lineId2, p1B, p2B, lineColor, 1) --double the line for better visibility
        end
    end
end

function Map:drawDirective(originPoint, targetPoint, color)
    if not settings.draw.directives then return end
    local sides = self:getVisibility(color, "directives")
    for _, side in pairs(sides) do
        local nextId = self:getNewMarker()
        local lineColor = {1,1,0.2,1}
        local fillColor = lineColor
        local heading = mist.utils.getHeadingPoints(originPoint, targetPoint)
        local reciprocal = mist.utils.getHeadingPoints(targetPoint, originPoint)
        local distance = 1000
        local lineStart = mist.projectPoint(originPoint, distance+200, heading)
        local arrowEnd = mist.projectPoint(targetPoint, distance, reciprocal)
        trigger.action.arrowToAll(side, nextId, arrowEnd, lineStart, lineColor, fillColor, 1)
    end
    return true
end

return Map