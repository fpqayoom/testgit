@tool
extends Control

var core: VcsCore

var rename_dialog: AcceptDialog
var rename_input: LineEdit
var selected_files: Array[String] = []
var selected_pr_number: int = -1
var is_viewing_remote: bool = false

func _ready():
	if not Engine.is_editor_hint(): return
	
	core = VcsCore.new()
	add_child(core)
	
	_setup_rename_dialog()
	
	# Setup 2-Column Tree (Checkbox + Text)
	if has_node("%FileTree"):
		%FileTree.set_column_expand(0, false)
		%FileTree.set_column_custom_minimum_width(0, 50)
	
	# Setup
	if has_node("%BtnSave"): %BtnSave.pressed.connect(_on_save)
	
	# Git Control
	if has_node("%BtnBranchCreate"): %BtnBranchCreate.pressed.connect(_on_create_branch)
	if has_node("%BtnBranchDel"): %BtnBranchDel.pressed.connect(_on_delete_branch)
	if has_node("%BtnPushProject"): %BtnPushProject.pressed.connect(_on_push_project)
	if has_node("%BtnPullProject"): %BtnPullProject.pressed.connect(_on_pull_project)
	
	# Explorer Views & Search
	if has_node("%BtnViewLocal"): %BtnViewLocal.pressed.connect(func(): is_viewing_remote = false; _populate_local_tree("res://"))
	if has_node("%BtnViewRemote"): %BtnViewRemote.pressed.connect(func(): is_viewing_remote = true; _populate_remote_tree())
	if has_node("%InSearch"): %InSearch.text_changed.connect(_on_search)
	if has_node("%FileTree"): %FileTree.item_edited.connect(_on_tree_checkbox_toggled)
	
	# Explorer Actions
	if has_node("%BtnPush"): %BtnPush.pressed.connect(_on_push_selected)
	if has_node("%BtnPull"): %BtnPull.pressed.connect(_on_pull_selected)
	if has_node("%BtnDel"): %BtnDel.pressed.connect(_on_delete_selected)
	if has_node("%BtnRename"): %BtnRename.pressed.connect(_open_rename_dialog)
	
	# Pull Requests
	if has_node("%BtnCreatePR"): %BtnCreatePR.pressed.connect(_on_create_pr)
	if has_node("%BtnFetchPRs"): %BtnFetchPRs.pressed.connect(_on_fetch_prs)
	if has_node("%BtnMergePR"): %BtnMergePR.pressed.connect(_on_merge_pr)
	if has_node("%PRList"): %PRList.item_selected.connect(_on_pr_selected)
	
	if core.db["token"] != "":
		%InToken.text = core.db["token"]
		%InOwner.text = core.db["owner"]
		%InRepo.text = core.db["repo"]
		_refresh_branches()
		_populate_local_tree("res://")

# --- UI HELPERS ---
func _set_status(msg: String, color: Color = Color.WHITE):
	if has_node("%Status"):
		%Status.text = msg
		%Status.modulate = color

func _start_task():
	if has_node("%TaskBlocker"): %TaskBlocker.show()

func _end_task():
	if has_node("%TaskBlocker"): %TaskBlocker.hide()

func _get_active_branch() -> String:
	if %BranchDrop.item_count == 0: return "main"
	return %BranchDrop.get_item_text(%BranchDrop.selected)

# --- SETUP ---
func _on_save():
	core.save_credentials(%InToken.text, %InOwner.text, %InRepo.text)
	_set_status("Connected.", Color.GREEN)
	_refresh_branches()
	_populate_local_tree("res://")

# --- GIT CONTROL (BRANCHES & PROJECT SYNC) ---
func _refresh_branches():
	_start_task()
	var res = await core.get_branches()
	if res.code == 200:
		%BranchDrop.clear()
		for b in JSON.parse_string(res.body): %BranchDrop.add_item(b["name"])
	_end_task()

func _on_create_branch():
	var nb = %InBranch.text.strip_edges()
	if nb == "": return
	_start_task()
	var res = await core.create_branch(nb, _get_active_branch())
	_set_status(res.msg, Color.GREEN if res.success else Color.RED)
	if res.success: _refresh_branches()
	_end_task()

func _on_delete_branch():
	var b = _get_active_branch()
	if b == "main": 
		_set_status("Cannot delete main branch.", Color.RED)
		return
	_start_task()
	var res = await core.delete_branch(b)
	_set_status(res.msg, Color.GREEN if res.success else Color.RED)
	if res.success: _refresh_branches()
	_end_task()

func _on_push_project():
	_start_task()
	var msg = %InProjectMsg.text if %InProjectMsg.text != "" else "Push entire project via Godot"
	var res = await core.push_whole_project(msg, _get_active_branch())
	_set_status(res.msg, Color.GREEN if res.success else Color.RED)
	_end_task()

func _on_pull_project():
	_start_task()
	var res = await core.pull_whole_project(_get_active_branch())
	_set_status(res.msg, Color.GREEN if res.success else Color.RED)
	if not is_viewing_remote: _populate_local_tree("res://")
	_end_task()

# --- EXPLORER (TREE POPULATION) ---
func _populate_local_tree(path: String, filter: String = ""):
	var tree: Tree = %FileTree
	tree.clear()
	var root = tree.create_item()
	_build_local_recursive(path, root, filter)
	%BtnViewLocal.modulate = Color(0.5, 1.0, 0.5)
	%BtnViewRemote.modulate = Color.WHITE

