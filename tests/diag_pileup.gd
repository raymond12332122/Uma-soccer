extends Node3D

## v0.9.1 diagnostic: did enabling player-vs-player collision create pileups?
##
## Players have never collided with one another in this project --
## FootballPlayer.tscn carried collision_mask = 5 (world + ball), omitting
## layer 2 -- so twenty-two bodies have always passed through each other.
## Turning that on is the fix for "defenders phase through the carrier", and
## it is also the single largest behavioural change in v0.9.1: every AI
## movement, formation slot and challenge approach was tuned in a world
## without body contact.
##
## The brief warns specifically against trading phasing for "rigid body
## piles where 10 players get stuck". This measures exactly that:
##
##   STUCK        -- a player who wants to move but is not moving
##   OVERLAP      -- pairs closer than two capsule radii
##   CLUSTER      -- the largest number of players inside a small radius

const MainScene := preload("res://scenes/Main.tscn")

const CAPSULE_DIAMETER := 0.8
const SECONDS := 60


func _ready() -> void:
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	await get_tree().physics_frame
	for i in range(120):
		await get_tree().physics_frame

	var players: Array = main.home_players + main.away_players
	var stuck_frames := 0
	var moving_frames := 0
	var overlap_frames := 0
	var worst_overlap := CAPSULE_DIAMETER
	var worst_cluster := 0
	var longest_stuck := 0
	var stuck_run := {}

	for i in range(SECONDS * 60):
		await get_tree().physics_frame
		for p in players:
			# "Wants to move but isn't": intent present, velocity near zero.
			var wants: bool = p.move_input.length() > 0.3
			var speed: float = Vector2(p.velocity.x, p.velocity.z).length()
			if wants:
				moving_frames += 1
				if speed < 0.4:
					stuck_frames += 1
					stuck_run[p] = stuck_run.get(p, 0) + 1
					longest_stuck = maxi(longest_stuck, stuck_run[p])
				else:
					stuck_run[p] = 0

			var near := 0
			for q in players:
				if q == p:
					continue
				var d: float = Vector2(p.global_position.x - q.global_position.x,
					p.global_position.z - q.global_position.z).length()
				if d < CAPSULE_DIAMETER:
					overlap_frames += 1
					worst_overlap = minf(worst_overlap, d)
				if d < 2.5:
					near += 1
			worst_cluster = maxi(worst_cluster, near + 1)

	print("DIAG-PILE: over %ds of live 11v11" % SECONDS)
	print("DIAG-PILE:   wants-to-move frames: %d, of which stuck: %d (%.1f%%)" % [
		moving_frames, stuck_frames, 100.0 * stuck_frames / maxf(moving_frames, 1)])
	print("DIAG-PILE:   longest continuous stuck run: %d frames (%.2fs)" % [
		longest_stuck, longest_stuck / 60.0])
	print("DIAG-PILE:   overlapping pair-frames: %d, closest pair %.2fm (capsules meet at %.2fm)" % [
		overlap_frames, worst_overlap, CAPSULE_DIAMETER])
	print("DIAG-PILE:   biggest cluster within 2.5m: %d players" % worst_cluster)
	get_tree().quit()
