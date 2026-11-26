extends Node3D

# UI related

# Buttons
@onready var BTN_loadModel : Button = $UI/HBox/Header/HeaderOptions/BTN_loadModel
@onready var BTN_sceneLights : Button = $UI/HBox/Footer/FooterOptions/BTN_sceneLights
@onready var BTN_extrasModel : Button = $UI/HBox/Footer/FooterOptions/BTN_extrasModel
@onready var BTN_lightOn : CheckBox = $UI/HBox/Center/VBoxContainer/LightsPopup/PanelContainer2/VBoxContainer3/VBoxContainer2/CenterContainer/BTN_LightOn
@onready var BTN_boneMode : Button = $UI/HBox/Center/CenterContainer/VBoxContainer/BTN_BoneMode
@onready var BTN_boneAxisX : Button = $UI/HBox/Center/CenterContainer/VBoxContainer/HBoxContainer/BTN_BoneAxis_X
@onready var BTN_boneAxisY : Button = $UI/HBox/Center/CenterContainer/VBoxContainer/HBoxContainer/BTN_BoneAxis_Y
@onready var BTN_boneAxisZ : Button = $UI/HBox/Center/CenterContainer/VBoxContainer/HBoxContainer/BTN_BoneAxis_Z
@onready var BTN_boneMirror : Button = $UI/HBox/Center/CenterContainer/VBoxContainer/BTN_BoneMirror
@onready var BTN_boneUndo : Button = $UI/HBox/Center/CenterContainer/VBoxContainer/BTN_BoneUndo
@onready var BTN_boneRedo : Button = $UI/HBox/Center/CenterContainer/VBoxContainer/BTN_BoneRedo
@onready var BTN_boneShow : Button = $UI/HBox/Center/CenterContainer2/VBoxContainer/BTN_BoneShow

# Popups
@onready var POPUP_extrasPop : Control = $UI/HBox/Center/VBoxContainer/ExtraPopup
@onready var POPUP_extrasParts : VBoxContainer = $UI/HBox/Center/VBoxContainer/ExtraPopup/PanelContainer/ScrollContainer/extraParts
@onready var POPUP_lightsPop : Control = $UI/HBox/Center/VBoxContainer/LightsPopup

# Labels
@onready var TXT_BoneName : RichTextLabel = $UI/HBox/TXT_BoneName
@onready var TXT_BoneTransf : RichTextLabel = $UI/HBox/TXT_BoneTransf

# Sliders
@onready var SLIDER_lightIntensity : HSlider = $UI/HBox/Center/VBoxContainer/LightsPopup/PanelContainer2/VBoxContainer3/VBoxContainer2/HBoxContainer/HSL_LightIntensity
@onready var SLIDER_lightX : HSlider = $UI/HBox/Center/VBoxContainer/LightsPopup/PanelContainer2/VBoxContainer3/VBoxContainer2/HBoxContainer2/HSL_LightX
@onready var SLIDER_lightY : HSlider = $UI/HBox/Center/VBoxContainer/LightsPopup/PanelContainer2/VBoxContainer3/VBoxContainer2/HBoxContainer3/HSL_LightY

# Tabs
@onready var TAB_Lights : TabBar = $UI/HBox/Center/VBoxContainer/LightsPopup/PanelContainer2/VBoxContainer3/VBoxContainer/PanelContainer/TAB_Lights

# Internal
@onready var POSE_Controller:PoseController = $UI/PoseController
@onready var SCENE_Manager:SceneManager = $SceneManager
@onready var UI_BoneMarkers:BoneMarkers = $UI/BoneMarkers

# Variables
const MODE_ICONS := [preload("res://assets/rotate.png"), preload("res://assets/move.png"), preload("res://assets/scale.png")]  # indexed by PoseController.Mode

# Axis buttons only work while HELD. Godot turns just the first finger into mouse events, so the
# buttons can't see a second finger: held state is tracked from raw touches in _input() instead.
var _axis_buttons: Array[Button] = []  # X, Y, Z
var _axis_fingers := {}  # touch index -> axis (0, 1, 2) of the button that finger is holding
var _axis_mouse: int = -1  # axis held by a real mouse press

