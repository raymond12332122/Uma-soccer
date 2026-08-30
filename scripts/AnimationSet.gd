class_name AnimationSet
extends RefCounted

## v0.9.2.1: the clip database (brief sections 2, 3, 11, 12).
##
## Every one of the 54 clips in the pack appears exactly once below, either
## under an INTENT it serves or in DEFERRED with the reason. Nothing outside
## this file names a clip: gameplay asks for "pass" or "save" and this decides
## what that looks like.
##
## ROLE SEPARATION IS THE POINT OF THE REWRITE. Human QA saw goalkeeper
## animations on strikers, midfielders and defenders. The v0.9.2 lookup walked
## the outfield table and then the keeper table, so any keeper intent was
## reachable by any player -- nothing was calling for one yet, but the
## structure permitted it, and the moment the keeper set grew from 4 clips to
## 22 it would have been a matter of time.
##
## Now every intent carries a Role, and AnimationController refuses an intent
## whose role does not match the player's. An outfield striker cannot select
## a dive, and a keeper cannot select a slide tackle, because the data says
## so -- not because no call site happens to do it.
##
## Every timing number is MEASURED by tests/diag_anim_inventory.gd on the
## retargeted clip, and re-running that tool reproduces them. They are not
## inferred from filenames, which were wrong about several of them.

enum Role {
	OUTFIELD,    ## anyone whose job is not keeping goal
	GOALKEEPER,  ## the keeper only
	ANY,         ## locomotion and other things every body does
}

enum Category {
	LOCOMOTION,
	IDLE,
	PASS,
	SHOT,
	HEADER,
	RECEIVE,
	BALL_SKILL,
	TACKLE,
	REACTION,
	FALL,
	GOALKEEPER,
	OTHER,
}

## Playback starts at the clip's own beginning rather than at a contact frame.
## Used where gameplay gives real warning -- a challenge, a keeper's dive, a
## player getting back up.
const WIND_UP := -1.0

# ---------------------------------------------------------------------------
# Locomotion
# ---------------------------------------------------------------------------

## Direction points for the locomotion blend space, in (right, forward) units,
## where right is the CHARACTER's right (see MODEL_RIGHT).
##
## Measured relative to 'jog forward'; the filenames' own left/right labelling
## matched the measurement:
##
##   clip                        angle    travel   duration   natural speed
##   jog forward                   0.0     2.15m     0.82s      2.62 m/s
##   jog forward diagonal        +45.0     2.31m     0.78s      2.95 m/s
##   jog forward diagonal (2)    -45.4     2.27m     0.83s      2.73 m/s
##   jog strafe right            +89.8     1.76m     0.72s      2.45 m/s
##   jog strafe left             -90.0     2.11m     0.70s      3.01 m/s
##   jog backward diagonal      +134.5     1.68m     0.72s      2.35 m/s
##   jog backward diagonal (2)  -135.5     2.13m     0.82s      2.61 m/s
##   jog backward               +-180.0    1.90m     0.78s      2.43 m/s
const LOCOMOTION := {
	"jog forward": Vector2(0.0, 1.0),
	"jog forward diagonal": Vector2(0.707, 0.707),
	"jog forward diagonal (2)": Vector2(-0.707, 0.707),
	"jog strafe right": Vector2(1.0, 0.0),
	"jog strafe left": Vector2(-1.0, 0.0),
	"jog backward diagonal": Vector2(0.707, -0.707),
	"jog backward diagonal (2)": Vector2(-0.707, -0.707),
	"jog backward": Vector2(0.0, -1.0),
}

const IDLE_CLIP := "offensive idle"
const IDLE_CLIP_KEEPER := "goalkeeper idle"

## Mean ground speed of the eight locomotion clips ON THE PACK SKELETON. Kept
## as the reference the rendered figures are sanity-checked against; it is NOT
## what the game divides by.
const PACK_NATURAL_SPEED := 2.64

