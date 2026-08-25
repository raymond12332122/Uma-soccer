# Uma Soccer

A 3D soccer prototype built in Godot 4, aimed at an installable Android APK.
This is the foundation for a much larger football game. Current milestone
(v0.5): two real 3D character models (Tokai Teio, Agnes Digital) on the
pitch simultaneously through the v0.4 reusable asset pipeline, on top of
the v0.3 3v3(+GK) team match (AI teammates/opponents, switching,
data-driven formations) and the v0.2 dribble/pass/shoot core.

## Tech Stack

- **Engine:** Godot 4.x (GDScript)
- **Rendering:** Mobile renderer (`renderer/rendering_method = "mobile"`) for
  good performance on Android devices
- **Physics:** Built-in Godot 3D physics (`CharacterBody3D` for players,
  `RigidBody3D` for the ball)

## Architecture

Each system is a small, single-purpose script (no giant manager):

| System | File | Responsibility |
|---|---|---|
| `PlayerData` | `scripts/PlayerData.gd` | Resource: one character's stats (speed, passing, shooting, dribbling, stamina, defense, foot, etc.) |
| `FootballPlayer` | `scripts/FootballPlayer.gd` | Shared entity for every player (human, AI, GK). Simulates movement/dribbling/kicking from *intent* fields it never sets itself |
| `PlayerController` | `scripts/PlayerController.gd` | Drives the one human-controlled `FootballPlayer` from touch/keyboard input |
| `AIController` | `scripts/AIController.gd` | Stateless per-frame offense/defense/goalkeeper decision logic |
| `TeamController` | `scripts/TeamController.gd` | Owns one team's roster; runs `AIController` on every member except the human target |
| `PossessionManager` | `scripts/PossessionManager.gd` | Single source of truth for who/which team currently has the ball, or if it's loose |
| `FormationManager` | `scripts/FormationManager.gd` | Data-driven starting positions, normalized and mirrored per team |
| `BallController` | `scripts/BallController.gd` | Ball physics tuning, max-speed clamp, reset |
| `CameraController` | `scripts/CameraController.gd` | Follow camera, retargetable at runtime (player switching) |
| `MatchManager` | `scripts/MatchManager.gd` | Top-level orchestrator: spawns both squads, wires the above together, owns scoring/switching/restart |
| `AnimationController` | `scripts/AnimationController.gd` | Owns whichever visual (real model or placeholder) is displayed for one `FootballPlayer`; translates gameplay state into animation/procedural motion |
| `CharacterRegistry` | `scripts/data/CharacterRegistry.gd` | Data-driven map from a `PlayerData.visual_id` string to a character model scene |

**How switching works:** `PlayerController` targets exactly one
`FootballPlayer`. `TeamController` drives every player on its roster
*except* whichever one `PlayerController` currently targets. Switching is
just reassigning that target — the old player is automatically back under
AI control on the very next physics frame, no separate enable/disable logic
needed.

