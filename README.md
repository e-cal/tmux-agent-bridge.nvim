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
  lazy = false, -- Start watcher/cleanup at startup.
  opts = {
    -- Pane selection and optional pane creation.
    pane = {
      launch = {
        enabled = true, -- Create an agent pane if none is found.
        agent = "opencode", -- Agent config to launch.
        direction = "right", -- Split direction for the new pane.
        size = "40%", -- tmux split size.
      },
    },

    -- Per-agent detection and key behavior.
    agents = {
      opencode = {
        display_name = "OpenCode", -- Label shown in pane pickers.
        detect = { -- configure how the plugin should detect if a pane is this agent
          title_patterns = { "^OC" }, -- Match pane titles.
          command_patterns = { "^opencode$" }, -- Match pane current command.
          process_patterns = { "opencode" }, -- Match full process list for the pane tty.
        },
        launch_cmd = "opencode", -- Command used when opening a pane.
        submit_keys = { "Enter" }, -- Keybind to send to submit the rendered prompt.
        clear_keys = { "C-k" }, -- Optional; Keybind to send to clear the chat/input before typing something new.
        new_keys = { "C-x", "n" }, -- Optional; Keybind to send to start a new chat/thread.
        display_title = function(pane)
          return pane.title:match("^OC | (.+)$") or pane.title
        end,
      },
    },

    -- Configure custom placeholder expansions available inside prompts.
    contexts = {
      ["@code"] = function(ctx)
        return ctx:this()
      end,
    },
  },
}
```

Why `lazy = false`?

- `setup()` starts the CWD watcher immediately so buffers can reload when an agent edits files on disk.
- `setup()` also registers the plugin's tmux cleanup on `VimLeavePre`.
- If the plugin is only loaded on first keypress, those background behaviors are missing until after the first use.

If you only use `tmux-agent-bridge.nvim` as an on-demand prompt sender and do not care about startup watchers or exit cleanup before first use, lazy-loading is fine.

## Placeholder Expressions

Prompts can contain placeholder expressions like `@this` or `@diff`.

- Placeholders are expanded just before the prompt is sent.
- In the ask buffer, placeholders are highlighted so you can see what will expand.
- If a placeholder returns `nil`, the original placeholder text is left in the prompt.

Built-in placeholders:

- `@this`: current selection, or the current cursor location if nothing is selected
- `@buffer`: current buffer path
- `@selection`: selected text as a fenced code block, or the current line if nothing is selected
- `@buffers`: all listed file buffers
- `@visible`: visible window ranges
- `@diagnostics`: diagnostics for the current buffer
- `@quickfix`: quickfix entries with file locations
- `@diff`: `git diff` output for the current working tree
- `@marks`: uppercase file marks
- `@grapple`: Grapple tag paths, if `grapple.nvim` is installed

Example:

```lua
require("tmux-agent-bridge").prompt("Review @selection and check related changes in @diff", { submit = true })
```

Customize placeholders with `opts.contexts`:

```lua
{
  "e-cal/tmux-agent-bridge.nvim",
  opts = {
    contexts = {
      ["@code"] = function(ctx)
        return ctx:selection()
      end,
      ["@file_and_diags"] = function(ctx)
        return table.concat(vim.tbl_filter(function(v)
          return v and v ~= ""
        end, {
          ctx:buffer(),
          ctx:diagnostics(),
        }), "\n\n")
      end,
      ["@diff"] = false, -- remove a built-in placeholder
    },
  },
}
```

Custom context functions receive a `ctx` object with these methods:

- `ctx:this()`: formatted reference to the current selection or cursor location
- `ctx:buffer()`: formatted reference to the current buffer
- `ctx:selection()`: selected text as a fenced code block with location header
- `ctx:buffers()`: comma-separated list of open file buffers
- `ctx:visible_text()`: comma-separated list of visible ranges across windows
- `ctx:diagnostics()`: formatted diagnostics for the current buffer
- `ctx:quickfix()`: formatted quickfix locations
- `ctx:git_diff()`: current `git diff` output
- `ctx:marks()`: formatted uppercase marks
- `ctx:grapple_tags()`: formatted Grapple tag paths

You can also use `ctx.buf`, `ctx.win`, `ctx.cursor`, and `ctx.range` directly if you need raw editor state.

## Keymaps

Use lazy.nvim's `keys`, or setup keymaps calling the api functions directly.

### Public API

- `require("tmux-agent-bridge").setup(opts)`
- `require("tmux-agent-bridge").ask(default, opts)`
- `require("tmux-agent-bridge").prompt(text, opts)`
- `require("tmux-agent-bridge").select()`
- `require("tmux-agent-bridge").toggle(agent_name)`
- `require("tmux-agent-bridge").send_keys(keys, opts)`

### Example Keymaps

```lua
{
  "e-cal/tmux-agent-bridge.nvim",
  keys = {
    {
      "<leader>aa",
      function()
        require("tmux-agent-bridge").ask("@buffer ", { submit = true })
      end,
      desc = "Ask agent",
    },
    {
      "<leader>an",
      function()
        require("tmux-agent-bridge").ask("@buffer ", { new = true, submit = true })
      end,
      desc = "Ask agent in new thread",
    },
    {
      "<leader>as",
      function()
        require("tmux-agent-bridge").select()
      end,
      desc = "Select prompt preset",
    },
    {
      "<leader>at",
      function()
        require("tmux-agent-bridge").toggle()
      end,
      desc = "Toggle agent pane",
    },
    {
      "<leader>ad",
      function()
        require("tmux-agent-bridge").ask("@diff ")
      end,
      desc = "Ask about git diff",
    },
    {
      "<leader>ae",
      function()
        require("tmux-agent-bridge").ask("@diagnostics ")
      end,
      desc = "Ask about diagnostics",
    },
    {
      "<leader>ac",
      function()
        require("tmux-agent-bridge").prompt(
          "Follow any instructions in the selected code and complete the functionality:\n\n@selection",
          { submit = true }
        )
      end,
      mode = "x",
      desc = "Complete selection",
    },
    {
      "<leader>ar",
      function()
        require("tmux-agent-bridge").prompt("Review @this for correctness and readability", { submit = true })
      end,
      mode = "x",
      desc = "Review selection",
    },
    {
      "<leader>at",
      function()
        require("tmux-agent-bridge").prompt("Add tests for @this", { submit = true })
      end,
      mode = "x",
      desc = "Generate tests",
    },
    {
      "<S-C-u>",
      function()
        require("tmux-agent-bridge").send_keys("PageUp", { agent = "opencode" })
      end,
      desc = "Scroll agent pane up",
    },
    {
      "<S-C-d>",
      function()
        require("tmux-agent-bridge").send_keys("PageDown", { agent = "opencode" })
      end,
      desc = "Scroll agent pane down",
    },
  },
}
```
