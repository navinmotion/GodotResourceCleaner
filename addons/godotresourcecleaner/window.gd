tool
extends WindowDialog
## Godot Resource Cleaner Main Script

enum Sort { NONE, SIZE_ASC, SIZE_DESC, PATH_ASC, PATH_DESC }
var sort = Sort.NONE

enum ExceptionType { IGN_FOLDER, IGN_EXTENSION, EXCL_FOLDER, EXCL_EXTENSION, EXCL_CONTAINING }

const SETTING_USE_MULTITHREADING := "ResCleaner/data/use_multithreading"
const SETTING_KEEP_LIST := "ResCleaner/data/keep_list"
const SETTING_IGNORE_FOLDER := "ResCleaner/data/ignore_folder"
const SETTING_IGNORE_EXT := "ResCleaner/data/ignore_ext"
const SETTING_EXCLUDE_FOLDER := "ResCleaner/data/exclude_folder"
const SETTING_EXCLUDE_EXT := "ResCleaner/data/exclude_ext"
const SETTING_EXCLUDE_CONTAINING := "ResCleaner/data/exclude_containing"

const EXCLUDE_FOLDER_DEFAULT := [".godot", "addons", ".git"]
const EXCLUDE_EXT_DEFAULT := [".godot", ".import"] # Godot 3 doesn't generate .uid files by default
const EXCLUDE_CONTAINING_DEFAULT := ["gitignore", "gitattributes"]

var editor_interface

onready var main = find_node("Main")
onready var setting = find_node("Setting")
onready var keep_list = find_node("KeepList")
onready var overlay = find_node("Overlay")
onready var button_scan = find_node("ButtonScan")

onready var progress_bar = find_node("ProgressBar")
onready var progress_label = find_node("ProgressLabel")
onready var cancel_button = find_node("CancelButton")
onready var use_multithreading_check_button = find_node("UseMultithreadingCheckButton")

var exclude_folder := []
var exclude_ext := []
var exclude_containing := []

var ignore_folder := []
var ignore_ext := []

var search_ext := []

var keep_paths := []
var unused_files := []

var scan_thread : Thread

var selected_count := 0
var filter_on := false
var ignore_on := false
var use_multithreading := true
var is_scanning := false

var file_utils

