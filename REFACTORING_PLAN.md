# GroupCommander & OperationalCommander Refactoring Plan

## Executive Summary

This plan proposes extracting common OODA loop orchestration into a base class and factoring out several cross-cutting concerns into single-purpose classes. The goal is to improve maintainability, testability, and enable new features like pluggable game plan strategies.

## 1. Base Class: OODACommander

### Purpose
Abstract the OODA loop orchestration pattern shared by both GroupCommander and OperationalCommander.

### Lua Inheritance Notes
Lua supports class inheritance through metatables. Both commanders can extend OODACommander:
```lua
-- Base class
local OODACommander = {}
OODACommander.__index = OODACommander

-- Derived class
local GroupCommander = {}
setmetatable(GroupCommander, {__index = OODACommander})
GroupCommander.__index = GroupCommander
```

### Responsibilities
- **OODA Loop Scheduling**: Manage the timer-based scheduling of OODA cycles
- **State Transitions**: Handle transitions between OBSERVE → ORIENT → DECIDE → ACT
- **Lifecycle Management**: Track instances, cleanup on destruction
- **Interval Configuration**: Allow subclasses to define custom OODA intervals
- **Phase Offset**: Randomize initial timing to prevent synchronized ticks

### Interface (Abstract Methods)
Subclasses must implement:
- `observe()` - Gather situational data
- `orient()` - Analyze and synthesize information
- `decide()` - Choose course of action
- `act()` - Execute decisions

### Concrete Methods
- `oodaTick()` - Orchestrate state transitions (already identical in both)
- `scheduleOODA(interval, offset)` - Set up periodic execution
- `destroy()` - Cleanup and deregistration

### Benefits
- **DRY Principle**: Eliminates duplicate OODA orchestration code
- **Consistency**: Ensures both commanders follow same loop pattern
- **Extensibility**: New commander types can easily adopt OODA pattern
- **Testing**: Can test loop orchestration independently

---

## 2. Spatial Geometry Service: SpatialCalculator

### Purpose
Centralize all position, distance, direction, and geometric calculations.

### Current Problem
Spatial calculations are scattered throughout both commanders:
- `calculateDestinationRelativeToThreats()` - GroupCommander
- `calculateReturnToObjective()` - GroupCommander
- `calculateThreatCenter()` - GroupCommander
- `calculateDistanceBetweenUnits()` - GroupCommander
- `calculateAssaultStagingPositions()` - OperationalCommander
- `calculateThreatClusterCenter()` - OperationalCommander
- `calculateSupportRallyPosition()` - OperationalCommander
- `getCommandersByDistance()` - OperationalCommander

### Responsibilities
- **Distance Calculations**: Point-to-point, unit-to-unit, unit-to-area
- **Center of Mass**: Calculate geometric centers (threat centers, group centers)
- **Direction Vectors**: Normalize, rotate, offset
- **Staging Positions**: Calculate tactical positions relative to threats/objectives
- **Proximity Checks**: Within radius, line of sight paths
- **Area Calculations**: Polygons, circles, overlaps

### Proposed Interface
```lua
SpatialCalculator.distance2D(pos1, pos2)
SpatialCalculator.calculateCenter(positions)
SpatialCalculator.normalizeVector(dx, dz)
SpatialCalculator.calculateDestination(from, direction, distance)
SpatialCalculator.calculateStagingPositions(center, radius, count, spreadAngle)
SpatialCalculator.calculateFlankingPosition(target, observer, distance, angleDegrees)
SpatialCalculator.isWithinRadius(position, center, radius)
SpatialCalculator.sortByDistance(positions, referencePoint)
SpatialCalculator.rotateVector(dx, dz, angleRadians)
SpatialCalculator.calculateBearing(from, to)
```

### Migration Strategy
1. Create SpatialCalculator with static methods
2. Migrate one calculation at a time, starting with most-used (distance)
3. Update commanders to use new service
4. Remove old calculation methods
5. Add unit tests for edge cases (zero distance, collocated points, etc.)

---

