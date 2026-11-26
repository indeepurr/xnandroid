class_name PoseController
extends Node

## Poses the active bone (BoneMarkers.active) by dragging while an axis is held.
## Posing is STEPPED: every drag_px_per_step pixels of drag apply one step (rotate_step_deg /
## move_step / scale_step). With no axis held, dragging orbits the camera as usual.
##
##   Hold Q / W / E (any combination)  -> unlock X / Y / Z (phone: hold the X / Y / Z buttons)
##   Left drag                         -> touch_mode (rotate by default; the phone's mode button changes it)
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
signal history_changed  # the undo / redo stacks changed
signal mode_changed(mode: int)  # the mode being posed changed (touch_mode, or a Shift / Ctrl override mid-drag)

enum Mode { ROTATE, MOVE, SCALE }

@export_group("Steps")
@export var rotate_step_deg: float = 5.0  ## degrees per step
@export var move_step: float = 0.01  ## world units per step
@export var scale_step: float = 0.05  ## added to the scale per step (1.0 -> 1.05 -> 1.10 ...)
@export var drag_px_per_step: float = 12.0  ## pixels of drag needed for one step (all three modes)
@export_group("")
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
		if v:
			_mirror_bone_pose(_active_bone())  # turning it on also mirrors the selected bone right away
		mirror_mode_changed.emit(v)

## Number of left/right bone pairs found on the current skeleton (handy for a UI hint).
var mirror_pair_count: int = 0

## The on-screen X / Y / Z buttons set this while held (1 = held), exactly like holding the key.
var touch_axes := Vector3.ZERO

## Drag mode when no modifier key is held. The on-screen mode button sets this; Shift / Shift+Ctrl still override it.
var touch_mode: Mode = Mode.ROTATE:
	set(v):
		touch_mode = v
		_set_current_mode(v)

## The mode actually being posed right now (differs from touch_mode only while a modifier overrides it).
var current_mode: Mode = Mode.ROTATE

## A touch has to move this many pixels before it starts posing, so tapping another bone to select it
## doesn't nudge the current one. Mouse drags aren't affected.
@export var touch_drag_slop: float = 12.0

var skeleton: Skeleton3D
var camera: Camera3D
var markers: BoneMarkers

var _drag_bone: int = -1
var _drag_bones: Array[int] = []  # dragged bone + its partner (captured even if mirroring is off, so toggling M mid-drag stays undoable)
var _drag_before: Array = []  # one captured state per entry of _drag_bones
var _press_pos := Vector2.ZERO
var _drag_live: bool = true  # false while a touch is still inside touch_drag_slop
var _finger: int = -1  # a non-emulated finger (index > 0) that owns the current drag; -1 = mouse / first finger
var _step_accum: float = 0.0  # drag pixels collected towards the next step
var _step_mode: Mode = Mode.ROTATE
var _mirror_of := PackedInt32Array()  # partner bone index per bone, -1 = none
var _undo: Array[Dictionary] = []
var _redo: Array[Dictionary] = []

func setup(skel: Skeleton3D, cam: Camera3D, bone_markers: BoneMarkers) -> void:
	skeleton = skel
	camera = cam
	markers = bone_markers
	_drag_bone = -1
	_finger = -1
	_undo.clear()
	_redo.clear()
	history_changed.emit()
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

func can_undo() -> bool:
	return not _undo.is_empty()

func can_redo() -> bool:
	return not _redo.is_empty()

## How far `bone` is from its rest pose in `mode`, as (x, y, z):
## rotate = degrees, move = offset in the parent's space, scale = multiplier (1 = rest).
## Without a valid bone it returns the rest values, so a label can always show something.
func get_transform_readout(bone: int, mode: Mode) -> Vector3:
	var rest_value := Vector3.ONE if mode == Mode.SCALE else Vector3.ZERO
	if not is_instance_valid(skeleton) or bone < 0 or bone >= skeleton.get_bone_count():
		return rest_value
	var rest := skeleton.get_bone_rest(bone)
	match mode:
		Mode.ROTATE:
			var q := rest.basis.get_rotation_quaternion().inverse() * skeleton.get_bone_pose_rotation(bone)
			var e := q.get_euler()
			return Vector3(rad_to_deg(e.x), rad_to_deg(e.y), rad_to_deg(e.z))
		Mode.MOVE:
			return skeleton.get_bone_pose_position(bone) - rest.origin
		_:
			return skeleton.get_bone_pose_scale(bone)

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
	_step_accum = 0.0
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
	_finger = -1
	_step_accum = 0.0
	_set_current_mode(touch_mode)  # a Shift / Ctrl override ends with the drag

## `axes` = (x, y, z) flags, `delta_px` = drag amount in pixels (sign = increase / decrease).
## Pixels are collected until they add up to whole steps, so posing snaps to the step values.
func manipulate(bone: int, mode: Mode, axes: Vector3, delta_px: float) -> void:
	if axes == Vector3.ZERO:
		return
	if mode != _step_mode:  # switched mode mid-drag: don't carry leftover pixels over
		_step_mode = mode
		_step_accum = 0.0
	_step_accum += delta_px
	var per_step := maxf(drag_px_per_step, 0.001)
	var steps := int(_step_accum / per_step)  # truncates towards zero
	if steps == 0:
		return
	_step_accum -= steps * per_step
	apply_steps(bone, mode, axes, steps)