func _ready() -> void:
	# Add the helper utility
	file_utils = preload("res://addons/godotresourcecleaner/file_utils.gd").new()
	add_child(file_utils)
	file_utils.connect("progress_updated", self, "_on_scan_progress_updated")

	# Tie UI events internally instead of relying on editor string matching from tscn 
	find_node("ButtonSetting").connect("pressed", self, "_on_button_setting_pressed")
	find_node("ButtonKeepList").connect("pressed", self, "_on_button_keep_list_pressed")
	find_node("LEFilter").connect("text_changed", self, "_on_le_filter_text_changed")
	find_node("ButtonScan").connect("pressed", self, "_on_button_scan_pressed")
	find_node("ButtonClean").connect("pressed", self, "_on_button_clean_pressed")
	find_node("ButtonKeep").connect("pressed", self, "_on_button_keep_pressed")
	find_node("ButtonDelete").connect("pressed", self, "_on_button_delete_pressed")
	find_node("ButtonDoneSetting").connect("pressed", self, "_on_button_done_pressed")
	find_node("FilterCheckButton").connect("toggled", self, "_on_check_button_toggled")
	find_node("IgnoreCheckButton").connect("toggled", self, "_on_ignore_check_button_toggled")
	find_node("UseMultithreadingCheckButton").connect("toggled", self, "_on_use_multithreading_check_button_toggled")
	find_node("ExcludeButton").connect("toggled", self, "_on_exclude_check_button_toggled")
	find_node("ButtonDoneKL").connect("pressed", self, "_on_button_done_kl_pressed")
	find_node("ButtonRemoveAll").connect("pressed", self, "_on_button_remove_all_pressed")

	# Confirmation Events
	find_node("ConfirmationDialog").connect("confirmed", self, "_on_confirmation_dialog_confirmed")
	find_node("ConfirmationDialogClean").connect("confirmed", self, "_on_confirmation_dialog_clean_confirmed")
	find_node("ConfirmationDialogKLRemoveAll").connect("confirmed", self, "_on_confirmation_dialog_kl_remove_all_confirmed")
	
	# Exceptions Form Events
	find_node("AddIgnoreFolderBtn").connect("pressed", self, "_on_button_ign_folder_pressed")
	find_node("AddIgnoreExtBtn").connect("pressed", self, "_on_button_ign_ext_pressed")
	find_node("AddExcludeFolderBtn").connect("pressed", self, "_on_button_exclude_folder_pressed")
	find_node("AddExcludeExtBtn").connect("pressed", self, "_on_button_exclude_ext_pressed")
	find_node("AddExcludeContBtn").connect("pressed", self, "_on_button_exclude_cont_pressed")

	# Dynamically set Standard Editor Icons 
	if Engine.editor_hint and editor_interface:
		var base = editor_interface.get_base_control()
		find_node("ButtonSetting").icon = base.get_icon("Tools", "EditorIcons")
		find_node("ButtonKeepList").icon = base.get_icon("FileList", "EditorIcons")
		find_node("ButtonScan").icon = base.get_icon("Search", "EditorIcons")
		find_node("ButtonClean").icon = base.get_icon("Clear", "EditorIcons")
		find_node("ButtonKeep").icon = base.get_icon("Pin", "EditorIcons")
		find_node("ButtonDelete").icon = base.get_icon("Remove", "EditorIcons")
		find_node("ButtonDoneSetting").icon = base.get_icon("Back", "EditorIcons")
		find_node("ButtonDoneKL").icon = base.get_icon("Back", "EditorIcons")
		find_node("ButtonSettingReset").icon = base.get_icon("Reload", "EditorIcons")
		find_node("ExcludeButton").icon = base.get_icon("NodeWarning", "EditorIcons")
		find_node("ButtonRemoveAll").icon = base.get_icon("Remove", "EditorIcons")
	
	find_node("HBoxFilter").visible = filter_on
	find_node("VBoxIgnore").visible = ignore_on
	main.visible = true
	overlay.visible = false
	setting.visible = false
	
	cancel_button.connect("pressed", self, "_on_cancel_scan_pressed")
	_hide_progress_ui()
	
	# Load Settings
	if ProjectSettings.has_setting(SETTING_KEEP_LIST):
		keep_paths = ProjectSettings.get(SETTING_KEEP_LIST)
		for path in keep_paths:
			find_node("VBoxKeepList").add_child(_add_keep_list_row(path))
			
	if ProjectSettings.has_setting(SETTING_USE_MULTITHREADING):
		use_multithreading = ProjectSettings.get(SETTING_USE_MULTITHREADING)
	use_multithreading_check_button.pressed = use_multithreading
		
	_load_exceptions(SETTING_IGNORE_FOLDER, ExceptionType.IGN_FOLDER)
	_load_exceptions(SETTING_IGNORE_EXT, ExceptionType.IGN_EXTENSION)
	_load_exceptions_wdefault(SETTING_EXCLUDE_FOLDER, EXCLUDE_FOLDER_DEFAULT, ExceptionType.EXCL_FOLDER)
	_load_exceptions_wdefault(SETTING_EXCLUDE_EXT, EXCLUDE_EXT_DEFAULT, ExceptionType.EXCL_EXTENSION)
	_load_exceptions_wdefault(SETTING_EXCLUDE_CONTAINING, EXCLUDE_CONTAINING_DEFAULT, ExceptionType.EXCL_CONTAINING)

func _hide_progress_ui() -> void:
	overlay.visible = false
	if progress_bar: progress_bar.visible = false
	if progress_label: progress_label.visible = false
	if cancel_button: cancel_button.visible = false

