class_name SceneManager
extends Node

## Owns the scene's two lights and the camera view.
##
##  - Lights: this manager is the source of truth. Change them through set_light_*() so the
##    stored state and the light node never disagree.
##  - Camera: the orbit rig is the source of truth while the user drags it. The manager only
##    takes a snapshot (capture) or pushes one back (apply_camera).
##  - reset_*() returns to the scene exactly as authored in the editor.
##
## Setup: add this node to the scene, assign `camera_rig` and the two lights in the Inspector.
## Later the (single) model and its pose manager will hang off this node.

signal light_changed(index: int)
signal camera_applied()
signal scene_reset()

@export var camera_rig: CameraRig
@export var lights: Array[DirectionalLight3D]

var _lights: Array[SceneStates.LightData] = []  # source of truth for the lights
var _default: SceneStates  # the scene as authored; filled one frame after _ready()

func _ready() -> void:
	if camera_rig == null:
		push_error("SceneManager: camera_rig isn't assigned.")
	if lights.size() != SceneStates.LIGHT_COUNT:
		push_error("SceneManager: expected %d lights, got %d." % [SceneStates.LIGHT_COUNT, lights.size()])
	for node in lights:
		_lights.append(_read_light(node))
	# The rig sets itself up in its own _ready(), so snapshot it one frame later.
	_capture_default.call_deferred()

# ---------------- whole scene ----------------
## Snapshot of everything: the live camera view plus the current light states.
func capture() -> SceneStates:
	var s := SceneStates.new()
	if is_instance_valid(camera_rig):
		s.camera = camera_rig.capture_view().sanitize()
	for i in mini(_lights.size(), SceneStates.LIGHT_COUNT):
		s.lights[i] = _lights[i].copy()
	return s

func apply(s: SceneStates) -> void:
	apply_camera(s.camera)
	for i in mini(_lights.size(), SceneStates.LIGHT_COUNT):
		_lights[i] = s.lights[i].copy().sanitize()
		_apply_light(i)
		light_changed.emit(i)

func reset_all() -> void:
	reset_camera()
	reset_lights()
	scene_reset.emit()

# ---------------- camera ----------------
func capture_camera() -> SceneStates.CameraData:
	return camera_rig.capture_view().sanitize()

func apply_camera(view: SceneStates.CameraData) -> void:
	if not is_instance_valid(camera_rig):
		return
	camera_rig.apply_view(view.copy().sanitize())
	camera_applied.emit()

func reset_camera() -> void:
	if _default:
		apply_camera(_default.camera)

# ---------------- lights ----------------
## A copy: editing it does nothing until you pass the values to set_light_*().
func get_light(index: int) -> SceneStates.LightData:
	return _lights[index].copy() if _valid_light(index) else null

func set_light_active(index : int, value : bool ) -> void:
	if _valid_light(index):
		_lights[index].on = value
		_commit_light(index)

func set_light_intensity(index: int, value: float) -> void:
	if _valid_light(index):
		_lights[index].intensity = value
		_commit_light(index)

## Pitch in degrees, -90..90 (negative = pointing down).
func set_light_rotation_x(index: int, degrees: float) -> void:
	if _valid_light(index):
		_lights[index].rot_x = degrees
		_commit_light(index)

## Yaw in degrees, wraps at +-180.
func set_light_rotation_y(index: int, degrees: float) -> void:
	if _valid_light(index):
		_lights[index].rot_y = degrees
		_commit_light(index)

## Stored (and saved later) but not applied yet: the scene runs without shadows.
func set_light_shadow(index: int, value: float) -> void:
	if _valid_light(index):
		_lights[index].shadow = value
		_commit_light(index)

func reset_lights() -> void:
	if _default == null:
		return
	for i in mini(_lights.size(), SceneStates.LIGHT_COUNT):
		_lights[i] = _default.lights[i].copy()
		_apply_light(i)
		light_changed.emit(i)

## The light as authored in the scene (what "reset" returns to). A copy; null before it's ready.
func get_default_light(index: int) -> SceneStates.LightData:
	if _default == null or index < 0 or index >= _default.lights.size():
		return null
	return _default.lights[index].copy()


## Puts one value of a light back to its authored value: "intensity", "rot_x", "rot_y" or "shadow".
func reset_light_property(index: int, property: String) -> void:
	if _default == null or not _valid_light(index) or index >= _default.lights.size():
		return
	if not (property in ["intensity", "rot_x", "rot_y", "shadow"]):
		return
	_lights[index].set(property, _default.lights[index].get(property))
	_commit_light(index)


# ---------------- internals ----------------
func _capture_default() -> void:
	_default = capture()

func _valid_light(index: int) -> bool:
	return index >= 0 and index < _lights.size() and index < lights.size() and is_instance_valid(lights[index])

func _commit_light(index: int) -> void:
	_lights[index].sanitize()
	_apply_light(index)
	light_changed.emit(index)

func _apply_light(index: int) -> void:
	if not _valid_light(index):
		return
	var node := lights[index]
	var d := _lights[index]
	node.global_rotation = Vector3(deg_to_rad(d.rot_x), deg_to_rad(d.rot_y), 0.0)
	node.light_energy = d.intensity
	# A light at zero intensity does nothing, so take it out of the lighting loop entirely.
	node.visible = ( d.intensity > 0.0 and d.on )
	# d.shadow is intentionally not applied yet.

## Works out the X / Y rotation from the light's direction, so a light authored with any
## orientation (including a roll) maps to the same direction in this two-angle model.
func _read_light(node: DirectionalLight3D) -> SceneStates.LightData:
	var l := SceneStates.LightData.new()
	if not is_instance_valid(node):
		return l
	var dir := -node.global_basis.z
	l.on = node.visible
	l.intensity = node.light_energy
	l.rot_x = rad_to_deg(asin(clampf(dir.y, -1.0, 1.0)))
	l.rot_y = rad_to_deg(atan2(-dir.x, -dir.z))
	return l.sanitize()
