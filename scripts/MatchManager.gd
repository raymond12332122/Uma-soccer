extends Node3D

## Top-level orchestrator. Spawns both squads, wires up the (small,
## single-purpose) subsystems -- PossessionManager, TeamController x2,
## PlayerController, MatchMood, PersonalityEventSystem -- and owns
## match-level concerns: goal scoring, player switching, and match
## restart. Everything else lives in its own script; this file
## intentionally stays thin.

const HOME_COLOR := Color(0.964706, 0.960784, 0.309804, 1)
const AWAY_COLOR := Color(0.85, 0.16, 0.16, 1)
const DEFAULT_HUMAN_INDEX := 9  # index into home_players -- the ST slot (see TestRoster's 4-3-3 slot order)

## Player-switching relevance weights (see _select_switch_target). Not
## "always pick the closest player" -- distance still matters most, but
## attacking/defensive positional relevance can outweigh a small distance
## difference, and the goalkeeper is deprioritized outside real danger.
## v0.8.2: raised across the board -- manual playtesting found repeated
## SWITCH presses sometimes landing on a distant, seemingly-unrelated
## player. SWITCH_DIST_WEIGHT and SWITCH_FAR_PENALTY_DISTANCE/_WEIGHT make
## genuinely distant candidates score much worse (not just slightly worse)
## even when they technically satisfy the ahead-of/behind-the-ball
## relevance check, and SWITCH_LATERAL_WEIGHT means "ahead of the ball" on
## the opposite touchline no longer counts as being "in the play".
const SWITCH_DIST_WEIGHT := 1.4
const SWITCH_LATERAL_WEIGHT := 0.5
const SWITCH_RELEVANCE_BONUS := 8.0
const SWITCH_GK_PENALTY := 20.0
## Beyond this distance from the ball, an extra steep penalty kicks in on
## top of the normal linear distance weight -- keeps a technically-"ahead"
## but genuinely far-off player from ever outscoring someone actually near
## the play.
const SWITCH_FAR_PENALTY_DISTANCE := 20.0
const SWITCH_FAR_PENALTY_WEIGHT := 2.5

## v0.8.2: a bare "match already mid-play from frame 0" didn't read as a
## real kickoff. PRE_MATCH/KICKOFF hold movement frozen for a beat (players
## already sit in formation, ball already sits at center -- both are just
## where _spawn_teams()/_reset_all_players() already put them, nothing new
## to build there) before PLAYING unlocks control and starts the clock.
## Deliberately NOT a cinematic -- no camera moves, no extra nodes, just a
## short hold. Scoped to genuine match start/restart only, not every goal
## restart (which stays instant, matching existing tested behavior).
enum MatchPhase { PRE_MATCH, KICKOFF, PLAYING }
## Kept genuinely brief (not a cinematic pause) so it reads as "the whistle
## just blew" rather than a loading screen -- long enough to be a real,
## visible hold; short enough to stay well inside the generous
## movement-outcome windows the rest of the game (and its tests) already
## use everywhere else.
const KICKOFF_DURATION := 0.35

var match_phase: int = MatchPhase.PRE_MATCH
var _kickoff_timer: float = 0.0

var _football_player_scene: PackedScene = preload("res://scenes/FootballPlayer.tscn")

@onready var ball: BallController = $Ball
@onready var score_label: Label = $UI/ScoreLabel
@onready var goal_area_left: Area3D = $Field/GoalAreaLeft
@onready var goal_area_right: Area3D = $Field/GoalAreaRight
@onready var camera_controller: CameraController = $CameraRig
@onready var players_root: Node3D = $Players

var home_score: int = 0
var away_score: int = 0

## Simple count-up match clock in seconds, read by the HUD's timer label.
## Purely cosmetic -- nothing gameplay-relevant depends on it (no halves/
## injury time yet), so it just keeps counting and resets alongside score
## on restart_match().
var match_time_elapsed: float = 0.0

var home_players: Array = []
var away_players: Array = []

var possession_manager: PossessionManager
var home_team: TeamController
var away_team: TeamController
var player_controller: PlayerController
var match_mood: MatchMood
var personality_event_system: PersonalityEventSystem
var debug_overlay: PersonalityDebugOverlay

var _switch_key_was_pressed: bool = false
var _restart_key_was_pressed: bool = false
var _debug_key_was_pressed: bool = false


func _ready() -> void:
	goal_area_left.body_entered.connect(_on_goal_scored_left)
	goal_area_right.body_entered.connect(_on_goal_scored_right)

	_spawn_teams()
	_setup_controllers()
	_setup_debug_overlay()
	_update_score_label()

	var hud: Node = $UI.get_node_or_null("HUD")
	if hud:
		hud.match_manager = self

	_start_kickoff()


