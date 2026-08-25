# Uma Soccer

A 3D soccer prototype built in Godot 4, aimed at an installable Android APK.
This is the foundation for a much larger football game. Current milestone
(v0.2): one player, one ball, real dribbling/passing/shooting on an open
field.

## Tech Stack

- **Engine:** Godot 4.x (GDScript)
- **Rendering:** Mobile renderer (`renderer/rendering_method = "mobile"`) for
  good performance on Android devices
- **Physics:** Built-in Godot 3D physics (`CharacterBody3D` for the player,
  `RigidBody3D` for the ball)

## Project Structure

```
uma-soccer/
├── project.godot            # Engine config (mobile renderer, autoloads)
├── export_presets.cfg       # Android export preset (arm64-v8a)
├── icon.svg
├── scenes/
│   ├── Main.tscn              # Entry scene: field, ball, player, camera, UI
│   ├── Field.tscn              # Ground, boundary walls, goals, goal triggers
│   ├── Player.tscn             # CharacterBody3D + action/control sensors
│   ├── Ball.tscn                # RigidBody3D soccer ball
│   └── UI/TouchControls.tscn   # Joystick + PASS/SHOOT/SPRINT buttons
├── scripts/
│   ├── InputState.gd          # Autoload singleton bridging touch + gameplay
│   ├── Player.gd               # Movement, dribbling, passing, shooting
│   ├── Ball.gd                  # Physics tuning + out-of-bounds reset
│   ├── CameraRig.gd             # Follow camera, biased toward the ball
│   ├── Main.gd                   # Goal detection, score, match restart
│   ├── TouchControls.gd         # Wires HUD buttons/joystick to InputState
│   └── JoystickBase.gd          # Virtual joystick drawing + input
└── tests/                     # Headless automated gameplay tests (see below)
    ├── gameplay_test.gd / GameplayTest.tscn      # Player+Ball physics
    └── main_scene_test.gd / MainSceneTest.tscn   # Goals + restart
```

## Controls

| Action   | Desktop            | Mobile              |
|----------|---------------------|----------------------|
| Move     | WASD / arrow keys   | Left joystick        |
| Sprint   | Hold Shift          | Hold SPRINT button   |
| Pass     | Tap F               | Tap PASS button       |
| Shoot    | Hold Space, release | Hold SHOOT, release   |
| Restart  | Tap R               | (desktop-only for now)|

Shooting is charge-based: the longer Space/SHOOT is held before release, the
harder the shot (up to a capped max speed). Passing is a fixed, lower-power
tap. Both fire in the direction you're currently moving, or the direction
you're facing if you're standing still.

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

## Setup (one-time, on your machine)

1. Install [Godot 4.x](https://godotengine.org/download) (stable release).
2. Open this folder as a project in Godot (`project.godot`).
3. Press **F5** (or the Play button) to run the prototype directly in the
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

`tests/` contains scripted gameplay smoke tests that run without a display,
driving the real Player/Ball/Main scenes through `InputState` exactly like
touch or keyboard input would, then asserting on the resulting physics
state (possession gained/lost, pass vs. shot power, max-speed clamp, goal
scoring, match restart). Not part of the shipped game — nothing in
`project.godot` references them.

Run them with a local Godot 4.3 binary:

```
godot --headless --path . tests/GameplayTest.tscn
godot --headless --path . tests/MainSceneTest.tscn
```

Both print `[PASS]`/`[FAIL]` per check and exit non-zero on any failure.

## Current Feature Set (v0.2)

- Football-style movement: acceleration/deceleration, smooth turning, sprint
- Soft-attach dribbling with realistic loss-of-control on sharp turns
- Passing (fixed low power) and charge-based shooting (variable power, capped
  max ball speed) — both directional
- Tuned ball physics: natural rolling friction, restrained bounce, no
  runaway speeds
- Camera that follows the player with a bias toward keeping the ball in view
  and a slight dynamic zoom-out on long passes/shots
- Mobile HUD: left joystick, right-side PASS/SHOOT/SPRINT cluster sized for
  thumbs
- Two goals with post/crossbar collision, goal-line scoring triggers, score
  counter, and match restart (desktop: R key)
- Boundary walls so the ball can't roll off the field

## Roadmap Ideas (for expanding into a full game)

- AI-controlled teammates/opponents
- Multiple controllable characters with switching
- Ball trapping/first-touch skill mechanics
- Match timer, possession stats, proper left/right team scoring
- Character models/animations (currently placeholder capsule)
- Stadium environment, crowd, audio
