This is where you configure SilverBullet to your liking. See [[^Library/Std/Config]] for the full list of options.

The kit declares its defaults via `config.define` (not `config.set`) so they appear in the [[Configuration Manager]] UI with descriptions and can be overridden cleanly. A `config.define` default applies only when the key isn't already set, so any value you set elsewhere (via the UI or another space-lua block) wins over the kit's default.

```space-lua
-- Plugs the kit installs by default. Edit and run "Plugs: Update" to apply
-- changes. The kit pre-installs TreeView's compiled bundle into _plug/ at
-- first-time setup, so the default below is mostly a record of intent —
-- changing it (e.g. adding silversearch.plug.js) and running Plugs: Update
-- is how you add more.
config.define("plugs", {
  description = "Plug URLs fetched on Plugs: Update.",
  type = "array",
  items = { type = "string" },
  default = {
    "github:joekrill/silverbullet-treeview/treeview.plug.js",
  },
  ui = { category = "Kit Defaults", label = "Plugs" },
})

-- TreeView sidebar position.
config.define("treeview.position", {
  description = "Where the TreeView sidebar appears.",
  type = "string",
  enum = { "lhs", "rhs" },
  default = "lhs",
  ui = { category = "Kit Defaults", label = "TreeView position" },
})

-- Custom task states. The Std library already defines taskStates as a known
-- key, so we set our override directly instead of redefining the schema.
-- Click a checkbox to cycle: [ ] open → [>] in progress → [x] done →
-- [?] blocked → [~] deferred → [!] urgent.
config.set("taskStates", { " ", ">", "x", "?", "~", "!" })
```
