#!/usr/bin/env bash
# Copies skills/* into ~/.agents/skills (Claude Code links ~/.claude/skills to the same directories).
set -euo pipefail
cd "$(dirname "$0")"
dest="${AGENT_SKILLS_DIR:-$HOME/.agents/skills}"
for s in skills/*/; do
  name="$(basename "$s")"
  rm -rf "$dest/$name.new" && cp -R "$s" "$dest/$name.new"
  rm -rf "$dest/$name" && mv "$dest/$name.new" "$dest/$name"
  echo "installed $name"
done