# Temp
var model : Node3D
var skeleton : Skeleton3D
var textures := {}
var _tex_root := ""  # where textures are read from: a folder path, or an Android folder (tree) URI

func _ready():
	_setup_ui()

# func _process(delta: float) -> void:

func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			var axis := _axis_button_at(event.position)
			if axis >= 0:
				_axis_fingers[event.index] = axis
				_refresh_held_axes()
		elif _axis_fingers.has(event.index):
			_axis_fingers.erase(event.index)
			_refresh_held_axes()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.device != InputEvent.DEVICE_ID_EMULATION:
		_axis_mouse = _axis_button_at(event.position) if event.pressed else -1  # emulated touch mouse is covered above
		_refresh_held_axes()

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		_axis_fingers.clear()  # a release can get lost when the app loses focus
		_axis_mouse = -1
		_refresh_held_axes()

## Which axis button (0 = X, 1 = Y, 2 = Z) is under `pos`, or -1.
func _axis_button_at(pos: Vector2) -> int:
	for k in _axis_buttons.size():
		var btn := _axis_buttons[k]
		if not btn.disabled and btn.is_visible_in_tree() and btn.get_global_rect().has_point(pos):
			return k
	return -1

func _refresh_held_axes() -> void:
	var held := Vector3.ZERO
	for axis in _axis_fingers.values():
		held[axis] = 1.0
	if _axis_mouse >= 0:
		held[_axis_mouse] = 1.0
	POSE_Controller.touch_axes = held
	for k in _axis_buttons.size():
		# Shows the pressed look for fingers the button itself can't see.
		var btn := _axis_buttons[k]
		if held[k] != 0.0:
			btn.add_theme_stylebox_override("normal", btn.get_theme_stylebox("pressed"))
		else:
			btn.remove_theme_stylebox_override("normal")

func _refresh_history_buttons() -> void:
	BTN_boneUndo.disabled = not POSE_Controller.can_undo()
	BTN_boneRedo.disabled = not POSE_Controller.can_redo()

## Shows how far the selected bone is from rest, in the mode being posed: [x, y, z].
func _refresh_transform_label() -> void:
	var v := POSE_Controller.get_transform_readout(UI_BoneMarkers.active, POSE_Controller.current_mode)
	TXT_BoneTransf.text = "[%s, %s, %s]" % [_fmt(v.x), _fmt(v.y), _fmt(v.z)]

static func _fmt(x: float) -> String:
	x = snappedf(x, 0.001)
	return String.num(0.0 if absf(x) < 0.0005 else x)

