Constants = require("constants")
AcceptableLevelsOfRisk = Constants.acceptableLevelsOfRisk
GroundTemplates = Constants.groundTemplates
TaskTypes = Constants.taskTypes

CoalitionCommander = require("coalition-commander")
ControlZones = require("control-zones")
GroupCommander = require("group-commander")
Order = require("order")
PatrolDoctrine = require("doctrines.tactical.patrol-doctrine")

-- Initial objective for Alpha is to defend the bridge
-- near the coordinates:
local blueDefendPosition = coord.LLtoLO(
    46 + 29/60 + 18/3600,
    38 + 08/60 + 05/3600
)

-- Known safe rally point for Blue forces
local bluePatrolPosition = coord.LLtoLO(
    46 + 28/60 + 26/3600,
    38 + 19/60 + 12/3600
)

-- Initial objective for Bravo is to reposition to the
-- Kvemo-Khoshka village at these coordinates:
local redPatrolPosition = coord.LLtoLO(
    46 + 33/60 + 23/3600,
    38 + 27/60 + 25/3600
)

-- Known safe rally point for Red forces
local redDefendPosition = coord.LLtoLO(
    46 + 32/60 + 58/3600,
    38 + 39/60 + 09/3600
)

local alpha = ControlZones:spawnGroupAtPoint(
    "Alpha",
    blueDefendPosition,
    "blue",
    GroundTemplates.blue[2],
    90
)
AlphaCommander = GroupCommander.new("Alpha", alpha)

local arnold = ControlZones:spawnGroupAtPoint(
    "Arnold",
    redPatrolPosition,
    "red",
    GroundTemplates.red[1],
    270
)
ArnoldCommander = GroupCommander.new("Arnold", arnold)

local benson = ControlZones:spawnGroupAtPoint(
    "Benson",
    redDefendPosition,
    "red",
    GroundTemplates.red[4],
    270
)
BensonCommander = GroupCommander.new("Benson", benson)

CZ = ControlZones.new(nil, GroundTemplates)
CcBlue = CoalitionCommander.new(CZ, {color = "blue", groundTemplates = GroundTemplates.blue})
CcRed = CoalitionCommander.new(CZ, {color = "red", groundTemplates = GroundTemplates.red})
CZ:addCommander("blue", CcBlue)
CZ:addCommander("red", CcRed)

local alphaDefenseOrder = Order.new({
    type = TaskTypes.ASSAULT,
    position = bluePatrolPosition,
    alr = AcceptableLevelsOfRisk.MEDIUM
})
AlphaCommander:issueOrder(alphaDefenseOrder)

local arnoldDefenseOrder = Order.new({
    type = TaskTypes.ASSAULT,
    position = bluePatrolPosition,
    alr = AcceptableLevelsOfRisk.LOW
})
ArnoldCommander:issueOrder(arnoldDefenseOrder)

ArnoldDefenseOrder = Order.new({
    type = TaskTypes.DEFEND,
    alr = AcceptableLevelsOfRisk.LOW
})

-- BensonCommander:issueOrder(bensonDefenseOrder)

-- ## General scenario setup
-- 1. Bravo encounters Alpha overlooking the bridge
--   - Should spot them when near Kvemo-Roka villag
--   - at a fork in the road
-- 2. Bravo retreats up either branch of the fork
-- 3. Alpha pursues, but loses sight due to terrain
-- 4. Alpha breaks off pursuit and returns to defend the bridge
-- 5. Bravo reports enemy position to strategic command
-- 6. Strategic command dispatches reinforcements to assist Bravo
-- 7. Bravo attempts to continue to Kvemo-Khoshka village after the threat is removed
