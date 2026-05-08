@tool
class_name VcsCore extends Node

const DB_PATH = "user://xogot_vcs_secure.dat"
const ENCRYPT_KEY = "xogot_master_key_2026"
const IGNORED_EXTENSIONS = [".import", ".uid", ".log", ".tmp"]
const IGNORED_FOLDERS = [".godot", ".git"]

var db: Dictionary = {"token": "", "owner": "", "repo": ""}

func _ready():
	_load_db()

func _load_db():
	if not FileAccess.file_exists(DB_PATH): return
	var file = FileAccess.open_encrypted_with_pass(DB_PATH, FileAccess.READ, ENCRYPT_KEY)
	if file:
		var parsed = JSON.parse_string(file.get_as_text())
		if typeof(parsed) == TYPE_DICTIONARY: db = parsed
		file.close()

func save_credentials(t: String, o: String, r: String):
	db["token"] = t; db["owner"] = o; db["repo"] = r
	var file = FileAccess.open_encrypted_with_pass(DB_PATH, FileAccess.WRITE, ENCRYPT_KEY)
	if file:
		file.store_string(JSON.stringify(db))
		file.close()

func is_ignored(file_name: String) -> bool:
	for ext in IGNORED_EXTENSIONS:
		if file_name.ends_with(ext): return true
	for f in IGNORED_FOLDERS:
		if file_name == f or file_name.begins_with(f + "/"): return true
	return false

# --- API ENGINE ---
func api_request(endpoint: String, method: int, body_dict: Dictionary = {}) -> Dictionary:
	var req = HTTPRequest.new()
	add_child(req)
	var headers = [
		"Authorization: Bearer " + db["token"],
		"Accept: application/vnd.github+json",
		"X-GitHub-Api-Version: 2022-11-28",
		"User-Agent: Godot-Xogot-VCS"
	]
	var url = "https://api.github.com/repos/" + db["owner"] + "/" + db["repo"] + endpoint
	var body_str = JSON.stringify(body_dict) if body_dict.size() > 0 else ""
	
	req.request(url, headers, method, body_str)
	var response = await req.request_completed
	req.queue_free()
	await get_tree().process_frame 
	
	var body_txt = ""
	if response[3] != null and response[3].size() > 0:
		body_txt = response[3].get_string_from_utf8()
	return {"code": response[1], "body": body_txt}

# --- BRANCH MANAGEMENT ---
func get_branches() -> Dictionary:
	return await api_request("/branches", HTTPClient.METHOD_GET)

func create_branch(new_branch: String, base_branch: String) -> Dictionary:
	var ref_res = await api_request("/git/ref/heads/" + base_branch, HTTPClient.METHOD_GET)
	if ref_res.code != 200: return {"success": false, "msg": "Base branch not found"}
	var sha = JSON.parse_string(ref_res.body)["object"]["sha"]
	var res = await api_request("/git/refs", HTTPClient.METHOD_POST, {"ref": "refs/heads/" + new_branch, "sha": sha})
	return {"success": res.code == 201, "msg": "Branch created"}

func delete_branch(branch: String) -> Dictionary:
	var res = await api_request("/git/refs/heads/" + branch, HTTPClient.METHOD_DELETE)
	return {"success": res.code == 204, "msg": "Branch deleted"}

# --- WHOLE PROJECT PUSH/PULL (GIT DATA API) ---
func get_remote_tree(branch: String) -> Dictionary:
	# 1. Safely get Branch Commit SHA first to prevent GitHub 409 errors
	var ref_res = await api_request("/git/ref/heads/" + branch, HTTPClient.METHOD_GET)
	if ref_res.code != 200: return {"success": false, "msg": "Remote branch missing."}
	var commit_sha = JSON.parse_string(ref_res.body)["object"]["sha"]
	
	# 2. Get Tree using the SHA
	var tree_res = await api_request("/git/trees/" + commit_sha + "?recursive=1", HTTPClient.METHOD_GET)
	if tree_res.code == 200: return {"success": true, "body": tree_res.body}
	return {"success": false, "msg": "Failed to load remote tree."}