# -----------------| CUSTOM FUNCTIONS |-----------------
func _setup_ui():
	## Buttons
	BTN_loadModel.pressed.connect(func(): _open_picker(OS.get_name() == "Android"))
	
	BTN_extrasModel.pressed.connect(func(): POPUP_extrasPop.visible = not POPUP_extrasPop.visible)
	BTN_sceneLights.pressed.connect(func(): POPUP_lightsPop.visible = not POPUP_lightsPop.visible)
	
	## Bone tools (phone)
	BTN_boneMode.pressed.connect(func():
		POSE_Controller.touch_mode = ((POSE_Controller.touch_mode + 1) % MODE_ICONS.size()) as PoseController.Mode
		_sync_bone_mode()
	)
	_axis_buttons.assign([BTN_boneAxisX, BTN_boneAxisY, BTN_boneAxisZ])
	BTN_boneUndo.pressed.connect(POSE_Controller.undo)
	BTN_boneRedo.pressed.connect(POSE_Controller.redo)
	POSE_Controller.history_changed.connect(_refresh_history_buttons)
	POSE_Controller.bone_changed.connect(func(_i): _refresh_transform_label())
	POSE_Controller.mode_changed.connect(func(_m): _refresh_transform_label())
	BTN_boneMirror.toggle_mode = true
	BTN_boneMirror.toggled.connect(func(on: bool): POSE_Controller.mirror_mode = on)
	POSE_Controller.mirror_mode_changed.connect(func(on: bool): BTN_boneMirror.set_pressed_no_signal(on))  # keeps it in sync with the M key
	_sync_bone_mode()
	_refresh_history_buttons()
	_refresh_transform_label()
	
	## Tapping the bone name deselects (safeguard for when the camera is too close to tap empty space)
	TXT_BoneName.mouse_filter = Control.MOUSE_FILTER_STOP
	TXT_BoneName.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			UI_BoneMarkers.select(-1)
	)
	
	## Tabs
	TAB_Lights.tab_changed.connect(_sync_light_sliders)
	_sync_light_sliders(TAB_Lights.current_tab)  # show the real light values from the start

	## Double-click a light slider to reset it to the scene's authored value
	_on_double_click(SLIDER_lightIntensity, func(): _reset_light("intensity"))
	_on_double_click(SLIDER_lightX, func(): _reset_light("rot_x"))
	_on_double_click(SLIDER_lightY, func(): _reset_light("rot_y"))
	
	## Sliders
	BTN_lightOn.toggled.connect(func(value):
		if not SCENE_Manager._valid_light(TAB_Lights.current_tab):
			return
		
		SCENE_Manager.set_light_active(TAB_Lights.current_tab, value)
	)
	
	SLIDER_lightIntensity.value_changed.connect(func(value):
		if not SCENE_Manager._valid_light(TAB_Lights.current_tab):
			return
		
		SCENE_Manager.set_light_intensity(TAB_Lights.current_tab, value)
	)
	
	SLIDER_lightX.value_changed.connect(func(value):
		if not SCENE_Manager._valid_light(TAB_Lights.current_tab):
			return
		
		SCENE_Manager.set_light_rotation_x(TAB_Lights.current_tab, 90 * value)
	)
	
	SLIDER_lightY.value_changed.connect(func(value):
		if not SCENE_Manager._valid_light(TAB_Lights.current_tab):
			return
		
		SCENE_Manager.set_light_rotation_y(TAB_Lights.current_tab, 180 * value)
	)

func _sync_bone_mode() -> void:
	BTN_boneMode.icon = MODE_ICONS[POSE_Controller.touch_mode]

func _on_file_selected(path: String, tex_root: String = "") -> void:
	_tex_root = tex_root if not tex_root.is_empty() else path.get_base_dir()
	
	var parser := XPSParser.new()
	var data := parser.parse(path)
	
	if data.is_empty():
		print( parser.last_error )
		
		for child in get_children():
			if child is FileDialog:
				child.queue_free()
		return
	
	if model:
		model.queue_free()
		textures.clear()
	
	model = Node3D.new()
	
	model.name = "Model 0"
	
	skeleton = XPSParser.build_skeleton(data["bones"])
	skeleton.name = "Armature"
	model.add_child( skeleton )
	
	for mesh in data["meshes"]:
		print(mesh["name"])
		
		var mesh_inst := MeshInstance3D.new()
		mesh_inst.name = mesh["name"]
		var mesh_arr := ArrayMesh.new()
		mesh_arr.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, mesh["arrays"])
		mesh_inst.mesh = mesh_arr
		
		var material := StandardMaterial3D.new()
		material.normal_enabled = false
		material.cull_mode = BaseMaterial3D.CULL_BACK
		material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY
		material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX
		material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
		material.roughness = .85
		
		for idx in range( mesh["textures"].size() ):
			if idx > 0:
				break
			
			var tex_path := _texture_path(mesh["textures"][idx]["file"])
			var tex := XPSParser.load_texture(tex_path, textures)
			
			if tex == null:
				print("texture not found: ", tex_path)
				continue
			
			if idx == 0:
				material.albedo_texture = tex
				
				if tex.get_meta("has_alpha", false):
					material.cull_mode = BaseMaterial3D.CULL_DISABLED
					material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
					material.alpha_scissor_threshold = .3
					
					material.render_priority = 1
			#else:
				#material.normal_enabled = true
				#material.normal_texture = tex
			
		mesh_inst.material_override = material
		
		model.add_child( mesh_inst )
		
		mesh_inst.skeleton = NodePath("../Armature")
		
		var checkPart = CheckButton.new()
		checkPart.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		checkPart.add_theme_font_size_override("font_size", 13)
		checkPart.mouse_filter = Control.MOUSE_FILTER_PASS
		checkPart.text = mesh["name"]
		checkPart.button_pressed = true
		checkPart.pressed.connect(func(): mesh_inst.visible = checkPart.button_pressed)
		POPUP_extrasParts.add_child(checkPart)
	
	add_child(model)
	
	UI_BoneMarkers.setup(skeleton, $CamRig/Camera3D)
	
	UI_BoneMarkers.bone_selected.connect(func(bone):
		TXT_BoneName.text = "None" if bone < 0 else skeleton.get_bone_name(bone)
		_refresh_transform_label()
		
		if bone < 0:
			return
		
		print("selected bone %s (index: %d)" % [ skeleton.get_bone_name(bone), bone ])
	)
	
	POSE_Controller.setup(skeleton, $CamRig/Camera3D, UI_BoneMarkers)
	
	BTN_loadModel.disabled = true
	BTN_sceneLights.disabled = false
	BTN_extrasModel.disabled = false
	BTN_boneMode.disabled = false
	for btn in _axis_buttons:
		btn.disabled = false
	BTN_boneMirror.disabled = false
	BTN_boneShow.disabled = false
	BTN_boneShow.pressed.connect(func():
		UI_BoneMarkers.markers_visible = not UI_BoneMarkers.markers_visible
	)
	_refresh_history_buttons()
	
	for child in get_children():
		if child is FileDialog:
			child.queue_free()

