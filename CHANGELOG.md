# Changelog

All notable changes to this project will be documented in this file.

## [1.1.1] - 2026-11-04

### Changed
- Uses less memory: the game loads when you open it, not when KOReader
  starts, so it no longer takes memory or startup time while unplayed.

## [1.1.0] - 2026-11-04

### Changed
- Hard puzzles build about twice as fast (max digit 6: up to 0.3 s on a
  desktop, now under 0.07 s): the one-step trials go on from where they
  found something instead of starting over. Same puzzles as before.
- A "Generating puzzle…" progress bar shows when a puzzle takes more than a
  moment. Needs game-common 1.12.0.

## [1.0.3] - 2026-11-03

### Changed
- Picks up game-common 1.11.0: the shared on-screen keyboard (where used)
  gives every key the same letter size, and the no-repeat history helper.

## [1.0.2] - 2026-11-02

### Changed
- Picks up game-common 1.10.0: the shared Tools → Games menu also lists
  the games' new "· multiplayer" entries under Party & quiz.

## [1.0.1] - 2026-11-02

### Changed
- Listed under **Tools → Games**, grouped by category, instead of its own
  entry in the Tools menu (game-common 1.9.1).

## [1.0.0] - 2026-10-30

### Added
- First release: Dominosa with four sizes (digits 0-3 to 0-6) and three
  difficulty levels.
- Puzzles are generated with a guaranteed unique solution: the numbering is
  hill-climbed until a graded logical solver cracks it at exactly the chosen
  difficulty (singles / shared cell / one-step trial).
- Tap a border (or two neighbouring cells) to place a domino, hold a border
  to mark it as "no domino here".
- Pair table under the board showing used pairs and duplicates.
- Hint button driven by the solver: it offers a domino the logic forces from
  your current position, after first pointing out any wrong domino.
- Check, Undo, Clear All, timer, and auto-save of the game in progress.
