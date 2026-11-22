class_name PoseController
extends Node

## Poses the active bone (BoneMarkers.active) by dragging while holding Q / W / E.
##
##   Hold Q / W / E (any combination)  -> unlock X / Y / Z
##   Left drag                         -> rotate (default)
##   Shift + left drag                 -> move
##   Shift + Ctrl + left drag          -> scale (always local)
##   G                                 -> toggle local / global (rotate + move)
##   M                                 -> toggle bone mirroring (lShin <-> rShin, ...)
##   Ctrl+Z / Ctrl+Y                   -> undo / redo (one entry per drag)
##   Alt+R                             -> reset the selected bone (and its mirror partner while mirroring)
##
## Several axes held at once:
##   rotate = one rotation about the combined axis, move = every held axis moves by the same
##   amount, scale = every held axis scales (Q+W+E = uniform).
##
## Bone rotation is stored as a Quaternion, so there's no gimbal lock or Euler order to worry about.

signal bone_changed(index: int)  # a bone's pose changed (-1 = everything, after reset_all)
signal global_mode_changed(is_global: bool)
signal mirror_mode_changed(enabled: bool)

enum Mode { ROTATE, MOVE, SCALE }

@export var rotate_speed: float = 0.01  ## radians per pixel of drag
@export var scale_speed: float = 0.005  ## log-scale per pixel (multiplicative, never reaches 0)
@export var drag_direction := Vector2(1.0, -1.0)  ## drag right / up = increase; use (1, 0) for horizontal only
@export var min_scale: float = 0.01
@export var max_scale: float = 50.0
@export var history_limit: int = 100

var global_mode: bool = false:
	set(v):
		if v == global_mode:
			return
		global_mode = v
		global_mode_changed.emit(v)

## When on, every edit to a bone is mirrored onto its left/right partner (across the model's
## X axis), and resets apply to both. Bones without a partner behave normally.
var mirror_mode: bool = false:
	set(v):
		if v == mirror_mode:
			return
		mirror_mode = v
		_refresh_mirror_marker()
		mirror_mode_changed.emit(v)

## Number of left/right bone pairs found on the current skeleton (handy for a UI hint).
var mirror_pair_count: int = 0

## On-screen axis buttons can set these later (1 = held), exactly like holding the key.
var touch_axes := Vector3.ZERO

var skeleton: Skeleton3D
var camera: Camera3D
var markers: BoneMarkers

var _drag_bone: int = -1
var _drag_bones: Array[int] = []  # dragged bone + its partner (captured even if mirroring is off, so toggling M mid-drag stays undoable)
var _drag_before: Array = []  # one captured state per entry of _drag_bones
var _mirror_of := PackedInt32Array()  # partner bone index per bone, -1 = none
var _undo: Array[Dictionary] = []
var _redo: Array[Dictionary] = []

func setup(skel: Skeleton3D, cam: Camera3D, bone_markers: BoneMarkers) -> void:
	skeleton = skel
	camera = cam
	markers = bone_markers
	_drag_bone = -1
	_undo.clear()
	_redo.clear()
	_build_mirror_map()
	if is_instance_valid(markers) and not markers.bone_selected.is_connected(_on_bone_selected):
		markers.bone_selected.connect(_on_bone_selected)
	_refresh_mirror_marker()

## Which axes are currently unlocked, as (x, y, z) flags of 0 or 1.
func held_axes() -> Vector3:
	var a := touch_axes
	if Input.is_physical_key_pressed(KEY_Q):  # physical keys: the QWE cluster on any layout
		a.x = 1.0
	if Input.is_physical_key_pressed(KEY_W):
		a.y = 1.0
	if Input.is_physical_key_pressed(KEY_E):
		a.z = 1.0
	return a

## True while the user is posing; the camera rig should skip left-drag rotation then.
func is_manipulating() -> bool:
	if _drag_bone != -1:
		return true
	return _active_bone() >= 0 and held_axes() != Vector3.ZERO

func get_pose_readout(bone: int) -> Dictionary:
	var e := skeleton.get_bone_pose_rotation(bone).get_euler()
	return {
		"rotation": Vector3(rad_to_deg(e.x), rad_to_deg(e.y), rad_to_deg(e.z)),
		"position": skeleton.get_bone_pose_position(bone),
		"scale": skeleton.get_bone_pose_scale(bone),
	}

