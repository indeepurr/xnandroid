class_name SceneStates

extends RefCounted

## Plain-data snapshot of a scene: one camera view and two lights.
## No nodes or engine objects, so it can be copied freely and later written to / read from a file.
## Angles are in degrees.
##
## Later this is where the model and its saved poses will be added.

const FORMAT_VERSION := 1
const LIGHT_COUNT := 2

class CameraData:
	## The camera orbits `target` at `distance`, looking along the yaw / pitch direction.
	var target := Vector3.ZERO
	var yaw: float = 0.0
	var pitch: float = 0.0
	var distance: float = 5.0
	var fov: float = 75.0

	func sanitize() -> CameraData:
		target = Vector3(
			SceneStates.finite_or(target.x, 0.0),
			SceneStates.finite_or(target.y, 0.0),
			SceneStates.finite_or(target.z, 0.0))
		yaw = wrapf(SceneStates.finite_or(yaw, 0.0), -180.0, 180.0)
		pitch = clampf(SceneStates.finite_or(pitch, 0.0), -89.0, 89.0)
		distance = clampf(SceneStates.finite_or(distance, 5.0), 0.01, 1000.0)
		fov = clampf(SceneStates.finite_or(fov, 75.0), 5.0, 120.0)
		return self

	func copy() -> CameraData:
		return CameraData.from_dict(to_dict())

	func to_dict() -> Dictionary:
		return {
			"target": [target.x, target.y, target.z],
			"yaw": yaw,
			"pitch": pitch,
			"distance": distance,
			"fov": fov,
		}

	static func from_dict(d: Dictionary) -> CameraData:
		var c := CameraData.new()
		var t = d.get("target", [])
		if t is Array and t.size() == 3:
			c.target = Vector3(
				SceneStates.as_float(t[0], 0.0),
				SceneStates.as_float(t[1], 0.0),
				SceneStates.as_float(t[2], 0.0))
		c.yaw = SceneStates.as_float(d.get("yaw"), c.yaw)
		c.pitch = SceneStates.as_float(d.get("pitch"), c.pitch)
		c.distance = SceneStates.as_float(d.get("distance"), c.distance)
		c.fov = SceneStates.as_float(d.get("fov"), c.fov)
		return c.sanitize()

class LightData:
	const MAX_INTENSITY := 2.0

	var on : bool = true
	var intensity: float = 0.25
	## Pitch, -90..90. Negative points the light downward, positive points it upward.
	var rot_x: float = 0.0
	## Yaw, wrapped to -180..180. 0 shines toward -Z (onto a model facing +Z), 180 toward +Z.
	var rot_y: float = 0.0
	## Reserved for shadows (0..1). Stored and saved, but not applied to the light yet.
	var shadow: float = 0.0

	func sanitize() -> LightData:
		intensity = clampf(SceneStates.finite_or(intensity, 0.25), 0.0, MAX_INTENSITY)
		rot_x = clampf(SceneStates.finite_or(rot_x, 0.0), -90.0, 90.0)
		rot_y = SceneStates.finite_or(rot_y, 0.0)
		if absf(rot_y) > 180.0:  # only wrap when out of range, so +180 stays +180 (wrapf would turn it into -180)
			rot_y = wrapf(rot_y, -180.0, 180.0)
		shadow = clampf(SceneStates.finite_or(shadow, 0.0), 0.0, 1.0)
		return self

	func copy() -> LightData:
		return LightData.from_dict(to_dict())

	func to_dict() -> Dictionary:
		return {"on" : on, "intensity": intensity, "rot_x": rot_x, "rot_y": rot_y, "shadow": shadow}

	static func from_dict(d: Dictionary) -> LightData:
		var l := LightData.new()
		l.on = d.get("on")
		l.intensity = SceneStates.as_float(d.get("intensity"), l.intensity)
		l.rot_x = SceneStates.as_float(d.get("rot_x"), l.rot_x)
		l.rot_y = SceneStates.as_float(d.get("rot_y"), l.rot_y)
		l.shadow = SceneStates.as_float(d.get("shadow"), l.shadow)
		return l.sanitize()

var camera := CameraData.new()
var lights: Array[LightData] = []

func _init() -> void:
	for i in LIGHT_COUNT:
		lights.append(LightData.new())

func duplicate_state() -> SceneStates:
	return SceneStates.from_dict(to_dict())

func to_dict() -> Dictionary:
	var light_list: Array = []
	for l in lights:
		light_list.append(l.to_dict())
	return {"version": FORMAT_VERSION, "camera": camera.to_dict(), "lights": light_list}

## Tolerant on purpose: anything missing or malformed falls back to a default value.
static func from_dict(d: Dictionary) -> SceneStates:
	var s := SceneStates.new()
	var cam = d.get("camera")
	if cam is Dictionary:
		s.camera = CameraData.from_dict(cam)
	var light_list = d.get("lights")
	if light_list is Array:
		for i in mini(light_list.size(), LIGHT_COUNT):
			if light_list[i] is Dictionary:
				s.lights[i] = LightData.from_dict(light_list[i])
	return s

# ---------------- small helpers shared by the data classes ----------------
static func finite_or(v: float, fallback: float) -> float:
	return v if is_finite(v) else fallback

## Reads a number from untrusted data (JSON, a file): anything that isn't a number gives `fallback`.
static func as_float(v: Variant, fallback: float) -> float:
	return float(v) if (v is float or v is int) else fallback
