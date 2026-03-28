tool
extends Node
class_name FileUtils

signal progress_updated(current, total, message)

var _mutex: Mutex
var _active_threads: Array = []
var _should_cancel: bool = false

func _init() -> void:
	_mutex = Mutex.new()

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_cleanup_threads()

func scan_res(
			filter_on: bool,
			search_ext: Array,
			exclude_folder: Array,
			exclude_ext: Array,
			exclude_containing: Array,
			keep_paths: Array,
			ignore_on: bool,
			ignore_folder: Array,
			ignore_ext: Array,
			use_threading: bool = true) -> Array:
	
	if use_threading:
		print("Start Multithreaded Scan...")
		return scan_res_threaded(
				filter_on,
				search_ext,
				exclude_folder,
				exclude_ext,
				exclude_containing,
				keep_paths,
				ignore_on,
				ignore_folder,
				ignore_ext
		)
	else:
		print("Start Singlethreaded Scan...")
		return scan_res_single_threaded(
				filter_on,
				search_ext,
				exclude_folder,
				exclude_ext,
				exclude_containing,
				keep_paths,
				ignore_on,
				ignore_folder,
				ignore_ext
		)

func scan_res_single_threaded(
			filter_on: bool,
			search_ext: Array,
			exclude_folder: Array,
			exclude_ext: Array,
			exclude_containing: Array,
			keep_paths: Array,
			ignore_on: bool,
			ignore_folder: Array,
			ignore_ext: Array) -> Array:
	
	emit_signal("progress_updated", 0, 100, "Scanning files (single-threaded)...")
	
	var all_files = get_all_files(
			"res://",
			exclude_folder,
			exclude_ext,
			exclude_containing)
	
	emit_signal("progress_updated", 40, 100, "Analyzing dependencies...")
	var all_dependencies = collect_all_dependencies(all_files)
	
	emit_signal("progress_updated", 80, 100, "Filtering results...")
	var no_dependency_files := []
	
	for f in all_files:
		if filter_on and not has_extension(f, search_ext):
			continue
		if keep_paths.has(f):
			continue
		if ignore_on:
			if has_folder(f, ignore_folder):
				continue
			if has_extension(f, ignore_ext):
				continue
		if not all_dependencies.has(f):
			no_dependency_files.append({
				"path": f,
				"size": get_file_size(f),
				"is_checked": false,
			})
	
	emit_signal("progress_updated", 100, 100, "Scan complete!")
	return no_dependency_files

func scan_res_threaded(
			filter_on: bool,
			search_ext: Array,
			exclude_folder: Array,
			exclude_ext: Array,
			exclude_containing: Array,
			keep_paths: Array,
			ignore_on: bool,
			ignore_folder: Array,
			ignore_ext: Array) -> Array:
		
	_should_cancel = false
	_cleanup_threads()
	
	emit_signal("progress_updated", 0, 100, "Scanning files (multi-threaded)...")
	var all_files = get_all_files(
			"res://",
			exclude_folder,
			exclude_ext,
			exclude_containing)
	
	if _should_cancel:
		return []
	
	emit_signal("progress_updated", 30, 100, "Analyzing dependencies (multi-threaded)...")
	var all_dependencies = collect_all_dependencies_threaded(all_files)
	
	if _should_cancel:
		return []
	
	emit_signal("progress_updated", 60, 100, "Filtering results...")
	var no_dependency_files = filter_files_threaded(
		all_files,
		all_dependencies,
		filter_on,
		search_ext,
		keep_paths,
		ignore_on,
		ignore_folder,
		ignore_ext)
	
	emit_signal("progress_updated", 100, 100, "Scan complete!")
	return no_dependency_files

func get_all_files(
		root: String,
		exclude_folder: Array,
		exclude_ext: Array,
		exclude_containing: Array) -> Array:
	var result := []
	var dir := Directory.new()
	if dir.open(root) != OK:
		return result
	
	dir.list_dir_begin(true, true)
	while true:
		if _should_cancel:
			break
			
		var dir_name = dir.get_next()
		if dir_name == "":
			break
			
		var full_path := root.plus_file(dir_name)

		if dir.current_is_dir():
			if not is_in_list(dir_name, exclude_folder):
				result += get_all_files(full_path, exclude_folder, exclude_ext, exclude_containing)
		elif not has_extension(dir_name, exclude_ext) and not contains_any(full_path, exclude_containing):
			result.append(full_path)
	
	dir.list_dir_end()
	return result

