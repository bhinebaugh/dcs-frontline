local acceptableLevelsOfRisk = {
    LOW = "Low", -- Accept favorable engagements only; withdraw to preserve forces
    MEDIUM = "Medium", -- Accept neutral/favorable engagements; withdraw to avoid heavy losses
    HIGH = "High", -- Accept major losses to achieve objectives
}

local dispositionTypes = {
    ADVANCE = "Advance",
    ASSAULT = "Assault",
    DEFEND = "Defend",
    EVADE = "Evade",
    HOLD = "Hold Position",
    RETREAT = "Retreat",
}

local formationTypes = {
    OFF_ROAD = "Off Road", -- moving off-road in Column formation 
    ON_ROAD = "On Road", -- moving on road in Column formation 
    RANK = "Rank", -- moving off road in Row formation 
    CONE = "Cone", -- moving in Wedge formation 
    VEE = "Vee", -- moving in Vee formation 
    DIAMOND = "Diamond", -- moving in Diamond formation 
    ECHELONL = "EchelonL", -- moving in Echelon Left formation 
    ECHELONR = "EchelonR", -- moving in Echelon Right formation  
}
local garrisonTemplates = { --static objects
    red = {"Ural-375"}, --category "Unarmed" {"KAMAZ Truck", "KAMAZ Truck"}, -- {"Ural-375", "Ural-375", "GAZ-66"},
    blue = {"M 818"}, --category "Unarmed" --{"M 818", "M 818"},
}
local groundTemplates = { --frontline, rear, farp
    red = {
        -- {"KAMAZ Truck", "KAMAZ Truck", "KAMAZ Truck", "KAMAZ Truck"},
        -- {"MTLB", "Ural-375", "Ural-375", "GAZ-66"},
        -- {"BTR-80", "KAMAZ Truck", "KAMAZ Truck", "GAZ-66"},
        -- {"BMP-2", "BTR-80", "MTLB", "GAZ-66"},
        {"BRDM-2", "BRDM-2", "BRDM-2"},
        {"BTR-80", "BTR-80", "BTR-80", "BTR-80"},
        {"BMP-2", "BMP-2", "BTR-80", "BTR-80"},
        {"T-72B", "T-72B", "BTR-60"}
    },
    blue = {
        -- {"Hummer", "M 818", "M 818", "M 818"},
        -- {"M-113", "Hummer", "M 818", "M 818"},
        {"M1045 HMMWV TOW",  "M1043 HMMWV Armament",  "M1043 HMMWV Armament"},
        {"M-113", "M-113", "M1043 HMMWV Armament",  "M1043 HMMWV Armament"},
        {"M-2 Bradley", "M-2 Bradley", "M1043 HMMWV Armament", "M1043 HMMWV Armament"},
        {"M-1 Abrams", "M-1 Abrams", "M-113"}
    }
}

-- Indirect fire support (artillery) templates, spawned one zone back from
-- the frontline (depth 1, see ControlZones:calculateDepthMap/spawnFireSupportForces)
-- rather than on the front line itself.
local fireSupportTemplates = {
    red = {
        {"SAU Msta"},
        {"SAU Msta", "SAU Msta"},
    },
    blue = {
        {"M-109"},
        {"M-109", "M-109"},
    },
}

local taskTypes = {
    DEFEND = 1,
    REINFORCE = 2,
    RECON = 3,
    ASSAULT = 4,
    RALLY = 5,
    INDIRECT = 6,
    AA = 7,
    REPOSITION = 8,
    PATROL = 9,
}

local threatStatus = {
    OBSERVED = "Observed",      -- Currently in LOS
    SUSPECTED = "Suspected",    -- Not currently visible but believed present
    UNCONFIRMED = "Unconfirmed", -- Position checked, not found
    LOST = "Lost",              -- Unconfirmed for >5 minutes, presumed gone
    ELIMINATED = "Eliminated"   -- Confirmed destroyed (BDA)
}

local statusTypes = {
    HOLD = 1,
    EN_ROUTE = 2,
}

local orderStatus = {
    ASSIGNED = "Assigned",       -- Order received, not yet acted upon
    IN_PROGRESS = "In Progress", -- Actively executing order
    COMPLETED = "Completed",     -- Successfully completed or deadline reached
    ABORTED = "Aborted",        -- Mission no longer possible or canceled
}

local oodaStates = {
    OBSERVE = "Observe",
    ORIENT = "Orient",
    DECIDE = "Decide",
    ACT = "Act",
}

local rgb = {
    blue = {0,0.1,0.8,0.5},
    red = {0.5,0,0.1,0.5},
    neutral = {0.1,0.1,0.1,0.5},
}

local rulesOfEngagement = {
    WEAPON_FREE = 0, -- Engage targets at will
    RETURN_FIRE = 3, -- Engage only if fired upon
    WEAPON_HOLD = 4, -- Hold fire, do not engage
}

-- Unit classification (armor/weapons/speed) now lives in src/units.lua and
-- src/weapons.lua, sourced from data/unit-data.csv and data/weapons-template.csv.

return {
    acceptableLevelsOfRisk = acceptableLevelsOfRisk,
    dispositionTypes = dispositionTypes,
    fireSupportTemplates = fireSupportTemplates,
    formationTypes = formationTypes,
    garrisonTemplates = garrisonTemplates,
    groundTemplates = groundTemplates,
    orderStatus = orderStatus,
    rulesOfEngagement = rulesOfEngagement,
    oodaStates = oodaStates,
    rgb = rgb,
    taskTypes = taskTypes,
    threatStatus = threatStatus,
    statusTypes = statusTypes
}
