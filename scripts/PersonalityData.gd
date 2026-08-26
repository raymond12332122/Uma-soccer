class_name PersonalityData
extends Resource

## Reusable per-character personality profile. Separate from PlayerData:
## PlayerData.movement_speed/passing/shooting/etc. determine football
## *ability*; these traits determine behavioral *tendencies*. A character
## can be technically excellent but chaotic, or average but disciplined --
## the two axes vary independently on purpose.
##
## All traits are normalized 0-100. AIController reads these to modify
## continuous decisions (formation adherence, sprint eagerness, shoot
## range, marking tightness, spacing); PersonalityEventSystem reads them
## to gate which spontaneous events a character can trigger at all.

@export_range(0.0, 100.0) var confidence: float = 50.0
@export_range(0.0, 100.0) var discipline: float = 50.0
@export_range(0.0, 100.0) var aggression: float = 50.0
@export_range(0.0, 100.0) var competitiveness: float = 50.0
@export_range(0.0, 100.0) var playfulness: float = 50.0
@export_range(0.0, 100.0) var impulsiveness: float = 50.0
@export_range(0.0, 100.0) var composure: float = 50.0
@export_range(0.0, 100.0) var teamwork: float = 50.0
## Higher = manages stamina better (less wasteful sprinting). This is the
## *tendency*; actual stamina drain/regen numbers stay on PlayerData/FootballPlayer.
@export_range(0.0, 100.0) var stamina_management: float = 50.0
@export_range(0.0, 100.0) var tactical_awareness: float = 50.0
@export_range(0.0, 100.0) var showmanship: float = 50.0
## Higher = lazier / less motivated when the match is calm.
@export_range(0.0, 100.0) var laziness: float = 50.0
@export_range(0.0, 100.0) var risk_taking: float = 50.0
