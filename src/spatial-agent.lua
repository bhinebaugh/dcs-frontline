-- SpatialAgent: DCS-aware geometry and spatial calculations
-- Provides consistent, tested spatial operations for commanders
-- (Yes, it's a pun on "Special Agent" 🕵️)

local SpatialAgent = {}

-- ============================================================================
-- DISTANCE CALCULATIONS
-- ============================================================================

--- Calculate 2D distance between two positions
-- Handles DCS position formats (with or without .p property)
-- @param pos1 Position table {x, y, z} or {p = {x, y, z}}
-- @param pos2 Position table {x, y, z} or {p = {x, y, z}}
-- @return number Distance in meters, or nil if positions invalid
function SpatialAgent.distance2D(pos1, pos2)
    if not pos1 or not pos2 then
        return nil
    end
    
    -- Extract actual position if wrapped in .p
    local p1 = pos1.p or pos1
    local p2 = pos2.p or pos2
    
    if not p1.x or not p1.z or not p2.x or not p2.z then
        return nil
    end
    
    local dx = p1.x - p2.x
    local dz = p1.z - p2.z
    return math.sqrt(dx * dx + dz * dz)
end

--- Calculate squared 2D distance (faster, avoids sqrt)
-- Useful for radius checks: distanceSquared < radius^2
-- @param pos1 Position table
-- @param pos2 Position table
-- @return number Squared distance in meters^2, or nil if positions invalid
function SpatialAgent.distanceSquared(pos1, pos2)
    if not pos1 or not pos2 then
        return nil
    end
    
    local p1 = pos1.p or pos1
    local p2 = pos2.p or pos2
    
    if not p1.x or not p1.z or not p2.x or not p2.z then
        return nil
    end
    
    local dx = p1.x - p2.x
    local dz = p1.z - p2.z
    return dx * dx + dz * dz
end

--- Check if position is within radius of center
-- Optimized: uses squared distance to avoid sqrt
-- @param position Position to check
-- @param center Center position
-- @param radius Radius in meters
-- @return boolean True if within radius, false otherwise
function SpatialAgent.isWithinRadius(position, center, radius)
    local distSq = SpatialAgent.distanceSquared(position, center)
    if not distSq then
        return false
    end
    return distSq <= (radius * radius)
end

-- ============================================================================
-- CENTER OF MASS / AVERAGE POSITION
-- ============================================================================

--- Calculate geometric center (average position) of multiple positions
-- @param positions Array of position tables
-- @return table Center position {x, y, z}, or nil if no valid positions
function SpatialAgent.calculateCenter(positions)
    if not positions or #positions == 0 then
        return nil
    end
    
    local sumX = 0
    local sumY = 0
    local sumZ = 0
    local count = 0
    
    for _, pos in ipairs(positions) do
        local p = pos.p or pos
        if p.x and p.z then
            sumX = sumX + p.x
            sumY = sumY + (p.y or 0)
            sumZ = sumZ + p.z
            count = count + 1
        end
    end
    
    if count == 0 then
        return nil
    end
    
    return {
        x = sumX / count,
        y = sumY / count,
        z = sumZ / count
    }
end

--- Calculate center from a table of objects with .position fields
-- Works with any objects that have a .position property (threats, allies, units, etc.)
-- @param objects Table of objects where each has a .position field
-- @return table Center position {x, y, z}, or nil if no valid positions
function SpatialAgent.calculateCenterOfObjects(objects)
    if not objects then
        return nil
    end
    
    local positions = {}
    for _, obj in pairs(objects) do
        if obj.position then
            table.insert(positions, obj.position)
        end
    end
    
    return SpatialAgent.calculateCenter(positions)
end

--- Calculate center of threat positions (convenience wrapper)
-- @param threats Table of threats where each has a .position field
-- @return table Center position {x, y, z}, or nil if no threats
function SpatialAgent.calculateThreatCenter(threats)
    return SpatialAgent.calculateCenterOfObjects(threats)
end

-- ============================================================================
-- VECTOR OPERATIONS
-- ============================================================================

--- Normalize a 2D direction vector
-- @param dx X component
-- @param dz Z component
-- @return number, number Normalized dx, dz, or 0,0 if zero-length
function SpatialAgent.normalizeVector(vector)
    local magnitude = math.sqrt(vector.x * vector.x + vector.z * vector.z)
    
    if magnitude < 0.001 then  -- Near-zero length
        return {x = 0, z = 0}
    end
    
    return {x = vector.x / magnitude, z = vector.z / magnitude}
end

--- Rotate a 2D vector by angle
-- @param dx X component
-- @param dz Z component  
-- @param angleRadians Rotation angle in radians (positive = counterclockwise)
-- @return vector Rotated vector {x, z}
function SpatialAgent.rotateVector(vector, angleDegrees)
    local angleRadians = math.rad(angleDegrees)
    local cosAngle = math.cos(angleRadians)
    local sinAngle = math.sin(angleRadians)
    
    local rotatedX = vector.x * cosAngle - vector.z * sinAngle
    local rotatedZ = vector.x * sinAngle + vector.z * cosAngle
    
    return {x = rotatedX, z = rotatedZ}
end

--- Calculate direction vector from one position to another
-- @param fromPos Starting position
-- @param toPos Target position
-- @return direction Normalized direction vector {x, z}, or ZERO if positions identical
function SpatialAgent.calculateDirection(fromPos, toPos)
    local dist = SpatialAgent.distance2D(fromPos, toPos)
    if not dist or dist < 0.001 then
        return {x = 0, z = 0}
    end
    
    local p1 = fromPos.p or fromPos
    local p2 = toPos.p or toPos
    
    local dx = p2.x - p1.x
    local dz = p2.z - p1.z
    
    return SpatialAgent.normalizeVector({x = dx, z = dz})
end

-- ============================================================================
-- TACTICAL POSITIONING
-- ============================================================================

--- Calculate destination point from origin in a direction
-- @param origin Starting position {x, y, z}
-- @param direction Normalized direction {x, z}
-- @param distance Distance to travel in meters
-- @return table Destination position {x, y, z}
function SpatialAgent.calculateDestination(origin, direction, distance)
    if not origin then
        return nil
    end
    
    local p = origin.p or origin
    
    return {
        x = p.x + (direction.x * distance),
        y = p.y or 0,
        z = p.z + (direction.z * distance)
    }
end

--- Calculate multiple staging positions around a center point
-- Positions are spread in an arc or circle for tactical deployment
-- @param center Center position {x, y, z}
-- @param radius Distance from center in meters
-- @param count Number of positions to generate
-- @param spreadAngleDegrees Arc width in degrees (360 = full circle, 120 = front arc)
-- @return table Array of positions
function SpatialAgent.calculateStagingPositions(center, radius, count, spreadAngleDegrees)
    if not center or count < 1 then
        return {}
    end
    
    local p = center.p or center
    local positions = {}
    
    -- Default to full circle if not specified
    local spreadRadians = math.rad(spreadAngleDegrees or 360)
    
    if count == 1 then
        -- Single position: place directly at radius
        table.insert(positions, {
            x = p.x + radius,
            y = p.y or 0,
            z = p.z
        })
        return positions
    end
    
    -- Multiple positions: spread evenly across arc
    local angleStep = spreadRadians / (count - 1)
    local startAngle = -spreadRadians / 2  -- Center the arc
    
    for i = 0, count - 1 do
        local angle = startAngle + (angleStep * i)
        table.insert(positions, {
            x = p.x + math.cos(angle) * radius,
            y = p.y or 0,
            z = p.z + math.sin(angle) * radius
        })
    end
    
    return positions
end

--- Calculate circular positions evenly distributed around a center
-- Simplified version of calculateStagingPositions for full 360° deployment
-- @param center Center position
-- @param radius Distance from center
-- @param count Number of positions
-- @return table Array of positions
function SpatialAgent.calculateCircularPositions(center, radius, count)
    return SpatialAgent.calculateStagingPositions(center, radius, count, 360)
end

--- Calculate staging positions on allied side of threat
-- Creates an arc of positions oriented toward the threat from the allied approach direction
-- @param threatCenter Center of threat cluster
-- @param distance Staging distance from threat center
-- @param commanderPositions Array of commander positions (current locations)
-- @param spreadAngleDegrees Arc spread in degrees (default 120)
-- @return table Array of staging positions rotated to face threat from allied side
function SpatialAgent.calculateAlliedSideStagingPositions(threatCenter, distance, commanderPositions, spreadAngleDegrees)
    local numPositions = #commanderPositions
    
    if numPositions == 0 then
        return {}
    end
    
    -- Calculate centroid of allied positions
    local alliedCenterX = 0
    local alliedCenterZ = 0
    local validCount = 0
    
    for _, pos in ipairs(commanderPositions) do
        if pos then
            alliedCenterX = alliedCenterX + pos.x
            alliedCenterZ = alliedCenterZ + pos.z
            validCount = validCount + 1
        end
    end
    
    if validCount == 0 then
        return {}
    end
    
    alliedCenterX = alliedCenterX / validCount
    alliedCenterZ = alliedCenterZ / validCount
    
    -- Calculate approach angle from allied center to threat center
    local dx = threatCenter.x - alliedCenterX
    local dz = threatCenter.z - alliedCenterZ
    local approachAngle = math.atan2(dz, dx)
    
    -- Flip 180° to get angle for allied side (opposite approach direction)
    local centerAngle = approachAngle + math.pi
    
    -- Generate arc positions centered at 0°
    local arcPositions = SpatialAgent.calculateStagingPositions(
        threatCenter, 
        distance, 
        numPositions, 
        spreadAngleDegrees or 120
    )
    
    -- Rotate positions so arc faces threat from allied side
    local rotatedPositions = {}
    for _, pos in ipairs(arcPositions) do
        -- Calculate relative position from threat center
        local relX = pos.x - threatCenter.x
        local relZ = pos.z - threatCenter.z
        
        -- Rotate by centerAngle
        local rotatedX = relX * math.cos(centerAngle) - relZ * math.sin(centerAngle)
        local rotatedZ = relX * math.sin(centerAngle) + relZ * math.cos(centerAngle)
        
        table.insert(rotatedPositions, {
            x = threatCenter.x + rotatedX,
            y = threatCenter.y or 0,
            z = threatCenter.z + rotatedZ
        })
    end
    
    return rotatedPositions
end

-- ============================================================================
-- SORTING AND GROUPING
-- ============================================================================

--- Sort positions by distance from a reference point
-- @param positions Array of position tables
-- @param referencePoint Reference position to measure from
-- @return table Sorted array of {position, distance} tables
function SpatialAgent.sortByDistance(positions, referencePoint)
    if not positions or not referencePoint then
        return {}
    end
    
    local positionsWithDistance = {}
    
    for _, pos in ipairs(positions) do
        local dist = SpatialAgent.distance2D(pos, referencePoint)
        if dist then
            table.insert(positionsWithDistance, {
                position = pos,
                distance = dist
            })
        end
    end
    
    table.sort(positionsWithDistance, function(a, b)
        return a.distance < b.distance
    end)
    
    return positionsWithDistance
end

return SpatialAgent
