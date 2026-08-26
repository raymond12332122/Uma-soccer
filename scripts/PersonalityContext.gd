class_name PersonalityContext
extends RefCounted

## Bundle of per-frame match state handed to personality trigger/behavior
## Callables, so event definitions can react to the match without each one
## threading its own set of parameters through PersonalityEventSystem.
## Built once per player-update by TeamController, mirroring what it
## already passes to AIController.

var ball: RigidBody3D
var mood: MatchMood
var match_manager: Node
var teammates: Array = []
var opponents: Array = []
var own_goal_pos: Vector3
var opponent_goal_pos: Vector3
var possessing_team: int = -1
var is_loose: bool = true