func _show_progress_ui() -> void:
	overlay.visible = true
	if progress_bar:
		progress_bar.visible = true
		progress_bar.value = 0
	if progress_label:
		progress_label.visible = true
		progress_label.text = "Starting scan..."
	if cancel_button: cancel_button.visible = true

func _on_scan_progress_updated(current: int, total: int, message: String) -> void:
	call_deferred("_update_progress_ui", current, total, message)

func _update_progress_ui(current: int, total: int, message: String) -> void:
	if progress_bar:
		progress_bar.value = (float(current) / total) * 100
	if progress_label:
		progress_label.text = message

func _on_cancel_scan_pressed() -> void:
	if is_scanning:
		file_utils.cancel_scan()
		if scan_thread:
			scan_thread.wait_to_finish()
			scan_thread = null
		is_scanning = false
		call_deferred("_update_scan_cancelled_ui")

func _update_scan_cancelled_ui() -> void:
	button_scan.disabled = false
	_hide_progress_ui()
	if progress_label:
		progress_label.text = "Scan cancelled"

func _load_exceptions(setting: String, type: int) -> void:
	if not ProjectSettings.has_setting(setting):
		return
	var items : Array = ProjectSettings.get(setting)
	for i in items:
		_add_exception(i, type, false)

func _load_exceptions_wdefault(setting: String, default_list: Array, type: int) -> void:
	var items : Array = ProjectSettings.get(setting) if ProjectSettings.has_setting(setting) else default_list
	for i in items:
		_add_exception(i, type, false)

func _on_button_setting_pressed() -> void:
	setting.show()

func _on_button_keep_list_pressed() -> void:
	keep_list.show()

func _on_button_scan_pressed() -> void:
	if is_scanning:
		return
		
	is_scanning = true
	button_scan.disabled = true
	_show_progress_ui()
	
	scan_thread = Thread.new()
	scan_thread.start(self, "_perform_scan_async")

func _perform_scan_async(userdata) -> void:
	selected_count = 0
	unused_files = file_utils.scan_res(
			filter_on, search_ext, exclude_folder, exclude_ext,
			exclude_containing, keep_paths, ignore_on,
			ignore_folder, ignore_ext, use_multithreading)
	
	call_deferred("_on_scan_completed")

func _on_scan_completed() -> void:
	is_scanning = false
	button_scan.disabled = false
	_hide_progress_ui()
	
	file_utils.sorting(unused_files, sort)
	_draw_result()
	
	if scan_thread:
		scan_thread.wait_to_finish()
		scan_thread = null

func _on_button_clean_pressed() -> void:
	find_node("CBImport").pressed = true
	find_node("CBFolders").pressed = true
	find_node("ConfirmationDialogClean").popup_centered()
	
func _on_confirmation_dialog_clean_confirmed() -> void:
	var any_clean := false
	if find_node("CBImport").pressed:
		any_clean = true
		file_utils.clean_import("res://", exclude_folder)
	if find_node("CBFolders").pressed:
		any_clean = true
		file_utils.clean_empty_folders("res://", exclude_folder)
		
	if any_clean:
		_refresh_filesystem()

func _on_size_button_pressed() -> void:
	sort = Sort.SIZE_DESC if sort == Sort.SIZE_ASC else Sort.SIZE_ASC
	file_utils.sorting(unused_files, sort)
	_draw_result()

func _on_path_button_pressed() -> void:
	sort = Sort.PATH_DESC if sort == Sort.PATH_ASC else Sort.PATH_ASC
	file_utils.sorting(unused_files, sort)
	_draw_result()

func _refresh() -> void:
	selected_count = 0
	unused_files = file_utils.scan_res(
			filter_on, search_ext, exclude_folder, exclude_ext,
			exclude_containing, keep_paths, ignore_on,
			ignore_folder, ignore_ext, use_multithreading)
	file_utils.sorting(unused_files, sort)
	_draw_result()

