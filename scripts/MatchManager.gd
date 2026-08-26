extends Node3D

## Top-level orchestrator. Spawns both squads, wires up the (small,
## single-purpose) subsystems -- PossessionManager, TeamController x2,
## PlayerController, MatchMood, PersonalityEventSystem -- and owns
## match-level concerns: goal scoring, player switching, and match
## restart. Everything else lives in its own script; this file
## intentionally stays thin.

const HOME_COLOR := Color(0.964706, 0.960784, 0.309804, 1)
const AWAY_COLOR := Color(0.85, 0.16, 0.16, 1)
const DEFAULT_HUMAN_INDEX := 2  # index into home_players -- the MID

var _football_player_scene: PackedScene = preload("res://scenes/FootballPlayer.tscn")

@onready var ball: BallController = $Ball
@onready var score_label: Label = $UI/ScoreLabel
@onready var goal_area_left: Area3D = $Field/GoalAreaLeft
@onready var goal_area_right: Area3D = $Field/GoalAreaRight
@onready var camera_controller: CameraController = $CameraRig
@onready var players_root: Node3D = $Players

var home_score: int = 0
var away_score: int = 0

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


func _spawn_teams() -> void:
	home_players = _spawn_team(TestRoster.home_team(), 0, HOME_COLOR)
	away_players = _spawn_team(TestRoster.away_team(), 1, AWAY_COLOR)


func _spawn_team(roster: Array[PlayerData], team_id: int, color: Color) -> Array:
	var formation: Dictionary = FormationManager.get_slots("3_flat")
	var result: Array = []

	for i in range(roster.size()):
		var data: PlayerData = roster[i]
		var player: FootballPlayer = _football_player_scene.instantiate()
		players_root.add_child(player)

		player.team_id = team_id
		player.is_goalkeeper = (i == 0)
		player.apply_player_data(data)

		var slot: Vector2 = formation["GK"][0] if i == 0 else formation["OUT"][i - 1]
		player.formation_slot = slot
		player.global_position = FormationManager.get_world_position(slot, team_id)
		player.set_team_color(color)

		result.append(player)

	return result


func _setup_controllers() -> void:
	possession_manager = PossessionManager.new()
	add_child(possession_manager)
	possession_manager.setup(home_players + away_players, ball)

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

	player_controller = PlayerController.new()
	add_child(player_controller)

	_set_human_player(home_players[DEFAULT_HUMAN_INDEX])


func _setup_debug_overlay() -> void:
	debug_overlay = PersonalityDebugOverlay.new()
	debug_overlay.match_manager = self
	$UI.add_child(debug_overlay)


func _physics_process(delta: float) -> void:
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


func _switch_to_next_player() -> void:
	if home_players.is_empty():
		return
	var current_index: int = home_players.find(player_controller.controlled_player)
	var next_index: int = (current_index + 1) % home_players.size()
	_set_human_player(home_players[next_index])


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
	_update_score_label()
	ball.reset_ball()
	_reset_all_players()
	_set_human_player(home_players[DEFAULT_HUMAN_INDEX])
	if match_mood:
		match_mood.notify_exciting_event()


func _reset_all_players() -> void:
	for player in home_players:
		_reset_player(player)
	for player in away_players:
		_reset_player(player)


func _reset_player(player: FootballPlayer) -> void:
	player.global_position = FormationManager.get_world_position(player.formation_slot, player.team_id)
	player.velocity = Vector3.ZERO
	player.reset_intent()


func _update_score_label() -> void:
	score_label.text = "Home %d - %d Away" % [home_score, away_score]


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
