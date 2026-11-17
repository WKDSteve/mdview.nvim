-- The :MDView commands of the bindings checklist of the nvim config that answer with a message or switch a setting
-- (BINDINGS-RUNTIME-CHECKLIST.md, section ":MDView"): each is typed on the command line with the setup of the nvim
-- config (TESTS/sheets/_bindings.lua), first without a session (the setting waits for the next :MDView start), then
-- with a stand-in session, where the sheet reads what the command handed to the relay. The commands that open a
-- buffer, a tab, a file or the browser are in mdview-bindings-views.sheet.lua.

local steps = {
  {
    lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_bindings.lua")]],
    note = "mdview.setup as in the nvim config, vim.notify and the relay transport recorders",
  },
  { expect = [[_G.open_doc()]], note = "a Markdown document is open" },
}

local function add(step)
  steps[#steps + 1] = step
end

---Type `:MDView <line>` and check what it said and did.
local function cmd(line, expect, note)
  add({ keys = ":MDView " .. line .. "<CR>", note = ":MDView " .. line .. ": " .. note })
  add({ expect = expect, note = ":MDView " .. line .. " " .. note })
end

-- Without a session: every setting is recorded for the next start, nothing reaches the relay.

cmd(
  "theme",
  [[_G.said("[mdview] current theme: github (known: github, dark-dimmed, plain, tokyonight, catppuccin)", "INFO")]],
  "reports the current theme and the known ones"
)
cmd(
  "theme tokyonight-dark",
  [[require("mdview.config.browser").defaults.theme == "tokyonight-dark"
    and _G.said("[mdview] theme set to tokyonight-dark (applies on next :MDView start)", "INFO")]],
  "switches the theme with a -dark suffix"
)
cmd(
  "theme no-such-theme",
  [[require("mdview.config.browser").defaults.theme == "tokyonight-dark"
    and _G.said('unknown theme "no-such-theme"', "WARN")]],
  "refuses an unknown theme and keeps the current"
)

cmd(
  "cursor",
  [[_G.said("[mdview] cursor marker: caret (choices: line, caret, block, section, off, toggle)", "INFO")]],
  "reports the marker of the config and the choices"
)
cmd(
  "cursor toggle",
  [[require("mdview.config.browser").defaults.cursor_marker == "section"
    and _G.said("[mdview] cursor marker: section (applies on next :MDView start)", "INFO")]],
  "turns the section spotlight on"
)
cmd(
  "cursor toggle",
  [[require("mdview.config.browser").defaults.cursor_marker == "off" and _G.said("cursor marker: off", "INFO")]],
  "and off again"
)
cmd(
  "cursor caret",
  [[require("mdview.config.browser").defaults.cursor_marker == "caret" and _G.said("cursor marker: caret", "INFO")]],
  "sets a named marker"
)

cmd(
  "blanklines",
  [[require("mdview.config.browser").defaults.preserve_blank_lines == true
    and _G.said("[mdview] preview blank lines: showing all blank lines (applies on next :MDView start)", "INFO")]],
  "toggles from the CommonMark default to every blank line shown"
)
cmd(
  "blanklines",
  [[require("mdview.config.browser").defaults.preserve_blank_lines == false
    and _G.said("preview blank lines: compressed (default)", "INFO")]],
  "and back"
)

cmd(
  "overlay list",
  [[_G.said("[mdview] overlays:\n  toc        off   — floating outline with the current section highlighted", "INFO")]],
  "lists the overlays, each with its state"
)
cmd("overlay", [[_G.said("[mdview] overlays:\n  toc        off", "INFO")]], "without a name lists them as well")
cmd(
  "overlay toc",
  [[require("mdview.config.browser").defaults.overlays.toc == true
    and _G.said("[mdview] overlay toc: on (applies on next :MDView start)", "INFO")]],
  "toggles the floating TOC on"
)
cmd("overlay list", [[_G.said("  toc        on ", "INFO")]], "shows it on")

cmd("sync", [[_G.said("[mdview] scroll sync is active", "INFO")]], "reports the state")
cmd(
  "sync pause",
  [[require("mdview.bindings.autocmds.scroll_sync").is_paused() and _G.said("[mdview] scroll sync paused", "INFO")]],
  "pauses the scroll sync"
)
cmd("sync", [[_G.said("[mdview] scroll sync is paused", "INFO")]], "reports it paused")
cmd(
  "sync resume",
  [[not require("mdview.bindings.autocmds.scroll_sync").is_paused() and _G.said("scroll sync resumed", "INFO")]],
  "resumes it"
)

-- file-log: off by default; the file goes into the fixture folder.
cmd("file-log status", [[_G.said("[mdview] file logging OFF (path: ", "INFO")]], "reports it off")
add({
  keys = ":MDView file-log on <C-r>=g:mdview_sheet_fixture<CR>/relay.log<CR>",
  note = ":MDView file-log on <path>",
})
add({
  expect = [[_G.said("[mdview] file logging ON -> " .. vim.fn.fnamemodify(_G.fixture .. "/relay.log", ":p"), "INFO")
    and select(1, require("mdview.adapter.log").file_log_state()) == true]],
  note = ":MDView file-log on <path> turns it on with that path",
})
cmd("file-log status", [[_G.said("file logging ON -> ", "INFO")]], "reports it on, without changing it")
cmd(
  "file-log toggle",
  [[_G.said("file logging OFF (path: ", "INFO") and select(1, require("mdview.adapter.log").file_log_state()) == false]],
  "toggles it off"
)
cmd(
  "file-log",
  [[_G.said("file logging ON -> ", "INFO") and select(1, require("mdview.adapter.log").file_log_state()) == true]],
  "without an action toggles it on again"
)
cmd(
  "file-log off",
  [[_G.said("file logging OFF (path: ", "INFO") and select(1, require("mdview.adapter.log").file_log_state()) == false]],
  "turns it off"
)

cmd(
  "lang",
  [=[_G.said("[mdview] display language: off (the preview shows the buffer as it is); no tab of another language", "INFO")]=],
  "reports that no display language is set"
)
cmd(
  "lang en",
  [[_G.said("[mdview] display language set to en, but ", "WARN")]],
  "sets one and says the preview stays original without language.nvim"
)
cmd(
  "lang off",
  [[_G.said("[mdview] display language: off (no running session: nothing to refresh)", "INFO")]],
  "turns it off"
)

cmd("reveal", [[_G.said("[mdview] no preview session running", "WARN")]], "needs a session")
cmd("pin", [[_G.said("[mdview] pin: no preview session running", "WARN")]], "needs a session")
add({ expect = [[#_G.sent == 0]], note = "nothing reached the relay without a session" })

-- With a stand-in session: the commands push their change live.
add({ lua = [[_G.session(true)]], note = "a session runs (stand-in)" })

cmd(
  "overlay toc",
  [[vim.deep_equal(_G.control(), { overlay = { name = "toc", on = false } })
    and _G.said("[mdview] overlay toc: off", "INFO")]],
  "sends the overlay switch to the preview"
)
cmd(
  "cursor section",
  [[_G.control().cursor == "section" and _G.said("[mdview] cursor marker: section", "INFO")]],
  "sends the marker to the preview"
)
cmd(
  "blanklines on",
  [[_G.control().blankLines == true and _G.said("[mdview] preview blank lines: showing all blank lines", "INFO")]],
  "sends the blank-line mode"
)
cmd(
  "reveal",
  [[_G.control().reveal == true and _G.said("[mdview] private blocks revealed", "INFO")]],
  "reveals the private blocks"
)
cmd(
  "reveal",
  [[_G.control().reveal == false and _G.said("[mdview] private blocks hidden", "INFO")]],
  "and hides them again"
)
cmd(
  "pin",
  [[require("mdview.core.pin").is_pinned() and _G.said("[mdview] preview pinned to ", "INFO")
   ]],
  "holds the preview on the current document"
)
cmd("pin status", [[_G.said("[mdview] preview is pinned to ", "INFO")]], "reports the pin")
cmd(
  "pin",
  [[not require("mdview.core.pin").is_pinned() and _G.said("[mdview] preview unpinned from ", "INFO")]],
  "without an action releases it again"
)

add({ lua = [[_G.session(false); _G.sent = {}]], note = "the session ends" })
add({ expect = [[_G.text() == ""]], note = "no message is left that no step asked for" })

return {
  id = "mdview.bindings-commands",
  title = "The :MDView commands of the nvim config answer with the setting they name and push it to a running preview",
  task = "mdview.nvim/bindings-checkliste-im-echten-browser-abnehmen",
  engine = "rpc",
  sizes = { { rows = 30, cols = 120 } },
  steps = steps,
  manual = {
    "In a real session (:MDView start): :MDView theme tokyonight-dark re-opens the preview in that theme, :MDView overlay toc shows and hides the floating TOC, :MDView cursor section dims everything but the current section, :MDView blanklines on shows every blank line, :MDView reveal unblurs a ```private block, :MDView sync pause stops the preview from following the cursor, :MDView pin keeps the preview on its document when another Markdown buffer is entered",
    "With language.nvim installed: :MDView lang de translates the preview, :MDView lang off shows it as written",
  },
}
