local config = require("tmux-agent-bridge.config")
local state = require("tmux-agent-bridge.state")
local system = require("tmux-agent-bridge.system")

local M = {}

local STASH_SESSION = "__tmux_agent_bridge_stash"
---@param keys string|string[]|nil
---@return string[]
local function normalize_keys(keys)
	if type(keys) == "string" then
		return { keys }
	end
	if type(keys) == "table" and vim.islist(keys) then
		return keys
	end
	return {}
end

---@param patterns string|string[]|nil
---@return string[]
local function normalize_patterns(patterns)
	if type(patterns) == "string" then
		return { patterns }
	end
	if type(patterns) == "table" and vim.islist(patterns) then
		return patterns
	end
	return {}
end

---@return string|nil
local function current_pane_id()
	if not system.in_tmux() then
		return nil
	end
	local pane_id = system.run({ "tmux", "display-message", "-p", "#{pane_id}" })
	if pane_id == "" then
		return nil
	end
	return pane_id
end

---@param pane_id string
---@return boolean
local function pane_exists(pane_id)
	local result = vim.system({ "tmux", "list-panes", "-t", pane_id }, { text = true }):wait()
	return result.code == 0
end

---@return string|nil
local function current_window_target()
	local target = system.run({ "tmux", "display-message", "-p", "#{session_name}:#{window_index}" })
	if target == "" then
		return nil
	end
	return target
end

---@return integer
local function current_pane_index()
	return tonumber(system.run({ "tmux", "display-message", "-p", "#{pane_index}" })) or 0
end

---@param tty string|nil
---@return string|nil
local function normalize_tty(tty)
	if not tty or tty == "" then
		return nil
	end
	return tty:gsub("^/dev/", "")
end

---@return table<string, string[]>
local function process_lines_by_tty()
	local by_tty = {}
	for _, line in ipairs(system.run_lines({ "ps", "-eo", "tty=,args=" })) do
		local tty, args = line:match("^%s*(%S+)%s+(.+)$")
		if tty and args and tty ~= "??" then
			by_tty[tty] = by_tty[tty] or {}
			table.insert(by_tty[tty], args)
		end
	end
	return by_tty
end

---@param pane table
---@param by_tty table<string, string[]>
---@return table
local function attach_process_details(pane, by_tty)
	local tty = normalize_tty(pane.tty)
	local process_lines = tty and by_tty[tty] or {}
	pane.tty = tty or ""
	pane.process_lines = process_lines or {}
	pane.process_text = table.concat(pane.process_lines, "\n")
	return pane
end