func push_whole_project(msg: String, branch: String) -> Dictionary:
	var ref_res = await api_request("/git/ref/heads/" + branch, HTTPClient.METHOD_GET)
	if ref_res.code != 200: return {"success": false, "msg": "Branch not found"}
	var commit_sha = JSON.parse_string(ref_res.body)["object"]["sha"]

	var commit_res = await api_request("/git/commits/" + commit_sha, HTTPClient.METHOD_GET)
	var base_tree_sha = JSON.parse_string(commit_res.body)["tree"]["sha"]

	var tree_nodes = []
	var files = _get_all_local_files("res://")
	for path in files:
		var content = Marshalls.utf8_to_base64(FileAccess.get_file_as_string(path))
		var blob_res = await api_request("/git/blobs", HTTPClient.METHOD_POST, {"content": content, "encoding": "base64"})
		if blob_res.code == 201:
			var blob_sha = JSON.parse_string(blob_res.body)["sha"]
			tree_nodes.append({
				"path": path.replace("res://", ""),
				"mode": "100644",
				"type": "blob",
				"sha": blob_sha
			})

	if tree_nodes.is_empty(): return {"success": false, "msg": "No files to push!"}

	var tree_res = await api_request("/git/trees", HTTPClient.METHOD_POST, {"base_tree": base_tree_sha, "tree": tree_nodes})
	var new_tree_sha = JSON.parse_string(tree_res.body)["sha"]

	var new_commit_res = await api_request("/git/commits", HTTPClient.METHOD_POST, {"message": msg, "tree": new_tree_sha, "parents": [commit_sha]})
	var new_commit_sha = JSON.parse_string(new_commit_res.body)["sha"]

	var update_res = await api_request("/git/refs/heads/" + branch, HTTPClient.METHOD_PATCH, {"sha": new_commit_sha})
	return {"success": update_res.code == 200, "msg": "Project Successfully Pushed!"}

func pull_whole_project(branch: String) -> Dictionary:
	var tree_res = await get_remote_tree(branch)
	if not tree_res.success: return tree_res
	
	var tree = JSON.parse_string(tree_res.body)["tree"]
	for item in tree:
		if item["type"] == "blob":
			var blob_res = await api_request("/git/blobs/" + item["sha"], HTTPClient.METHOD_GET)
			if blob_res.code == 200:
				var content = Marshalls.base64_to_utf8(JSON.parse_string(blob_res.body)["content"].replace("\n", ""))
				var local_path = "res://" + item["path"]
				DirAccess.make_dir_recursive_absolute(local_path.get_base_dir())
				var f = FileAccess.open(local_path, FileAccess.WRITE)
				f.store_string(content)
				f.close()
				
	EditorInterface.get_resource_filesystem().scan()
	return {"success": true, "msg": "Project Successfully Pulled!"}

# --- SINGLE FILE OPS ---
func push_file(local_path: String, msg: String, branch: String) -> Dictionary:
	if not FileAccess.file_exists(local_path): return {"success": false, "msg": "Missing file."}
	var gh_path = local_path.replace("res://", "")
	var b64_content = Marshalls.utf8_to_base64(FileAccess.open(local_path, FileAccess.READ).get_as_text())
	
	var get_res = await api_request("/contents/" + gh_path + "?ref=" + branch, HTTPClient.METHOD_GET)
	var payload = {"message": msg, "content": b64_content, "branch": branch}
	if get_res.code == 200: payload["sha"] = JSON.parse_string(get_res.body)["sha"]
		
	var put_res = await api_request("/contents/" + gh_path, HTTPClient.METHOD_PUT, payload)
	return {"success": put_res.code in [200, 201], "msg": "Pushed " + gh_path.get_file()}

func pull_file(local_path: String, branch: String) -> Dictionary:
	var gh_path = local_path.replace("res://", "")
	var res = await api_request("/contents/" + gh_path + "?ref=" + branch, HTTPClient.METHOD_GET)
	if res.code == 200:
		var content = Marshalls.base64_to_utf8(JSON.parse_string(res.body)["content"].replace("\n", ""))
		DirAccess.make_dir_recursive_absolute(local_path.get_base_dir())
		var f = FileAccess.open(local_path, FileAccess.WRITE)
		f.store_string(content)
		f.close()
		EditorInterface.get_resource_filesystem().scan()
		return {"success": true, "msg": "Pulled " + gh_path.get_file()}
	return {"success": false, "msg": "File not on branch."}

# --- LOCAL FILE MANAGER OPS ---
func _get_all_local_files(dir_path: String) -> Array[String]:
	var list: Array[String] = []
	var dir = DirAccess.open(dir_path)
	if dir:
		dir.list_dir_begin()
		var file = dir.get_next()
		while file != "":
			if not is_ignored(file):
				var full = dir_path + "/" + file if dir_path != "res://" else "res://" + file
				if dir.current_is_dir():
					list.append_array(_get_all_local_files(full))
				else:
					list.append(full)
			file = dir.get_next()
	return list

func local_rename_move(src: String, dest: String) -> bool:
	var dir = DirAccess.open("res://")
	return dir.rename(src, dest) == OK

func local_delete(path: String) -> bool:
	var dir = DirAccess.open("res://")
	return dir.remove(path) == OK

# --- PULL REQUESTS ---
func get_pull_requests() -> Dictionary:
	return await api_request("/pulls?state=open", HTTPClient.METHOD_GET)

func merge_pull_request(pr_number: int, commit_title: String) -> Dictionary:
	var payload = {"commit_title": commit_title, "merge_method": "merge"}
	var res = await api_request("/pulls/" + str(pr_number) + "/merge", HTTPClient.METHOD_PUT, payload)
	return {"success": res.code == 200, "msg": "PR Merged Successfully"}

