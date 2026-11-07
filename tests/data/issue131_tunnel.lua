-- issue #131 (juliu, 2026-11-07 19:09, 0.7.4): the tunnel window's build of action juliu:191, its street part (from the
-- report's out.log; a crosswalk's reference given as its segment's id, as the rebuild gets it): the segments it adds and removes, the node configurations it removes and adds
return {
  ["addedSegments"] = {
    [1] = {
      ["entity"] = -1,
      ["node0"] = 35565,
      ["node1"] = 35436
    },
    [2] = {
      ["entity"] = -2,
      ["node0"] = 35436,
      ["node1"] = 35603
    }
  },
  ["nodeConfigsToAdd"] = {
    [1] = {
      ["comp"] = {
        ["crosswalks"] = {

        },
        ["doubleSlipSwitch"] = false,
        ["laneConnections"] = {
          [1] = {
            ["lane0"] = 0,
            ["lane1"] = 1,
            ["segment0"] = 45199,
            ["segment1"] = -1,
            ["withRoad"] = true,
            ["withTram"] = true
          },
          [2] = {
            ["lane0"] = 0,
            ["lane1"] = 1,
            ["segment0"] = -1,
            ["segment1"] = 45199,
            ["withRoad"] = true,
            ["withTram"] = true
          }
        },
        ["trafficLightPreference"] = 2
      },
      ["entity"] = 35565
    },
    [2] = {
      ["comp"] = {
        ["crosswalks"] = {

        },
        ["doubleSlipSwitch"] = false,
        ["laneConnections"] = {
          [1] = {
            ["lane0"] = 0,
            ["lane1"] = 1,
            ["segment0"] = -1,
            ["segment1"] = -2,
            ["withRoad"] = true,
            ["withTram"] = true
          },
          [2] = {
            ["lane0"] = 0,
            ["lane1"] = 1,
            ["segment0"] = -2,
            ["segment1"] = -1,
            ["withRoad"] = true,
            ["withTram"] = true
          }
        },
        ["trafficLightPreference"] = 2
      },
      ["entity"] = 35436
    },
    [3] = {
      ["comp"] = {
        ["crosswalks"] = {
          [1] = 45602,
          [2] = 35549
        },
        ["doubleSlipSwitch"] = false,
        ["laneConnections"] = {
          [1] = {
            ["lane0"] = 1,
            ["lane1"] = 4,
            ["segment0"] = 45602,
            ["segment1"] = 35549,
            ["withRoad"] = true,
            ["withTram"] = false
          },
          [2] = {
            ["lane0"] = 2,
            ["lane1"] = 4,
            ["segment0"] = 45602,
            ["segment1"] = 35549,
            ["withRoad"] = true,
            ["withTram"] = false
          },
          [3] = {
            ["lane0"] = 3,
            ["lane1"] = 3,
            ["segment0"] = 45602,
            ["segment1"] = 35549,
            ["withRoad"] = true,
            ["withTram"] = false
          },
          [4] = {
            ["lane0"] = 1,
            ["lane1"] = 5,
            ["segment0"] = 35549,
            ["segment1"] = 45602,
            ["withRoad"] = true,
            ["withTram"] = false
          },
          [5] = {
            ["lane0"] = 1,
            ["lane1"] = 6,
            ["segment0"] = 35549,
            ["segment1"] = 45602,
            ["withRoad"] = true,
            ["withTram"] = false
          },
          [6] = {
            ["lane0"] = 2,
            ["lane1"] = 4,
            ["segment0"] = 35549,
            ["segment1"] = 45602,
            ["withRoad"] = true,
            ["withTram"] = false
          },
          [7] = {
            ["lane0"] = 3,
            ["lane1"] = 1,
            ["segment0"] = 45602,
            ["segment1"] = -2,
            ["withRoad"] = true,
            ["withTram"] = true
          },
          [8] = {
            ["lane0"] = 0,
            ["lane1"] = 4,
            ["segment0"] = -2,
            ["segment1"] = 45602,
            ["withRoad"] = true,
            ["withTram"] = true
          }
        },
        ["trafficLightPreference"] = 2
      },
      ["entity"] = 35603
    }
  },
  ["nodeConfigsToRemove"] = {
    [1] = 35565,
    [2] = 35436,
    [3] = 35603
  },
  ["removedSegments"] = {
    [1] = 35475,
    [2] = 35476
  }
}
