-- GamePlan: Pluggable decision strategy for OODACommanders
-- Receives context from ORIENT phase, returns decisions for ACT phase
-- Works at any command level (operational, tactical, individual)

local GamePlan = {}
GamePlan.__index = GamePlan

-- Factory method for creating new GamePlan instances
function GamePlan.new(config)
    local self = setmetatable({}, GamePlan)
    
    self.name = config.name or "UnnamedPlan"
    self.description = config.description or ""
    
    -- State tracking
    self.currentPhase = nil
    self.phaseHistory = {}
    self.createdAt = timer.getTime()
    
    return self
end

-- Main planning method - subclasses must implement
-- @param context PlanningContext table with goal, situation, resources, commander
-- @return decisions table (structure varies by commander type)
function GamePlan:plan(context)
    error("GamePlan subclass must implement plan(context)")
end

-- Get human-readable name
function GamePlan:getName()
    return self.name
end

-- Get detailed description
function GamePlan:getDescription()
    return self.description
end

-- Record phase transition for history tracking
function GamePlan:recordPhaseTransition(fromPhase, toPhase, reason)
    table.insert(self.phaseHistory, {
        from = fromPhase,
        to = toPhase,
        reason = reason or "unknown",
        timestamp = timer.getTime()
    })
end

-- ============================================================================
-- PLANNING CONTEXT STRUCTURE
-- ============================================================================

-- PlanningContext is built during ORIENT phase and consumed during DECIDE
-- Structure works for any OODACommander subclass
--
-- {
--     -- What we're planning for (polymorphic)
--     goal = objective or order,    -- Objective (ops level) or Order (tactical level)
--     goalType = "objective" or "order",  -- Discriminator
--     
--     -- Current situation assessment (from ORIENT)
--     situation = {
--         -- Varies by commander type:
--         -- OperationalCommander: objectiveContext with threats, statusCounts, etc.
--         -- GroupCommander: threatAssessment, orderContext, ownForce, etc.
--     },
--     
--     -- Available resources for planning
--     resources = {
--         -- Varies by commander type:
--         -- OperationalCommander:
--         --   availableCommanders: array of commanders with no active orders
--         --   allCommanders: array of ALL commanders (for recruiting if needed)
--         -- GroupCommander: ownCapabilities, ammo, fuel, etc.
--     },
--     
--     -- Reference to commander (for utility methods, configuration)
--     -- GamePlans can call commander utility methods like:
--     --   commander:scoreCommandersForRecon()
--     --   commander:calculateAssaultStagingPositions()
--     --   commander:selectCommandersWithinTimeWindow()
--     commander = self,
-- }
--
-- Note: GamePlans have full visibility and control over all commanders.
-- Units not recruited by any GamePlan will fall back to autonomous behavior.

return GamePlan