## Ground speed a locomotion clip covers on a RENDERED character at 1x, after
## retargeting and the 1.6m height normalisation. Per character because the
## roster differs by 19%: same total height, different leg-to-height ratio.
const RENDERED_NATURAL_SPEED_BY_VISUAL := {
	"agnes_digital": 2.93,
	"air_groove": 3.38,
	"gold_ship": 3.49,
	"grass_wonder": 3.12,
	"mejiro_mcqueen": 3.26,
	"oguri_cap": 3.42,
	"silence_suzuka": 3.30,
	"symboli_rudolf": 3.38,
	"tamamo_cross": 2.87,
	"tm_opera_o": 3.20,
	"tokai_teio": 3.08,
}
const RENDERED_NATURAL_SPEED := 3.22

## Playback rate band. Below the floor the legs crawl while the body slides;
## above the ceiling a jog clip stops reading as a person running. The game's
## 8.5 m/s sprint is about 2.6x the gait, so the ceiling IS reached and
## sprinting slides -- measured and reported, not hidden.
const RATE_MIN := 0.55
const RATE_MAX := 1.90

const IDLE_SPEED := 0.30
const FULL_MOVE_SPEED := 1.60

## Yaw correction for every character model (section 18). MEASURED as zero:
## the pack and all 11 rigs face the model's local +Z, already this game's
## forward.
const MODEL_YAW_OFFSET_DEGREES := 0.0

## The character's own RIGHT in the model's local frame.
##
## Not +X. Godot is right-handed with a node's forward at -Z, while this
## project faces players along +Z, so right = forward x up = -X. Feeding the
## blend space +X plays the strafe-LEFT clip when a player moves right.
const MODEL_RIGHT := Vector3(-1.0, 0.0, 0.0)

# ---------------------------------------------------------------------------
# Intents
# ---------------------------------------------------------------------------

