local rgb = {
    blue = {0,0.1,0.8,0.5},
    red = {0.5,0,0.1,0.5},
    neutral = {0.1,0.1,0.1,0.5},
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

return {
    rgb = rgb,
    taskTypes = taskTypes,
    groundTemplates = groundTemplates
}
