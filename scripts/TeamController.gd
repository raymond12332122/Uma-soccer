class_name TeamController
extends Node

## Owns one team's roster and drives every member that isn't the current
## human-controlled player through AIController each physics frame.
## Excluding the human target is the entire "switching" mechanism from
## this side -- whichever player stops being excluded here simply starts
## receiving AI intent again on the very next frame.

@export var team_id: int = 0

var players: Array = []
var human_player: FootballPlayer = null

var ball: RigidBody3D
var possession: PossessionManager
var opponent_team: TeamController

var own_goal_pos: Vector3
var opponent_goal_pos: Vector3


func setup(p_players: Array, p_ball: RigidBody3D, p_possession: PossessionManager, p_own_goal: Vector3, p_opponent_goal: Vector3) -> void:
	players = p_players
	ball = p_ball
	possession = p_possession
	own_goal_pos = p_own_goal
	opponent_goal_pos = p_opponent_goal


func set_opponent_team(team: TeamController) -> void:
	opponent_team = team


func set_human_player(player: FootballPlayer) -> void:
	human_player = player


func _physics_process(_delta: float) -> void:
	if opponent_team == null:
		return

	for player in players:
		if player == human_player:
			continue

		if player.is_goalkeeper:
			AIController.update_goalkeeper(player, ball, own_goal_pos)
		else:
			var target: Vector3 = FormationManager.get_world_position(player.formation_slot, team_id)
			AIController.update_player(player, ball, possession, players, opponent_team.players, own_goal_pos, opponent_goal_pos, target)
