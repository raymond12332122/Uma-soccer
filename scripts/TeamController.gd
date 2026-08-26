class_name TeamController
extends Node

## Owns one team's roster and drives every member that isn't the current
## human-controlled player. Excluding the human target is the entire
## "switching" mechanism from this side -- whichever player stops being
## excluded here simply starts receiving AI/personality intent again on
## the very next frame.
##
## Per non-human player, per frame: PersonalityEventSystem gets first
## look. If it reports an event is actively driving that player's intent,
## AIController is skipped entirely for this frame (the event owns
## movement/sprint this frame). Otherwise AIController runs as normal,
## and PersonalityEventSystem then rolls for whether a new event should
## start (after AI, so a freshly-started event isn't immediately
## overwritten by this same frame's AI output).

@export var team_id: int = 0

var players: Array = []
var human_player: FootballPlayer = null

var ball: RigidBody3D
var possession: PossessionManager
var opponent_team: TeamController
var mood: MatchMood
var personality_events: PersonalityEventSystem

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


func set_personality_systems(p_mood: MatchMood, p_events: PersonalityEventSystem) -> void:
	mood = p_mood
	personality_events = p_events


func _physics_process(delta: float) -> void:
	if opponent_team == null:
		return

	for player in players:
		if player == human_player:
			continue

		var ctx: PersonalityContext = _build_context(player)

		if personality_events and mood:
			if personality_events.tick(player, delta, ctx):
				continue

		if player.is_goalkeeper:
			AIController.update_goalkeeper(player, ball, own_goal_pos)
		else:
			var target: Vector3 = FormationManager.get_world_position(player.formation_slot, team_id)
			AIController.update_player(player, ball, possession, players, opponent_team.players, own_goal_pos, opponent_goal_pos, target)

		if personality_events and mood:
			personality_events.maybe_trigger(player, delta, ctx)


func _build_context(player: FootballPlayer) -> PersonalityContext:
	var ctx := PersonalityContext.new()
	ctx.ball = ball
	ctx.mood = mood
	ctx.teammates = players
	ctx.opponents = opponent_team.players if opponent_team else []
	ctx.own_goal_pos = own_goal_pos
	ctx.opponent_goal_pos = opponent_goal_pos
	if possession:
		ctx.possessing_team = possession.possessing_team
		ctx.is_loose = possession.is_loose
	return ctx
