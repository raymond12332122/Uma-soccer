---
name: run-uma-soccer
description: Build, run, and drive Uma Soccer (Godot 4 3D football prototype). Use when asked to run the game, launch the app, take a screenshot of the match, or interact with the live 22-player match (move/sprint/pass/switch/score/restart) rather than just running its automated test suite.
---

Uma Soccer is a Godot 4.3 3D game (no compiled build step -- GDScript is
interpreted straight from source). It's driven via
`tests/run_driver.gd` / `tests/RunDriver.tscn`, a scene that instantiates
the REAL entry point (`scenes/Main.tscn`, exactly what pressing F5 in the
editor or the exported APK runs) and pokes it through the same
`InputState` autoload the touch controls/keyboard feed. Run it windowed
under Xvfb for real screenshots (the primary path below), or `--headless`
for a fast functional-only check with no display.

This is a single-project repo -- all paths below are relative to repo root.

## Prerequisites

```bash
# Xvfb ships pre-installed in this container's base image; if missing:
sudo apt-get update && sudo apt-get install -y xvfb
# fluxbox (a window manager) is NOT preinstalled and IS required -- see
# Gotchas for why Godot hangs on window creation without one:
sudo apt-get install -y --no-install-recommends fluxbox
```

No GPU/DRI device is present in this container; rendering uses Mesa's
`llvmpipe` software rasterizer (already part of the `libgl1-mesa-dri`
package that ships with the base image -- nothing extra to install for
that specifically).

## Setup

Download the Godot 4.3 editor/runtime binary (there's no engine binary
checked into the repo):

```bash
mkdir -p /tmp/godot-bin && cd /tmp/godot-bin
curl -sSL -o godot.zip "https://github.com/godotengine/godot/releases/download/4.3-stable/Godot_v4.3-stable_linux.x86_64.zip"
unzip -o -q godot.zip
chmod +x Godot_v4.3-stable_linux.x86_64
GODOT=/tmp/godot-bin/Godot_v4.3-stable_linux.x86_64
```

From the repo root, pre-import assets once (glTF character models etc.) --
skippable, but the first windowed/headless run does this implicitly and
adds noisy `WARNING: Material uses a specular and glossiness workflow...`
lines to its own output otherwise:

```bash
$GODOT --headless --path . --import
```

No API keys or env vars required.

## Build

No separate build step -- GDScript runs directly from source.

## Run (agent path)

Launch Xvfb and a window manager as background services (once per
session), then run the driver scene windowed against that display. Godot
needs BOTH `--rendering-driver opengl3` (its default Vulkan path fails --
no GPU) and a window manager running on the X display (see Gotchas) or it
hangs indefinitely before ever reaching the scene's `_ready()`.

```bash
Xvfb :88 -screen 0 1280x720x24 > /tmp/xvfb.log 2>&1 &
disown
sleep 2
DISPLAY=:88 fluxbox > /tmp/fluxbox.log 2>&1 &
disown
sleep 2

mkdir -p /tmp/xdgrun && chmod 700 /tmp/xdgrun
cd <repo-root>
DISPLAY=:88 XDG_RUNTIME_DIR=/tmp/xdgrun LIBGL_ALWAYS_SOFTWARE=1 \
  timeout 60 $GODOT --path . --rendering-driver opengl3 --display-driver x11 \
  tests/RunDriver.tscn > /tmp/driver.log 2>&1
grep "DRIVER:" /tmp/driver.log
```

The driver spawns the real 22-player 11v11 match, moves the controlled
player toward the ball, sprints, passes, switches player, forces and
verifies a goal, restarts the match, and prints one `DRIVER: ...` line per
step. Expected output (session succeeded if you see this):

```
DRIVER: spawned -- home=11 away=11 controlled=Teio
DRIVER: screenshot -> /root/.local/share/godot/app_userdata/Uma Soccer/driver_01_01_kickoff.png
DRIVER: approached ball -- has_possession=... pos=...
DRIVER: sprinted -- stamina 100% -> 89%
DRIVER: screenshot -> .../driver_02_02_midplay.png
DRIVER: pressed SWITCH -- Teio -> Agnes
DRIVER: screenshot -> .../driver_03_03_after_switch.png
DRIVER: goal test -- scored=true score_label='Home 1 - 0 Away'
DRIVER: screenshot -> .../driver_04_04_after_goal.png
DRIVER: restart_match() -- score_label='Home 0 - 0 Away'
DRIVER: SESSION COMPLETE
```

Screenshots (PNG) land under Godot's per-user data dir -- the driver
prints the exact absolute path for each one (via
`ProjectSettings.globalize_path`), typically
`~/.local/share/godot/app_userdata/Uma Soccer/driver_NN_<label>.png`
(4 shots: kickoff, midplay, after-switch, after-goal). `cp` one out to
inspect it, e.g. via the Read tool.

**Fast functional-only check** (no rendering, no Xvfb/fluxbox needed --
runs in a couple seconds, but produces no screenshots, see Gotchas):

```bash
timeout 30 $GODOT --headless --path . tests/RunDriver.tscn
```

To exercise a different flow (different button sequence, force a
personality event via `main.force_personality_event(player, event_id)`,
etc.), edit `tests/run_driver.gd`'s `_drive()` function directly -- it's a
linear scripted sequence, not a REPL; add/reorder steps there and rerun.

