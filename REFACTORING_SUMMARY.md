# Refactoring Summary: Key Insights & Priorities

## TL;DR

Your codebase has excellent separation between threat analysis (already extracted) but commanders are doing too much. The refactoring focuses on:

1. **OODACommander base class** - Abstract loop orchestration
2. **Single-purpose services** - Extract spatial, status, order, and intel concerns
3. **GamePlan strategies** - Make RECON→RALLY→ASSAULT just one of many strategies

## What You Already Did Right ✓

- **ThreatAnalyzer**: Coalition-agnostic force analysis
- **ThreatDetector**: LOS and probability-based detection
- **ThreatTracker**: Memory and aging of threat intel
- **Order & Objective**: Clean domain objects

These show good instincts for separation of concerns!

## Biggest Wins from Refactoring

### 1. OODACommander Base Class
**Effort**: Low (1-2 days)  
**Value**: High  
**Why**: Both commanders have *identical* `oodaTick()` code. This is textbook inheritance.

```lua
-- Before: Duplicated in both files
function GroupCommander:oodaTick()
    if self.oodaState == oodaStates.OBSERVE then
        self:observe()
        self.oodaState = oodaStates.ORIENT
    -- ... etc
end

-- After: One place, inherited by both
local OODACommander = {}
function OODACommander:oodaTick()
    -- Same code, used by both subclasses
end
```

### 2. SpatialAgent Service
**Effort**: Medium (3-5 days) ✅ COMPLETED
**Value**: High  
**Why**: 10+ spatial calculation methods scattered across files, lots of duplication

**Examples of duplication found:**
- `calculateThreatCenter()` in GroupCommander
- `calculateThreatClusterCenter()` in OperationalCommander
- Both calculate average of positions nearly identically

**After refactoring:**
```lua
-- Both commanders use same service
local center = SpatialAgent.calculateThreatCenter(threats)
local distance = SpatialAgent.distance2D(pos1, pos2)
local staging = SpatialAgent.calculateStagingPositions(center, 2000, 4, 45)
```

### 3. OrderCoordinator
**Effort**: Medium (4-5 days) ✅ COMPLETED
**Value**: Medium-High
**Why**: Clarifies ownership and provides stateless context utilities

**Architectural Insight:**
The key was finding the right separation:
- **OrderCoordinator owns objective graph (data)** - Single source of truth
- **OperationalCommander owns lifecycle (behavior)** - Planning, issuing, cleanup

This avoids God Object antipattern while keeping behavior with the actor who performs it.

**After refactoring:**
```lua
-- GroupCommander derives order context in ORIENT
local orderContext = OrderCoordinator.deriveOrderContext(
    self.orders, status.position, status.alr
)

-- OperationalCommander derives objective context in ORIENT
local objContext = self.orderCoordinator:deriveObjectiveContext(
    objective, statusCounts, threats, threatCount
)
```

### 4. GamePlan Strategy Pattern
**Effort**: High (5-7 days initial, ongoing for new plans)  
**Value**: Very High  
**Why**: Opens up entire new dimension of tactical variety

**Current problem:**
```lua
-- Hardcoded in planObjectiveOrders()
if lastOrderType == taskTypes.RECON then
    if threatCount == 0 then
        self:planDefendOrders(objective)
    else
        self:planRallyOrders(objective, threats)
    end
elseif lastOrderType == taskTypes.RALLY then
    -- ... more hardcoded logic
```

**Refactored:**
```lua
-- Choose strategy based on situation
local plan = self:selectGamePlan(objective, situation)
local nextPhase = plan:getNextPhase(currentPhase, result, situation)
plan:planOrdersForPhase(nextPhase, commanders, context)
```

Now you can add Blitzkrieg, Infiltration, Siege, etc. as new classes without touching core commander logic!

## Recommended Implementation Order

### Phase 1: Quick Wins (Week 1) ✅ COMPLETED
**Start here** - These are low-risk, high-value extractions:

1. ✅ **OODACommander base class** - Eliminates duplication immediately
2. ✅ **SpatialAgent** - Centralized geometry calculations
3. ✅ **Validate** - Everything works correctly

### Phase 2: Core Services (Weeks 2-3) ✅ COMPLETED
**Build the foundation** - These enable the rest:

4. ✅ **Complete SpatialAgent** - All geometry methods migrated
5. ✅ **ForceStatusAnalyzer** - All status/ammo/attrition calculations
6. ✅ **OrderCoordinator** - Objective graph ownership with stateless utilities
7. ✅ **Validate** - Run through complete mission scenarios

### Phase 3: Strategic Layer (Weeks 4-5) 🎯 NEXT
**The exciting part** - New capabilities:

