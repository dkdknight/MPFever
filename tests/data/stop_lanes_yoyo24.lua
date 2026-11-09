-- issue #161 (yoyo, 2026-11-08 16:15Z, 0.7.10): the stop tool's build yoyo:24, a bus stop on a Roads Plus one-way tram street
-- without sidewalks (segment 368306, yoshi_road_plus tram_new_electrified_one_way), from the report's out.log: the segment it
-- removes (one 5.5 m tram lane, as on every game) and the tool's copy that replaces it (a 5 m platform lane added on each side).
-- The builder's town statistics were 0 / 0; replayStop's script copy gave 57.430 / 2062.063 of terrain alignment on YkeWoudstra's
-- game ("TOWN STATS DIFFER", a resynchronisation)
return {
  uid = "yoyo:24", at = 3703400, ctx = 32, native = true,
  ts = { al = 0, ar = 0, tr = 0, rk = 0, ba = 0, br = 0, tv = 0 },
  proposal = {
    addedNodes = {},
    addedSegments = {
      [1] = { entity = -1, type = 0, comp = {
        type = 0, typeIndex = -1, node0 = 76914, node1 = 323569, roadType = 1, distance = 0,
        roadTemplate = "yoshi_road_plus::/infrastructure/street/tram/tram_new_electrified_one_way.street_template",
        roadStyle = "::/infrastructure/street/tram/tram_new.street", roadDevelopmentLocked = false,
        laneConfigs = { { width = 5, forward = true, offset = 0, speed = 10, height = 0.10000000149011612, transportModes = { [0] = true, [1] = false, [2] = false, [3] = false, [4] = false, [5] = false, [6] = false, [7] = false, [8] = false, [9] = false, [10] = false, [11] = false, [12] = false, [13] = false, [14] = false, [15] = false } }, { width = 5.5, forward = true, offset = 0.25, speed = 27.777778625488281, height = 0, transportModes = { [0] = false, [1] = false, [2] = false, [3] = false, [4] = false, [5] = true, [6] = true, [7] = false, [8] = false, [9] = false, [10] = false, [11] = false, [12] = false, [13] = false, [14] = false, [15] = false } }, { width = 5, forward = true, offset = 0, speed = 10, height = 0.10000000149011612, transportModes = { [0] = true, [1] = false, [2] = false, [3] = false, [4] = false, [5] = false, [6] = false, [7] = false, [8] = false, [9] = false, [10] = false, [11] = false, [12] = false, [13] = false, [14] = false, [15] = false } } },
        objects = { { -400000000, 1 } } } }
    },
    removedNodes = {},
    removedSegments = {
      [1] = { entity = 368306, type = 0, comp = {
        type = 0, typeIndex = -1, node0 = 76914, node1 = 323569, roadType = 1, distance = 0,
        roadTemplate = "yoshi_road_plus::/infrastructure/street/tram/tram_new_electrified_one_way.street_template",
        roadStyle = "::/infrastructure/street/tram/tram_new.street", roadDevelopmentLocked = false,
        laneConfigs = { { width = 5.5, forward = true, offset = 0.25, speed = 27.777778625488281, height = 0, transportModes = { [0] = false, [1] = false, [2] = false, [3] = false, [4] = false, [5] = true, [6] = true, [7] = false, [8] = false, [9] = false, [10] = false, [11] = false, [12] = false, [13] = false, [14] = false, [15] = false } } },
        objects = {} } }
    },
    edgeObjectsToAdd = {
      [1] = { model = "::/stations/street/small_stops/small_new.con", category = 0, left = false, oneWay = false, param = 0.57147938013076782,
        segmentEntity = -1, name = "Highfield Road", params = { seed = 0, rse_stop_era = 1, year = 2020 } }
    },
    edgeObjectsToRemove = {},
    nodeConfigsToAdd = {},
  },
}
