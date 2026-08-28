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
| `TeamPlan` | `scripts/TeamPlan.gd` | **Team level (v0.8.3).** One per team, ticked once per frame before any player: decides the attacking/defending phase as a continuous scalar and *allocates* every player a single named duty (contest / press support / short support / wide / run in behind / mark / cover space) |
| `BallContest` | `scripts/BallContest.gd` | **(v0.8.4)** The actual contest for the ball. A challenger who stays in a genuine challenge long enough wins it outright -- scored on proximity, how hard they are closing, how exposed the carrier is (a stationary carrier is the most vulnerable), and defensive/dribbling stats plus personality. Evaluated once per frame by `PossessionManager` |
| `PassEvaluator` | `scripts/PassEvaluator.gd` | **(v0.8.3)** Scores every reachable teammate on openness, lane, progression, distance, pressure relief and role; solves the launch speed a pass needs from the measured ball-roll model. Shared by the AI carrier and the human PASS button |
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
| Switch   | Tap Tab             | Tap SWAP button          |
| Restart  | Tap R               | (desktop-only for now)      |

Shooting is charge-based: the longer Space/SHOOT is held before release, the
harder the shot (up to a capped max speed) -- the SHOOT button itself fills
in with a charge ring while held, on top of the same mechanic. Passing is a
fixed, lower-power tap. Both fire in the direction you're currently moving,
or the direction you're facing if you're standing still. Switch cycles
through your team's 11 players; the controlled player has a glowing ring
underfoot and a name label overhead (the only player on the pitch that gets
one -- see the HUD section below) so it's always obvious who you're playing
as.

### Mobile HUD & true multitouch (v0.8)

`scripts/HUD.gd` (`scenes/UI/HUD.tscn`) owns every on-screen control plus a
single central per-finger input dispatcher, replacing the old
Button/gui_input-based touch controls. Godot's default
"emulate_mouse_from_touch" setting (now disabled in `project.godot`)
resolves every touch through *one* synthesized mouse pointer, which is why
the joystick and action buttons used to fight each other -- holding SHOOT
while dragging the joystick was effectively "one finger, two jobs". Now
each `InputEventScreenTouch.index` (a real, independent finger) is bound
exclusively to whichever control it first touches down on
(`scripts/ui/VirtualJoystick.gd` / `scripts/ui/TouchButton.gd`, both
self-drawing `Control`s that never touch Godot's `Button`/mouse-emulation
path), so the joystick and any combination of SHOOT/PASS/SPRINT can be held
at once by separate fingers. Desktop/editor testing still works via the
mouse, handled through the same dispatcher under a reserved finger index.

The HUD layout is a top bar (score + match timer), a top-left panel
(controlled character's name + a stamina bar that tints gold while
sprinting), a large joystick in the bottom-left corner, and a SHOOT/PASS/
SPRINT thumb cluster in the bottom-right corner, all anchored close to the
screen edges for one-handed reach.

## Ball Control / Dribbling

The ball is never attached to the player. While the ball is within close
range, a spring-style force gently steers it to a point just ahead of the
player's facing direction each physics frame — the ball still fully obeys
physics (collisions, bounces, momentum) on top of that force. Turning
sharply at speed, sprinting, or passing/shooting all break this steering
(with a brief cooldown after a kick before control can be regained), so
losing the ball on a bad touch is a real possibility, not just cosmetic.

