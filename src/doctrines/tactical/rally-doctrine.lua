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
local ForceStatusAnalyzer = require("force-status-analyzer")
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

function RallyDoctrine:considerAbort(context)
    local threat = context.threatAssessment
    local status = context.statusReport
    local totalUnits = context.totalUnits

    local retreatAssessment = 0.0

    -- ammunition
    if ForceStatusAnalyzer.isAmmoCritical(status.ammoCount, context.initialAmmoCount) then
        retreatAssessment = retreatAssessment + 1.0
    elseif ForceStatusAnalyzer.isAmmoLow(status.ammoCount, context.initialAmmoCount) then
        retreatAssessment = retreatAssessment + 0.5
    end

    -- health: a group that hasn't lost a unit can still be battered close to
    -- death (attritionRate below wouldn't catch this - see getStatusReport's
    -- healthRatio)
    if ForceStatusAnalyzer.isHealthCritical(status.healthRatio) then
        retreatAssessment = retreatAssessment + 1.0
    elseif ForceStatusAnalyzer.isHealthLow(status.healthRatio) then
        retreatAssessment = retreatAssessment + 0.5
    end

    -- fuel
    if ForceStatusAnalyzer.isFuelCritical(status.fuelRemaining) then
        retreatAssessment = retreatAssessment + 1.0
    elseif ForceStatusAnalyzer.isFuelLow(status.fuelRemaining) then
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

    -- suitability: if group no longer meets missionProfile, increase abort pressure
    local suitability = context.suitability
    if suitability and suitability < 0.3 then
        retreatAssessment = retreatAssessment + (0.3 - suitability) * 2
    end

    return retreatAssessment
end

-- Fallback destination if a known threat's weapon range currently reaches
-- us, or nil if we're already outside it (see SpatialAgent.fallbackDestination).
function RallyDoctrine:considerFallback(context)
    local threat = context.threatAssessment
    local safeDistance = threat.range and threat.range.theirReach
    if not safeDistance or not threat.center then
        return nil
    end
    return SpatialAgent.fallbackDestination(context.ownPosition, threat.center, safeDistance)
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
        }
    end

    -- Falling back out of a threat's weapon range takes priority over
    -- continuing toward the staging position - a mass-up point isn't safe
    -- if reaching it means walking through someone's engagement envelope.
    -- Doesn't abort the order; once safe, rallying resumes on its own.
    local fallback = self:considerFallback(context)
    if fallback then
        return {
            disposition = dispositionTypes.RETREAT,
            destination = fallback,
            orderAction = "start",
        }
    end

    local distanceToStaging = SpatialAgent.distance2D(ownPosition, stagingPosition)
    if distanceToStaging <= proximity then
        self:changePhase("Hold")
        return {
            disposition = dispositionTypes.HOLD,
            destination = nil,
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
        }
    end

    local fallback = self:considerFallback(context)
    if fallback then
        return {
            disposition = dispositionTypes.RETREAT,
            destination = fallback,
        }
    end

    -- Genuinely arrived and stable (not aborting, not falling back out of
    -- range) - this is Hold's real first shot at running at all (see
    -- GroupCommander:decide/abortPhase's comment on why), so it's the right
    -- moment to actually declare the order complete rather than the
    -- advance-arrival trigger doing it prematurely, one cycle before this
    -- phase ever got to run.
    return {
        disposition = dispositionTypes.HOLD,
        destination = nil,
        orderAction = "complete",
    }
end

-- Abort's one real shot to act(): the trigger that got us here (considerAbort
-- tripping in Advance or Hold) deliberately only transitioned phase without
-- setting orderAction, so this handler - not the trigger - is what actually
-- retreats and declares the order aborted. Only after this runs does the
-- order become finished and GroupCommander:decide() hand off to
-- DefensiveDoctrine for continued self-preservation (see its comment).
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