## 3. Unit & Group Status Analyzer: ForceStatusAnalyzer

### Purpose
Analyze unit and group health, readiness, and capabilities separate from tactical analysis.

### Current Problem
Status analysis is mixed with decision-making logic:
- `getStatusReport()` - GroupCommander (ammo, health, alive count)
- `getCollectiveStatus()` - GroupCommander (percentage alive)
- `assessOwnForce()` - GroupCommander (calls multiple analysis methods)
- `analyzeOwnForce()` - GroupCommander (complex status interpretation)
- `handleCriticalStatusConditions()` - GroupCommander (low ammo, casualties, fuel)
- `checkThreatStatuses()` - GroupCommander (threat aging and status)

### Responsibilities
- **Health Assessment**: Unit damage, group casualties, attrition rates
- **Readiness Evaluation**: Ammo levels, fuel status, formation coherence
- **Capability Analysis**: What can this force still accomplish?
- **Critical Condition Detection**: Low ammo, high casualties, immobile
- **Status Thresholds**: Determine when conditions become critical
- **Change Detection**: Track status degradation over time

### Proposed Interface
```lua
ForceStatusAnalyzer.new(groupName)  -- Instance per group
analyzer:updateStatus()  -- Refresh from DCS units
analyzer:getHealthReport()  -- {aliveCount, deadCount, damagedCount, totalHealth}
analyzer:getReadinessReport()  -- {ammo%, fuel%, mobilityStatus, coherence}
analyzer:getCriticalConditions()  -- Array of threshold violations
analyzer:getCapabilityAssessment()  -- What tasks can we still perform?
analyzer:getCollectiveStatus()  -- Single 0-1 metric
analyzer:hasChanged(threshold)  -- Detect significant status changes
analyzer:getStatusTrend()  -- Improving, stable, degrading
```

### Integration Points
- GroupCommander uses in `observe()` or `orient()` phase
- OperationalCommander queries for force allocation decisions
- Could emit events when critical thresholds crossed

---

## 4. Order & Objective Manager: OrderCoordinator

### Purpose
Manage the lifecycle and relationships between objectives, orders, and assigned units.

### Current Problem
Order management is split across commanders and mixed with strategy:
- `issueOrder()` - GroupCommander
- `handleOrderDecisions()` - GroupCommander
- `assessOrderContext()` - GroupCommander
- `planObjectiveOrders()` - OperationalCommander
- `syncOrderStatuses()` - OperationalCommander
- `reviewAndCancelObsoleteOrders()` - OperationalCommander
- `isOrderChanged()` - OperationalCommander
- Order and Objective classes exist but coordination is ad-hoc

### Responsibilities
- **Order Lifecycle**: Create, assign, track, complete, abort, cancel
- **Status Synchronization**: Keep objective and order states consistent
- **Assignment Management**: Track which orders are assigned to which commanders
- **Obsolescence Detection**: Identify orders that should be canceled
- **Change Detection**: Determine if new orders differ from current
- **Progress Tracking**: Aggregate order completion across objectives
- **Conflict Resolution**: Prevent duplicate or conflicting assignments

### Proposed Interface
```lua
OrderCoordinator.new(coalition)  -- Instance per side
coordinator:createObjective(config)
coordinator:assignOrder(objective, commander, orderConfig)
coordinator:syncOrderStatuses(commanders)  -- Batch sync
coordinator:getActiveOrders(objectiveId)
coordinator:getCommanderOrder(commanderName)
coordinator:cancelObsoleteOrders(predicate)
coordinator:isOrderChanged(commander, newOrder)
coordinator:hasAvailableCommanders()
coordinator:getObjectiveProgress(objective)
coordinator:completeObjective(objectiveId)
```

### Benefits
- **Single Source of Truth**: All order state in one place
- **Simplified Commanders**: Commanders focus on tactics, not bookkeeping
- **Auditing**: Easy to track order history and patterns
- **Testing**: Can test order logic without full commander setup

---

## 5. Strategy Pattern: GamePlan System

