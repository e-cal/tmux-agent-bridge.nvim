local config = require("tmux-agent-bridge.config")
local system = require("tmux-agent-bridge.system")

---@class tmux_agent_bridge.Context
---@field win integer
---@field buf integer
---@field cursor integer[]
---@field range? tmux_agent_bridge.context.Range
local Context = {}
Context.__index = Context

local ns_id = vim.api.nvim_create_namespace("TmuxAgentBridgeContext")

---@param buf number
---@return string|nil
local function get_filename(buf)
	if vim.api.nvim_get_option_value("buftype", { buf = buf }) == "" then
		local name = vim.api.nvim_buf_get_name(buf)
		if name ~= "" then
			return name
		end
	end

	return nil
end

---@return integer
local function last_used_valid_win()
	local fallback = vim.api.nvim_get_current_win()
	local last_used_win = fallback
	local latest_last_used = 0

	for _, win in ipairs(vim.api.nvim_list_wins()) do
		local buf = vim.api.nvim_win_get_buf(win)
		if get_filename(buf) then
			local last_used = vim.fn.getbufinfo(buf)[1].lastused or 0
			if last_used > latest_last_used then
				latest_last_used = last_used
				last_used_win = win
			end
		end
	end

	return last_used_win
end

---@class tmux_agent_bridge.context.Range
---@field from integer[]
---@field to integer[]
---@field kind "char"|"line"|"block"

---@param buf integer
---@return tmux_agent_bridge.context.Range|nil
local function selection(buf)
	local mode = vim.fn.mode()
	local kind = (mode == "V" and "line") or (mode == "v" and "char") or (mode == "\22" and "block")
	if not kind then
		return nil
	end

	if vim.fn.mode():match("[vV\22]") then
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<esc>", true, false, true), "x", true)
	end

	local from = vim.api.nvim_buf_get_mark(buf, "<")
	local to = vim.api.nvim_buf_get_mark(buf, ">")
	if from[1] > to[1] or (from[1] == to[1] and from[2] > to[2]) then
		from, to = to, from
	end

	return {
		from = { from[1], from[2] },
		to = { to[1], to[2] },
		kind = kind,
	}
end

