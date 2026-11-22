class_name BoneMarkers

extends Control

signal bone_selected(index: int)  # -1 = nothing selected

@export var normal_color := Color(1, 1, 1, 0.55)
@export var selected_color := Color(1.0, 0.75, 0.1, 1.0)
@export var draw_radius: float = 6.0
@export var pick_radius: float = 36.0  ## px; generous so fingers can hit small bones
@export var tap_slop: float = 12.0  ## max finger/mouse movement for a press+release to count as a tap
@export var tap_max_ms: int = 350
@export var deselect_on_empty_tap: bool = true

var markers_visible: bool = true:
	set(v):
		markers_visible = v
		_dirty = true
		queue_redraw()

var input_enabled: bool = true  ## set false while popups are open
var active: int = -1
var skeleton: Skeleton3D
var camera: Camera3D

var _screen := PackedVector2Array()  # projected position per bone
var _on := PackedByteArray()  # 1 = on screen side of the camera, 0 = behind it
var _dirty: bool = true
var _last_cam := Transform3D()
var _last_skel := Transform3D()
var _last_fov: float = 0.0
var _last_vp := Vector2.ZERO
var _press_pos := Vector2.ZERO
var _press_ms: int = 0


func setup(skel: Skeleton3D, cam: Camera3D) -> void:
	skeleton = skel
	camera = cam
	active = -1
	mark_dirty()

## Call after the pose changes (e.g. at the end of PoseManager.apply_pose()).
func mark_dirty() -> void:
	_dirty = true

func select(index: int) -> void:
	if index == active:
		return
	
	active = index
	queue_redraw()
	bone_selected.emit(index)
	
## Nearest on-screen bone within pick_radius of `pos`, or -1.
func pick(pos: Vector2) -> int:
	var best := -1
	var best_d := pick_radius * pick_radius
	for i in _screen.size():
		if _on[i] == 0:
			continue
		var d := _screen[i].distance_squared_to(pos)
		if d < best_d:
			best_d = d
			best = i
	return best

func _process(_delta: float) -> void:
	if not markers_visible or not is_instance_valid(skeleton) or not is_instance_valid(camera):
		return
	# Only re-project when something that affects screen positions changed.
	var cam_xf := camera.global_transform
	var skel_xf := skeleton.global_transform
	var vp := get_viewport_rect().size
	if _dirty or cam_xf != _last_cam or skel_xf != _last_skel or camera.fov != _last_fov or vp != _last_vp:
		_last_cam = cam_xf
		_last_skel = skel_xf
		_last_fov = camera.fov
		_last_vp = vp
		_dirty = false
		_refresh()
		queue_redraw()

func _refresh() -> void:
	var n := skeleton.get_bone_count()
	if _screen.size() != n:
		_screen.resize(n)
		_on.resize(n)
	var to_world := skeleton.global_transform
	for i in n:
		var world := to_world * skeleton.get_bone_global_pose(i).origin
		if camera.is_position_behind(world):
			_on[i] = 0
		else:
			_on[i] = 1
			_screen[i] = camera.unproject_position(world)

func _draw() -> void:
	if not markers_visible:
		return
	
	for i in _screen.size():
		if _on[i] == 1 and i != active:
			draw_circle(_screen[i], draw_radius, normal_color)
	
	# Selected marker last so it sits on top.
	if active >= 0 and active < _screen.size() and _on[active] == 1:
		draw_circle(_screen[active], draw_radius * 1.5, selected_color)
		draw_arc(_screen[active], draw_radius * 1.5, 0.0, TAU, 24, Color.WHITE, 2.0)

func _unhandled_input(event: InputEvent) -> void:
	if Input.is_physical_key_pressed(KEY_Q) or Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_E):
		return
	
	if not markers_visible or not input_enabled or not is_instance_valid(skeleton):
		return
	
	# A tap selects; a drag is left alone for the camera rig (we never mark the event handled).
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_press_pos = event.position
			_press_ms = Time.get_ticks_msec()
		else:
			var moved : float = event.position.distance_to(_press_pos)
			var elapsed := Time.get_ticks_msec() - _press_ms
			if moved <= tap_slop and elapsed <= tap_max_ms:
				var hit := pick(event.position)
				if hit != -1 or deselect_on_empty_tap:
					select(hit)

func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	
	if k == null or not k.pressed or k.echo:
		return
	
	match k.keycode:
		KEY_H:
			if k.alt_pressed:
				markers_visible = not markers_visible
				select(-1)
