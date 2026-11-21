class_name XPSParser
extends RefCounted
## Pure-data XPS parser: no nodes, no UI, no FileAccess calls per field.
## parse() only touches its own Packed arrays, so it can run on a worker thread.
##
## Reads binary .xps files and binary .mesh files (a .mesh is an .xps without the header).
## On failure parse() returns {} and sets `last_error` to a message you can show in the UI.
##
## parse(path) returns {} on failure, otherwise:
## {
##   "version": Vector2i(major, minor),   # (0, 0) for headerless .mesh files
##   "has_header": bool,
##   "bones":   { "names": PackedStringArray, "parents": PackedInt32Array, "coords": PackedVector3Array },
##   "meshes":  [ { "name": String, "uv_layers": int,
##                  "textures": [ { "file": String, "uv": int } ],   # "file" is already a bare file name
##                  "arrays": Array } ]   # ready for ArrayMesh.add_surface_from_arrays()
## }

const MAGIC := 323232  # first uint32 of an .xps; .mesh files don't have it
const MAX_UV_LAYERS := 8

var last_error: String = ""

var _b: PackedByteArray
var _p: int = 0


func parse(path: String) -> Dictionary:
	last_error = ""
	_b = FileAccess.get_file_as_bytes(path)  # the only file I/O
	if _b.size() < 8:
		return _fail("The file is empty or couldn't be read.")

	# ---- header (.xps only; a .mesh starts directly at the bone count) ----
	var has_header := _b.decode_u32(0) == MAGIC
	var major := 0
	var minor := 0
	_p = 0
	if has_header:
		_p = 4
		major = _u16()
		minor = _u16()
		_skip_string()  # tool name
		var settings_len := _u32()
		_skip_string()  # machine
		_skip_string()  # account
		_skip_string()  # files used
		_p += settings_len * 4
		if _p > _b.size():
			return _fail("The XPS header is damaged or truncated.")

	# ---- bones ----
	var bone_count := _u32()
	if not _fits(bone_count * 15):  # a bone is at least 15 bytes
		return _fail("The bone count doesn't fit the file. It may not be a valid XPS or .mesh file.")
	var names := PackedStringArray()
	var parents := PackedInt32Array()
	var coords := PackedVector3Array()
	names.resize(bone_count)
	parents.resize(bone_count)
	coords.resize(bone_count)
	for i in bone_count:
		names[i] = _read_string()
		if not _fits(14):
			return _fail("The bone data is truncated.")
		parents[i] = _b.decode_s16(_p)  # signed: -1 = root (get_16() would give 65535)
		coords[i] = Vector3(_b.decode_float(_p + 2), _b.decode_float(_p + 6), _b.decode_float(_p + 10))
		_p += 14

	# ---- meshes ----
	var mesh_count := _u32()
	if not _fits(mesh_count * 17):  # a mesh record is at least 17 bytes
		return _fail("The mesh count doesn't fit the file.")
	# Headerless files leave major/minor at 0, which gives the .mesh defaults
	# (tangents present, fixed 4 weights) with no special case.
	var has_tangent := (major <= 2 and minor <= 12)
	var var_weights := major >= 3
	var has_bones := bone_count > 0
	var meshes: Array[Dictionary] = []

	for m in mesh_count:
		var mesh_name := _read_string()
		if mesh_name.is_empty():
			mesh_name = "mesh_%d" % m
		var uv_layers := _u32()
		var tex_count := _u32()
		if uv_layers > MAX_UV_LAYERS or not _fits(tex_count * 5):
			return _fail("Mesh %d has invalid data." % m)
		var textures: Array[Dictionary] = []
		for t in tex_count:
			# Some files store full Windows paths; keep only the file name.
			var file := _read_string().replace("\\", "/").get_file()
			textures.append({"file": file, "uv": _u32()})

		var vcount := _u32()
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		if not _read_vertices(arrays, vcount, uv_layers, has_tangent, has_bones, var_weights):
			return _fail("Mesh %d (%s) has damaged vertex data." % [m, mesh_name])

		# Triangle indices are one contiguous block of u32s: no loop needed.
		var tri_count := _u32()
		var idx_bytes := tri_count * 12
		if not _fits(idx_bytes):
			return _fail("Mesh %d (%s) has damaged triangle data." % [m, mesh_name])
		arrays[Mesh.ARRAY_INDEX] = _b.slice(_p, _p + idx_bytes).to_int32_array()
		_p += idx_bytes

		meshes.append({
			"name": mesh_name,
			"uv_layers": uv_layers,
			"textures": textures,
			"arrays": arrays,
		})

	_b = PackedByteArray()  # release the file buffer
	return {
		"version": Vector2i(major, minor),
		"has_header": has_header,
		"bones": {"names": names, "parents": parents, "coords": coords},
		"meshes": meshes,
	}


