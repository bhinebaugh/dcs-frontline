local rgb = require("constants").rgb
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

function Map:drawZone(name, color, pt)
    local zoneId = self:getNewMarker()
    self.markers.zones[name] = zoneId
    trigger.action.circleToAll(-1, zoneId, pt, 510, {0,0,0,0.2}, rgb[color], 1)
    local labelId = self:getNewMarker()
    self.markers.zoneLabels[name] = labelId
    trigger.action.textToAll(-1, labelId, pt, {1,1,0,0.5}, {0,0,0,0}, 13, true, name)
end

function Map:redrawZone(name, color)
    trigger.action.setMarkupColorFill(self.markers.zones[name], rgb[color])
end

function Map:drawZones(zones)
    for name, info in pairs(zones) do
        self:drawZone(name, info.color, info.point)
    end

    trigger.action.circleToAll(-1, 9998, mist.utils.makeVec3GL(self.center["red"]), 420, {1,0,0,1}, {1,0,0,0.2}, 1)
    trigger.action.circleToAll(-1, 9999, mist.utils.makeVec3GL(self.center["blue"]), 420, {0,0,1,1}, {0,0,1,0.2}, 1)
end

function Map:drawEdges(edges)
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
    for _, zonePoints in pairs(edges) do
        local lineId = self:getNewMarker()
        table.insert(self.markers.front[color], lineId)
        local lineColor = rgb[color]
        --need zone points
        local z1, z2 = zonePoints.p1, zonePoints.p2
        local p1A, p1B = mist.projectPoint(z1, 2000, heading), mist.projectPoint(z1, 2200, heading)
        local p2A, p2B = mist.projectPoint(z2, 2000, heading), mist.projectPoint(z2, 2200, heading)
        trigger.action.lineToAll(-1, lineId, p1A, p2A, lineColor, 1)
        lineId = self:getNewMarker()
        table.insert(self.markers.front[color], lineId)
        trigger.action.lineToAll(-1, lineId, p1B, p2B, lineColor, 1) --double the line for better visibility
    end
end

function Map:drawDirective(originPoint, targetPoint)
    local side = -1 --which coalition the arrow is visible to
    local nextId = self:getNewMarker()
    local color = {1,1,0.2,1}
    local fill = color
    local heading = mist.utils.getHeadingPoints(originPoint, targetPoint)
    local reciprocal = mist.utils.getHeadingPoints(targetPoint, originPoint)
    local distance = 1000
    local lineStart = mist.projectPoint(originPoint, distance, heading)
    local arrowEnd = mist.projectPoint(targetPoint, distance, reciprocal)
    trigger.action.arrowToAll(side, nextId, arrowEnd, lineStart, color, fill, 1)
    return true
end

return Map