func _refresh_filesystem() -> void:
	if Engine.editor_hint and editor_interface:
		editor_interface.get_resource_filesystem().scan()

func _on_first_checkbox_toggled(is_toggled: bool) -> void:
	for file in unused_files:
		file.checkbox.pressed = is_toggled

func _on_checkbox_toggled(is_toggled: bool, file: Dictionary) -> void:
	file.is_checked = is_toggled
	selected_count += 1 if is_toggled else -1

func _on_button_keep_pressed() -> void:
	if unused_files.empty():
		return
	if selected_count == 0:
		return
		
	for ndf in unused_files:
		if ndf.is_checked:
			var path = ndf.path
			if !keep_paths.has(path):
				keep_paths.append(path)
				find_node("VBoxKeepList").add_child(_add_keep_list_row(path))
				
	ProjectSettings.set(SETTING_KEEP_LIST, keep_paths)
	ProjectSettings.save()
	_refresh()

func _on_button_delete_pressed() -> void:
	if unused_files.empty() or selected_count == 0:
		return
	find_node("ConfirmationDialog").dialog_text = "Are you sure you want to permanently delete all selected files (%d)? This action cannot be undone." % selected_count
	find_node("ConfirmationDialog").popup_centered()

func _on_confirmation_dialog_confirmed() -> void:
	file_utils.delete_selected(unused_files)
	_refresh_filesystem()
	_refresh()

func _on_le_filter_text_changed(new_text: String) -> void:
	var filter : String = new_text.strip_edges().to_lower()
	var container = find_node("VBoxMain")
	for c in container.get_children():
		var p_label = c.get_node_or_null("PathLabel")
		if p_label:
			var path_text : String = p_label.text.to_lower()
			c.visible = filter == "" or path_text.find(filter) != -1

func _draw_result() -> void:
	var container = find_node("VBoxMain")
	for child in container.get_children():
		child.queue_free()
		
	if unused_files.empty():
		return
		
	container.add_child(_add_first_row())
	container.add_child(HSeparator.new())
	
	for ndf in unused_files:
		container.add_child(_add_row(ndf))

func _add_first_row() -> HBoxContainer:
	var hbox := HBoxContainer.new()
	var c_box := CheckBox.new()
	c_box.connect("toggled", self, "_on_first_checkbox_toggled")
	
	var placeholder = Control.new()
	placeholder.rect_min_size = Vector2(48, 48)
	
	var s_button := Button.new()
	s_button.text = "Size"
	s_button.align = Button.ALIGN_LEFT
	s_button.rect_min_size.x = 80.0
	s_button.connect("pressed", self, "_on_size_button_pressed")
	
	var p_button := Button.new()
	p_button.text = "Path"
	p_button.align = Button.ALIGN_LEFT
	p_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p_button.connect("pressed", self, "_on_path_button_pressed")
	
	hbox.add_child(c_box)
	hbox.add_child(placeholder)
	hbox.add_child(s_button)
	hbox.add_child(p_button)
	
	return hbox
	
func _add_row(ndf: Dictionary) -> HBoxContainer:
	var hbox := HBoxContainer.new()
	var c_box := CheckBox.new()
	c_box.connect("toggled", self, "_on_checkbox_toggled", [ndf])
	ndf["checkbox"] = c_box
	
	var tex_rec = TextureRect.new()
	tex_rec.rect_min_size = Vector2(48, 48)
	tex_rec.expand = true
	
	var s_label := Label.new()
	s_label.text = file_utils.format_file_size(ndf.size)
	s_label.rect_min_size.x = 80.0
	
	var p_label := Label.new()
	p_label.name = "PathLabel"
	p_label.text = ndf.path
	
	hbox.add_child(c_box)
	hbox.add_child(tex_rec)
	hbox.add_child(s_label)
	hbox.add_child(p_label)
	
	if Engine.editor_hint and editor_interface:
		var preview = editor_interface.get_resource_previewer()
		preview.queue_resource_preview(ndf.path, self, "_on_preview_ready", tex_rec)
	
	return hbox

