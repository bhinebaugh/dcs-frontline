local rgb = require("constants").rgb
local garrisonTemplates = require("constants").garrisonTemplates
local groundTemplates = require("constants").groundTemplates
local Map = require("map")
local isCounterClockwise = require("helpers").isCounterClockwise --Load helper functions

local ControlZones = {}
ControlZones.__index = ControlZones

function ControlZones.new(namedZones, groundTemplates)
    local self = setmetatable({}, ControlZones)
    if not namedZones then
        self.allZones = {}      --array of names of zones
        self.zonesByName = {}   --full zone details indexed by zone name
        self.zoneCheckCounter = 1 --zone to be considered by next scheduled ownership check
        self.owner = {}
        self.neighbors = {}
        self.edges = {}
        self.perimeter = {}
        self.front = {
            blue = {},
            red = {}
        }
        self.depthMap = {
            blue = {},
            red = {}
        }
    else
        -- self.zonesByName = namedZones
        --put keys into allZones
    end
    self.maxima = nil
    self.groupCounter = 1
    self.commanders = {}
    -- self.maxima = {
    --     westmost = nil,
    --     eastmost = nil,
    --     northmost = nil,
    --     southmost = nil
    -- }
    self.groundTemplates = groundTemplates or {
        blue = {},
        red = {}
    }
    self.centroid = {}
    return self
end

function ControlZones:getNewGroupId()
    self.groupCounter = self.groupCounter + 1
    return self.groupCounter
end

function ControlZones:addCommander(side, c)
    self.commanders[side] = c
end

function ControlZones:getOpponent(color)
    return color == "blue" and "red" or "blue"
end

function ControlZones:setup(options)
    options = options or {}

    for zonename, zoneobj in pairs(mist.DBs.zonesByName) do
        if string.sub(zonename,1,7) == 'control' then
            -- add an 'owner' property to zones
            -- zoneobj.owner = 0
            self.zonesByName[zonename] = zoneobj --indexed by name of the trigger zone
            table.insert(self.allZones, zoneobj.name) --list of all zone names / names of all zones
        end
    end

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

    self.map = Map.new()

    self.perimeter = self:findPerimeter(self.allZones)
    self.centroid["blue"] = self:centroidOfZones(self:getCluster("blue"))
    self.centroid["red"] = self:centroidOfZones(self:getCluster("red"))

    self.timerId = mist.scheduleFunction(
        ControlZones.checkOwnership,
        {self},
        timer.getTime() + 20,
        2 --every two seconds
    )
end

