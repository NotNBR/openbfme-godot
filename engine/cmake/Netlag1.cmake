# Lane NETLAG-1 (the command delay of a multiplayer game: RotWK's frame + 1): tests of the test executable. Included from engine/CMakeLists.txt so the
# lane's file lists stay out of the shared list. No new sources (the Network's and the peer's files are already listed).
set(OPENBFME_NETLAG1_TESTS
    tests/test_netlag1.cpp
    tests/test_netlag2.cpp # lane NETLAG-2: the round trip the adaptive run-ahead plans for
    tests/test_test_child.cpp # lane DEVPORT-7: TestChild.h (the relay a test starts never outlives it)
)