### Purpose
Define different strategic approaches (RECON → RALLY → ASSAULT is just one) as pluggable strategies.

### Current Problem
The RECON → RALLY → ASSAULT sequence is hardcoded in `planObjectiveOrders()`:
- Phase progression logic is brittle
- No way to support alternative strategies
- Difficult to test different approaches
- Can't adapt strategy to situation dynamically

### Proposed Architecture

#### GamePlan Interface
```lua
-- Base class for all game plans
local GamePlan = {}
GamePlan.__index = GamePlan

function GamePlan:initialize(objective, context)
function GamePlan:getNextPhase(currentPhase, phaseResult, situation)
function GamePlan:planOrdersForPhase(phase, availableCommanders, context)
function GamePlan:evaluatePhaseCompletion(phase, orders, situation)
function GamePlan:shouldAbort(situation)
```

#### Concrete Strategies

**1. ReconRallyAssault (Current Default)**
- Phases: RECON → RALLY → ASSAULT → DEFEND
- Best for: Unknown threats, coordinated attacks
- Requires: Multiple groups, time to coordinate

**2. BlitzkriegPlan**
- Phases: SCOUT → ASSAULT (skip rally)
- Best for: Overwhelming force, speed priority
- Requires: Strong initial force, clear advantage

**3. DelayingActionPlan**
- Phases: SCREEN → FALLBACK → DEFEND → FALLBACK (repeating)
- Best for: Buying time, defensive operations
- Requires: Prepared fallback positions

**4. InfiltractionPlan**
- Phases: STEALTH_APPROACH → AMBUSH → RAID → EXFILTRATE
- Best for: Hit-and-run, high-value targets
- Requires: Light forces, concealment

**5. Siege Plan**
- Phases: ENCIRCLE → SUPPRESS → REDUCE → OCCUPY
- Best for: Fortified positions, urban areas
- Requires: Artillery support, patience

#### GamePlan Selection
```lua
-- OperationalCommander chooses plan based on situation
function OperationalCommander:selectGamePlan(objective, situation)
    local threatLevel = self:assessThreatLevel(objective)
    local forceRatio = self:calculateForceRatio(objective)
    local timeConstraint = objective.deadline ~= nil
    
    if forceRatio > 2.0 and timeConstraint then
        return BlitzkriegPlan.new()
    elseif forceRatio < 0.5 then
        return DelayingActionPlan.new()
    else
        return ReconRallyAssault.new()
    end
end
```

### Implementation Strategy
1. **Extract Current Logic**: Move RECON→RALLY→ASSAULT into ReconRallyAssault class
2. **Define Interface**: GamePlan base class with required methods
3. **Update OperationalCommander**: Replace hardcoded logic with `currentPlan:getNextPhase()`
4. **Implement Selection**: Add `selectGamePlan()` method
5. **Add New Plans**: Implement one alternative plan to validate flexibility
6. **Testing**: Each plan can be unit tested independently

### Benefits
- **Flexibility**: Easy to add new strategic approaches
- **Situational Adaptation**: Choose best plan for circumstances
- **Testing**: Test plans in isolation
- **Clarity**: Each strategy is self-contained and readable
- **Reusability**: Plans could be shared across different objectives

---

## 6. Intel Management Service: IntelligenceService

### Purpose
Centralize all intelligence sharing and aggregation between commanders.

### Current Problem
Intel sharing is ad-hoc and scattered:
- `aggregateThreatsFromGroups()` - OperationalCommander pulls from groups
- `updateThreatIntel()` - GroupCommander receives intel
- `updateAllyIntel()` - GroupCommander receives ally info
- `assessNearbyAllyStrength()` - OperationalCommander calculates
- ThreatTracker instances are independent per commander

### Responsibilities
- **Threat Aggregation**: Consolidate threat info from all sources
- **Ally Coordination**: Share friendly force positions and strength
- **Information Age**: Track freshness and reliability of intel
- **Dissemination**: Push relevant intel to commanders who need it
- **Filtering**: Provide relevant intel based on proximity and clearance
- **Fog of War**: Model information uncertainty and staleness

