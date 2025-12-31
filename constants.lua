local rgb = {
    blue = {0,0.1,0.8,0.5},
    red = {0.5,0,0.1,0.5},
    neutral = {0.1,0.1,0.1,0.5},
}

local groundTemplates = { --frontline, rear, farp
    red = {
        {"KAMAZ Truck", "KAMAZ Truck", "KAMAZ Truck", "KAMAZ Truck"},
        {"BMP-2", "BTR-80", "GAZ-66", "Infantry AK", "Infantry AK", "Infantry AK", "Infantry AK", "Infantry AK" },
        {"Ural-375", "Ural-375", "Ural-375", "GAZ-66", "Paratrooper RPG-16", "Infantry AK", "Infantry AK", "Infantry AK", "Infantry AK", "Infantry AK" },
    },
    blue = {
        {"M 818", "M 818", "M 818", "Hummer"},
        {"M 818", "Hummer", "Soldier M4", "Soldier M4", "Soldier M4", "Soldier M249" },
        {"M-2 Bradley", "Hummer", "Hummer", "Soldier M4", "Soldier M4", "Soldier M4", "Soldier M4" },
    }
}

return {
    rgb = rgb,
    groundTemplates = groundTemplates
}
