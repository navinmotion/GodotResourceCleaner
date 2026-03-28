tool
extends GridContainer
## Setting and handling filters

export(NodePath) var root_window_path
export(NodePath) var button_path

func _ready() -> void:
	# Name checkboxes
	for c in get_children():
		c.text = "." + c.name
	
	# Connect Button
	if button_path:
		var btn = get_node_or_null(button_path)
		if btn:
			btn.connect("pressed", self, "_toggle_all")
	
	# Connect and set every CheckBox
	if root_window_path:
		var root_window = get_node_or_null(root_window_path)
		if root_window:
			for c in get_children():
				if c is CheckBox:
					c.connect("toggled", root_window, "on_checkbox_toggled", [c.text])

func _toggle_all() -> void:
	# Determine if all checkboxes are pressed
	var all_pressed := true
	for c in get_children():
		if c is CheckBox:
			if !c.pressed:
				all_pressed = false
				break
	
	# Toggle all checkboxes based on current state
	for c in get_children():
		if c is CheckBox:
			c.pressed = !all_pressed