func _get_files_in_single_directory(
		root: String,
		exclude_ext: Array,
		exclude_containing: Array) -> Array:
	var result := []
	var dir := Directory.new()
	if dir.open(root) != OK:
		return result
	
	dir.list_dir_begin(true, true)
	while true:
		var dir_name = dir.get_next()
		if dir_name == "":
			break
		
		var full_path := root.plus_file(dir_name)
		
		if not dir.current_is_dir():
			if not has_extension(dir_name, exclude_ext) and not contains_any(full_path, exclude_containing):
				result.append(full_path)
	
	dir.list_dir_end()
	return result

func get_all_files_threaded(
		root: String,
		exclude_folder: Array,
		exclude_ext: Array,
		exclude_containing: Array) -> Array:
	
	var result := []
	var root_dirs = _get_root_directories(root, exclude_folder)
	var total_dirs = root_dirs.size()
	
	if total_dirs == 0:
		return result
	
	var threads := []
	var results := []
	var processed_dirs = 0
	
	for i in range(total_dirs):
		results.append([])
	
	var max_threads = min(OS.get_processor_count(), total_dirs)
	var dirs_per_thread = ceil(float(total_dirs) / max_threads)
	
	for thread_id in range(max_threads):
		var thread = Thread.new()
		var start_idx = thread_id * dirs_per_thread
		var end_idx = min(start_idx + dirs_per_thread, total_dirs)
		
		if start_idx < total_dirs:
			var thread_data = {
				"thread_id": thread_id,
				"start_idx": start_idx,
				"end_idx": end_idx,
				"root_dirs": root_dirs,
				"exclude_folder": exclude_folder,
				"exclude_ext": exclude_ext,
				"exclude_containing": exclude_containing,
				"results": results
			}
			
			thread.start(self, "_file_scan_worker", thread_data)
			threads.append(thread)
	
	_mutex.lock()
	for thread in threads:
		_active_threads.append(thread)
	_mutex.unlock()
	
	for i in range(threads.size()):
		var thread = threads[i]
		thread.wait_to_finish()
		
		_mutex.lock()
		processed_dirs += 1
		var progress = int((float(processed_dirs) / threads.size()) * 30)
		emit_signal("progress_updated", progress, 100, "Scanning directories... (%d/%d)" % [processed_dirs, threads.size()])
		_mutex.unlock()
	
	_mutex.lock()
	for thread in threads:
		_active_threads.erase(thread)
	_mutex.unlock()
	
	for thread_result in results:
		result += thread_result
	
	return result

func _get_root_directories(root: String, exclude_folder: Array) -> Array:
	var dirs := []
	var dir := Directory.new()
	if dir.open(root) != OK:
		return dirs
	
	dirs.append(root)
	dir.list_dir_begin(true, true)
	while true:
		var dir_name = dir.get_next()
		if dir_name == "":
			break
		if dir.current_is_dir() and not is_in_list(dir_name, exclude_folder):
			dirs.append(root.plus_file(dir_name))
	dir.list_dir_end()
	return dirs

func _file_scan_worker(data: Dictionary) -> void:
	var thread_id = data.thread_id
	var start_idx = data.start_idx
	var end_idx = data.end_idx
	var root_dirs = data.root_dirs
	var exclude_ext = data.exclude_ext
	var exclude_containing = data.exclude_containing
	var results = data.results
	var thread_result := []
	
	for i in range(start_idx, end_idx):
		if _should_cancel:
			break
			
		var dir_path = root_dirs[i]
		var dir_files = _get_files_in_single_directory(dir_path, exclude_ext, exclude_containing)
		thread_result += dir_files
	
	_mutex.lock()
	results[thread_id] = thread_result
	_mutex.unlock()

func contains_any(target: String, list: Array) -> bool:
	for sub in list:
		if target.find(sub) != -1:
			return true
	return false

func is_in_list(target: String, list: Array) -> bool:
	for item in list:
		if target == item:
			return true
	return false

func has_extension(path: String, list: Array) -> bool:
	for ext in list:
		if path.ends_with(ext):
			return true
	return false

func has_folder(path: String, list: Array) -> bool:
	var segments = path.replace("res://", "").split("/")
	for folder in list:
		if folder in segments:
			return true
	return false

