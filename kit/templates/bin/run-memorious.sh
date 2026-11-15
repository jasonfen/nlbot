#!/bin/bash
export PATH="${HOME_DIR}/.local/bin:$PATH"
# memorious-localtime.py wraps memorious-mcp so timestamps use local time
# (${TIMEZONE}), not the package's hardcoded UTC. See that file. The
# mcp<2 pin still applies: fastmcp 2.14.1 breaks on mcp 2.0.0.
exec uvx --with 'mcp<2' --from memorious-mcp python ${VAULT_DIR}/bin/memorious-localtime.py "$@"