### Proposed Interface
```lua
IntelligenceService.new(coalition)  -- One per side
service:reportThreats(commanderName, threats)
service:getThreatIntel(position, radius, maxAge)
service:reportAllyStatus(commanderName, status)
service:getNearbyAllies(position, radius, excludeCommander)
service:getConsolidatedThreatMap()
service:ageAllIntel(deltaTime)
service:shareIntelWith(commander, position, radius)
```

### Integration
- GroupCommanders report observations to IntelligenceService
- OperationalCommander queries service instead of polling commanders
- Service automatically ages intel and removes stale data
- Supports different intel sharing rules (all vs proximity-based)

---

## 7. Additional Extraction Candidates

### 7a. FormationManager
**Current**: Formation logic scattered in GroupCommander
**Purpose**: Calculate and maintain tactical formations
**Methods**: 
- `calculateFormationPositions(centerPoint, unitCount, formationType)`
- `assignFormationSlots(units, positions)`
- `maintainCoherence(currentPositions, targetFormation)`

### 7b. MovementController
**Current**: Move order logic mixed with decisions
**Purpose**: Handle pathfinding and movement commands
**Methods**:
- `issueMoveCommand(group, destination, formationType, speed)`
- `shouldReissueMoveOrder(lastOrder, newDestination, tolerance)`
- `estimateArrivalTime(from, to, terrainType, unitSpeed)`

### 7c. ROEController
**Current**: ROE logic in GroupCommander.act()
**Purpose**: Manage rules of engagement based on disposition
**Methods**:
- `determineROE(disposition, threatLevel, alr)`
- `applyROE(group, roeLevel)`
- `escalateROE(currentROE, situation)`

---

## 8. Implementation Roadmap

### Phase 1: Foundation (Week 1-2)
- [x] Create OODACommander base class
- [x] Migrate GroupCommander to extend OODACommander
- [x] Migrate OperationalCommander to extend OODACommander
- [x] Validate OODA loop still works correctly
- [ ] Add tests for OODACommander lifecycle

### Phase 2: Spatial Extraction (Week 3)
- [x] Create SpatialCalculator class (implemented as **SpatialAgent**)
- [x] Migrate distance calculations
- [x] Migrate center/average calculations
- [x] Migrate staging position calculations
- [x] Update commanders to use SpatialCalculator
- [ ] Add unit tests for edge cases

### Phase 3: Status Analysis (Week 4)
- [x] Create ForceStatusAnalyzer class
- [x] Migrate status reporting from GroupCommander
- [x] Migrate critical condition checks
- [x] Update commanders to use ForceStatusAnalyzer
- [x] All attrition and ammo calculations now use analyzer
- [ ] Add tests for critical thresholds

### Phase 4: Order Management (Week 5-6)
- [ ] Create OrderCoordinator class
- [ ] Migrate order lifecycle methods
- [ ] Migrate order synchronization logic
- [ ] Migrate obsolescence detection
- [ ] Update both commanders to use coordinator
- [ ] Add comprehensive order management tests

### Phase 5: Game Plan System (Week 7-8)
- [ ] Define GamePlan interface
- [ ] Extract ReconRallyAssault into class
- [ ] Implement plan selection logic in OperationalCommander
- [ ] Validate current behavior preserved
- [ ] Implement one alternative plan (Blitzkrieg)
- [ ] Add plan selection tests

### Phase 6: Intel Service (Week 9)
- [ ] Create IntelligenceService class
- [ ] Migrate threat aggregation
- [ ] Migrate ally intel sharing
- [ ] Update commanders to use service
- [ ] Add intel aging tests

### Phase 7: Polish & Optimization (Week 10)
- [ ] Extract FormationManager if needed
- [ ] Extract MovementController if needed
- [ ] Extract ROEController if needed
- [ ] Performance profiling
- [ ] Documentation updates
- [ ] Integration testing

---

## 8.1 Implementation Notes

### Phase 1 - Completed ✅
**Files Created:**
- `src/ooda-commander.lua` (57 lines) - Base class with OODA loop orchestration