func collect_all_dependencies(paths: Array) -> Array:
	var all_deps := []
	for p in paths:
		var deps = ResourceLoader.get_dependencies(p)
		for d in deps:
			# Godot 3 returns simple paths, no "::" parsing needed.
			if !all_deps.has(d):
				all_deps.append(d)
	return all_deps

func collect_all_dependencies_threaded(paths: Array) -> Array:
	var all_deps := []
	var total_files = paths.size()
	
	if total_files == 0:
		return all_deps
	
	var threads := []
	var results := []
	var processed_files = 0
	
	var max_threads = min(OS.get_processor_count(), total_files)
	var files_per_thread = ceil(float(total_files) / max_threads)
	
	for i in range(max_threads):
		results.append([])
	
	for thread_id in range(max_threads):
		var thread = Thread.new()
		var start_idx = thread_id * files_per_thread
		var end_idx = min(start_idx + files_per_thread, total_files)
		
		if start_idx < total_files:
			var thread_data = {
				"thread_id": thread_id,
				"start_idx": start_idx,
				"end_idx": end_idx,
				"paths": paths,
				"results": results
			}
			
			thread.start(self, "_dependency_worker", thread_data)
			threads.append(thread)
	
	_mutex.lock()
	for thread in threads:
		_active_threads.append(thread)
	_mutex.unlock()
	
	for i in range(threads.size()):
		var thread = threads[i]
		thread.wait_to_finish()
		
		_mutex.lock()
		processed_files += files_per_thread
		var progress = 30 + int((float(min(processed_files, total_files)) / total_files) * 30)
		emit_signal("progress_updated", progress, 100, "Analyzing dependencies... (%d/%d)" % [min(processed_files, total_files), total_files])
		_mutex.unlock()
	
	_mutex.lock()
	for thread in threads:
		_active_threads.erase(thread)
	_mutex.unlock()
	
	var deps_set := {}
	for thread_result in results:
		for dep in thread_result:
			deps_set[dep] = true
	
	return deps_set.keys()

func _dependency_worker(data: Dictionary) -> void:
	var thread_id = data.thread_id
	var start_idx = data.start_idx
	var end_idx = data.end_idx
	var paths = data.paths
	var results = data.results
	var thread_deps := []
	
	for i in range(start_idx, end_idx):
		if _should_cancel:
			break
			
		var p = paths[i]
		var deps = ResourceLoader.get_dependencies(p)
		for d in deps:
			if not thread_deps.has(d):
				thread_deps.append(d)
	
	_mutex.lock()
	results[thread_id] = thread_deps
	_mutex.unlock()

func filter_files_threaded(
		all_files: Array,
		all_dependencies: Array,
		filter_on: bool,
		search_ext: Array,
		keep_paths: Array,
		ignore_on: bool,
		ignore_folder: Array,
		ignore_ext: Array) -> Array:
	
	var no_dependency_files := []
	var total_files = all_files.size()
	var processed_files = 0
	
	for i in range(total_files):
		if _should_cancel:
			break
			
		var f = all_files[i]
		if filter_on and not has_extension(f, search_ext):
			continue
		if keep_paths.has(f):
			continue
		if ignore_on:
			if has_folder(f, ignore_folder):
				continue
			if has_extension(f, ignore_ext):
				continue
		if not all_dependencies.has(f):
			no_dependency_files.append({
				"path": f,
				"size": get_file_size(f),
				"is_checked": false,
			})
		
		processed_files += 1
		if processed_files % 50 == 0:
			var progress = 60 + int((float(processed_files) / total_files) * 40)
			emit_signal("progress_updated", progress, 100, "Filtering results... (%d/%d)" % [processed_files, total_files])
	
	return no_dependency_files

func cancel_scan() -> void:
	_should_cancel = true
	_cleanup_threads()

func _cleanup_threads() -> void:
	if not _mutex:
		return
		
	var threads_to_wait : Array
	_mutex.lock()
	threads_to_wait = _active_threads.duplicate()
	_active_threads.clear()
	_mutex.unlock()
	
	for thread in threads_to_wait:
		if thread and thread is Thread:
			if thread.is_active():
				thread.wait_to_finish()
	
	_mutex.lock()
	_active_threads.clear()
	_mutex.unlock()


class FileSorter:
	static func sort_size_asc(a, b):
		if a.size == b.size: return a.path < b.path
		return a.size < b.size
	static func sort_size_desc(a, b):
		if a.size == b.size: return a.path < b.path
		return a.size > b.size
	static func sort_path_asc(a, b):
		return a.path < b.path
	static func sort_path_desc(a, b):
		return a.path > b.path

