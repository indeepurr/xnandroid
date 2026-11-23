class_name CameraRig
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

@export_group("Touch")
@export var pinch_zoom_speed: float = 1.0  ## 1 = the distance follows the finger spread exactly

var _yaw: float = 0.0
var _pitch: float = 0.0
var _distance: float = 5.0

# Touch gesture state. Two fingers = pan (their midpoint) + zoom (their spread).
var _touches := {}  # finger index -> position
var _last_centroid := Vector2.ZERO
var _last_spread: float = 0.0

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
	if event is InputEventScreenTouch:
		_on_touch(event)
		return
	if event is InputEventScreenDrag:
		_on_drag(event)
		return
	if event is InputEventMouseMotion and _touches.size() >= 2:
		return  # a two-finger gesture is running; ignore the mouse drag emulated from the first finger
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

func _on_touch(event: InputEventScreenTouch) -> void:
	if event.pressed:
		if event.index == 0:
			_touches.clear()  # the first finger starts a new gesture; drops any stale entry
		_touches[event.index] = event.position
	else:
		_touches.erase(event.index)
	_sync_gesture()

func _on_drag(event: InputEventScreenDrag) -> void:
	var known := _touches.has(event.index)
	_touches[event.index] = event.position
	if not known:
		_sync_gesture()  # a finger we lost track of: restart from here instead of jumping
		return
	if _touches.size() != 2:
		return
	var pts := _touches.values()
	var a: Vector2 = pts[0]
	var b: Vector2 = pts[1]
	var centroid := (a + b) * 0.5
	var spread := a.distance_to(b)
	if _last_spread > 1.0 and spread > 1.0:
		# Fingers apart = zoom in = camera closer.
		_distance = clampf(_distance * pow(_last_spread / spread, pinch_zoom_speed), min_distance, max_distance)
	var d := centroid - _last_centroid
	var right: Vector3 = global_transform.basis.x
	var up: Vector3 = global_transform.basis.y
	global_position += (-right * d.x + up * d.y) * pan_speed * _distance
	_last_centroid = centroid
	_last_spread = spread
	_apply()

func _sync_gesture() -> void:
	if _touches.size() == 2:
		var pts := _touches.values()
		var a: Vector2 = pts[0]
		var b: Vector2 = pts[1]
		_last_centroid = (a + b) * 0.5
		_last_spread = a.distance_to(b)

func _apply() -> void:
	rotation = Vector3(_pitch, _yaw, 0.0)
	camera.position = Vector3(0.0, 0.0, _distance)

## Snapshot of the view for SceneManager (degrees / world units).
func capture_view() -> SceneStates.CameraData:
	var v := SceneStates.CameraData.new()
	v.target = global_position
	v.yaw = rad_to_deg(_yaw)
	v.pitch = rad_to_deg(_pitch)
	v.distance = _distance
	v.fov = camera.fov
	return v

func apply_view(v: SceneStates.CameraData) -> void:
	global_position = v.target
	_yaw = deg_to_rad(v.yaw)
	_pitch = clampf(deg_to_rad(v.pitch), -PI / 2.0 + 0.01, PI / 2.0 - 0.01)
	_distance = clampf(v.distance, min_distance, max_distance)
	camera.fov = v.fov
	_apply()
