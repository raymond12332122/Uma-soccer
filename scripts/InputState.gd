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

# v0.8.1: a level-sampled shoot_held boolean alone can silently swallow a
# very fast tap -- if a touch's press *and* release both land inside the
# same gap between two physics ticks, the physics loop only ever observes
# the settled final (false) value and never sees the transient press, so
# no shot fires at all. shoot_pressed_at_ms/shoot_release_pending give the
# physics loop a real-timestamped, one-shot record of that edge instead of
# relying on it having sampled the right instant.
#
# shoot_pressed_at_ms: Time.get_ticks_msec() when SHOOT went down, or -1
# if not currently pressed (also used as a "was this press still live"
# guard -- cleared on player-switch so a lingering press can't credit a
# phantom shot to whichever player is controlled by the time it's finally
# released).
var shoot_pressed_at_ms: int = -1
# One-shot: set true (with shoot_release_elapsed_seconds) the instant
# SHOOT is released; consumed and reset by PlayerController next physics
# frame via FootballPlayer.notify_shoot_release().
var shoot_release_pending: bool = false
var shoot_release_elapsed_seconds: float = 0.0

# Continuous: true while the on-screen SPRINT button is held.
var sprint_held: bool = false

# One-shot: set true by TouchControls on tap, consumed (and reset) by
# MatchManager on the next physics frame. Cycles the human-controlled
# player.
var switch_pressed: bool = false