func sorting(no_dependency_files: Array, sort_type: int) -> void:
	if no_dependency_files.empty():
		return
		
	match sort_type:
		0: # NONE:
			pass
		1: # SIZE_ASC
			no_dependency_files.sort_custom(FileSorter, "sort_size_asc")
		2: # SIZE_DESC
			no_dependency_files.sort_custom(FileSorter, "sort_size_desc")
		3: # PATH_ASC
			no_dependency_files.sort_custom(FileSorter, "sort_path_asc")
		4: # PATH_DESC
			no_dependency_files.sort_custom(FileSorter, "sort_path_desc")

func delete_selected(no_dependency_files: Array) -> void:
	var dir = Directory.new()
	if dir.open("res://") != OK:
		return
		
	var deleted_count := 0
	var space_freed := 0
	
	for ndf in no_dependency_files:
		if ndf.is_checked:
			var path = ndf.path
			if dir.file_exists(path):
				var err = dir.remove(path)
				if err == OK:
					deleted_count += 1
					space_freed += ndf.size
					print("File deleted: ", path)
					
					var import_path = path + ".import"
					if dir.file_exists(import_path):
						var import_err = dir.remove(import_path)
						if import_err == OK:
							print("Associated .import file deleted: ", import_path)
						else:
							print("Failed to delete .import file: ", import_path)
				else:
					print("Failed to delete File: ", path)
					
	print("Deleted %d unused files, freed %s" % [deleted_count, format_file_size(space_freed)])

func clean_import(root: String, exclude_folder: Array) -> void:
	var deleted_count := [0]
	_clean_orphaned_files(root, ".import", exclude_folder, deleted_count)
	print("Deleted %d orphaned .import files" % deleted_count[0])

func _clean_orphaned_files(root: String, extension: String, exclude_folder: Array, count: Array) -> void:
	var dir := Directory.new()
	if dir.open(root) != OK:
		return
		
	dir.list_dir_begin(true, true)
	while true:
		var dir_name = dir.get_next()
		if dir_name == "":
			break
		
		var path = root.plus_file(dir_name)
		
		if dir.current_is_dir():
			if not is_in_list(dir_name, exclude_folder):
				_clean_orphaned_files(path, extension, exclude_folder, count)
		elif dir_name.ends_with(extension):
			var source_path = path.replace(extension, "")
			var f = File.new()
			if not f.file_exists(source_path):
				var err = dir.remove(path)
				if err == OK:
					count[0] += 1
					print("Deleted:", path)
				else:
					print("Failed to delete:", path)
	dir.list_dir_end()

func clean_empty_folders(root: String, exclude_folder: Array) -> void:
	var deleted_count := [0]
	_remove_empty_dirs(root, exclude_folder, deleted_count)
	print("Deleted %d empty folders" % deleted_count[0])

func _remove_empty_dirs(root: String, exclude_folder: Array, deleted_count: Array) -> bool:
	var dir := Directory.new()
	if dir.open(root) != OK:
		return false

	var is_empty := true
	dir.list_dir_begin(true, true)
	while true:
		var dir_name = dir.get_next()
		if dir_name == "":
			break
			
		var path = root.plus_file(dir_name)
		
		if dir.current_is_dir():
			if not is_in_list(dir_name, exclude_folder):
				if not _remove_empty_dirs(path, exclude_folder, deleted_count):
					is_empty = false
		else:
			is_empty = false
	dir.list_dir_end()

	if is_empty:
		var parent_dir := Directory.new()
		if parent_dir.open(root.get_base_dir()) == OK:
			if parent_dir.remove(root) == OK:
				deleted_count[0] += 1
				print("Deleted empty folder:", root)
		return true
	return false

func get_file_size(path: String) -> int:
	var f = File.new()
	if f.file_exists(path):
		if f.open(path, File.READ) == OK:
			var size = f.get_len()
			f.close()
			return size
	return 0

func format_file_size(bytes: int) -> String:
	if bytes >= 1073741824:
		return "%.1f GB" % (bytes / 1073741824.0)
	elif bytes >= 1048576:
		return "%.1f MB" % (bytes / 1048576.0)
	elif bytes >= 1024:
		return "%.1f KB" % (bytes / 1024.0)
	else:
		return "%d B" % bytes