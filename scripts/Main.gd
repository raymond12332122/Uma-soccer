extends Node3D

@onready var ball: RigidBody3D = $Ball
@onready var score_label: Label = $UI/ScoreLabel
@onready var goal_area_left: Area3D = $Field/GoalAreaLeft
@onready var goal_area_right: Area3D = $Field/GoalAreaRight

var score: int = 0


func _ready() -> void:
	goal_area_left.body_entered.connect(_on_goal_scored)
	goal_area_right.body_entered.connect(_on_goal_scored)
	_update_score_label()


func _on_goal_scored(body: Node3D) -> void:
	if body.is_in_group("ball"):
		score += 1
		_update_score_label()
		ball.reset_ball()


func _update_score_label() -> void:
	score_label.text = "Goals: %d" % score
