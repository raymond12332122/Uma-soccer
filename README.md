# Uma Soccer

A 3D soccer prototype built in Godot 4, aimed at an installable Android APK.
This is the foundation for a much larger football game. Current milestone
(v0.7): a complete 11v11 match on a data-driven 4-3-3 formation -- 22
players (11 per team, 2 goalkeepers) with formation-role-aware team shape
(defenders hold depth, wingers stretch the field, forwards push forward and
give only limited defensive support), a relevance-scored player switch
(distance to ball *and* attacking/defensive positioning, not just
"closest"), gradual stamina fatigue (sprint speed/acceleration/close
control all degrade smoothly rather than cutting off), a light pass-
direction assist, and a hysteresis-stabilized `PossessionManager` for
22-player crowds -- all on top of the v0.6 personality system (every
character's traits still continuously bias AI decisions and drive
spontaneous events like Gold Ship getting bored and sitting down
mid-match), the v0.5 roster of 11 real 3D characters (v0.4's reusable
asset pipeline, each character now used once per team), the v0.3 team
match foundations, and the v0.2 dribble/pass/shoot core.

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
| `AIController` | `scripts/AIController.gd` | Stateless per-frame offense/defense/goalkeeper decision logic; role-category-aware team shape (v0.7) |
| `TeamController` | `scripts/TeamController.gd` | Owns one team's roster; runs `AIController` on every member except the human target; computes each team's shared ball-challenger/dangerous-opponent once per frame (v0.7) |
| `PossessionManager` | `scripts/PossessionManager.gd` | Single source of truth for who/which team currently has the ball, or if it's loose; hysteresis-stabilized for 22-player crowds (v0.7) |
| `FormationManager` | `scripts/FormationManager.gd` | Data-driven formations (4-3-3), role-labeled slots, normalized/mirrored per team; `role_category()` maps a specific slot to a generic GK/DEF/MID/FWD bucket (v0.7) |
| `BallController` | `scripts/BallController.gd` | Ball physics tuning, max-speed clamp, reset |
| `CameraController` | `scripts/CameraController.gd` | Follow camera, retargetable at runtime (player switching) |
| `MatchManager` | `scripts/MatchManager.gd` | Top-level orchestrator: spawns both squads, wires the above together, owns scoring/switching/restart; relevance-scored switch target selection (v0.7) |
| `AnimationController` | `scripts/AnimationController.gd` | Owns whichever visual (real model or placeholder) is displayed for one `FootballPlayer`; translates gameplay state into animation/procedural motion |
| `CharacterRegistry` | `scripts/data/CharacterRegistry.gd` | Data-driven map from a `PlayerData.visual_id` string to a character model scene |
| `PersonalityData` | `scripts/PersonalityData.gd` | Resource: one character's behavioral traits (confidence, discipline, aggression, etc.) -- separate from `PlayerData`'s football-ability stats |
| `PersonalityProfiles` | `scripts/data/PersonalityProfiles.gd` | Data-driven map from a character id to its `PersonalityData` (neutral default for unmatched ids) |
| `PersonalityEvent` / `PersonalityEvents` | `scripts/PersonalityEvent.gd`, `scripts/data/PersonalityEvents.gd` | Reusable "trigger → probability → condition → behavior → duration → cooldown" event definitions; `PersonalityEvents.gd` is the actual character-specific data |
| `PersonalityEventSystem` | `scripts/PersonalityEventSystem.gd` | Evaluates event definitions against per-player runtime state each frame; owned once by `MatchManager`, shared by both teams |
| `PersonalityContext` | `scripts/PersonalityContext.gd` | Per-frame bundle of match state (ball, mood, teammates, opponents, goals, possession) handed to event Callables |
| `MatchMood` | `scripts/MatchMood.gd` | Tracks "how eventful has the match been lately" for calm-dependent triggers |
| `PersonalityDebugOverlay` | `scripts/PersonalityDebugOverlay.gd` | F3-toggled developer overlay: controlled character's personality/AI/event/possession state |

