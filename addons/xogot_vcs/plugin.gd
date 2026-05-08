@tool
extends EditorPlugin

var main_panel_instance: Control

func _enter_tree():
	var ui_path = "res://addons/xogot_vcs/main_ui.tscn"
	if FileAccess.file_exists(ui_path):
		main_panel_instance = load(ui_path).instantiate()
		
		# ADD THESE TWO LINES TO FIX THE SQUISHING
		main_panel_instance.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		main_panel_instance.size_flags_vertical = Control.SIZE_EXPAND_FILL
		
		EditorInterface.get_editor_main_screen().add_child(main_panel_instance)
		_make_visible(false)
	else:
		push_error("VCS Plugin: Could not find main_ui.tscn")


func _has_main_screen(): return true
func _make_visible(visible): if main_panel_instance: main_panel_instance.visible = visible
func _get_plugin_name(): return "VCS Engine"
func _get_plugin_icon(): return EditorInterface.get_editor_theme().get_icon("Git", "EditorIcons")