function ControlZones:centroidOfZones(zones)
    local sumX = 0
    local sumY = 0
    for _, id in pairs(zones) do
        sumX = sumX + self.zonesByName[id].x
        sumY = sumY + self.zonesByName[id].y
    end
    return { x = sumX / #zones, y = sumY / #zones }
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

function ControlZones:changeZoneOwner(name, newOwner)
    local formerOwner = self.owner[name]
    if newOwner == formerOwner then
        env.info("Warning: zone not changed, "..newOwner.." already controls "..name)
        return false
    end
    self.owner[name] = newOwner
    env.info("<<<<<<>>>>>>> Control change: "..name.." switched from "..formerOwner.." to "..newOwner)

    self.map:redrawZone(name, newOwner, self:getZone(name).point)
    if formerOwner ~= "neutral" then
        self:recalculateGeometry(formerOwner)
        for i, front in pairs(self.front[formerOwner]) do
            self.map:drawFrontline(front.points, formerOwner, i == 1, front.isLoop)
        end
    end
    if newOwner ~= "neutral" then
        self:recalculateGeometry(newOwner)
        for i, front in pairs(self.front[newOwner]) do
            self.map:drawFrontline(front.points, newOwner, i == 1, front.isLoop)
        end
    end
end

function ControlZones:checkOwnership()
    local zoneName = self.allZones[self.zoneCheckCounter]
    self:updateZoneOwner(zoneName)

    self.zoneCheckCounter = self.zoneCheckCounter + 1
    if self.zoneCheckCounter > #self.allZones then self.zoneCheckCounter = 1 end
end

function ControlZones:updateZoneOwner(zoneName)
    local ownerColor = self.owner[zoneName]
    local blueGround = mist.makeUnitTable({'[blue][vehicle]'})
    local redGround = mist.makeUnitTable({'[red][vehicle]'})
    local groundInZone = {
        blue = mist.getUnitsInZones(blueGround, zoneName),
        red = mist.getUnitsInZones(redGround, zoneName)
    }
    if ownerColor == "neutral" then
        -- if blue and no red, blue now owns
        -- if red and no blue, red now owns
        -- if neither or both, stays neutral
        if #groundInZone["blue"] > 0 and #groundInZone["red"] <= 0 then
            self:changeZoneOwner(zoneName, "blue")
        elseif #groundInZone["red"] > 0 and #groundInZone["blue"] <= 0 then
            self:changeZoneOwner(zoneName, "red")
        end
    elseif ownerColor and #groundInZone[ownerColor] <= 0 then
        env.info("####### "..ownerColor.." no longer has any units in "..zoneName)
        local opponentColor = self:getOpponent(ownerColor)
        if #groundInZone[opponentColor] > 0 then
            self:changeZoneOwner(zoneName, opponentColor)
        else
            self:changeZoneOwner(zoneName, "neutral")
        end
    end
end

function ControlZones:addNeighbor(key1, key2) --bidirectional
    if not self:hasNeighbor(key1, key2) then
        table.insert(self.neighbors[key1], key2)
    end
    if not self:hasNeighbor(key2, key1) then
        table.insert(self.neighbors[key2], key1)
    end
end

function ControlZones:hasNeighbor(key, neighborKey)
    for _, n in ipairs(self.neighbors[key]) do
        if n == neighborKey then return true end
    end
    return false
end

function ControlZones:getNeighbors(key, color, includeNeutral)
    local color = color or nil
    if not color then
        return self.neighbors[key] or {}
    end
    local different = {}
    for _, n in ipairs(self.neighbors[key]) do
        if self.owner[n] == color or (includeNeutral and self.owner[n] == "neutral") then
            table.insert(different, n)
        end
    end
    return different
end

function ControlZones:constructDelaunayIndex()
    local points = {}
    local keyToIndex = {}
    local indexToKey = {}
    local index = 1

    -- Convert to indexed array for algorithm
    -- e.g. {1: {zone info}, ...}
    for key, point in pairs(self.zonesByName) do
        points[index] = {x = point.x, y = point.y}
        keyToIndex[key] = index
        indexToKey[index] = key
        index = index + 1
        self.neighbors[key] = {}
    end

    local triangles = self:delaunayTriangulate(points)

    -- Convert back to key-based triangles
    -- e.g. {3,15,7} to {"control-5","control-8","control-7"}
    self.triangles = {}
    for _, tri in ipairs(triangles) do
        table.insert(self.triangles, {
            indexToKey[tri[1]],
            indexToKey[tri[2]],
            indexToKey[tri[3]]
        })
    end
    for _, tri in ipairs(self.triangles) do
        self:addNeighbor(tri[1], tri[2])
        self:addNeighbor(tri[2], tri[3])
        self:addNeighbor(tri[3], tri[1])
    end

    self.keyToIndex = keyToIndex
    self.indexToKey = indexToKey

end

-- Bowyer-Watson Delaunay Triangulation
function ControlZones:delaunayTriangulate(points)
    if #points < 3 then return {} end

    -- Find bounding super-triangle to bootstrap the algorithm
    -- (Starting at infinity)
    local minX, minY = math.huge, math.huge
    local maxX, maxY = -math.huge, -math.huge

    for _, p in ipairs(points) do
        minX = math.min(minX, p.x)
        minY = math.min(minY, p.y)
        maxX = math.max(maxX, p.x)
        maxY = math.max(maxY, p.y)
    end

    local dx = maxX - minX
    local dy = maxY - minY
    local deltaMax = math.max(dx, dy) * 2

    local superTriangle = {
        {x = minX - deltaMax, y = minY - 1},
        {x = minX + deltaMax * 2, y = minY - 1},
        {x = minX + deltaMax, y = maxY + deltaMax * 2}
    }

    -- Add super triangle points
    for _, p in ipairs(superTriangle) do
        table.insert(points, p)
    end

    local triangles = {{#points - 2, #points - 1, #points}}

    -- Add each point one at a time
    for i = 1, #points - 3 do
        local point = points[i]
        local badTriangles = {}

        -- Find triangles whose circumcircle contains the point
        for j, tri in ipairs(triangles) do
            if self:inCircumcircle(point, points[tri[1]], points[tri[2]], points[tri[3]]) then
                table.insert(badTriangles, j)
            end
        end

        -- Find the boundary of the polygonal hole
        local polygon = {}
        for _, triIdx in ipairs(badTriangles) do
            local tri = triangles[triIdx]
            local edges = {
                {tri[1], tri[2]},
                {tri[2], tri[3]},
                {tri[3], tri[1]}
            }

            for _, edge in ipairs(edges) do
                local shared = false
                for _, otherTriIdx in ipairs(badTriangles) do
                    if otherTriIdx ~= triIdx then
                        local otherTri = triangles[otherTriIdx]
                        if self:triangleHasEdge(otherTri, edge[1], edge[2]) then
                            shared = true
                            break
                        end
                    end
                end

                if not shared then
                    table.insert(polygon, edge)
                end
            end
        end

        -- Remove bad triangles (in reverse to maintain indices)
        for j = #badTriangles, 1, -1 do
            table.remove(triangles, badTriangles[j])
        end

        -- Create new triangles from point to polygon edges
        for _, edge in ipairs(polygon) do
            table.insert(triangles, {edge[1], edge[2], i})
        end
    end

    -- Remove triangles that share vertices with super triangle
    local finalTriangles = {}
    local superIndices = {#points - 2, #points - 1, #points}

    for _, tri in ipairs(triangles) do
        local hasSuper = false
        for _, v in ipairs(tri) do
            for _, s in ipairs(superIndices) do
                if v == s then
                    hasSuper = true
                    break
                end
            end
            if hasSuper then break end
        end

        if not hasSuper then
            table.insert(finalTriangles, tri)
        end
    end

    return finalTriangles
end

-- Check if point is inside circumcircle of triangle
function ControlZones:inCircumcircle(p, a, b, c)
    local ax, ay = a.x - p.x, a.y - p.y
    local bx, by = b.x - p.x, b.y - p.y
    local cx, cy = c.x - p.x, c.y - p.y

    local det = (ax * ax + ay * ay) * (bx * cy - cx * by) -
                (bx * bx + by * by) * (ax * cy - cx * ay) +
                (cx * cx + cy * cy) * (ax * by - bx * ay)

    return det > 0
end

-- Check if triangle contains edge
function ControlZones:triangleHasEdge(tri, v1, v2)
    return (tri[1] == v1 and tri[2] == v2) or (tri[2] == v1 and tri[1] == v2) or
           (tri[2] == v1 and tri[3] == v2) or (tri[3] == v1 and tri[2] == v2) or
           (tri[3] == v1 and tri[1] == v2) or (tri[1] == v1 and tri[3] == v2)
end

-- Get perimeter edges of the provided color that are facing another color
function ControlZones:getPerimeterZones(color)
    if not self.triangles then
        self:constructDelaunayIndex()
    end
    
    local frontZones = {}
    local frontSet = {}
    
    for _, tri in ipairs(self.triangles) do
        local colors = {
            self.owner[tri[1]],
            self.owner[tri[2]],
            self.owner[tri[3]]
        }
        
        -- Check each edge of the triangle
        local edgePairs = {
            {1, 2, 3},
            {2, 3, 1},
            {3, 1, 2}
        }
        
        for _, pair in ipairs(edgePairs) do
            local v1, v2, v3 = pair[1], pair[2], pair[3]
            
            -- Edge v1-v2 is part of perimeter if:
            -- - both v1 and v2 are 'color'
            -- - v3 is 'facingColor' or "neutral"
            if colors[v1] == color and colors[v2] == color and colors[v3] ~= color then
                local key1, key2 = tri[v1], tri[v2]
                if not frontSet[key1] then
                    frontSet[key1] = true
                    table.insert(frontZones, key1)
                end
                if not frontSet[key2] then
                    frontSet[key2] = true
                    table.insert(frontZones, key2)
                end
            end
        end
    end
    
    return frontZones
end

function ControlZones:getPerimeterEdges(color, returnPoints) --returns a table of pairs of zone names (default) or positions of those zones
    if not self.triangles then
        self:constructDelaunayIndex()
    end
    
    local edges = {}
    local edgeSet = {}  -- to avoid duplicates
    
    for _, tri in ipairs(self.triangles) do
        local colors = {
            self.owner[tri[1]],
            self.owner[tri[2]],
            self.owner[tri[3]]
        }
        
        -- Check each edge of the triangle
        local edgePairs = {
            {1, 2, 3},
            {2, 3, 1},
            {3, 1, 2}
        }
        
        for _, pair in ipairs(edgePairs) do
            local v1, v2, v3 = pair[1], pair[2], pair[3]
            
            -- Edge v1-v2 is part of perimeter if:
            -- - both v1 and v2 are 'color'
            -- - v3 is 'facingColor' or "neutral"
            if colors[v1] == color and colors[v2] == color and colors[v3] ~= color then
                local key1, key2 = tri[v1], tri[v2]
                local edgeKey = key1 < key2 and (key1 .. "-" .. key2) or (key2 .. "-" .. key1)
                
                if not edgeSet[edgeKey] then
                    edgeSet[edgeKey] = true
                    if returnPoints then
                        table.insert(edges, {p1 = self:getZone(key1).point, p2 = self:getZone(key2).point, o1 = self:getZone(tri[v3]).point})
                    else
                        table.insert(edges, {p1 = key1, p2 = key2, o1 = tri[v3]})
                    end
                end
            end
        end
    end
    
    return edges
end

function ControlZones:getEdge(z1, z2)
    local edgeKey = z1 < z2 and (z1 .. "-" .. z2) or (z2 .. "-" .. z1)
    return self.edges[edgeKey]
end

function ControlZones:getAllEdges()
    if not self.triangles then
        self:constructDelaunayIndex()
    end
    if not self.edges then
        self:precalculateConnections()
    end

    return self.edges
end

function ControlZones:precalculateConnections()
    if not self.triangles then
        self:constructDelaunayIndex()
    end
    local edgeSet = {}  -- to avoid duplicates

    -- Examine each triangle
    for l, tri in ipairs(self.triangles) do
        -- Check each edge of the triangle
        local triPairs = {
            {1, 2},
            {2, 3},
            {3, 1}
        }
        for m, pair in ipairs(triPairs) do
            local v1, v2 = pair[1], pair[2]
            local key1, key2
            if tri[v1] < tri[v2] then
                key1, key2 = tri[v1], tri[v2]
            else
                key1, key2 = tri[v2], tri[v1]
            end
            local edgeKey = key1 .. "-" .. key2

            if not edgeSet[edgeKey] then
                edgeSet[edgeKey] = true
                local z1, z2 = self:getZone(key1), self:getZone(key2)
                local heading = mist.utils.getHeadingPoints(z1.point, z2.point)
                local distance = mist.utils.get2DDist(z1.point, z2.point)
                local roadPath = land.findPathOnRoads("roads", z1.x, z1.y, z2.x, z2.y)
                local roadDistance = roadPath and mist.getPathLength(roadPath) or 10*distance
                local allowable_detour = 1.4
                local cross_country = roadDistance / distance > allowable_detour

                -- Depending on number of zones and their separation, it could be speed things up
                -- to not bother with full calculation if road path is obviously inefficient
                -- local cutoff = distance * 2
                -- local roadDistance, _ = mist.getPathLength(roadPath, cutoff)

                self.edges[edgeKey] = {
                    p1 = z1.point,
                    p2 = z2.point,
                    heading = heading,
                    distance = {
                        straight = distance,
                        road = roadDistance,
                    },
                    crosscountry = cross_country,
                    terrainDifficulty = 0,
                    triangles = {l} --index of member triangle in self.triangles
                }
            elseif not table.contains(self.edges[edgeKey].triangles, l) then
                table.insert(self.edges[edgeKey].triangles, l)
            end
        end
    end

    return self.edges
end

-- Normalize angle to [0, 2π)
local function normalizeAngle(angle)
    local TWO_PI = 2 * math.pi
    angle = angle % TWO_PI
    if angle < 0 then
        angle = angle + TWO_PI
    end
    return angle
end
local function angularDistance(from, to)
    local TWO_PI = 2 * math.pi
    local diff = (to - from) % TWO_PI
    if diff < 0 then
        diff = diff + TWO_PI
    end
    return diff
end

function ControlZones:getHeading(z1, z2)
    local heading = self:getEdge(z1, z2).heading
    if z1 < z2 then
        return heading
    else
        return normalizeAngle(heading + math.pi)
    end
end

function ControlZones:calculateLength(front)
    local length = 0
    if #front.zones < 2 then
        return length
    end

    for i=2, #front.zones do
        local edge = self:getEdge(front.zones[i], front.zones[i-1])
        length = length + edge.distance.straight
    end
    if front.isLoop then
        local edge = self:getEdge(front.zones[#front.zones], front.zones[1])
        length = length + edge.distance.straight
    end

    return length
end

-- Calculates edges in contiguous sequence, returning multiple if frontline is disconnected
function ControlZones:getOrderedFrontlines(color)
    local fronts = {}

    -- Find any isolated zones (no friendly neighbors)
    local ownZones = self:getCluster(color)
    for _, zone in pairs(ownZones) do
        local friendlyNeighbors = self:getNeighbors(zone, color, false)
        if #friendlyNeighbors == 0 then
            local segment = {
                zones = {zone},
                points = {},
                length = nil,
                isLoop = true,
            }
            local pt = self:getZone(zone).point
            local eighth = math.pi/4
            for i=1,8 do
                table.insert(segment.points, {center = pt, heading = i*eighth})
            end
            table.insert(segment.points, {center = pt, heading = eighth})

            table.insert(fronts, segment)
        end
    end

    local edges = self:getPerimeterEdges(color)

    if #edges == 0 then return fronts end
    local globalVisited = {}

    -- Generate a lookup table for all own border zones
    local frontZones = {}
    for _, edge in ipairs(edges) do
        frontZones[edge.p1] = true
        frontZones[edge.p2] = true
    end

    -- Find flank zones (both on the frontline and on the global perimeter)
    local anchors = {}
    for zone, _ in pairs(frontZones) do
        if table.contains(self.perimeter, zone) then
            table.insert(anchors, zone)
        end
    end

    -- Find frontline path by clockwise sweep from previous allied zone, projecting points toward each enemy zone
    -- then jumping to first allied zone encountered until back at start zone or reached the other flank (zone is on the perimeter)
    local function constructSegment(startKey, prev)
        local segment = {
            zones = {},
            points = {},
            length = nil,
            isLoop = false,
        }
        local current = startKey
        local lastEnemy = nil
        local prevOnPerimeter = false

        repeat -- keep hopping to allied neighbor (the one on closest cw heading after enemy neighbor)
            globalVisited[current] = true
            table.insert(segment.zones, current)
            local z = self:getZone(current)

            local foundNext = false

            -- Sort all neighbors by distance from prev heading
            local initialHeading = normalizeAngle(
                mist.utils.getHeadingPoints(
                    self:getZone(current).point,
                    self:getZone(prev).point
                )
            )
            local sortedNeighbors = self:getNeighbors(current)
            table.sort(sortedNeighbors, function(a, b)
                local headingA = normalizeAngle(mist.utils.getHeadingPoints(z.point, self:getZone(a).point))
                local headingB = normalizeAngle(mist.utils.getHeadingPoints(z.point, self:getZone(b).point))
                local arcA = angularDistance(initialHeading, headingA)
                local arcB = angularDistance(initialHeading, headingB)
                return arcA < arcB
            end)
            table.insert(sortedNeighbors, table.remove(sortedNeighbors, 1))

            local nextFriendlyZone = nil
            for _, neighbor in pairs(sortedNeighbors) do
                if self.owner[neighbor] == color then
                    nextFriendlyZone = neighbor
                    break
                else --enemy neighbor, record heading
                    lastEnemy = neighbor
                    local enemyHeading = self:getHeading(current, neighbor)
                    table.insert(segment.points, {center = z.point, heading = enemyHeading})
                end
            end

            if nextFriendlyZone and frontZones[nextFriendlyZone] then --end if not on frontline (not facing enemy)
                local currentOnPerimeter = table.contains(self.perimeter, current)
                if currentOnPerimeter and prevOnPerimeter and globalVisited[nextFriendlyZone] then
                    foundNext = false
                elseif currentOnPerimeter and nextFriendlyZone == startKey then
                    foundNext = false
                else
                    foundNext = true
                    prevOnPerimeter = currentOnPerimeter
                    prev = current
                    current = nextFriendlyZone
                end
            end
        until (current == startKey) or not foundNext

        if current == startKey then
            -- make a final, extra line back to original zone, offset toward shared enemy neighbor
            if not table.contains(self.perimeter, current) then
                segment.isLoop = true
            end
            if lastEnemy then
                local lastPoint = self:getZone(current).point
                local enemyHeading = mist.utils.getHeadingPoints(lastPoint, self:getZone(lastEnemy).point)
                table.insert(segment.points, {center = lastPoint, heading = enemyHeading})
            end
        end
        segment.length = self:calculateLength(segment)

        return segment
    end --end local function constructSegment

    -- Construct all anchored front lines by starting at each left flank zone
    for _, zone in pairs(anchors) do
        local i = table.findIndex(self.perimeter, zone)
        if i then
            local ccw = i+1 > #self.perimeter and 1 or i+1
            local cw = i-1 < 1 and #self.perimeter or i-1
            local ccwz = self.perimeter[ccw]
            local cwz = self.perimeter[cw]
            if self.owner[ccwz] == color and self.owner[cwz] ~= color then
                local segment = constructSegment(zone, ccwz)
                table.insert(fronts, segment)
            elseif self.owner[ccwz] ~= color and self.owner[cwz] ~= color then
                local segment = constructSegment(zone, ccwz)
                table.insert(fronts, segment)
            end
        end
    end

    -- Examine all zones on border to identify closed loop (internal) fronts
    for startKey, _ in pairs(frontZones) do
        if not globalVisited[startKey] then
            env.info(">>>>>>> "..startKey.." hasn't been visited yet")
            local tris = {}
            -- Find triangles that include the zone in question
            for _, edge in pairs(edges) do
                if edge.p1 == startKey then
                    table.insert(tris, {edge.p1, edge.p2, edge.o1})
                elseif edge.p2 == startKey then
                    table.insert(tris, {edge.p2, edge.p1, edge.o1})
                end
            end
            -- Identify previous allied zone by startKey->enemy->allied being a ccw sequence
            for _, tri in pairs(tris) do
                local z1 = self:getZone(tri[1])
                local z2 = self:getZone(tri[3]) --enemy neighbor
                local z3 = self:getZone(tri[2]) --allied neighbor

                if isCounterClockwise({x = z1.x, y = z1.y}, {x = z2.x, y = z2.y}, {x = z3.x, y = z3.y}) then
                    env.info("   using "..tri[2].." as prev for "..startKey)
                    local segment = constructSegment(startKey, tri[2])
                    table.insert(fronts, segment)
                end
            end
        end
    end

    self.front[color] = fronts

    return fronts
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
        local zone = self:getZone(zonename)
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

function ControlZones:calculateDepthMap(color)
    local depthMap = {}
    local queue = {}
    local maxDepth = 0

    for _, zoneName in ipairs(self:getPerimeterZones(color)) do
        if not depthMap[zoneName] then
            depthMap[zoneName] = 0
            table.insert(queue, zoneName)
        end
    end

    local head = 1
    while head <= #queue do
        local current = queue[head]
        head = head + 1
        for _, neighbor in ipairs(self:getNeighbors(current, color)) do
            if not depthMap[neighbor] then
                depthMap[neighbor] = depthMap[current] + 1
                if depthMap[neighbor] > maxDepth then maxDepth = depthMap[neighbor] end
                table.insert(queue, neighbor)
            end
        end
    end

    self.depthMap[color] = depthMap
    return maxDepth
end

function ControlZones:selectZonesAtDepth(color, targetDepth)
    local result = {}
    for zoneName, depth in pairs(self.depthMap[color]) do
        if depth == targetDepth then
            table.insert(result, zoneName)
        end
    end
    return result
end

-- Returns a random point on the edge between two adjacent zones of the given depth.
-- Pass an optional bias (0-1) to weight t toward the midpoint; default 0 = uniform.
function ControlZones:randomPointOnEdgeAtDepth(color, targetDepth, bias)
    local eligibleEdges = self:edgesAtDepth(color, targetDepth)
    if #eligibleEdges == 0 then return nil end

    local edge = eligibleEdges[math.random(#eligibleEdges)]
    return self:randomPointOnEdge(edge, bias)
end

function ControlZones:edgesAtDepth(color, targetDepth)
    local zones = self:selectZonesAtDepth(color, targetDepth)

    -- Collect all edges where both endpoints are at targetDepth
    local eligibleEdges = {}
    for i = 1, #zones do
        for j = i + 1, #zones do
            local edge = self:getEdge(zones[i], zones[j])
            if edge then
                table.insert(eligibleEdges, edge)
            end
        end
    end

    return eligibleEdges
end

function ControlZones:randomPointOnEdge(e, bias)
    local t = math.random()
    if bias and bias > 0 then
        -- blend toward 0.5 by the bias factor
        t = t + bias * (0.5 - t)
    end

    return {
        x = e.p1.x + t * (e.p2.x - e.p1.x),
        y = e.p1.z + t * (e.p2.z - e.p1.z), --yes, this is awful, but edges use Vec3 coords
    }
end

-- Selects up to targetCount points from candidates using farthest-point sampling,
-- guaranteeing maximum spread. Each pick is the candidate farthest from all
-- already-selected points. Stops early if the next-best candidate is closer than
-- minSeparation (optional). Accepts and returns tables of {x, y} points.
function ControlZones:farthestPointSample(candidates, targetCount, minSeparation)
    if #candidates == 0 then return {} end
    targetCount = math.min(targetCount, #candidates)

    local selected = {}
    local used = {}

    local firstIdx = math.random(#candidates)
    table.insert(selected, candidates[firstIdx])
    used[firstIdx] = true

    while #selected < targetCount do
        local bestIdx = nil
        local bestDist = -1

        for i, candidate in ipairs(candidates) do
            if not used[i] then
                local minDist = math.huge
                for _, sel in ipairs(selected) do
                    local dx = candidate.x - sel.x
                    local dy = candidate.y - sel.y
                    local d = math.sqrt(dx * dx + dy * dy)
                    if d < minDist then minDist = d end
                end
                if minDist > bestDist then
                    bestDist = minDist
                    bestIdx = i
                end
            end
        end

        if not bestIdx then break end
        if minSeparation and bestDist < minSeparation then break end

        table.insert(selected, candidates[bestIdx])
        used[bestIdx] = true
    end

    return selected
end

-- Returns triangles where all three vertices fall within [minDepth, maxDepth].
-- Triangles spanning the boundary of that range (e.g. vertices at depth 1 and 2)
-- produce points that interpolate between those depths, naturally landing in the
-- Goldilocks zone without needing a separate containment check.
function ControlZones:selectTrianglesByDepthRange(color, minDepth, maxDepth)
    local result = {}
    local depthMap = self.depthMap[color]
    if not depthMap then return result end

    for _, tri in ipairs(self.triangles) do
        local d1 = depthMap[tri[1]]
        local d2 = depthMap[tri[2]]
        local d3 = depthMap[tri[3]]
        if d1 and d2 and d3
            and d1 >= minDepth and d1 <= maxDepth
            and d2 >= minDepth and d2 <= maxDepth
            and d3 >= minDepth and d3 <= maxDepth then
            table.insert(result, tri)
        end
    end
    return result
end

-- Returns a uniformly-distributed random point inside a triangle defined by zone names.
-- Uses the sqrt(r1) formula to avoid the non-uniform clustering near the centroid
-- that results from the naive barycentric approach.
function ControlZones:randomPointInTriangle(tri)
    local p1 = self:getZone(tri[1]).point
    local p2 = self:getZone(tri[2]).point
    local p3 = self:getZone(tri[3]).point
    local r1 = math.sqrt(math.random())
    local r2 = math.random()
    return {
        x = (1 - r1) * p1.x + r1 * (1 - r2) * p2.x + r1 * r2 * p3.x,
        y = (1 - r1) * p1.z + r1 * (1 - r2) * p2.z + r1 * r2 * p3.z,
    }
end

function ControlZones:recalculateGeometry(color)
    env.info(".. recalculating geometry for "..color)
    self:getOrderedFrontlines(color)
    self:calculateDepthMap(color)
end

function ControlZones:spawnFARP(color, pt)
    local searchRadius = 1000
    local clearRadius = 120
    local spot = Disposition.getSimpleZones(mist.utils.makeVec3(pt), searchRadius, clearRadius, 1)
    if not spot or not spot[1] then
        env.info("!! no suitable spot found for spawning FARP")
        return false
    end

    local coal = color == "blue" and country.id.USA or country.id.RUSSIA --country.id.USSR
    local farp = {
        ["category"] = "Heliports",
        ["shape_name"] = "FARPS", -- "invisiblefarp"  | "FARP"           | "FARP_SINGLE_01"
        ["type"] = "FARP",        -- "Invisible FARP" | "SINGLE_HELIPAD" | "FARP_SINGLE_01"
        ["unitId"] = mist.getNextUnitId(),
        ["x"] = spot[1].x,
        ["y"] = spot[1].y,
        ["name"] = color.." FARP "..math.random(1000,9999),
        ["heading"] = 0,
        ["dead"] = false,
        ["dynamicSpawn"] = true,
        ["allowHotStart"] = true
        -- ["dynamicCargo"]
    }
    coalition.addStaticObject(coal, farp)

    local farp_stock = {
        blue = {
            "UH-1H",
            -- "UH-60L",
            "OH-6A",
            "AH-6J",
            "OH-58D",
            -- "SA342L",
            -- "SA342M",
            -- "SA342Minigun",
            -- "SA342Mistral",
            "AH-64D_BLK_II",
        },
        red = {
            "Mi-8MT",
            "Mi-24P",
            "Ka-50_3",
        }
    }
    timer.scheduleFunction(
        function (info)
            local farpObj = Airbase.getByName(info.name)
            local wh = farpObj:getWarehouse()
            for _, item in pairs(farp_stock[info.color]) do
                wh:setItem(item, 4)
            end
            wh:setLiquidAmount(0, 1000)
        end,
        {name = farp.name, color = color},
        timer.getTime()+5
    )

    return true -- or farp name or id
end

function ControlZones:orientToClosestEnemy(zoneName)
    local opponent = self:getOpponent(self.owner[zoneName])
    local enemyNeighbors = self:getNeighbors(zoneName, opponent)
    local nearestEnemy
    local dist = math.huge
    for _, enemyZone in pairs(enemyNeighbors) do
        local newDist = self:getEdge(zoneName, enemyZone).distance.straight
        if newDist < dist then
            nearestEnemy = enemyZone
            dist = newDist
        end
    end
    local heading
    if nearestEnemy then
        heading = mist.utils.getHeadingPoints(self:getZone(zoneName).point, self:getZone(nearestEnemy).point)
        -- env.info("-> Orienting units in"..zoneName..": "..mist.utils.toDegree(heading))
    else
        heading =  mist.utils.getHeadingPoints(self.centroid[self.owner[zoneName]], self.centroid[opponent])
        env.info("!? could not find nearestEnemy ("..zoneName.." might not be frontline zone?)")
    end
    return heading
end

function ControlZones:spawnStaticInZone(groupName, zoneName, color, template, heading)
    local zn = self:getZone(zoneName)

    local searchRadius = zn.radius
    local clearRadius = 15
    -- heavy calculation? improve performance; get single, larger spot to speed up?
    local spots = Disposition.getSimpleZones(zn.point, searchRadius, clearRadius, 1)

    if not spots or #spots < 1 then
        env.info("!! coundn't spawn garrison for "..zoneName)
        return false
    end

    local vars = {
        type = template, --"Airshow_Crowd",
        country = color == "blue" and "USA" or "USSR",
        category = "Unarmed",
        x = spots[1].x,
        y = spots[1].y,
        name = groupName,
        heading = heading
    }
    local newGroup = mist.dynAddStatic(vars)

    return newGroup --groupName
end

function ControlZones:spawnGroupAtPoint(groupName, point, color, template, heading)
    local unitSet = {}

    local searchRadius = 500
    local clearRadius = 50
    -- heavy calculation? improve performance; get single, larger spot to speed up?
    local spots = Disposition.getSimpleZones(point, searchRadius, clearRadius, #template)

    if #spots < #template then
        env.info("!! not enough spots for spawning all units of "..groupName..". spots found: "..#spots.." of "..#template)
        return nil
    end

    for j, unitName in pairs(template) do
        local variance = math.random(-4, 4)/10
        local hdg = heading + variance
        table.insert(unitSet, j, { type = unitName, x = spots[j].x, y = spots[j].y, heading = hdg})
    end
    local newGroup = mist.dynAdd({ -- mist.dynAddStatic()
        groupName = groupName,
        units = unitSet,
        country = color == "blue" and "USA" or "USSR",
        category = "vehicle",
    })

    return groupName
end

function ControlZones:spawnGroupInZone(groupName, zoneName, color, template, heading)
    local zn = self:getZone(zoneName)
    return self:spawnGroupAtPoint(groupName, zn.point, color, template, heading)
end

function ControlZones:fillFrontGaps(front, color)
    if #front.zones < 2 then
        return {}
    end

    local midpoints = {}
    local MAX_FRONT_GAP = 6000
    local avgHeading =  mist.utils.getHeadingPoints(self.centroid[color], self.centroid[self:getOpponent(color)])

    for i=2, #front.zones do
        local edge = self:getEdge(front.zones[i], front.zones[i-1])
        -- if edge.crosscountry
        if edge.distance.straight > MAX_FRONT_GAP then
            local pt = self:randomPointOnEdge(edge, 0.7)

            local r = math.random(#groundTemplates)
            local template = groundTemplates[color][r]

            table.insert(midpoints, pt)
            self:spawnGroupAtPoint("mid_"..math.random(1000,9000), mist.utils.makeVec3(pt), color, template, avgHeading)
        end
    end

    env.info("padded gaps in frontline: "..#midpoints)
    env.info(mist.utils.tableShow(midpoints))
    return midpoints
end

function ControlZones:spawnFrontlineForces(front, color)
    local reserves = {}
    local avgHeading =  mist.utils.getHeadingPoints(self.centroid[color], self.centroid[self:getOpponent(color)])
    local templates = groundTemplates[color]

    local MAX_FRONT_GAP = 6000
    local MAX_GROUPS_PER_ZONE = 2

    for i, zoneName in ipairs(front.zones) do
        local heading = self:orientToClosestEnemy(zoneName)
        for _ = 1, math.random(MAX_GROUPS_PER_ZONE) do
            local groupName = zoneName.."-"..self:getNewGroupId()
            self:spawnGroupInZone(groupName, zoneName, color, templates[math.random(#templates)], heading)
            table.insert(reserves, groupName)
        end

        if i > 1 then
            local edge = self:getEdge(zoneName, front.zones[i-1])
            if edge.distance.straight > MAX_FRONT_GAP then
                local groupName = "midway-"..self:getNewGroupId()
                env.info("Adding group "..groupName.." between zones "..zoneName..front.zones[i-1])
                self:spawnGroupAtPoint(groupName, mist.utils.makeVec3(self:randomPointOnEdge(edge, 0.7)), color, templates[math.random(#templates)], avgHeading)
                table.insert(reserves, groupName)
            end
        end
    end

    return reserves
end
function ControlZones:garrisonZones(zones, color)
    -- on first pass spawn basic template to hold zone,
    local type = garrisonTemplates[color]
    local avgHeading =  mist.utils.getHeadingPoints(self.centroid[color], self.centroid[self:getOpponent(color)])
    for _, zoneName in pairs(zones) do
        -- Static vehicle units are more suited to the limited requirements of garrison forces
        -- but commanded dynamic units don't respond to them by default
        -- self:spawnStaticInZone(zoneName.." garrison", zoneName, color, type, avgHeading)
        self:spawnGroupInZone(zoneName.." garrison", zoneName, color, type, avgHeading)
    end
end

function ControlZones:placeFARPs(color)
    local MIN_FARP_SEPARATION = 9000
    local SETBACK_DISTANCE = 4000

    -- primary: place FARPs in depth 1-2 triangle interiors
    local candidates = {}
    local farpPoints = {}
    local tris = self:selectTrianglesByDepthRange(color, 1, 2)
    for _, tri in pairs(tris) do
        table.insert(candidates, self:randomPointInTriangle(tri))
    end
    -- local farpPoints = self:farthestPointSample(candidates, #candidates, MIN_FARP_SEPARATION)

    -- ensure the side gets at least 1 FARP
    if #candidates == 0 then
        env.info(".......... falling back to alternate FARP placement")
        local heading = mist.utils.getHeadingPoints(self.centroid[self:getOpponent(color)], self.centroid[color])

        -- fallback: offset a point on a depth-1 edge outward past the perimeter
        -- self:edgesAtDepth(color, 1)
        -- self:selectZonesAtDepth(color, 1)
        local pt1 = self:randomPointOnEdgeAtDepth(color, 1)
        local zns = self:selectZonesAtDepth(color, 1)
        if pt1 then
            env.info(".......... edge depth-1")
            local offset1 = mist.projectPoint(pt1, SETBACK_DISTANCE, heading)
            table.insert(farpPoints, offset1)
        elseif #zns then
            env.info(".......... zone depth-1")
            local pt = self:getZone(zns[1]).point
            local offset1 = mist.projectPoint(pt, SETBACK_DISTANCE, heading)
            table.insert(farpPoints, offset1)
        else
            -- self:edgesAtDepth(color, 0)
            local pt0 = self:randomPointOnEdgeAtDepth(color, 0)

            if pt0 then
                env.info(".......... edge depth-0")
                local offset0 = mist.projectPoint(pt0, SETBACK_DISTANCE, heading)
                table.insert(farpPoints, offset0)
            else
                env.info("!! no viable FARP placement found for "..color)
            end
        end
    else
        farpPoints = self:farthestPointSample(candidates, #candidates, MIN_FARP_SEPARATION)
    end

    env.info(".......... "..#candidates.." potential FARP placement points found, narrowed down to "..#farpPoints)
    for _, pt in pairs(farpPoints) do
        self:spawnFARP(color, pt)
    end
end

function ControlZones:kickoff()
    local zoneInfo = {}
    for name, color in pairs(self.owner) do
        zoneInfo[name] = {color = color, point = self:getZone(name).point}
    end
    self.map:drawZones(zoneInfo)
    self.map:drawEdges(self:getAllEdges())
    for color, cmd in pairs(self.commanders) do
        self:garrisonZones(self:getCluster(color), color)

        local fronts = self:getOrderedFrontlines(color)
        self:calculateDepthMap(color)

        self:placeFARPs(color)

        -- draw frontlines
        for i, front in pairs(fronts) do
            self.map:drawFrontline(front.points, color, false, front.isLoop)

            local reserves = self:spawnFrontlineForces(front, color)
            cmd:addReserves(reserves)
        end
    end

end

return ControlZones