# ---------------- editing API (input below and future touch UI both use this) ----------------
## Call before a series of manipulate() calls; end_edit() commits ONE undo entry.
func begin_edit(bone: int) -> void:
	if not is_instance_valid(skeleton) or bone < 0 or bone >= skeleton.get_bone_count():
		return
	_drag_bone = bone
	_drag_bones = _edit_set(bone)
	_drag_before = []
	for b in _drag_bones:
		_drag_before.append(_capture(b))

func end_edit() -> void:
	if _drag_bone == -1:
		return
	# One undo entry covering every bone that actually changed (the bone and/or its partner).
	var bones: Array[int] = []
	var before: Array = []
	var after: Array = []
	for k in _drag_bones.size():
		var b := _drag_bones[k]
		var now := _capture(b)
		if now != _drag_before[k]:
			bones.append(b)
			before.append(_drag_before[k])
			after.append(now)
	if not bones.is_empty():
		_push({"bones": bones, "before": before, "after": after})
	_drag_bone = -1
	_drag_bones = []
	_drag_before = []

## `axes` = (x, y, z) flags, `delta_px` = drag amount in pixels (sign = increase / decrease).
func manipulate(bone: int, mode: Mode, axes: Vector3, delta_px: float) -> void:
	if not is_instance_valid(skeleton) or bone < 0 or bone >= skeleton.get_bone_count():
		return
	if axes == Vector3.ZERO or delta_px == 0.0:
		return
	match mode:
		Mode.ROTATE:
			_rotate(bone, axes, delta_px * rotate_speed)
		Mode.MOVE:
			_move(bone, axes, delta_px)
		Mode.SCALE:
			_scale(bone, axes, delta_px)
	if mirror_mode:
		var partner := get_mirror_bone(bone)
		if partner >= 0:
			_mirror_pose(bone, partner)
			_changed(partner)
	_changed(bone)

func reset_bone(bone: int) -> void:
	if not is_instance_valid(skeleton) or bone < 0 or bone >= skeleton.get_bone_count():
		return
	# While mirroring, the partner is reset too, as part of the same undo entry.
	var bones: Array[int] = []
	var before: Array = []
	var after: Array = []
	for b in _mirror_targets(bone):
		var was := _capture(b)
		skeleton.reset_bone_pose(b)
		var now := _capture(b)
		if now != was:
			bones.append(b)
			before.append(was)
			after.append(now)
		_changed(b)
	if not bones.is_empty():
		_push({"bones": bones, "before": before, "after": after})

func reset_all() -> void:
	if not is_instance_valid(skeleton):
		return
	skeleton.reset_bone_poses()
	_undo.clear()
	_redo.clear()
	_changed(-1)

func undo() -> void:
	if _undo.is_empty():
		return
	var e: Dictionary = _undo.pop_back()
	_restore_entry(e, "before")
	_redo.append(e)

func redo() -> void:
	if _redo.is_empty():
		return
	var e: Dictionary = _redo.pop_back()
	_restore_entry(e, "after")
	_undo.append(e)

# ---------------- input ----------------
func _unhandled_input(event: InputEvent) -> void:
	if not is_instance_valid(skeleton):
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			if is_manipulating():
				begin_edit(_active_bone())
		else:
			end_edit()
	elif event is InputEventMouseMotion and _drag_bone != -1 and (event.button_mask & MOUSE_BUTTON_MASK_LEFT):
		# Modifiers are read on every motion event, so you can switch mode mid-drag.
		var mode := Mode.ROTATE
		if event.shift_pressed:
			mode = Mode.SCALE if event.ctrl_pressed else Mode.MOVE
		manipulate(_drag_bone, mode, held_axes(), event.relative.dot(drag_direction))

func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	
	if k == null or not k.pressed or k.echo:
		return
	
	match k.keycode:
		KEY_G:
			if not k.ctrl_pressed:
				global_mode = not global_mode
		KEY_Z:
			if k.ctrl_pressed:
				undo()
		KEY_Y:
			if k.ctrl_pressed:
				redo()
		KEY_R:
			if k.alt_pressed:
				if k.shift_pressed:
					markers.select(-1)
					reset_all()
				else: reset_bone(_active_bone())
			
		KEY_M:
			if k.alt_pressed: return
			elif k.ctrl_pressed:
				_mirror_bone_pose(_active_bone())
			else:
				mirror_mode = not mirror_mode
				print("mirror mode: " + str(mirror_mode))

