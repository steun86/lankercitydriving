# canvas_layer.gd
extends CanvasLayer
## Overlay HUD:
##  - Top-left stats: FPS, Camera, Car, Tiles, RAM/VRAM
##  - Bottom buttons: Drive / Pan (emits mode_changed)
##  - Adds a TileBoxesDrawer child to draw tile outlines

signal mode_changed(new_mode: int)
enum { MODE_DRIVE = 1, MODE_PAN = 2 }

@export var car_path: NodePath = ^"../Car"
@export var tile_streamer_path: NodePath = ^"../TileStreamer"

# Tile box options (passed to drawer)
@export var show_tile_boxes: bool = true
@export var show_tile_ids: bool = false

# Limit how many tile IDs to list in text
@export var max_tile_ids_in_text: int = 24

var _root: Control
var _label: Label
var _row: HBoxContainer
var _mode: int = MODE_DRIVE

# Bottom “manual zoom” row + buttons
var _row_zoom: HBoxContainer
var _btn_auto: Button
var _btn_z17: Button
var _btn_z18: Button
var _btn_z19: Button
var _btn_z20: Button

func _ready() -> void:
	# Fullscreen root so children can anchor
	_root = Control.new()
	_root.anchor_left = 0; _root.anchor_top = 0; _root.anchor_right = 1; _root.anchor_bottom = 1
	add_child(_root)

	# --- Stats label (top-left) ---
	_label = Label.new()
	_label.add_theme_color_override("font_color", Color.WHITE)
	_label.set("theme_override_font_sizes/font_size", 14)
	_label.anchor_left = 0.0; _label.anchor_top = 0.0
	_label.offset_left = 8;   _label.offset_top = 8
	_root.add_child(_label)

	# --- Bottom buttons (centered) ---
	_row = HBoxContainer.new()
	_row.add_theme_constant_override("separation", 6)
	_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_row.anchor_left = 0.0; _row.anchor_right = 1.0
	_row.anchor_top = 1.0;  _row.anchor_bottom = 1.0
	_row.offset_left = 8;   _row.offset_right = -8
	_row.offset_top = -48;  _row.offset_bottom = -8
	_root.add_child(_row)

	var b_drive := Button.new()
	b_drive.text = "1: Drive"
	b_drive.toggle_mode = true
	b_drive.button_pressed = true
	b_drive.pressed.connect(func(): _set_mode(MODE_DRIVE))
	_row.add_child(b_drive)

	var b_pan := Button.new()
	b_pan.text = "2: Pan / Place"
	b_pan.toggle_mode = true
	b_pan.pressed.connect(func(): _set_mode(MODE_PAN))
	_row.add_child(b_pan)

	# keep toggles exclusive
	b_drive.toggled.connect(func(pressed: bool):
		if pressed: b_pan.button_pressed = false)
	b_pan.toggled.connect(func(pressed: bool):
		if pressed: b_drive.button_pressed = false)
		
	# --- Manual Zoom Row (Auto, z17..z20) ---
	_row_zoom = HBoxContainer.new()
	_row_zoom.add_theme_constant_override("separation", 6)
	_row_zoom.alignment = BoxContainer.ALIGNMENT_CENTER

	# Anchor it just above the Drive/Pan row at the bottom
	_row_zoom.anchor_left = 0.0
	_row_zoom.anchor_right = 1.0
	_row_zoom.anchor_top = 1.0
	_row_zoom.anchor_bottom = 1.0
	_row_zoom.offset_left = 8
	_row_zoom.offset_right = -8
	_row_zoom.offset_top = -88   # sits above the Drive/Pan row
	_row_zoom.offset_bottom = -48
	_root.add_child(_row_zoom)

	# Build buttons
	_btn_auto = _make_zoom_btn("Auto", func():
		_auto_zoom()
		# exclusivity: make Auto the only pressed one
		_btn_auto.button_pressed = true
		for b in [_btn_z17, _btn_z18, _btn_z19, _btn_z20]:
			if b: b.button_pressed = false
	)
	_btn_auto.button_pressed = true  # start in Auto
	_row_zoom.add_child(_btn_auto)

	_btn_z17 = _make_zoom_btn("z17", func():
		_force_zoom(17)
		_btn_auto.button_pressed = false
		for b in [_btn_z17, _btn_z18, _btn_z19, _btn_z20]:
			if b: b.button_pressed = (b == _btn_z17)
	)
	_row_zoom.add_child(_btn_z17)

	_btn_z18 = _make_zoom_btn("z18", func():
		_force_zoom(18)
		_btn_auto.button_pressed = false
		for b in [_btn_z17, _btn_z18, _btn_z19, _btn_z20]:
			if b: b.button_pressed = (b == _btn_z18)
	)
	_row_zoom.add_child(_btn_z18)

	_btn_z19 = _make_zoom_btn("z19", func():
		_force_zoom(19)
		_btn_auto.button_pressed = false
		for b in [_btn_z17, _btn_z18, _btn_z19, _btn_z20]:
			if b: b.button_pressed = (b == _btn_z19)
	)
	_row_zoom.add_child(_btn_z19)

	_btn_z20 = _make_zoom_btn("z20", func():
		_force_zoom(20)
		_btn_auto.button_pressed = false
		for b in [_btn_z17, _btn_z18, _btn_z19, _btn_z20]:
			if b: b.button_pressed = (b == _btn_z20)
	)
	_row_zoom.add_child(_btn_z20)

	# Disable buttons for zoom folders that don't exist
	if has_node(tile_streamer_path):
		var ts := get_node(tile_streamer_path)
		if ts and ts.has_method("get_available_zooms"):
			var avail: Array = ts.get_available_zooms()
			_btn_z17.disabled = not avail.has(17)
			_btn_z18.disabled = not avail.has(18)
			_btn_z19.disabled = not avail.has(19)
			_btn_z20.disabled = not avail.has(20)

	
	# --- TileBoxesDrawer (screen-space rectangles) ---
	if show_tile_boxes:
		var Drawer := preload("res://tile_boxes_drawer.gd") # adjust path if needed
		var boxes: Control = Drawer.new()
		boxes.set("tile_streamer_path", tile_streamer_path)
		boxes.set("show_ids", show_tile_ids)
		add_child(boxes)  # child of CanvasLayer (drawn over world, under buttons)

