# Lane WALL-2 (castle and fortress walls: the pathfinder's portals, the portal modules, raised walkways, life on the walls): sources and tests. Included from
# engine/CMakeLists.txt so the lane's file lists stay out of the shared list.

# simulation sources (sim audit manifest)
list(APPEND OPENBFME_SIM_SOURCES
    src/GameLogic/AI/AIPathfindPortals.cpp
)
set(OPENBFME_WALL2_TESTS
    tests/test_wall2_portals.cpp
)
