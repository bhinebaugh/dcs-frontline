-- OrderExecutionPlan: Assault-oriented behavior for executing orders
--
-- Assumes any order is essentially an assault mission:
-- - Move to destination
-- - Destroy threats near objective
-- - Defend position without pursuing too far
-- - Handle order lifecycle (start, complete, abort)
--
-- Critical status checks override normal behavior to force retreats when heavily damaged.

local constants = require("constants")
local ForceStatusAnalyzer = require("force-status-analyzer")
local GamePlan = require("game-plan")
local SpatialAgent = require("spatial-agent")

local dispositionTypes = constants.dispositionTypes
local orderStatus = constants.orderStatus
local taskTypes = constants.taskTypes

local OrderExecutionPlan = {}
setmetatable(OrderExecutionPlan, {__index = GamePlan})
OrderExecutionPlan.__index = OrderExecutionPlan

function OrderExecutionPlan.new()
    local self = GamePlan.new({
        name = "OrderExecution",
        description = "Execute orders with assault-oriented behavior: move to objective, destroy nearby threats, defend without overextending"
    })
    setmetatable(self, OrderExecutionPlan)
    
    return self
end

-- Main planning method
-- Returns: {disposition = "RETREAT/HOLD/ADVANCE/DEFEND", destination = point or nil}
function OrderExecutionPlan:plan(context)
    -- Validate context
    if not context.situation or not context.commander then
        env.info("ERROR: OrderExecutionPlan - invalid context")
        return {disposition = dispositionTypes.HOLD, destination = nil}
    end
    
    local situation = context.situation
    local commander = context.commander
    
    -- Check for critical status conditions that override normal decisions
    local criticalDecision = self:checkCriticalStatus(situation, commander)
    if criticalDecision then
        return criticalDecision
    end
    
    -- Execute order logic
    return self:executeOrder(situation, commander)
end

-- Check for critical status conditions (casualties, ammo)
function OrderExecutionPlan:checkCriticalStatus(situation, commander)
    local status = situation.statusReport
    local threat = situation.threatAssessment
    
    if not status or status.aliveCount == 0 then
        return nil  -- No decision needed
    end
    
    local totalUnits = #commander.initialUnitNames
    local attritionRate = ForceStatusAnalyzer.calculateAttritionRate(status.aliveCount, totalUnits)
    
    -- CRITICAL: Heavy casualties (>40%) - force retreat
    if attritionRate > 0.4 then
        env.info(commander.groupName .. " ORDER EXEC: RETREAT (critical casualties: " .. 
                 string.format("%.0f%%", attritionRate * 100) .. ")")
        
        -- Abort order
        if commander.orders and commander.orders:isActive() then
            commander.orders:abort("critical_casualties")
        end
        
        local retreatDest = self:calculateRetreatDestination(situation, commander)
        return {
            disposition = dispositionTypes.RETREAT,
            destination = retreatDest
        }
    end
    
    -- CRITICAL: No ammunition - abort offensive orders, retreat if threatened
    if commander.initialAmmoCount > 0 and status.ammoCount == 0 then
        -- Abort offensive orders
        if commander.orders and commander.orders:isActive() then
            local orderContext = situation.orderContext
            if orderContext and (orderContext.type == taskTypes.ASSAULT or orderContext.type == taskTypes.ATTACK) then
                commander.orders:abort("no_ammo")
            end
        end
        
        -- Retreat if threats present
        if threat.count > 0 and not threat.stale then
            env.info(commander.groupName .. " ORDER EXEC: RETREAT (no ammo, threats present)")
            local retreatDest = self:calculateRetreatDestination(situation, commander)
            return {
                disposition = dispositionTypes.RETREAT,
                destination = retreatDest
            }
        else
            return {disposition = dispositionTypes.HOLD, destination = nil}
        end
    end
    
    -- WARNING: Moderate casualties (30-40%) with unfavorable situation
    if attritionRate > 0.3 and threat.favorability < 0.8 then
        env.info(commander.groupName .. " ORDER EXEC: RETREAT (casualties: " .. 
                 string.format("%.0f%%", attritionRate * 100) .. ", Fav:" .. 
                 string.format("%.2f", threat.favorability) .. ")")
        
        -- Abort offensive orders
        if commander.orders and commander.orders:isActive() then
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
        env.info(commander.groupName .. " ORDER EXEC: RETREAT (early casualties: " .. 
                 string.format("%.0f%%", attritionRate * 100) .. ", Fav:" .. 
                 string.format("%.2f", threat.favorability) .. ")")
        
        if commander.orders and commander.orders:isActive() then
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
    if commander.initialAmmoCount > 0 then
        if ForceStatusAnalyzer.isAmmoLow(status.ammoCount, commander.initialAmmoCount, 20) and 
           threat.favorability < 2.0 then
            env.info(commander.groupName .. " ORDER EXEC: HOLD (low ammo, insufficient advantage)")
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
function OrderExecutionPlan:calculateRetreatDestination(situation, commander)
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

