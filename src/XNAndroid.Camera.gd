extends Node3D

@export var camera : Camera3D
@export var pose : PoseController

@export_group("Rotate")
@export var rotate_speed: float = 0.005

@export_group("Pan")
@export var pan_speed: float = 0.001  ## Scaled by zoom distance, so it feels consistent

@export_group("Zoom")
@export var zoom_step: float = 0.1  ## 0.1 = 10% per scroll tick
@export var min_distance: float = 0.3
@export var max_distance: float = 50.0

var _yaw: float = 0.0
var _pitch: float = 0.0
var _distance: float = 5.0

func _ready() -> void:
	if camera == null:
		camera = get_node_or_null("Camera3D") as Camera3D
	if camera == null:
		push_error("CameraRig: no Camera3D assigned or found as a child.")
		set_process_unhandled_input(false)
		return

	_distance = clampf(camera.position.length(), min_distance, max_distance)
	_yaw = rotation.y
	_pitch = rotation.x
	_apply()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var mask: int = event.button_mask
		if ( mask & MOUSE_BUTTON_MASK_LEFT ) and not ( pose and pose.is_manipulating( ) ):
			_yaw -= event.relative.x * rotate_speed
			_pitch = clampf(_pitch - event.relative.y * rotate_speed, -PI / 2.0 + 0.01, PI / 2.0 - 0.01)
			_apply()
		elif mask & MOUSE_BUTTON_MASK_MIDDLE:
			var right: Vector3 = global_transform.basis.x
			var up: Vector3 = global_transform.basis.y
			var offset: Vector3 = (-right * event.relative.x + up * event.relative.y) * pan_speed * _distance
			global_position += offset
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_distance = clampf(_distance * (1.0 - zoom_step), min_distance, max_distance)
			_apply()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_distance = clampf(_distance * (1.0 + zoom_step), min_distance, max_distance)
			_apply()

func _apply() -> void:
	rotation = Vector3(_pitch, _yaw, 0.0)
	camera.position = Vector3(0.0, 0.0, _distance)
