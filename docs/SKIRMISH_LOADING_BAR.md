# Skirmish loading-bar presentation

Progress callbacks render the existing LoadScreen.apt bar with buffer swapping
enabled, so synchronous loading updates reach the window. The initial 0% is
presented before loading begins. Gameplay starts immediately when loading
returns, with no extra completion update, frame wait or minimum-duration timer.

The game world stays hidden while it is being constructed, so unfinished terrain
does not show through the loading artwork. Its original visibility is restored
on both successful and failed loads.

Validation on macOS: four existing loading-screen tests (83 assertions), a
headless scripted Skirmish, and a windowed scripted Skirmish. A render-frame
observer confirmed progress from 0% through 100% before gameplay; the completed
bar was captured and visually inspected. The immediate-entry follow-up also
completed a scripted match with no load errors.