## Gameplay intent -> role, category, and one or more clips to choose from.
##
## Per clip:
##   clip    the file
##   start   where playback begins, in clip seconds. WIND_UP means the clip's
##           own start; otherwise it is the measured contact time, so the boot
##           is driving through the ball on frame one.
##   tail    how much is kept after `start`, so an action cannot lock the body
##
## WHY MOST STRIKES START AT CONTACT: gameplay decides to pass and launches
## the ball on the same frame -- FootballPlayer's own event documentation says
## action_started "fires on the same frame as the contact today (the
## simulation has no wind-up)". Delaying the ball to wait for the animation
## would make the animation authoritative over gameplay, which is forbidden.
## So a strike starts AT its contact frame and what plays is the
## follow-through. That is a cost, not a solved problem: measured at 0.43m of
## ball travel before the clip reaches full weight.
##
## Several intents list more than one clip. That is for variety, and the
## choice is made per use; it is not a claim that each is separately
## triggered by a distinct game state.
const INTENTS := {
	# --- outfield: striking the ball ---
	"pass": {
		"role": Role.OUTFIELD, "category": Category.PASS,
		"fade_in": 0.07, "fade_out": 0.18,
		"clips": [{"clip": "soccer penalty kick", "start": 0.74, "tail": 0.55}],
	},
	"shoot": {
		"role": Role.OUTFIELD, "category": Category.SHOT,
		"fade_in": 0.07, "fade_out": 0.25,
		"clips": [{"clip": "soccer penalty kick", "start": 0.74, "tail": 0.76}],
	},
	## Shooting on the run. 'strike foward jog' bakes a run-up into the clip
	## and travels 3.12m, which is why v0.9.2 deferred it -- but root
	## translation is stripped from every clip at build time, so that
	## objection no longer applies and the clip is simply a strike taken
	## mid-stride, which is what most shots in this game are.
	"shoot_running": {
		"role": Role.OUTFIELD, "category": Category.SHOT,
		"fade_in": 0.07, "fade_out": 0.25,
		"clips": [{"clip": "strike foward jog", "start": 0.44, "tail": 0.86}],
	},
	"header": {
		"role": Role.OUTFIELD, "category": Category.HEADER,
		"fade_in": 0.08, "fade_out": 0.25,
		"clips": [
			{"clip": "header soccerball", "start": 0.42, "tail": 0.90},
			{"clip": "header soccerball (2)", "start": 0.18, "tail": 1.10},
		],
	},

	# --- outfield: controlling the ball ---
	"touch": {
		"role": Role.OUTFIELD, "category": Category.BALL_SKILL,
		"fade_in": 0.06, "fade_out": 0.14,
		"clips": [{"clip": "kneeing soccerball (2)", "start": 0.12, "tail": 0.45}],
	},
	"trap": {
		"role": Role.OUTFIELD, "category": Category.BALL_SKILL,
		"fade_in": 0.10, "fade_out": 0.20,
		"clips": [
			{"clip": "stall soccerball (4)", "start": 1.40, "tail": 0.42},
			{"clip": "stall soccerball", "start": 2.85, "tail": 0.40},
			{"clip": "stall soccerball (2)", "start": 1.83, "tail": 0.29},
			{"clip": "stall soccerball (3)", "start": 2.01, "tail": 0.29},
		],
	},
	"receive": {
		"role": Role.OUTFIELD, "category": Category.RECEIVE,
		"fade_in": 0.10, "fade_out": 0.20,
		"clips": [{"clip": "receive soccerball", "start": 0.55, "tail": 0.90}],
	},

	# --- outfield: challenging ---
	##
	## ALL THREE tackle clips put the player ON THE FLOOR. Measured by
	## tests/diag_clip_posture.gd, which samples hips height against the rig's
	## own standing rest height across the window the game actually plays:
	##
	##   soccer tackle       min hips 0.16 of rest   GROUNDED
	##   soccer tackle (3)   min hips 0.18 of rest   GROUNDED
	##   soccer tackle (2)   min hips 0.23 of rest   GROUNDED
	##
	## v0.9.2 called 'soccer tackle (3)' the STANDING challenge, on the
	## grounds that it has no root travel while the other two cover 4m. Zero
	## travel does not mean upright: it is a tackle from a standstill that
	## still puts the player on the ground. That misclassification is what
	## human QA saw as outfield players in grounded, keeper-looking poses --
	## the clip is correctly role-gated and was simply the wrong clip.
	##
	## So there is only ONE challenge intent now, and it means a committed
	## slide. The pack contains no upright standing-tackle clip, so ordinary
	## pressing plays no full-body clip at all; locomotion already shows a
	## defender closing in. Same reasoning as dribble knock-ons.
	"challenge_slide": {
		"role": Role.OUTFIELD, "category": Category.TACKLE,
		"fade_in": 0.10, "fade_out": 0.30,
		"clips": [
			{"clip": "soccer tackle (2)", "start": WIND_UP, "tail": 1.40},
			{"clip": "soccer tackle", "start": WIND_UP, "tail": 1.60},
			{"clip": "soccer tackle (3)", "start": WIND_UP, "tail": 1.20},
		],
	},

	# --- being knocked over: ANY role ---
	#
	# Not outfield-specific. Going down and getting back up are things a body
	# does, not skills a position has, and a keeper carrying the ball can be
	# fouled like anyone else -- which is precisely what the live-match role
	# check caught: a fouled keeper asked for an intent marked OUTFIELD and
	# was refused, so the keeper stayed upright through a foul.
	"tripped": {
		"role": Role.ANY, "category": Category.FALL,
		"fade_in": 0.05, "fade_out": 0.25,
		"clips": [{"clip": "soccer trip", "start": WIND_UP, "tail": 1.60}],
	},
	"fallen": {
		"role": Role.ANY, "category": Category.FALL,
		"fade_in": 0.10, "fade_out": 0.25,
		"clips": [{"clip": "fallen idle", "start": WIND_UP, "tail": 1.50}],
	},
	"get_up": {
		"role": Role.ANY, "category": Category.REACTION,
		"fade_in": 0.10, "fade_out": 0.25,
		"clips": [{"clip": "standing up", "start": WIND_UP, "tail": 1.65}],
	},

	# --- goalkeeper: stopping the ball ---
	## The keeper's dives and blocks start from their own beginning: a save is
	## committed to from GK_SAVE_TIME (1.1s) of warning, the one place in the
	## game where a wind-up has room to play.
	"save_left": {
		"role": Role.GOALKEEPER, "category": Category.GOALKEEPER,
		"fade_in": 0.06, "fade_out": 0.30,
		"clips": [{"clip": "goalkeeper diving save", "start": WIND_UP, "tail": 1.60}],
	},
	"save_right": {
		"role": Role.GOALKEEPER, "category": Category.GOALKEEPER,
		"fade_in": 0.06, "fade_out": 0.30,
		"clips": [{"clip": "goalkeeper diving save (2)", "start": WIND_UP, "tail": 1.60}],
	},
	"block": {
		"role": Role.GOALKEEPER, "category": Category.GOALKEEPER,
		"fade_in": 0.08, "fade_out": 0.25,
		"clips": [
			{"clip": "goalkeeper body block", "start": WIND_UP, "tail": 1.30},
			{"clip": "goalkeeper body block (2)", "start": WIND_UP, "tail": 1.20},
			{"clip": "goalkeeper body block (3)", "start": WIND_UP, "tail": 1.60},
		],
	},
	"catch": {
		"role": Role.GOALKEEPER, "category": Category.GOALKEEPER,
		"fade_in": 0.08, "fade_out": 0.25,
		"clips": [
			{"clip": "goalkeeper catch", "start": WIND_UP, "tail": 1.40},
			{"clip": "goalkeeper catch (2)", "start": WIND_UP, "tail": 1.25},
			{"clip": "goalkeeper catch (3)", "start": WIND_UP, "tail": 1.60},
			{"clip": "goalkeeper catch (4)", "start": WIND_UP, "tail": 1.60},
		],
	},
	"scoop": {
		"role": Role.GOALKEEPER, "category": Category.GOALKEEPER,
		"fade_in": 0.10, "fade_out": 0.25,
		"clips": [{"clip": "goalkeeper scoop", "start": WIND_UP, "tail": 1.60}],
	},
	## Beaten. Fires when a keeper committed to a save and the ball went past.
	"gk_miss": {
		"role": Role.GOALKEEPER, "category": Category.GOALKEEPER,
		"fade_in": 0.08, "fade_out": 0.30,
		"clips": [{"clip": "goalkeeper miss", "start": WIND_UP, "tail": 1.60}],
	},

	# --- goalkeeper: moving and organising ---
	"sidestep_left": {
		"role": Role.GOALKEEPER, "category": Category.GOALKEEPER,
		"fade_in": 0.06, "fade_out": 0.12,
		"clips": [{"clip": "goalkeeper sidestep", "start": WIND_UP, "tail": 0.52}],
	},
	"sidestep_right": {
		"role": Role.GOALKEEPER, "category": Category.GOALKEEPER,
		"fade_in": 0.06, "fade_out": 0.12,
		"clips": [{"clip": "goalkeeper sidestep (2)", "start": WIND_UP, "tail": 0.50}],
	},
	## Organising the defence while play is far away. v0.9.2 deferred these as
	## "7 seconds of pointing with no gameplay state that means it" -- but a
	## keeper whose intent is POSITION with the ball 30m upfield is exactly
	## that state, and it is the keeper's most common one.
	"gk_organise": {
		"role": Role.GOALKEEPER, "category": Category.GOALKEEPER,
		"fade_in": 0.20, "fade_out": 0.35,
		"clips": [
			{"clip": "goalkeeper directing", "start": WIND_UP, "tail": 2.50},
			{"clip": "goalkeeper directing (2)", "start": WIND_UP, "tail": 2.50},
		],
	},

	# --- goalkeeper: with the ball ---
	"distribute_kick": {
		"role": Role.GOALKEEPER, "category": Category.GOALKEEPER,
		"fade_in": 0.08, "fade_out": 0.25,
		"clips": [{"clip": "goalkeeper drop kick", "start": 2.09, "tail": 1.00}],
	},
	"distribute_throw": {
		"role": Role.GOALKEEPER, "category": Category.GOALKEEPER,
		"fade_in": 0.08, "fade_out": 0.25,
		"clips": [{"clip": "goalkeeper overhand throw", "start": 1.79, "tail": 1.00}],
	},
	"distribute_pass": {
		"role": Role.GOALKEEPER, "category": Category.GOALKEEPER,
		"fade_in": 0.08, "fade_out": 0.25,
		"clips": [{"clip": "goalkeeper pass", "start": 0.64, "tail": 0.80}],
	},
	"place_ball": {
		"role": Role.GOALKEEPER, "category": Category.GOALKEEPER,
		"fade_in": 0.12, "fade_out": 0.25,
		"clips": [
			{"clip": "goalkeeper placing ball", "start": WIND_UP, "tail": 2.00},
			{"clip": "goalkeeper placing ball (2)", "start": WIND_UP, "tail": 2.50},
		],
	},
}

