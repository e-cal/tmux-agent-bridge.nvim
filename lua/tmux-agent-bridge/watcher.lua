local config = require("tmux-agent-bridge.config")
local system = require("tmux-agent-bridge.system")

local M = {}

local watcher_state = {
	group = nil,
	debounce_timer = nil,
	poll_timer = nil,
	paths = {},
	recent_writes = {},
	mtimes = {},
	root = nil,
	watcher = nil,
}

local function watch_opts()
	return config.opts.watch or {}
end

local function stop_timer()
	if watcher_state.debounce_timer then
		watcher_state.debounce_timer:stop()
		watcher_state.debounce_timer:close()
		watcher_state.debounce_timer = nil
	end
end

local function stop_poll_timer()
	if watcher_state.poll_timer then
		watcher_state.poll_timer:stop()
		watcher_state.poll_timer:close()
		watcher_state.poll_timer = nil
	end
end

local function stop_watcher()
	stop_timer()
	stop_poll_timer()
	if watcher_state.watcher then
		watcher_state.watcher:stop()
		watcher_state.watcher:close()
		watcher_state.watcher = nil
	end
	watcher_state.paths = {}
	watcher_state.recent_writes = {}
	watcher_state.mtimes = {}
	watcher_state.root = nil
end

---@param path string
---@return string|nil
local function mtime_key(path)
	local stat = vim.uv.fs_stat(path)
	if not stat or not stat.mtime then
		return nil
	end
	return string.format("%s:%s", tostring(stat.mtime.sec or 0), tostring(stat.mtime.nsec or 0))
end

---@param path string|nil
---@param root string|nil
---@return boolean
local function path_in_root(path, root)
	if not path or not root then
		return false
	end
	if path == root then
		return true
	end
	return path:sub(1, #root + 1) == root .. "/"
end

---@param path string
---@return string
local function display_path(path)
	local display = vim.fn.fnamemodify(path, ":~:.")
	return display:gsub("^%./", "")
end

---@param bufnr integer
---@param force_refresh? boolean
---@return string|nil
local function track_buffer(bufnr, force_refresh)
	if not vim.api.nvim_buf_is_loaded(bufnr) or vim.bo[bufnr].buftype ~= "" then
		return nil
	end

	local filetype = vim.bo[bufnr].filetype
	if (watch_opts().excluded_filetypes or {})[filetype] then
		return nil
	end

	local name = system.canonical_path(vim.api.nvim_buf_get_name(bufnr))
	if not name or not path_in_root(name, watcher_state.root) then
		return nil
	end

	local key = mtime_key(name)
	if key and (force_refresh or watcher_state.mtimes[name] == nil) then
		watcher_state.mtimes[name] = key
	end
	return name
end

local function notify_reload(path)
	if watch_opts().notify == false then
		return
	end
		vim.notify("Reloading " .. display_path(path), vim.log.levels.INFO, { title = "tmux-agent-bridge" })
end

---@param path string|nil
local function mark_recent_write(path)
	if not path or path == "" then
		return
	end

	local full_path = system.canonical_path(path)
	if not full_path then
		return
	end

	local now = vim.uv.now()
	watcher_state.recent_writes[full_path] = now

	for tracked_path, ts in pairs(watcher_state.recent_writes) do
		if now - ts > (watch_opts().recent_write_ttl_ms or 1000) then
			watcher_state.recent_writes[tracked_path] = nil
		end
	end
end

---@param path string
---@return boolean
local function was_recently_written(path)
	local ts = watcher_state.recent_writes[path]
	if not ts then
		return false
	end

	if vim.uv.now() - ts > (watch_opts().recent_write_ttl_ms or 1000) then
		watcher_state.recent_writes[path] = nil
		return false
	end

	return true
end

---@param changed_paths table<string, boolean>|nil
local function reload_buffers(changed_paths)
	local root = watcher_state.root
	if not root then
		return
	end

	local reload_all = changed_paths == nil or vim.tbl_isempty(changed_paths)
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].buftype == "" then
			local filetype = vim.bo[bufnr].filetype
			if not (watch_opts().excluded_filetypes or {})[filetype] then
				local name = system.canonical_path(vim.api.nvim_buf_get_name(bufnr))
				if name and path_in_root(name, root) then
					if not was_recently_written(name) and (reload_all or changed_paths[name]) then
						if vim.fn.filereadable(name) == 1 and not vim.bo[bufnr].modified then
							vim.cmd("silent! checktime " .. bufnr)
							track_buffer(bufnr)
						end
					end
				end
			end
		end
	end
