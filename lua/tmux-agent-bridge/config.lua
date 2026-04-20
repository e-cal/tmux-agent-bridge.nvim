local M = {}

---@class tmux_agent_bridge.PromptSpec
---@field prompt string
---@field ask? boolean
---@field submit? boolean
---@field new? boolean
---@field clear? boolean
---@field description? string

---@class tmux_agent_bridge.Opts
---@field debug? boolean
---@field ask? table
---@field pane? table
---@field watch? table
---@field agents? table<string, table>
---@field contexts? table<string, fun(context: tmux_agent_bridge.Context): string|nil>|table<string, false>
---@field prompts? table<string, tmux_agent_bridge.PromptSpec|false>

---@type tmux_agent_bridge.Opts
M.defaults = {
	debug = false,
	ask = {
		capture = "buffer",
		prompt = "Ask agent: ",
		buffer = {
			width_ratio = 0.7,
			height_ratio = 0.3,
			min_width = 60,
			min_height = 8,
			border = "rounded",
			title_pos = "center",
			linewrap = true,
			submit_on_write = true,
			start_insert = true,
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
			prompt = "Send to coding agent pane",
		},
		launch = {
			enabled = true,
			agent = "opencode",
			direction = "right",
			size = "40%",
			focus = false,
			allow_passthrough = false,
			auto_close = false,
			wait_ms = 1200,
		},
	},
	watch = {
		enabled = true,
		debounce_ms = 150,
		poll_interval_ms = 1000,
		recent_write_ttl_ms = 1000,
		notify = true,
		excluded_filetypes = {},
	},
	agents = {
		opencode = {
			display_name = "OpenCode",
			detect = {
				title_patterns = { "^OC" },
				command_patterns = { "^opencode$" },
				process_patterns = { "opencode" },
			},
			launch_cmd = "opencode",
			clear_keys = { "C-k" },
			new_keys = { "C-x", "n" },
			submit_keys = { "Enter" },
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
