local rgb = require("constants").rgb
local isCounterClockwise = require("helpers").isCounterClockwise --Load helper functions

local ControlZones = {}
ControlZones.__index = ControlZones

function ControlZones.new(namedZones, groundTemplates)
    local self = setmetatable({}, ControlZones)
    if not namedZones then
        self.allZones = {}      --array of names of zones
        self.zonesByName = {}   --full zone details indexed by zone name
        self.owner = {}
        self.neighbors = {}
        self.front = {
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
    self.markerCounter = 9990
    self.frontlineMarkers = {blue = {}, red = {}} --should really be connected to :addCommander
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
    self.groupOfUnit = {}
    self.groundGroups = {}
    self.groupsByZone = {}
    self.centroid = {}
    return self
end

function ControlZones:addCommander(side, c)
    self.commanders[side] = c
end

function ControlZones:setup(options)
    options = options or {}

    for zonename, zoneobj in pairs(mist.DBs.zonesByName) do
        if string.sub(zonename,1,7) == 'control' then
            -- add an 'owner' property to zones
            -- zoneobj.owner = 0
            self.zonesByName[zonename] = zoneobj --indexed by name of the trigger zone
            table.insert(self.allZones, zoneobj.name) --list of all zone names / names of all zones
            -- trigger.action.circleToAll(-1, 5000+zoneobj.zoneId, zoneobj.point, 500, {0.5,0.5,0.5,0.8}, {0.6,0.6,0.6,0.5}, 1)
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

    local blueZones = self:getCluster("blue")
    local redZones = self:getCluster("red")

    --find centroid (averaged point, center of mass) of opponent's cluster
    --for now this will be used as the axis along which frontlines will be offset
    for color, zoneCluster in pairs({ blue = blueZones, red = redZones }) do
        local sumX = 0
        local sumY = 0
        for _, id in pairs(zoneCluster) do
            sumX = sumX + self.zonesByName[id].x
            sumY = sumY + self.zonesByName[id].y
        end
        self.centroid[color] = { x = sumX / #zoneCluster, y = sumY / #zoneCluster }
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

function ControlZones:getGroupsInZone(zoneName)
    return self.groupsByZone[zoneName]
end

function ControlZones:changeZoneOwner(name, newOwner)
    local formerOwner = self.owner[name]
    if newOwner == formerOwner then
        env.info("Notice: zone not changed, "..newOwner.." already controls "..name)
        return false
    end
    self.owner[name] = newOwner
    env.info("Control change: "..name.." switched from "..formerOwner.." to "..newOwner)

    --redraw map zone and borders as needed
    trigger.action.setMarkupColorFill(self:getZone(name).zoneId, rgb[newOwner])
    if formerOwner ~= "neutral" then
        self:drawFrontline(formerOwner)
    end
    if newOwner ~= "neutral" then
        self:drawFrontline(newOwner)
    end
end

function ControlZones:checkOwnership(time)
    -- if owner units not in a color zone, lose control 
    -- if units in a neutral zone, gain control 
    -- if both colors in zone, no change
    env.info("checking zone control......")
    for zoneName, _ in pairs(self.zonesByName) do
        self:updateZoneOwner(zoneName)
    end
    return time + 30
end

function ControlZones:updateZoneOwner(zoneName)
    env.info("checking ownership of "..zoneName)
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
            local opponentColor = ownerColor == "blue" and "red" or "blue"
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

function ControlZones:getNeighbors(key, color)
    local color = color or nil
    if not color then
        return self.neighbors[key] or {}
    end
    local different = {}
    for _, n in ipairs(self.neighbors[key]) do
        if self.owner[n] == color then
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

-- Get perimeter edges facing another color
function ControlZones:getPerimeterZones(color)
    if not self.triangles then
        self:buildDelaunayIndex()
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

function ControlZones:getPerimeterEdges(color)
    if not self.triangles then
        self:buildDelaunayIndex()
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
                    table.insert(edges, {p1 = key1, p2 = key2})
                end
            end
        end
    end
    
    return edges
end

function ControlZones:getAllEdges()
    if not self.triangles then
        self:buildDelaunayIndex()
    end

    local edges = {}
    local edgeSet = {}  -- to avoid duplicates

    --examine each triangle
    for l, tri in ipairs(self.triangles) do
        -- Check each edge of the triangle
        local triPairs = {
            {1, 2},
            {2, 3},
            {3, 1}
        }
        for m, pair in ipairs(triPairs) do
            local v1, v2 = pair[1], pair[2]
            local key1, key2 = tri[v1], tri[v2]
            local edgeKey = key1 < key2 and (key1 .. "-" .. key2) or (key2 .. "-" .. key1)
            
            if not edgeSet[edgeKey] then
                edgeSet[edgeKey] = true
                table.insert(edges, {p1 = key1, p2 = key2})
            end
        end
    end

    return edges
end

function ControlZones:drawEdges()
    for m, edge in pairs(self:getAllEdges()) do
        --draw edge 
        trigger.action.lineToAll(-1, 2000+m, self:getZone(edge.p1).point, self:getZone(edge.p2).point, {1,1,0.2,0.1}, 5)
    end
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

function ControlZones:getNewGroupId()
    self.groupCounter = self.groupCounter + 1
    return self.groupCounter
end

function ControlZones:getNewMarker()
    self.markerCounter = self.markerCounter + 1
    return self.markerCounter
end

function ControlZones:drawFrontline(color)
    self.front[color] = self:getPerimeterEdges(color)
    --first erase any existing lines
    if self.frontlineMarkers[color] then
        for _, id in pairs(self.frontlineMarkers[color]) do
            trigger.action.removeMark(id)
        end
        self.frontlineMarkers[color] = {}
    end
    --then draw a line for each edge of the current color's front
    for _, zonePoints in pairs(self.front[color]) do
        local lineId = self:getNewMarker()
        table.insert(self.frontlineMarkers[color], lineId)
        local lineColor = rgb[color]
        local heading
        local z1, z2 = self:getZone(zonePoints.p1), self:getZone(zonePoints.p2)
        if color == "blue" then
            heading = mist.utils.getHeadingPoints(self.centroid["blue"], self.centroid["red"])
        else
            heading = mist.utils.getHeadingPoints(self.centroid["red"], self.centroid["blue"])
        end
        local p1A, p1B = mist.projectPoint(z1.point, 2000, heading), mist.projectPoint(z1.point, 2200, heading)
        local p2A, p2B = mist.projectPoint(z2.point, 2000, heading), mist.projectPoint(z2.point, 2200, heading)
        trigger.action.lineToAll(-1, lineId, p1A, p2A, lineColor, 1)
        lineId = self:getNewMarker()
        table.insert(self.frontlineMarkers[color], lineId)
        trigger.action.lineToAll(-1, lineId, p1B, p2B, lineColor, 1) --double the line for better visibility
    end
end

function ControlZones:drawDirective(fromZone, toZone)
    local side = -1 --which coalition the arrow is visible to
    local nextId = self:getNewMarker()
    local color = {1,1,0.2,1}
    local fill = color
    local originPoint = self:getZone(fromZone).point
    local targetPoint = self:getZone(toZone).point
    local heading = mist.utils.getHeadingPoints(originPoint, targetPoint)
    local reciprocal = mist.utils.getHeadingPoints(targetPoint, originPoint)
    local distance = 1000
    local lineStart = mist.projectPoint(originPoint, distance, heading)
    local arrowEnd = mist.projectPoint(targetPoint, distance, reciprocal)
    trigger.action.arrowToAll(side, nextId, arrowEnd, lineStart, color, fill, 1)
    return true
end

function ControlZones:spawnGroupInZone(groupName, zoneName, color, template)
    local zn = self:getZone(zoneName)
    local unitSet = {}
    local xoff = math.random(-40, 40)
    local yoff = math.random(-40, 40)
    for j, unitName in pairs(template) do
        table.insert(unitSet, j, { type = unitName, x = zn.x + xoff, y = zn.y + yoff})
        xoff = xoff + math.random(-22, 22)
        yoff = yoff + math.random(-22, 22)
    end
    local newGroup = mist.dynAdd({ -- mist.dynAddStatic()
        groupName = groupName,
        units = unitSet,
        country = color == "blue" and "USA" or "USSR",
        category = "vehicle",
    })
    for _, unit in pairs(Group.getByName(groupName):getUnits()) do
        local unitName = unit:getName()
        if unitName then self.groupOfUnit[unitName] = newGroup.name end
    end
    self.groundGroups[newGroup.name] = {
        origin = zoneName,
        color = color,
    }
    if not self.groupsByZone[zoneName] then
        self.groupsByZone[zoneName] = { groupName }
    else
        table.insert(self.groupsByZone[zoneName], groupName)
    end
    return groupName
end

function ControlZones:processDeadUnit(unitName)
    env.info("control zone: unit "..unitName.." is dead")
    local grpName = self.groupOfUnit[unitName]
    local grpColor = self.groundGroups[grpName].color
    env.info("    from group "..grpName.." of "..grpColor)
    if mist.groupIsDead(grpName) then --error if player
        env.info("    >>> GROUP LOST all units of "..grpName.." are dead")
        self.commanders[grpColor]:registerGroupLost(grpName)
        local originZone = self.groundGroups[grpName].origin
        self:updateZoneOwner(originZone)
    else
        self.commanders[grpColor]:registerUnitLost(unitName, grpName)
    end
end

function ControlZones:constructTask(params)
    local task = {}
    local pt = params.destination.point

    local route = {
        ["points"] = {
            [1] = {
                type= AI.Task.WaypointType.TURNING_POINT,
                x = pt.x,
                y = pt.z,
                speed = 100,
                action = AI.Task.VehicleFormation.RANK
            },
            [2] = {
                type= AI.Task.WaypointType.TURNING_POINT,
                x = pt.x,
                y = pt.z,
                speed = 100,
                action = AI.Task.VehicleFormation.RANK
            },
        }
    }

    --also mist.ground.buildWP or mist.groupToPoint(groupName, zoneName, ...)
    local taskMove = {
        id = 'Mission',
        params = {
            route = route,
        }
    }

    task = taskMove
    return task
end

function ControlZones:setGroupTask(groupName, task)
    local group = Group.getByName(groupName)
    if not group then
        env.info("Not assigning task: no group "..groupName)
        return false
    end

    group:getController():setTask(task)
    --remove group from self.groupsByZone[]
    return true
end

function ControlZones:populateZones()
    -- on first pass spawn basic template to hold zone,
    -- later reinforce zones prioritized by each commander
    for _, cmd in pairs(self.commanders) do
        --a single group for each zone to start
        local zones = self:getCluster(cmd.color)
        local reinforcements = cmd:chooseZoneReinforcements(zones)
        for zoneName, data in pairs(reinforcements) do
            self:spawnGroupInZone(data.groupName, zoneName, cmd.color, data.template)
        end

        --front zones get an additional group
        local frontlineZones = self:getPerimeterZones(cmd.color)
        reinforcements = cmd:chooseZoneReinforcements(frontlineZones)
        for zoneName, data in pairs(reinforcements) do
            self:spawnGroupInZone(data.groupName, zoneName, cmd.color, data.template)
        end
    end
end

function ControlZones:requestOrders()
    for _, cmd in pairs(self.commanders) do
        local params = cmd:issueOrders()
        if params then
            env.info("    constructing task for "..params.group)
            local task = self:constructTask(params)
            self:setGroupTask(params.group, task)
            self:drawDirective(params.origin.name, params.destination.name)
        end
    end
end

function ControlZones:kickoff()
    self:populateZones()
    timer.scheduleFunction(
        function(params)
            params.context:requestOrders()
            return timer.getTime() + 30
        end,
        {context = self},
        timer.getTime() + 8
    )
end

return ControlZones
