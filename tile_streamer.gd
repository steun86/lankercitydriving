extends Node2D
##
## Multi-zoom XYZ Tile Streamer (Godot 4)
## Folder layout:  tiles_root_path/<z>/<x>/<y>.png|jpg
## Put a `.gdignore` file inside tiles_root_path so the editor won't import thousands of tiles.
##

@export_dir var tiles_root_path: String = "res://art/tiles_xyz"
@export var tile_px: int = 512            # 256 (default gdal2tiles) or 512 if you used --tilesize=512
@export var load_radius: int = 2          # tiles beyond view to LOAD
@export var unload_radius: int = 3        # tiles beyond view to KEEP (hysteresis)
@export var tiles_per_frame: int = 6      # cap load work per frame
@export var max_cache: int = 900          # cap total live sprites/textures
@export var move_threshold_px: float = 6.0
@export var zoom_threshold: float = 0.01
@export var show_debug: bool = true
@export var allow_manual_zoom: bool = true
var _zoom_override: bool = false

# Camera2D.zoom.x: smaller = zoomed out, larger = zoomed in
# Map it to tile zooms from coarse→fine.
var _zoom_rules := [
	[0.1, 17],  # very zoomed out  -> z17 (least detail)
	[0.5, 18],
	[10, 19]
	
]


# Runtime state
var _camera: Camera2D
var _loaded := {}                      # Dictionary<Vector3i(z,x,y), Sprite2D>
var _keep := {}
var _load_queue: Array[Vector3i] = []

# Available zooms and current/target selection
var _zooms: Array[int] = []
var _z_current: int = -1
var _z_target: int = -1

# Fixed world origin anchored to the HIGHEST zoom on disk
var _z_base: int = -1
var _base_min_x: int
var _base_min_y: int

# Per-zoom bounds (clamping); recomputed on swap
var _min_x: int; var _max_x: int
var _min_y: int; var _max_y: int

# Debounce/unchanged-window tracking
var _last_min_x_idx: int = 0
var _last_max_x_idx: int = -1
var _last_min_y_idx: int = 0
var _last_max_y_idx: int = -1
var _last_cam_pos: Vector2 = Vector2.INF
var _last_cam_zoom: float = -1.0

func _ready() -> void:
	_camera = get_viewport().get_camera_2d()
	if _camera:
		_camera.make_current()

	_zooms = _detect_available_zooms()
	if _zooms.is_empty():
		push_warning("TileStreamer: no zoom folders under %s" % tiles_root_path)
		set_process(false); return

	# Define a single, fixed world origin from the highest zoom
	_z_base = _zooms.max()
	if not _scan_bounds_for_zoom(_z_base):
		push_warning("No tiles found at base z=%d" % _z_base)
		set_process(false); return
	_base_min_x = _min_x
	_base_min_y = _min_y

	# Start at the highest zoom (or whatever you prefer)
	_z_current = _z_base
	_z_target = _z_current

	# Prepare bounds for current zoom (for clamping)
	_scan_bounds_for_zoom(_z_current)

	set_process(true)

func _process(dt: float) -> void:
	if _camera == null:
		return

	if not _zoom_override:
		_update_target_zoom()
		if _z_target != _z_current:
			_swap_zoom_level(_z_target)
	# else: keep the forced zoom level

	_update_visible_tiles()
	_drain_queue()	

# --- Zoom selection -----------------------------------------------------------

func _detect_available_zooms() -> Array[int]:
	var out: Array[int] = []
	var d := DirAccess.open(tiles_root_path)
	if d == null: return out
	for name in d.get_directories():
		if name.is_valid_int():
			out.append(int(name))
	out.sort()
	return out

func _pick_zoom_for_camera(cam_zoom: float) -> int:
	var chosen : Variant= _z_current if _z_current != -1 else _zooms.max()
	for rule in _zoom_rules:
		var max_cam: float = rule[0]
		var z: int = rule[1]
		if cam_zoom <= max_cam:
			chosen = z
			break
	# Snap to nearest available if missing
	if not _zooms.has(chosen):
		var nearest := _zooms[0]
		var best : Variant= abs(nearest - chosen)
		for z2 in _zooms:
			var d : Variant= abs(z2 - chosen)
			if d < best:
				best = d; nearest = z2
		chosen = nearest
	return chosen

func _update_target_zoom() -> void:
	var cam_zoom := _camera.zoom.x
	var new_target := _pick_zoom_for_camera(cam_zoom)
	if new_target != _z_current:
		_z_target = new_target

func _swap_zoom_level(new_z: int) -> void:
	# Clear sprites/queue
	for k in _loaded.keys(): _loaded[k].queue_free()
	_loaded.clear()
	_load_queue.clear()

	_z_current = new_z
	_scan_bounds_for_zoom(_z_current) # for clamping only

	# Reset debounce so we recompute immediately
	_last_min_x_idx = 0; _last_max_x_idx = -1
	_last_min_y_idx = 0; _last_max_y_idx = -1
	_last_cam_pos = Vector2.INF; _last_cam_zoom = -1.0

