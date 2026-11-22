extends Node3D

# UI related

# Buttons
@onready var BTN_loadModel:Button = $UI/HBox/Header/HeaderOptions/BTN_loadModel
@onready var BTN_extrasModel:Button = $UI/HBox/Footer/FooterOptions/BTN_extrasModel

# Popups
@onready var POPUP_extrasPop:Control = $UI/HBox/Center/ExtraPopup
@onready var POPUP_extrasParts:VBoxContainer = $UI/HBox/Center/ExtraPopup/PanelContainer/ScrollContainer/extraParts

# Internal
@onready var POSE_Controller:PoseController = $UI/PoseController
@onready var UI_BoneMarkers:BoneMarkers = $UI/BoneMarkers

# Labels
@onready var TXT_BoneName : RichTextLabel = $/root/Scene/UI/HBox/Center/TXT_BoneName

# Variables

# Temp
var model : Node3D
var skeleton : Skeleton3D
var textures := {}

func _ready():
	_setup_ui()

# func _process(delta: float) -> void:

# -----------------| CUSTOM FUNCTIONS |-----------------
func _setup_ui():
	BTN_loadModel.pressed.connect(func():
		var fd := FileDialog.new()
		fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
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
		fd.title = "Select XPS file"
		fd.content_scale_stretch = fd.CONTENT_SCALE_STRETCH_FRACTIONAL
		fd.content_scale_factor = .7
		
		add_child(fd)
		
		fd.file_selected.connect(_on_file_selected)
		fd.canceled.connect(func(): fd.queue_free())
		fd.popup_centered()
	)
	
	BTN_extrasModel.pressed.connect(func(): POPUP_extrasPop.visible = not POPUP_extrasPop.visible)

func _on_file_selected(path: String) -> void:
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
			
			var tex := XPSParser.load_texture(path.get_base_dir().path_join(mesh["textures"][idx]["file"]), textures)
			
			if tex == null:
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
		
		if bone < 0:
			return
		
		print("selected bone %s (index: %d)" % [ skeleton.get_bone_name(bone), bone ])
	)
	
	POSE_Controller.setup(skeleton, $CamRig/Camera3D, UI_BoneMarkers)
	
	BTN_loadModel.disabled = true
	BTN_extrasModel.disabled = false
	
	for child in get_children():
		if child is FileDialog:
			child.queue_free()