func _add_keep_list_row(path: String) -> HBoxContainer:
	var hbox := HBoxContainer.new()
	var rem_button := Button.new()
	if Engine.editor_hint and editor_interface:
		rem_button.icon = editor_interface.get_base_control().get_icon("Remove", "EditorIcons")
	rem_button.connect("pressed", self, "_on_button_remove_from_kl_pressed", [path, hbox])
	
	var sep := VSeparator.new()
	var tex_rec = TextureRect.new()
	tex_rec.rect_min_size = Vector2(48, 48)
	tex_rec.expand = true
	var p_label := Label.new()
	p_label.text = path
	
	hbox.add_child(rem_button)
	hbox.add_child(sep)
	hbox.add_child(tex_rec)
	hbox.add_child(p_label)
	
	if Engine.editor_hint and editor_interface:
		var preview = editor_interface.get_resource_previewer()
		preview.queue_resource_preview(path, self, "_on_preview_ready", tex_rec)
	
	return hbox
	
func _on_button_remove_from_kl_pressed(path: String, node: Node) -> void:
	if keep_paths.has(path):
		keep_paths.erase(path)
		node.queue_free()
		ProjectSettings.set(SETTING_KEEP_LIST, keep_paths)
		ProjectSettings.save()

func _on_preview_ready(path: String, preview: Texture, thumbnail_preview: Texture, tex_rec: TextureRect) -> void:
	if preview and tex_rec:
		tex_rec.texture = preview
	elif tex_rec and Engine.editor_hint and editor_interface:
		tex_rec.texture = editor_interface.get_base_control().get_icon("File", "EditorIcons")

func _on_button_remove_all_pressed() -> void:
	if not keep_paths.empty():
		find_node("ConfirmationDialogKLRemoveAll").popup_centered()

func _on_confirmation_dialog_kl_remove_all_confirmed() -> void:
	keep_paths.clear()
	var container = find_node("VBoxKeepList")
	for c in container.get_children():
		c.queue_free()
	ProjectSettings.set(SETTING_KEEP_LIST, keep_paths)
	ProjectSettings.save()

func _on_check_button_toggled(toggled_on: bool) -> void:
	filter_on = toggled_on
	find_node("HBoxFilter").visible = filter_on
	
func _on_button_done_pressed() -> void:
	setting.hide()

func _on_button_done_kl_pressed() -> void:
	keep_list.hide()

func on_checkbox_toggled(toggled_on: bool, ext: String) -> void:
	if toggled_on:
		search_ext.append(ext)
	else:
		if search_ext.has(ext):
			search_ext.erase(ext)
			
func _add_exception(txt: String, exception: int, save: bool) -> void:
	var hbox := HBoxContainer.new()
	var new_button := Button.new()
	if Engine.editor_hint and editor_interface: 
		new_button.icon = editor_interface.get_base_control().get_icon("Remove", "EditorIcons")
	
	new_button.connect("pressed", self, "_on_delete_exception", [exception, txt, hbox])
	var new_sep := VSeparator.new()
	var new_label := Label.new()
	new_label.text = txt
	
	hbox.add_child(new_button)
	hbox.add_child(new_sep)
	hbox.add_child(new_label)
	
	match exception:
		ExceptionType.IGN_FOLDER:
			if not ignore_folder.has(txt):
				ignore_folder.append(txt)
				find_node("VBoxIgnFolder").add_child(hbox)
				if save: ProjectSettings.set(SETTING_IGNORE_FOLDER, ignore_folder)
		ExceptionType.IGN_EXTENSION:
			if not ignore_ext.has(txt):
				ignore_ext.append(txt)
				find_node("VBoxIgnExt").add_child(hbox)
				if save: ProjectSettings.set(SETTING_IGNORE_EXT, ignore_ext)
		ExceptionType.EXCL_FOLDER:
			if not exclude_folder.has(txt):
				exclude_folder.append(txt)
				find_node("VBoxFolder").add_child(hbox)
				if save: ProjectSettings.set(SETTING_EXCLUDE_FOLDER, exclude_folder)
		ExceptionType.EXCL_EXTENSION:
			if not exclude_ext.has(txt):
				exclude_ext.append(txt)
				find_node("VBoxExt").add_child(hbox)
				if save: ProjectSettings.set(SETTING_EXCLUDE_EXT, exclude_ext)
		ExceptionType.EXCL_CONTAINING:
			if not exclude_containing.has(txt):
				exclude_containing.append(txt)
				find_node("VBoxContains").add_child(hbox)
				if save: ProjectSettings.set(SETTING_EXCLUDE_CONTAINING, exclude_containing)
	if save:
		ProjectSettings.save()
		
