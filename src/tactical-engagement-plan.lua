-- TacticalEngagementPlan: Default threat-response behavior for ground units
--
-- Decision logic:
-- 1. Critical status (casualties/ammo) → Force retreat/hold
-- 2. Following orders → Execute order mission with threat awareness
-- 3. Autonomous → Engage/retreat/hold based on force comparison
--
-- This encapsulates the tactical "fight or flight" decision-making that
-- individual units use when responding to immediate threats.

local constants = require("constants")
local ForceStatusAnalyzer = require("force-status-analyzer")
local GamePlan = require("game-plan")
local SpatialAgent = require("spatial-agent")

local dispositionTypes = constants.dispositionTypes
local orderStatus = constants.orderStatus
local taskTypes = constants.taskTypes

local TacticalEngagementPlan = {}
setmetatable(TacticalEngagementPlan, {__index = GamePlan})
TacticalEngagementPlan.__index = TacticalEngagementPlan

function TacticalEngagementPlan.new()
    local self = GamePlan.new({
        name = "TacticalEngagement",
        description = "Reactive threat-response behavior: retreat from overwhelming force, engage favorable targets, hold moderate positions"
    })
    setmetatable(self, TacticalEngagementPlan)
    
    return self
end

-- Main planning method
-- Returns: {disposition = "RETREAT/HOLD/ADVANCE/DEFEND", destination = point or nil}
function TacticalEngagementPlan:plan(context)
    -- Validate context
    if not context.situation or not context.commander then
        env.info("ERROR: TacticalEngagementPlan - invalid context")
        return {disposition = dispositionTypes.HOLD, destination = nil}
    end
    
    local situation = context.situation
    local commander = context.commander
    
    -- Check for critical status conditions that override normal decisions
    local criticalDecision = self:checkCriticalStatus(situation, commander)
    if criticalDecision then
        return criticalDecision
    end
    
    -- Route to order-based or autonomous decision logic
    if situation.hasActiveOrders then
        return self:planWithOrders(situation, commander)
    else
        return self:planAutonomous(situation, commander)
    end
end

-- Check for critical status conditions (casualties, ammo)
function TacticalEngagementPlan:checkCriticalStatus(situation, commander)
    local status = situation.statusReport
    local threat = situation.threatAssessment
    
    if not status or status.aliveCount == 0 then
        return nil  -- No decision needed
    end
    
    local totalUnits = situation.initialUnitCount
    local attritionRate = ForceStatusAnalyzer.calculateAttritionRate(status.aliveCount, totalUnits)
    
    -- CRITICAL: Heavy casualties (>40%) - force retreat
    if attritionRate > 0.4 then
        env.info(commander.groupName .. " GAMEPLAN: RETREAT (critical casualties: " .. 
                 string.format("%.0f%%", attritionRate * 100) .. ")")
        
        -- Abort any active orders
        if situation.hasActiveOrders and commander.orders then
            commander.orders:abort("critical_casualties")
        end
        
        local retreatDest = self:calculateRetreatDestination(situation, commander)
        return {
            disposition = dispositionTypes.RETREAT,
            destination = retreatDest
        }
    end
    
    -- CRITICAL: No ammunition (for units that had ammo)
    if situation.hadAmmoInitially and status.ammoCount == 0 then
        -- Abort offensive orders
        if situation.hasActiveOrders and commander.orders then
            local orderContext = situation.orderContext
            if orderContext and (orderContext.type == taskTypes.ASSAULT or orderContext.type == taskTypes.ATTACK) then
                commander.orders:abort("no_ammo")
            end
        end
        
        -- Force retreat if threats present
        if threat.count > 0 and not threat.stale then
            env.info(commander.groupName .. " GAMEPLAN: RETREAT (no ammo, threats present)")
            local retreatDest = self:calculateRetreatDestination(situation, commander)
            return {
                disposition = dispositionTypes.RETREAT,
                destination = retreatDest
            }
        else
            -- No threats, hold position
            return {
                disposition = dispositionTypes.HOLD,
                destination = nil
            }
        end
    end
    
    -- WARNING: Moderate casualties (30-40%) with unfavorable situation
    if attritionRate > 0.3 and threat.favorability < 0.8 then
        env.info(commander.groupName .. " GAMEPLAN: RETREAT (casualties: " .. 
                 string.format("%.0f%%", attritionRate * 100) .. ", Fav:" .. 
                 string.format("%.2f", threat.favorability) .. ")")
        
        -- Abort offensive orders
        if situation.hasActiveOrders and commander.orders then
            local orderContext = situation.orderContext
            if orderContext and (orderContext.type == taskTypes.ASSAULT or orderContext.type == taskTypes.ATTACK) then
                commander.orders:abort("casualties")
            end
        end
        
        local retreatDest = self:calculateRetreatDestination(situation, commander)
        return {
            disposition = dispositionTypes.RETREAT,
            destination = retreatDest
        }
    end
    
    -- WARNING: Light casualties (20-30%) with clearly unfavorable
    if attritionRate > 0.2 and threat.favorability < 0.65 then
        env.info(commander.groupName .. " GAMEPLAN: RETREAT (early casualties: " .. 
                 string.format("%.0f%%", attritionRate * 100) .. ", Fav:" .. 
                 string.format("%.2f", threat.favorability) .. ")")
        
        if situation.hasActiveOrders and commander.orders then
            local orderContext = situation.orderContext
            if orderContext and (orderContext.type == taskTypes.ASSAULT or orderContext.type == taskTypes.ATTACK) then
                commander.orders:abort("casualties")
            end
        end
        
        local retreatDest = self:calculateRetreatDestination(situation, commander)
        return {
            disposition = dispositionTypes.RETREAT,
            destination = retreatDest
        }
    end
    
    -- WARNING: Low ammunition - hold unless overwhelming advantage
    if situation.hadAmmoInitially then
        if ForceStatusAnalyzer.isAmmoLow(status.ammoCount, situation.initialAmmoCount, 20) and 
           threat.favorability < 2.0 then
            env.info(commander.groupName .. " GAMEPLAN: HOLD (low ammo, insufficient advantage)")
            commander:stopMovement()
            return {
                disposition = dispositionTypes.HOLD,
                destination = nil
            }
        end
    end
    
    return nil  -- No critical conditions
