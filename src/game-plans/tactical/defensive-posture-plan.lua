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
local GamePlan = require("game-plan")

local dispositionTypes = constants.dispositionTypes

local DefensivePosturePlan = {}
setmetatable(DefensivePosturePlan, {__index = GamePlan})
DefensivePosturePlan.__index = DefensivePosturePlan

function DefensivePosturePlan.new()
    local self = GamePlan.new({
        name = "DefensivePosture",
        description = "Autonomous stand-your-ground behavior: hold position, retreat if overwhelmed, advance only when favorable"
    })
    setmetatable(self, DefensivePosturePlan)
    
    return self
end

-- Main planning method
-- Returns: {disposition = "RETREAT/HOLD/ADVANCE", destination = point or nil}
function DefensivePosturePlan:plan(context)
    -- Validate context
    if not context.situation or not context.commander then
        env.info("ERROR: DefensivePosturePlan - invalid context")
        return {disposition = dispositionTypes.HOLD, destination = nil}
    end
    
    local situation = context.situation
    local commander = context.commander
    
    -- Check for critical status conditions that override normal decisions
    local alerts = commander:getCriticalStatus(situation)
    
    -- Make autonomous defensive decisions
    return self:makeDefensiveDecision(situation, commander, alerts)
end

-- Calculate retreat destination away from threats
function DefensivePosturePlan:calculateRetreatDestination(situation, commander)
    local threat = situation.threatAssessment
    
    -- Use directly observed threats if available (more stable)
    local observedThreatCenter = commander:calculateThreatCenter(true)
    if observedThreatCenter then
        return commander:calculateDestinationRelativeToThreats(observedThreatCenter, true)
    elseif threat.center then
        return commander:calculateDestinationRelativeToThreats(threat.center, true)
    else
        return commander:calculateReturnToObjective()
    end
end

-- Make defensive decision based on threat assessment
function DefensivePosturePlan:makeDefensiveDecision(situation, commander, alerts)
    local threat = situation.threatAssessment
    local status = situation.statusReport

    -- Check for active threats (observed or suspected, not just memory)
    local activeThreats = 0
    if threat.statuses then
        activeThreats = (threat.statuses.observed or 0) + (threat.statuses.suspected or 0)
    end
    
    -- Unarmed units: retreat if threatened, hold otherwise
    if status.ammoCount == 0 or alerts then
        if activeThreats > 0 and threat.center then
            if threat.favorability < 0.8 then
                env.info(commander.groupName .. " DEFENSIVE: RETREAT (unarmed, threatened)")
                local retreatDest = self:calculateRetreatDestination(situation, commander)
                return {
                    disposition = dispositionTypes.RETREAT,
                    destination = retreatDest
                }
            else
                commander:stopMovement()
                return {disposition = dispositionTypes.HOLD, destination = nil }
            end
        else
            commander:stopMovement()
            return {disposition = dispositionTypes.HOLD, destination = nil }
        end
    end
    
    -- Calculate thresholds with attrition penalties
    local totalUnits = #commander.initialUnitNames
    local attritionRate = ForceStatusAnalyzer.calculateAttritionRate(status.aliveCount, totalUnits)
    local retreatThreshold = 0.6
    local advanceThreshold = 1.5
    
    -- Heavy casualties prevent advancing
    if attritionRate > 0.4 then
        advanceThreshold = 999
    end
    
    -- Hysteresis based on current disposition (prevents oscillation)
    local hysteresis = 0.15
    if commander.disposition == dispositionTypes.RETREAT then
        retreatThreshold = retreatThreshold + hysteresis
    elseif commander.disposition == dispositionTypes.ADVANCE then
        advanceThreshold = advanceThreshold - hysteresis
    end
    
    -- No threats: hold position
    if threat.count == 0 or not threat.center then
        env.info(commander.groupName .. " DEFENSIVE: HOLD (no threats)")
        return {disposition = dispositionTypes.HOLD, destination = nil}
    end
    
    -- Stale threats: hold or maintain course
    if threat.stale then
        if threat.hasRecentIntel then
            -- Maintain current disposition for temporary intel gaps
            return nil
        else
            env.info(commander.groupName .. " DEFENSIVE: HOLD (stale threats)")
            commander:stopMovement()
            return {disposition = dispositionTypes.HOLD, destination = nil}
        end
    end
    
    -- Retreating with no direct LOS: check if contact broken
    if commander.disposition == dispositionTypes.RETREAT and commander.directLOSCount == 0 then
        if threat.statuses and threat.statuses.observed == 0 and threat.statuses.suspected == 0 then
            env.info(commander.groupName .. " DEFENSIVE: HOLD (contact broken)")
            commander:stopMovement()
            return {disposition = dispositionTypes.HOLD, destination = nil}
        end
    end
    
    -- Weak position: retreat
    if activeThreats > 0 and threat.favorability < retreatThreshold then
        env.info(commander.groupName .. " DEFENSIVE: RETREAT (Fav:" .. 
                 string.format("%.2f", threat.favorability) .. ")")
        
        local retreatDest = self:calculateRetreatDestination(situation, commander)
        return {
            disposition = dispositionTypes.RETREAT,
            destination = retreatDest
        }
    end
    
    -- Strong position: advance
    if activeThreats > 0 and threat.favorability >= advanceThreshold then
        env.info(commander.groupName .. " DEFENSIVE: ADVANCE (Fav:" .. 
                 string.format("%.2f", threat.favorability) .. ")")
        
        local advanceDest = commander:calculateDestinationRelativeToThreats(threat.center, false)
        return {
            disposition = dispositionTypes.ADVANCE,
            destination = advanceDest
        }
    end
    
    -- Moderate position: hold
    env.info(commander.groupName .. " DEFENSIVE: HOLD (moderate, Fav:" .. 
             string.format("%.2f", threat.favorability) .. ")")
    commander:stopMovement()
    return {disposition = dispositionTypes.HOLD, destination = nil}
end

return DefensivePosturePlan
