local M = {}

local DEBUG_LOG_PATH = "/tmp/tmux-agent-bridge-debug.log"

---@return boolean
local function debug_enabled()
	local ok, state = pcall(require, "tmux-agent-bridge.state")
	return ok and state.opts and state.opts.debug == true
end

---@param message string
local function append_debug_line(message)
	if not debug_enabled() then
		return
	end

	local line = os.date("%Y-%m-%d %H:%M:%S") .. " " .. message
	pcall(vim.fn.writefile, { line }, DEBUG_LOG_PATH, "a")
end

---@return boolean
function M.in_tmux()
	return vim.fn.executable("tmux") == 1 and vim.env.TMUX ~= nil
end

---@param cmd string[]
---@return string
function M.run(cmd)
	local result = vim.system(cmd, { text = true }):wait()
	if result.code ~= 0 then
		append_debug_line("command failed: " .. vim.inspect(cmd) .. " stderr=" .. tostring(result.stderr or ""))
		return ""
	end
	local stdout = (result.stdout or ""):gsub("%s+$", "")
	return stdout
end

---@param cmd string[]
---@return string[]
function M.run_lines(cmd)
	local output = M.run(cmd)
	if output == "" then
		return {}
	end
	return vim.split(output, "\n", { plain = true, trimempty = true })
end

---@param message string
---@param level? integer
function M.notify(message, level)
	vim.notify("tmux-agent-bridge: " .. message, level or vim.log.levels.INFO, { title = "tmux-agent-bridge" })
end

---@param message string
function M.debug(message)
	append_debug_line(message)
end

---@param path string|nil
---@return string|nil
function M.normalize_path(path)
	if not path or path == "" then
		return nil
	end
	if vim.fs and vim.fs.normalize then
		return vim.fs.normalize(path)
	end
	return vim.fn.fnamemodify(path, ":p")
end

---@param path string|nil
---@return string|nil
function M.canonical_path(path)
	local normalized = M.normalize_path(path)
	if not normalized then
		return nil
	end
	local real = vim.uv.fs_realpath(normalized)
	return real or normalized
end

---@return string
function M.debug_log_path()
	return DEBUG_LOG_PATH
end

return M
