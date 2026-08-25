extends Node

# Shared input state written by touch controls and read by Player. Keyboard
# input is polled directly in Player.gd/Main.gd so the game is fully
# playable in the editor without any InputMap setup.

var move_vector: Vector2 = Vector2.ZERO

# One-shot: set true by TouchControls on tap, consumed (and reset) by
# Player on the next physics frame.
var pass_pressed: bool = false

# Continuous: true while the on-screen SHOOT button is held (charging a
# shot), false on release.
var shoot_held: bool = false

# Continuous: true while the on-screen SPRINT button is held.
var sprint_held: bool = false

# One-shot: set true by TouchControls on tap, consumed (and reset) by
# MatchManager on the next physics frame. Cycles the human-controlled
# player.
var switch_pressed: bool = false
