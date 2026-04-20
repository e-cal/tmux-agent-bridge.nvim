local config = require("tmux-agent-bridge.config")

local M = {
	opts = vim.deepcopy(config.defaults),
	pane_id = nil,
	agent_name = nil,
	hidden_pane_spec = nil,
}

return M
