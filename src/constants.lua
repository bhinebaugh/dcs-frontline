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

local groundTemplates = { --frontline, rear, farp
    red = {
        {"KAMAZ Truck", "KAMAZ Truck", "KAMAZ Truck", "KAMAZ Truck"},
        {"MTLB", "Ural-375", "Ural-375", "GAZ-66"},
        {"BTR-80", "KAMAZ Truck", "KAMAZ Truck", "GAZ-66"},
        {"BMP-2", "BTR-80", "MTLB", "GAZ-66"},
    },
    blue = {
        {"Hummer", "M 818", "M 818", "M 818"},
        {"M-113", "Hummer", "M 818", "M 818"},
        {"M-113", "M-113", "Hummer", "Hummer"},
        {"M-2 Bradley", "M1043 HMMWV Armament", "M1043 HMMWV Armament", "Hummer"},
    }
}

local taskTypes = {
    DEFEND = 1,
    REINFORCE = 2,
    RECON = 3,
    ASSAULT = 4,
    RESERVE = 5,
    INDIRECT = 6,
    AA = 7,
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

-- Unit classification and threat ratings
-- Each unit type has threat values against infantry, armor, and air
local unitClassification = {
    -- Infantry units
    ["Soldier M4"] = {category = "infantry", threats = {infantry = 2, armor = 0.5, air = 0}, strength = 1},
    ["Soldier M249"] = {category = "infantry", threats = {infantry = 3, armor = 0.5, air = 0}, strength = 1.2},
    ["Infantry AK"] = {category = "infantry", threats = {infantry = 2, armor = 0.5, air = 0}, strength = 1},
    ["Paratrooper RPG-16"] = {category = "infantry", threats = {infantry = 1.5, armor = 4, air = 0}, strength = 1.5},
    
    -- Light vehicles / Trucks
    ["Hummer"] = {category = "infantry", threats = {infantry = 1, armor = 0.5, air = 0}, strength = 1.5},
    ["GAZ-66"] = {category = "infantry", threats = {infantry = 1, armor = 0.5, air = 0}, strength = 1.5},
    ["UAZ-469"] = {category = "infantry", threats = {infantry = 0.5, armor = 0, air = 0}, strength = 0.8},
    ["M 818"] = {category = "infantry", threats = {infantry = 0.5, armor = 0, air = 0}, strength = 1},
    ["KAMAZ Truck"] = {category = "infantry", threats = {infantry = 0.5, armor = 0, air = 0}, strength = 1},
    ["Kamaz 43101"] = {category = "infantry", threats = {infantry = 0.5, armor = 0, air = 0}, strength = 1},
    ["Ural-375"] = {category = "infantry", threats = {infantry = 0.5, armor = 0, air = 0}, strength = 1},
    ["Ural-4320-31"] = {category = "infantry", threats = {infantry = 0.5, armor = 0, air = 0}, strength = 1},
    ["Ural-4320T"] = {category = "infantry", threats = {infantry = 0.5, armor = 0, air = 0}, strength = 1},
    
    -- Scout vehicles
    ["M1043 HMMWV Armament"] = {category = "infantry", threats = {infantry = 3, armor = 2, air = 0}, strength = 2},
    ["BRDM-2"] = {category = "infantry", threats = {infantry = 3, armor = 1.5, air = 0}, strength = 2},
    
    -- Light armor / IFVs
    ["M-113"] = {category = "armor", threats = {infantry = 3, armor = 1, air = 0}, strength = 2.5},
    ["M-2 Bradley"] = {category = "armor", threats = {infantry = 5, armor = 3, air = 0}, strength = 4},
    ["BMP-2"] = {category = "armor", threats = {infantry = 5, armor = 3, air = 0}, strength = 4},
    ["BTR-80"] = {category = "armor", threats = {infantry = 4, armor = 2, air = 0}, strength = 3},
    
    -- Medium armor
    ["M-1 Abrams"] = {category = "armor", threats = {infantry = 3, armor = 8, air = 0}, strength = 8},
    ["T-72B"] = {category = "armor", threats = {infantry = 3, armor = 7, air = 0}, strength = 7},
    ["T-80U"] = {category = "armor", threats = {infantry = 3, armor = 7.5, air = 0}, strength = 7.5},
    
    -- Air defense
    ["Avenger"] = {category = "armor", threats = {infantry = 1, armor = 0, air = 6}, strength = 3},
    ["Vulcan"] = {category = "armor", threats = {infantry = 2, armor = 1, air = 5}, strength = 3},
    ["Strela-10M3"] = {category = "armor", threats = {infantry = 0, armor = 0, air = 5}, strength = 3},
    ["Strela-1 9P31"] = {category = "armor", threats = {infantry = 0, armor = 0, air = 5}, strength = 3},
    
    -- Artillery
    ["M-109"] = {category = "armor", threats = {infantry = 6, armor = 4, air = 0}, strength = 5},
    ["2S9 Nona"] = {category = "armor", threats = {infantry = 5, armor = 3, air = 0}, strength = 4},
}

-- Vulnerability modifiers based on unit category
local vulnerabilityMatrix = {
    infantry = {
        infantry = 1.0,  -- Infantry vs infantry weapons
        armor = 0.3,     -- Infantry vs armor weapons (takes cover, dispersed)
        air = 0.2,        -- Infantry vs air weapons (small target)
        antiair = 0.4     -- Infantry vs anti-air weapons
    },
    armor = {
        infantry = 0.5,  -- Armor vs infantry weapons (some resistance)
        armor = 1.2,     -- Armor vs armor weapons (vulnerable to AT)
        air = 0.8,        -- Armor vs air weapons
        antiair = 0.6     -- Armor vs anti-air weapons
    },
    air = {
        infantry = 0.4,  -- Air vs infantry weapons (less effective)
        armor = 0.7,     -- Air vs armor weapons
        air = 1.0,        -- Air vs air weapons
        antiair = 1.5     -- Air vs anti-air weapons (highly vulnerable)
    },
    antiair = {
        infantry = 0.6,  -- AA vs infantry weapons
        armor = 0.9,     -- AA vs armor weapons
        air = 1.3,        -- AA vs air weapons (highly effective)
        antiair = 1.0     -- AA vs anti-air weapons
    }
}

return {
    acceptableLevelsOfRisk = acceptableLevelsOfRisk,
    dispositionTypes = dispositionTypes,
    formationTypes = formationTypes,
    groundTemplates = groundTemplates,
    rulesOfEngagement = rulesOfEngagement,
    oodaStates = oodaStates,
    rgb = rgb,
    taskTypes = taskTypes,
    threatStatus = threatStatus,
    statusTypes = statusTypes,
    unitClassification = unitClassification,
    vulnerabilityMatrix = vulnerabilityMatrix
}
