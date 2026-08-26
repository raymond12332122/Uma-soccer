class_name MatchMood
extends RefCounted

## Tracks "how eventful has the match been lately" for personality
## triggers like "match is calm" / "long period without exciting action".
## One instance lives on MatchManager; goal scoring and tackles reset the
## clock via notify_exciting_event().

const CALM_THRESHOLD := 12.0
const LONG_CALM_THRESHOLD := 25.0

var time_since_exciting_event: float = 0.0


func tick(delta: float) -> void:
	time_since_exciting_event += delta


func notify_exciting_event() -> void:
	time_since_exciting_event = 0.0


func is_calm() -> bool:
	return time_since_exciting_event > CALM_THRESHOLD


func is_long_calm() -> bool:
	return time_since_exciting_event > LONG_CALM_THRESHOLD