-- Execute order with assault-oriented behavior
function OrderExecutionPlan:executeOrder(situation, commander)
    local threat = situation.threatAssessment
    local orderContext = situation.orderContext
    
    -- Handle order lifecycle events
    if commander.orders.status == orderStatus.ASSIGNED then
        commander.orders:start()
        local orderTypeName = self:getOrderTypeName(orderContext.type)
        env.info(commander.groupName .. " ORDER EXEC: Starting " .. orderTypeName .. 
                 " @ " .. string.format("%.0f,%.0f", commander.orders.position.x, commander.orders.position.z) .. 
                 " r:" .. commander.orders.radius .. " ALR:" .. commander.orders.alr)
    end
    
    if commander.orders:isExpired() then
        commander.orders:complete()
        env.info(commander.groupName .. " ORDER EXEC: Complete (deadline)")
        return {disposition = dispositionTypes.HOLD, destination = nil}
    end
    
    if not orderContext then
        return {disposition = dispositionTypes.HOLD, destination = nil}
    end
    
    -- Check if should abort for overwhelming threat
    if commander:shouldAbortForThreat() then
        commander.orders:abort("threat_retreat")
        local retreatDest = self:calculateRetreatDestination(situation, commander)
        return {
            disposition = dispositionTypes.RETREAT,
            destination = retreatDest
        }
    end
    
    -- No threats or eliminated - move to objective
    if threat.count == 0 or not threat.center then
        return self:moveToObjective(commander, orderContext)
    end
    
    -- RECON completes when threats detected
    if orderContext.type == taskTypes.RECON then
        env.info(commander.groupName .. " ORDER EXEC: RECON complete - threats detected")
        commander.orders:complete()
        return {disposition = dispositionTypes.HOLD, destination = nil}
    end
    
    -- Reached destination - complete order and defend
    local atDestination = (commander:getDestinationToObjective(orderContext.position, orderContext.radius) == nil)
    if atDestination then
        env.info(commander.groupName .. " ORDER EXEC: Reached objective, defending")
        commander.orders:complete()
        commander:stopMovement()
        return {disposition = dispositionTypes.DEFEND, destination = nil}
    end
    
    -- REPOSITION: Move to safety, ignore threats
    if orderContext.type == taskTypes.REPOSITION then
        return {
            disposition = dispositionTypes.ADVANCE,
            destination = commander:getDestinationToObjective(orderContext.position, orderContext.radius)
        }
    end
    
    -- Stale threats: move to objective
    if threat.stale then
        if threat.hasRecentIntel then
            return nil  -- Maintain current disposition/destination
        else
            return self:moveToObjective(commander, orderContext)
        end
    end
    
    -- Retreating with no direct LOS: check if contact broken
    if commander.disposition == dispositionTypes.RETREAT and commander.directLOSCount == 0 then
        if threat.statuses and threat.statuses.observed == 0 and threat.statuses.suspected == 0 then
            commander:stopMovement()
            return {disposition = dispositionTypes.HOLD, destination = nil}
        end
    end
    
    -- Strong favorability: advance on threats (within leash)
    local advanceThreshold = 1.5
    if threat.favorability >= advanceThreshold and orderContext.distanceToOrdered < orderContext.leashDistance then
        env.info(commander.groupName .. " ORDER EXEC: ADVANCE (on threats, Fav:" .. 
                 string.format("%.2f", threat.favorability) .. ")")
        
        local advanceDest = commander:calculateDestinationRelativeToThreats(threat.center, false)
        
        -- Verify advance doesn't exceed leash
        if advanceDest then
            local destDist = SpatialAgent.distance2D(advanceDest, orderContext.position)
            if destDist > orderContext.leashDistance then
                -- Too far, return to objective
                return self:moveToObjective(commander, orderContext)
            end
        end
        
        return {
            disposition = dispositionTypes.ADVANCE,
            destination = advanceDest
        }
    end
    
    -- Default: move to objective
    return self:moveToObjective(commander, orderContext)
end

-- Move toward the ordered objective
function OrderExecutionPlan:moveToObjective(commander, orderContext)
    local destination = commander:getDestinationToObjective(orderContext.position, orderContext.radius)
    
    if destination then
        return {
            disposition = dispositionTypes.ADVANCE,
            destination = destination
        }
    else
        -- At objective, defend
        return {
            disposition = dispositionTypes.DEFEND,
            destination = nil
        }
    end
end

-- Get human-readable order type name
function OrderExecutionPlan:getOrderTypeName(orderType)
    if orderType == taskTypes.RALLY then return "RALLY"
    elseif orderType == taskTypes.ASSAULT then return "ASSAULT"
    elseif orderType == taskTypes.RECON then return "RECON"
    elseif orderType == taskTypes.DEFEND then return "DEFEND"
    elseif orderType == taskTypes.REPOSITION then return "REPOSITION"
    elseif orderType == taskTypes.REINFORCE then return "REINFORCE"
    elseif orderType == taskTypes.ATTACK then return "ATTACK"
    else return tostring(orderType)
    end
end

return OrderExecutionPlan
