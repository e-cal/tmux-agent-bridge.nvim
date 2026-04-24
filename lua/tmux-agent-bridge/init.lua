local config = require("tmux-agent-bridge.config")
local Context = require("tmux-agent-bridge.context")
local state = require("tmux-agent-bridge.state")
local system = require("tmux-agent-bridge.system")
local tmux = require("tmux-agent-bridge.tmux")
local ui = require("tmux-agent-bridge.ui")
local watcher = require("tmux-agent-bridge.watcher")

local M = {}

---@param opts table|nil
---@return { clear: boolean, submit: boolean, new: boolean, context: tmux_agent_bridge.Context, agent: string|nil }
local function normalize_prompt_opts(opts)
	return {
		clear = opts and opts.clear or false,
		submit = opts and opts.submit or false,
		new = opts and opts.new or false,
		context = opts and opts.context or Context.new(),
		agent = opts and opts.agent or nil,
	}
end

---@param prompt_text string
---@param opts table|nil
---@return string, table, boolean
local function resolve_prompt_spec(prompt_text, opts)
	local prompt_spec = config.opts.prompts and config.opts.prompts[prompt_text] or nil
	if not prompt_spec then
		return prompt_text, normalize_prompt_opts(opts), false
	end

	local merged = vim.tbl_deep_extend("force", vim.deepcopy(prompt_spec), opts or {})
	local normalized = normalize_prompt_opts(merged)
	return prompt_spec.prompt or prompt_text, normalized, prompt_spec.ask == true
end

---@param candidates table[]
---@param prompt string
---@param callback fun(target: table|nil)
local function select_target_by_pane_index(candidates, prompt, callback)
	local by_index = {}
	local lines = {}
	local ordered_targets = {}
	for _, candidate in ipairs(candidates) do
		local pane_index = tonumber(candidate.pane_index)
		if pane_index then
			by_index[pane_index] = candidate
			table.insert(ordered_targets, candidate)
			table.insert(lines, string.format("[%d] %s", pane_index, tmux.format_target_label(candidate)))
		end
	end

	local width = math.max(40, #prompt + 4)
	for _, line in ipairs(lines) do
		width = math.max(width, #line + 2)
	end
	width = math.min(width, math.max(1, vim.o.columns - 4))
	local height = math.min(#lines, math.max(1, vim.o.lines - 4))
	local row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
	local col = math.max(0, math.floor((vim.o.columns - width) / 2))

	local buf = vim.api.nvim_create_buf(false, true)
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
		title = " " .. prompt .. " ",
		title_pos = "center",
	})

	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.wo[win].cursorline = true

	local ns = vim.api.nvim_create_namespace("tmux-agent-bridge-pane-selector")
	for row, line in ipairs(lines) do
		local pane_index = line:match("^%[(%d+)%]")
		if pane_index then
			vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, {
				end_col = #pane_index + 2,
				hl_group = "TmuxAgentBridgePaneIndex",
			})
		end
	end

	local done = false
	local function finish(target)
		if done then
			return
		end
		done = true
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
		callback(target)
	end

	for digit = 0, 9 do
		vim.keymap.set("n", tostring(digit), function()
			local target = by_index[digit]
			if target then
				finish(target)
			end
		end, { buffer = buf, nowait = true, silent = true })
	end

	vim.keymap.set("n", "<CR>", function()
		local line = vim.api.nvim_win_get_cursor(win)[1]
		finish(ordered_targets[line])
	end, { buffer = buf, nowait = true, silent = true })
	vim.keymap.set("n", "q", function()
		finish(nil)
	end, { buffer = buf, nowait = true, silent = true })
	vim.keymap.set("n", "<Esc>", function()
		finish(nil)
	end, { buffer = buf, nowait = true, silent = true })
	vim.api.nvim_create_autocmd("WinClosed", {
		once = true,
		pattern = tostring(win),
		callback = function()
			finish(nil)
		end,
	})
end

