class_name PlayerData
extends Resource

## Reusable per-character stat block. Construct/modify these to define
## individual players; FootballPlayer.apply_player_data() maps them onto
## actual gameplay tunables.

@export var id: String = ""
@export var display_name: String = "Player"
@export_enum("GK", "DEF", "MID", "FWD") var position: String = "MID"

## Real physics units (m/s, m/s^2) -- tune directly.
@export var movement_speed: float = 5.0
@export var acceleration: float = 14.0
@export var sprint_speed: float = 8.5

## 0-100 skill ratings -- scaled onto gameplay tunables by FootballPlayer.
@export_range(0.0, 100.0) var passing: float = 70.0
@export_range(0.0, 100.0) var shooting: float = 70.0
@export_range(0.0, 100.0) var dribbling: float = 70.0
@export_range(0.0, 100.0) var stamina: float = 80.0
@export_range(0.0, 100.0) var defensive_ability: float = 60.0

@export_enum("Right", "Left") var preferred_foot: String = "Right"

## Key into CharacterRegistry for the 3D model to display for this
## character. Empty string = use the placeholder capsule. Swapping in a
## real model is purely a data change here -- no gameplay code involved.
@export var visual_id: String = ""