## Opens the system picker. On Android it picks a FOLDER, because Android only lets the app read
## the files you grant it: the folder grant covers the model AND its textures.
func _open_picker(pick_folder: bool, known_folder: String = "") -> void:
	# Android second step: open the system picker already inside the folder that was just granted.
	if not pick_folder and known_folder.begins_with("content://"):
		_open_android_file_picker(known_folder)
		return
	
	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_OPEN_DIR if pick_folder else FileDialog.FILE_MODE_OPEN_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.set_customization_flag_enabled(FileDialog.CUSTOMIZATION_CREATE_FOLDER, false)
	fd.set_customization_flag_enabled(FileDialog.CUSTOMIZATION_DELETE, false)
	fd.set_customization_flag_enabled(FileDialog.CUSTOMIZATION_FAVORITES, false)
	fd.set_customization_flag_enabled(FileDialog.CUSTOMIZATION_RECENT, false)
	fd.set_flag(Window.FLAG_BORDERLESS, true)
	fd.set_flag(Window.FLAG_RESIZE_DISABLED, true)
	fd.use_native_dialog = true
	fd.size = Vector2i( 336, 559 )
	fd.position = Vector2i( -7, 0 )
	fd.filters = PackedStringArray(["*.xps ; XNALara XPS", "*.mesh ; XNALara mesh"])
	fd.title = "Select the model's folder" if pick_folder else "Select XPS file"
	fd.content_scale_stretch = fd.CONTENT_SCALE_STRETCH_FRACTIONAL
	fd.content_scale_factor = .7
	
	add_child(fd)
	
	if pick_folder:
		fd.dir_selected.connect(_on_folder_selected)
	else:
		fd.file_selected.connect(func(path: String): _on_file_selected(path, known_folder))
	fd.canceled.connect(func(): fd.queue_free())
	fd.popup_centered()

## Android: opens the system file picker at `tree_uri` (the folder picked a moment ago).
## Goes through DisplayServer directly because FileDialog would mangle a content:// start path.
func _open_android_file_picker(tree_uri: String) -> void:
	DisplayServer.file_dialog_show(
		"Select the model file",
		_tree_to_document_uri(tree_uri),
		"", false,
		DisplayServer.FILE_DIALOG_MODE_OPEN_FILE,
		PackedStringArray(["*.xps", "*.mesh"]),
		func(ok: bool, paths: PackedStringArray, _filter: int):
			if ok and not paths.is_empty():
				_on_file_selected(paths[0], tree_uri)
	)