func _on_delete_exception(exception: int, txt: String, node: Node) -> void:
	node.queue_free()
	match exception:
		ExceptionType.IGN_FOLDER:
			if ignore_folder.has(txt): ignore_folder.erase(txt)
			ProjectSettings.set(SETTING_IGNORE_FOLDER, ignore_folder)
		ExceptionType.IGN_EXTENSION:
			if ignore_ext.has(txt): ignore_ext.erase(txt)
			ProjectSettings.set(SETTING_IGNORE_EXT, ignore_ext)
		ExceptionType.EXCL_FOLDER:
			if exclude_folder.has(txt): exclude_folder.erase(txt)
			ProjectSettings.set(SETTING_EXCLUDE_FOLDER, exclude_folder)
		ExceptionType.EXCL_EXTENSION:
			if exclude_ext.has(txt): exclude_ext.erase(txt)
			ProjectSettings.set(SETTING_EXCLUDE_EXT, exclude_ext)
		ExceptionType.EXCL_CONTAINING:
			if exclude_containing.has(txt): exclude_containing.erase(txt)
			ProjectSettings.set(SETTING_EXCLUDE_CONTAINING, exclude_containing)
	ProjectSettings.save()
		
func _on_ignore_check_button_toggled(toggled_on: bool) -> void:
	ignore_on = toggled_on
	find_node("VBoxIgnore").visible = toggled_on

func _on_button_ign_folder_pressed() -> void:
	var le = find_node("TextEditIgnFolder")
	var txt : String = le.text.strip_edges()
	if not txt.empty():
		le.text = ""
		_add_exception(txt, ExceptionType.IGN_FOLDER, true)

func _on_button_ign_ext_pressed() -> void:
	var le = find_node("TextEditIgnExt")
	var txt : String = le.text.strip_edges()
	if not txt.empty():
		le.text = ""
		_add_exception(txt, ExceptionType.IGN_EXTENSION, true)

func _on_use_multithreading_check_button_toggled(toggled_on: bool) -> void:
	use_multithreading = toggled_on
	ProjectSettings.set(SETTING_USE_MULTITHREADING, use_multithreading)
	ProjectSettings.save()

func _on_exclude_check_button_toggled(toggled_on: bool) -> void:
	find_node("VBoxExclude").visible = toggled_on

func _on_button_exclude_folder_pressed() -> void:
	var le = find_node("TextEditExcFolder")
	var txt : String = le.text.strip_edges()
	if not txt.empty():
		le.text = ""
		_add_exception(txt, ExceptionType.EXCL_FOLDER, true)

func _on_button_exclude_ext_pressed() -> void:
	var le = find_node("TextEditExcExt")
	var txt : String = le.text.strip_edges()
	if not txt.empty():
		le.text = ""
		_add_exception(txt, ExceptionType.EXCL_EXTENSION, true)

func _on_button_exclude_cont_pressed() -> void:
	var le = find_node("TextEditExcContaining")
	var txt : String = le.text.strip_edges()
	if not txt.empty():
		le.text = ""
		_add_exception(txt, ExceptionType.EXCL_CONTAINING, true)
