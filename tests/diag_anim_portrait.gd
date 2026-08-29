extends Node3D

## v0.9.2: look at the characters up close (brief sections 18, 23, 30).
##
## The match playtest renders a character 57 pixels tall, which is enough to
## confirm they are the right size and not standing in a T-pose and nothing
## else. This puts a camera two metres from three different rigs, running the
## real locomotion clip through the real AnimationController, and captures
## front and side views mid-stride.
##
## It exists because the things most likely to be wrong here are things only
## an eye catches: a character facing away from the direction it runs, an arm
## through a torso, a hip rotated ninety degrees by a bad bone map. Section 23
## asks for more than one character precisely because a bone map that happens
## to fit Gold Ship is not evidence about Tamamo Cross.
##
## Run windowed:
##   DISPLAY=:88 XDG_RUNTIME_DIR=/tmp/xdgrun LIBGL_ALWAYS_SOFTWARE=1 \
##     godot --path . --rendering-driver opengl3 --display-driver x11 \
##     tests/DiagAnimPortrait.tscn

const SHOT_DIR := "user://v092_portraits"
const SUBJECTS := ["gold_ship", "tamamo_cross", "silence_suzuka"]
## Ground speeds to pose at: standing, a jog, and flat out.
const SPEEDS := [0.0, 5.0, 8.5]


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, 140, 0)
	add_child(light)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.18, 0.35, 0.22)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.7, 0.7, 0.75)
	e.ambient_light_energy = 0.7
	env.environment = e
	add_child(env)

	var cam := Camera3D.new()
	add_child(cam)

	for i in range(SUBJECTS.size()):
		var visual_id: String = SUBJECTS[i]
		# The real controller, built exactly as a match builds it, so what is
		# photographed is the shipped path and not a rig loaded by hand.
		var holder := Node3D.new()
		add_child(holder)
		var ac := AnimationController.new()
		holder.add_child(ac)
		ac.set_visual(visual_id)
		await get_tree().process_frame

		for speed in SPEEDS:
			# Facing +Z, running along +Z: forward locomotion.
			ac.set_motion(Vector3(0, 0, speed))
			ac._drive_tree()
			# Let the gait advance to mid-stride rather than catching the
			# first frame of the loop, which is a near-neutral pose on every
			# clip and would hide a broken leg.
			for f in range(24):
				await get_tree().process_frame

			for view in [["front", Vector3(0, 1.0, 2.6)], ["side", Vector3(2.6, 1.0, 0.0)]]:
				cam.global_position = holder.global_position + (view[1] as Vector3)
				cam.look_at(holder.global_position + Vector3(0, 0.85, 0))
				await RenderingServer.frame_post_draw
				var img: Image = get_viewport().get_texture().get_image()
				var path: String = "%s/%s_%.0f_%s.png" % [SHOT_DIR, visual_id, speed, view[0]]
				img.save_png(ProjectSettings.globalize_path(path))
				print("PORTRAIT: %s" % ProjectSettings.globalize_path(path))

		var tree: AnimationTree = ac.get_node_or_null("AnimationTree")
		print("PORTRAIT: %-16s animated=%s height=%.3fm rate=%.2f" % [
			visual_id, ac.is_animated(),
			ac.last_measured_height * (ac.get_child(0) as Node3D).scale.y,
			float(tree.get("parameters/MoveScale/scale")) if tree else -1.0])
		holder.queue_free()
		await get_tree().process_frame

	get_tree().quit()
