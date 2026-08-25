extends Node3D

@onready var ball: RigidBody3D = $Ball
@onready var player: CharacterBody3D = $Player
@onready var score_label: Label = $UI/ScoreLabel
@onready var goal_area_left: Area3D = $Field/GoalAreaLeft
@onready var goal_area_right: Area3D = $Field/GoalAreaRight

var score: int = 0
var _player_spawn_transform: Transform3D
var _r_was_pressed: bool = false


func _ready() -> void:
	goal_area_left.body_entered.connect(_on_goal_scored)
	goal_area_right.body_entered.connect(_on_goal_scored)
	_player_spawn_transform = player.global_transform
	_update_score_label()


func _process(_delta: float) -> void:
	var r_now := Input.is_key_pressed(KEY_R)
	if r_now and not _r_was_pressed:
		restart_match()
	_r_was_pressed = r_now


func _on_goal_scored(body: Node3D) -> void:
	if body.is_in_group("ball"):
		score += 1
		_update_score_label()
		ball.reset_ball()


func restart_match() -> void:
	score = 0
	_update_score_label()
	ball.reset_ball()
	player.global_transform = _player_spawn_transform
	player.velocity = Vector3.ZERO


func _update_score_label() -> void:
	score_label.text = "Goals: %d" % score
