extends Node

const LOCAL_PACKS := ["res://tiles_xyz.zip"]              # your dev pack
const LOCAL_TILE_BASE := "res://tiles_xyz"                # path inside the pack
const REMOTE_TILE_BASE := "https://lanker.toonlab.be/tiles"

const KEY := "application/custom/tile_base_url"

static func get_tile_base_url() -> String:
	return str(ProjectSettings.get_setting(KEY, LOCAL_TILE_BASE))

func _enter_tree() -> void:
	if OS.has_feature("web"):
		# Browser build → fetch tiles over HTTP
		ProjectSettings.set_setting(KEY, REMOTE_TILE_BASE)
		print("Boot: web build, tiles from", REMOTE_TILE_BASE)
	else:
		# Desktop/dev → mount local pack and use res://
		var mounted_any := false
		for p in LOCAL_PACKS:
			if ProjectSettings.load_resource_pack(p):
				print("Mounted:", p)
				mounted_any = true
			else:
				push_warning("Could not mount: %s" % p)
		# Prefer mounted pack; fall back to folder if present
		if mounted_any or DirAccess.dir_exists_absolute(LOCAL_TILE_BASE):
			ProjectSettings.set_setting(KEY, LOCAL_TILE_BASE)
		else:
			# last-resort fallback to remote even on desktop
			ProjectSettings.set_setting(KEY, REMOTE_TILE_BASE)
			push_warning("No local tiles found; using remote:", REMOTE_TILE_BASE)
