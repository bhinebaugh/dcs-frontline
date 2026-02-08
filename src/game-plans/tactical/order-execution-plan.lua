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
    local alerts = commander:getCriticalStatus(situation)
    
    -- Execute order logic
    return self:executeOrder(situation, commander, alerts)
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
function OrderExecutionPlan:executeOrder(situation, commander, alerts)
    local threat = situation.threatAssessment
    local orderContext = situation.orderContext
    
    -- Handle order lifecycle events
    if commander.orders.status == orderStatus.ASSIGNED and orderContext then
        commander.orders:start()
        local orderTypeName = self:getOrderTypeName(orderContext.type)
        env.info(commander.groupName .. " ORDER EXEC: Starting " .. orderTypeName .. 
                 " @ " .. string.format("%.0f,%.0f", commander.orders.position.x, commander.orders.position.z) .. 
                 " r:" .. commander.orders.radius .. " ALR:" .. commander.orders.alr)
    end
    
    if commander.orders:isExpired() then
        env.info(commander.groupName .. " ORDER EXEC: Complete (deadline)")
        commander.orders:complete()
        commander:stopMovement()
        return {disposition = dispositionTypes.HOLD, destination = nil}
    end
    
    if not orderContext then
        return {disposition = dispositionTypes.HOLD, destination = nil}
    end
    
    -- Check if should abort for overwhelming threat
    if alerts or commander:shouldAbortForThreat() then
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
        commander:stopMovement()
        return {disposition = dispositionTypes.HOLD, destination = nil}
    end

    -- Reached destination - handle based on order type
    local atDestination = (commander:getDestinationToObjective(orderContext.position, orderContext.radius) == nil)
    if atDestination then
        -- RALLY: Hold at rally point until rally time, then complete
        if orderContext.type == taskTypes.RALLY then
            local currentTime = timer.getTime()
            local pushTime = commander.orders.pushTime or currentTime  -- Default to immediate if not set
            
            if currentTime < pushTime then
                -- Rally time not reached - hold position
                local remainingTime = math.floor(pushTime - currentTime)
                env.info(commander.groupName .. " ORDER EXEC: At rally point, holding for " .. remainingTime .. "s")
                commander:stopMovement()
                return {disposition = dispositionTypes.DEFEND, destination = orderContext.position}
            else
                -- Rally time reached - complete order
                env.info(commander.groupName .. " ORDER EXEC: Rally complete")
                commander.orders:complete()
                commander:stopMovement()
                return {disposition = dispositionTypes.DEFEND, destination = orderContext.position}
            end
        end
        
        -- Other order types: complete immediately
        env.info(commander.groupName .. " ORDER EXEC: Reached objective, defending")
        commander.orders:complete()
        commander:stopMovement()
        return {disposition = dispositionTypes.DEFEND, destination = orderContext.position}
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
    
    -- Strong favorability: advance on threats closer than objective
    local advanceThreshold = 1.5
    if threat.favorability >= advanceThreshold then
        local advanceDest = commander:calculateDestinationRelativeToThreats(threat.center, false)
        
        -- Verify threat is closer to group than objective
        if advanceDest then
            local objectiveDist = SpatialAgent.distance2D(orderContext.position, commander:getPosition())
            local threatDist = SpatialAgent.distance2D(threat.center, orderContext.position)
            if threatDist > objectiveDist then
                -- Threat too far from objective, return to objective instead
                return self:moveToObjective(commander, orderContext)
            end
        end
        
        env.info(commander.groupName .. " ORDER EXEC: ADVANCE (on threats, Fav:" .. 
                 string.format("%.2f", threat.favorability) .. ")")
        
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
            destination = orderContext.position
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
