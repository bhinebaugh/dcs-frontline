-- Per-unit-type data: armor, speed, and weapon loadout.
-- Source of truth is data/unit-data.csv, gathered by tools/unit-data-dump.lua
-- and hand-verified. Regenerate from that CSV rather than hand-editing out of
-- sync. Table keys are exact DCS typeName strings - do not rename them, they
-- must match what DCS/mist expect when spawning (see src/constants.lua's
-- groundTemplates/garrisonTemplates, which reference these same strings).
--
-- armorClass: ordinal tier judged by feel, not real armor thickness -
--   0 = unarmored (infantry, soft-skinned trucks/cars)
--   1 = light (APC/SAM/AAA/artillery chassis)
--   2 = medium (IFV)
--   3 = heavy (MBT)
-- Matches the vs-tier effectiveness columns in weapons.lua.
--
-- speedMax: meters/second, from DCS's own Unit:getDesc().speedMax. Treat this
-- as a fast-lookup approximation - prefer a live getDesc() call when a real
-- Unit reference is available (see GroupCommander:getSlowestUnitSpeed).
--
-- weapons: list of weapon_id keys into weapons.lua, one per ammo type the
-- unit carries (weapons.lua is keyed by ammo, not weapon system - see its
-- header). Empty list = unarmed - confirmed by hand for Hummer/Tigr_233036
-- despite DCS tagging both "Armed vehicles" (see data/unit-data.csv for DCS's
-- own tags, kept there for reference only - they've been found unreliable,
-- e.g. those two). BMP-2 and BMP-3 share "2A42_30_HE"/"2A42_30_AP" rows
-- despite firing them from different guns (2A42 vs 2A72) - same ammo,
-- same effectiveness, see weapons-template.csv for the min_range caveat.
--
-- Kamaz 43101 and Avenger are intentionally omitted: DCS could not resolve
-- either type name during data collection (silently substituted Leopard-2 -
-- see tools/unit-data-dump.lua's usage notes) and their dumped stats are
-- garbage. Add them back once verified via the Mission Editor.

local units = {
    ["Soldier M4"] = {
        dcsRole = "Infantry",
        armorClass = 0,
        life = 1.04,
        speedMax = 4.00,
        weapons = {"5_56x45_Carbine", "5_56x45_NOtr_Carbine"},
    },
    ["Soldier M249"] = {
        dcsRole = "Infantry",
        armorClass = 0,
        life = 1.04,
        speedMax = 4.00,
        weapons = {"5_56x45_SAW", "5_56x45_NOtr_SAW"},
    },
    ["Infantry AK"] = {
        dcsRole = "Infantry",
        armorClass = 0,
        life = 1.04,
        speedMax = 4.00,
        weapons = {"5_45x39", "5_45x39_NOtr"},
    },
    ["Paratrooper RPG-16"] = {
        dcsRole = "Infantry",
        armorClass = 0,
        life = 1.04,
        speedMax = 4.00,
        weapons = {"PG_16V"},
    },
    ["Hummer"] = {
        dcsRole = "APC",
        armorClass = 1,
        life = 2.5,
        speedMax = 31.39,
        weapons = {}, -- confirmed unarmed despite DCS "Armed vehicles" tag
    },
    ["GAZ-66"] = {
        dcsRole = "Truck",
        armorClass = 0,
        life = 2,
        speedMax = 20.83,
        weapons = {},
    },
    ["UAZ-469"] = {
        dcsRole = "Car",
        armorClass = 0,
        life = 1.8,
        speedMax = 27.78,
        weapons = {},
    },
    ["M 818"] = {
        dcsRole = "Truck",
        armorClass = 0,
        life = 2,
        speedMax = 20.83,
        weapons = {},
    },
    ["KAMAZ Truck"] = {
        dcsRole = "Truck",
        armorClass = 0,
        life = 2,
        speedMax = 20.83,
        weapons = {},
    },
    ["Ural-375"] = {
        dcsRole = "Truck",
        armorClass = 0,
        life = 2,
        speedMax = 20.83,
        weapons = {},
    },
    ["Ural-4320-31"] = {
        dcsRole = "Truck",
        armorClass = 0,
        life = 3,
        speedMax = 20.83,
        weapons = {},
    },
    ["Ural-4320T"] = {
        dcsRole = "Truck",
        armorClass = 0,
        life = 2,
        speedMax = 20.83,
        weapons = {},
    },
    ["M1043 HMMWV Armament"] = {
        dcsRole = "APC",
        armorClass = 1,
        life = 2.5,
        speedMax = 31.39,
        weapons = {"M2_12_7_T", "M2_12_7"},
    },
    ["M1045 HMMWV TOW"] = {
        dcsRole = "APC",
        armorClass = 1,
        life = 2.5,
        speedMax = 31.39,
        weapons = {"TOW2"},
    },
    ["BRDM-2"] = {
        dcsRole = "APC",
        armorClass = 1,
        life = 3,
        speedMax = 27.78,
        weapons = {"KPVT_14_5_T", "KPVT_14_5", "7_62x54", "7_62x54_NOTRACER"},
    },
    ["Tigr_233036"] = {
        dcsRole = "APC",
        armorClass = 1,
        life = 2.5,
        speedMax = 40.00,
        weapons = {}, -- confirmed unarmed despite DCS "Armed vehicles" tag
    },
    ["M-113"] = {
        dcsRole = "APC",
        armorClass = 1,
        life = 3,
        speedMax = 16.67,
        weapons = {"M2_12_7_T", "M2_12_7"},
    },
    ["BMD-1"] = {
        dcsRole = "IFV",
        armorClass = 2,
        life = 3,
        speedMax = 16.95,
        weapons = {"2A28_73", "7_62x54", "7_62x54_NOTRACER", "MALUTKA"},
    },
    ["M-2 Bradley"] = {
        dcsRole = "IFV",
        armorClass = 2,
        life = 6,
        speedMax = 18.33,
        weapons = {"M242_25_HE_M792", "M242_25_AP_M791", "TOW2", "7_62x51tr", "7_62x51"},
    },
    ["BMP-2"] = {
        dcsRole = "IFV",
        armorClass = 2,
        life = 5,
        speedMax = 18.33,
        weapons = {"2A42_30_HE", "2A42_30_AP", "7_62x54", "7_62x54_NOTRACER", "KONKURS"},
    },
    ["BMP-3"] = {
        dcsRole = "IFV",
        armorClass = 2,
        life = 5,
        speedMax = 19.44,
        weapons = {"UOF_17_100HE", "2A42_30_HE", "2A42_30_AP", "7_62x54", "7_62x54_NOTRACER", "P_9M117"},
    },
    ["BTR-60"] = {
        dcsRole = "APC",
        armorClass = 1,
        life = 3,
        speedMax = 22.00,
        weapons = {"KPVT_14_5_T", "KPVT_14_5", "7_62x54", "7_62x54_NOTRACER"},
    },
    ["BTR-80"] = {
        dcsRole = "APC",
        armorClass = 1,
        life = 3,
        speedMax = 25.00,
        weapons = {"KPVT_14_5_T", "KPVT_14_5", "7_62x54", "7_62x54_NOTRACER"},
    },
    ["M-1 Abrams"] = {
        dcsRole = "Tank",
        armorClass = 3,
        life = 32,
        speedMax = 18.53,
        weapons = {"M256_120_AP", "M256_120_HE", "M2_12_7_T", "M2_12_7", "7_62x51tr", "7_62x51"},
    },
    ["T-72B"] = {
        dcsRole = "Tank",
        armorClass = 3,
        life = 25,
        speedMax = 16.67,
        weapons = {"2A46M_125_AP", "2A46M_125_HE", "SVIR", "7_62x54", "7_62x54_NOTRACER", "Utes_12_7x108_T", "Utes_12_7x108"},
    },
    ["T-80U"] = {
        dcsRole = "Tank",
        armorClass = 3,
        life = 28,
        speedMax = 19.44,
        weapons = {"2A46M_125_AP", "2A46M_125_HE", "REFLEX", "7_62x54", "7_62x54_NOTRACER", "Utes_12_7x108_T", "Utes_12_7x108"},
    },
    ["Vulcan"] = {
        dcsRole = "AAA",
        armorClass = 1,
        life = 3,
        speedMax = 16.67,
        weapons = {"M61_20_AP_gr", "M61_20_HE_gr"},
    },
    ["Strela-10M3"] = {
        dcsRole = "SAM",
        armorClass = 1,
        life = 3,
        speedMax = 16.67,
        weapons = {"SA9M333", "7_62x54", "7_62x54_NOTRACER"}, -- AMMODATA also revealed a 7.62mm MG not in the original loadout
    },
    ["Strela-1 9P31"] = {
        dcsRole = "SAM",
        armorClass = 1,
        life = 3,
        speedMax = 27.78,
        weapons = {"SA9M31M"},
    },
    ["M-109"] = {
        dcsRole = "Artillery",
        armorClass = 1,
        life = 3,
        speedMax = 15.64,
        weapons = {"M185_155"},
    },
    ["2S9 Nona"] = {
        dcsRole = "Artillery",
        armorClass = 1,
        life = 4,
        speedMax = 16.67,
        weapons = {"2A60_120"},
    },
    ["SAU Msta"] = {
        dcsRole = "Artillery",
        armorClass = 1,
        life = 4,
        speedMax = 16.67,
        weapons = {"2A64_152", "Utes_12_7x108_T", "Utes_12_7x108"}, -- AMMODATA revealed a 12.7mm NSVT self-defense MG not in the original estimate
    },
}

return units