---@param opts { agent?: string }|nil
---@param callback fun(target: table|nil)
local function resolve_target(opts, callback)
	if not system.in_tmux() then
		system.notify("tmux not available", vim.log.levels.WARN)
		callback(nil)
		return
	end

	local candidates = tmux.sibling_candidates(opts and opts.agent or nil)
	if #candidates == 0 then
		local launch = config.opts.pane.launch or {}
		if launch.enabled == false then
			system.notify("No coding agent panes found in this tmux window", vim.log.levels.WARN)
			callback(nil)
			return
		end

		local target = tmux.open((opts and opts.agent) or launch.agent)
		if not target then
			callback(nil)
			return
		end

		local wait_ms = tonumber(launch.wait_ms) or 0
		if wait_ms > 0 then
			vim.wait(wait_ms)
		end
		callback(target)
		return
	end

	if #candidates == 1 then
		callback(candidates[1])
		return
	end

	select_target_by_pane_index(
		candidates,
		(config.opts.pane.selector and config.opts.pane.selector.prompt) or "Send to coding agent pane",
		callback
	)
end

local function setup_highlights()
	vim.api.nvim_set_hl(0, "TmuxAgentBridgePlaceholder", { link = "Special" })
	vim.api.nvim_set_hl(0, "TmuxAgentBridgeContextValue", { link = "String" })
	vim.api.nvim_set_hl(0, "TmuxAgentBridgePaneIndex", { link = "Keyword" })
end

---@param prompt_text string
---@param opts? table
function M.prompt(prompt_text, opts)
	local resolved_prompt, resolved_opts, use_ask = resolve_prompt_spec(prompt_text, opts)
	if use_ask then
		return M.ask(resolved_prompt, resolved_opts)
	end

	resolve_target(resolved_opts, function(target)
		if not target then
			resolved_opts.context:resume()
			return
		end

		local rendered = resolved_opts.context:render(resolved_prompt)
		local plaintext = resolved_opts.context.plaintext(rendered.output)
		local ok, err = tmux.send_message(target, plaintext, resolved_opts)
		if not ok then
			resolved_opts.context:resume()
			system.notify(err or "failed to send message", vim.log.levels.ERROR)
			return
		end

		resolved_opts.context:clear()
	end)
end

---@param default string|nil
---@param opts? table
function M.ask(default, opts)
	opts = normalize_prompt_opts(opts)
	local ask_prompt = opts.new and "Ask agent (new):" or nil

	ui.ask(default, opts.context, ask_prompt, function(input)
		if input:sub(-2) == "\\n" then
			input = input:sub(1, -3) .. "\n"
			opts.clear = false
			opts.submit = false
		end
		M.prompt(input, opts)
	end, function()
		opts.context:resume()
	end)
end

function M.select()
	local items = {}
	for name, prompt in pairs(config.opts.prompts or {}) do
		table.insert(items, {
			name = name,
			prompt = prompt,
		})
	end
	table.sort(items, function(a, b)
		return a.name < b.name
	end)

	if #items == 0 then
		M.ask("")
		return
	end

	vim.ui.select(items, {
		prompt = "tmux-agent-bridge",
		format_item = function(item)
			local description = item.prompt.description
			if description and description ~= "" then
				return item.name .. " - " .. description
			end
			return item.name
		end,
	}, function(choice)
		if not choice then
			return
		end
		if choice.prompt.ask then
			M.ask(choice.prompt.prompt, choice.prompt)
			return
		end
		M.prompt(choice.prompt.prompt, choice.prompt)
	end)
end

---@param keys string|string[]
---@param opts? { agent?: string }
function M.send_keys(keys, opts)
	resolve_target(opts, function(target)
		if not target then
			return
		end
		local ok, err = tmux.send_key_sequence(target, keys)
		if not ok then
			system.notify(err or "failed to send keys", vim.log.levels.ERROR)
		end
	end)
end

---@param agent_name string|nil
function M.open(agent_name)
	tmux.open(agent_name)
end

---@param agent_name string|nil
function M.toggle(agent_name)
	tmux.toggle(agent_name)
end

---@param opts? tmux_agent_bridge.Opts
function M.setup(opts)
	state.opts = config.setup(opts)
	setup_highlights()
	watcher.setup()

	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = vim.api.nvim_create_augroup("TmuxAgentBridgeCleanup", { clear = true }),
		callback = function()
			watcher.stop()
			local pane_id = tmux.get_managed_pane_id()
			if
				pane_id
				and state.hidden_pane_spec
				and config.opts.pane.launch.auto_close ~= true
				and system.in_tmux()
			then
				vim.system({ "tmux", "kill-pane", "-t", pane_id }, { text = true }):wait(1000)
				tmux.clean_up_stash_session(pane_id)
				state.pane_id = nil
				state.agent_name = nil
				state.hidden_pane_spec = nil
			end
		end,
	})
end

return M