end

-- Calculate retreat destination away from threats
function TacticalEngagementPlan:calculateRetreatDestination(situation, commander)
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

-- Plan decisions when following orders
function TacticalEngagementPlan:planWithOrders(situation, commander)
    local threat = situation.threatAssessment
    local orderContext = situation.orderContext
    
    -- Handle order lifecycle events
    if commander.orders.status == orderStatus.ASSIGNED then
        commander.orders:start()
        self:logOrderStart(commander, orderContext)
    end
    
    if commander.orders:isExpired() then
        commander.orders:complete()
        env.info(commander.groupName .. " GAMEPLAN: Order complete (deadline)")
        return {disposition = dispositionTypes.HOLD, destination = nil}
    end
    
    if not orderContext then
        return {disposition = dispositionTypes.HOLD, destination = nil}
    end
    
    -- Check if should abort for overwhelming threat
    if self:shouldAbortForThreat(situation, commander) then
        commander.orders:abort("threat_retreat")
        local retreatDest = self:calculateRetreatDestination(situation, commander)
        return {
            disposition = dispositionTypes.RETREAT,
            destination = retreatDest
        }
    end
    
    -- No threats or eliminated
    if threat.count == 0 or not threat.center then
        return self:planMoveToOrdered(situation, commander, orderContext)
    end
    
    -- RECON completes when threats detected
    if orderContext.type == taskTypes.RECON then
        env.info(commander.groupName .. " GAMEPLAN: RECON complete - threats detected")
        commander.orders:complete()
        return {disposition = dispositionTypes.HOLD, destination = nil}
    end
    
    -- RALLY: Complete when arrived
    if orderContext.type == taskTypes.RALLY then
        local atRallyPoint = (commander:getDestinationToObjective(orderContext.position, orderContext.radius) == nil)
        if atRallyPoint then
            env.info(commander.groupName .. " GAMEPLAN: Reached rally point")
            commander.orders:complete()
            commander:stopMovement()
            return {disposition = dispositionTypes.HOLD, destination = nil}
        end
    end
    
    -- REPOSITION: Move to safety, ignore threats
    if orderContext.type == taskTypes.REPOSITION then
        local atPosition = (commander:getDestinationToObjective(orderContext.position, orderContext.radius) == nil)
        if atPosition then
            commander.orders:complete()
            commander:stopMovement()
           return {disposition = dispositionTypes.HOLD, destination = nil}
        end
        
        -- Continue to destination even if threats detected
        return {
            disposition = dispositionTypes.ADVANCE,
            destination = commander:getDestinationToObjective(orderContext.position, orderContext.radius)
        }
    end
    
    -- RALLY: Engage threats if they're closer than rally destination
    if orderContext.type == taskTypes.RALLY and threat.center then
        local shouldEngageDirectly = self:shouldEngageBeforeRally(situation, commander, orderContext)
        if shouldEngageDirectly then
            commander.orders:abort("closer_threat")
            return self:planEngagement(threat, orderContext, commander)
        end
    end
    
    -- Stale threats: maintain course or move to ordered
    if threat.stale then
        if threat.hasRecentIntel then
            return nil  -- Maintain current disposition/destination
        else
            return self:planMoveToOrdered(situation, commander, orderContext)
        end
    end
    
    -- Retreating with no direct LOS: check if contact broken
    if commander.disposition == dispositionTypes.RETREAT and commander.directLOSCount == 0 then
        if threat.statuses and threat.statuses.observed == 0 and threat.statuses.suspected == 0 then
            commander:stopMovement()
            return {disposition = dispositionTypes.HOLD, destination = nil}
        end
    end
    
    -- Strong position within leash: advance on threats
    local advanceThreshold = 1.5
    if threat.favorability >= advanceThreshold and orderContext.distanceToOrdered < orderContext.leashDistance then
        return self:planAdvanceOnThreats(threat, orderContext, commander)
    end
    
    -- Default: move to ordered position
    return self:planMoveToOrdered(situation, commander, orderContext)