## The keeper's second idle, used as a looping state rather than a one-shot.
const IDLE_CLIP_KEEPER_ALT := "goalkeeper idle (2)"

## Older names kept working, so a call site that says "tackle" still means a
## challenge. Semantic aliases, not clip names.
const ALIASES := {
	"tackle": "challenge_slide",
	"challenge": "challenge_slide",
	"slide": "challenge_slide",
}

## Clips deliberately not connected, with the reason. Listed so the counts can
## be checked against the pack and a later milestone can pick them up
## knowingly rather than rediscovering them.
##
## The three 'kick' clips are the notable ones: they are the obvious names to
## reach for and they are the wrong choice, because almost nothing remains
## after the boot meets the ball, and the follow-through is the only part
## gameplay leaves room to show.
const DEFERRED := {
	"kick soccerball": "0.06s remains after contact; nothing visible to play",
	"kick soccerball (2)": "0.09s remains after contact; nothing visible to play",
	"kick up soccerball": "0.10s remains after contact; nothing visible to play",
	"kneeing soccerball": "0.14s after contact; the (2) variant gives 0.51s",
	"throw in": "no throw-in state exists; the ball is never out of play yet",
	"transition": "unidentifiable 0.77s clip, no measurable foot event",
	"scissor kick": "a bicycle kick, hips at 0.14 of rest -- genuinely grounded. Correct for a spectacular overhead volley and wrong for the ordinary airborne-ball shot that was triggering it, which is the same 'inappropriate grounded pose' QA reported. Deferred until there is a gameplay state that means an overhead volley specifically.",
}