# ---------------- transform math ----------------
func _rotate(i: int, axes: Vector3, angle: float) -> void:
	var rot := skeleton.get_bone_pose_rotation(i)
	var axis := axes.normalized()
	var axis_in_parent: Vector3
	if global_mode:
		# World axis -> the bone's parent space (rotation only).
		var parent_world_q := (skeleton.global_basis * _parent_global_basis(i)).get_rotation_quaternion()
		axis_in_parent = parent_world_q.inverse() * axis
	else:
		# Bone-local axis expressed in parent space.
		axis_in_parent = rot * axis
	var delta := Quaternion(axis_in_parent.normalized(), angle)
	skeleton.set_bone_pose_rotation(i, (delta * rot).normalized())

func _move(i: int, axes: Vector3, delta_px: float) -> void:
	var gp := skeleton.get_bone_global_pose(i)
	var world_pos := skeleton.global_transform * gp.origin
	var dir_world := axes
	if not global_mode:
		dir_world = (skeleton.global_basis * gp.basis).get_rotation_quaternion() * axes
	var delta_world := dir_world * (delta_px * _world_per_pixel(world_pos))
	# World -> parent space, including any parent scale, so the bone follows the cursor 1:1.
	var to_parent := (skeleton.global_basis * _parent_global_basis(i)).inverse()
	skeleton.set_bone_pose_position(i, skeleton.get_bone_pose_position(i) + to_parent * delta_world)

func _scale(i: int, axes: Vector3, delta_px: float) -> void:
	var s := skeleton.get_bone_pose_scale(i)
	var f := exp(delta_px * scale_speed)
	if axes.x != 0.0:
		s.x = clampf(s.x * f, min_scale, max_scale)
	if axes.y != 0.0:
		s.y = clampf(s.y * f, min_scale, max_scale)
	if axes.z != 0.0:
		s.z = clampf(s.z * f, min_scale, max_scale)
	skeleton.set_bone_pose_scale(i, s)

func _parent_global_basis(i: int) -> Basis:
	var p := skeleton.get_bone_parent(i)
	return skeleton.get_bone_global_pose(p).basis if p >= 0 else Basis.IDENTITY

## World units covered by one screen pixel at `world_pos`, so dragging feels the same at any zoom.
func _world_per_pixel(world_pos: Vector3) -> float:
	var vp := camera.get_viewport().get_visible_rect().size
	var px := vp.y if camera.keep_aspect == Camera3D.KEEP_HEIGHT else vp.x
	if camera.projection == Camera3D.PROJECTION_ORTHOGONAL:
		return camera.size / px
	var dist := camera.global_position.distance_to(world_pos)
	return 2.0 * dist * tan(deg_to_rad(camera.fov) * 0.5) / px

# ---------------- helpers ----------------
func _active_bone() -> int:
	return markers.active if is_instance_valid(markers) else -1

func _capture(i: int) -> Array:
	return [
		skeleton.get_bone_pose_position(i),
		skeleton.get_bone_pose_rotation(i),
		skeleton.get_bone_pose_scale(i),
	]

func _restore(i: int, state: Array) -> void:
	skeleton.set_bone_pose_position(i, state[0])
	skeleton.set_bone_pose_rotation(i, state[1])
	skeleton.set_bone_pose_scale(i, state[2])
	_changed(i)

func _push(entry: Dictionary) -> void:
	_undo.append(entry)
	if _undo.size() > history_limit:
		_undo.pop_front()
	_redo.clear()

func _changed(i: int) -> void:
	if is_instance_valid(markers):
		markers.mark_dirty()
	bone_changed.emit(i)

func _restore_entry(entry: Dictionary, key: String) -> void:
	var bones: Array = entry["bones"]
	var states: Array = entry[key]
	for k in bones.size():
		_restore(bones[k], states[k])

# ---------------- mirroring ----------------

## The left/right partner of `bone`, or -1 if it has none.
func get_mirror_bone(bone: int) -> int:
	if bone < 0 or bone >= _mirror_of.size():
		return -1
	return _mirror_of[bone]

## Bones a reset should touch: the bone, plus its partner while mirroring.
func _mirror_targets(bone: int) -> Array[int]:
	var t: Array[int] = [bone]
	if mirror_mode:
		var p := get_mirror_bone(bone)
		if p >= 0:
			t.append(p)
	return t

## Bones an edit might touch: the bone and its partner, whether or not mirroring is on.
func _edit_set(bone: int) -> Array[int]:
	var t: Array[int] = [bone]
	var p := get_mirror_bone(bone)
	if p >= 0:
		t.append(p)
	return t

