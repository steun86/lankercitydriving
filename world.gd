extends Node2D

@export_dir var tiles_root_path: String = Boot.get_tile_base_url()
@export var zoom_level: int = 19
@export var tile_px: int = 512

@onready var cam: Camera2D = $Car/Camera2D
@onready var car: CharacterBody2D = $Car
@onready var overlay: CanvasLayer = $CanvasLayer

@export var zoom_min: float = 0.05
@export var zoom_max: float = 1.5
@export var zoom_step: float = 1.1   # multiplicative per wheel tick
var _target_zoom: float = 1.0

enum { MODE_DRIVE = 1, MODE_PAN = 2 }
var _mode: int = MODE_DRIVE

# pan params
@export var pan_speed: float = 1200.0
var _dragging := false
var _drag_last: Vector2

func _ready() -> void:	

	cam.make_current()
	_center_on_tiles()
	_target_zoom = cam.zoom.x
	overlay.mode_changed.connect(_on_mode_changed)
	
	
	var b := _compute_bounds_pixels_rebased()
	if b.size == Vector2i.ZERO:
		push_warning("No tiles found. Check tiles_root_path/zoom_level.")
		return

	# Limits in the SAME rebased space the streamer uses (origin at 0,0)
	cam.limit_left = 0
	cam.limit_top = 0
	cam.limit_right = b.size.x
	cam.limit_bottom = b.size.y

	# Start centered on the map
	#var center := Vector2(b.size) * 0.5
	#$Car.global_position = center
	#$cam.global_position = center
	
	# zoom
	_target_zoom = cam.zoom.x

func _compute_bounds_pixels_rebased() -> Rect2i:
	var z_path := "%s/%d" % [tiles_root_path, zoom_level]
	var dz := DirAccess.open(z_path)
	if dz == null: return Rect2i()

	var min_x := 2147483647
	var min_y := 2147483647
	var max_x := -2147483648
	var max_y := -2147483648

	for x_name in dz.get_directories():
		if not x_name.is_valid_int(): continue
		var xi := int(x_name)
		min_x = min(min_x, xi); max_x = max(max_x, xi)

		var dx := DirAccess.open("%s/%s" % [z_path, x_name])
		if dx == null: continue
		for f in dx.get_files():
			if !(f.ends_with(".png") or f.ends_with(".jpg") or f.ends_with(".jpeg")): continue
			var base := f.get_basename()
			if not base.is_valid_int(): continue
			var yi := int(base)
			min_y = min(min_y, yi); max_y = max(max_y, yi)

	if min_x == 2147483647 or min_y == 2147483647: return Rect2i()

	var w := (max_x - min_x + 1) * tile_px
	var h := (max_y - min_y + 1) * tile_px
	return Rect2i(Vector2i.ZERO, Vector2i(w, h))

func _process(delta: float) -> void:
	# Smooth towards target
	var z : Variant = clamp(_target_zoom, zoom_min, zoom_max)
	var current := cam.zoom.x
	var next := lerpf(current, z, clamp(delta * 10.0, 0.0, 1.0))
	if abs(next - _target_zoom) < 0.001:
		next = _target_zoom  # snap when close, stops endless tiny changes
	cam.zoom = Vector2(next, next)
	
	if _mode == MODE_PAN:
		_pan_update(delta)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		print_debug("btn:", event.button_index, " pressed:", event.pressed)
	# mouse wheel zoom
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:   
			_target_zoom /= zoom_step
			if _target_zoom < zoom_min: _target_zoom = zoom_min
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN: 
			_target_zoom *= zoom_step
			if _target_zoom > zoom_max : _target_zoom = zoom_max
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_dragging = true
			_drag_last = get_viewport().get_mouse_position()
		if event.button_index == MOUSE_BUTTON_LEFT and _mode == MODE_PAN:
			car.global_position = _mouse_world()
	if event is InputEventMouseButton and not event.pressed:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_dragging = false

	# keyboard shortcuts (mirror overlay)
	if Input.is_action_just_pressed("drive_mode"): 
		_on_mode_changed(MODE_DRIVE)
	if Input.is_action_just_pressed("pan_mode"):   
		_on_mode_changed(MODE_PAN)	
	
func _on_mode_changed(m: int) -> void:
	_mode = m
	car.control_enabled = (_mode == MODE_DRIVE)
	if _mode == MODE_DRIVE:
		cam.global_position = car.global_position


func _pan_update(delta: float) -> void:
	# WASD panning in world space
	var dir := Vector2.ZERO
	if Input.is_action_pressed("ui_up"):    dir.y -= 1.0
	if Input.is_action_pressed("ui_down"):  dir.y += 1.0
	if Input.is_action_pressed("ui_left"):  dir.x -= 1.0
	if Input.is_action_pressed("ui_right"): dir.x += 1.0
	if dir != Vector2.ZERO:
		cam.global_position += dir.normalized() * pan_speed * delta / cam.zoom.x

	# right mouse drag panning (screen space → world)
	if _dragging:
		var mouse_now := get_viewport().get_mouse_position()
		var delta_scr := mouse_now - _drag_last
		_drag_last = mouse_now
		cam.global_position -= delta_scr / cam.zoom  # unrotated cam

func _mouse_world() -> Vector2:
	# Convert screen mouse to world pos (unrotated Camera2D)
	var scr := get_viewport().get_mouse_position()
	var half := get_viewport_rect().size * 0.5
	return cam.global_position + (scr - half) / cam.zoom

func _center_on_tiles() -> void:
	# if you already have your rebased bounds, just center; otherwise do nothing
	# (you can keep your existing code that computes bounds and centers car/camera)
	pass
