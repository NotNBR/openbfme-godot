# Lane FX-4 (building fire, smoke, shake): sources and tests of the openbfme_core library and the test executable. Included from engine/CMakeLists.txt so
# the lane's file lists stay out of the shared list.

# simulation sources (sim audit manifest): TransitionDamageFX runs in the logic (its RandomBone draws the logic random, its OCLs make objects)
list(APPEND OPENBFME_SIM_SOURCES
    src/GameLogic/Module/TransitionDamageFX.cpp
)
set(OPENBFME_FX4_TESTS
    tests/test_fx4_transition.cpp
)