## Applies `steps` whole steps (negative = the other way). Also usable directly, e.g. from tap buttons.
func apply_steps(bone: int, mode: Mode, axes: Vector3, steps: int) -> void:
	if not is_instance_valid(skeleton) or bone < 0 or bone >= skeleton.get_bone_count():
		return
	if axes == Vector3.ZERO or steps == 0:
		return
	_set_current_mode(mode)
	match mode:
		Mode.ROTATE:
			_rotate(bone, axes, deg_to_rad(rotate_step_deg) * steps)
		Mode.MOVE:
			_move(bone, axes, move_step * steps)
		Mode.SCALE:
			_scale(bone, axes, scale_step * steps)
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
	history_changed.emit()
	_changed(-1)

func undo() -> void:
	if _undo.is_empty():
		return
	var e: Dictionary = _undo.pop_back()
	_restore_entry(e, "before")
	_redo.append(e)
	history_changed.emit()

func redo() -> void:
	if _redo.is_empty():
		return
	var e: Dictionary = _redo.pop_back()
	_restore_entry(e, "after")
	_undo.append(e)
	history_changed.emit()

# ---------------- input ----------------
func _unhandled_input(event: InputEvent) -> void:
	if not is_instance_valid(skeleton):
		return
	if event is InputEventScreenTouch:
		_on_screen_touch(event)
	elif event is InputEventScreenDrag:
		# Only fingers after the first land here as drags: Godot turns the first finger into mouse events.
		if event.index == _finger and _drag_bone != -1:
			_drag(event.relative, false, false)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_press_pos = event.position
			_drag_live = event.device != InputEvent.DEVICE_ID_EMULATION  # emulated from touch -> needs the slop first
			if _drag_bone == -1 and _can_pose():
				begin_edit(_active_bone())
		else:
			end_edit()
	elif event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT):
		if _drag_bone == -1:
			# An axis was held after the press (e.g. the other thumb pressed an axis button): pose from here.
			if _can_pose():
				begin_edit(_active_bone())
				_press_pos = event.position
				_drag_live = event.device != InputEvent.DEVICE_ID_EMULATION
			return
		if _finger != -1:
			return  # another finger owns this drag
		if not _drag_live:
			if event.position.distance_to(_press_pos) < touch_drag_slop:
				return
			_drag_live = true
			return  # posing starts from the next motion event
		_drag(event.relative, event.shift_pressed, event.ctrl_pressed)

func _on_screen_touch(event: InputEventScreenTouch) -> void:
	if event.pressed:
		if event.index == 0:
			return  # the first finger arrives as emulated mouse events (handled in _unhandled_input)
		if _drag_bone != -1:
			# A finger joined while posing: that's a pinch / two-finger pan. Stop posing (kept as one undo step).
			end_edit()
		elif _can_pose():
			# One finger holds an axis button and this one drags. Godot only emulates the mouse for the
			# first finger, so this finger's drag is read from InputEventScreenDrag.
			_finger = event.index
			_drag_live = true
			begin_edit(_active_bone())
	elif event.index == _finger:
		end_edit()

## True when a bone is selected and an axis is held, i.e. a drag would pose it.
func _can_pose() -> bool:
	return _active_bone() >= 0 and held_axes() != Vector3.ZERO

func _drag(relative: Vector2, shift: bool, ctrl: bool) -> void:
	# Modifiers are read on every motion event, so you can switch mode mid-drag.
	var mode: Mode = touch_mode
	if shift:
		mode = Mode.SCALE if ctrl else Mode.MOVE
	manipulate(_drag_bone, mode, held_axes(), relative.dot(drag_direction))

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

func _move(i: int, axes: Vector3, distance: float) -> void:
	var gp := skeleton.get_bone_global_pose(i)
	var dir_world := axes
	if not global_mode:
		dir_world = (skeleton.global_basis * gp.basis).get_rotation_quaternion() * axes
	var delta_world := dir_world * distance
	# World -> parent space, including any parent scale, so the bone moves exactly `distance` in the world.
	var to_parent := (skeleton.global_basis * _parent_global_basis(i)).inverse()
	skeleton.set_bone_pose_position(i, skeleton.get_bone_pose_position(i) + to_parent * delta_world)

func _scale(i: int, axes: Vector3, amount: float) -> void:
	var s := skeleton.get_bone_pose_scale(i)
	# Additive steps (snapped to hide float noise), so going up and back down lands exactly on 1.0.
	if axes.x != 0.0:
		s.x = snappedf(clampf(s.x + amount, min_scale, max_scale), 0.0001)
	if axes.y != 0.0:
		s.y = snappedf(clampf(s.y + amount, min_scale, max_scale), 0.0001)
	if axes.z != 0.0:
		s.z = snappedf(clampf(s.z + amount, min_scale, max_scale), 0.0001)
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
	history_changed.emit()

func _set_current_mode(m: Mode) -> void:
	if m == current_mode:
		return
	current_mode = m
	mode_changed.emit(m)

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