8. **Extract ReconRallyAssault** - Current logic becomes a GamePlan class
9. **GamePlan interface** - Define the strategy pattern
10. **Add one alternative** - Prove the pattern works (suggest Blitzkrieg)
11. **Validate** - Test both strategies

### Phase 4: Polish (Week 6+)
**Nice-to-haves** - Do if time permits:

12. **IntelligenceService** - Centralize intel sharing (if needed)
13. **Additional GamePlans** - DelayingAction, Infiltration, etc.
14. **Performance tuning** - Optimize hot paths

## Lua Inheritance Pattern

For your reference, here's how to do clean inheritance in Lua:

```lua
-- Base class
local OODACommander = {}
OODACommander.__index = OODACommander

function OODACommander.new(config)
    local self = setmetatable({}, OODACommander)
    self.oodaState = config.initialState
    -- ... base initialization
    return self
end

function OODACommander:oodaTick()
    -- Concrete implementation (not overridden)
end

function OODACommander:observe()
    error("Subclass must implement observe()")
end

-- Derived class
local GroupCommander = {}
setmetatable(GroupCommander, {__index = OODACommander})  -- Inherit from OODACommander
GroupCommander.__index = GroupCommander

function GroupCommander.new(config)
    -- Call parent constructor
    local self = OODACommander.new(config)
    setmetatable(self, GroupCommander)  -- Override metatable
    
    -- Child-specific initialization
    self.groupName = config.groupName
    return self
end

function GroupCommander:observe()
    -- Implement abstract method
    -- Can call parent methods: OODACommander.someMethod(self)
end
```

## Key Metrics to Track

**Before refactoring, measure:**
- Lines of code in each commander: `wc -l group-commander.lua operational-commander.lua`
- Number of methods per class
- OODA loop execution time: Add timing in `oodaTick()`

**After refactoring, compare:**
- Lines of code should decrease in commanders, increase in services
- Method count lower per class
- OODA timing should be similar (±10%)
- **Most importantly**: Time to add new GamePlan should be <2 hours

## Risk Assessment

### Low Risk ✓
- OODACommander extraction (identical code)
- SpatialCalculator (pure functions, easy to test)
- Order/Objective enhancements (already partially abstracted)

### Medium Risk ⚠
- GamePlan extraction (complex state machine)
- ForceStatusAnalyzer (touches many decision points)
- IntelligenceService (timing-sensitive)

### High Risk ⚠⚠
- Changing OODA loop timing/scheduling
- Modifying threat detection logic
- Altering existing phase progression before extraction complete

## Testing Recommendations

**Unit Tests** (New classes in isolation):
```lua
-- Example for SpatialCalculator
function test_distance2D_basic()
    local pos1 = {x = 0, z = 0}
    local pos2 = {x = 3, z = 4}
    assert(SpatialCalculator.distance2D(pos1, pos2) == 5)
end

function test_distance2D_same_point()
    local pos = {x = 100, z = 200}
    assert(SpatialCalculator.distance2D(pos, pos) == 0)
end
```

**Integration Tests** (Commanders with services):
- Create mock DCS environment
- Run through RECON → RALLY → ASSAULT with test units
- Verify orders issued correctly
- Check final positions and states

**Regression Tests** (Existing missions):
- Run current scenarios before and after
- Compare unit positions at checkpoints
- Verify objectives achieved
- Check performance metrics

## Questions to Consider

1. **Do you want to start with Phase 1 immediately, or discuss approach first?**
   
2. **Are there specific GamePlan strategies you have in mind** beyond the ones I proposed (Blitzkrieg, DelayingAction, Infiltration, Siege)?

3. **Is there a testing framework** you're already using, or should we set one up?

4. **Performance constraints** - What's the maximum acceptable OODA loop time? Current baseline?

5. **Breaking changes** - Can we temporarily break mission files during refactoring, or must backward compatibility be maintained?

6. **Code style** - Do you have preferences for naming, file organization, documentation format?

## Next Steps

**If you want to proceed:**

1. **Choose starting point** - I recommend Phase 1 (OODACommander + basic SpatialCalculator)
2. **Set up testing** - Even basic smoke tests will help
3. **Create feature branch** - Keep refactoring isolated until stable
4. **Iterative validation** - Test after each extraction

**If you want to explore first:**

1. **Review refactoring plan** - Full details in REFACTORING_PLAN.md
2. **Check diagrams** - Visualize the architecture changes
3. **Ask questions** - Clarify any concerns or constraints
4. **Prioritize phases** - Reorder based on your needs

---

## Code Examples: Before & After

### Example 1: Distance Calculation

