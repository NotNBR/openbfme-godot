# Lane OWNERFIX-2 (the owner's playtest of 2026-10-17: structure auras, the Command Points rule, handicap, resource building overlap): client sources and
# tests. Included from engine/CMakeLists.txt so the lane's file lists stay out of the shared list.
set(OPENBFME_OWNERFIX2_CLIENT_SOURCES
    src/GameClient/FloatingText.cpp # the money texts of paying buildings (InGameUI floating text): client
    src/GameClient/TerrainResourceFeedback.cpp # the resource claim feedback (placement percentage and decals): client, reads the logic's grid
)
set(OPENBFME_OWNERFIX2_TESTS
    tests/test_ownerfix2.cpp
)
