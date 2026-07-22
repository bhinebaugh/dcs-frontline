-- RallyDoctrine: Move to an assigned staging position and hold, without being
-- diverted into engaging threats along the way.
--
-- Rally exists to let a dispersed force mass at a safe distance before a
-- coordinated Assault. Unlike AsOrderedDoctrine (which treats every order as
-- an assault and will chase down standoff engagements), Rally only cares
-- about reaching its assigned point. DCS's own ROE (set to WEAPON_FREE by
-- GroupCommander) already lets units return fire opportunistically along the
-- way - this doctrine just keeps the group on course toward the staging
-- point instead of letting that incidental contact redirect movement.
--
-- Only a serious danger (using the order's own ALR-scaled retreat threshold)
-- will pull a group off task, via Abort.

local constants = require("constants")
local Doctrine = require("doctrine")
local AsOrderedDoctrine = require("doctrines.tactical.as-ordered-doctrine")
local SpatialAgent = require("spatial-agent")

local dispositionTypes = constants.dispositionTypes

local RallyDoctrine = {}
setmetatable(RallyDoctrine, {__index = Doctrine})
RallyDoctrine.__index = RallyDoctrine

function RallyDoctrine.new(commanderName)
    local self = Doctrine.new("Rally", commanderName)
    setmetatable(self, RallyDoctrine)

    self:registerPhase("Advance", RallyDoctrine.advancePhase)
    self:registerPhase("Hold", RallyDoctrine.holdPhase)
    self:registerPhase("Abort", RallyDoctrine.abortPhase)

    return self
end

-- Danger assessment is shared with AsOrderedDoctrine (ammo, attrition, threat
-- favorability, suitability) - it doesn't depend on order type. Only the
-- threshold at which it triggers an abort differs per ALR.
function RallyDoctrine:considerAbort(context)
    return AsOrderedDoctrine.considerAbort(self, context)
end

function RallyDoctrine:advancePhase(context)
    local ownPosition = context.ownPosition
    local stagingPosition = context.orderPosition
    local proximity = context.orderProximity or 500

    local abortThreshold = context.retreatThreshold or 0.4

    if self:considerAbort(context) >= abortThreshold then
        self:changePhase("Abort")
        return {
            disposition = dispositionTypes.HOLD,
            destination = nil,
            orderAction = "abort",
        }
    end

    local distanceToStaging = SpatialAgent.distance2D(ownPosition, stagingPosition)
    if distanceToStaging <= proximity then
        self:changePhase("Hold")
        return {
            disposition = dispositionTypes.HOLD,
            destination = nil,
            orderAction = "complete",
        }
    end

    return {
        disposition = dispositionTypes.ADVANCE,
        destination = stagingPosition,
        orderAction = "start",
    }
end

function RallyDoctrine:holdPhase(context)
    local abortThreshold = context.retreatThreshold or 0.4

    if self:considerAbort(context) >= abortThreshold then
        self:changePhase("Abort")
        return {
            disposition = dispositionTypes.HOLD,
            destination = nil,
            orderAction = "abort",
        }
    end

    return {
        disposition = dispositionTypes.HOLD,
        destination = nil,
    }
end

function RallyDoctrine:abortPhase(context)
    local threat = context.threatAssessment
    local ownPosition = context.ownPosition

    local retreatDest = nil
    if threat.center then
        local direction = SpatialAgent.calculateDirection(threat.center, ownPosition)
        retreatDest = SpatialAgent.calculateDestination(ownPosition, direction, 1000)
    end

    return {
        disposition = dispositionTypes.RETREAT,
        destination = retreatDest,
        orderAction = "abort",
    }
end

return RallyDoctrine
