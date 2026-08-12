-- DefensivePosturePlan: Stand-your-ground autonomous behavior
--
-- For units without orders:
-- - Hold position and defend
-- - Retreat if overwhelmed
-- - Advance only with strong favorability
-- - No pursuit beyond local area
--
-- This is a conservative defensive strategy for units not actively committed to objectives.

local constants = require("constants")
local acceptableLevelsOfRisk = constants.acceptableLevelsOfRisk

local ForceStatusAnalyzer = require("force-status-analyzer")
local Doctrine = require("doctrine")
local SpatialAgent = require("spatial-agent")

local dispositionTypes = constants.dispositionTypes

local DefensiveDoctrine = {}
setmetatable(DefensiveDoctrine, {__index = Doctrine})
DefensiveDoctrine.__index = DefensiveDoctrine

local alrThreshold = {
    [acceptableLevelsOfRisk.LOW] = {
        advance = 1.0,
        hold = 0.5,
        retreat = 0.3,
    },
    [acceptableLevelsOfRisk.MEDIUM] = {
        advance = 0.8,
        hold = 0.6,
        retreat = 0.5,
    },
    [acceptableLevelsOfRisk.HIGH] = {
        advance = 0.6,
        hold = 0.9,
        retreat = 0.7,
    }
}

function DefensiveDoctrine.new(commanderName)
    local self = Doctrine.new("Defensive", commanderName)
    setmetatable(self, DefensiveDoctrine)
    self.basePosition = nil

    self:registerPhase("Position", DefensiveDoctrine.positionPhase)
    self:registerPhase("Hold", DefensiveDoctrine.holdPhase)
    self:registerPhase("Retreat", DefensiveDoctrine.retreatPhase)
    self:registerPhase("Advance", DefensiveDoctrine.advancePhase)

    return self
end

function DefensiveDoctrine:considerRetreat(context)
    local threat = context.threatAssessment
    local status = context.statusReport
    local totalUnits = context.totalUnits

    local retreatAssessment = 0.0

    local ownPosition = context.ownPosition
    if not self.basePosition then
        self.basePosition = context.ownPosition
    end
    local basePosition = context.orderPosition or self.basePosition
    local excursion = SpatialAgent.distance2D(basePosition, ownPosition)
    local defenseRadius = context.defenseRadius or 4000

    -- as distance from base approaches max allowed, increase retreat pressure
    if self.currentPhaseName == "Advance" then
        retreatAssessment = retreatAssessment + excursion / defenseRadius
    end

    -- ammunition
    if ForceStatusAnalyzer.isAmmoCritical(status.ammoCount, context.initialAmmoCount) then
        retreatAssessment = retreatAssessment + 1.0
    elseif ForceStatusAnalyzer.isAmmoLow(status.ammoCount, context.initialAmmoCount) then
        retreatAssessment = retreatAssessment + 0.5
    end

    -- attrition rate
    local attritionRate = ForceStatusAnalyzer.calculateAttritionRate(status.aliveCount, totalUnits)
    retreatAssessment = retreatAssessment + attritionRate

    -- threat favorability
    if threat.count > 0 then
        if threat.favorability < 1.0 then
            retreatAssessment = retreatAssessment + (1 - threat.favorability) * 2
        else
            retreatAssessment = retreatAssessment - (1 / threat.favorability)
        end
    end

    -- range advantage: outranging the threat reduces retreat pressure,
    -- being outranged increases it (see EngagementAnalyzer.assessRange)
    if threat.range then
        retreatAssessment = retreatAssessment - threat.range.advantageRatio
    end

    -- suitability: if group no longer meets missionProfile, increase retreat pressure
    local suitability = context.suitability
    if suitability and suitability < 0.3 then
        retreatAssessment = retreatAssessment + (0.3 - suitability) * 2
    end

    return retreatAssessment
end

