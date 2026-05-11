# Dashboard

## Open Tasks

${template.each(query[[from index.tag "task" where not _.done and not string.find(_.page, "node_modules") and not string.find(_.page, "templates/") limit 20]], function(t) return "- [" .. (t.state or " ") .. "] " .. t.name .. " (" .. t.page .. ")\n" end)}


## Recent Activity

${template.each(query[[from index.tag "page" where not string.find(_.name, "node_modules") order by _.lastModified desc limit 10]], templates.pageItem)}

## Open Handoffs

${template.each(query[[from index.tag "task" where not _.done and not string.find(_.page, "node_modules") and not string.find(_.page, "templates/") and string.find(_.itags or "", "handoff")]], function(t) return "- " .. t.name .. " (" .. t.page .. ")\n" end)}

## Open Ideas

${template.each(query[[from index.tag "task" where not _.done and not string.find(_.page, "node_modules") and not string.find(_.page, "templates/") and string.find(_.itags or "", "idea")]], function(t) return "- " .. t.name .. " (" .. t.page .. ")\n" end)}