func _fail(message: String) -> Dictionary:
	last_error = message
	push_error("XPS: %s" % message)
	_b = PackedByteArray()
	return {}


## True if `n` more bytes can be read from the current position.
func _fits(n: int) -> bool:
	return n >= 0 and _p + n <= _b.size()


func _read_vertices(arrays: Array, vcount: int, uv_layers: int, has_tangent: bool, has_bones: bool, var_weights: bool) -> bool:
	# Smallest possible vertex record: a garbage vertex count can't make us allocate gigabytes.
	var min_vertex_bytes := 28 + uv_layers * 8 + (2 if (has_bones and var_weights) else 0)
	if not _fits(vcount * min_vertex_bytes):
		return false

	# Pre-sized outputs, written by index (no append, no temp Arrays).
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uv1 := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var tangs := PackedFloat32Array()
	var ids := PackedInt32Array()
	var wts := PackedFloat32Array()
	verts.resize(vcount)
	norms.resize(vcount)
	uv1.resize(vcount)
	if uv_layers >= 2:
		uv2.resize(vcount)
	if has_tangent and uv_layers >= 1:
		tangs.resize(vcount * 4)
	if has_bones:
		ids.resize(vcount * 4)
		wts.resize(vcount * 4)

	if has_bones and var_weights:
		# v3+: weight count varies per vertex, so the stride isn't fixed.
		var p := _p
		for v in vcount:
			if p + min_vertex_bytes > _b.size():
				return false
			verts[v] = Vector3(_b.decode_float(p), _b.decode_float(p + 4), _b.decode_float(p + 8))
			norms[v] = Vector3(_b.decode_float(p + 12), _b.decode_float(p + 16), _b.decode_float(p + 20))
			p += 28  # position + normal + colour (colour skipped)
			for l in uv_layers:
				if l == 0:
					uv1[v] = Vector2(_b.decode_float(p), _b.decode_float(p + 4))
				elif l == 1:
					uv2[v] = Vector2(_b.decode_float(p), _b.decode_float(p + 4))
				p += 8
			var cnt := _b.decode_u16(p)
			p += 2
			var wp := p + cnt * 2
			if wp + cnt * 4 > _b.size():
				return false
			var q := v * 4
			for i in mini(cnt, 4):  # TODO: >4 weights are truncated; sort by weight + renormalise if needed
				ids[q + i] = _b.decode_u16(p + i * 2)
				wts[q + i] = _b.decode_float(wp + i * 4)
			p = wp + cnt * 4
		_p = p
	else:
		# Fixed stride: grab the whole block once, view it as floats AND ints
		# (the u16 bone ids are packed two per int32), then index into it.
		var uv_words := 2 + (4 if has_tangent else 0)  # per UV layer, in 4-byte words
		var stride := 7 + uv_layers * uv_words + (6 if has_bones else 0)
		var byte_len := vcount * stride * 4
		if not _fits(byte_len):
			return false
		var block := _b.slice(_p, _p + byte_len)
		_p += byte_len
		var f := block.to_float32_array()
		var n := block.to_int32_array()
		var bone_off := 7 + uv_layers * uv_words

		for v in vcount:
			var o := v * stride
			verts[v] = Vector3(f[o], f[o + 1], f[o + 2])
			norms[v] = Vector3(f[o + 3], f[o + 4], f[o + 5])
			# f[o + 6] is the vertex colour: skipped on purpose
			if uv_layers >= 1:
				uv1[v] = Vector2(f[o + 7], f[o + 8])
				if has_tangent:
					var t := v * 4
					tangs[t] = f[o + 9]
					tangs[t + 1] = f[o + 10]
					tangs[t + 2] = f[o + 11]
					tangs[t + 3] = f[o + 12]
				if uv_layers >= 2:
					var u := o + 7 + uv_words
					uv2[v] = Vector2(f[u], f[u + 1])
			if has_bones:
				var bo := o + bone_off
				var q := v * 4
				var a := n[bo]
				var c := n[bo + 1]
				ids[q] = a & 0xFFFF
				ids[q + 1] = (a >> 16) & 0xFFFF
				ids[q + 2] = c & 0xFFFF
				ids[q + 3] = (c >> 16) & 0xFFFF
				wts[q] = f[bo + 2]
				wts[q + 1] = f[bo + 3]
				wts[q + 2] = f[bo + 4]
				wts[q + 3] = f[bo + 5]

	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uv1
	if uv_layers >= 2:
		arrays[Mesh.ARRAY_TEX_UV2] = uv2
	if not tangs.is_empty():
		arrays[Mesh.ARRAY_TANGENT] = tangs
	if has_bones:
		arrays[Mesh.ARRAY_BONES] = ids
		arrays[Mesh.ARRAY_WEIGHTS] = wts
	return true