# --- Bounds scan per zoom -----------------------------------------------------

func _scan_bounds_for_zoom(z: int) -> bool:
	_min_x = 2147483647; _min_y = 2147483647
	_max_x = -2147483648; _max_y = -2147483648

	var z_path := "%s/%d" % [tiles_root_path, z]
	var dz := DirAccess.open(z_path)
	if dz == null: return false

	for x_name in dz.get_directories():
		if not x_name.is_valid_int(): continue
		var xi := int(x_name)
		_min_x = min(_min_x, xi); _max_x = max(_max_x, xi)

		var dx := DirAccess.open("%s/%s" % [z_path, x_name])
		if dx == null: continue
		for f in dx.get_files():
			if !(f.ends_with(".png") or f.ends_with(".jpg") or f.ends_with(".jpeg")): continue
			var base := f.get_basename()
			if not base.is_valid_int(): continue
			var yi := int(base)
			_min_y = min(_min_y, yi); _max_y = max(_max_y, yi)

	return _min_x != 2147483647 and _min_y != 2147483647

# --- Streaming ---------------------------------------------------------------

func _update_visible_tiles() -> void:
	# Debounce: only recompute when the camera moved/zoomed enough
	var cam_pos := _camera.global_position
	var cam_zoom := _camera.zoom.x
	if _last_cam_pos != Vector2.INF:
		if cam_pos.distance_to(_last_cam_pos) < move_threshold_px and abs(cam_zoom - _last_cam_zoom) < zoom_threshold:
			return
	_last_cam_pos = cam_pos; _last_cam_zoom = cam_zoom

	_keep.clear()

	# World rect in view (orthographic, unrotated). Note: zoom>1 => smaller world.
	var half: Vector2 = (get_viewport().get_visible_rect().size * 0.5) / cam_zoom
	var tl: Vector2 = cam_pos - half
	var br: Vector2 = cam_pos + half

	# Scale from CURRENT zoom to BASE zoom (power of two)
	var s2b: int = 1 << (_z_base - _z_current)

	# Convert world -> tile indices at CURRENT zoom, anchored to base origin.
	# world_x = ((x*s2b - _base_min_x) * tile_px)
	#  => x = floor((world_x / tile_px + _base_min_x) / s2b)
	var min_x_load: int = int((min(tl.x, br.x) / tile_px + _base_min_x) / s2b) - load_radius
	var max_x_load: int = int((max(tl.x, br.x) / tile_px + _base_min_x) / s2b) + load_radius
	var min_y_load: int = int((min(tl.y, br.y) / tile_px + _base_min_y) / s2b) - load_radius
	var max_y_load: int = int((max(tl.y, br.y) / tile_px + _base_min_y) / s2b) + load_radius

	# Clamp to dataset bounds at current zoom
	min_x_load = max(min_x_load, _min_x);  max_x_load = min(max_x_load, _max_x)
	min_y_load = max(min_y_load, _min_y);  max_y_load = min(max_y_load, _max_y)

	# KEEP window (larger) for hysteresis
	var min_x_keep: int = int((min(tl.x, br.x) / tile_px + _base_min_x) / s2b) - unload_radius
	var max_x_keep: int = int((max(tl.x, br.x) / tile_px + _base_min_x) / s2b) + unload_radius
	var min_y_keep: int = int((min(tl.y, br.y) / tile_px + _base_min_y) / s2b) - unload_radius
	var max_y_keep: int = int((max(tl.y, br.y) / tile_px + _base_min_y) / s2b) + unload_radius

	min_x_keep = max(min_x_keep, _min_x);  max_x_keep = min(max_x_keep, _max_x)
	min_y_keep = max(min_y_keep, _min_y);  max_y_keep = min(max_y_keep, _max_y)

	# Early-out if LOAD window unchanged
	if (min_x_load == _last_min_x_idx and max_x_load == _last_max_x_idx
	and min_y_load == _last_min_y_idx and max_y_load == _last_max_y_idx):
		return
	_last_min_x_idx = min_x_load; _last_max_x_idx = max_x_load
	_last_min_y_idx = min_y_load; _last_max_y_idx = max_y_load

	# Enqueue missing tiles in LOAD window
	for tx in range(min_x_load, max_x_load + 1):
		for ty in range(min_y_load, max_y_load + 1):
			var key := Vector3i(_z_current, tx, ty)
			_keep[key] = true
			if not _loaded.has(key) and not _load_queue.has(key):
				_load_queue.push_back(key)

	# Unload tiles outside the larger KEEP window (hysteresis)
	var drop: Array = []
	for k in _loaded.keys():
		var zxy: Vector3i = k
		if zxy.x != _z_current:
			drop.append(k); continue
		if zxy.y < min_x_keep or zxy.y > max_x_keep or zxy.z < min_y_keep or zxy.z > max_y_keep:
			drop.append(k)
	for k in drop:
		_loaded[k].queue_free()
		_loaded.erase(k)