## Writes the mirror image of `src`'s pose onto `dst` (mirror plane = the model's YZ plane, x -> -x).
## Position is mirrored as an offset from rest, rotation as (x, -y, -z, w), scale is copied.
## Assumes rest rotations are identity, which is how the parser builds the skeleton.
func _mirror_pose(src: int, dst: int) -> void:
	var rest_src := skeleton.get_bone_rest(src)
	var rest_dst := skeleton.get_bone_rest(dst)
	var d := skeleton.get_bone_pose_position(src) - rest_src.origin
	skeleton.set_bone_pose_position(dst, rest_dst.origin + Vector3(-d.x, d.y, d.z))
	var q := skeleton.get_bone_pose_rotation(src)
	skeleton.set_bone_pose_rotation(dst, Quaternion(q.x, -q.y, -q.z, q.w))
	skeleton.set_bone_pose_scale(dst, skeleton.get_bone_pose_scale(src))
	
## One-shot: copies the mirror image of `bone`'s pose onto its partner (undoable). Works with mirroring off.
func _mirror_bone_pose(bone: int) -> void:
	var partner := get_mirror_bone(bone)
	if not is_instance_valid(skeleton) or partner < 0:
		return
	var before := _capture(partner)
	_mirror_pose(bone, partner)
	var after := _capture(partner)
	if after != before:
		_push({"bones": [partner], "before": [before], "after": [after]})
	_changed(partner)

func _on_bone_selected(_index: int) -> void:
	_refresh_mirror_marker()

func _refresh_mirror_marker() -> void:
	if not is_instance_valid(markers):
		return
	# set() so this still works if BoneMarkers doesn't have the mirror_bone property yet.
	markers.set("mirror_bone", get_mirror_bone(_active_bone()) if mirror_mode else -1)

func _build_mirror_map() -> void:
	var count := skeleton.get_bone_count()
	var index := {}
	for i in count:
		index[skeleton.get_bone_name(i)] = i
	var raw := PackedInt32Array()
	raw.resize(count)
	raw.fill(-1)
	for i in count:
		for cand in _mirror_candidates(skeleton.get_bone_name(i)):
			# A pairing only counts if the swapped name really exists on this skeleton.
			if index.has(cand) and index[cand] != i:
				raw[i] = index[cand]
				break
	# Keep only pairs that agree in both directions.
	_mirror_of = PackedInt32Array()
	_mirror_of.resize(count)
	mirror_pair_count = 0
	for i in count:
		var j := raw[i]
		_mirror_of[i] = j if (j >= 0 and raw[j] == i) else -1
		if _mirror_of[i] > i:
			mirror_pair_count += 1

const _SEPARATORS := " _.-"

## Possible partner names for `n`: Left/Right words, a lone L/R token ("Bip01 L Hand", "arm.L"),
## a camelCase prefix ("lShldrBend") or a camelCase suffix ("ThumbL").
static func _mirror_candidates(n: String) -> PackedStringArray:
	var out := PackedStringArray()
	for pair in [["Left", "Right"], ["left", "right"], ["LEFT", "RIGHT"]]:
		if n.contains(pair[0]):
			out.append(n.replace(pair[0], pair[1]))
		if n.contains(pair[1]):
			out.append(n.replace(pair[1], pair[0]))
	var last := n.length() - 1
	for i in n.length():
		var c := n[i]
		if _is_side_letter(c) and (i == 0 or _SEPARATORS.contains(n[i - 1])) and (i == last or _SEPARATORS.contains(n[i + 1])):
			out.append(n.substr(0, i) + _other_side(c) + n.substr(i + 1))
	if n.length() > 1:
		if _is_side_letter(n[0]) and _is_upper(n[1]):
			out.append(_other_side(n[0]) + n.substr(1))
		if _is_side_letter(n[last]) and (_is_lower(n[last - 1]) or n[last - 1].is_valid_int()):
			out.append(n.substr(0, last) + _other_side(n[last]))
	return out

static func _is_side_letter(c: String) -> bool:
	return c == "l" or c == "r" or c == "L" or c == "R"

static func _other_side(c: String) -> String:
	match c:
		"l":
			return "r"
		"r":
			return "l"
		"L":
			return "R"
		_:
			return "L"

static func _is_upper(c: String) -> bool:
	return c != c.to_lower()

static func _is_lower(c: String) -> bool:
	return c != c.to_upper()