# ---------- tiny readers (all work on the single in-memory buffer) ----------

func _u16() -> int:
	if _p + 2 > _b.size():
		_p = _b.size() + 1  # "ran off the end": the callers' _fits()/size checks then fail
		return 0
	var v := _b.decode_u16(_p)
	_p += 2
	return v


func _u32() -> int:
	if _p + 4 > _b.size():
		_p = _b.size() + 1
		return 0
	var v := _b.decode_u32(_p)
	_p += 4
	return v


func _str_len() -> int:
	if _p >= _b.size():
		_p = _b.size() + 1
		return 0
	var n := _b[_p]
	_p += 1
	if n >= 128:  # 7-bit encoded length, same as the old read_next_string
		if _p >= _b.size():
			_p = _b.size() + 1
			return 0
		n = (n & 0x7F) | (_b[_p] << 7)
		_p += 1
	return n


func _skip_string() -> void:
	_p += _str_len()


func _read_string() -> String:
	var n := _str_len()
	if _p + n > _b.size():
		_p = _b.size() + 1
		return ""
	var s := _b.slice(_p, _p + n).get_string_from_utf8()
	_p += n
	return s


# ---------- main-thread helpers ----------

## Two loops instead of three; no per-bone pose calls.
static func build_skeleton(bones: Dictionary) -> Skeleton3D:
	var sk := Skeleton3D.new()
	sk.name = "Armature"
	var names: PackedStringArray = bones["names"]
	var parents: PackedInt32Array = bones["parents"]
	var coords: PackedVector3Array = bones["coords"]
	var count := names.size()

	for n in names:
		sk.add_bone(n)  # every bone must exist before parents are assigned

	for i in count:
		var local := coords[i]
		var par := parents[i]
		if par >= 0 and par < count:
			sk.set_bone_parent(i, par)
			local -= coords[par]
		sk.set_bone_rest(i, Transform3D(Basis.IDENTITY, local))
	sk.reset_bone_poses()
	return sk


## Cached, aspect-correct downscale. `cache` maps full path -> Texture2D (or null).
static func load_texture(path: String, cache: Dictionary, max_dim: int = 1024) -> Texture2D:
	if cache.has(path):
		return cache[path]
	
	var tex: Texture2D = null
	
	if FileAccess.file_exists(path):
		var img := Image.load_from_file(path)
		if img:
			if img.is_compressed():
				img.decompress()  # compressed images can't be resized
			
			var w := img.get_width()
			var h := img.get_height()
			
			var longest := maxi(w, h)
			
			if longest > max_dim:
				var s := float(max_dim) / float(longest)
				img.resize(maxi(1, int(w * s)), maxi(1, int(h * s)), Image.INTERPOLATE_BILINEAR)
				
			img.generate_mipmaps()
			
			var has_alpha := img.detect_alpha() != Image.ALPHA_NONE
			tex = ImageTexture.create_from_image(img)
			tex.set_meta("has_alpha", has_alpha)
	
	cache[path] = tex
	return tex
