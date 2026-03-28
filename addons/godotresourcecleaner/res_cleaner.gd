tool
extends EditorPlugin
## Init Plugin

const WINDOW = preload("res://addons/godotresourcecleaner/window.tscn")

var button : Button
var window : WindowDialog

func _enter_tree() -> void:
	# Add toolbar button
	button = Button.new()
	# Fallback to standard editor icon since inline SVGs are not cleanly supported in Godot 3 
	button.icon = get_editor_interface().get_base_control().get_icon("Tools", "EditorIcons")
	button.hint_tooltip = "Open Godot Resource Cleaner"
	button.connect("pressed", self, "_on_button_pressed")
	add_control_to_container(CONTAINER_TOOLBAR, button)

	# Load and attach window
	window = WINDOW.instance()
	window.editor_interface = get_editor_interface()
	window.visible = false
	get_editor_interface().get_base_control().add_child(window)

func _on_button_pressed() -> void:
	window.popup_centered(Vector2(720, 720))

func _exit_tree() -> void:
	# Clean up plugin
	remove_control_from_container(CONTAINER_TOOLBAR, button)
	if button:
		button.queue_free()
	if window:
		window.queue_free()