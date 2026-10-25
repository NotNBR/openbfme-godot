# Create-a-Hero statistics and awards

The hero manager reads statistics and awards from the mounted
`Data/INI/AwardSystem.ini` and each subclass's `Stats` / `Awards` lists.
It shows statistic labels and values, award images, earned states, and the
selected award's localized description. Definitions and thresholds are data
driven, including explicitly mounted mods.

Each hero's counters live in `Save/<uniqueID>` beside its `MyHero_<uniqueID>.cah`.
The hero definition, its checksum, network messages, replays and simulation
hashes do not include these local counters. Missing statistics files mean a
new hero. File access/write errors reach the live-game report and log; manager
read errors reach its notes and last message. Writes replace a temporary file
only after it closes successfully. Unknown counter names survive saving.

The client records the locally controlled hero's kills, once per scored victim,
before the normal relationship and score-type gates. Replays and observers
do not write progress. Ordered client events carry owned statistic names and
the hero ID across the worker boundary; presentation consumes each event once.
Pending events are flushed on shutdown. Failed writes keep the counters dirty;
presentation and shutdown retry the save without recounting consumed events or
completed results. The dirty flag clears only after a successful write. Started skirmish/LAN/Internet sessions
also count their completed result once through the system's named result
statistics. A hero need not be recruited to receive the match result.

An award needs at least one trigger. Every trigger must pass; each sums the
named counters and compares that sum with its threshold. Earned medals remain
available after restarting, and new awards are reported in the game log.

Evidence: RotWK `scoreTheKill` 0x69560B–0x69564C,
`CreateAHeroHero` kill counting 0x80B1D4, statistics reading 0x80B339,
Manager selection 0x9C513E and stats list 0x9C523F, award-state provider
0x9BF127. The latter returns empty for an absent award, `0` for locked and
`1` for earned. Subclass lists use duplicate suppression (0x61A4FF /
0x61A5B5 → 0x5489D4). BFME2 donor `Rva0040AA27.cpp` supplies the all-trigger
and signed 32-bit sum comparison; `AwardSystemManagerParseThingStat.cpp`
supplies the field registry and reference validation. Target findings retain
the disputed-binary caveat S-001; donor-only behavior is not a parity claim.

S-1403 remains for cosmetic `UpgradeAwards` bling, the in-game award popup,
WotR result counters, computed `PrimaryKey` / `SecondaryKey` statistics, and
retail-exact result timing. Result timing currently follows the completed
`EndGameView`; this is an explicit integration inference. The retail award
file contains no active `UpgradeAwards` rows. These gaps remain reported by
the builder rather than being claimed complete.

Validation: `cah statistics:*` covers trigger boundaries, invalid definitions,
replacement writes and retail decimal-prefix conversion. `cah statistics
retail:*` uses mounted retail definitions/movies to check persisted medal
unlocking and real kill events, including duplicate scoring and unchanged
simulation hashes when profile recording is enabled.

The Awards tab restores the retail template's image/name bindings after its
child image clips finish initialization. The current APT player clears the
parent's first-frame image assignment when the child's first frame runs;
this is a scoped presentation bridge, with general initialization ordering
still covered by S-104. Award states remain strings, as consumed by the
movie's empty / "0" / "1" comparisons. Shell RenderImage clips now use the
same image-mode shaders as HUD clips, so locked medals are grayscale and
earned medals retain their colour (mode render-state inference: S-5016).

The retail shell regression opens the actual Awards tab, checks every medal
binding and label, reopens the tab, then earns a medal and checks its colour
mode. `godot/tests/cah_awards_display_test.gd` checks the mounted movie with an
empty temporary `CAH_TEST_PROFILE`; a windowed run also permits `--shot=...`
for visual inspection. It never writes to the player's hero profile.