**Changes:**
- Both GroupCommander and OperationalCommander now extend OODACommander
- `oodaTick()` method handles all state transitions
- Fixed typo: `oodaInternval` → `oodaInterval`
- Proper Lua inheritance: `setmetatable(Child, {__index = Parent})`

**Git Commits:**
- "Factor out OODACommander base class"

### Phase 2 - Completed ✅
**Files Created:**
- `src/spatial-agent.lua` (306 lines) - DCS-aware spatial utilities (playful pun on "Special Agent")

**Key Methods:**
- `distance2D()` - Handles DCS `.p` property, nil checks, replaces all MIST vector math
- `calculateCenterOfObjects()` - Generic center calculation for any objects with `.position`
- `calculateThreatCenter()` - Convenience wrapper for threat-specific use
- `calculateDirection()` - Direction + distance combined
- `calculateStagingPositions()` - Tactical deployment positions
- `isWithinRadius()` - Optimized with distanceSquared for performance
- `rotateVector()` - 2D rotation for flanking/offset positions

**Migrations:**
- Replaced 12 manual spatial calculations in GroupCommander
- Replaced 16 spatial calculations in OperationalCommander
- Updated ThreatTracker to use SpatialAgent
- Eliminated all `mist.vec.mag(mist.vec.sub())` calls
- Eliminated all manual `math.sqrt(dx*dx + dz*dz)` distance calculations

**Design Decision:**
- Stateless utilities pattern (not stateful instances)
- Functions accept DCS objects directly (Groups, Units, positions)
- Naming: `calculateCenterOfObjects()` (generic) vs `calculateThreatCenter()` (convenience)

**Git Commits:**
- "Factor the SpatialAgent out of the commander positional calculation concerns"

### Phase 3 - Completed ✅
**Files Created:**
- `src/force-status-analyzer.lua` (372 lines) - Stateless force analysis utilities

**Key Methods:**
- `getStatusReport()` - Detailed unit metrics (alive count, ammo, health, fuel)
- `calculateCollectiveStatus()` - Percentage of units alive
- `calculateAttritionRate()` - Attrition rate (0.0 = no losses, 1.0 = total loss)
- `calculateAmmoPercentage()` - Ammo remaining as percentage
- `isAmmoLow()` / `isAmmoCritical()` - Threshold checks with defaults (20% / 5%)
- `hasSignificantAttrition()` - Check if losses exceed threshold
- `calculateAverageHealth()` - Average health per unit
- `compareToBaseline()` - Single function returning comprehensive analysis

**Migrations:**
- Replaced GroupCommander's `getStatusReport()` implementation (was 70+ lines, now 3 lines)
- Replaced GroupCommander's `getCollectiveStatus()` implementation
- Replaced all manual attrition calculations: `1 - (aliveCount / totalCount)` → `ForceStatusAnalyzer.calculateAttritionRate()`
- Replaced all ammo threshold calculations: `initialAmmoCount * 0.05` → `ForceStatusAnalyzer.isAmmoCritical()`
- Updated OperationalCommander with 4 attrition rate replacements

**Design Decision:**
- Stateless utilities following SpatialAgent pattern
- Functions accept group names, Group instances, or status reports
- Commanders store baseline values (initialAmmoCount, initialUnitNames)
- Analyzer provides calculations, commanders maintain state

**Benefits:**
- Consistent status analysis across both commanders
- Reusable for any future commander types
- Centralizes threshold logic (easy to tune balance)
- Decouples "how to calculate" from "when to calculate"

---

## 9. Testing Strategy

### Unit Tests (New Classes)
Each new class should have tests for:
- Initialization and configuration
- Happy path operations
- Edge cases (nil values, zero distances, empty collections)
- Error conditions
- State transitions

### Integration Tests (Commander Interaction)
- OODACommander subclassing works correctly
- Commanders use new services correctly
- Order flow from objective → OperationalCommander → GroupCommander
- Intel flows from GroupCommander → IntelligenceService → OperationalCommander
- Game plans transition through phases correctly