## The picker's start location must be a document URI, but a folder grant gives a tree URI
## (".../tree/<id>" or ".../tree/<id>/document/<id>"). Same authority, different path.
func _tree_to_document_uri(tree_uri: String) -> String:
	var i := tree_uri.find("/tree/")
	if i == -1:
		return tree_uri
	var rest := tree_uri.substr(i + 6)
	var j := rest.find("/document/")
	var doc_id := rest.substr(j + 10) if j != -1 else rest
	return tree_uri.substr(0, i) + "/document/" + doc_id

## Android: `dir` is a folder (tree) URI. Find the model inside it; if the folder can't be
## listed, ask for the model file itself and still read the textures from this folder.
func _on_folder_selected(dir: String) -> void:
	_free_file_dialogs()
	var model_name := ""
	var files := _list_tree_files(dir) if dir.begins_with("content://") else DirAccess.get_files_at(dir)
	print("Folder listing found %d file(s) in: %s" % [files.size(), dir])
	for f in files:
		if f.get_extension().to_lower() in ["xps", "mesh"]:
			model_name = f
			break
	if model_name.is_empty():
		print("Couldn't list the folder (or no .xps/.mesh in it); asking for the model file: ", dir)
		_open_picker.call_deferred(false, dir)
		return
	_on_file_selected(dir + "#" + model_name, dir)

## Lists the file names inside an Android folder (tree) URI. Godot can READ files through
## "treeUri#file" but has no directory listing for content:// URIs (DirAccess returns nothing),
## so this asks Android's DocumentsContract directly. Returns an empty list if anything fails,
## which makes the caller fall back to the second picker.
func _list_tree_files(tree_uri: String) -> PackedStringArray:
	var names := PackedStringArray()
	if not Engine.has_singleton("AndroidRuntime"):
		return names
	var runtime = Engine.get_singleton("AndroidRuntime")
	var contract = JavaClassWrapper.wrap("android.provider.DocumentsContract")
	var uri_class = JavaClassWrapper.wrap("android.net.Uri")
	if contract == null or uri_class == null:
		return names
	var tree = uri_class.parse(tree_uri)
	var children = contract.buildChildDocumentsUriUsingTree(tree, contract.getTreeDocumentId(tree))
	var cursor = runtime.getActivity().getContentResolver().query(children, PackedStringArray(["_display_name"]), "", PackedStringArray(), "_display_name", null)  # 6-arg overload: selection, selectionArgs, sortOrder, CancellationSignal. Folders ignore selection; the bridge rejects null for String params.
	if cursor == null:
		return names
	while cursor.moveToNext():
		names.append(cursor.getString(0))
	cursor.close()
	return names

## Where a texture named in the model lives: "treeUri#file" on Android, "folder/file" elsewhere.
func _texture_path(file: String) -> String:
	if _tex_root.begins_with("content://"):
		return _tex_root + "#" + file
	return _tex_root.path_join(file)

func _free_file_dialogs() -> void:
	for child in get_children():
		if child is FileDialog:
			child.queue_free()

func _sync_light_sliders(index: int) -> void:
	var l := SCENE_Manager.get_light(index)
	if l == null:
		return
	
	BTN_lightOn.set_pressed_no_signal(l.on)
	SLIDER_lightIntensity.set_value_no_signal(l.intensity)
	SLIDER_lightX.set_value_no_signal(l.rot_x / 90.0)  # sliders run -1..1, lights store degrees
	SLIDER_lightY.set_value_no_signal(l.rot_y / 180.0)

func _reset_light(property: String) -> void:
	SCENE_Manager.reset_light_property(TAB_Lights.current_tab, property)
	_sync_light_sliders(TAB_Lights.current_tab)

func _on_double_click(slider: Range, action: Callable) -> void:
	slider.tooltip_text = "Double-click to reset"
	slider.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed and event.double_click:
			slider.accept_event()  # stop the slider from also jumping to the click position
			action.call()
	)