end

-- Plan autonomous decisions (no orders)
function TacticalEngagementPlan:planAutonomous(situation, commander)
    local threat = situation.threatAssessment
    local status = situation.statusReport
    
    -- Unarmed units: retreat if threatened, hold otherwise
    if status.ammoCount == 0 then
        if threat.count > 0 and threat.center then
            if threat.favorability < 0.8 then
                local retreatDest = self:calculateRetreatDestination(situation, commander)
                return {
                    disposition = dispositionTypes.RETREAT,
                    destination = retreatDest
                }
            else
                commander:stopMovement()
                return {disposition = dispositionTypes.HOLD, destination = nil}
            end
        else
            commander:stopMovement()
            return {disposition = dispositionTypes.HOLD, destination = nil}
        end
    end
    
    -- Calculate thresholds with attrition penalties
    local attritionRate = ForceStatusAnalyzer.calculateAttritionRate(status.aliveCount, situation.initialUnitCount)
    local retreatThreshold = 0.6
    local advanceThreshold = 1.5
    
    -- Heavy casualties prevent advancing
    if attritionRate > 0.4 then
        advanceThreshold = 999
    end
    
    -- Hysteresis based on current disposition
    local hysteresis = 0.15
    if commander.disposition == dispositionTypes.RETREAT then
        retreatThreshold = retreatThreshold + hysteresis
    elseif commander.disposition == dispositionTypes.ADVANCE then
        advanceThreshold = advanceThreshold - hysteresis
    end
    
    -- No threats: hold
    if threat.count == 0 or not threat.center then
        return {disposition = dispositionTypes.HOLD, destination = nil}
    end
    
    -- Stale threats: hold or maintain course
    if threat.stale then
        if threat.hasRecentIntel then
            return nil  -- Maintain current
        else
            commander:stopMovement()
            return {disposition = dispositionTypes.HOLD, destination = nil}
        end
    end
    
    -- Retreating with no direct LOS: check if contact broken
    if commander.disposition == dispositionTypes.RETREAT and commander.directLOSCount == 0 then
        if threat.statuses and threat.statuses.observed == 0 and threat.statuses.suspected == 0 then
            commander:stopMovement()
            return {disposition = dispositionTypes.HOLD, destination = nil}
        end
    end
    
    -- Weak: retreat
    if threat.favorability < retreatThreshold then
        local retreatDest = self:calculateRetreatDestination(situation, commander)
        return {
            disposition = dispositionTypes.RETREAT,
            destination = retreatDest
        }
    end
    
    -- Strong: advance
    if threat.favorability >= advanceThreshold then
        local advanceDest = commander:calculateDestinationRelativeToThreats(threat.center, false)
        return {
            disposition = dispositionTypes.ADVANCE,
            destination = advanceDest
        }
    end
    
    -- Moderate: hold
    commander:stopMovement()
    return {disposition = dispositionTypes.HOLD, destination = nil}