func _start_kickoff() -> void:
	match_phase = MatchPhase.KICKOFF
	_kickoff_timer = KICKOFF_DURATION


func _spawn_teams() -> void:
	home_players = _spawn_team(TestRoster.home_team(), 0, HOME_COLOR)
	away_players = _spawn_team(TestRoster.away_team(), 1, AWAY_COLOR)

	# Wired once, up front -- used only for the pass-direction assist (see
	# FootballPlayer._find_pass_target), never mutated per-frame.
	for p in home_players:
		p.set_match_context(home_players, away_players)
	for p in away_players:
		p.set_match_context(away_players, home_players)


func _spawn_team(roster: Array[PlayerData], team_id: int, color: Color) -> Array:
	var slots: Array = FormationManager.get_slots(FormationManager.DEFAULT_FORMATION)
	var result: Array = []

	for i in range(roster.size()):
		var data: PlayerData = roster[i]
		var slot: Dictionary = slots[i]
		var player: FootballPlayer = _football_player_scene.instantiate()
		players_root.add_child(player)

		player.team_id = team_id
		player.is_goalkeeper = (slot["role"] == "GK")
		player.formation_role = slot["role"]
		player.apply_player_data(data)

		player.formation_slot = slot["pos"]
		player.global_position = FormationManager.get_world_position(slot["pos"], team_id)
		player.set_team_color(color)

		result.append(player)

	return result


func _setup_controllers() -> void:
	possession_manager = PossessionManager.new()
	add_child(possession_manager)
	possession_manager.setup(home_players + away_players, ball)
	for p in home_players + away_players:
		p.set_possession_manager(possession_manager)

	match_mood = MatchMood.new()
	personality_event_system = PersonalityEventSystem.new()

	var home_goal: Vector3 = FormationManager.get_world_position(Vector2(-1, 0), 0)
	var away_goal: Vector3 = FormationManager.get_world_position(Vector2(-1, 0), 1)

	home_team = TeamController.new()
	home_team.team_id = 0
	add_child(home_team)
	home_team.setup(home_players, ball, possession_manager, home_goal, away_goal)
	home_team.set_personality_systems(match_mood, personality_event_system)

	away_team = TeamController.new()
	away_team.team_id = 1
	add_child(away_team)
	away_team.setup(away_players, ball, possession_manager, away_goal, home_goal)
	away_team.set_personality_systems(match_mood, personality_event_system)

	home_team.set_opponent_team(away_team)
	away_team.set_opponent_team(home_team)

	# The human is skipped by TeamController's own per-player loop, so this
	# is the only place they ever get a reference to their side's plan --
	# and execute_pass() needs one to evaluate a pass the way an AI pass is
	# evaluated (see FootballPlayer.team_plan).
	for p in home_players:
		p.set_team_plan(home_team.plan)
	for p in away_players:
		p.set_team_plan(away_team.plan)

	player_controller = PlayerController.new()
	add_child(player_controller)

	_set_human_player(home_players[DEFAULT_HUMAN_INDEX])


func _setup_debug_overlay() -> void:
	debug_overlay = PersonalityDebugOverlay.new()
	debug_overlay.match_manager = self
	$UI.add_child(debug_overlay)


func _physics_process(delta: float) -> void:
	if match_phase != MatchPhase.PLAYING:
		_kickoff_timer -= delta
		for player in home_players + away_players:
			player.movement_locked = true
		if _kickoff_timer <= 0.0:
			match_phase = MatchPhase.PLAYING
			for player in home_players + away_players:
				player.movement_locked = false
		return

	match_time_elapsed += delta

	if match_mood:
		match_mood.tick(delta)

	var tab_now := Input.is_key_pressed(KEY_TAB)
	var switch_requested: bool = InputState.switch_pressed or (tab_now and not _switch_key_was_pressed)
	_switch_key_was_pressed = tab_now
	InputState.switch_pressed = false

	if switch_requested:
		_switch_to_next_player()

	var r_now := Input.is_key_pressed(KEY_R)
	if r_now and not _restart_key_was_pressed:
		restart_match()
	_restart_key_was_pressed = r_now

	var f3_now := Input.is_key_pressed(KEY_F3)
	if f3_now and not _debug_key_was_pressed and debug_overlay:
		debug_overlay.toggle_visible()
	_debug_key_was_pressed = f3_now


## Switching considers distance to the ball, current possession, and
## attacking/defensive relevance -- not just "closest player" -- so it
## feels like picking the right teammate rather than blindly cycling.
## Falls back to plain next-index cycling if scoring can't pick anyone
## (e.g. only one player left).
func _switch_to_next_player() -> void:
	if home_players.is_empty():
		return
	var current: FootballPlayer = player_controller.controlled_player
	var candidates: Array = home_players.duplicate()
	candidates.erase(current)
	if candidates.is_empty():
		return

	var target: FootballPlayer = _select_switch_target(candidates)
	if target == null:
		var current_index: int = home_players.find(current)
		target = home_players[(current_index + 1) % home_players.size()]
	_set_human_player(target)