end

local function poll_for_changes()
	local root = watcher_state.root
	if not root then
		return
	end

	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		local name = track_buffer(bufnr, false)
		if
			name
			and vim.fn.filereadable(name) == 1
			and not vim.bo[bufnr].modified
			and not was_recently_written(name)
		then
			local current_key = mtime_key(name)
			local previous_key = watcher_state.mtimes[name]
			if current_key and previous_key and current_key ~= previous_key then
				vim.cmd("silent! checktime " .. bufnr)
				watcher_state.mtimes[name] = current_key
			elseif current_key then
				watcher_state.mtimes[name] = current_key
			end
		end
	end
end

local function start_poll_timer()
	stop_poll_timer()
	watcher_state.poll_timer = vim.uv.new_timer()
	watcher_state.poll_timer:start(
		0,
		tonumber(watch_opts().poll_interval_ms) or 1000,
		vim.schedule_wrap(function()
			poll_for_changes()
		end)
	)
end

---@param changed_path string|nil
local function schedule_reload(changed_path)
	if changed_path and changed_path ~= "" and watcher_state.root then
		local full_path = changed_path
		if changed_path:sub(1, 1) ~= "/" then
			full_path = watcher_state.root .. "/" .. changed_path
		end
		full_path = system.canonical_path(full_path)
		if full_path then
			watcher_state.paths[full_path] = true
		end
	end

	stop_timer()
	watcher_state.debounce_timer = vim.uv.new_timer()
	watcher_state.debounce_timer:start(
		watch_opts().debounce_ms or 150,
		0,
		vim.schedule_wrap(function()
			local changed_paths = next(watcher_state.paths) and vim.deepcopy(watcher_state.paths) or nil
			watcher_state.paths = {}
			reload_buffers(changed_paths)
			stop_timer()
		end)
	)
end

---@param root string
local function start_watcher(root)
	root = system.canonical_path(root)
	if not root or root == watcher_state.root then
		return
	end

	stop_watcher()

	local watcher = vim.uv.new_fs_event()
	local ok, err = pcall(function()
		watcher:start(
			root,
			{ recursive = true },
			vim.schedule_wrap(function(watch_err, changed_path)
				if watch_err then
					vim.notify(
				"tmux-agent-bridge watch: " .. tostring(watch_err),
						vim.log.levels.WARN,
				{ title = "tmux-agent-bridge" }
					)
					return
				end
				schedule_reload(changed_path)
			end)
		)
	end)

	if not ok then
		watcher:close()
			vim.notify("tmux-agent-bridge watch: failed to watch " .. root .. ": " .. tostring(err), vim.log.levels.ERROR, {
				title = "tmux-agent-bridge",
			})
		return
	end

	watcher_state.root = root
	watcher_state.watcher = watcher
	vim.o.autoread = true
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		track_buffer(bufnr, true)
	end
end

function M.stop()
	stop_watcher()
end

function M.setup()
	stop_watcher()
	if watch_opts().enabled == false then
		return
	end

	watcher_state.group = vim.api.nvim_create_augroup("TmuxAgentBridgeWatch", { clear = true })
	vim.o.autoread = true
	start_watcher(vim.fn.getcwd())
	start_poll_timer()

	vim.api.nvim_create_autocmd({ "VimEnter", "DirChanged" }, {
		group = watcher_state.group,
		callback = function()
			start_watcher(vim.fn.getcwd())
		end,
	})

	vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter", "CursorHold", "CursorHoldI" }, {
		group = watcher_state.group,
		callback = function()
			poll_for_changes()
			vim.cmd("silent! checktime")
		end,
	})

	vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost", "FileChangedShellPost" }, {
		group = watcher_state.group,
		callback = function(args)
			if args.buf and vim.api.nvim_buf_is_valid(args.buf) then
				local name = track_buffer(args.buf, true)
				if args.event == "FileChangedShellPost" and name then
					notify_reload(name)
				end
			end
		end,
	})

	vim.api.nvim_create_autocmd({ "BufWritePre", "BufWritePost" }, {
		group = watcher_state.group,
		callback = function(args)
			mark_recent_write(args.file)
		end,
	})

	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = watcher_state.group,
		callback = function()
			stop_watcher()
		end,
	})
end

return M
