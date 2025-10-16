--[[ This is handy for development, so that you don't need to delete and re-add the individual scripts in the ME when you make a change.  These will not be packaged with the .miz, so you shouldn't use this script loader for packaging .miz files for other machines/users.  You'll want to add each script individually with a DO SCRIPT FILE ]]--
--assert(loadfile("C:\\Users\\Kelvin\\Documents\\code\\RotorOps\\scripts\\RotorOps.lua"))()

local ControlZones = {}
ControlZones.__index = ControlZones

function ControlZones.new(namedZones)
    local self = setmetatable({}, ControlZones)
    if not namedZones then
        self.allZones = {}      --array of names of zones
        self.zonesByName = {}   --full zone details indexed by zone name
        self.owner = {}
    else
        --self.zonesByName = namedZones
        --put keys into allZones
    end
    self.maxima = nil
    -- self.maxima = {
    --     westmost = nil,
    --     eastmost = nil,
    --     northmost = nil,
    --     southmost = nil
    -- }
    return self
end

function ControlZones:setup(options)
    options = options or {}
    -- Voronoi distribution from two initial random points
    local redSeed = self.allZones[math.random(#self.allZones)]
    local blueSeed = self.allZones[math.random(#self.allZones)]
    while blueSeed == redSeed do
        blueSeed = self.allZones[math.random(#self.allZones)]
    end

    local initialRedZone = self.zonesByName[redSeed]
    env.info("Red starting zone: "..redSeed)
    local initialBlueZone = self.zonesByName[blueSeed]
    env.info("Blue starting zone: "..blueSeed)

    for name, zone in pairs(self.zonesByName) do
        local redDistance = self:distance(zone, initialRedZone)
        local blueDistance = self:distance(zone, initialBlueZone)
        self.owner[name] = (redDistance < blueDistance) and "red" or "blue"
    end
end

function ControlZones:getCluster(color)
    local cluster = {}
    for name, ownerColor in pairs(self.owner) do
        if ownerColor == color then
            table.insert(cluster, name)
        end
    end
    return cluster
end

function ControlZones:distance(p1, p2)
    local dx = p2.x - p1.x
    local dy = p2.y - p1.y
    return math.sqrt(dx * dx + dy * dy)
end

function ControlZones:getZone(name)
    return self.zonesByName[name]
end

--get zones whose names start with 'control'
--get their coordinates
--grow from opposing start points somehow
--or split the cluster
-- choose a start zone
-- add a connected zone (one of closest zones)
function table.contains(table, el)
    for _, v in pairs(table) do
        if v == el then
            return true
        end
    end
    return false
end
function table.findIndex(table, needle)
    for i, v in pairs(table) do
        if v == needle then
            return i
        end
    end
    return nil
end

function isCounterClockwise(p1, p2, p3)
    -- swapped to account for DCS coordinate weirdness
    return (p2.y - p1.y) * (p3.x - p1.x) - (p2.x - p1.x) * (p3.y - p1.y) > 0
    -- standard (x,y) as (N/S,E/W) version:
    -- return (p2.x - p1.x) * (p3.y - p1.y) - (p2.y - p1.y) * (p3.x - p1.x) > 0
end

function ControlZones:assignCompassMaxima()
    local firstZone = self:getZone(self.allZones[1])
    self.maxima = {
        westmost = { name = firstZone.name, x = firstZone.x, y = firstZone.y},
        eastmost = { name = firstZone.name, x = firstZone.x, y = firstZone.y},
        southmost = { name = firstZone.name, x = firstZone.x, y = firstZone.y},
        northmost = { name = firstZone.name, x = firstZone.x, y = firstZone.y},
    }
    for i = 2, #self.allZones do
        local zone = self:getZone(self.allZones[i])
        if zone.y < self.maxima.westmost.y then
            self.maxima.westmost = { name = zone.name, x = zone.x, y = zone.y}
        elseif zone.y > self.maxima.eastmost.y then
            self.maxima.eastmost = { name = zone.name, x = zone.x, y = zone.y}
        end
        if zone.x < self.maxima.southmost.x then
            self.maxima.southmost = { name = zone.name, x = zone.x, y = zone.y}
        elseif zone.x > self.maxima.northmost.x then
            self.maxima.northmost = { name = zone.name, x = zone.x, y = zone.y}
        end
    end
end

function ControlZones:findPerimeter(zoneList) --zoneList is array of indices = names from zonesByName table
    if #zoneList < 3 then return zoneList end

    local zones = {}
    for _, zonename in pairs(zoneList) do
        zone = self:getZone(zonename)
        table.insert(zones, { name = zonename, x = zone.x, y = zone.y })
    end

    local leftmost = 1
    for i = 2, #zones do
        if zones[i].y < zones[leftmost].y then
            leftmost = i
        end
    end

    local hull = {}
    local current = leftmost

    repeat
        table.insert(hull, zones[current].name) --first point will be westmost
        local next = 1

        for i = 2, #zones do
            if next == current or isCounterClockwise(zones[current], zones[i], zones[next]) then
                next = i
            end
        end

        current = next
    until current == leftmost --we're back at first point

    return hull --return array of zone names
end

function ControlZones:findZonesNearPoint(startPoint, zoneNames, maxDistance)
    env.info("### looking for points "..maxDistance.." from "..startPoint.x..", "..startPoint.y)
    local nearbyzones = {}
    for i, name in pairs(zoneNames) do
        local zone = self:getZone(name)
        local dist = mist.utils.get2DDist(startPoint, { x = zone.x, y = zone.y })
        env.info("distance to "..zone.name.." is "..dist)
        if dist < maxDistance then
            table.insert(nearbyzones, name)
        end
    end
    return nearbyzones
end

local cz = ControlZones.new()
for zonename, zoneobj in pairs(mist.DBs.zonesByName) do
  if string.sub(zonename,1,7) == 'control' then
    -- add an 'owner' property to zones
    -- zoneobj.owner = 0
    cz.zonesByName[zonename] = zoneobj --indexed by name of the trigger zone
    table.insert(cz.allZones, zoneobj.name) --list of all zone names / names of all zones
    trigger.action.circleToAll(-1, 5000+zoneobj.zoneId, zoneobj.point, 500, {0.5,0.5,0.5,0.8}, {0.6,0.6,0.6,0.5}, 1)
  end
end
cz:setup()

local perimIds = cz:findPerimeter(cz.allZones)
cz:assignCompassMaxima()
local width = cz.maxima.eastmost.y - cz.maxima.westmost.y
local height = cz.maxima.northmost.x - cz.maxima.southmost.x
local centerpoint = { y = 200, x = cz.maxima.southmost.x+height/2, z = cz.maxima.westmost.y+width/2 }

local blueZones = cz:getCluster("blue")
--find centroid (averaged point, center of mass) of blue cluster
local sumX = 0
local sumY = 0
for _, id in pairs(blueZones) do
    sumX = sumX + cz.zonesByName[id].x
    sumY = sumY + cz.zonesByName[id].y
end

local rgb = {
    blue = {0,0,1,0.5},
    red = {1,0,0,0.5},
    neutral = {0.1,0.1,0.1,0.5},
}
local i = 0
for name, color in pairs(cz.owner) do
    i = i + 1
    trigger.action.circleToAll(-1, 6000+i, cz:getZone(name).point, 510, {0,0,0,0}, rgb[color], 1)
end

--create a sequence of line segments that connect blue zones between first and last bluePerimIds
--we have 3 sequences of points:
--perimIds, which is the outer polygon
--blueOuterPerimIds, which is the sequence within perimIds that is blue
--bluePerimIds, which is blueOuterPerimIds plus points not on outer polygon (ie not a member of perimIds)

local frontlinePoints = {}
-- start with last outer perim point (b/c both perims are constructed as points listed ccw)
-- then continue adding from blue perim list  until first outer perim point reached, wrapping around to start of array 
local lastSharedPerimeterId = blueOuterPerimIds[#blueOuterPerimIds]
local frontlineStartIndex = table.findIndex(bluePerimIds, lastSharedPerimeterId)
local p = frontlineStartIndex
for i = 1, #bluePerimIds do
    table.insert(frontlinePoints, bluePerimIds[p])
    if bluePerimIds[p] == blueOuterPerimIds[1] then
        break
    end
    p = p + 1
    if p > #bluePerimIds then p = 1 end
end

env.info("Frontline points (inclusive) "..mist.utils.tableShow(frontlinePoints))

local ptA = cz:getZone(frontlinePoints[1]).point
local heading = mist.utils.getHeadingPoints(ctrPerim, ptA)
ptA = mist.projectPoint(ptA, 2400, heading)
local ptA2 = mist.projectPoint(ptA, 100, heading)
env.info("line segment from "..frontlinePoints[1])
local ptB, ptB2
for i = 2, #frontlinePoints do
    ptB = cz:getZone(frontlinePoints[i]).point
    heading = mist.utils.getHeadingPoints(ctrPerim, ptB)
    ptB = mist.projectPoint(ptB, 2200, heading)
    ptB2 = mist.projectPoint(ptB, 100, heading)
    trigger.action.lineToAll(-1, 1700+i, ptA, ptB, {0,0.3,1,1}, 1)
    trigger.action.lineToAll(-1, 1800+i, ptA2, ptB2, {0,0.3,1,1}, 1)
    env.info("line segment from "..frontlinePoints[i])
    ptA = ptB
    ptA2 = ptB2
end
