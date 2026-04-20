local M = {}

---@class tmux_agent_bridge.PromptSpec
---@field prompt string # Prompt text with placeholders like @this.
---@field ask? boolean # Open the ask UI before sending.
---@field submit? boolean # Press the agent's submit keys after sending.
---@field new? boolean # Start a new agent thread/chat first.
---@field clear? boolean # Clear existing input before sending.
---@field description? string # Label shown in prompt pickers.

---@class tmux_agent_bridge.Opts
---@field debug? boolean # Enable debug logging.
---@field ask? table # Prompt capture UI options.
---@field pane? table # Pane selection and launch options.
---@field watch? table # External file change reload behavior.
---@field agents? table<string, table> # Agent detection and key mappings.
---@field contexts? table<string, fun(context: tmux_agent_bridge.Context): string|nil>|table<string, false> # Placeholder renderers.
---@field prompts? table<string, tmux_agent_bridge.PromptSpec|false> # Named prompt presets.

---@type tmux_agent_bridge.Opts
M.defaults = {
	debug = false, -- Log tmux/system details to /tmp for troubleshooting.
	ask = {
		capture = "buffer", -- "buffer" or "input".
		prompt = "Ask agent: ", -- Default ask prompt label.
		buffer = {
			width_ratio = 0.7, -- Width as a fraction of the editor.
			height_ratio = 0.3, -- Height as a fraction of the editor.
			min_width = 60, -- Minimum ask buffer width.
			min_height = 8, -- Minimum ask buffer height.
			border = "rounded", -- Floating window border style.
			title_pos = "center", -- Floating title alignment.
			linewrap = true, -- Wrap long lines in the ask buffer.
			submit_on_write = true, -- `:write` submits the prompt.
			start_insert = true, -- Enter insert mode when opening ask UI.
			submit_keys = {
				n = { "<CR>" },
				i = { "<C-s>" },
			},
			cancel_keys = {
				n = { "q", "<Esc>" },
				i = { "<C-c>" },
			},
		},
	},
	pane = {
		selector = {
			prompt = "Send to coding agent pane", -- Pane picker title.
		},
		launch = {
			enabled = true, -- Open a pane when none matches.
			agent = "opencode", -- Agent config to launch by default.
			direction = "right", -- right, left, up, or down.
			size = "40%", -- tmux split size.
			focus = false, -- Focus the new pane after opening it.
			allow_passthrough = false, -- Reuse non-agent panes when launching.
			auto_close = false, -- Keep managed pane open on Vim exit.
			wait_ms = 1200, -- Delay before sending to a newly opened pane.
		},
	},
	watch = {
		enabled = true, -- Watch cwd for external file edits.
		debounce_ms = 150, -- Batch rapid watcher events.
		poll_interval_ms = 1000, -- Fallback polling interval.
		recent_write_ttl_ms = 1000, -- Ignore our own recent writes briefly.
		notify = true, -- Notify when a buffer reloads from disk.
		excluded_filetypes = {}, -- Filetypes to never auto-reload.
	},
	agents = {
		opencode = {
			display_name = "OpenCode", -- Label shown in selectors.
			detect = {
				title_patterns = { "^OC" }, -- Match pane_title.
				command_patterns = { "^opencode$" }, -- Match pane_current_command.
				process_patterns = { "opencode" }, -- Match processes on the pane tty.
			},
			launch_cmd = "opencode", -- Shell command used to open the agent.
			clear_keys = { "C-k" }, -- Clear current input.
			new_keys = { "C-x", "n" }, -- Start a new chat/thread.
			submit_keys = { "Enter" }, -- Submit the pasted prompt.
			display_title = function(pane)
				return pane.title:match("^OC | (.+)$") or pane.title
			end,
		},
	},
	contexts = {
		["@this"] = function(context)
			return context:this()
		end,
		["@buffer"] = function(context)
			return context:buffer()
		end,
		["@selection"] = function(context)
			return context:selection()
		end,
		["@buffers"] = function(context)
			return context:buffers()
		end,
		["@visible"] = function(context)
			return context:visible_text()
		end,
		["@diagnostics"] = function(context)
			return context:diagnostics()
		end,
		["@quickfix"] = function(context)
			return context:quickfix()
		end,
		["@diff"] = function(context)
			return context:git_diff()
		end,
		["@marks"] = function(context)
			return context:marks()
		end,
		["@grapple"] = function(context)
			return context:grapple_tags()
		end,
	},
	prompts = {
		ask = {
			prompt = "",
			ask = true,
			submit = true,
			description = "Ask the agent",
		},
		diagnostics = {
			prompt = "Explain @diagnostics",
			submit = true,
			description = "Explain diagnostics",
		},
		diff = {
			prompt = "Review the following git diff for correctness and readability: @diff",
			submit = true,
			description = "Review git diff",
		},
		document = {
			prompt = "Add comments documenting @this",
			submit = true,
			description = "Document code",
		},
		explain = {
			prompt = "Explain @this and its context",
			submit = true,
			description = "Explain code",
		},
		fix = {
			prompt = "Fix @diagnostics",
			submit = true,
			description = "Fix diagnostics",
		},
		implement = {
			prompt = "Implement @this",
			submit = true,
			description = "Implement code",
		},
		optimize = {
			prompt = "Optimize @this for performance and readability",
			submit = true,
			description = "Optimize code",
		},
		review = {
			prompt = "Review @this for correctness and readability",
			submit = true,
			description = "Review code",
		},
		test = {
			prompt = "Add tests for @this",
			submit = true,
			description = "Generate tests",
		},
	},
}

---@type tmux_agent_bridge.Opts
M.opts = vim.deepcopy(M.defaults)

---@param opts? tmux_agent_bridge.Opts
---@return tmux_agent_bridge.Opts
function M.setup(opts)
	M.opts = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})

	local user_opts = opts or {}
	for _, field in ipairs({ "contexts", "prompts" }) do
		if type(user_opts[field]) == "table" and type(M.opts[field]) == "table" then
			for key, value in pairs(user_opts[field]) do
				if value == false then
					M.opts[field][key] = nil
				end
			end
		end
	end

	return M.opts
end

return M
