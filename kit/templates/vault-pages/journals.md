# Journals

See [[processes/journaling]] for compaction rules.

${template.each(query[[from index.tag "page" where string.find(_.name, "journals/") order by _.name desc]], templates.pageItem)}