## Run (human path)

Open the project in the Godot editor and press F5 -- opens a window,
plays live, no agent use.

## Test

The project's own automated regression suite (assertion-based, separate
from the driver above):

```bash
for scene in GameplayTest MainSceneTest TeamSystemTest CharacterPipelineTest PersonalityTest V0_7MatchTest; do
  $GODOT --headless --path . tests/$scene.tscn
done
```

Each prints `[PASS]`/`[FAIL]` per check, a `TEST_SUMMARY: ALL PASS` (or
`FAILURES PRESENT`) line, and exits non-zero on any failure. 323
assertions total across the six suites as of v0.7.

---

## Gotchas

- **Godot hangs forever with no output past the audio-driver warnings,
  under Xvfb, with no window manager running.** Confirmed by direct A/B
  test: identical launch command, only difference was `fluxbox` running
  on the display or not. Without one, the scene's own `_ready()` never
  even fires (added a print as the very first line of `_ready()` --
  never printed). Fix: always start a window manager (`fluxbox` is
  enough) on the Xvfb display before launching Godot windowed.

- **Godot's default rendering driver (Vulkan) fails immediately** with
  `ERROR: Required extension VK_KHR_surface not found` (no GPU), then
  falls back to Wayland, which also fails (`XDG_RUNTIME_DIR is invalid or
  not set`), and the process exits. Fix: pass
  `--rendering-driver opengl3 --display-driver x11` explicitly, and set
  `LIBGL_ALWAYS_SOFTWARE=1` so Mesa uses `llvmpipe` (confirmed working:
  `OpenGL API 4.5 ... Using Device: Mesa - llvmpipe`) plus a valid
  `XDG_RUNTIME_DIR` (any writable, mode-700 directory; Wayland is never
  actually used once `--display-driver x11` is passed, but Godot still
  probes/warns about it otherwise).

- **Screenshot capture (`await RenderingServer.frame_post_draw`) hangs
  forever under `--headless`.** The dummy renderer used in headless mode
  never emits a post-draw frame signal. Confirmed by direct repro: the
  exact same driver scene reaches `_ready()` fine headless but never gets
  past its first screenshot call (60s timeout, zero further output). The
  driver checks `DisplayServer.get_name() == "headless"` and skips
  screenshots in that mode instead of hanging -- if you write a new
  screenshot-taking script, add the same guard.

- **A plain `RigidBody3D.global_position = ...` teleport can be silently
  lost under real-time windowed execution, even though the identical line
  works reliably in every headless test run.** Root-caused by direct A/B
  instrumentation: printing `Engine.get_physics_frames()` alongside the
  ball's position showed the assignment taking effect for exactly one
  synchronous read, then reverting to (approximately) its pre-assignment
  trajectory on the very next physics tick, with velocity showing exactly
  `(0,0,0)` (i.e., not knocked away by a force/impulse -- silently
  overwritten). This never reproduces in headless tests, which run fast
  enough that there's no real-world race against the physics thread; it's
  specific to real-time windowed/software-rendered execution. Fix: use
  `PhysicsServer3D.body_set_state()` for a hard teleport instead of the
  plain property setter (see `tests/run_driver.gd`'s goal-test step) --
  confirmed reliable across repeated runs once switched.

- **Pressing a one-shot `InputState` flag (e.g. `switch_pressed = true`)
  and reading the result after a single `await get_tree().physics_frame`
  can still show the pre-press state.** The awaited frame can resume
  before `MatchManager._physics_process` for that same tick has
  necessarily consumed the flag. Wait two physics frames, not one, after
  setting a pulse-style `InputState` flag before reading the result.

- **Teleporting the ball directly into a goal trigger without first
  clearing the defending team can let the goalkeeper intercept and clear
  it as a legitimate save**, before you ever observe a score -- not a
  bug, just unrealistic test setup (the driver had been running live
  22-player AI for hundreds of frames by that point, so the away keeper
  was genuinely defending). The driver moves `away_players` off to a
  corner immediately before the goal-placement step to get a clean,
  reproducible scoring demo.

## Troubleshooting

- **`SCRIPT ERROR: Parse Error: Cannot infer the type of "X" variable
  because the value doesn't have a set type.`** when running a scene that
  reaches into an untyped script variable (e.g. `main.ball` where `main`
  is declared as bare `var main = MainScene.instantiate()`, or the result
  of `lerp(...)`) via `:=`. GDScript's static analyzer can't infer a type
  through an untyped/Variant-typed expression. Fix: use an explicit type
  annotation (`var ball: BallController = main.ball`) instead of `:=`.

- **`Exit code 1` with no visible command output at all**, seen
  repeatedly in this session specifically when a command sequence
  included `pkill` (even guarded with `|| true`, even followed by
  further commands). Root cause not fully isolated -- looked like a
  quirk of this sandboxed shell's error-reporting wrapper suppressing all
  stdout whenever an early command in the sequence exited non-zero,
  `pkill` included (`pkill` exits 1 when it matches nothing, which is
  normal, not a real error). Workaround: avoid `pkill` for cleanup;
  `ps aux | grep -iE "xvfb|godot|fluxbox"` and `kill <pid>` explicitly
  instead.
