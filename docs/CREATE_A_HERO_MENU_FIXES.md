# Create-a-Hero menu corrections

Donor references are relative to Open-BFME-2:

- `Code/GameEngine/Source/GameClient/GUI/GUICallbacks/Apt/AptMyHero.cpp`
  refreshes `UpdateHeroBaseAttributes` after edits. The shell now invokes the
  movie update from its edited-hero notification, including saved-hero changes.
- `Code/GameEngine/Source/GameClient/GUI/AptPlayer.cpp`, `FindRenderImage`,
  tries image records and then the mapped-image collection. The device now
  follows both lookups for `_imageMap`; this restores VerticalScrollBar's
  button and thumb images without changing the movie or its input behavior.
- `Code/GameEngineDevice/Source/W3DDevice/GameClient/Drawable/Draw/W3DModelDraw.cpp`,
  `setModelState`, calls `adjustAnimation` after changing model state. Our split
  model/animation tables previously retained a shared idle state across a new
  skeleton or ModelAnimationPrefix. This left an Elf or Wizard preview playing
  the Captain's idle clip until another animation was picked. A binding change
  now forces animation selection to resolve the new prefix immediately.
- `AptMyHeroRefreshCamera.cpp` supplies ViewInfo's pitch, zoom, floor, distance,
  shift and horizontal field of view. The preview now keeps horizontal FOV,
  reads the mounted map's camera offset for zoom distance, and keeps Floor
  separate from Zoom. The subsequent camera correction follows the donor's mode-1 transform:
  Floor is copied to groundLevel as an absolute plane; the zoomed map offset
  is rotated by pitch/heading, scaled by `1 - Floor / offset.z`, then translated
  by Floor and the named XY point. The hero's terrain Z is not added again.
  S-1405 remains for RotWK mode/flags and fixed-view selection. The Powers
  fixed-view placement is preserved separately; retail pixel parity still
  requires an independent capture.

The hero-list event correction uses the existing GadgetListBox contract:
GLM_SELECTED data1 is the gadget, data2 is the selected row; the callback's
window is the receiving owner. The regression changes the selected row through
the real gadget and checks the displayed record.

Validation: native Create-a-Hero and draw-runtime regressions; scripted builder
flow across classes, appearance, powers and save; windowed screenshots of the
full-body preview, Powers view and restored scrollbar artwork. Retail bytes and
screenshots are not committed.

The Attributes movie supplies `{_x: curX, _y: curY}` as duplicateMovieClip's
third argument. Ignoring it stacked the thirty-two ticks of each bar at the template
position. The optional initializer is now applied through the VM's property
setter. EA's property-copy order remains disclosed under S-104; the real retail
movie test pins all 160 tick positions and that disclosure. The builder screenshot
run now captures the actual Attributes page as well as Appearance.

The in-game Palantir now uses Create-a-Hero's model-state `PortraitImageName`
instead of the generic template's Wanderer portrait. Donor
`CreateAHeroHero::Update` (BFME2 RVA 0x4087E0..0x408802) caches the first
non-null draw-module portrait through `Drawable` RVA 0x272709; the selected
portrait getter (RVA 0x2946AB) prefers that image to `SelectPortrait`.
The port resolves the object's current model flags with the draw runtime's
existing matcher. Retail CreateAHeroModels.inc supplies the expectations:
Shield Maiden = CPShieldMaiden, Captain = CPCaptainofGondor. The HUD regression
checks those distinct portraits and a mixed selection of two heroes sharing
the same object template. The ordinary template comparison shortcut must not
skip custom heroes. S-760 still covers disguise/template overrides.

The Powers screen's `Cah::Portrait` mapping also uses that applied preview
object's portrait now. It previously used the class `IconImage`, so Hero of
the West displayed the Gondor tree. `cah_preview_apply` returns the resolved
portrait after applying the hero, and the view supplies it to the shell image
store. Text refreshes preserve it. Before a preview exists, the explicit
default is HPGandalf, as in donor AptMyHero RVA 0x5B0725. A native shell
regression pins both the default and preservation across class/text refreshes;
a windowed Powers-screen capture confirms the Shield Maiden image replaces
the tree. The separate live-preview camera placement remains under S-1405;
the experimental portrait-row transform did not establish correct framing and
is not included in this fix.

Saved-hero selection now refreshes all ten `MyPowerIcon_<level>` images and
`APT:MyPowerLevel_<level>` labels on the Manager page and clears the previous
hover description. Previously only the Powers editing page refreshed these
keys, leaving stale or missing powers beside the saved-hero list. This follows
donor AptMyHero RVA 0x5B0446 / 0x5B0416 (ten level entries). The real gadget
selection regression switches through all eight system heroes and verifies
every icon, including removal of stale icons in empty slots.

PR self-review also checked the missing-settings path: `cah_view_info` reports
an absent map/archive explicitly, and a failed camera refresh clears the
incomplete view dictionary before the next frame can read `camera_offset`.
The standalone camera regression covers that failure as well as the donor
Floor transform.

The preview camera offset is cached for the loaded game/map. Appearance and
attribute edits reuse it instead of reparsing gamedata.ini on the main thread.
Every game replacement or reset invalidates the cache, including setup with a
new file system. Failed settings loads leave it invalid and keep reporting the
error rather than caching an invented offset.