**Before** (Scattered across files):
```lua
-- In group-commander.lua
function GroupCommander:calculateDistanceBetweenUnits(unit1, unit2)
    local pos1 = unit1:getPosition().p
    local pos2 = unit2:getPosition().p
    return math.sqrt((pos1.x - pos2.x)^2 + (pos1.z - pos2.z)^2)
end

-- In operational-commander.lua (similar code)
local distanceToOrdered = math.sqrt(
    (ownPos.x - orderedPosition.x)^2 + 
    (ownPos.z - orderedPosition.z)^2
)
```

**After** (Single source of truth):
```lua
-- In spatial-calculator.lua
function SpatialCalculator.distance2D(pos1, pos2)
    local dx = pos1.x - pos2.x
    local dz = pos1.z - pos2.z
    return math.sqrt(dx * dx + dz * dz)
end

-- Usage in commanders
local dist = SpatialCalculator.distance2D(ownPos, targetPos)
```

### Example 2: GamePlan Selection

**Before** (Hardcoded in OperationalCommander):
```lua
function OperationalCommander:planObjectiveOrders(objective)
    -- 100+ lines of hardcoded phase logic
    if lastOrderType == taskTypes.RECON then
        if threatCount == 0 then
            self:planDefendOrders(objective)
        else
            self:planRallyOrders(objective, threats)
        end
    elseif lastOrderType == taskTypes.RALLY then
        -- more conditions...
    end
end
```

**After** (Pluggable strategies):
```lua
-- In operational-commander.lua
function OperationalCommander:planObjectiveOrders(objective)
    if not objective.gamePlan then
        objective.gamePlan = self:selectGamePlan(objective)
    end
    
    local situation = self:assessSituation(objective)
    objective.gamePlan:execute(situation, self)
end

function OperationalCommander:selectGamePlan(objective)
    local forceRatio = self:calculateForceRatio(objective)
    local hasTime = not objective.deadline or (objective.deadline - timer.getTime()) > 600
    
    if forceRatio > 2.0 and not hasTime then
        return BlitzkriegPlan.new(objective)
    elseif forceRatio < 0.5 then
        return DelayingActionPlan.new(objective)
    else
        return ReconRallyAssault.new(objective)
    end
end

-- In recon-rally-assault.lua (new file)
function ReconRallyAssault:execute(situation, commander)
    local phase = self:getCurrentPhase()
    local nextPhase = self:determineNextPhase(phase, situation)
    
    if phase ~= nextPhase then
        self:transitionTo(nextPhase)
    end
    
    self:planOrdersForPhase(nextPhase, commander, situation)
end
```

### Example 3: OODA Inheritance

**Before** (Duplicated):
```lua
-- group-commander.lua
function GroupCommander:oodaTick()
    if self.oodaState == oodaStates.OBSERVE then
        self:observe()
        self.oodaState = oodaStates.ORIENT
    elseif self.oodaState == oodaStates.ORIENT then
        self:orient()
        self.oodaState = oodaStates.DECIDE
    -- etc...
end

-- operational-commander.lua (exact same code)
function OperationalCommander:oodaTick()
    if self.oodaState == oodaStates.OBSERVE then
        self:observe()
        self.oodaState = oodaStates.ORIENT
    -- etc...
end
```

**After** (Inherited):
```lua
-- ooda-commander.lua (new base class)
local OODACommander = {}
OODACommander.__index = OODACommander

function OODACommander:oodaTick()
    if self.oodaState == oodaStates.OBSERVE then
        self:observe()
        self.oodaState = oodaStates.ORIENT
    elseif self.oodaState == oodaStates.ORIENT then
        self:orient()
        self.oodaState = oodaStates.DECIDE
    elseif self.oodaState == oodaStates.DECIDE then
        self:decide()
        self.oodaState = oodaStates.ACT
    elseif self.oodaState == oodaStates.ACT then
        self:act()
        self.oodaState = oodaStates.OBSERVE
    end
end

-- group-commander.lua
local GroupCommander = {}
setmetatable(GroupCommander, {__index = OODACommander})
GroupCommander.__index = GroupCommander
-- Now oodaTick() is inherited automatically

-- operational-commander.lua
local OperationalCommander = {}
setmetatable(OperationalCommander, {__index = OODACommander})
OperationalCommander.__index = OperationalCommander
-- Now oodaTick() is inherited automatically
```

## Summary

Your instinct to separate concerns is spot-on. The codebase already shows good patterns with threat analysis extracted. This refactoring extends that philosophy to spatial, status, order management, and strategic planning.

**The GamePlan system is the crown jewel** - it transforms your AI from having "one way to attack" into a library of tactical doctrines that can be selected, tested, and extended independently.

Start with Phase 1 (OODACommander + SpatialCalculator basics) - you'll see immediate benefits and can decide whether to continue based on results.
