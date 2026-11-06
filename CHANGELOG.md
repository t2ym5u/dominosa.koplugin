# Changelog

All notable changes to this project will be documented in this file.

## [1.2.0] - 2026-11-05

### Changed
- Hard no longer needs a guess. Until now every Hard grid could only be
  finished by trying a domino and seeing it fail ("what if it were
  here?"). Hard now takes the same reasoning as Medium ("every place left
  for this pair uses this cell"), but several times as often: Medium needs
  it 1 to 3 times, Hard at least 3 to 7 times depending on the size.
- The hint only gives dominoes found by that reasoning. On a Hard game
  saved by an older version, when the reasoning finds nothing it reveals the
  next domino instead.
- Hard grids, and some Medium ones, differ from those of 1.1.x for the same
  seed, so the Daily Challenge may show a different Dominosa grid once.
- Faster generation: the grader keeps a work list instead of rescanning the
  grid, and reuses its tables from one try to the next. Worst case over 50
  seeds on a desktop: Hard ~0.1 s (up to ~1.8 s when LuaJIT's compiler
  thrashed) → ~35–60 ms; Medium under 11 ms. Same puzzles for the same seed.

## [1.1.2] - 2026-11-04

### Fixed
- A game no longer crashes when an outdated plugin is installed alongside:
  shared modules left behind by an older plugin are replaced by this
  plugin's own copy instead of being used as they are.

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
