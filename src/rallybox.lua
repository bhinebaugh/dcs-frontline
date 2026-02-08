local constants = require("constants")
local taskTypes = constants.taskTypes

local GroupCommander = require("group-commander")
local Objective = require("objective")
local OperationalCommander = require("operational-commander")

-- Initial objective for Alpha is to defend the bridge
-- near the coordinates:
local blueAttackPosition = coord.LLtoLO(
    42 + 35/60 + 31/3600,
    41 + 56/60 + 26/3600
)

-- Known safe rally point for Blue forces
local blueRallyPosition = coord.LLtoLO(
    42 + 20/60 + 50/3600,
    41 + 50/60 + 50/3600
)

-- Initial objective for Bravo is to reposition to the
-- Kvemo-Khoshka village at these coordinates:
-- local redAttackPosition = coord.LLtoLO(
--     42 + 37/60 + 03/3600,
--     41 + 44/60 + 0/3600
-- )
local redAttackPosition = coord.LLtoLO(
    44 + 5/60 + 10/3600,
    44 + 16/60 + 35/3600
)

-- Known safe rally point for Red forces
local redRallyPosition = coord.LLtoLO(
    42 + 43/60 + 53/3600,
    42 + 02/60 + 56/3600
)

local opsBlue = OperationalCommander.new({color = "blue"})
local opsRed = OperationalCommander.new({color = "red"})

-- Assign rally points to strategic commanders
opsBlue.rallyPoints = {
    {position = blueRallyPosition, radius = 500}
}

opsRed.rallyPoints = {
    {position = redRallyPosition, radius = 500}
}

-- Create and assign objectives directly
opsBlue.orderCoordinator.objectives = {
    Objective.new({
        type = taskTypes.ASSAULT,
        position = redAttackPosition,
        radius = 500,
    })
}

opsRed.orderCoordinator.objectives = {
    Objective.new({
        type = taskTypes.ASSAULT,
        position = redAttackPosition,
        deadline = timer.getTime() + 1800,  -- 30 minute deadline
    })
}

local function createGroupCommandersForCoalition(coalitionSide, color, opsCommander)
    local groups = coalition.getGroups(coalitionSide, Group.Category.GROUND) or {}
    for _, group in ipairs(groups) do
        if group and group:isExist() then
            local groupName = group:getName()
            GroupCommander.new(groupName, {
                color = color,
                stratcom = opsCommander
            })
        end
    end
end

createGroupCommandersForCoalition(coalition.side.BLUE, "blue", opsBlue)
createGroupCommandersForCoalition(coalition.side.RED, "red", opsRed)

-- ## General scenario setup
-- 1. Blue pushes up to secure the town North of Zugdidi
-- 2. Red pushes southwest to seize Gali
-- 3. Each faction should start with recon units scouting ahead
-- 4. As they make contact, assault orders should be given
-- 7. Each faction should commit forces until one side is destroyed
-- 8. Individual groups will retreat despite orders, if they take heavy losses

