local config = require("tmux-agent-bridge.config")

local M = {}

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

---@param buf number
---@param mode_keys table<string, string[]|string>|nil
---@param callback function
local function set_mode_keymaps(buf, mode_keys, callback)
	if not mode_keys then
		return
	end
	for mode, keys in pairs(mode_keys) do
		for _, lhs in ipairs(normalize_keys(keys)) do
			vim.keymap.set(mode, lhs, callback, { buffer = buf, nowait = true, silent = true })
		end
	end
end

---@param buf number
---@param context tmux_agent_bridge.Context
---@param ns number
local function highlight_buffer(buf, context, ns)
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local text = table.concat(lines, "\n")
	local rendered = context:render(text)
	local extmarks = context.extmarks(rendered.input)

	for _, extmark in ipairs(extmarks) do
		vim.api.nvim_buf_set_extmark(buf, ns, (extmark.row or 1) - 1, extmark.col, {
			end_col = extmark.end_col,
			hl_group = extmark.hl_group,
		})
	end
end

---@param default string|nil
---@param context tmux_agent_bridge.Context
---@param ask_opts table
---@param on_submit fun(value: string)
---@param on_cancel fun()
local function buffer_input(default, context, ask_opts, on_submit, on_cancel)
	local buffer_opts = ask_opts.buffer or {}
	local width = math.max(buffer_opts.min_width or 60, math.floor(vim.o.columns * (buffer_opts.width_ratio or 0.7)))
	local height = math.max(buffer_opts.min_height or 8, math.floor(vim.o.lines * (buffer_opts.height_ratio or 0.3)))
	local row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1)
	local col = math.max(0, math.floor((vim.o.columns - width) / 2))

	local submit_on_write = buffer_opts.submit_on_write == true
	local temp_file = submit_on_write and vim.fn.tempname() or nil
	local buf = vim.api.nvim_create_buf(false, not submit_on_write)
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = buffer_opts.border or "rounded",
		title = " " .. (ask_opts.prompt or "Ask agent: ") .. " ",
		title_pos = buffer_opts.title_pos or "center",
	})

	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "tmux_agent_bridge_ask"
	vim.bo[buf].buftype = ""
	vim.bo[buf].swapfile = false

	if temp_file then
		vim.api.nvim_buf_set_name(buf, temp_file)
	end

	vim.wo[win].wrap = buffer_opts.linewrap == true
	vim.wo[win].linebreak = buffer_opts.linewrap == true

	if buffer_opts.linewrap == true then
		vim.keymap.set("n", "j", "gj", { buffer = buf, nowait = true, silent = true })
		vim.keymap.set("n", "k", "gk", { buffer = buf, nowait = true, silent = true })
		vim.keymap.set("n", "0", "g0", { buffer = buf, nowait = true, silent = true })
		vim.keymap.set("n", "^", "g^", { buffer = buf, nowait = true, silent = true })
		vim.keymap.set("n", "$", "g$", { buffer = buf, nowait = true, silent = true })
	end

	local initial = default and vim.split(default, "\n", { plain = true, trimempty = false }) or { "" }
	if #initial == 0 then
		initial = { "" }
	end

	local cursor_row = #initial
	if default and default ~= "" then
		table.insert(initial, 1, "")
		cursor_row = 1
	elseif initial[#initial] ~= "" then
		table.insert(initial, "")
	end

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, initial)
	vim.api.nvim_win_set_cursor(win, { cursor_row, 0 })

	local ns = vim.api.nvim_create_namespace("tmux-agent-bridge-ask-highlight")
	highlight_buffer(buf, context, ns)

	local done = false
	local function finish_submit()
		if done then
			return
		end
		done = true
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		local value = table.concat(lines, "\n")
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
		if temp_file then
			pcall(vim.fn.delete, temp_file)
		end
		if value == "" then
			on_cancel()
			return
		end
		on_submit(value)
	end

	local function finish_cancel()
		if done then
			return
		end
		done = true
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
		if temp_file then
			pcall(vim.fn.delete, temp_file)
		end
		on_cancel()
	end

	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		buffer = buf,
		callback = function()
			highlight_buffer(buf, context, ns)
		end,
	})

	vim.api.nvim_create_autocmd("WinClosed", {
		once = true,
		pattern = tostring(win),
		callback = finish_cancel,
	})

	if submit_on_write then
		vim.api.nvim_create_autocmd("BufWritePost", {
			buffer = buf,
			callback = finish_submit,
		})
	end

	set_mode_keymaps(buf, buffer_opts.submit_keys or { n = { "<CR>" }, i = { "<C-s>" } }, finish_submit)
	set_mode_keymaps(buf, buffer_opts.cancel_keys or { n = { "q", "<Esc>" }, i = { "<C-c>" } }, finish_cancel)

	if buffer_opts.start_insert ~= false then
		vim.cmd("startinsert")
	end
end

---@param default string|nil
---@param context tmux_agent_bridge.Context
---@param prompt_override string|nil
---@param on_submit fun(value: string)
---@param on_cancel fun()
function M.ask(default, context, prompt_override, on_submit, on_cancel)
	local ask_opts = vim.deepcopy(config.opts.ask or {})
	if prompt_override then
		ask_opts.prompt = prompt_override
	end

	if ask_opts.capture == "input" then
		vim.ui.input({
			prompt = ask_opts.prompt or "Ask agent: ",
			default = default,
		}, function(value)
			if value == nil or value == "" then
				on_cancel()
				return
			end
			on_submit(value)
		end)
		return
	end

	buffer_input(default, context, ask_opts, on_submit, on_cancel)
end

return M