**How switching works:** `PlayerController` targets exactly one
`FootballPlayer`. `TeamController` drives every player on its roster
*except* whichever one `PlayerController` currently targets. Switching is
just reassigning that target — the old player is automatically back under
AI control on the very next physics frame, no separate enable/disable logic
needed. As of v0.7, *which* teammate switching lands on is relevance-scored
(`MatchManager._select_switch_target`) rather than a plain next-index
cycle — see [11v11 Match & Team Shape](#11v11-match--team-shape-v07) below.

**How possession works:** Every `FootballPlayer` tracks its own
`has_possession` locally (ball within its control sensor, not on a
post-kick cooldown). `PossessionManager` polls all players each frame and
reports whichever one is closest to the ball as the current carrier (and
that player's team as the possessing team) — giving AI a single, cheap
question to ask ("does my team have the ball?") without changing how the
underlying dribble physics resolves a contested ball. As of v0.7 it also
applies a small hysteresis margin so a crowded 22-player box doesn't flip
the carrier every frame over sub-centimeter distance jitter between two
teammates who both happen to be in range.

## Project Structure

```
uma-soccer/
├── project.godot                 # Engine config (mobile renderer, autoloads)
├── export_presets.cfg            # Android export preset (arm64-v8a)
├── assets/
│   └── characters/
│       ├── CREDITS.md             # License/attribution for every character model -- read before adding assets
│       └── <11 model folders>     # tokai_teio, agnes_digital, tamamo_cross, oguri_cap, gold_ship,
│                                   # symboli_rudolf, air_groove, tm_opera_o, grass_wonder,
│                                   # mejiro_mcqueen, silence_suzuka -- each <name>.glb + extracted textures
├── scenes/
│   ├── Main.tscn                  # Entry scene: field, ball, players container, camera, UI
│   ├── Field.tscn                  # Ground, boundary walls, goals, goal triggers
│   ├── FootballPlayer.tscn         # Reusable player scene (spawned N times by MatchManager)
│   ├── Ball.tscn                    # RigidBody3D soccer ball
│   └── UI/TouchControls.tscn       # Joystick + PASS/SHOOT/SPRINT/SWITCH buttons
├── scripts/
│   ├── data/TestRoster.gd         # 11v11 4-3-3 test squads (PlayerData instances; 11 characters, 1x/team)
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
│   ├── JoystickBase.gd              # Virtual joystick drawing + input
│   ├── PersonalityData.gd            # Per-character behavioral-trait Resource
│   ├── data/PersonalityProfiles.gd   # character id -> PersonalityData
│   ├── PersonalityEvent.gd           # One event definition (trigger/probability/duration/cooldown/behavior)
│   ├── data/PersonalityEvents.gd     # The actual character-specific event list
│   ├── PersonalityEventSystem.gd     # Evaluates event definitions against runtime state each frame
│   ├── PersonalityContext.gd         # Per-frame match-state bundle handed to event Callables
│   ├── MatchMood.gd                  # "How eventful has the match been lately" tracker
│   └── PersonalityDebugOverlay.gd    # F3 developer overlay
├── tools/
│   └── inspect_character_model.gd / InspectCharacterModel.tscn  # Reusable pre-integration model inspector
└── tests/                        # Headless automated tests (see below)
    ├── gameplay_test.gd / GameplayTest.tscn          # FootballPlayer+PlayerController physics
    ├── main_scene_test.gd / MainSceneTest.tscn        # Goals, per-team score, restart, celebration
    ├── team_system_test.gd / TeamSystemTest.tscn      # Spawning, switching, possession, AI, GK
    ├── character_pipeline_test.gd / CharacterPipelineTest.tscn  # Registry, AnimationController, real-model gameplay parity
    ├── personality_test.gd / PersonalityTest.tscn      # Personality profiles, AI modifiers, event triggers/cooldowns/interruption
    └── v0_7_match_test.gd / V0_7MatchTest.tscn          # 22-player formation/roles, smart switching, role-based shape, fatigue, pass assist, possession hysteresis, 22-player goal/restart reset
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

## Team AI (v0.3, extended v0.7)

Simple, reactive, no lookahead or tactics -- the base decision loop from
v0.3 is unchanged; v0.7 (below) adds formation-role awareness on top:

- **Offense** (own team has the ball): the carrier dribbles toward goal and
  auto-shoots once in range; teammates push into space ahead of their
  formation slot and keep spacing from each other (repel when too close, so
  they don't bunch).
- **Defense** (opponent has it, or ball is loose): the team's nominated
  ball-challenger (nearest suitable teammate) presses the ball directly;
  everyone else holds a defensive-leaning position pulled back toward their
  own goal.
- **Goalkeeper**: stays on the goal line, tracks the ball laterally, steps
  out when the ball gets dangerously close, and instantly clears (shoots)
  the ball upfield if it ends up in the keeper's control rather than
  dribbling around the box. A keeper standing in the goal mouth also blocks
  shots simply through normal collision — no separate block-detection code
  needed.

## 11v11 Match & Team Shape (v0.7)

The match is now a full 11v11 on a data-driven 4-3-3: `FormationManager`
defines 11 role-labeled slots (GK, LB, CB, CB, RB, CM, CM, CM, LW, ST, RW)
as normalized coordinates, mirrored per team exactly like the old 3-slot
layout was. Adding "4-4-2", "3-5-2", "4-2-3-1", etc. later is purely a new
entry in `FormationManager.FORMATIONS` — nothing in `TeamController` or
`AIController` references a formation by name or assumes a slot count.

**Formation-role team shape.** Each `FootballPlayer` carries a
`formation_role` (e.g. `"CB"`, `"LW"`, `"ST"`) assigned at spawn.
`FormationManager.role_category()` maps that to a generic `GK`/`DEF`/`MID`/
`FWD` bucket that `AIController` reads for positional tendencies — never a
specific character:

| Situation | DEF | MID | FWD |
|---|---|---|---|
| Attacking-support advance distance | smallest (hold depth) | moderate (passing options) | biggest (attacking space) |
| Defensive fallback pull toward goal | strongest (recover hardest) | moderate (track dangerous areas) | weakest ("limited defensive support") |

Wingers (`LW`/`RW`) additionally stay pulled wide during an attacking move
instead of drifting toward the ball, so the team actually stretches the
field rather than everyone converging on one spot.

**Decision hierarchy**, per non-carrier player, in priority order:
1. **immediate danger / 2. possession opportunity** — the team's single
   `ball_challenger` (nearest suitable teammate to the ball, computed
   *once per team per frame* by `TeamController` rather than redundantly
   inside every player's own update — a real O(n·m) → O(n) win at 11-a-side)
   goes straight at the ball, whether it's loose or an opponent has it.
3. **defensive responsibility** — everyone else recovers toward defensive
   shape (role + discipline + a slight bias toward covering the most
   advanced opponent, `dangerous_opponent`, also computed once per team).
4. **attacking opportunity / 5. formation positioning** — when a teammate
   has the ball, everyone else pushes into useful space per the table above.

**Smart switching.** `MatchManager._select_switch_target()` scores every
other home player by distance to the ball *and* attacking/defensive
relevance (ahead of the ball when we have possession; goal-side of the ball
when defending), with a penalty for the goalkeeper outside real danger —
not simply "closest player." Cycling still lands on a real, distinct
teammate every time; it's no longer a fixed round-robin, so it can (and
should) revisit the couple of most relevant players in a phase of play
rather than touring the whole roster.

**Stamina fatigue** is now gradual, not a hard on/off cliff at 0 stamina:
sprint speed, acceleration, and close (dribble) control all scale smoothly
down as `current_stamina` drops (a fresh, full-stamina player behaves
exactly as before this system existed — every formula resolves to its old
fixed value at `stamina_ratio == 1.0`). AI positioning also gets a small
amount of random noise once a player is significantly fatigued ("decision
quality slightly" affected, per design) — never enough to stop them moving,
pressing, or defending.

**Pass assist.** `FootballPlayer.execute_pass()` still aims from the
player's own movement/facing direction by default, but if a teammate sits
roughly ahead of that aim (within a ~70° cone) and has a clear lane (no
opponent close to the straight line between them), the pass direction
blends toward them — a nudge, not FIFA-style auto-targeting. With no
suitable teammate (or none known at all — `FootballPlayer.teammates`/
`opponents` are only wired for informational pass-assist purposes, set once
by `MatchManager` after both squads spawn), the pass goes out exactly where
aimed, identical to pre-v0.7 behavior. AI ball-carriers still only
dribble + auto-shoot (deciding *when* to pass is not yet AI-driven — see
Roadmap).

**Debug overlay** (F3) now lists every one of the 22 players — id, name,
formation role, stamina, possession, active personality event — alongside
the detailed view of whichever one is currently controlled.

**Performance.** With 21 AI updates/frame (22 players minus the human) all
doing simple vector math, this is nowhere near CPU-bound at 60Hz — a 10
second idle 22-player match and repeated headless test runs show no
slowdown. The one concrete algorithmic waste found and fixed was the
per-player-redundant ball-challenger/dangerous-opponent scan noted above.
Draw calls / skinned-mesh bone counts (noted since v0.5's roadmap) remain
the more likely real bottleneck on an actual Android device, but that
needs on-device or rendered profiling this headless test environment can't
do — see Roadmap.

## Personality System (v0.6)

Every character has a `PersonalityData` profile (13 traits, 0-100:
confidence, discipline, aggression, competitiveness, playfulness,
impulsiveness, composure, teamwork, stamina_management,
tactical_awareness, showmanship, laziness, risk_taking) — a completely
separate axis from `PlayerData`'s football-ability stats. A character can
be technically excellent but chaotic, or average but disciplined; the two
never determine each other. These are this fan project's own
interpretations of each character's personality, not claims about
official game mechanics — see each profile's comment in
`scripts/data/PersonalityProfiles.gd` for the reasoning, including an
explicit note on Mejiro McQueen (no behavior brief existed for her, so
her profile is this project's own extrapolation).

**Personality continuously affects AI decisions** (`AIController` reads
`player.personality`, no per-character branches — every character's data
alone accounts for the differences):

| Trait(s) | Effect |
|---|---|
| aggression, risk_taking | Bigger forward-run advance distance when supporting an attack |
| aggression, risk_taking, impulsiveness / stamina_management, composure | Lower/higher sprint-distance threshold (sprints more eagerly, or waits until closer) |
| confidence, risk_taking | Longer/shorter willing shoot range |
| discipline | How far the defensive fallback shape pulls back toward goal vs. holds the formation slot |
| teamwork | Spacing radius kept from teammates (tighter with poor teamwork = more bunching) |

**Personality events** (`scripts/PersonalityEventSystem.gd` +
`scripts/data/PersonalityEvents.gd`) are the reusable "trigger →
probability → condition → behavior → duration → cooldown" system for
spontaneous, character-specific moments. Every event: has a fixed
duration and cooldown, is instantly interruptible (switching to or
restarting clears it — see `FootballPlayer.reset_intent()`), never
touches possession/goal-detection state (it only ever writes to the same
`move_input`/`sprint_requested` intent fields AIController already uses),
and **only ever runs for AI-controlled players** — `TeamController`
excludes the human target from personality events the exact same way it
excludes them from `AIController`, so an event can never steal control
mid-action from whoever you're playing as.

Current events:

- **`gold_ship_bored_sit`** — during a calm moment, away from the ball:
  stops moving, sits down (new "sitting" animation state) for ~5s.
  "Gold Ship got bored and sat down midfield," rarely (cooldown 75s) —
  not "Gold Ship is permanently useless."
- **`gold_ship_wander_off`** — during a calm moment: wanders a few meters
  from her current spot instead of holding position.
- **`gold_ship_sudden_sprint`** — the ball is in moderate range: suddenly
  sprints for it regardless of tactical sense.
- **`opera_o_showboat`** — dribbling in the attacking third: a brief
  showy hesitation (still advancing toward goal, just not sprinting)
  before continuing.
- **`agnes_excited_near_teio`** — something exciting just happened and
  Tokai Teio is nearby: a brief excited reaction.
- **`exhausted_ease_off`** — trait-gated (poor `stamina_management`),
  any qualifying character: eases off the pace when exhausted and the
  match is calm, rather than continuing to sprint carelessly.
- **`lost_possession_frustration`** / **`missed_shot_reaction`** —
  trait-gated (low `composure`, or low `confidence`/`composure`): a brief
  frustrated pause after losing the ball or a shot not immediately
  working out. High-confidence characters skip this entirely, i.e.
  "recover faster from mistakes" by not pausing at all.

Goal reactions are a separate, simpler direct path (not the probability
system, since a goal is already a discrete match event, not something to
poll for): the scoring team gets `play_celebration()` by default, upgraded
to a `victory_pose` for high `showmanship` or `excited_reaction` for high
`playfulness`; the conceding team gets a `frustrated_reaction` for low
`composure`, otherwise no special reaction.

Adding a new character-specific behavior later is one more
`PersonalityEvent` entry in `PersonalityEvents.build_events()` — nothing
about `PersonalityEventSystem`, `AIController`, or `FootballPlayer` needs
to change.

**Debug overlay:** press **F3** in-game (or in the editor) to toggle a
developer overlay showing the controlled character's name, personality
traits, possession state, active personality event and time remaining,
and a compact list of which AI players currently have an event active.
`MatchManager.force_personality_event(player, event_id)` forces a specific
event immediately (bypassing its probability roll) for testing without
waiting on RNG — e.g. `force_personality_event(gold_ship, "gold_ship_bored_sit")`.

**Roster note:** Gold Ship was moved from goalkeeper to an outfield
defender in v0.6 (Symboli Rudolf took the gloves instead). Her chaotic
personality events are gated safely regardless, but having them
originally apply to the one player who *must* stay near goal was an
unnecessary risk — disciplined Rudolf is also a better thematic fit for
goalkeeper than Gold Ship.

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
  true for every model integrated so far — a lightweight procedural
  fallback (speed-scaled bob/lean while moving, a dip pulse on pass/shoot,
  a hop-spin on celebration, a lunge-tilt on a won tackle) keeps the
  character visibly alive. `FootballPlayer` never knows which path is
  active.
- **T-pose fix:** every currently-integrated model ships in its raw bind
  pose (arms out horizontally) with no clips, so on the no-real-clips path
  `AnimationController._fix_tpose_arms()` rotates just the upper-arm bone
  on each side (`Arm_L`/`Arm_R`, found by name) from its T-pose direction
  down to a relaxed hang — the elbow/wrist/fingers are children of that
  bone and follow automatically via normal skeleton hierarchy, so nothing
  else needs to be touched. Legs are already in a natural standing pose at
  rest and are left alone. This is a static pose correction, not a walk/
  run animation — see Roadmap for real gait animation, deferred to the
  dedicated visual pass.

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
godot --headless --path . tests/PersonalityTest.tscn
godot --headless --path . tests/V0_7MatchTest.tscn
```

Each prints `[PASS]`/`[FAIL]` per check and exits non-zero on any failure.
`team_system_test.gd` covers spawning, team assignment, formation
positioning, switching, possession transfer, AI movement, and goalkeeper
behavior; `character_pipeline_test.gd` is data-driven over every
`CharacterRegistry`-registered model (11 as of this milestone; a future
addition gets the full battery automatically, no new test code) covering
registry lookup, `AnimationController`'s real-model and
placeholder-fallback paths (scale auto-fit, team-tint behavior, all
states/actions, real-vs-procedural animation detection), gameplay parity
with the placeholder, full-match spawn placement, and player switching /
AI handoff / camera retargeting specifically for a real-model character;
`personality_test.gd` covers profile validity for every roster character
(distinct, non-identical trait sets), `AIController` modifier formulas
(advance distance, sprint threshold, shoot range, defensive pull, spacing
radius all responding to personality, isolated per-trait), event gating
(id-gated and trait-gated), probability-driven triggering, cooldown
enforcement, duration/auto-expiry, interruption via `reset_intent()`,
Gold Ship's bored/sit event specifically, and that player switching, match
restart, and goal scoring all continue to behave correctly during and
after an active personality event; `v0_7_match_test.gd` is the newest
suite, covering everything that changed or scaled up in v0.7: 22-player/
11-per-team/2-goalkeeper spawn with every formation slot's role assigned,
the 4-3-3's slot/role-category data itself, two on-pitch instances of the
same character (e.g. both teams' Gold Ship) behaving fully independently
(distinct stamina, distinct personality-event cooldowns), the smart-switch
scoring formula preferring attacking/defensive relevance over raw distance,
role-based attacking/defensive shape differences (winger vs. central
midfielder, ball-challenger vs. non-challenger defender), goalkeeper
movement staying smooth (no teleporting) when suddenly threatened, gradual
stamina-fatigue speed scaling with recovery, pass-assist direction logic,
an AI-controlled forward actually scoring through normal decision-making
with 22 players on the pitch, `PossessionManager`'s hysteresis margin
holding an established carrier through jitter while still legitimately
handing off on a genuine change, and the full 22-player goal/restart reset
(formation return, both goalkeepers back on their line, cleared personality
events, retained camera target); the other two re-validate the full v0.2/
v0.3 mechanics (dribble, pass, shot power/clamp, goal scoring, celebration,
restart) now running with real characters filling the entire pitch.
345 assertions total across all six suites, all passing (`character_pipeline_test.gd` also verifies the T-pose fix below: the diagnostic flag plus the actual posed arm-bone geometry, per model).

## Current Feature Set (v0.7)

- Full 11v11 match on a data-driven 4-3-3 formation — 22 players, 11 per
  team, exactly 2 goalkeepers, every non-GK slot assigned a specific role
  (LB/CB/RB, CM, LW/ST/RW) that generically (never per-character) biases
  `AIController`'s team shape
- All 11 currently-integrated character models are used once per team (22
  player slots from 11 real characters), each a fully independent
  `FootballPlayer`/`PlayerData`/`PersonalityData` instance — verified by
  test that two on-pitch copies of the same character never share stamina,
  cooldowns, or event state
- Relevance-scored player switching (distance to ball + attacking/
  defensive positioning), a light pass-direction assist toward an open
  aligned teammate, gradual stamina fatigue instead of a hard cutoff, and
  a hysteresis-stabilized `PossessionManager` so a crowded 22-player box
  doesn't flip the ball carrier on sub-frame jitter
- 11 real 3D characters integrated (all glTF binary, CC BY 4.0, see
  `assets/characters/CREDITS.md`) via the reusable, data-driven pipeline
  (`CharacterRegistry` + `AnimationController`). Every addition after the
  first required zero changes to `FootballPlayer`/`AIController`/
  `PlayerController`/`TeamController`/`PossessionManager`/
  `BallController`/`CameraController`/`MatchManager` — purely data (one
  registry entry, one `visual_id` assignment, one credits block each)
- The placeholder capsule no longer appears in a normal match — every one
  of the 22 slots is a real character — though it's still exercised
  directly by the test suite and used automatically for any `PlayerData`
  without a `visual_id`
- Automatic scale normalization (measured, not guessed) and orientation
  handling for downloaded models with inconsistent conventions — verified
  per-model via geometry (eye vs. hair mesh position), not assumed from
  one model to the next
- Procedural fallback animation (bob/lean/pulse) for the common case of a
  downloaded model with no animation clips, with a clean path to real
  clips later via keyword-matched state/action names
- Goal celebrations trigger automatically on the scoring team for every
  character, real or placeholder
- Every character now also has a `PersonalityData` profile (13 behavioral
  traits, independent of football stats) that continuously biases
  `AIController`'s decisions — advance distance, sprint eagerness, shoot
  range, defensive discipline, and teammate spacing all vary by character
  instead of being identical across the roster
- A reusable `PersonalityEventSystem` drives spontaneous,
  character-specific moments (Gold Ship getting bored and sitting down or
  wandering off, Opera O showboating in the attacking third, Agnes
  reacting to Tokai Teio nearby, exhausted characters easing off, low-
  composure/confidence characters briefly reacting to a lost ball or
  missed shot) — every event has a duration and cooldown, is instantly
  interruptible, never touches possession/goal state, and only ever runs
  on AI-controlled players so it can never steal control from whoever
  you're playing as
- Goal reactions are personality-driven too: high-showmanship characters
  get a `victory_pose`, high-playfulness characters get an
  `excited_reaction`, low-composure characters on the conceding side get a
  `frustrated_reaction` — everyone else keeps the default celebration (or
  no special reaction when conceding)
- An F3 developer overlay shows the controlled character's personality
  traits, AI/possession state, and active event, and
  `MatchManager.force_personality_event()` lets any event be forced
  immediately for testing without waiting on its probability roll
- Gold Ship was moved from goalkeeper to outfield defender (Symboli
  Rudolf now keeps goal) so her chaotic events can never affect the one
  position that must stay disciplined near the goal line

## Roadmap Ideas (for expanding into a full game)

- Integrate the 5 models that couldn't be downloaded this round (Super
  Creek, Satano Diamond, Twin Turbo, Meisho Doto Halloween, Calstone
  Light O — see `assets/characters/CREDITS.md` for why) once re-shared in
  a way this environment can fetch. Twin Turbo and Meisho Doto also have
  personality briefs on file (extreme sprint tendency / poor stamina
  management for Twin Turbo; nervous hesitation with bursts of
  determination for Meisho Doto) that were deliberately **not**
  implemented yet, per instruction, since `PersonalityProfiles`/
  `PersonalityEvents` shouldn't be authored for a character whose actual
  model isn't in the project — the architecture (data-driven profile map
  + reusable event system) needs nothing new to support them once their
  models arrive
- AI passing decisions (AI ball-carriers still only dribble + auto-shoot;
  v0.7 only added *direction* assist to the human PASS button, not an AI
  decision of *when* to pass)
- Additional formations (4-4-2, 3-5-2, 4-2-3-1, ...) and in-match tactic
  switching — `FormationManager`/`AIController` are already built
  formation-agnostic for this, so it's purely new formation data plus a UI
  to pick it
- Fouls, offsides, substitutions, a match timer, possession stats (all
  explicitly out of scope for v0.7, per instruction)
- Ball trapping/first-touch skill mechanics
- Real animation clips (walk/run/kick cycles) once available, replacing the
  procedural fallback per character
- Stadium environment, crowd, audio
- On-device (or at least rendered, non-headless) performance profiling —
  draw calls and skinned-mesh bone counts couldn't be measured in this
  headless test environment and are the more likely real bottleneck on
  Android at 22 characters than any of the v0.7 AI/logic changes
- Bone-count optimization pass on skinned character models for Android
  (each model's ~400+ joints are mostly cosmetic cloth/hair physics chains
  that currently just sit in bind pose; fine with 22 on screen so far in
  headless testing, worth profiling on-device)
