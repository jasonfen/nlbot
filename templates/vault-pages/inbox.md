# Inbox

## Open Tasks (live — all pages)

${template.each(query[[from index.tag "task" where not _.done and not string.find(_.page, "node_modules") and not string.find(_.page, "templates/") order by _.page]], function(t) return "- " .. t.page .. ": " .. t.name .. "\n" end)}

## Action Items

<!-- Track concrete to-dos here. Tag with `#action`. Sub-tags: `#infra`, `#bug`, `#docs`. -->