end

-- Helper: Should abort order due to threat?
function TacticalEngagementPlan:shouldAbortForThreat(situation, commander)
    -- Uses commander's existing logic
    return commander:shouldAbortForThreat()
end

-- Helper: Should engage threat directly instead of rallying?
function TacticalEngagementPlan:shouldEngageBeforeRally(situation, commander, orderContext)
    local threat = situation.threatAssessment
    local ownPos = commander:getOwnPosition()
    
    if not ownPos or not threat.center then
        return false
    end
    
    local distToThreat = SpatialAgent.distance2D(ownPos, threat.center)
    local distToRally = SpatialAgent.distance2D(ownPos, orderContext.position)
    
    -- Threat significantly closer than rally point (50% threshold)
    return distToThreat < distToRally * 0.5
end

-- Helper: Plan engagement with threats
function TacticalEngagementPlan:planEngagement(threat, orderContext, commander)
    local advanceThreshold = 1.5
    
    if threat.favorability >= advanceThreshold then
        local advanceDest = commander:calculateDestinationRelativeToThreats(threat.center, false)
        return {
            disposition = dispositionTypes.ADVANCE,
            destination = advanceDest
        }
    else
        commander:stopMovement()
        return {
            disposition = dispositionTypes.HOLD,
            destination = nil
        }
    end
end

-- Helper: Plan advance on threats
function TacticalEngagementPlan:planAdvanceOnThreats(threat, orderContext, commander)
    local advanceDest = commander:calculateDestinationRelativeToThreats(threat.center, false)
    
    -- Verify doesn't exceed leash
    if advanceDest and orderContext then
        local destDist = SpatialAgent.distance2D(advanceDest, orderContext.position)
        if destDist > orderContext.leashDistance then
            -- Return to objective instead
            local returnDest = commander:getDestinationToObjective(orderContext.position, orderContext.radius)
            return {
                disposition = dispositionTypes.ADVANCE,
                destination = returnDest
            }
        end
    end
    
    return {
        disposition = dispositionTypes.ADVANCE,
        destination = advanceDest
    }
end

-- Helper: Plan movement to ordered position
function TacticalEngagementPlan:planMoveToOrdered(situation, commander, orderContext)
    local destination = commander:getDestinationToObjective(orderContext.position, orderContext.radius)
    
    if destination then
        return {
            disposition = dispositionTypes.ADVANCE,
            destination = destination
        }
    else
        -- At objective: defend
        if orderContext.type == taskTypes.RALLY or orderContext.type == taskTypes.REINFORCE then
            commander.orders:complete()
        end
        return {
            disposition = dispositionTypes.DEFEND,
            destination = nil
        }
    end
end

-- Helper: Log order start
function TacticalEngagementPlan:logOrderStart(commander, orderContext)
    local orderTypeName = orderContext.type == taskTypes.RALLY and "RALLY" or
                        orderContext.type == taskTypes.ASSAULT and "ASSAULT" or
                        orderContext.type == taskTypes.RECON and "RECON" or
                        orderContext.type == taskTypes.DEFEND and "DEFEND" or
                        orderContext.type == taskTypes.REPOSITION and "REPOSITION" or
                        orderContext.type == taskTypes.REINFORCE and "REINFORCE" or
                        orderContext.type == taskTypes.ATTACK and "ATTACK" or
                        tostring(orderContext.type)
    env.info(commander.groupName .. " GAMEPLAN: Starting " .. orderTypeName .. 
             " @ " .. string.format("%.0f,%.0f", orderContext.position.x, orderContext.position.z) .. 
             " r:" .. orderContext.radius .. " ALR:" .. orderContext.alr)
end

return TacticalEngagementPlan