func _select_switch_target(candidates: Array) -> FootballPlayer:
	var ball_pos: Vector3 = ball.global_position
	var team_has_possession: bool = possession_manager and possession_manager.possessing_team == 0
	var ball_loose: bool = possession_manager == null or possession_manager.is_loose

	var best: FootballPlayer = null
	var best_score := -INF
	for p in candidates:
		var dist: float = p.global_position.distance_to(ball_pos)
		var score: float = -dist * SWITCH_DIST_WEIGHT
		score -= absf(p.global_position.z - ball_pos.z) * SWITCH_LATERAL_WEIGHT
		if dist > SWITCH_FAR_PENALTY_DISTANCE:
			score -= (dist - SWITCH_FAR_PENALTY_DISTANCE) * SWITCH_FAR_PENALTY_WEIGHT

		if p.is_goalkeeper:
			score -= SWITCH_GK_PENALTY

		if team_has_possession:
			# Attacking relevance: prefer a teammate positioned ahead of
			# the ball (further toward the opponent goal), a better
			# candidate to receive/support the attack than one who's
			# simply nearby but square or behind the ball.
			if p.global_position.x > ball_pos.x:
				score += SWITCH_RELEVANCE_BONUS
		elif not ball_loose:
			# Defensive danger: prefer a teammate positioned between the
			# ball and our own goal -- actually in a position to matter
			# defensively, not just whoever happens to be nearby upfield.
			if p.global_position.x < ball_pos.x:
				score += SWITCH_RELEVANCE_BONUS

		if score > best_score:
			best_score = score
			best = p
	return best


func _set_human_player(player: FootballPlayer) -> void:
	if player_controller.controlled_player:
		player_controller.controlled_player.set_controlled_visual(false)

	player_controller.set_controlled_player(player)
	player.set_controlled_visual(true)
	home_team.set_human_player(player)

	if camera_controller:
		camera_controller.set_target(player)
		camera_controller.set_ball(ball)


func _on_goal_scored_right(body: Node3D) -> void:
	if body.is_in_group("ball"):
		home_score += 1
		_after_goal(home_players, away_players)


func _on_goal_scored_left(body: Node3D) -> void:
	if body.is_in_group("ball"):
		away_score += 1
		_after_goal(away_players, home_players)


func _after_goal(scoring_team: Array, conceding_team: Array) -> void:
	_update_score_label()
	if match_mood:
		match_mood.notify_exciting_event()

	for player in scoring_team:
		player.play_celebration()
		player.react_to_goal(true)
	for player in conceding_team:
		player.react_to_goal(false)

	ball.reset_ball()
	_reset_all_players()


func restart_match() -> void:
	home_score = 0
	away_score = 0
	match_time_elapsed = 0.0
	_update_score_label()
	ball.reset_ball()
	_reset_all_players()
	_set_human_player(home_players[DEFAULT_HUMAN_INDEX])
	if match_mood:
		match_mood.notify_exciting_event()
	_start_kickoff()


func _reset_all_players() -> void:
	for player in home_players:
		_reset_player(player)
	for player in away_players:
		_reset_player(player)


func _reset_player(player: FootballPlayer) -> void:
	player.global_position = FormationManager.get_world_position(player.formation_slot, player.team_id)
	player.velocity = Vector3.ZERO
	# A player who was on the floor when the goal went in lines up for the
	# restart rather than serving out a knockdown from a passage of play that
	# no longer exists. The recovery phase is deliberately harder to leave than
	# the old timer was, so it has to be cleared explicitly here.
	player.clear_recovery_state()
	player.reset_intent()


func _update_score_label() -> void:
	score_label.text = "Home %d - %d Away" % [home_score, away_score]


## "MM:SS" for the HUD's match timer label.
func get_match_time_string() -> String:
	if match_phase != MatchPhase.PLAYING:
		return "KICKOFF"
	var total_seconds: int = int(match_time_elapsed)
	return "%02d:%02d" % [total_seconds / 60, total_seconds % 60]


## Debug/test hook: force a specific personality event onto a player right
## now, bypassing its probability roll and trigger check. Used by the F3
## debug overlay's forced-event shortcut and by automated tests that need
## a deterministic event without waiting on RNG.
func force_personality_event(player: FootballPlayer, event_id: String) -> bool:
	if personality_event_system == null:
		return false
	var team: TeamController = home_team if player.team_id == 0 else away_team
	var ctx: PersonalityContext = team._build_context(player)
	return personality_event_system.force_trigger(player, event_id, ctx)
