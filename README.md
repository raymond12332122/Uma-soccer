# Uma Soccer

A 3D soccer prototype built in Godot 4, aimed at an installable Android APK.
This is the foundation for a much larger football game. Current milestone
(v0.3): a real 3v3(+GK) team match — two squads, AI teammates and
opponents, player switching, and a data-driven player/formation system —
built on top of the v0.2 dribble/pass/shoot core.

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
├── scenes/
│   ├── Main.tscn                  # Entry scene: field, ball, players container, camera, UI
│   ├── Field.tscn                  # Ground, boundary walls, goals, goal triggers
│   ├── FootballPlayer.tscn         # Reusable player scene (spawned N times by MatchManager)
│   ├── Ball.tscn                    # RigidBody3D soccer ball
│   └── UI/TouchControls.tscn       # Joystick + PASS/SHOOT/SPRINT/SWITCH buttons
├── scripts/
│   ├── data/TestRoster.gd         # Small hand-built 3v3(+GK) test squads (PlayerData instances)
│   ├── InputState.gd               # Autoload singleton bridging touch + gameplay
│   ├── PlayerData.gd                # Per-character stat Resource
│   ├── FootballPlayer.gd            # Movement, dribbling, passing, shooting (shared by everyone)
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
└── tests/                        # Headless automated tests (see below)
    ├── gameplay_test.gd / GameplayTest.tscn          # FootballPlayer+PlayerController physics
    ├── main_scene_test.gd / MainSceneTest.tscn        # Goals, per-team score, restart
    └── team_system_test.gd / TeamSystemTest.tscn      # Spawning, switching, possession, AI, GK
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
```

Each prints `[PASS]`/`[FAIL]` per check and exits non-zero on any failure.
`team_system_test.gd` covers spawning, team assignment, formation
positioning, switching, possession transfer, AI movement, and goalkeeper
behavior; the other two re-validate the full v0.2 mechanics (dribble, pass,
shot power/clamp, goal scoring, restart) now running through the v0.3
architecture.

## Current Feature Set (v0.3)

- Everything from v0.2 (movement, dribbling, passing, shooting, camera,
  tuned ball physics) unchanged in feel, now data-driven per player
- `PlayerData`: reusable per-character stats that actually affect gameplay
  (speed/accel/sprint directly; passing/shooting/dribbling/stamina/defense
  scaled into kick power, dribble control, sprint endurance, and control
  sensor reach)
- 3v3(+GK) test match: two full squads, distinct stats per player
- Player switching (Tab / SWITCH button) between all 4 home players, camera
  and control indicator follow instantly, previous player becomes AI
- Simple offense/defense/goalkeeper AI for every non-controlled player
- `PossessionManager`: live ball-carrier and possessing-team tracking
- Data-driven formations (`FormationManager`), currently one 3-outfield
  shape, structured so 4-3-3/4-4-2/etc. are just new data entries later
- Per-team score ("Home N - N Away"), goal reset, and full match restart
  (score + all 8 players + ball) via R key

## Roadmap Ideas (for expanding into a full game)

- Full 11-a-side rosters and formations
- AI passing decisions (currently AI ball-carriers dribble + auto-shoot only)
- Ball trapping/first-touch skill mechanics
- Match timer, possession stats
- Character models/animations (currently placeholder capsules)
- Stadium environment, crowd, audio
- Formation editor / tactic selection UI
