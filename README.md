# tmux-agent-bridge.nvim

General tmux bridge for sending prompts from Neovim to coding-agent TUIs running in sibling tmux panes.

Features:

- sibling-pane agent discovery via configurable pane identifiers
- prompt capture and placeholder expansion similar to `opencode.nvim`
- tmux `send-keys` routing with per-agent clear/new/submit key sequences
- optional pane creation when no agent pane is available
- built-in CWD watcher to reload buffers when external edits land on disk

Example `lazy.nvim` setup:

```lua
{
  "e-cal/tmux-agent-bridge.nvim",
  dir = "~/projects/tmux-agent-bridge.nvim",
  lazy = false,
  opts = {
    pane = {
      launch = {
        enabled = true,
        agent = "opencode",
        direction = "right",
        size = "40%",
      },
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
      ["@code"] = function(ctx)
        return ctx:this()
      end,
    },
  },
}
```

Public API:

- `require("tmux-agent-bridge").setup(opts)`
- `require("tmux-agent-bridge").ask(default, opts)`
- `require("tmux-agent-bridge").prompt(text, opts)`
- `require("tmux-agent-bridge").select()`
- `require("tmux-agent-bridge").toggle(agent_name)`
- `require("tmux-agent-bridge").send_keys(keys, opts)`
