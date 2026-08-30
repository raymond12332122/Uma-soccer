extends Node3D

## LEVEL 3 validation: watch an actual match through the real camera.
##
## Saves the rendered frame on a fixed cadence with the camera position in the
## filename, and reports the extremes the camera reached, so the containment in
## CameraController can be checked against what the shipped follow logic
## actually produces rather than against a scripted pose list.

const MainScene := preload("res://scenes/Main.tscn")
const SECONDS := 90
const SHOT_EVERY := 90
const SHOT_DIR := "user://rendered"

var _cam_min := Vector3(INF, INF, INF)
var _cam_max := Vector3(-INF, -INF, -INF)


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(SHOT_DIR)
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	for i in range(90):
		await get_tree().process_frame
	var cam: Camera3D = get_viewport().get_camera_3d()
	var ball: Node3D = main.ball

	for i in range(SECONDS * 60):
		await get_tree().process_frame
		var p: Vector3 = cam.global_position
		_cam_min = Vector3(minf(_cam_min.x, p.x), minf(_cam_min.y, p.y), minf(_cam_min.z, p.z))
		_cam_max = Vector3(maxf(_cam_max.x, p.x), maxf(_cam_max.y, p.y), maxf(_cam_max.z, p.z))
		if i % SHOT_EVERY == 0:
			var img: Image = get_viewport().get_texture().get_image()
			img.save_png("%s/t%04d_cam%+06.1f%+06.1f_ball%+06.1f%+06.1f.png" % [
				SHOT_DIR, i / 60, p.x, p.z,
				ball.global_position.x, ball.global_position.z])

	print("RENDER: camera reached x %.2f..%.2f  y %.2f..%.2f  z %.2f..%.2f" % [
		_cam_min.x, _cam_max.x, _cam_min.y, _cam_max.y, _cam_min.z, _cam_max.z])
	print("RENDER: limits are |x| <= %.2f and z >= %.2f" % [
		CameraController.CAMERA_X_LIMIT, CameraController.CAMERA_Z_FORWARD_LIMIT])
	var ok: bool = absf(_cam_min.x) <= CameraController.CAMERA_X_LIMIT + 0.01 \
		and absf(_cam_max.x) <= CameraController.CAMERA_X_LIMIT + 0.01 \
		and _cam_min.z >= CameraController.CAMERA_Z_FORWARD_LIMIT - 0.01
	print("RENDER: containment held: %s" % str(ok))
	get_tree().quit()
