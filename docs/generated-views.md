# Generated views (Lua API for other plugins)

mdview normally previews a buffer that holds a Markdown file. A **generated
view** is the other case: a plugin keeps a scratch buffer (`buftype=nofile`,
any filetype) and produces the Markdown the browser shows on demand, from a
callback. The buffer text and the preview are independent: the buffer can hold a
log, a table, anything, and the browser shows what the callback returns.

The first user is casedesk.nvim's log reading copy: the browser view follows the
filter and the folds of the copy in Neovim.

## The contract

```lua
local mdview = require("mdview")

mdview.open({
  bufnr = buf,                              -- default: the current buffer
  name = "caselog://case-123/app.log.md",   -- the view's room, becomes the buffer name
  render = function(bufnr)                  -- required: Markdown lines for the browser
    return { "# app.log", "", "- [12:00:02 ERROR boom](entry/2)" }
  end,
  on_click = function(target, ctx)          -- optional: a clicked relative link
    -- target = "entry/2", ctx = { bufnr = buf, name = "caselog://case-123/app.log.md" }
  end,
})

mdview.refresh(buf)                         -- push a new rendering now
```

| Field | Meaning |
| --- | --- |
| `bufnr` | The buffer of the view. Any `buftype`, `nofile` included; it stays as it is. |
| `name` | The view's room and the document name the browser sees. Set as the buffer name when given and different; without it the buffer must already have a name. **Must end in `.md`, `.markdown` or `.mdx`**: the browser decides by the extension whether it renders Markdown or a code view. A scheme (`myplugin://…`) keeps it apart from every file path. Two views cannot share a name. |
| `render(bufnr)` | Returns the Markdown as a list of strings. Called on every push, so keep it cheap or cache inside. |
| `on_click(target, ctx)` | Optional. Receives a link the person clicked in the view. |

`open` returns `true` on success. A bad contract (no `render`, a name without a
Markdown extension, a name another view has) is reported and returns `false`;
`name` or `on_click` without `render` is refused as well.

## What mdview does with it

- **Session.** With a running session (`:MDView start`), `open` points the
  preview at the view and opens a browser tab, like `:MDView open`. Without one,
  and the view is the current buffer, `open` starts the session for it. Without
  one for a buffer in the background, `open` registers the view and says that no
  session runs; the next `:MDView start` from that buffer shows it.
- **Idempotent `open`.** `open` of a view asks the relay which rooms have a tab
  and opens a further one only when it has to, so an owner may simply call
  `open` whenever it wants "show this view": with `browser.behavior = "reuse"`
  (the default) and the one tab open, the view is pushed into that tab, even
  when it shows another document right now (and also when the view is not the
  current buffer: an explicit `open` is a request to show it); with one tab per
  document, a tab that already watches the view's room is only brought up to
  date. No tab, or a relay that does not answer, opens one as before. Because
  the relay is asked, `open` returns `true` once the request is made; a browser
  that then cannot start is reported, not returned. `:MDView open` of a file
  keeps opening a tab every time.
- **Text.** Every route that sends preview text (live push, buffer switch,
  initial push, display language) asks `render(bufnr)` instead of reading the
  buffer. The display transform (`browser.transform`, `browser.display_lang`)
  runs on the rendering, as on a file.
- **Pushes.** A text change of the buffer (`TextChanged`, `TextChangedI`) pushes
  by itself, throttled like any edit (`live_push_throttle_ms`). Changes the
  buffer text does not show (a filter, folds) need `mdview.refresh(bufnr)`; it
  goes through the same throttle and returns `false` without a session or for a
  buffer that is no view. Entering the view's buffer shows it again.
- **Background views.** Under `browser.behavior = "reuse"` the one tab follows
  the active buffer. A view that is refreshed while the person works in another
  buffer only updates the tab if the tab still shows the view; it never takes
  the tab away from the document on screen.
- **Render errors.** A `render` that raises or returns anything but a list of
  strings is reported once (until it renders again), and the browser shows the
  error instead of a stale page.
- **Clicks.** A clicked *relative* link of the view (`[x](entry/42)`) goes to
  `on_click("entry/42", ctx)`; query and fragment are dropped by the browser, as
  for click-to-navigate. It is never opened as a file. Absolute paths and URLs
  behave as in any document. This rides on `experimental.click_navigate` (on by
  default); with it off, no click arrives. Browser Back/Forward to a view shows
  its buffer again.
- **Not line for line.** The lines of the buffer are not the lines on screen, so
  scroll and selection sync, breadcrumbs, reverse scroll and the
  `browser.highlighter = "nvim"` fence colors leave the view alone, and a
  write-back from the browser (a checkbox, a text field, a block edit) is
  refused with a notice in the tab.
- **End.** Deleting or wiping the buffer ends the view: the tab that still shows
  it gets a short "was closed" notice, the room's bookkeeping is dropped, and a
  pin on the view is released.

## Example: a filtered log

```lua
local filter = nil
local function render(bufnr)
  local out = { "# " .. vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t:r"), "" }
  for i, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if not filter or line:find(filter, 1, true) then
      out[#out + 1] = ("- [%s](entry/%d)"):format(line, i)
    end
  end
  return out
end

require("mdview").open({
  name = "mylog://service/app.log.md",
  render = render,
  on_click = function(target, ctx)
    local n = tonumber(target:match("^entry/(%d+)$"))
    local win = vim.fn.bufwinid(ctx.bufnr)
    if n and win ~= -1 then
      vim.api.nvim_win_set_cursor(win, { n, 0 })
    end
  end,
})

-- later, after the filter changed:
filter = "ERROR"
require("mdview").refresh()
```

Implementation: `lua/mdview/core/generated.lua`. Tests:
`TESTS/nvim/generated_view_spec.lua`.
