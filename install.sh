#!/usr/bin/env bash
#
# Installs a symlink into ~/.local/bin and prints the shell function to add.
#
# A symlink rather than a copy: `git pull` in this repository then updates the
# tool everywhere at once, with no reinstall step to remember.

set -euo pipefail

SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/agent-worktrees.sh"
TARGET="$HOME/.local/bin/agent-worktrees"

mkdir -p "$HOME/.local/bin"
ln -sf "$SOURCE" "$TARGET"
chmod +x "$SOURCE"
echo "✓ $TARGET -> $SOURCE"

case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *)
        echo
        echo "⚠  ~/.local/bin is not in your PATH. Add this to your shell config:"
        echo '     export PATH="$HOME/.local/bin:$PATH"'
        ;;
esac

RC="${ZDOTDIR:-$HOME}/.zshrc"
[[ -f "$RC" ]] || RC="$HOME/.bashrc"

if grep -q 'agent-worktrees' "$RC" 2>/dev/null; then
    echo "✓ shell function already present in $(basename "$RC")"
    exit 0
fi

cat <<'BLOCK'

Add this to your shell config. It must be a FUNCTION, not an alias — only a
function can change the current shell's directory, and an alias cannot capture
the script's output.

awt() {
    local cli="$HOME/.local/bin/agent-worktrees"
    case "${1:-start}" in
        start|"")
            local out dir agent
            out="$(AWT_WRAPPER=1 "$cli" start)" || return 1
            dir="${out%%$'\t'*}"; agent="${out##*$'\t'}"
            cd "$dir" || return 1
            [[ "$agent" == "plain shell" ]] && return 0
            "$agent"
            ;;
        *) "$cli" "$@" ;;
    esac
}

BLOCK