func _build_local_recursive(dir_path: String, parent: TreeItem, filter: String):
	var dir = DirAccess.open(dir_path)
	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name != "":
			if not core.is_ignored(file_name):
				var full_path = dir_path + "/" + file_name if dir_path != "res://" else "res://" + file_name
				if dir.current_is_dir():
					var dir_item = %FileTree.create_item(parent)
					dir_item.set_text(1, "[D] " + file_name)
					dir_item.set_metadata(1, full_path)
					_build_local_recursive(full_path, dir_item, filter)
				else:
					if filter == "" or filter.to_lower() in file_name.to_lower():
						var file_item = %FileTree.create_item(parent)
						# Col 0 = Checkbox, Col 1 = Text
						file_item.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
						file_item.set_editable(0, true)
						file_item.set_checked(0, false)
						file_item.set_text(1, file_name)
						file_item.set_metadata(1, full_path)
			file_name = dir.get_next()

func _populate_remote_tree():
	_start_task()
	%FileTree.clear()
	var res = await core.get_remote_tree(_get_active_branch())
	if res.success:
		var root = %FileTree.create_item()
		var json = JSON.parse_string(res.body)
		for item in json.get("tree", []):
			if item["type"] == "blob":
				var path = item["path"]
				var file_item = %FileTree.create_item(root)
				file_item.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
				file_item.set_editable(0, true)
				file_item.set_checked(0, false)
				file_item.set_text(1, path)
				file_item.set_metadata(1, "res://" + path)
		_set_status("Showing GitHub files on " + _get_active_branch(), Color.GREEN)
		%BtnViewRemote.modulate = Color(0.5, 1.0, 0.5)
		%BtnViewLocal.modulate = Color.WHITE
	else:
		_set_status("Failed to load remote files.", Color.RED)
	_end_task()

func _on_search(new_text: String):
	if is_viewing_remote:
		# Search not supported cleanly on remote tree without re-fetching or caching.
		_set_status("Search only works on Local View.", Color.YELLOW)
	else:
		_populate_local_tree("res://", new_text)

func _on_tree_checkbox_toggled():
	selected_files.clear()
	var root = %FileTree.get_root()
	if root: _gather_checked(root)

func _gather_checked(item: TreeItem):
	if item.get_cell_mode(0) == TreeItem.CELL_MODE_CHECK and item.is_checked(0):
		selected_files.append(item.get_metadata(1))
	var child = item.get_first_child()
	while child:
		_gather_checked(child)
		child = child.get_next()

# --- EXPLORER ACTIONS ---
func _on_push_selected():
	if selected_files.is_empty(): return
	_start_task()
	var msg = %InMsg.text if %InMsg.text != "" else "Update selected files"
	for file in selected_files:
		await core.push_file(file, msg, _get_active_branch())
	_set_status("Pushed " + str(selected_files.size()) + " files.", Color.GREEN)
	_end_task()

func _on_pull_selected():
	if selected_files.is_empty(): return
	_start_task()
	for file in selected_files:
		await core.pull_file(file, _get_active_branch())
	_set_status("Pulled " + str(selected_files.size()) + " files.", Color.GREEN)
	if not is_viewing_remote: _populate_local_tree("res://")
	_end_task()

func _on_delete_selected():
	if selected_files.is_empty(): return
	_start_task()
	var count = 0
	if is_viewing_remote:
		for path in selected_files:
			if (await core.delete_remote_file(path, _get_active_branch())).success: count += 1
		_populate_remote_tree()
	else:
		for path in selected_files:
			if core.local_delete(path): count += 1
		_populate_local_tree("res://")
	_set_status("Deleted " + str(count) + " files.", Color.GREEN)
	_end_task()

func _setup_rename_dialog():
	rename_dialog = AcceptDialog.new()
	rename_dialog.title = "Rename Local File"
	rename_dialog.dialog_text = "Enter new name/path:"
	add_child(rename_dialog)
	rename_input = LineEdit.new()
	rename_dialog.add_child(rename_input)
	rename_dialog.confirmed.connect(_execute_rename)

func _open_rename_dialog():
	if is_viewing_remote:
		_set_status("Cannot rename files while viewing Remote.", Color.RED)
		return
	if selected_files.is_empty(): return
	rename_input.text = selected_files[0]
	rename_dialog.popup_centered(Vector2(300, 100))

func _execute_rename():
	var old_path = selected_files[0]
	var new_path = rename_input.text.strip_edges()
	if core.local_rename_move(old_path, new_path):
		_set_status("Renamed successfully.", Color.GREEN)
		_populate_local_tree("res://")

# --- PULL REQUESTS ---
func _on_create_pr():
	var title = %InPrTitle.text.strip_edges()
	var head = %InPrHead.text.strip_edges()
	var base = %InPrBase.text.strip_edges()
	if title == "" or head == "" or base == "": return
	
	_start_task()
	var res = await core.create_pull_request(title, head, base)
	_set_status(res.msg, Color.GREEN if res.success else Color.RED)
	if res.success: _on_fetch_prs()
	_end_task()

func _on_fetch_prs():
	_start_task()
	var res = await core.get_pull_requests()
	if res.code == 200:
		var prs = JSON.parse_string(res.body)
		%PRList.clear()
		for pr in prs:
			%PRList.add_item("#" + str(pr["number"]) + " - " + pr["title"])
			%PRList.set_item_metadata(%PRList.item_count - 1, pr["number"])
		_set_status("Fetched " + str(prs.size()) + " PRs.", Color.GREEN)
	else:
		_set_status("Failed to fetch PRs.", Color.RED)
	_end_task()

func _on_pr_selected(index: int):
	selected_pr_number = %PRList.get_item_metadata(index)

func _on_merge_pr():
	if selected_pr_number == -1: return
	_start_task()
	var res = await core.merge_pull_request(selected_pr_number, "Merged via Godot IDE")
	_set_status(res.msg, Color.GREEN if res.success else Color.RED)
	if res.success: _on_fetch_prs()
	_end_task()