func _process(_dt: float) -> void:
	var lines: Array[String] = []

	lines.append("Mode: " + ("Drive" if _mode == MODE_DRIVE else "Pan/Place"))
	lines.append("FPS: %d" % Engine.get_frames_per_second())

	# Camera
	var cam := get_viewport().get_camera_2d()
	if cam:
		lines.append("Camera: (%.1f, %.1f) zoom=%.2f" %
			[cam.global_position.x, cam.global_position.y, cam.zoom.x])

	# Car
	if has_node(car_path):
		var car: Node2D = get_node(car_path)
		lines.append("Car: (%.1f, %.1f)" % [car.global_position.x, car.global_position.y])

	# Tile summary + sample IDs
	if has_node(tile_streamer_path):
		var ts := get_node(tile_streamer_path)
		if ts.has_method("_get_loaded_summary"):
			var s: Dictionary = ts._get_loaded_summary()
			lines.append("Tiles z=%s count=%d x:[%d-%d] y:[%d-%d]" %
				[str(s.get("z")), int(s.get("count", 0)),
				 int(s.get("min_x", 0)), int(s.get("max_x", 0)),
				 int(s.get("min_y", 0)), int(s.get("max_y", 0))])

	# Memory (RAM + VRAM)
	var mem_ram := Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0
	var mem_vram := Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0
	var mem_tex := Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0
	lines.append("RAM: %.1f MB | VRAM: %.1f MB (textures: %.1f MB)" % [mem_ram, mem_vram, mem_tex])

	_label.text = "\n".join(lines)

func _unhandled_input(event: InputEvent) -> void:
	# Keyboard shortcuts (also add Input Map actions: drive_mode=1, pan_mode=2)
	if Input.is_action_just_pressed("drive_mode") \
	or (event is InputEventKey and event.pressed and event.keycode == KEY_1):
		_set_mode(MODE_DRIVE)
	if Input.is_action_just_pressed("pan_mode") \
	or (event is InputEventKey and event.pressed and event.keycode == KEY_2):
		_set_mode(MODE_PAN)

func _set_mode(m: int) -> void:
	if _mode == m: return
	_mode = m
	mode_changed.emit(_mode)

func _make_zoom_btn(text: String, pressed_cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.pressed.connect(pressed_cb)
	return b

func _force_zoom(z: int) -> void:
	if not has_node(tile_streamer_path): return
	var ts := get_node(tile_streamer_path)
	if ts and ts.has_method("set_forced_zoom"):
		ts.set_forced_zoom(z)

func _auto_zoom() -> void:
	if not has_node(tile_streamer_path): return
	var ts := get_node(tile_streamer_path)
	if ts and ts.has_method("clear_forced_zoom"):
		ts.clear_forced_zoom()