### Regression Tests
- Current scenarios still work
- RECON → RALLY → ASSAULT flow preserved
- Critical status conditions trigger correctly
- Threat detection and response unchanged
- Performance characteristics maintained

### Test Utilities
- Mock DCS units and groups
- Mock timer functions
- Configurable test scenarios
- Assertion helpers for spatial calculations
- Order lifecycle validators

---

## 10. Risk Mitigation

### Breaking Changes
- **Risk**: Refactoring breaks existing functionality
- **Mitigation**: 
  - Incremental changes with validation after each
  - Keep old methods as deprecated wrappers initially
  - Comprehensive regression testing
  - Feature flags for new behavior

### Performance Impact
- **Risk**: Additional abstraction layers slow down OODA loops
- **Mitigation**:
  - Profile before and after each phase
  - Avoid premature optimization
  - Cache expensive calculations
  - Batch operations where possible

### Lua Limitations
- **Risk**: Lua's OOP support is limited
- **Mitigation**:
  - Use established metatable patterns
  - Document inheritance structure clearly
  - Keep class hierarchies shallow (max 2 levels)
  - Provide helper functions for common patterns

### Incomplete Migration
- **Risk**: Half-migrated code is worse than original
- **Mitigation**:
  - Complete each phase before moving to next
  - Each phase should be independently valuable
  - Can pause refactoring at phase boundaries
  - Maintain working code at all times

---

## 11. Success Metrics

### Code Quality
- [ ] Reduced code duplication (target: <5% duplicate lines)
- [ ] Improved test coverage (target: >70% for new classes)
- [ ] Decreased cyclomatic complexity (target: <15 per method)
- [ ] Better separation of concerns (measurable via dependency graphs)

### Maintainability
- [ ] New commander types can be added in <100 LOC
- [ ] New game plans can be added in <200 LOC
- [ ] Spatial calculations have single source of truth
- [ ] Order management logic centralized

### Functionality
- [ ] All existing scenarios pass
- [ ] Can implement 2+ new game plans
- [ ] Can add new commander types easily
- [ ] Intel sharing works consistently

### Performance
- [ ] OODA loop timing unchanged (±5%)
- [ ] Memory usage stable or reduced
- [ ] No new performance bottlenecks

---

## 12. Future Enhancements Enabled

After refactoring, these become much easier:

1. **Machine Learning Integration**: Game plan selection based on learned patterns
2. **Dynamic Difficulty**: Adjust commander intelligence on the fly
3. **Replay System**: Record and replay commander decisions
4. **Visual Debugging**: Show OODA state, planned routes, intel maps
5. **Multi-Objective Planning**: Coordinate multiple simultaneous objectives
6. **Resource Management**: Ammo, fuel, reinforcements as strategic resources
7. **Diplomatic AI**: Coalition coordination, ceasefire negotiations
8. **Morale System**: Unit morale affects performance and decisions
9. **Weather/Time**: Environmental factors affect strategy choices
10. **Specialized Commanders**: AirDefenseCommander, ArmorCommander, etc.

---

## Questions for Discussion

1. **Priority**: Which phases are most valuable? Can we reorder?
2. **Lua Constraints**: Any concerns about OOP patterns in Lua?
3. **Game Plans**: What other strategic patterns would be useful?
4. **Testing**: Do we have DCS test infrastructure available?
5. **Timeline**: Is 10-week timeline realistic given team capacity?
6. **Breaking Changes**: Acceptable to break saves/missions temporarily?
7. **Performance**: What are current performance bottlenecks to preserve?
8. **Documentation**: What level of code documentation is expected?

---

## Conclusion

This refactoring plan significantly improves the architecture while preserving functionality. The incremental approach allows pausing at any phase boundary with valuable improvements already captured. The GamePlan system in particular opens up exciting possibilities for varied AI behavior and player-facing strategic choices.

Most importantly, each extracted concern becomes independently testable, reusable, and understandable - making the codebase more maintainable and extensible for future development.
