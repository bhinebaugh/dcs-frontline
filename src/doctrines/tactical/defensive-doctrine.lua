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
local ForceStatusAnalyzer = require("force-status-analyzer")
local Doctrine = require("doctrine")
local SpatialAgent = require("spatial-agent")

local dispositionTypes = constants.dispositionTypes

local DefensiveDoctrine = {}
setmetatable(DefensiveDoctrine, {__index = Doctrine})
DefensiveDoctrine.__index = DefensiveDoctrine

function DefensiveDoctrine.new(commanderName)
    local self = Doctrine.new("Defensive", commanderName)
    setmetatable(self, DefensiveDoctrine)

    self:registerPhase("Hold", DefensiveDoctrine.holdPhase)
    self:registerPhase("Retreat", DefensiveDoctrine.retreatPhase)
    self:registerPhase("Advance", DefensiveDoctrine.advancePhase)
    
    return self
end

function DefensiveDoctrine:considerRetreat(context)
    local commander = context.commander
    local situation = context.situation
    local threat = situation.threatAssessment
    local status = situation.statusReport
    local totalUnits = #commander.initialUnitNames

    local retreatAssessment = 0.0

    -- ammunition
    if ForceStatusAnalyzer.isAmmoCritical(status.ammoCount, commander.initialAmmoCount) then
        retreatAssessment = retreatAssessment + 1.0
    elseif ForceStatusAnalyzer.isAmmoLow(status.ammoCount, commander.initialAmmoCount) then
        retreatAssessment = retreatAssessment + 0.5
    end

    -- attrition rate
    local attritionRate = ForceStatusAnalyzer.calculateAttritionRate(status.aliveCount, totalUnits)
    retreatAssessment = retreatAssessment + attritionRate

    -- threat favorability
    if threat.count > 0 and threat.favorability < 1.0 then
        retreatAssessment = retreatAssessment + (1 - threat.favorability)
    else
        retreatAssessment = retreatAssessment - (1 / threat.favorability)
    end

    -- suitability: if group no longer meets missionProfile, increase retreat pressure
    local suitability = context.situation.suitability
    if suitability and suitability < 0.3 then
        retreatAssessment = retreatAssessment + (0.3 - suitability) * 2
    end

    return retreatAssessment
end

function DefensiveDoctrine:considerAdvance(context)
    local commander = context.commander
    local situation = context.situation
    local threat = situation.threatAssessment
    local status = situation.statusReport
    local totalUnits = #commander.initialUnitNames

    local advanceAssessment = 0.0

    -- threat favorability
    if threat.count > 0 then
        if threat.favorability < 1.0 then
            advanceAssessment = advanceAssessment + threat.favorability
        else
            advanceAssessment = advanceAssessment + threat.favorability / 2
        end
    end

    -- attrition rate
    local attritionRate = ForceStatusAnalyzer.calculateAttritionRate(status.aliveCount, totalUnits)
    advanceAssessment = advanceAssessment - attritionRate

    -- ammunition
    if ForceStatusAnalyzer.isAmmoLow(status.ammoCount, commander.initialAmmoCount) then
        advanceAssessment = 0.0
    end
    
    return advanceAssessment
end

function DefensiveDoctrine:holdPhase(context)
    local retreatThreshold = 1.0
    local advanceThreshold = 0.7

    if self:considerRetreat(context) >= retreatThreshold then
        self:changePhase("Retreat")
    elseif self:considerAdvance(context) >= advanceThreshold then
        self:changePhase("Advance")
    end

    return {disposition = dispositionTypes.HOLD, destination = nil}
end

function DefensiveDoctrine:retreatPhase(context)
    local commander = context.commander
    local situation = context.situation

    local threat = situation.threatAssessment
    local ownPosition = commander:getOwnPosition()

    -- Use directly observed threats if available (more stable)
    local retreatDest = nil

    if threat.center then
        local direction = SpatialAgent.calculateDirection(threat.center, ownPosition)
        retreatDest = SpatialAgent.calculateDestination(threat.center, direction, 1000)
    else
        self:changePhase("Hold")
    end

    return {
        disposition = dispositionTypes.RETREAT,
        destination = retreatDest
    }
end

function DefensiveDoctrine:advancePhase(context)
    local commander = context.commander
    local situation = context.situation

    local threat = situation.threatAssessment
    local ownPosition = commander:getOwnPosition()

    local holdThreshold = 0.5
    local retreatThreshold = 0.3
    local retreatAssessment = self:considerRetreat(context)
    local standoffDistance = 500

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