**How possession works:** Every `FootballPlayer` tracks its own
`has_possession` locally (ball within its control sensor, not on a
post-kick cooldown). `PossessionManager` polls all players each frame and
reports whichever one is closest to the ball as the current carrier (and
that player's team as the possessing team) — giving AI a single, cheap
question to ask ("does my team have the ball?") without changing how the
underlying dribble physics resolves a contested ball.

## Project Structure

```
uma-soccer/
├── project.godot                 # Engine config (mobile renderer, autoloads)
├── export_presets.cfg            # Android export preset (arm64-v8a)
├── assets/
│   └── characters/
│       ├── CREDITS.md             # License/attribution for every character model -- read before adding assets
│       ├── tokai_teio/            # tokai_teio.glb + its extracted textures
│       └── agnes_digital/         # agnes_digital.glb + its extracted textures
├── scenes/
│   ├── Main.tscn                  # Entry scene: field, ball, players container, camera, UI
│   ├── Field.tscn                  # Ground, boundary walls, goals, goal triggers
│   ├── FootballPlayer.tscn         # Reusable player scene (spawned N times by MatchManager)
│   ├── Ball.tscn                    # RigidBody3D soccer ball
│   └── UI/TouchControls.tscn       # Joystick + PASS/SHOOT/SPRINT/SWITCH buttons
├── scripts/
│   ├── data/TestRoster.gd         # Small hand-built 3v3(+GK) test squads (PlayerData instances)
│   ├── data/CharacterRegistry.gd  # visual_id -> character model scene
│   ├── InputState.gd               # Autoload singleton bridging touch + gameplay
│   ├── PlayerData.gd                # Per-character stat Resource (incl. visual_id)
│   ├── FootballPlayer.gd            # Movement, dribbling, passing, shooting (shared by everyone)
│   ├── AnimationController.gd        # Visual/animation for one player -- real model or fallback
│   ├── PlayerController.gd          # Human input -> FootballPlayer intent
│   ├── AIController.gd               # Offense/defense/GK decision logic
│   ├── TeamController.gd             # Per-team AI driver + human-player exclusion
│   ├── PossessionManager.gd          # Ball-carrier / possessing-team tracking
│   ├── FormationManager.gd           # Data-driven formation slots
│   ├── BallController.gd             # Ball physics tuning + reset
│   ├── CameraController.gd           # Follow camera, runtime-retargetable
│   ├── MatchManager.gd               # Spawns teams, wires systems, scoring/switch/restart
│   ├── TouchControls.gd             # Wires HUD buttons/joystick to InputState
│   └── JoystickBase.gd              # Virtual joystick drawing + input
├── tools/
│   └── inspect_character_model.gd / InspectCharacterModel.tscn  # Reusable pre-integration model inspector
└── tests/                        # Headless automated tests (see below)
    ├── gameplay_test.gd / GameplayTest.tscn          # FootballPlayer+PlayerController physics
    ├── main_scene_test.gd / MainSceneTest.tscn        # Goals, per-team score, restart, celebration
    ├── team_system_test.gd / TeamSystemTest.tscn      # Spawning, switching, possession, AI, GK
    └── character_pipeline_test.gd / CharacterPipelineTest.tscn  # Registry, AnimationController, real-model gameplay parity
```

## Controls

| Action   | Desktop            | Mobile                 |
|----------|---------------------|-------------------------|
| Move     | WASD / arrow keys   | Left joystick            |
| Sprint   | Hold Shift          | Hold SPRINT button       |
| Pass     | Tap F               | Tap PASS button           |
| Shoot    | Hold Space, release | Hold SHOOT, release       |
| Switch   | Tap Tab             | Tap SWITCH button          |
| Restart  | Tap R               | (desktop-only for now)      |

Shooting is charge-based: the longer Space/SHOOT is held before release, the
harder the shot (up to a capped max speed). Passing is a fixed, lower-power
tap. Both fire in the direction you're currently moving, or the direction
you're facing if you're standing still. Switch cycles through your team's 4
players (GK included); the controlled player has a glowing ring underfoot
and a name label overhead so it's always obvious who you're playing as.

Touch controls also work with a mouse in the Godot editor, since Godot
translates mouse input into GUI touch-equivalent events automatically — no
Android device needed to test the full control scheme.

## Ball Control / Dribbling

The ball is never attached to the player. While the ball is within close
range, a spring-style force gently steers it to a point just ahead of the
player's facing direction each physics frame — the ball still fully obeys
physics (collisions, bounces, momentum) on top of that force. Turning
sharply at speed, sprinting, or passing/shooting all break this steering
(with a brief cooldown after a kick before control can be regained), so
losing the ball on a bad touch is a real possibility, not just cosmetic.

## Team AI (v0.3)

Simple, reactive, no lookahead or tactics:

- **Offense** (own team has the ball): the carrier dribbles toward goal and
  auto-shoots once in range; teammates push their formation slot forward and
  keep spacing from each other (repel when too close, so they don't bunch).
- **Defense** (opponent has it, or ball is loose): the nearest teammate to
  the most advanced opponent presses them (or the ball, if loose); everyone
  else holds a defensive-leaning position pulled back toward their own goal.
- **Goalkeeper**: stays on the goal line, tracks the ball laterally, steps
  out when the ball gets dangerously close, and instantly clears (shoots)
  the ball upfield if it ends up in the keeper's control rather than
  dribbling around the box. A keeper standing in the goal mouth also blocks
  shots simply through normal collision — no separate block-detection code
  needed.

## Character Asset Pipeline

`PlayerData.visual_id` is the only connection between gameplay and visuals.
Empty (the default) means "use the placeholder capsule." Set it to a key
registered in `CharacterRegistry` and `AnimationController` handles the
rest automatically. Two models are integrated as of v0.5 (Tokai Teio,
Agnes Digital), both through this exact process with zero gameplay-code
changes required for the second one:

- **Scale:** downloaded models arrive with wildly inconsistent (sometimes
  simply wrong) embedded scale conventions. Rather than trusting that,
  `AnimationController` measures the imported mesh's actual bind-pose
  height and normalizes it to the game's calibrated ~1.6m character
  height — no per-model manual scale tuning.
- **Orientation:** `facing_correction_degrees` (default 0) is a one-line
  fix if a future model's front doesn't already face the engine's +Z
  forward convention.
- **Materials/textures:** handled entirely by Godot's glTF importer. Godot
  4.3 auto-converts the legacy `KHR_materials_pbrSpecularGlossiness`
  workflow to its metallic/roughness pipeline (a documented, non-blocking
  accuracy caveat from Godot itself, not a bug in this project).
- **Team color:** a real model keeps its own authored textures untouched
  (`AnimationController.supports_team_tint()` is `false` for it) rather
  than getting crudely tinted like the placeholder capsule.
- **Animation:** if a model ships clips, their names are keyword-matched
  onto gameplay states (`idle`/`walk`/`run`/`sprint`/`dribble`) and actions
  (`pass`/`shoot`/`celebration`/`tackle`) automatically. If it has none —
  true for both models integrated so far — a lightweight procedural
  fallback (speed-scaled bob/lean while moving, a dip pulse on pass/shoot,
  a hop-spin on celebration, a lunge-tilt on a won tackle) keeps the
  character visibly alive. `FootballPlayer` never knows which path is
  active.

**Adding another character model:** drop the file under
`assets/characters/<name>/`, optionally run
`godot --headless --path . tools/InspectCharacterModel.tscn -- res://assets/characters/<name>/<file>`
to sanity-check it first (mesh/skeleton/animation/scale summary, and a
warning if the auto-fit measurement looks degenerate), add one line to
`CharacterRegistry.MODELS`, set `visual_id` on a `PlayerData` entry, and
add a license/attribution block to `assets/characters/CREDITS.md`. No
`FootballPlayer`/`AIController`/gameplay code changes required.

**Licensing:** every character model's source, author, and license lives
in `assets/characters/CREDITS.md`. Read it before adding or shipping any
model — a permissively-licensed 3D file does not automatically clear
rights to a character design that belongs to someone else's IP (see that
file's note on the first model, which is a fan reproduction of a Cygames
character).

## Setup (one-time, on your machine)

1. Install [Godot 4.x](https://godotengine.org/download) (stable release).
2. Open this folder as a project in Godot (`project.godot`).
3. Press **F5** (or the Play button) to run the match directly in the
   editor — no additional setup needed for this step.

## Building the Android APK

1. In Godot: **Project > Install Android Build Template**.
2. In **Editor Settings > Export > Android**, point Godot at your Android
   SDK path (install Android Studio / command-line SDK tools if you don't
   have one yet) and generate a debug keystore if prompted.
3. **Project > Export...** — the "Android" preset is already configured
   (package `com.umasoccer.prototype`, arm64-v8a, landscape, immersive
   mode). Click **Export Project** to produce an `.apk` in `builds/`.
4. Install the APK on a device: `adb install builds/uma-soccer.apk`, or
   copy it to the device and open it directly.

This is the only step that requires local tooling on your machine — Godot's
Android SDK path can't be configured remotely. Everything else (gameplay
code, scenes, iteration, testing) happens through this repo.

## Headless Automated Tests

`tests/` contains scripted smoke tests that run without a display, driving
the real scenes through `InputState`/public APIs exactly like touch or
keyboard input and match logic would, then asserting on the resulting
state. Not part of the shipped game — nothing in `project.godot` references
them.

Run them with a local Godot 4.3 binary:

```
godot --headless --path . tests/GameplayTest.tscn
godot --headless --path . tests/MainSceneTest.tscn
godot --headless --path . tests/TeamSystemTest.tscn
godot --headless --path . tests/CharacterPipelineTest.tscn
```

Each prints `[PASS]`/`[FAIL]` per check and exits non-zero on any failure.
`team_system_test.gd` covers spawning, team assignment, formation
positioning, switching, possession transfer, AI movement, and goalkeeper
behavior; `character_pipeline_test.gd` is data-driven over every
`CharacterRegistry`-registered model (so a v0.6+ addition gets the full
battery automatically) covering registry lookup, `AnimationController`'s
real-model and placeholder-fallback paths (scale auto-fit, team-tint
behavior, all states/actions, real-vs-procedural animation detection),
gameplay parity with the placeholder, full-match spawn placement, and
player switching / AI handoff / camera retargeting specifically for a
real-model character; the other two re-validate the full v0.2/v0.3
mechanics (dribble, pass, shot power/clamp, goal scoring, celebration,
restart) now running with two real characters on the pitch.
95 assertions total across all four suites, all passing.

## Current Feature Set (v0.5)

- Everything from v0.3 (3v3+GK match, AI, switching, formations, possession
  tracking, per-team score) unchanged in feel
- Two real 3D characters integrated (Tokai Teio, Agnes Digital — both glTF
  binary, CC BY 4.0, see `assets/characters/CREDITS.md`) via the reusable,
  data-driven pipeline (`CharacterRegistry` + `AnimationController`).
  Adding the second required zero changes to `FootballPlayer`/
  `AIController`/`PlayerController`/`TeamController`/`PossessionManager`/
  `BallController`/`CameraController`/`MatchManager` — purely data
  (one registry entry, one `visual_id` assignment, one credits block)
- Both real characters are on the home roster, so both are actually
  playable through switching, not just AI-visible
- Automatic scale normalization (measured, not guessed) and orientation
  handling for downloaded models with inconsistent conventions
- Procedural fallback animation (bob/lean/pulse) for the common case of a
  downloaded model with no animation clips, with a clean path to real
  clips later via keyword-matched state/action names
- Remaining roster slots still use the original placeholder capsule,
  proving the fallback and multiple real-model paths coexist correctly
- Goal celebrations trigger automatically on the scoring team, including
  for real-model characters

## Roadmap Ideas (for expanding into a full game)

- Integrate further character models as they're provided (same pipeline)
- Full 11-a-side rosters and formations
- AI passing decisions (currently AI ball-carriers dribble + auto-shoot only)
- Ball trapping/first-touch skill mechanics
- Match timer, possession stats
- Real animation clips (walk/run/kick cycles) once available, replacing the
  procedural fallback per character
- Stadium environment, crowd, audio
- Formation editor / tactic selection UI
- Bone-count optimization pass on skinned character models for Android
  (both models' ~400+ joints are mostly cosmetic cloth/hair physics chains
  that currently just sit in bind pose; fine for a couple of characters on
  screen, worth profiling as more are added)