---@param line string
---@return table|nil
local function parse_pane_line(line)
	local pane_id, pane_index, current_command, title, current_path, tty =
		line:match("^(%%%d+)\t([^\t]+)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
	if not pane_id then
		return nil
	end

	return {
		pane_id = pane_id,
		pane_index = tonumber(pane_index) or 0,
		current_command = current_command or "",
		title = title or "",
		current_path = current_path or "",
		tty = tty or "",
		process_lines = {},
		process_text = "",
	}
end

---@param pane table
---@return table|nil
local function detect_agent(pane)
	local names = vim.tbl_keys(config.opts.agents or {})
	table.sort(names)

	for _, agent_name in ipairs(names) do
		local agent = config.opts.agents[agent_name]
		local detect = agent and agent.detect or nil
		local matched = false

		if type(detect) == "function" then
			local ok, result = pcall(detect, pane, agent)
			matched = ok and result == true
		elseif type(detect) == "table" then
			for _, pattern in ipairs(normalize_patterns(detect.title_patterns)) do
				if pane.title:match(pattern) then
					matched = true
					break
				end
			end
			if not matched then
				for _, pattern in ipairs(normalize_patterns(detect.command_patterns)) do
					if pane.current_command:match(pattern) then
						matched = true
						break
					end
				end
			end
			if not matched then
				for _, pattern in ipairs(normalize_patterns(detect.path_patterns)) do
					if pane.current_path:match(pattern) then
						matched = true
						break
					end
				end
			end
			if not matched then
				for _, pattern in ipairs(normalize_patterns(detect.process_patterns)) do
					if pane.process_text:match(pattern) then
						matched = true
						break
					end
				end
			end
		end

		if matched then
			pane.agent_name = agent_name
			pane.agent = agent
			return pane
		end
	end

	return nil
end

---@param pane_id string
---@param agent_name string|nil
---@return table|nil
local function pane_details(pane_id, agent_name)
	local by_tty = process_lines_by_tty()
	local line = system.run({
		"tmux",
		"display-message",
		"-p",
		"-t",
		pane_id,
		"#{pane_id}\t#{pane_index}\t#{pane_current_command}\t#{pane_title}\t#{pane_current_path}\t#{pane_tty}",
	})
	if line == "" then
		return nil
	end

	local pane = parse_pane_line(line)
	if not pane then
		return nil
	end
	pane = attach_process_details(pane, by_tty)

	if agent_name then
		pane.agent_name = agent_name
		pane.agent = config.opts.agents[agent_name]
		return pane
	end

	return detect_agent(pane)
end

---@param agent_name string|nil
---@return string|nil, string|nil
local function launch_command(agent_name)
	agent_name = agent_name or (config.opts.pane.launch and config.opts.pane.launch.agent) or nil
	local agent = agent_name and config.opts.agents[agent_name] or nil
	if not agent then
		return nil, "No launch agent configured"
	end

	local command = agent.launch_cmd
	if type(command) == "function" then
		local ok, value = pcall(command)
		if not ok then
			return nil, tostring(value)
		end
		command = value
	end

	if type(command) ~= "string" or command == "" then
		return nil, "No launch command configured for agent '" .. agent_name .. "'"
	end

	return command, nil
end

---@param agent_name string|nil
---@return string[]|nil, string|nil
local function build_split_args(agent_name)
	local launch = config.opts.pane.launch or {}
	local cmd, err = launch_command(agent_name)
	if not cmd then
		return nil, err
	end

	local args = { "tmux", "split-window" }
	local direction = launch.direction or "right"
	if direction == "right" then
		table.insert(args, "-h")
	elseif direction == "left" then
		table.insert(args, "-h")
		table.insert(args, "-b")
	elseif direction == "down" then
		table.insert(args, "-v")
	elseif direction == "up" then
		table.insert(args, "-v")
		table.insert(args, "-b")
	else
		return nil, "Invalid split direction '" .. tostring(direction) .. "'"
	end

	if launch.focus ~= true then
		table.insert(args, "-d")
	end

	if launch.size ~= nil and tostring(launch.size) ~= "" then
		table.insert(args, "-l")
		table.insert(args, tostring(launch.size))
	end

	table.insert(args, "-P")
	table.insert(args, "-F")
	table.insert(args, "#{pane_id}")
	table.insert(args, cmd)

	return args, nil
end

---@param pane_id string
---@param key string
---@return boolean, string|nil
local function send_key_to_pane(pane_id, key)
	local result = vim.system({ "tmux", "send-keys", "-t", pane_id, key }, { text = true }):wait()
	if result.code == 0 then
		return true, nil
	end
	return false, (result.stderr or "failed to send tmux key"):gsub("%s+$", "")
end

---@param pane_id string
---@param text string
---@return boolean, string|nil
local function send_literal_to_pane(pane_id, text)
	local result = vim.system({ "tmux", "send-keys", "-t", pane_id, "-l", text }, { text = true }):wait()
	if result.code == 0 then
		return true, nil
	end
	return false, (result.stderr or "failed to send tmux text"):gsub("%s+$", "")
end

---@param pane_id string
---@param text string
---@return boolean, string|nil
local function send_text_to_pane(pane_id, text)
	if text == "" then
		return true, nil
	end

	local temp_path = vim.fn.tempname()
	local ok, write_err =
		pcall(vim.fn.writefile, vim.split(text, "\n", { plain = true, trimempty = false }), temp_path, "b")
	if not ok then
		return false, tostring(write_err)
	end

	local buffer_name = "tmux-agent-bridge-paste"
	local load_result = vim.system({ "tmux", "load-buffer", "-b", buffer_name, temp_path }, { text = true }):wait()
	pcall(vim.fn.delete, temp_path)
	if load_result.code ~= 0 then
		return false, (load_result.stderr or "failed to load tmux buffer"):gsub("%s+$", "")
	end

	local paste_result = vim.system(
		{ "tmux", "paste-buffer", "-d", "-p", "-t", pane_id, "-b", buffer_name },
		{ text = true }
	)
		:wait()
	if paste_result.code ~= 0 then
		return false, (paste_result.stderr or "failed to paste tmux buffer"):gsub("%s+$", "")
	end

	return true, nil
end

---@return string|nil
function M.get_managed_pane_id()
	if not state.pane_id then
		return nil
	end
	if pane_exists(state.pane_id) then
		return state.pane_id
	end
	state.pane_id = nil
	state.agent_name = nil
	state.hidden_pane_spec = nil
	return nil
end

---@param agent_name string|nil
---@return table[]
function M.sibling_candidates(agent_name)
	if not system.in_tmux() then
		return {}
	end

	local current_pane = current_pane_id()
	local current_window = current_window_target()
	if not current_pane or not current_window then
		return {}
	end

	local candidates = {}
	local by_tty = process_lines_by_tty()
	local pane_lines = system.run_lines({
		"tmux",
		"list-panes",
		"-t",
		current_window,
		"-F",
		"#{pane_id}\t#{pane_index}\t#{pane_current_command}\t#{pane_title}\t#{pane_current_path}\t#{pane_tty}",
	})

	for _, line in ipairs(pane_lines) do
		local pane = parse_pane_line(line)
		if pane and pane.pane_id ~= current_pane then
			pane = attach_process_details(pane, by_tty)
			local detected = detect_agent(pane)
			if detected and (not agent_name or detected.agent_name == agent_name) then
				table.insert(candidates, detected)
			end
		end
	end

	local here = current_pane_index()
	table.sort(candidates, function(a, b)
		local a_dist = math.abs((a.pane_index or 0) - here)
		local b_dist = math.abs((b.pane_index or 0) - here)
		if a_dist ~= b_dist then
			return a_dist < b_dist
		end
		return (a.pane_index or 0) < (b.pane_index or 0)
	end)

	return candidates
end

---@param target table
---@return string
function M.format_target_label(target)
	local title = target.title
	if target.agent and type(target.agent.display_title) == "function" then
		local ok, value = pcall(target.agent.display_title, target)
		if ok and type(value) == "string" and value ~= "" then
			title = value
		end
	end

	local program = (target.agent and target.agent.display_name)
		or target.agent_name
		or (target.current_command ~= "" and target.current_command)
		or "agent"
	if title and title ~= "" then
		return string.format("%s | %s", program, title)
	end
	return program
end

---@param pane_id string
function M.clean_up_stash_session(pane_id)
	if pane_id and not pane_exists(pane_id) then
		state.hidden_pane_spec = nil
	end
	if state.hidden_pane_spec then
		return
	end
	vim.system({ "tmux", "kill-session", "-t", STASH_SESSION }, { text = true }):wait(1000)
end

---@param pane_id string
function M.auto_toggle(pane_id)
	if not state.hidden_pane_spec then
		local session_exists = vim.system({ "tmux", "has-session", "-t", STASH_SESSION }, { text = true }):wait().code
			== 0
		if not session_exists then
			vim.system({ "tmux", "new-session", "-d", "-s", STASH_SESSION }, { text = true }):wait()
		end

		local hidden_pane = system.run({ "tmux", "break-pane", "-d", "-P", "-s", pane_id, "-t", STASH_SESSION })
		if hidden_pane ~= "" then
			state.hidden_pane_spec = hidden_pane
		else
			system.notify("failed to hide tmux pane", vim.log.levels.ERROR)
		end
		return
	end

	local launch = config.opts.pane.launch or {}
	local args = { "tmux", "join-pane" }
	local direction = launch.direction or "right"
	if direction == "right" then
		table.insert(args, "-h")
	elseif direction == "left" then
		table.insert(args, "-h")
		table.insert(args, "-b")
	elseif direction == "down" then
		table.insert(args, "-v")
	elseif direction == "up" then
		table.insert(args, "-v")
		table.insert(args, "-b")
	end
	if launch.focus ~= true then
		table.insert(args, "-d")
	end
	if launch.size ~= nil and tostring(launch.size) ~= "" then
		table.insert(args, "-l")
		table.insert(args, tostring(launch.size))
	end
	table.insert(args, "-s")
	table.insert(args, state.hidden_pane_spec)

	local joined = vim.system(args, { text = true }):wait()
	if joined.code == 0 then
		state.hidden_pane_spec = nil
		M.clean_up_stash_session(state.pane_id)
	else
		system.notify("failed to restore tmux pane", vim.log.levels.ERROR)
	end
end

---@param agent_name string|nil
---@return table|nil
function M.open(agent_name)
	if not system.in_tmux() then
		system.notify("tmux not available", vim.log.levels.WARN)
		return nil
	end

	agent_name = agent_name or (config.opts.pane.launch and config.opts.pane.launch.agent) or nil
	local existing = M.get_managed_pane_id()
	if existing then
		if state.hidden_pane_spec then
			M.auto_toggle(existing)
		end
		return pane_details(existing, state.agent_name or agent_name)
	end

	local args, err = build_split_args(agent_name)
	if not args then
		system.notify(err or "failed to create tmux pane", vim.log.levels.ERROR)
		return nil
	end

	local pane_id = system.run(args)
	if pane_id == "" then
		system.notify("failed to create tmux pane", vim.log.levels.ERROR)
		return nil
	end

	state.pane_id = pane_id
	state.agent_name = agent_name

	local launch = config.opts.pane.launch or {}
	if launch.allow_passthrough ~= true then
		vim.system({ "tmux", "set-option", "-t", pane_id, "-p", "allow-passthrough", "off" }, { text = true }):wait()
	end

	return pane_details(pane_id, agent_name)
		or {
			pane_id = pane_id,
			pane_index = 0,
			current_command = "",
			title = "",
			current_path = "",
			agent_name = agent_name,
			agent = config.opts.agents[agent_name],
		}
end

---@param agent_name string|nil
function M.toggle(agent_name)
	local pane_id = M.get_managed_pane_id()
	local auto_close = config.opts.pane.launch and config.opts.pane.launch.auto_close == true

	if pane_id then
		if auto_close then
			vim.system({ "tmux", "kill-pane", "-t", pane_id }, { text = true }):wait()
			state.pane_id = nil
			state.agent_name = nil
			state.hidden_pane_spec = nil
		else
			M.auto_toggle(pane_id)
		end
		return
	end

	M.clean_up_stash_session(nil)
	M.open(agent_name)
end

---@param target table
---@param keys string|string[]|nil
---@return boolean, string|nil
function M.send_key_sequence(target, keys)
	for _, key in ipairs(normalize_keys(keys)) do
		local ok, err = send_key_to_pane(target.pane_id, key)
		if not ok then
			return false, err
		end
	end
	return true, nil
end

---@param target table
---@param text string
---@return boolean, string|nil
function M.send_text(target, text)
	return send_text_to_pane(target.pane_id, text)
end

---@param target table
---@param text string
---@param opts? { clear?: boolean, submit?: boolean, new?: boolean }
---@return boolean, string|nil
function M.send_message(target, text, opts)
	local agent = target.agent or config.opts.agents[target.agent_name] or {}
	opts = opts or {}
	text = text or ""

	if opts.new then
		local ok, err = M.send_key_sequence(target, agent.new_keys)
		if not ok then
			return false, err
		end
	end

	if (opts.clear or text ~= "") and agent.clear_keys then
		local ok, err = M.send_key_sequence(target, agent.clear_keys)
		if not ok then
			return false, err
		end
	end

	if text ~= "" then
		local ok, err = M.send_text(target, text)
		if not ok then
			return false, err
		end
	end

	if opts.submit then
		local ok, err = M.send_key_sequence(target, agent.submit_keys)
		if not ok then
			return false, err
		end
	end

	return true, nil
end

return M
