--[[ This is handy for development, so that you don't need to delete and re-add the individual scripts in the ME when you make a change.  These will not be packaged with the .miz, so you shouldn't use this script loader for packaging .miz files for other machines/users.  You'll want to add each script individually with a DO SCRIPT FILE ]]--
--assert(loadfile("C:\\Users\\Kelvin\\Documents\\code\\RotorOps\\scripts\\RotorOps.lua"))()

require("table") --Load modified standard libraries

local ControlZones = require("control-zones") --Load the ControlZones class from control-zoness.lua
local CoalitionCommander = require("coalition-commander") --Load the CoalitionCommander class from coalition-commander.lua

local UnitLostHandler = require("handlers").UnitLostHandler --Load event handlers

local constants = require("constants") --Load constants

--get zones whose names start with 'control'
--get their coordinates
--grow from opposing start points somehow
--or split the cluster
-- choose a start zone
-- add a connected zone (one of closest zones)


local cz = ControlZones.new(nil, constants.groundTemplates)

cz:setup()
cz:constructDelaunayIndex()

local perimIds = cz:findPerimeter(cz.allZones)
cz:assignCompassMaxima()
local width = cz.maxima.eastmost.y - cz.maxima.westmost.y
local height = cz.maxima.northmost.x - cz.maxima.southmost.x
local centerpoint = { y = 200, x = cz.maxima.southmost.x+height/2, z = cz.maxima.westmost.y+width/2 }

local i = 0
for name, color in pairs(cz.owner) do
    i = i + 1
    local z = cz:getZone(name)
    local pt = z.point
    trigger.action.circleToAll(-1, z.zoneId, pt, 510, {0,0,0,0.2}, constants.rgb[color], 1)
    trigger.action.textToAll(-1, 2000+z.zoneId, pt, {1,1,0,0.5}, {0,0,0,0}, 13, true, z.name)
end

cz:drawEdges()
cz:drawFrontline("blue")
cz:drawFrontline("red")
trigger.action.circleToAll(-1, 9998, mist.utils.makeVec3GL(cz.centroid["red"]), 420, {1,0,0,1}, {1,0,0,0.2}, 1)
trigger.action.circleToAll(-1, 9999, mist.utils.makeVec3GL(cz.centroid["blue"]), 420, {0,0,1,1}, {0,0,1,0.2}, 1)

local unitLostHandler = UnitLostHandler.new(cz)
world.addEventHandler(unitLostHandler)

cz:addCommander("blue", CoalitionCommander.new(cz, {color = "blue"}, constants.groundTemplates.blue))
cz:addCommander("red", CoalitionCommander.new(cz, {color = "red"}, constants.groundTemplates.red))
cz:kickoff()