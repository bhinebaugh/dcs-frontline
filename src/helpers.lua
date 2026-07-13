local function isCounterClockwise(p1, p2, p3)
    -- swapped to account for DCS coordinate weirdness
    return (p2.y - p1.y) * (p3.x - p1.x) - (p2.x - p1.x) * (p3.y - p1.y) > 0
    -- standard (x,y) as (N/S,E/W) version:
    -- return (p2.x - p1.x) * (p3.y - p1.y) - (p2.y - p1.y) * (p3.x - p1.x) > 0
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

return {
    isCounterClockwise = isCounterClockwise,
    normalizeAngle = normalizeAngle,
    angularDistance = angularDistance
}