func _drain_queue() -> void:
	if _load_queue.is_empty(): return
	var n : Variant= min(tiles_per_frame, _load_queue.size())
	for i in n:
		var key: Vector3i = _load_queue.pop_front()
		if key.x != _z_current: continue         # stale after zoom swap
		if _loaded.has(key): continue
		var tex := _load_tile_texture(key.x, key.y, key.z)
		if tex == null: continue
		var spr := Sprite2D.new()
		spr.centered = false
		spr.texture = tex
		spr.z_index = -10
		# Place in a SINGLE world space anchored to base origin
		#var s2b: int = 1 << (_z_base - key.x)
		#spr.position = Vector2(
			#((key.y * s2b) - _base_min_x) * tile_px,
			#((key.z * s2b) - _base_min_y) * tile_px
		#)
		
		# Scale from this tile's zoom to the base zoom (e.g. z20->z19 = 2x)
		var s2b: int = 1 << (_z_base - key.x)  # key.x is z
		spr.scale = Vector2(s2b, s2b)

		# Position in the fixed world (anchored at base_min_x/y)
		spr.position = Vector2(
			((key.y * s2b) - _base_min_x) * tile_px,
			((key.z * s2b) - _base_min_y) * tile_px
		)

		add_child(spr)
		_loaded[key] = spr
		if _loaded.size() > max_cache:
			_evict_some()

func _load_tile_texture(z: int, x: int, y: int) -> Texture2D:
	# Bypass importer; works with .gdignore
	var p_png := "%s/%d/%d/%d.png" % [tiles_root_path, z, x, y]
	var p_jpg := "%s/%d/%d/%d.jpg" % [tiles_root_path, z, x, y]
	var img := Image.new()
	var err := img.load(p_png)
	if err != OK:
		err = img.load(p_jpg)
		if err != OK:
			return null
	# img.generate_mipmaps() # optional, if you zoom a lot
	return ImageTexture.create_from_image(img)

func _evict_some() -> void:
	var cam_pos := _camera.global_position
	var entries: Array = []
	for k in _loaded.keys():
		var s: Sprite2D = _loaded[k]
		entries.append([s.position.distance_to(cam_pos), k])
	entries.sort_custom(func(a, b): return a[0] > b[0]) # farthest first
	var to_evict: int = max(0, _loaded.size() - max_cache)
	for i in to_evict:
		var key = entries[i][1]
		_loaded[key].queue_free()
		_loaded.erase(key)

# --- Overlay helpers ----------------------------------------------------------

func _get_loaded_count() -> int:
	return _loaded.size()

func _get_loaded_tiles() -> Array:
	return _loaded.keys()

func _get_loaded_summary() -> Dictionary:
	var count := _loaded.size()
	var min_xi := 9223372036854775807
	var max_xi := -9223372036854775808
	var min_yi := 9223372036854775807
	var max_yi := -9223372036854775808
	for k in _loaded.keys():
		var zxy: Vector3i = k
		min_xi = min(min_xi, zxy.y); max_xi = max(max_xi, zxy.y)
		min_yi = min(min_yi, zxy.z); max_yi = max(max_yi, zxy.z)
	return {
		"z": _z_current,
		"count": count,
		"min_x": min_xi, "max_x": max_xi,
		"min_y": min_yi, "max_y": max_yi
	}

# Convert a (z,x,y) tile id to WORLD pixel position (top-left) in the streamer's fixed world space.
func world_pos_for(z: int, x: int, y: int) -> Vector2:
	var s2b: int = 1 << (_z_base - z) # scale to base zoom
	return Vector2(
		((x * s2b) - _base_min_x) * tile_px,
		((y * s2b) - _base_min_y) * tile_px
	)

func set_forced_zoom(z: int) -> void:
	if not allow_manual_zoom:
		return
	# snap to a real folder (nearest), just like the auto logic
	if not _zooms.has(z):
		var nearest := _zooms[0]
		var best : Variant = abs(nearest - z)
		for z2 in _zooms:
			var d : Variant = abs(z2 - z)
			if d < best:
				best = d; nearest = z2
		z = nearest
	_zoom_override = true
	_swap_zoom_level(z)

func clear_forced_zoom() -> void:
	if not allow_manual_zoom:
		return
	_zoom_override = false
	# let auto rules pick on the next _process()

func get_available_zooms() -> Array[int]:
	return _zooms.duplicate()

func get_current_zoom() -> int:
	return _z_current

func is_zoom_overridden() -> bool:
	return _zoom_override