---@param buf integer
---@param range tmux_agent_bridge.context.Range
local function highlight(buf, range)
	local end_row = range.to[1] - (range.kind == "line" and 0 or 1)
	local end_col = nil
	if range.kind ~= "line" then
		local line = vim.api.nvim_buf_get_lines(buf, end_row, end_row + 1, false)[1] or ""
		end_col = math.min(range.to[2] + 1, #line)
	end

	vim.api.nvim_buf_set_extmark(buf, ns_id, range.from[1] - 1, range.from[2], {
		end_row = end_row,
		end_col = end_col,
		hl_group = "Visual",
	})
end

---@type tmux_agent_bridge.Context?
Context.current = nil

---@param range? tmux_agent_bridge.context.Range
---@return tmux_agent_bridge.Context
function Context.new(range)
	local self = setmetatable({}, Context)
	self.win = last_used_valid_win()
	self.buf = vim.api.nvim_win_get_buf(self.win)
	self.cursor = vim.api.nvim_win_get_cursor(self.win)
	self.range = range or selection(self.buf)

	Context.current = self

	if self.range then
		highlight(self.buf, self.range)
	end

	return self
end

function Context:clear()
	vim.api.nvim_buf_clear_namespace(self.buf, ns_id, 0, -1)
end

function Context:resume()
	self:clear()
	if self.range ~= nil then
		vim.cmd("normal! gv")
	end
end

---@param prompt string
---@return { input: table[], output: table[] }
function Context:render(prompt)
	local contexts = config.opts.contexts or {}
	local placeholders = {}

	for placeholder, render_fn in pairs(contexts) do
		if type(render_fn) == "function" then
			placeholders[placeholder] = {
				input = function()
					return { placeholder, "TmuxAgentBridgePlaceholder" }
				end,
				output = function()
					local ok, value = pcall(render_fn, self)
					if ok and value then
						return { value, "TmuxAgentBridgeContextValue" }
					end
					return { placeholder, "TmuxAgentBridgePlaceholder" }
				end,
			}
		end
	end

	local placeholder_keys = vim.tbl_keys(placeholders)
	table.sort(placeholder_keys, function(a, b)
		return #a > #b
	end)

	local input, output = {}, {}
	local index = 1
	while index <= #prompt do
		local next_pos = #prompt + 1
		local next_placeholder = nil

		for _, placeholder in ipairs(placeholder_keys) do
			local pos = prompt:find(placeholder, index, true)
			if pos and pos < next_pos then
				next_pos = pos
				next_placeholder = placeholder
			end
		end

		local text = prompt:sub(index, next_pos - 1)
		if #text > 0 then
			table.insert(input, { text })
			table.insert(output, { text })
		end

		if next_placeholder then
			table.insert(input, placeholders[next_placeholder].input())
			table.insert(output, placeholders[next_placeholder].output())
			index = next_pos + #next_placeholder
		else
			break
		end
	end

	return {
		input = input,
		output = output,
	}
end

---@param rendered table[]
---@return string
function Context.plaintext(rendered)
	return table.concat(vim.tbl_map(function(part)
		return part[1]
	end, rendered))
end

---@param rendered table[]
---@return table[]
function Context.extmarks(rendered)
	local row = 1
	local col = 1
	local extmarks = {}

	for _, part in ipairs(rendered) do
		local part_text = part[1]
		local part_hl = part[2]
		local segments = vim.split(part_text, "\n", { plain = true })
		for i, segment in ipairs(segments) do
			if i > 1 then
				row = row + 1
				col = 1
			end
			if part_hl then
				table.insert(extmarks, {
					row = row,
					col = col - 1,
					end_col = col + #segment - 1,
					hl_group = part_hl,
				})
			end
			col = col + #segment
		end
	end

	return extmarks
end

---@param loc string|integer
---@param args? { start_line?: integer, start_col?: integer, end_line?: integer, end_col?: integer }
---@return string|nil
function Context.format(loc, args)
	assert(type(loc) ~= "string" or #loc > 0, "Filepath cannot be an empty string")

	local filepath = (type(loc) == "number" and get_filename(loc)) or (type(loc) == "string" and loc) or nil
	if not filepath then
		return nil
	end

	local result = vim.fn.fnamemodify(filepath, ":p:~")

	if args and args.start_line then
		if args.end_line and args.start_line > args.end_line then
			args.start_line, args.end_line = args.end_line, args.start_line
			if args.start_col and args.end_col then
				args.start_col, args.end_col = args.end_col, args.start_col
			end
		end

		result = result .. ":L" .. tostring(args.start_line)
		if args.start_col then
			result = result .. ":C" .. tostring(args.start_col)
		end
		if args.end_line then
			result = result .. "-L" .. tostring(args.end_line)
			if args.end_col then
				result = result .. ":C" .. tostring(args.end_col)
			end
		end
	end

	return result
end

function Context:this()
	if self.range then
		return Context.format(self.buf, {
			start_line = self.range.from[1],
			start_col = (self.range.kind ~= "line") and (self.range.from[2] + 1) or nil,
			end_line = self.range.to[1],
			end_col = (self.range.kind ~= "line") and (self.range.to[2] + 1) or nil,
		})
	end

	return Context.format(self.buf, {
		start_line = self.cursor[1],
		start_col = self.cursor[2] + 1,
	})
end

function Context:buffer()
	return Context.format(self.buf)
end

function Context:selection()
	local ref = self:this()
	local ft = vim.bo[self.buf].filetype
	local content

	if self.range then
		local from, to = self.range.from, self.range.to
		if self.range.kind == "line" then
			local lines = vim.api.nvim_buf_get_lines(self.buf, from[1] - 1, to[1], false)
			content = table.concat(lines, "\n")
		else
			local text = vim.api.nvim_buf_get_text(self.buf, from[1] - 1, from[2], to[1] - 1, to[2] + 1, {})
			content = table.concat(text, "\n")
		end
	else
		content = vim.api.nvim_buf_get_lines(self.buf, self.cursor[1] - 1, self.cursor[1], false)[1] or ""
	end

	return ref .. "\n```" .. ft .. "\n" .. content .. "\n```"
end

function Context:buffers()
	local file_list = {}
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		local path = Context.format(buf)
		if path then
			table.insert(file_list, path)
		end
	end
	if #file_list == 0 then
		return nil
	end
	return table.concat(file_list, ", ")
end

function Context:visible_text()
	local visible = {}
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		local buf = vim.api.nvim_win_get_buf(win)
		local location = Context.format(buf, {
			start_line = vim.fn.line("w0", win),
			end_line = vim.fn.line("w$", win),
		})
		if location then
			table.insert(visible, location)
		end
	end
	if #visible == 0 then
		return nil
	end
	return table.concat(visible, ", ")
end

---@param diagnostic vim.Diagnostic
---@return string
function Context.format_diagnostic(diagnostic)
	local location = Context.format(diagnostic.bufnr, {
		start_line = diagnostic.lnum + 1,
		start_col = diagnostic.col + 1,
		end_line = (diagnostic.end_lnum or diagnostic.lnum) + 1,
		end_col = (diagnostic.end_col or diagnostic.col) + 1,
	})

	return string.format(
		"%s (%s): %s",
		location,
		diagnostic.source or "unknown source",
		diagnostic.message:gsub("%s+", " "):gsub("^%s", ""):gsub("%s$", "")
	)
end

function Context:diagnostics()
	local diagnostics = vim.diagnostic.get(self.buf)
	if #diagnostics == 0 then
		return nil
	end

	local items = vim.tbl_map(function(diagnostic)
		return "- " .. Context.format_diagnostic(diagnostic)
	end, diagnostics)

	return #diagnostics .. " diagnostics:\n" .. table.concat(items, "\n")
end

function Context:quickfix()
	local qflist = vim.fn.getqflist()
	if #qflist == 0 then
		return nil
	end

	local lines = {}
	for _, entry in ipairs(qflist) do
		local has_buf = entry.bufnr ~= 0 and vim.api.nvim_buf_get_name(entry.bufnr) ~= ""
		if has_buf then
			table.insert(
				lines,
				Context.format(entry.bufnr, {
					start_line = entry.lnum,
					start_col = entry.col,
				})
			)
		end
	end

	if #lines == 0 then
		return nil
	end

	return table.concat(lines, ", ")
end

function Context:git_diff()
	local result = vim.system({ "git", "--no-pager", "diff" }, { text = true }):wait()
	if result.code == 129 then
		return nil
	end
	if result.code ~= 0 then
		system.debug("git diff failed: " .. tostring(result.stderr or ""))
		return nil
	end
	if result.stdout == "" then
		return nil
	end
	return result.stdout
end

function Context:marks()
	local marks = {}
	for _, mark in ipairs(vim.fn.getmarklist()) do
		if mark.mark:match("^'[A-Z]$") then
			table.insert(
				marks,
				Context.format(mark.pos[1], {
					start_line = mark.pos[2],
					start_col = mark.pos[3],
				})
			)
		end
	end
	if #marks == 0 then
		return nil
	end
	return table.concat(marks, ", ")
end

function Context:grapple_tags()
	local ok, grapple = pcall(require, "grapple")
	if not ok then
		return nil
	end
	local tags = grapple.tags()
	if not tags or #tags == 0 then
		return nil
	end

	local paths = {}
	for _, tag in ipairs(tags) do
		table.insert(paths, Context.format(tag.path))
	end
	return table.concat(paths, ", ")
end

return Context