# ---------------------------------------------------------------------------
# Queries
# ---------------------------------------------------------------------------

## Resolve an intent for a player of this role.
##
## Returns {} when the intent does not exist OR when it belongs to the other
## role. That second case is the whole point: an outfield player asking for
## "save_left" gets nothing back, structurally, whatever the call site
## intended.
static func resolve(intent: String, role: int) -> Dictionary:
	var name: String = ALIASES.get(intent, intent)
	if not INTENTS.has(name):
		return {}
	var entry: Dictionary = INTENTS[name]
	if not allowed(name, role):
		return {}
	return entry


## May a player of this role use this intent at all?
static func allowed(intent: String, role: int) -> bool:
	var name: String = ALIASES.get(intent, intent)
	if not INTENTS.has(name):
		return false
	var want: int = INTENTS[name]["role"]
	return want == Role.ANY or want == role


## Library key for one clip option of an intent.
static func variant_key(intent: String, index: int) -> String:
	return "%s#%d" % [ALIASES.get(intent, intent), index]


## How many clip options an intent has.
static func variant_count(intent: String) -> int:
	var name: String = ALIASES.get(intent, intent)
	return INTENTS[name]["clips"].size() if INTENTS.has(name) else 0


static func natural_speed(visual_id: String) -> float:
	return RENDERED_NATURAL_SPEED_BY_VISUAL.get(visual_id, RENDERED_NATURAL_SPEED)


## Every clip file this table refers to, for the build step and the counts.
static func all_mapped_clips() -> Array:
	var out: Array = []
	for c in LOCOMOTION:
		out.append(c)
	for c in [IDLE_CLIP, IDLE_CLIP_KEEPER, IDLE_CLIP_KEEPER_ALT]:
		if not (c in out):
			out.append(c)
	for intent in INTENTS:
		for opt in INTENTS[intent]["clips"]:
			if not (opt["clip"] in out):
				out.append(opt["clip"])
	return out


## Clip counts per category, for the report (section 12).
static func category_counts() -> Dictionary:
	var out := {}
	for intent in INTENTS:
		var cat: int = INTENTS[intent]["category"]
		var key: String = Category.keys()[cat]
		var seen: Array = out.get(key, [])
		for opt in INTENTS[intent]["clips"]:
			if not (opt["clip"] in seen):
				seen.append(opt["clip"])
		out[key] = seen
	out["LOCOMOTION"] = LOCOMOTION.keys()
	out["IDLE"] = [IDLE_CLIP, IDLE_CLIP_KEEPER, IDLE_CLIP_KEEPER_ALT]
	return out
