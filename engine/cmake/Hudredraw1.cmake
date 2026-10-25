# Lane HUDREDRAW-1 (the in-game HUD redraws only the Apt levels that changed; the note lists stay bounded): tests. Included from engine/CMakeLists.txt so
# the lane's file lists stay out of the shared list.
set(OPENBFME_HUDREDRAW1_TESTS
    tests/test_hudredraw1.cpp
    tests/test_hudredraw1_retail.cpp
)
