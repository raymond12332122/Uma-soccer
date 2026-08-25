# Uma Soccer

A 3D soccer prototype built in Godot 4, aimed at an installable Android APK.
This is the foundation for a much larger football game — right now it's a
single-player physics sandbox: move around, dribble, and kick the ball into
either goal.

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
│   ├── Main.tscn             # Entry scene: field, ball, player, camera, UI
│   ├── Field.tscn             # Ground, boundary walls, goals, goal triggers
│   ├── Player.tscn            # CharacterBody3D + kick detection area
│   ├── Ball.tscn               # RigidBody3D soccer ball
│   └── UI/TouchControls.tscn  # Virtual joystick + kick button
└── scripts/
    ├── InputState.gd         # Autoload singleton bridging touch + gameplay
    ├── Player.gd              # Movement, kicking, keyboard fallback
    ├── Ball.gd                 # Out-of-bounds reset
    ├── CameraRig.gd            # Smooth follow camera
    ├── Main.gd                  # Goal detection + score tracking
    ├── TouchControls.gd        # Wires joystick/button to InputState
    └── JoystickBase.gd         # Virtual joystick drawing + input
```

## Controls

- **Desktop (editor testing):** WASD or arrow keys to move, Space to kick
- **Mobile/Android:** On-screen virtual joystick (bottom-left) to move,
  KICK button (bottom-right) to shoot

Both input paths work at the same time — the touch controls also work with
a mouse in the Godot editor, since Godot translates mouse input into GUI
touch-equivalent events automatically.

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
code, scenes, iteration) happens through this repo.

## Current Prototype Features

- Third-person 3D movement on an open field
- Physics-based ball with realistic bounce/friction
- Kick mechanic (walk into range, tap KICK) that shoots toward the ball
- Two goals with post/crossbar collision and invisible goal-line triggers
- Score counter (increments on either goal, ball auto-resets to center)
- Boundary walls so the ball can't roll off the field

## Roadmap Ideas (for expanding into a full game)

- AI-controlled teammates/opponents
- Multiple controllable characters with switching
- Passing mechanics and ball trapping/control
- Match timer, possession stats, proper left/right team scoring
- Character models/animations (currently placeholder capsule)
- Stadium environment, crowd, audio
