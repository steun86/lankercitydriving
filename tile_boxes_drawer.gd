# tiles_boxes_drawer.gd
extends Control
## Draws screen-space rectangles for loaded tiles (unrotated Camera2D).
## Put this node as a child of your CanvasLayer HUD.

@export var tile_streamer_path: NodePath
@export var show_fills: bool = true
@export var show_ids: bool = false
@export var line_color: Color = Color(1, 1, 0, 0.9)
@export var fill_color: Color = Color(1, 1, 0, 0.10)

var _font := ThemeDB.fallback_font
var _font_size := ThemeDB.fallback_font_size

func _ready() -> void:
	# Cover the whole viewport
	anchor_left = 0.0;  anchor_top = 0.0
	anchor_right = 1.0; anchor_bottom = 1.0
	offset_left = 0; offset_top = 0; offset_right = 0; offset_bottom = 0
	mouse_filter = MOUSE_FILTER_IGNORE

func _process(_dt: float) -> void:
	queue_redraw() # cheap (just lines/text)

func _draw() -> void:
	if not has_node(tile_streamer_path): return
	var ts := get_node(tile_streamer_path)
	if ts == null: return
	if not (ts.has_method("_get_loaded_tiles") and ts.has_method("world_pos_for")): return

	var cam := get_viewport().get_camera_2d()
	if cam == null: return

	# screen = half + (world - cam_pos) * cam.zoom   (unrotated Camera2D)
	var vp_size := get_viewport().get_visible_rect().size
	var half := vp_size * 0.5
	var zoom := cam.zoom

	var keys: Array = ts._get_loaded_tiles()
	for k in keys:
		var zxy: Vector3i = k  # (z,x,y)
		var wpos: Vector2 = ts.world_pos_for(zxy.x, zxy.y, zxy.z) # top-left world px

		# IMPORTANT: each lower zoom covers more world → scale by 2^(baseZ - z)
		var s2b := 1
		if "_z_base" in ts:
			s2b = 1 << int(ts._z_base - zxy.x)

		var screen_pos: Vector2 = half + (wpos - cam.global_position) * zoom
		var screen_size: Vector2 = Vector2(ts.tile_px * s2b, ts.tile_px * s2b) * zoom
		var r := Rect2(screen_pos, screen_size)

		if show_fills:
			draw_rect(r, fill_color, true)
			draw_rect(r, line_color, false)

		if show_ids:
			draw_string(_font, screen_pos + Vector2(4, 14),
				"(%d,%d,%d)" % [zxy.x, zxy.y, zxy.z],
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, _font_size)