**Contested-ball fix (v0.8).** `has_possession` is a purely local flag (in
sensor range + no cooldown), so two opposing players standing in the ball's
control range used to both apply this steering force every frame --
opposing pulls and dampers that cancel out at equilibrium, freezing the
ball in place until one side physically shoved it clear. `PossessionManager`
already elects one carrier generically (closest, with hysteresis so it
doesn't flicker); now only that elected carrier actively steers the ball --
see `FootballPlayer._update_possession()`. The loser still physically
collides with the ball via normal capsule/rigidbody contact, so a contest
still feels physical instead of the ball going inert.

## Team AI (v0.3, extended v0.7, v0.8)

Simple, reactive, no lookahead or tactics -- the base decision loop from
v0.3 is unchanged; v0.7 added formation-role awareness; v0.8 makes the
formation targets themselves alive:

- **Ball-reactive team shape (v0.8).** `FormationManager.get_dynamic_position()`
  continuously shifts each player's formation target with the ball's
  current location (weighted by role -- defenders barely shift
  longitudinally but stay compact laterally; forwards/midfielders shift
  more both ways), instead of a permanently fixed coordinate. A static
  target was the actual cause of players "not moving" -- a defender whose
  slot happened to be far from wherever play currently was just sat at
  that exact spot indefinitely.
- **Support spacing (v0.8, replaced in v0.8.3).** Spacing used to be a
  mutual repulsion between nearby teammates plus a minimum distance from
  the ball. v0.8.3 replaced that with allocated duty geometry (below);
  repulsion survives only as short-range collision avoidance.
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

### Team level -> player level -> ball carrier (v0.8.3)

Before v0.8.3 there was no team layer at all: every player independently
re-derived "what phase are we in / should I go at the ball / where do I
stand" from the same global inputs. That is why 22 players behaved like 22
agents reacting to one ball -- nothing anywhere *allocated* a
responsibility, so any job that looked attractive to one player looked
equally attractive to every similar player at once.

- **Team level (`TeamPlan`, once per team per frame).** `attack_intent` is
  a continuous scalar from -1 (fully defending) to +1 (fully attacking)
  that *slews* rather than switching (`INTENT_SLEW_RATE`), so a change of
  possession moves every downstream target smoothly instead of teleporting
  it. It then fills a fixed list of duty slots -- one CONTEST, at most one
  PRESS_SUPPORT, at most `MAX_RUN_BEHIND` runners, `MAX_SUPPORT_WIDE` wide
  players, up to `MAX_MARKERS` markers, everyone else COVER_SPACE. Those
  ceilings *are* the "not every player should contest / make the same run"
  rule, expressed structurally. Assignment carries a retention bonus so
  near-equal candidates don't trade jobs on positional noise.
- **Player level (`AIController._duty_target`).** One duty becomes one
  position. Every branch derives from the same continuous inputs (the
  smoothed play position, `attack_intent`, the player's own formation
  anchor), so a duty handover moves a target a few metres rather than to
  the opposite side of the pitch.
- **Ball carrier (`AIController._decide_possession_action`).** A
  deterministic hierarchy -- shoot if the chance is genuinely good, else
  pass if `PassEvaluator`'s best option beats a threshold that falls under
  pressure and the longer the ball is held and rises with clear grass
  ahead, else carry. Carrying is the default, not the leftover.

Two signals are deliberately kept separate and it matters: whether the ball
is under our control *this instant* (reactive -- decides who chases a loose
ball) versus whether we are the team attacking (a shape question, which
uses `PossessionManager`'s sticky signal so a one-frame loose touch never
dissolves the attack). Team shape also reacts to `TeamPlan.shape_ball_pos`,
a smoothed "where is play" point, rather than to a contested rigid body's
frame-to-frame jitter -- only the player actually going to win the ball
uses its true position.

### Winning the ball back (v0.8.4)

Before v0.8.4 there was **no tackle mechanic at all**. Possession went to
whichever player with the ball inside their control radius happened to be
closest to it, and two facts made that close to unwinnable for a defender:
the carrier's dribble spring pins the ball 0.62m in front of them, and both
players are 0.4m-radius capsules, so a challenger's centre can never get
nearer than 0.8m to the carrier's. Outside an almost exactly head-on
challenge, the carrier was closer to the ball by construction, forever.
Measured in an isolated 1v1: a challenger hand-steered straight at the ball
beat a *stationary* carrier from 7 of 8 approach angles, but the real AI
challenger managed only 4 of 8 -- because `PRESS_CONTACT_RANGE` blended its
target toward the goal across the final 1.6m, so it arced past a ball that
was not moving.

Possession now changes hands two ways. The old geometric election still
applies (running onto a loose ball, winning a head-on 50/50), and on top of
it `BallContest` accumulates a challenge while the conditions for one hold
and decays it when they stop. It is deliberately **not** random: the
outcome is a readable consequence of what both players did. A completed
tackle knocks the ball clear and puts the loser on a short cooldown -- and
because the dribble spring is gated on that same cooldown, the ball is
genuinely free for a moment rather than being pulled straight back.

The carrier reacts to it too: an AI player who can feel a tackle coming
lowers its own bar for releasing the ball, which is both realistic and what
keeps passing frequency up now that carriers can be dispossessed.

### Staying in the play (v0.8.4)

Measured over a live match: in the second after kicking, a player who had
**shot** closed 0.86m back toward its own formation slot, while a player
who had **passed** moved 0.92m further away. The reported "shoots, then
immediately returns to formation" was real and specific to shooting -- a
shot hands the ball to the keeper, which flips team possession, which slews
`attack_intent` negative and drops the entire forward line, including the
player standing where a rebound would land.

`FootballPlayer.post_action_involvement()` now decays from 1 to 0 across
`POST_ACTION_WINDOW` after any kick, and `AIController` blends in a
follow-up position by that weight: a shooter holds a rebound position off
the goal, a passer continues its run past the ball. Because the weight
decays rather than expiring, the player drifts back into normal shape
instead of snapping out of it.

### Stable possession phases (v0.8.5)

The v0.8.4 playtest reported that the whole team still reorganised on
individual ball touches: an opponent touches it and the side flips to
attack, loses it and everyone reassembles, touches it again and the cycle
repeats -- visible as players reversing direction together.

Instrumenting the full chain (contact -> instantaneous possession ->
sticky team possession -> `attack_intent` -> duty allocation -> movement
target -> observed reversal) over three 60-second all-AI matches showed the
description was not literally what was happening, and pointed at something
more specific:

* The tactical phase was **not** flipping many times a second. It changed
  0.02-0.22 times per second, median dwell 0.42-3.97s.
* But **the number of duty-set flips equalled the number of phase changes
  exactly in every run** (1/1, 9/9, 13/13).
* On the single frame of each flip, players who received a new duty saw
  their movement target jump **8.10m, 9.47m and 10.27m** on average,
  against a **0.01-0.13m** baseline on every other frame.
* 30-45% of all movement reversals landed within a second of a phase change.

So v0.8.3 had made the *depth* layer continuous (`attack_intent` slews, and
measured settled at |intent| > 0.9 for 77-98% of frames) but left the
**duty allocation** layer -- fed by the same phase signal -- as a hard
binary switch between two disjoint slot sets. One frame reassigned all ten
outfielders at once. That switch, not the phase rate, was the earthquake.

Four changes:

1. **Named possession phases.** `PossessionManager` classifies each instant
   as `LOOSE`, `CONTESTED` or `SETTLED`, and confirms a change of team
   possession on a two-tier rule: an uncontested hold claims the phase in
   0.30s, a hold still being fought over needs 0.85s. Coming out of a
   challenge *with* the ball is a turnover; still being in the challenge is
   not. A loose ball now *decays* a pending claim instead of resetting it,
   so a real turnover whose first touch bobbles still converges while a
   ball that keeps breaking loose never does.
2. **Continuous duty allocation.** Slot *counts* come from `attack_intent`
   rather than a boolean, so the duty set migrates across the ~1.2s intent
   ramp instead of switching on one frame, and the team genuinely holds a
   transitional shape in between -- one runner still committed, one marker
   already picked up.
3. **A rate limit on the aim point** (`TARGET_MAX_SPEED`). The existing
   exponential filter is a low-pass, not a limit: fed a 10m step it still
   moved the point at ~35 m/s. The cap sits well above sprinting speed, so
   it only engages on a discontinuity a player could not have followed.
4. **Shape-holders track play while attacking.** `_cover_space_target`
   blended only 0.12 toward play whenever `attack_intent` was positive, so
   a player holding shape sat on a near-static formation anchor while their
   own team had the ball -- an attacking-phase bug specifically, and why
   midfielders measured 88-95% motionless with the ball over 20m away.

Measured after: target jump on a phase-change frame **6.38m -> 0.26m**;
share of the outfield reassigned per phase change **~57% -> under 1%**;
reversals landing within half a second of a phase change **30% -> 10-16%**;
the project's own direction-change guard **0.196 -> 0.105 per player per
second** (threshold 0.15). Total movement roughly doubled, because the
midfield is no longer parked.

### Off-ball intelligence, aimed passing, play continuation (v0.8.6)

v0.8.5 made the team's SHAPE stable. The v0.8.6 playtest report was about
what the players were then doing inside that stable shape, which was mostly
nothing: forwards and midfielders stood still off the ball, and anyone who
passed or shot turned for home. Five measured root causes, all structural
rather than tuning:

1. **Post-action was a blend fighting an allocation, not a state.** The
   instant a player kicked, `TeamPlan` re-allocated them: they are 0m from
   the ball, which scores badly for `SUPPORT_SHORT` (it wants ~9m) and is
   explicitly penalised for `RUN_BEHIND`, so they fell through to
   `COVER_SPACE` -- the leftover -- whose target was 70-88% of a *static*
   formation anchor. `post_action_involvement()` then spent 2.5s partially
   cancelling a "go home" instruction the same system had just issued.
   There is now a real allocated `Duty.FOLLOW_UP`, decided before the
   attacking slots, so the instruction is never issued in the first place.

2. **Four to six outfielders per side had no job at all.** The attacking
   slot ceilings totalled six (`SUPPORT_SHORT` 2 + `RUN_BEHIND` 2 +
   `SUPPORT_WIDE` 2) against ten outfielders. The ceilings are correct --
   not every forward should make the same run -- but there was no second
   tier of off-ball work beneath them, so "not selected for a run" and
   "nothing to do" were the same thing. New `Duty.PUSH_UP` (advance into
   your own channel ahead of the ball and hold a lane, lanes fanned apart
   so several advancing players are several options rather than a crowd).

3. **Shape-holders could not move sideways.** `_cover_space_target`'s
   attacking branch held `shape.z` fixed, so play switching flanks -- the
   most common thing in a football match -- moved their target by exactly
   zero. It now tracks play in both axes, at a much higher weight
   (0.20-0.70 rather than 0.12-0.31), bounded by `COVER_MAX_DRIFT`.

4. **The human PASS button barely consulted the player's aim.**
   `_process_pass_input()` called `execute_pass()` with no `forward_axis`
   and no plan, so `W_PROGRESSION` -- the largest weight at 0.34 -- scored
   a flat **zero** on every human pass; `W_ALIGNMENT` was 0.08, so where
   you pointed was ~8% of a decision owned by openness, distance and role.
   And with nothing inside the 3.5-14m band it fired
   `PASS_SPEED_MAX * pass_speed_scale` = up to **12.1 m/s** against a
   `SHOT_SPEED_MIN` of **12.5** -- the reported "PASS behaves like a weak
   shot" was a full-power blind punt. Aimed passes now score on a separate
   weighting where alignment dominates (0.60, on the raw dot product), get
   the team context the AI gets, use a 2-18m band, and fall back to a 7 m/s
   knock into space.

5. **AI shots were unaimed and their power was inverted.**
   `execute_shot()` took no direction, so the kick fell back to
   `_get_aim_direction()` -- which is `move_input`, and that is
   `Vector2.ZERO` for any carrier inside its arrive radius, leaving the
   shot to go wherever `_facing_angle` last pointed. Power was
   `0.45 + range_quality*0.55`, and `range_quality` is highest when
   *closest*, so the AI struck hardest from 2m and softest from 13m. Shots
   are now aimed at a chosen point inside the real goal mouth, away from
   the keeper, with power solved from the distance.

Two further defects fell out of the same investigation:

**There was no model of the pitch.** `FIELD_HALF_LENGTH` (26) is a
formation-layout box; `Field.tscn` puts the goal mouth at **x = ±29** and
the perimeter wall at **±35**, so every attacking decision aimed at a point
3m *in front of* the goal, and the 6m strip behind each goal was
unmodelled. Worse, the shot angle test used
`absf(goal_dir.dot(forward_axis))` -- so a shot pointing directly *away*
from the attacking direction, which is exactly what a shot from behind the
net looks like, scored a perfect 1.0. That is the reported "opponent moved
behind the goal and tried to score from there". `FormationManager` now
carries the real geometry (`GOAL_LINE_X`, `GOAL_HALF_WIDTH`,
`clamp_to_playable`, `is_behind_goal_line`), the angle term is signed, and
a player behind the goal line does not shoot.

**A carrier was being physically braked by the ball.** A `CharacterBody3D`
cannot push a `RigidBody3D` -- Godot stops it dead -- and the player's
`collision_mask` includes the ball's layer. Measured in an isolated 1v0, a
player told to sprint in a straight line with the ball at their feet
reached **0.9 m/s** against a sprint speed of 8.5. Dribbling was not
carrying the ball, it was grinding along behind an obstacle. Separately the
dribble damper opposed the ball's *absolute* velocity, so it fought the
motion the spring was producing (carrying the ball at a sprint demanded
~30 m/s² of damper against a total budget of 18) -- which is why
`dribble_distance_sprint` had no observable effect at all, and why the ball
sat *nearer* the player at a sprint (0.74m) than standing still (0.89m).
Players now shove the ball they run into, the damper is relative to the
player, and no player can climb the ball. Neither collision shape changed
size.

### Touch-based close control, passing lanes, real pass weight (v0.8.7)

v0.8.6 fixed what the AI *decides*. The v0.8.7 report was about how the
football itself *feels*: the ball read as heavy and welded to the dribbler,
the PASS button behaved like a weak kick, and teammates moved constantly
without ever offering a pass. Each turned out to be a specific, measurable
defect rather than a matter of tuning.

**The dribble leash was shorter than the player's own body.** This is the
whole "PUSH BALL -> CHASE BALL -> PUSH BALL" complaint, and it is geometry.
A player capsule has radius **0.40** and the ball had radius **0.35**, so
the closest their centres can ever be is **0.75m** -- but `dribble_distance`
asked for the ball to sit **0.62m** ahead, a point *inside the player's own
capsule*. The ball therefore never sat in front of the dribbler at all; it
was permanently jammed against them and shoved along. Measured (120-frame
runs, everyone else parked): sprinting, the ball sat at 0.86m -- i.e. at the
contact floor -- and the carrier could only reach **1.5 m/s**, because they
were pushing the ball with their body; at a walking pace the ball was
knocked away instead and possession survived **31 of 120 frames**. There was
no regime in which a player moved at pace *and* kept the ball. The ball is
now **0.16m** radius (it was also ~3x oversized on screen: 0.70m across
against a 1.6m player), and both leashes sit clearly outside the resulting
0.56m contact floor.

**The close-control sensor was narrower than the leash**, so a carrier
knocked the ball out of their own possession radius. `apply_player_data()`
overwrote whatever `FootballPlayer.tscn` said with a hardcoded 0.95-1.35m,
making the scene value dead configuration; the sensor is now derived from
the leash it has to contain.

**Close control is now touches, not a spring.** The old model applied a
force toward a point ahead of the player *every frame, along every axis* --
permanent attachment by construction, with no independent ball motion left
to feel. A dribble is now discrete touches that knock the ball ahead, plus a
sideways-only shepherd; between touches the ball simply rolls. A ball that
falls behind is recovered by touching *more often*, never harder, so a touch
stays bounded below the weakest pass and can never read as a kick. A change
of direction re-touches early, which is what makes a fake work: measured,
the ball leaves a 90-degree turn **100 degrees** off its old heading with
possession held through it.

**Pass weight was solved from the lead point instead of the receiver.** A
feedback loop running the wrong way: a receiver moving *toward* the passer
collapsed the solved distance, so the ball was struck softer, so it flew
longer, so it was led even shorter. Measured on six identical 9m passes, the
solved distance fell to **4.3m** and the ball was struck at 4.3 m/s, rolling
5.7m -- dying three metres short of a teammate the player had aimed directly
at. That is the "PASS behaves like a small kick" report. Weight now comes
from the true distance and the lead is bounded to a fraction of the pass;
the same six passes are now struck at a consistent **8.1-8.3 m/s** and all
reach.

**No support duty had any concept of a passing lane.** `SUPPORT_SHORT`,
`SUPPORT_WIDE`, `PUSH_UP` and `RUN_BEHIND` each derived a point from
formation slot, ball position and forward axis, then stood on it whether or
not an opponent was planted between that point and the ball. Measured over a
live match, **47%** of teammates inside passing range were screened -- about
half the "options" on screen were not options. Support duties now search a
small ring around the duty's own target for a spot that is genuinely
available, weighing lane, space, range, progression, spacing and how far it
drags the player off shape.

Measured after (35s AI-vs-AI): teammates with a clear lane **53% -> 65%**;
midfielders more than 20m from the ball still adjusting **12-30% -> 85%**;
four-or-more teammates bunched within 6m of the ball on **2%** of carrier
frames; turnovers **48/min -> 56/min**; and the human-monopoly assertion
that had been failing since v0.8.6 (80%) now passes at **44-74%**, with
opponent challenges peaking at the full 0.80 needed for a tackle.

One idea was tried and **reverted, with its result recorded in the code** so
it is not silently re-attempted: having a pressing defender aim at an
interception point ahead of the ball. Against a *dribbled* ball that lead
lands past the carrier, so defenders ran around their man instead of
engaging -- turnovers collapsed **54/min -> 12/min** and a human's
possession share went 44% -> 96%. Pressure comes from getting tight, not
from outguessing the carrier.

Three older assertions were repaired rather than relaxed, because each was
passing for a reason that had stopped being true: one measured the sprint
leash while the player was pinned against a touchline collider; one inferred
"the AI passed" from the carrier merely *losing* the ball, which the old
broken close control did constantly; and one asked the AI to pass while
facing thirty metres of completely empty grass, with no opponent anywhere in
the scene.

### Football foundation: touches, reach, and pass weight (v0.9.0)

A human played v0.8.8 and reported three things the automated suite could
not see. All three were real, and in each case the tests were measuring the
wrong quantity rather than lying.

**"AI still steals from unrealistic distances."** v0.8.8's suite asserted
that acquisitions happen inside `POSSESSION_CONTACT_RADIUS` and that kicks
come from inside challenge range, and both were true. Neither measured the
frame `has_possession` actually flips. Measured there, **42% of all
acquisitions were outside the 1.20m gate, out to 1.97m** -- because the gate
had an escape hatch:

```gdscript
if not has_possession and ball_gap > possession_contact_radius and _contest_win_timer <= 0.0:
    return
```

`_contest_win_timer` was set by `notify_possession_won_from_opponent()`,
which exists for a tackler collecting the ball they just poked away. But
`PossessionManager` calls that on EVERY opponent carrier change, so every
player who ever became carrier got 0.6s with the contact requirement
switched off entirely. The notification is now split: a plain possession-won
event is a REACTION (it plays an animation), and `notify_contest_won()` --
called only by `BallContest` on a real tackle -- is the one that grants the
exemption. The exemption also STRETCHES the radius to `CONTEST_WIN_REACH`
(1.70m) rather than removing it.

Retention had the same shape of bug with no bound at all: `POSSESSION_GRACE`
plus the control radius let **the ball reach 3.56m from a player who still
counted as having it**. That is what makes a turnover look absurd from the
outside, and it is now capped by `RETAIN_MAX_DISTANCE` (2.20m).

| measured over a live match | v0.8.8 | v0.9.0 |
|---|---|---|
| worst distance at which the ball was GAINED | 1.97m | 1.26m |
| worst distance at which it was still "his" | 3.56m | 2.21m |
| acquisitions per minute | 69 | 26 |

**"The pass is too weak to be useful."** The v0.8.8 tests checked that a
pass reached the right PLACE and never asked how fast it was going when it
got there. `speed_for_distance` sized every pass so the ball would *stop*
2m past the receiver -- which necessarily makes it arrive dead. A 4m pass
launched at the 4.0 m/s floor.

Passes are now sized by ARRIVAL SPEED, which the roll model inverts exactly:
with `roll = ROLL_PER_SPEED * v - ROLL_OFFSET`, a ball still doing `va` at
distance `d` needs `v = d / ROLL_PER_SPEED + va`, and the offset cancels.

| pass | launched at (v0.8.8 -> v0.9.0) | arrives at |
|---|---|---|
| 4m | 4.10 -> **5.77** m/s | 2.42 m/s |
| 8m | 6.47 -> **8.14** m/s | 2.42 m/s |
| 12m | 8.84 -> **10.50** m/s | 2.42 m/s |

Arrival pace is now constant with distance instead of decaying to nothing,
and the band still stops short of `SHOT_SPEED_MIN` (12.5), so a pass can
never become a weak shot.

**The pass weight was sized against DEFENSIVE SHAPE, not chosen.** The first
value tried made a 4m pass 6.37 m/s, and it broke a non-negotiable: v0_8_3
asserts defenders stay goal-side of the ball, the v0.8.8 build passes that
5 of 5 at 100%, and at that weight it fell to 84-85% on four runs in five.
A faster ball gets in behind a defensive line -- that is real football, and
it is also the thing the preserve list forbids regressing. Measuring the
trade rather than picking a side found a cliff:

| arrival | 4m pass | defenders goal-side |
|---|---|---|
| 1.2 (~the old model) | 3.57 m/s | 100, 100, 100 |
| 2.8 | 5.17 m/s | 100, 96 |
| **3.4 (chosen)** | **5.77 m/s** | **100 x5** |
| 4.0 | 6.37 m/s | 100, 84, 84, 85, 84 |

3.4 keeps essentially all of the pass-power gain (+41% on the short passes
that felt worst) at no measured cost to defensive shape. The full curve is
recorded at `PASS_ARRIVAL_SPEED` so the cliff is not rediscovered.

**"Dribbling feels like dragging the ball."** Only partly answered, and the
honest record of that is below.

**Stopping with the ball** was the one clearly-broken manoeuvre. A carrier
who released the stick took ZERO further touches -- the ball simply rolled
away from them, out to 1.64m from a walking leash of 0.85m, still moving
faster than the player the whole way. There is now a distinct STOP touch
that puts a foot on the ball: measured, separation on stopping went **1.64m
-> 0.76m**.

**Ball-contact events.** Every deliberate contact -- dribble, turn, stop,
pass, shot -- now emits `ball_touched` carrying the contact point,
direction, strength, distance, the carrier's velocity and which foot it
reads as. The dependency runs one way on purpose: the physics emits and
nothing in the simulation listens, so close control behaves identically with
no animation system attached. When the animation pack arrives it can either
subscribe (ball drives animation) or call the same entry points from a key
frame (animation drives ball) without either side being rewritten.

**A challenge can now be beaten.** Previously a challenge could only be
outrun; nothing the carrier did with the ball could defeat it, so a fake
meant nothing. A defender who is committed (carrying real speed) and
wrong-footed (momentum now pointing away from the ball) immediately after
the carrier cuts across their body loses three quarters of their challenge
progress. Deliberately still deterministic -- this file's whole design
rejects a dice roll, and a failure the player *caused* is worth more than
one they cannot see or influence.

**Four experiments were tried and reverted**, results recorded at their
sites so they are not retried blind:

- Raising the urgent touch-interval floor 0.12s -> 0.20s to stop a turn
  reading as a push: the carrier went from 120 of 120 frames on the ball
  through a 90-degree turn to 42. A rolling ball needs those contacts.
- Sharing the urgency window between `turning` and `trailing`: cut the turn
  to 2 touches and lost possession outright. `trailing` is the mechanism
  that recovers an escaping ball, not a cosmetic signal.
- A deadband on the lateral shepherd force, on the theory that it pins the
  ball to the dribble line: measured lateral deviation was 0.00m over 180
  frames, which looks conclusive and is an artifact -- a dead-straight test
  run has nothing to push the ball off the line. Softening it changed the
  straight line not at all and broke turning and stopping.
- (v0.8.8, still recorded) bounding `_kickable_ball`'s action-range
  fallback.

**A latent boundary defect that v0.9.0 exposed.** v0_8_8's "no player is
ever behind a goal line" check began failing intermittently -- 96 and 123
player-frames on two of fifteen runs, clean on the other thirteen. Chasing
it down: `update_goalkeeper` was the ONE positioning path in the game that
never clamped its target. `own_goal_pos` sits at `GOAL_LINE_X` (29.0) and
the playable area ends at `PLAYABLE_HALF_LENGTH` (28.0), so a keeper's
default standing position was, by construction, a metre behind their own
goal line; they registered as out of play whenever they actually settled
there. Every outfield target has always gone through `clamp_to_playable` at
the end of `update_player`; this one did not.

Both halves of that are worth stating. The DEFECT is old and readable in
the code, and nothing in v0.9.0 touches keeper positioning. The
MANIFESTATION is new: the v0.8.8 build is clean on 17 runs against 2
failures in 15 here, which is too large a gap to be chance, and the likely
reason is that stickier possession and more compact play leave a keeper
sitting at that default target more of the time. "Pre-existing, not mine"
would have been the convenient half of the truth; a latent bug this
milestone started triggering is the whole of it.

**A metric that stopped meaning anything.** The playtest reports what share
of frames a midfielder more than 20m from the ball is moving -- v0.8.6's
answer to "midfielders go inert when play is elsewhere". Across three
v0.9.0 runs of identical code it returned 0%, 87% and 100%, which is the
signature of a sample rather than a behaviour: the sample was **one frame**.
Tighter possession keeps play compact enough that a midfielder is hardly
ever 20m from the ball any more, so the condition almost never triggers.
The figure is left in the playtest with its sample size printed beside it,
and no claim about midfield activity is made on the strength of it.

**Known issue, reported not tuned.** The dragging feel is NOT root-caused.
Isolated, the straight-line touch cycle is healthy -- 2.7 touches/s at a
jog, separation swinging 0.53m -> 1.25m between contacts, which is a real
touch rhythm rather than a push. The 6.9 touches/s figure quoted from the
v0.8.8 playtest is a live-match average across AI carriers under constant
pressure and turning, not a measurement of the human's dribble. Three
hypotheses were tested and all three were wrong. What remains is either
something the isolated scene cannot reproduce, or a matter of feel that
needs a human at the controls to judge.

### Possession validity: awareness is not contact (v0.8.8)

The v0.8.7 playtest reported that the AI could steal, pass and shoot from
distances it could not physically reach. That turned out to be two separate
missing checks rather than a wrong number anywhere, and both were found by
instrumenting a live match rather than by reading constants.

**Passing and shooting asked nothing about possession.** `execute_pass` and
`execute_shot` took the ball from `ball_in_action_range` -- the ActionArea,
radius 2.5m -- and struck it. Nothing checked whether the player actually
had the ball. Any player could play a ball somebody else was dribbling, from
across a small crowd. Measured over a 40s match: 64 kicks, from up to
**2.54m**, and **14% of them struck by a player who was not the carrier at
all**. A kick now requires being the elected carrier: measured after, 0%
from a non-carrier and no kick anywhere in a live match from beyond
challenge range.

**Possession was one flag doing two incompatible jobs.** `has_possession`
answered "is the ball inside my ControlArea", and that radius has to be
*wide* -- v0.8.7 sized it to contain the dribble leash, so a sprinting
carrier does not knock the ball out of their own possession radius.
`PossessionManager` then elected a carrier straight from that flag, so
standing ~1.7m from a ball someone else was dribbling simply won it, with no
contact and no challenge: 40% of all possession changes had no challenge
built at all. The two jobs are now separated -- **acquire tight, retain
loose**. Gaining the ball needs it genuinely at your feet
(`POSSESSION_CONTACT_RADIUS`) or a won contest; keeping it still works out to
the full control radius, so touch dribbling is untouched.

That radius was **sized by sweeping it**, not chosen. At 0.95m nobody could
collect a loose ball either and the ball ran ownerless for 83% of a match;
ownership by radius measured 0.95m -> 17%, 1.20m -> 35%, 1.45m -> 32%,
1.75m -> 46%. 1.20m is about one stride, well inside the 2.4m challenge
range and well below the 1.61m-mean / 2.74m-max distances the bug was
handing possession over at.

**Nearly half the outfield defended during its own attack.** Every attacking
slot count derives from `attack_intent`, which ramps over ~1.2s and only
commits after a side has held the ball that long -- and with turnovers
running at ~44/min it essentially never arrived. Measured *while a side had
the ball*: `COVER_SPACE` 3.0 players and `MARK` 1.6, leaving the carrier
about 3.6 teammates on any duty that offers a pass. Possession of the ball
is a fact rather than a slewed opinion, so a side that holds it now floors a
short outlet, a runner and a wide option regardless of intent. Offensive
duties went **3.6 -> 6.6** players and the carrier's clear passing options
**2.2 -> 3.1 per frame**.

The floor keys off the STICKY possession signal, not the instantaneous
carrier. Keyed on the latter first, it toggled with every bobble and churned
duties at 0.341 changes per player per second against a 0.30 ceiling --
which is precisely the oscillation this file warns about, reintroduced one
layer up. On the sticky signal it measures 0.153.

**You sprint to a 50/50 ball.** `sprint_requested` stops once a player is
within `sprint_threshold` of their target, which is right for taking up a
position and wrong for the one player nominated to win the ball: it made
them jog the final few metres of every race. That was harmless while
possession transferred at 1.7m by geometry, and became decisive the moment
contact was required.

**The ball was never heavy -- it was being hit too hard.** "Ball physics
still feel heavy" sounds like a mass or damping problem, and it was neither:
the ball's own properties are fine. `PassEvaluator` decides how hard to
strike *every pass in the game* by inverting a fitted model of how far the
ball rolls for a given launch speed. That model was fitted in v0.8.3 -- and
v0.8.7 then changed the ball itself, from radius 0.35 to 0.16, which changes
both its rolling inertia and how it meets the turf. Nothing re-fitted the
model, so the equation the game used no longer described the ball the game
actually had. Re-measured on the real pitch (`tests/diag_roll.gd`) the
relationship is very cleanly linear, and the old constants were simply
wrong -- launch 4.0 m/s rolls 5.85m, 6.0 rolls 9.20m, 9.0 rolls 14.27m,
11.0 rolls 17.67m. `ROLL_PER_SPEED` / `ROLL_OFFSET` are re-fitted to
1.689 / 0.924, which reproduces every sampled point to within 0.02m.

The second half of it was the *overrun* -- the deliberate margin that lets a
receiver run onto the ball rather than have it die at their feet. That was a
MULTIPLIER (x1.35 of the pass length), so the further the ball was played
the further past the receiver it ran. The thing being modelled is a couple
of metres of pitch, and it is the same couple of metres whether the pass
came from 4m or 14m, so it is now an absolute `OVERRUN_DISTANCE`. Together
the two fixes make pass weight exact across the whole band:

| wanted | before | after |
|---|---|---|
| 8m | 11.5m (+3.5) | 9.99m (+2.0) |
| 12m | 17.0m (+5.0) | 13.99m (+2.0) |
| 14m | 17.7m (+3.7, clamped at PASS_SPEED_MAX) | 16.00m (+2.0) |

Every pass now overruns by exactly the designed 2.0m instead of by 2-5m
growing with distance, and a 14m pass no longer clamps against the top of
the speed band. This is also why the complaint survived v0.8.7's ball
change: shrinking the ball was correct, and it silently invalidated the
model that decided what to do with it.

Three ideas were tried and **reverted with their results recorded** in the
code. Giving `FOLLOW_UP` the lane treatment `_push_up_target` uses: measured
duty-by-duty it was the largest single contributor to a carrier being
crowded by their own side (0.46 teammates within 5m per frame against 0.36
for `MARK`), and its width is the passer's live z, which right after a short
pass is roughly the receiver's z -- so spreading it laterally looked
obvious, and made the metric worse (1.85, above the entire 1.42-1.77 range
it had been in). A longer post-tackle cooldown: challenge build-up collapsed
from 0.80 to 0.37 while the possession share barely moved. And -- carried
over from v0.8.7 -- having a presser aim ahead of the ball.

**Measured in a live 45s match after the milestone** (`tests/PlaytestV088`,
headless and rendered under Xvfb; the same script run against the v0.8.7
build for comparison):

| | v0.8.7 | v0.8.8 |
|---|---|---|
| kicks struck from, mean / furthest | -- | 0.99m / 2.32m (challenge range 2.4m) |
| kicks by a player who was not the carrier | -- | 0 |
| AI ball/carrier separation while dribbling | 1.27m | 0.94m |
| AI passes per minute / shots per 45s | 90.7 / 3 | 50.7 / 14 |
| turnovers per minute | -- | 8.0 |
| human under active challenge while carrying | 16% | 52% |
| mean pass launch speed | 7.4 m/s | 6.8 m/s |
| human passes reaching the intended teammate | 28% | 28% |

Two of those deserve a note. The pass rate FALLING while shots rise is the
roll-model fix: play progresses instead of being recycled sideways. And the
human pass completion is identical in both builds, because that figure is a
property of the measurement -- the scripted human presses PASS twice a
second while running at the ball, under challenge half the time -- and not
of the passing code. It is reported here rather than quietly dropped
precisely because it looks like a v0.8.8 problem until it is baselined.

Both the regression suite and the playtest measure a kick's distance from
the frame BEFORE it lands. Read on the frame the kick is detected, the ball
has already been struck and has travelled -- a shot at ~22 m/s is 0.37m away
one frame later -- which overstates hardest for the hardest kicks. That
artifact alone reported 1 of 41 legal kicks as out of range in the suite,
and a rendered playtest's furthest kick as 2.48m against a 2.4m limit.
Neither was a real escape.

Known issue, reported rather than tuned away: v0.8.5's assertion that
reversals are not concentrated right after a phase change (<22%) fails on
roughly one run in three. Keying the possession floors on a step rather than
a ramp genuinely broke it -- 25%, 25%, 22% -- and ramping them recovered
most of that. What is left is a metric whose spread is far wider than the
difference between builds. Measured over six 60s matches each, plus four
with v0.8.8's contest sprint disabled to test whether that change was
responsible:

| build | samples | mean | over 22 |
|---|---|---|---|
| v0.8.7 baseline | 22, 18, 14, 13, 17, 21, 14, 22, 19, 17, 17, 19 | 17.75 | 0 of 12 |
| v0.8.8 | 21, 13, 24, 18, 13, 31 | 20.0 | 2 of 6 |
| v0.8.8, contest sprint off | 10, 17, 10, 31 | 17.0 | 1 of 4 |

Stated plainly: this is a real residual regression, not noise. The means are
close, but the baseline never crosses the threshold in twelve runs and
v0.8.8 crosses it in a third of them.

The contest sprint was the obvious suspect -- the nominated ball-winner
accelerates hard exactly when possession changes, which is precisely what
this metric counts -- and it explains only about 3 points. The 31 outlier
occurs with the sprint disabled too, so removing it neither explains nor
fixes the excursions. The sprint is kept: it is what makes a player actually
win a 50/50 ball once contact is required (see below), and giving that up
would undo the central fix of this milestone to buy an unreliable pass on
one assertion.

What is left is most likely the same trade the whole milestone makes --
possession now changes hands on real contact, so the moments when it changes
are sharper events than they were when the ball simply drifted between
players. Narrowing it further means changing how many players react to a
loose ball, which is the AI-behaviour change this cleanup milestone
deliberately did not make.

Known issue, reported rather than tuned away: v0.8.7's assertion that "a
useful share of in-range teammates have a clear passing lane (>50%)" now
fails on most runs, at 39-56%. It is a RATIO, and this milestone grew its
denominator. Measured over five 35s matches per build:

| | v0.8.7 | v0.8.8 |
|---|---|---|
| teammates in passing range, per carrier frame | 3.67 | 5.43 |
| of those, with a CLEAR lane (absolute) | 2.17 | 2.75 |
| share with a clear lane (what the test asserts) | 59% | 51% |

The carrier has **27% more clear options than before**, not fewer; there are
simply 48% more teammates in range to divide them by. Carrier frames per
match also rose from 442 to 634-1211, because contact-based possession means
the ball is genuinely held rather than running ownerless. The v0.8.7
assertion is left exactly as written -- editing a previous milestone's test
to flatter this one's numbers would be worthless -- and v0.8.8's own suite
asserts the absolute figure instead, which is the one that answers "do I
have somebody to pass to".

(v0.8.7's build is nearly deterministic on this metric, 2.17 on every run,
because a ball that spends most of its time loose produces very similar
matches. v0.8.8's spread is real football varying between matches.)

Known issue, reported rather than tuned away: against a scripted bot that
sprints at the ball 100% of the time and never passes, that bot now holds
88-95% of carrier time. Requiring contact to take the ball inherently
rewards whoever chases hardest, and only one AI player pursues at a time.
The assertion was already unreliable before this milestone (it failed at 80%
in v0.8.6 and ranged 44-96% in v0.8.7); v0.8.8 makes it fail consistently.
Fixing it properly means changing how many players react to a loose ball,
which is an AI-behaviour change this cleanup milestone deliberately did not
make.

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
godot --headless --path . tests/V0_8PlaytestFixesTest.tscn
godot --headless --path . tests/V0_8_1PlaytestFixesTest.tscn
godot --headless --path . tests/V0_8_2PlaytestFixesTest.tscn
godot --headless --path . tests/V0_8_2OscillationTest.tscn
godot --headless --path . tests/V0_8_3AIBehaviorTest.tscn
godot --headless --path . tests/V0_8_4PlaytestFixesTest.tscn
godot --headless --path . tests/V0_8_5PossessionPhaseTest.tscn
godot --headless --path . tests/V0_8_6OffBallTest.tscn
godot --headless --path . tests/V0_8_7FootballFeelTest.tscn
godot --headless --path . tests/V0_8_8PossessionValidityTest.tscn
```

The `tests/Diag*.tscn` scenes are measurement tools rather than tests: they
print numbers and assert nothing. `DiagRoll` fits the ball roll model (run
it after any change to the ball or the turf, and update `PassEvaluator`'s
constants from its output -- the model going stale after v0.8.7 resized the
ball is exactly the bug it now exists to catch), `DiagLaneShare` separates
clear passing lanes from teammates merely in range, and `DiagCarrierPop`
compares carrier-election definitions. `tests/PlaytestV08*.tscn` are
rendered/headless play sessions that report measurements, not assertions.

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
restart) now running with real characters filling the entire pitch;
`v0_8_playtest_fixes_test.gd` is the newest suite, covering the manual-
playtest fix pass: a two-player contested-ball scenario that used to freeze
(now proven to keep moving and resolve to a single carrier),
`is_currently_sprinting`/stamina drain+regen smoothness, a ball fired
directly at a goal post being physically blocked by the new goal geometry,
`HUD.gd`'s multitouch dispatcher holding the joystick and SHOOT
independently on two separate synthetic finger IDs at once (drag one,
release either, both stay correctly isolated), a far-side defender still
moving under the new ball-reactive formation targets instead of sitting
frozen at a static spawn point, and supporting teammates keeping a passing
distance from the ball carrier instead of stacking on top of them;
`v0_8_1_playtest_fixes_test.gd` is the latest suite, covering the manual-
playtest gameplay-correction pass: the low perimeter curb still reliably
containing the ball and a sprinting player from every side, a player being
physically blocked by the new goal net collision while the ball can still
enter and score before ever reaching it, pass power never overlapping shot
power regardless of stats, an AI player actually shooting when in range
(preferred over passing), actually passing when out of range with an open
teammate instead of holding the ball forever, falling back to a genuine
no-kick dribble when neither a shot nor a pass makes sense, pass targeting
only ever considering same-team players (an equally-well-positioned
opponent is never picked) while a same-team player stays a valid target
even while human-controlled, an AI teammate actually releasing the ball
toward the human player like any other teammate, a fast tap on SHOOT still
firing a shot even when the press and release both land inside the same
physics-tick gap, and switching the controlled player mid-charge never
crediting a phantom shot to whoever is controlled by the time a
still-held finger is released; `v0_8_2_playtest_fixes_test.gd` is the
latest suite, covering the football-intelligence pass: the ball settling
close to the feet at a standstill and loosening (but never fully letting
go) while sprinting, the retuned dribble spring still never freezing a
contested ball, a forward's shape surviving a brief loose-ball moment
mid-attack instead of snapping back to defensive recovery, a real
turnover correctly producing `TRANSITION_DEFENSE`, ball-challenger
hysteresis holding through a sub-margin jitter (no defender-swarm
flicker), the AI's omnidirectional pass search finding a teammate
directly behind the carrier that the human PASS button's narrower cone
correctly does not, switch-target scoring preferring a relevant nearby
player over a genuinely distant one, and the kickoff state machine itself
(starts in KICKOFF, movement frozen, transitions to PLAYING on its own,
timer only then starts, normal goal scoring still works afterward).
`v0_8_2_oscillation_test.gd` is the newest suite, covering the movement-
oscillation hotfix: a brief opponent touch not stealing team possession
while a sustained one does, the shape-state dwell holding through a
single-frame possession swing but releasing once it elapses (and ball
interaction preempting it immediately), pressing and carrying pointing the
same way at contact range, the possession grace absorbing control-radius
chatter without masking a real dispossession, an AI attacker under a
genuinely stable game state never reversing direction across 600 frames,
and live-match AI state churn staying far below the pre-fix rate.
`v0_8_3_ai_behavior_test.gd` covers the v0.8.3 team-AI pass: duty slot
ceilings holding in a live match, no teammate ever contesting our own
carrier, `attack_intent` ramping rather than snapping, arrival without
overshoot or recoil, the pass and shot speed bands being non-overlapping
for every stat combination, kick instrumentation recording intent, passes
actually reaching their target at 5/9/13m, an AI pass being aimed at the
teammate it chose, the human-controlled teammate being a normal pass
option, a carrier releasing rather than holding forever, the facing angle
turning at a finite rate, midfielders staying active with the ball parked
in a far corner, forwards holding an advanced line, a carrier's teammates
giving them space, defenders staying goal-side, live-match movement not
looping, AI passing and shooting being distinguishable, an AI shooting
from a real chance but never from the halfway line, and goalkeepers being
unaffected.
495 assertions total across all eleven suites, all passing (`character_pipeline_test.gd` also verifies the T-pose fix below: the diagnostic flag plus the actual posed arm-bone geometry, per model).

## Current Feature Set (v0.7, extended v0.8, v0.8.1, v0.8.2)

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
- **(v0.8)** A real mobile football HUD (`scripts/HUD.gd` /
  `scenes/UI/HUD.tscn`) with true independent-finger multitouch, a
  ball-reactive AI positioning system that keeps every player alive and
  properly spaced instead of idling at a static formation slot, a
  contested-ball fix so two players fighting for the ball can never freeze
  it, a closer mobile-scale camera, a fully enclosed stadium (tiered
  stands, end stands, team benches, corner flags), and a real goal frame
  (posts, crossbar, back stanchions, and a semi-transparent net) instead of
  three bare tubes — see the sections above for each in detail
- **(v0.8.1)** A real AI pass/shoot decision hierarchy (see `AIController._decide_possession_action`)
  -- before this, an AI player in possession only ever checked "am I in
  shooting range," so nobody ever passed and the human's own teammates
  never released the ball toward them either; pass power and shot power
  now never overlap so the two actions read as clearly different;
  SHOOT fires reliably even on a very fast tap (see
  `FootballPlayer.notify_shoot_release()`); a low perimeter curb replaced
  the old tall boundary wall; the goal net now physically blocks players
  while still letting the ball score before reaching it
- **(v0.8.2)** A named AI state model (`AIController.AIState` --
  HOLDING_POSSESSION/ATTACKING_RUN/SUPPORTING_ATTACK/TRANSITION_ATTACK/
  PRESSING/SEEKING_BALL/MARKING/TRANSITION_DEFENSE/RECOVERING_SHAPE)
  driven by `PossessionManager`'s new *sticky* `last_team_with_possession`
  rather than the instantaneous per-tick value, so a brief loose-ball
  bounce mid-attack no longer collapses the whole team's shape into
  defensive recovery and back; the AI's pass search is now
  omnidirectional (a teammate square or behind the carrier is a real
  option, not just whoever's directly ahead); `TeamController` now keeps
  a sticky ball-challenger so defenders don't flicker-swarm the ball;
  switch-target scoring weighs distance and lateral position much more
  heavily; a genuinely gentler dribble spring (close at a standstill,
  loosens while sprinting, still never freezes a contest); and a brief
  KICKOFF hold before PLAYING starts (formations set, ball centered,
  movement frozen, timer withheld) instead of the match beginning
  mid-play on frame one

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
