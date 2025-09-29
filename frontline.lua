--[[ This is handy for development, so that you don't need to delete and re-add the individual scripts in the ME when you make a change.  These will not be packaged with the .miz, so you shouldn't use this script loader for packaging .miz files for other machines/users.  You'll want to add each script individually with a DO SCRIPT FILE ]]--
--assert(loadfile("C:\\Users\\Kelvin\\Documents\\code\\RotorOps\\scripts\\RotorOps.lua"))()

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

function isCounterClockwise(p1, p2, p3)
    -- swapped to account for DCS coordinate weirdness
    return (p2.y - p1.y) * (p3.x - p1.x) - (p2.x - p1.x) * (p3.y - p1.y) > 0
    -- standard (x,y) as (N/S,E/W) version:
    -- return (p2.x - p1.x) * (p3.y - p1.y) - (p2.y - p1.y) * (p3.x - p1.x) > 0
end

local westmost = 1 --zone y is E/W yes? == Vec3's z
local eastmost = 1
local northmost = 1
local southmost = 1
function findCompassMaxima(zones)
    for i = 2, #zones do
        if zones[i].y < zones[westmost].y then
            westmost = i
        elseif zones[i].y > zones[eastmost].y then
            eastmost = i
        end
        if zones[i].x < zones[southmost].x then
            southmost = i
        elseif zones[i].x > zones[northmost].x then
            northmost = i
        end
    end
end

function findPerimeterZones(zones) --convex hull algo
    if #zones < 3 then return zones end

    local leftmost = 1
    for i = 2, #zones do
        if zones[i].y < zones[leftmost].y then
            leftmost = i
        end
    end

    local hull = {}
    local current = leftmost
    
    repeat
        table.insert(hull, current) --first point will be westmost
        local next = 1

        for i = 2, #zones do
            if next == current or isCounterClockwise(zones[current], zones[i], zones[next]) then
                next = i
            end
        end

        current = next
    until current == leftmost --we're back at first point

    return hull --returns table of IDs of zone in controlzones
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

function findZonesNearPoint(startPoint, zones, maxDistance)
    env.info("### looking for points "..maxDistance.." from "..startPoint.x..", "..startPoint.y)
    local nearbyzones = {}
    for i, zone in pairs(zones) do
        local dist = mist.utils.get2DDist(startPoint, { x = zone.x, y = zone.y })
        env.info("distance to "..zone.name.." is "..dist)
        if dist < maxDistance then
            table.insert(nearbyzones, i)
        end
    end
    return nearbyzones
end

-- env.info( mist.utils.tableShow(mist.DBs.zonesByName) )
local controlzones = {}
for zonename, zoneobj in pairs(mist.DBs.zonesByName) do
  if string.sub(zonename,1,7) == 'control' then
    -- add an 'owner' property to zones
    -- zoneobj.owner = 0
    table.insert(controlzones, zoneobj)
    trigger.action.circleToAll(-1, 5000+zoneobj.zoneId, zoneobj.point, 700, {0,0,0,0.5}, {0,0,0,0}, 1)
  end
end

local perimIds = findPerimeterZones(controlzones)
env.info("Perim IDs"..mist.utils.tableShow(perimIds))
env.info("length of table: "..#perimIds)
for i, zoneId in pairs(perimIds) do
    mist.marker.drawZone(controlzones[zoneId].name, { color = {1,1,1,0.2} })
    trigger.action.textToAll(-1, 240+i, controlzones[zoneId].point, {1,1,0.6,1}, {0,0,0,0}, 20, true, "Perim "..i.." / Zone "..perimIds[i].."="..zoneId.." ("..controlzones[zoneId].name..")")
end

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
    mist.marker.drawZone(controlzones[perimIds[pos]].name, { fillColor = {0,0.5,1,0.5} })
end
env.info("Blue starts with "..#blueOuterPerimIds.." perimeter zones")
env.info("They are "..mist.utils.tableShow(blueOuterPerimIds))

findCompassMaxima(controlzones)
local width = controlzones[eastmost].y - controlzones[westmost].y
local height = controlzones[northmost].x - controlzones[southmost].x
local centerpoint = { y = 200, x = controlzones[southmost].point.x+height/2, z = controlzones[westmost].point.z+width/2 }
trigger.action.circleToAll(-1, 1, centerpoint, 350, {0,0,0,0}, {0.8,0.8,0.1,1}, 1) -- mark center of combat area

--find centroid (averaged point, center of mass) of blue perimeter, and use that to find nearby (non-perimeter) zones to create a blue cluster
local sumX = 0
local sumY = 0
for i, id in pairs(blueOuterPerimIds) do
    sumX = sumX + controlzones[id].x
    sumY = sumY + controlzones[id].y
end
local ctrPerim = { x = sumX/#blueOuterPerimIds, y = sumY/#blueOuterPerimIds }
trigger.action.circleToAll(-1, 3, {x = ctrPerim.x, y = 200, z = ctrPerim.y}, 350, {0,0,0,0}, {0.3,1,0.6,1}, 1) -- mark center of blue edge area
local startDistance = math.min(width, height)/2
local bluezoneIds = findZonesNearPoint(ctrPerim, controlzones, startDistance)
env.info("made nearby zones blue: "..#bluezoneIds)

for _, zoneId in pairs(bluezoneIds) do
    mist.marker.drawZone(controlzones[zoneId].name, { color = {0,0,0,0}, fillColor = {0,0,0.7,0.3} })
end
table.insert(bluezones, firstzone)

-- map drawing args: shape, coalition, id, pt1...ptN, linecolor, fillcolor, linetype 
-- trigger.action.markupToAll(7, -1, 99, pt1, pt2, pt3, pt4, {1,0,0,1}, {0,0,0,0}, 6)
local blueedge = findPerimeterZones(bluezones)
local initialPt = blueedge[1].point
local ptA = initialPt
for i = 2, #blueedge do
    ptB = blueedge[i].point
    trigger.action.markupToAll(7, -1, 700+i, ptA, ptB, {0,0,1,1}, {0,0,1,1}, 4)
    -- mist.marker.add({ pos = ptB, id = 800+i, markType = 5, message = "Line "..blueedge[i].name })
    -- trigger.action.textToAll(-1, 800+i, ptB, {0,0,0,1}, {0,0,0,0}, 20, true, "Line "..blueedge[i].name.." to "..blueedge[i-1].name)
    ptA = ptB
end
trigger.action.markupToAll(7, -1, 777, initialPt, ptB, {0,0,1,1}, {0,0,0,1}, 4)
