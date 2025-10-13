--[[ This is handy for development, so that you don't need to delete and re-add the individual scripts in the ME when you make a change.  These will not be packaged with the .miz, so you shouldn't use this script loader for packaging .miz files for other machines/users.  You'll want to add each script individually with a DO SCRIPT FILE ]]--
--assert(loadfile("C:\\Users\\Kelvin\\Documents\\code\\RotorOps\\scripts\\RotorOps.lua"))()

local ControlZones = {}
ControlZones.__index = ControlZones

function ControlZones.new(namedZones)
    local self = setmetatable({}, ControlZones)
    if not namedZones then
        self.allZones = {}      --array of names of zones
        self.zonesByName = {}   --full zone details indexed by zone name
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

function findNearbyZones(startzone, zones, distance)
    env.info("### looking for points "..distance.." from "..startzone.name)
    local nearbyzones = {}
    for i, zone in pairs(zones) do
        if zone.name == startzone.name then
            env.info("pass")
        else
            dist = mist.utils.get3DDist(startzone.point, zone.point)
            env.info("distance to "..zone.name.." is "..dist)
            if dist < distance then
                table.insert(nearbyzones, zone)
            end
        end
    end
    return nearbyzones
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

local perimIds = cz:findPerimeter(cz.allZones)
env.info("Perim IDs"..mist.utils.tableShow(perimIds))
env.info("length of table: "..#perimIds)

-- choose a few perimeter points for blue
-- requirements: adjacent, at least 2, not more than half the total
-- result will be ids (pos) of zones in controlzones table
local blueOuterPerimIds = {}

local startElem = math.random(#perimIds)
local endElem = startElem + math.random(math.floor(#perimIds/2)) -- blue will start with at least 2, up to half the perimeter zones
env.info("start, end: "..startElem..", "..endElem)

for i = startElem, endElem do
    local pos = i
    if i > #perimIds then
        pos = i - #perimIds
    end
    table.insert(blueOuterPerimIds, perimIds[pos])
    env.info("i: "..i..", pos in perim table: "..pos)
    env.info("perimeter zone #"..pos.." is value (zone) of "..perimIds[pos]..", which is CZ[_]")
    -- mist.marker.drawZone(perimIds[pos], { fillColor = {0,0.5,1,0.5} })
end
env.info("Blue starts with "..#blueOuterPerimIds.." perimeter zones")
env.info("They are "..mist.utils.tableShow(blueOuterPerimIds))

cz:assignCompassMaxima()
local width = cz.maxima.eastmost.y - cz.maxima.westmost.y
local height = cz.maxima.northmost.x - cz.maxima.southmost.x
local centerpoint = { y = 200, x = cz.maxima.southmost.x+height/2, z = cz.maxima.westmost.y+width/2 }

--find centroid (averaged point, center of mass) of blue perimeter, and use that to find nearby (non-perimeter) zones to create a blue cluster
--this method could stand to be replaced with something better
local sumX = 0
local sumY = 0
for i, id in pairs(blueOuterPerimIds) do
    sumX = sumX + cz.zonesByName[id].x
    sumY = sumY + cz.zonesByName[id].y
end
local ctrPerim = { x = sumX/#blueOuterPerimIds, y = sumY/#blueOuterPerimIds }
local startDistance = math.min(width, height)/2
local bluezoneIds = cz:findZonesNearPoint(ctrPerim, cz.allZones, startDistance)
-- make sure all previously chosen blue outer perim points are included
for _, name in pairs(blueOuterPerimIds) do
    if not table.contains(bluezoneIds, name) then
        table.insert(bluezoneIds, name)
    end
end
env.info("made nearby zones blue: "..#bluezoneIds)

for i, zoneId in pairs(bluezoneIds) do
    -- mist.marker.drawZone(zoneId, { color = {0,0,0,0}, fillColor = {0,0,0.7,0.3} })
    trigger.action.circleToAll(-1, 6000+i, cz:getZone(zoneId).point, 510, {0.1,0.4,1,0.4}, {0.1,0.4,1,0.1}, 1)
end

--remove points that were elements of the whole perimeter
--so only 'internal' perimeter remains, i.e. points facing non-blue points
local bluePerimIds = cz:findPerimeter(bluezoneIds)
env.info(#bluePerimIds.." zones form the blue perimeter: "..mist.utils.tableShow(bluePerimIds))
env.info("battlefront anchor zones "..blueOuterPerimIds[1]..", "..blueOuterPerimIds[#blueOuterPerimIds])

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
