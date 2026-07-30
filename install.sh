#!/usr/bin/env bash
#
# Instalacja: dowiązanie w PATH + blok do ~/.zshrc.
# Dowiązanie, nie kopia — dzięki temu `git pull` w tym repozytorium od razu
# aktualizuje narzędzie, bez powtarzania instalacji.

set -euo pipefail
ZRODLO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sesja.sh"
CEL="$HOME/.local/bin/sesja-cli"

mkdir -p "$HOME/.local/bin"
ln -sf "$ZRODLO" "$CEL"
echo "✓ $CEL -> $ZRODLO"

case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) echo "⚠ ~/.local/bin nie jest w PATH — dopisz do ~/.zshrc:"
       echo '    export PATH="$HOME/.local/bin:$PATH"' ;;
esac

if grep -q 'sesja-cli' "$HOME/.zshrc" 2>/dev/null; then
    echo "✓ funkcja `sesja` jest już w ~/.zshrc"
else
    echo
    echo "Dopisz do ~/.zshrc (funkcja, nie alias — tylko funkcja zmieni katalog powłoki):"
    echo
    sed -n '/^sesja() {/,/^}/p' "$(dirname "$ZRODLO")/README.md" 2>/dev/null \
      || echo "  (blok znajdziesz w README.md, sekcja „Jedno hasło: sesja”)"
fi
