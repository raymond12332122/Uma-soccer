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

## v0.8.2: which player is currently pressing the ball, kept sticky across
## frames (see _pick_ball_challenger) so it doesn't flicker between two
## similarly-placed defenders as the ball moves -- a fresh nearest-player
## recompute every single frame with no memory at all was the actual cause
## of "defenders swarm/chase the ball": whichever of two close defenders
## was a hair's-breadth closer would flip frame to frame, so both would
## visibly dash in and out toward the ball instead of exactly one of them
## committing to press while the other held shape.
## This team's tactical plan for the current frame -- the team level of the
## decision hierarchy. Created in setup(), ticked once per physics frame
## before any player is updated.
var plan: TeamPlan = null

var _current_challenger: FootballPlayer = null
## A challenger candidate must be closer than the current one by more than
## this margin to take over -- same spirit as PossessionManager's own
## HYSTERESIS_MARGIN, applied to the same kind of "who's closest" jitter.
const CHALLENGER_HYSTERESIS_MARGIN := 1.2


func setup(p_players: Array, p_ball: RigidBody3D, p_possession: PossessionManager, p_own_goal: Vector3, p_opponent_goal: Vector3) -> void:
	players = p_players
	ball = p_ball
	possession = p_possession
	own_goal_pos = p_own_goal
	opponent_goal_pos = p_opponent_goal
	plan = TeamPlan.new()
	plan.setup(team_id, own_goal_pos, opponent_goal_pos)


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

	# Computed once per team per frame rather than once per player -- every
	# non-challenging player used to redo an equivalent O(opponents) scan
	# independently at 11-a-side, which is real duplicated work.
	# AIController.update_player just reads the shared result below.
	# v0.8.3: THE team-level pass. One call, once per team per frame, that
	# decides the phase and allocates every player's duty before any
	# individual is updated -- see TeamPlan. Everything below is now the
	# player level acting on a decision that was already made for the side
	# as a whole, which is the structural difference between a team and 11
	# agents that each happen to be looking at the same ball.
	# The shared read of the pitch, built ONCE for the whole side and then used
	# by the plan, by every duty target and by the carrier's decision.
	#
	# This is the structural half of "the bots do not understand football":
	# pressure, space, lane quality and where the ball is going were each being
	# worked out independently at several call sites with different radii and
	# different weights, so two parts of the same team could disagree about
	# whether a lane was open. One snapshot, one answer.
	#
	# Cost is O(players * opponents) once per team per frame, not per player per
	# frame -- see FootballPerception.build.
	plan.perception = FootballPerception.new(
		team_id, players, opponent_team.players, ball, possession,
		own_goal_pos, opponent_goal_pos)

	plan.update(players, opponent_team.players, ball, possession, delta)

	var ball_challenger: FootballPlayer = plan._contester
	var dangerous_opponent: Node3D = AIController.find_dangerous_opponent(opponent_team.players, own_goal_pos)

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
			var category: String = FormationManager.role_category(player.formation_role)
			var target: Vector3 = FormationManager.get_dynamic_position(player.formation_slot, team_id, ball.global_position, category)
			AIController.update_player(player, ball, possession, players, opponent_team.players, own_goal_pos, opponent_goal_pos, target, ball_challenger, dangerous_opponent, delta, plan)

		if personality_events and mood:
			personality_events.maybe_trigger(player, delta, ctx)


## Sticky version of AIController.find_ball_challenger -- see
## _current_challenger's doc comment for why plain nearest-player-every-
## frame flickered between defenders.
func _pick_ball_challenger() -> FootballPlayer:
	var nearest: FootballPlayer = AIController.find_ball_challenger(players, ball)
	if nearest == null:
		_current_challenger = null
		return null

	if _current_challenger == null or not is_instance_valid(_current_challenger) or _current_challenger.is_goalkeeper:
		_current_challenger = nearest
		return _current_challenger

	if _current_challenger == nearest:
		return _current_challenger

	var current_dist: float = _current_challenger.global_position.distance_to(ball.global_position)
	var nearest_dist: float = nearest.global_position.distance_to(ball.global_position)
	if nearest_dist + CHALLENGER_HYSTERESIS_MARGIN < current_dist:
		_current_challenger = nearest
	return _current_challenger


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
