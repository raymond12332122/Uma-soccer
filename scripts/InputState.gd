extends Node

# Shared input state written by touch controls (and read as a fallback-free
# source by Player). Keyboard input is polled directly in Player.gd so the
# game is playable in the editor without any InputMap setup.

var move_vector: Vector2 = Vector2.ZERO
var kick_pressed: bool = false
