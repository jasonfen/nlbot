# Handoffs

Tag any task `#handoff` anywhere in the vault and <BOT_NAME> will pick it up on the next soul loop. See [[processes/handoffs]] for lifecycle details.

## Open Handoffs

${template.each(query[[from index.tag "task" where not _.done and not string.find(_.page, "templates/") and string.find(_.itags or "", "handoff") order by _.page]], function(t) return "- " .. t.page .. ": " .. t.name .. "\n" end)}

## Archive

${template.each(query[[from index.tag "page" where string.find(_.name, "handoffs/") order by _.name desc]], function(p) return "- [[" .. p.name .. "|" .. p.name .. "]]\n" end)}
