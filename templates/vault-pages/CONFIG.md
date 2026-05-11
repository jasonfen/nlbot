This is where you configure SilverBullet to your liking. See [[^Library/Std/Config]] for the full list of options.

```space-lua
-- Plugs are loaded from this list on Plugs: Update. The bot kit declares
-- TreeView by default because vault navigation without it is rough. Add
-- more here as you discover them — Plugs: Update fetches and compiles.
config.set("plugs", {
  "github:joekrill/silverbullet-treeview/treeview.plug.js",
})

-- TreeView: folder-tree sidebar on the left. Essential for jumping
-- between handoffs/, journals/, processes/ without typing wiki-links.
config.set("treeview", {
  position = "lhs",
})

-- Custom task states. Click a checkbox to cycle through:
-- [ ] open → [>] in progress → [x] done → [?] blocked → [~] deferred → [!] urgent.
-- The bot's soul-loop and handoff queries treat `[ ]` as "open" and
-- everything else as "not actionable yet."
config.set("taskStates", {
  " ",
  ">",
  "x",
  "?",
  "~",
  "!",
})
```