function DefensiveDoctrine:considerAdvance(context)
    local threat = context.threatAssessment
    local status = context.statusReport

    local advanceAssessment = 0.0

    local ownPosition = context.ownPosition
    if not self.basePosition then
        self.basePosition = context.ownPosition
    end
    local basePosition = context.orderPosition or self.basePosition
    local excursion = SpatialAgent.distance2D(basePosition, ownPosition)
    local defenseRadius = context.defenseRadius or 4000

    -- decrease advance likelihood as group gets farther from base position
    if self.currentPhaseName == "Advance" then
        advanceAssessment = advanceAssessment - excursion / defenseRadius
    end

    -- threat favorability
    if threat.count > 0 then
        advanceAssessment = advanceAssessment + threat.favorability / 2
    end

    -- attrition rate
    local attritionRate = ForceStatusAnalyzer.calculateAttritionRate(status.aliveCount, context.totalUnits)
    advanceAssessment = advanceAssessment - attritionRate

    -- ammunition
    if ForceStatusAnalyzer.isAmmoLow(status.ammoCount, context.initialAmmoCount) then
        advanceAssessment = 0.0
    end

    return advanceAssessment
end

function DefensiveDoctrine:positionPhase(context)
    local alr = context.orderAlr or context.ownAlr
    local threat = context.threatAssessment
    local ownPosition = context.ownPosition
    local distanceToDestination = SpatialAgent.distance2D(ownPosition, context.orderPosition or self.basePosition)

    local holdThreshold = alrThreshold[alr].hold
    local retreatThreshold = alrThreshold[alr].retreat
    local retreatAssessment = self:considerRetreat(context)
    local advanceAssessment = self:considerAdvance(context)

    if threat.count > 0 then
        if retreatAssessment >= retreatThreshold then
            self:changePhase("Retreat")
        elseif retreatAssessment >= holdThreshold then
            self:changePhase("Hold")
        end
    end

    if distanceToDestination <= 500 then
        self:changePhase("Hold")
    end

    return {
        disposition = dispositionTypes.ADVANCE,
        destination = context.orderPosition or self.basePosition
    }
end

function DefensiveDoctrine:holdPhase(context)
    local alr = context.orderAlr or context.ownAlr
    local retreatThreshold = alrThreshold[alr].retreat
    local advanceThreshold = alrThreshold[alr].advance

    local retreatAssessment = self:considerRetreat(context)
    local advanceAssessment = self:considerAdvance(context)

    if retreatAssessment >= retreatThreshold then
        self:changePhase("Retreat")
    elseif advanceAssessment >= advanceThreshold then
        self:changePhase("Advance")
    end

    return {
        disposition = dispositionTypes.HOLD,
        destination = nil
    }
end

function DefensiveDoctrine:retreatPhase(context)
    local threat = context.threatAssessment
    local ownPosition = context.ownPosition

    -- Use directly observed threats if available (more stable)
    local retreatDest = nil

    -- TODO reconsider retreat if threat favorability improves, not just if threat disappears
    -- TODO consider aborting doctrine if already retreated and threat is still highly unfavorable
    if threat.center then
        local direction = SpatialAgent.calculateDirection(threat.center, ownPosition)
        retreatDest = SpatialAgent.calculateDestination(ownPosition, direction, 1000)
    else
        self:changePhase("Hold")
    end

    return {
        disposition = dispositionTypes.RETREAT,
        destination = retreatDest
    }
end

function DefensiveDoctrine:advancePhase(context)
    local alr = context.orderAlr or context.ownAlr
    local threat = context.threatAssessment
    local ownPosition = context.ownPosition

    local holdThreshold = alrThreshold[alr].hold
    local retreatThreshold = alrThreshold[alr].retreat
    local retreatAssessment = self:considerRetreat(context)
    local standoffDistance = (threat.range and threat.range.standoffDistance) or 500

    -- Use directly observed threats if available (more stable)
    local advanceDest = nil

    if retreatAssessment >= retreatThreshold then
        self:changePhase("Retreat")
    elseif retreatAssessment >= holdThreshold or not threat.center then
        self:changePhase("Hold")
    else
        local threatDistance = SpatialAgent.distance2D(ownPosition, threat.center)
        local direction = SpatialAgent.calculateDirection(ownPosition, threat.center)
        advanceDest = SpatialAgent.calculateDestination(ownPosition, direction, threatDistance - standoffDistance)
    end

    return {
        disposition = dispositionTypes.ADVANCE,
        destination = advanceDest
    }
end


return DefensiveDoctrine
