#!/usr/bin/env bash
#
# Izolacja sesji roboczych — jeden agent, jeden katalog roboczy.
#
# PO CO TO ISTNIEJE
# =================
# 29.07.2026 dwóch agentów pracowało w JEDNYM katalogu roboczym. Skutek: commit
# jednego z nich wciągnął niezacommitowane pliki drugiego, a rebase przepisał
# hashe już wypchniętych commitów. Moduł Finanse ocalał tylko dlatego, że ktoś
# to w porę zauważył.
#
# Git ma na to wbudowane rozwiązanie: `git worktree`. Jedno repozytorium
# (wspólne obiekty i refy), ale WIELE niezależnych katalogów roboczych, każdy
# z własnym checkoutem i własnym indeksem. Dwie sesje fizycznie nie mogą sobie
# nadpisać plików, a git NIE POZWOLI wypożyczyć tej samej gałęzi do dwóch
# worktree naraz — to wbudowana blokada, nie nasza konwencja.
#
# CZEGO WORKTREE NIE ZAŁATWIA
# ===========================
# Obiekty i refy są wspólne, więc `rebase`, `commit --amend` i `push --force`
# na WYPCHNIĘTEJ gałęzi nadal popsują pracę drugiej osoby. Worktree chroni
# katalog roboczy, nie historię.
#
# UŻYCIE
#   sesja.sh                       # ANKIETA: baza, nazwa, agent (domyślne)
#   sesja.sh nowa <nazwa> [prod]   # bez pytań; `prod` = hotfix na produkcję
#   sesja.sh lista                 # co jest zajęte i przez kogo
#   sesja.sh gdzie                 # gdzie jestem, od czego odbity, ile zaległości
#   sesja.sh proba                 # czy dociągnięcie bazy da konflikt
#   sesja.sh sprzataj              # usuń worktree bez zmian i bez commitów
#   sesja.sh sprawdz               # czy izolacja naprawdę działa
#
# Integracja z powłoką i instalacja: patrz README.md

set -euo pipefail

# ---------------------------------------------------------------------------
# NARZĘDZIE JEST GLOBALNE, NIE NALEŻY DO ŻADNEGO PROJEKTU
# ---------------------------------------------------------------------------
# Repozytorium ustalamy z KATALOGU, W KTÓRYM STOISZ, a nie z położenia skryptu.
# Wcześniej było odwrotnie i skutek był taki, że `sesja` uruchomiona w kanariksie
# zakładała sesję dla kamara — bo tam leżał plik. Teraz ten sam skrypt obsługuje
# każde repozytorium na dysku.
#
# `--git-common-dir` zamiast `--show-toplevel`, bo w worktree ten pierwszy
# wskazuje na GŁÓWNE repozytorium, a drugi na bieżący katalog roboczy. Chcemy
# główne — inaczej sesja zakładana z wnętrza sesji tworzyłaby zagnieżdżenia.
GLOWNE="$(git rev-parse --git-common-dir 2>/dev/null || true)"
if [[ -z "$GLOWNE" ]]; then
    printf '\033[0;31m%s\033[0m\n' "To nie jest katalog repozytorium git." >&2
    printf '%s\n' "Wejdź do projektu, w którym chcesz założyć sesję, i spróbuj ponownie." >&2
    exit 1
fi
GLOWNE="$(cd "$GLOWNE" && pwd)"          # bywa ścieżką względną
GLOWNE="$(dirname "$GLOWNE")"            # .../repo/.git -> .../repo
BAZA="$(dirname "$GLOWNE")"
PREFIKS="$(basename "$GLOWNE")-sesja"

kolor()  { printf '\033[%sm%s\033[0m\n' "$1" "$2"; }
info()   { kolor '0;36' "$1"; }
ok()     { kolor '0;32' "$1"; }
uwaga()  { kolor '0;33' "$1"; }
blad()   { kolor '0;31' "$1" >&2; }

# ---------------------------------------------------------------------------
# GAŁĄŹ BAZOWA SESJI
# ---------------------------------------------------------------------------
# Sesja może być odbita od `origin/stage` albo od `origin/prod` (hotfix). Od tego
# momentu KAŻDE pytanie „ile mam własnych commitów" i „czy jestem do tyłu" ma
# sens wyłącznie względem TEJ bazy, nie względem stage'a na sztywno.
#
# Wcześniej `sprzataj` liczył zawsze `origin/stage..<gałąź>`. Dla sesji odbitej
# od proda ta liczba jest fałszywa w najgorszą stronę: commity proda, których
# stage jeszcze nie ma, byłyby policzone jako „własne", więc katalog gotowy do
# usunięcia zostawałby na dysku — albo, po zmergowaniu proda do stage'a, sesja
# z prawdziwą pracą pokazałaby zero i kwalifikowałaby się do skasowania.

domyslna_baza() {
    if git -C "$GLOWNE" rev-parse --verify --quiet origin/stage >/dev/null; then
        echo "origin/stage"
    else
        echo "origin/prod"
    fi
}

# Baza zapisywana jest przy zakładaniu sesji we WSPÓLNEJ konfiguracji repozytorium
# (`branch.<gałąź>.sesjaBaza`), a nie w konfiguracji worktree — dzięki temu
# przeżywa usunięcie katalogu i jest widoczna z każdego innego worktree.
zapisz_baze() {
    git -C "$GLOWNE" config "branch.$1.sesjaBaza" "$2"
}

baza_galezi() {
    local galaz="$1" zapisana upstream

    zapisana="$(git -C "$GLOWNE" config --get "branch.$galaz.sesjaBaza" 2>/dev/null || true)"
    if [[ -n "$zapisana" ]] && git -C "$GLOWNE" rev-parse --verify --quiet "$zapisana" >/dev/null; then
        echo "$zapisana"
        return 0
    fi

    # Sesje założone przed wprowadzeniem tego klucza go nie mają. Bazę da się
    # jednak odzyskać ze śledzenia, bo `worktree add -b <gałąź> <baza>` je ustawia.
    #
    # Jeden warunek jest tu konieczny: po `push -u` upstream przestaje wskazywać
    # bazę, a zaczyna wskazywać ZDALNĄ KOPIĘ TEJ SAMEJ GAŁĘZI. Bez tego wyjątku
    # sesja po pierwszym pushu raportowałaby zawsze zero commitów do tyłu i zero
    # własnych — czyli wyglądałaby na nietkniętą dokładnie wtedy, gdy pracy jest
    # najwięcej.
    #
    # Weryfikacja ISTNIENIA refu jest tu obowiązkowa, nie ostrożnościowa:
    # `rev-parse --symbolic-full-name` na nierozwiązywalnej nazwie NIE zwraca
    # błędu, tylko odbija wejście z powrotem (dosłowne „gałąź@{upstream}").
    # Taki śmieć przeszedłby dalej jako baza, `rev-list` by się na nim wywalił,
    # a `|| echo 0` zamieniłoby awarię w „zero własnych commitów" — czyli sesja
    # z prawdziwą pracą wyglądałaby na nietkniętą i poszłaby do skasowania.
    upstream="$(git -C "$GLOWNE" rev-parse --abbrev-ref --symbolic-full-name "$galaz@{upstream}" 2>/dev/null || true)"
    if [[ -n "$upstream" && "$upstream" != "origin/$galaz" ]] \
       && git -C "$GLOWNE" rev-parse --verify --quiet "$upstream" >/dev/null; then
        echo "$upstream"
        return 0
    fi

    domyslna_baza
}

# ---------------------------------------------------------------------------
# ANKIETA — jedno hasło, reszta pytaniami
# ---------------------------------------------------------------------------
# Menu w czystym bashu, bez `gum`, `fzf` ani `whiptail` — żeby uruchomienie
# sesji nie wymagało instalowania czegokolwiek. Pytania idą na stderr, bo
# stdout niesie wynik (ścieżkę), który czyta funkcja powłoki.

# Czyta z terminala, gdy jest; ze standardowego wejścia, gdy go nie ma. Bez tego
# ankiety nie da się przetestować inaczej niż ręcznie, a nietestowalny kod
# interaktywny to kod, w którym błędy wychodzą dopiero przy człowieku.
wczytaj_linie() {
    local l
    read -r l || l=""
    printf '%s' "$l"
}

wybierz() {
    local pytanie="$1"; shift
    local opcje=("$@") i wybor
    {
        printf '\n\033[0;36m%s\033[0m\n' "$pytanie"
        for i in "${!opcje[@]}"; do printf '   %d) %s\n' "$((i + 1))" "${opcje[$i]}"; done
    } >&2
    while true; do
        printf '   wybór [1]: ' >&2
        wybor="$(wczytaj_linie)"
        wybor="${wybor:-1}"
        if [[ "$wybor" =~ ^[0-9]+$ ]] && [ "$wybor" -ge 1 ] && [ "$wybor" -le "${#opcje[@]}" ]; then
            printf '%s\n' "${opcje[$((wybor - 1))]}"
            return 0
        fi
        printf '   \033[0;31mnie ma takiej opcji\033[0m\n' >&2
    done
}

zapytaj_o_nazwe() {
    local nazwa
    while true; do
        printf '\n\033[0;36mNazwa sesji\033[0m (katalog, gałąź i okno dostaną tę samą)\n' >&2
        printf '   nazwa: ' >&2
        nazwa="$(wczytaj_linie)"
        # Slug: bez spacji i znaków, które w nazwie gałęzi albo katalogu robią
        # niespodzianki. Wolę odrzucić i poprosić ponownie niż po cichu zmienić
        # to, co człowiek wpisał.
        if [[ "$nazwa" =~ ^[a-z0-9][a-z0-9-]{1,38}$ ]]; then
            printf '%s\n' "$nazwa"
            return 0
        fi
        printf '   \033[0;31mmałe litery, cyfry i myślniki, 2–39 znaków\033[0m\n' >&2
    done
}

# ---------------------------------------------------------------------------
# KONFIGURACJA PROJEKTU — plik w repozytorium, wykrywanie jako zapas
# ---------------------------------------------------------------------------
# `.sesje.conf` leży w korzeniu repozytorium (nie w katalogu-kontenerze, bo ten
# nie jest wersjonowany). Parsowany ŚCIŚLE, nie `source`'owany: wczytywanie
# konfiguracji przez `source` znaczy, że plik w katalogu projektu wykonuje
# dowolny kod, a to niepotrzebne ryzyko dla pliku, który sam generuję.
odczytaj_conf() {
    local plik="$GLOWNE/.sesje.conf" klucz="$1"
    [[ -f "$plik" ]] || return 1
    sed -n "s/^[[:space:]]*${klucz}[[:space:]]*=[[:space:]]*//p" "$plik" \
        | sed 's/[[:space:]]*$//' | head -1 | grep . || return 1
}

dostepne_agenty() {
    local a
    for a in claude gemini copilot; do
        command -v "$a" >/dev/null 2>&1 && printf '%s\n' "$a"
    done
    printf 'sama powłoka\n'
}

cmd_start() {
    local baza nazwa agent domyslny

    info "Nowa sesja robocza — repozytorium: $(basename "$GLOWNE")"

    # Bazy: tylko te, które faktycznie istnieją zdalnie. Pytanie o gałąź,
    # której nie ma, kończyłoby się błędem dopiero po wpisaniu nazwy.
    local bazy=()
    git -C "$GLOWNE" rev-parse --verify --quiet origin/stage >/dev/null && bazy+=("stage — praca bieżąca")
    git -C "$GLOWNE" rev-parse --verify --quiet origin/prod  >/dev/null && bazy+=("prod — HOTFIX na produkcję")
    if [ "${#bazy[@]}" -eq 0 ]; then
        blad "Nie ma ani origin/stage, ani origin/prod."
        exit 1
    fi
    baza="$(wybierz "Od czego odbić sesję?" "${bazy[@]}")"
    baza="${baza%% *}"

    nazwa="$(zapytaj_o_nazwe)"

    domyslny="$(odczytaj_conf agent || echo claude)"
    # Dwa przebiegi zamiast wstawiania na poczatek w locie: rozwijanie PUSTEJ
    # tablicy pod `set -u` wywala sie na bashu 3.2, ktory macOS ma w /bin/bash.
    local wszystkie=() agenty=() a
    while IFS= read -r a; do wszystkie+=("$a"); done < <(dostepne_agenty)
    for a in "${wszystkie[@]}"; do [[ "$a" == "$domyslny" ]] && agenty+=("$a"); done
    for a in "${wszystkie[@]}"; do [[ "$a" == "$domyslny" ]] || agenty+=("$a"); done
    agent="$(wybierz "Którego agenta uruchomić?" "${agenty[@]}")"

    {
        printf '\n\033[0;33m%s\033[0m\n' "Do zatwierdzenia:"
        printf '   gałąź:    %s\n' "$([ "$baza" = prod ] && echo "hotfix/$nazwa" || echo "sesja/$nazwa")"
        printf '   baza:     origin/%s\n' "$baza"
        printf '   katalog:  %s\n' "$BAZA/$PREFIKS-$nazwa"
        printf '   agent:    %s\n' "$agent"
        printf '   Enter = tak, cokolwiek innego = przerwij: '
    } >&2
    local potwierdzenie
    potwierdzenie="$(wczytaj_linie)"
    if [[ -n "$potwierdzenie" ]]; then
        uwaga "Przerwane — nic nie utworzone."
        exit 0
    fi

    local katalog
    katalog="$(cmd_nowa "$nazwa" "$baza" | tail -1)"

    # Skrypt nie zmieni katalogu powłoki rodzica — to ograniczenie procesów, nie
    # niedoróbka. Gdy woła nas funkcja powłoki (SESJA_WRAPPER=1), oddajemy jej
    # ścieżkę i agenta, a ona robi `cd`. Uruchomiony wprost — wchodzimy sami
    # i podmieniamy proces na agenta.
    if [[ -n "${SESJA_WRAPPER:-}" ]]; then
        printf '%s\t%s\n' "$katalog" "$agent"
        return 0
    fi
    cd "$katalog" || exit 1
    [[ "$agent" == "sama powłoka" ]] && exec "${SHELL:-/bin/bash}"
    exec "$agent"
}

cmd_nowa() {
    local nazwa="${1:-}"
    local zadana_baza="${2:-stage}"
    if [[ -z "$nazwa" ]]; then
        blad "Podaj nazwę sesji, np.: sesja.sh nowa finanse"
        blad "Hotfix na produkcję:   sesja.sh nowa <nazwa> prod"
        exit 1
    fi

    # WYBÓR BAZY JEST TU KRYTYCZNY, NIE KOSMETYCZNY.
    # `stage` bywa daleko przed `prod` (30.07.2026: 16 commitów, całe nowe
    # moduły). Hotfix odbity od stage'a przywiózłby na produkcję cały ten ładunek
    # razem z jedną poprawioną linią. Dlatego baza jest jawna, a gałąź nazywa się
    # inaczej — żeby w `git branch` było widać, co celuje w produkcję.
    local baza_ref galaz
    case "$zadana_baza" in
        prod|origin/prod)   baza_ref="origin/prod";  galaz="hotfix/$nazwa" ;;
        stage|origin/stage) baza_ref="origin/stage"; galaz="sesja/$nazwa"  ;;
        *)                  baza_ref="$zadana_baza"; galaz="sesja/$nazwa"  ;;
    esac

    local katalog="$BAZA/$PREFIKS-$nazwa"

    if [[ -d "$katalog" ]]; then
        uwaga "Worktree już istnieje — wchodzę w istniejący."
        echo "$katalog"
        return 0
    fi

    # ZAWSZE od świeżego stanu zdalnego. Odbicie od lokalnej gałęzi zaciągnęłoby
    # cudze niezacommitowane decyzje i zaczynałoby pracę od nieznanego stanu.
    git -C "$GLOWNE" fetch origin --quiet

    if ! git -C "$GLOWNE" rev-parse --verify --quiet "$baza_ref" >/dev/null; then
        blad "Nie ma takiej bazy: $baza_ref"
        exit 1
    fi

    # PRZEZ HERDRA, GDY JEST DOSTĘPNY.
    # Herdr to menedżer przestrzeni roboczych dla agentów — sam zarządza
    # worktree i pokazuje je w interfejsie razem ze statusem agenta. Tworzenie
    # katalogu za jego plecami zadziała, ale nowa sesja nie otworzy się w oknie.
    # Dlatego oddajemy mu robotę, a sami dokładamy tylko to, czego nie robi:
    # bazę na świeżym origin/stage i wspólną pamięć Claude Code.
    if command -v herdr >/dev/null 2>&1; then
        herdr worktree create --cwd "$GLOWNE" --branch "$galaz" --base "$baza_ref" --path "$katalog" >/dev/null 2>&1 \
            || git -C "$GLOWNE" worktree add -b "$galaz" "$katalog" "$baza_ref" >/dev/null
    elif git -C "$GLOWNE" rev-parse --verify --quiet "$galaz" >/dev/null; then
        git -C "$GLOWNE" worktree add "$katalog" "$galaz" >/dev/null
    else
        git -C "$GLOWNE" worktree add -b "$galaz" "$katalog" "$baza_ref" >/dev/null
    fi

    zapisz_baze "$galaz" "$baza_ref"
    podepnij_pamiec "$katalog"

    ok "Sesja ${nazwa} gotowa."
    info "  katalog: $katalog"
    info "  gałąź:   $galaz (od $baza_ref)"

    # Przy hotfixie mówimy wprost, co jest inne — i przypominamy o kroku, o który
    # najłatwiej się potknąć. Poprawka scalona TYLKO do proda zostanie cicho
    # cofnięta przy następnym wydaniu stage'a, bo stage jej nie zna.
    if [[ "$baza_ref" == "origin/prod" ]]; then
        echo
        uwaga "HOTFIX NA PRODUKCJĘ — gałąź odbita od proda, nie od stage'a."
        uwaga "  Po wdrożeniu SCAL TĘ POPRAWKĘ TAKŻE DO stage:"
        uwaga "    git checkout stage && git merge $galaz"
        uwaga "  Bez tego następne wydanie stage'a ją cicho cofnie."
    fi

    echo "$katalog"
}

# ---------------------------------------------------------------------------
# WSPÓLNA PAMIĘĆ AGENTÓW MIĘDZY SESJAMI
# ---------------------------------------------------------------------------
# Claude Code trzyma historię i pamięć projektu w katalogu nazwanym od ŚCIEŻKI
# projektu (~/.claude/projects/-Users-marcin-...). Każdy worktree ma inną
# ścieżkę, więc bez tego kroku agent w nowej sesji startuje z PUSTĄ pamięcią:
# nie widzi MEMORY.md ani ustaleń z poprzednich rozmów.
#
# To najgorszy możliwy rodzaj izolacji — chcieliśmy rozdzielić PLIKI, a przy
# okazji rozdzieliliśmy WIEDZĘ. Dlatego katalog pamięci sesji jest dowiązaniem
# do katalogu pamięci głównego repozytorium.
podepnij_pamiec() {
    local katalog="$1"
    local baza_projektow="$HOME/.claude/projects"
    [[ -d "$baza_projektow" ]] || return 0

    # Nazwa katalogu = ścieżka z zamienionymi `/` i `_` na `-`.
    local klucz_glowny klucz_sesji
    klucz_glowny="$(printf '%s' "$GLOWNE"  | tr '/_' '--')"
    klucz_sesji="$(printf '%s' "$katalog" | tr '/_' '--')"

    local zrodlo="$baza_projektow/$klucz_glowny"
    local cel="$baza_projektow/$klucz_sesji"

    [[ -d "$zrodlo" ]] || return 0        # główny projekt nie ma jeszcze pamięci
    [[ -e "$cel" ]]    && return 0        # nie nadpisujemy istniejącej

    ln -s "$zrodlo" "$cel" 2>/dev/null && \
        info "  pamięć:  wspólna z głównym repozytorium (dowiązanie)"
}

# ---------------------------------------------------------------------------
# PRÓBA SCALENIA — „czy mogę bezpiecznie dociągnąć bazę"
# ---------------------------------------------------------------------------
# Pytanie pada za każdym razem, gdy `gdzie` pokaże zaległość, a odpowiadanie na
# nie przez faktyczny `git merge` i ewentualne cofanie jest złym pomysłem: przy
# konflikcie zostawia katalog w stanie pół-scalonym, w środku czyjejś pracy.
#
# Dlatego próba idzie WYŁĄCZNIE po bazie obiektów, nie po katalogu roboczym:
#   `git stash create` — robi obiekt commita ze stanu roboczego i NIE rusza ani
#                        indeksu, ani plików (w przeciwieństwie do `git stash`),
#   `git merge-tree`   — liczy scalenie dwóch commitów bez checkoutu.
#
# Efekt uboczny, który akurat jest zaletą: próba obejmuje zmiany NIEZACOMMITOWANE.
# Zwykłe `git merge --ff-only` w ogóle by ich nie wzięło pod uwagę i odmówiłoby
# dopiero w trakcie, komunikatem o nadpisaniu lokalnych zmian.
cmd_proba() {
    local tu galaz baza stan wynik
    tu="$(git rev-parse --show-toplevel 2>/dev/null || echo '')"
    if [[ -z "$tu" ]]; then
        blad "To nie jest katalog repozytorium."
        exit 1
    fi

    galaz="$(git rev-parse --abbrev-ref HEAD)"
    baza="$(baza_galezi "$galaz")"
    git fetch origin --quiet 2>/dev/null || uwaga "  (nie udało się odświeżyć origin — próba na tym, co lokalne)"

    info "Próba scalenia $baza w $galaz — nic nie zostanie zmienione."

    local z_tylu
    z_tylu="$(git rev-list --count "HEAD..$baza" 2>/dev/null || echo 0)"
    if [[ "$z_tylu" == "0" ]]; then
        ok "  jesteś na bieżąco z $baza — nie ma czego dociągać"
        return 0
    fi

    # Pusty wynik = brak zmian roboczych; wtedy próbujemy sam HEAD.
    stan="$(git stash create 2>/dev/null || true)"
    [[ -n "$stan" ]] || stan="HEAD"

    if wynik="$(git merge-tree --write-tree --name-only "$stan" "$baza" 2>&1)"; then
        ok "  $z_tylu commitów do dociągnięcia, BEZ konfliktu"
        info "  możesz scalić: git merge $baza"
        return 0
    fi

    blad "  KONFLIKT — te pliki wymagają ręcznego rozstrzygnięcia:"
    echo "$wynik" | tail -n +2 | sed 's/^/    /' >&2
    uwaga "  katalog roboczy pozostał NIETKNIĘTY — scalaj dopiero świadomie"
    return 1
}

cmd_lista() {
    info "Katalogi robocze tego repozytorium:"
    git -C "$GLOWNE" worktree list --porcelain | awk '
        /^worktree /   { sciezka = substr($0, 10) }
        /^branch /     { galaz   = substr($0, 8); sub("refs/heads/", "", galaz) }
        /^detached/    { galaz   = "(odłączony HEAD)" }
        /^$/           { if (sciezka != "") printf("  %-58s %s\n", sciezka, galaz); sciezka=""; galaz="" }
        END            { if (sciezka != "") printf("  %-58s %s\n", sciezka, galaz) }
    '

    # Które są w tej chwili używane przez powłokę — pomaga wyłapać, że dwie
    # osoby siedzą w tym samym miejscu.
    local zajete
    zajete="$(lsof -a -d cwd -Fn 2>/dev/null | grep "^n$BAZA/$PREFIKS" | sed 's/^n//' | sort -u || true)"
    if [[ -n "$zajete" ]]; then
        echo
        info "Otwarte w powłokach:"
        echo "$zajete" | sed 's/^/  /'
    fi
}

cmd_sprzataj() {
    info "Szukam worktree bez zmian i bez własnych commitów…"
    local usuniete=0

    while IFS= read -r sciezka; do
        [[ -d "$sciezka" ]] || continue
        [[ "$sciezka" == "$GLOWNE" ]] && continue

        # TYLKO KATALOGI SESYJNE. Bez tego warunku sprzątanie przechodziło po
        # WSZYSTKICH worktree repozytorium i kasowało cudze — łącznie z
        # gałęziami, które w nich siedziały. Sprawdzone boleśnie 29.07.2026:
        # zniknęły kamar-sentry-prod i kamar-sentry-wp. Polecenie „posprzątaj
        # moje sesje" nie ma prawa dotknąć niczego innego.
        [[ "$(basename "$sciezka")" == "$PREFIKS-"* ]] || continue

        # Nietknięte = brak zmian roboczych I brak commitów ponad bazą.
        if [[ -n "$(git -C "$sciezka" status --porcelain 2>/dev/null)" ]]; then
            uwaga "  pomijam (są zmiany): $sciezka"
            continue
        fi
        local galaz baza ile
        galaz="$(git -C "$sciezka" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
        [[ -n "$galaz" ]] || continue

        # Względem WŁASNEJ bazy sesji, nie względem stage'a na sztywno.
        baza="$(baza_galezi "$galaz")"

        # Gdy liczenie się nie uda, katalog ZOSTAJE. Nieznany stan nie może
        # znaczyć „nic tu nie ma" — koszt błędu jest niesymetryczny: zostawiony
        # worktree to zajęte 50 MB, skasowany to cudza praca.
        if ! ile="$(git -C "$GLOWNE" rev-list --count "$baza..$galaz" 2>/dev/null)"; then
            uwaga "  pomijam (nie umiem policzyć commitów wzgl. $baza): $sciezka"
            continue
        fi
        if [[ "$ile" != "0" ]]; then
            uwaga "  pomijam ($ile własnych commitów ponad $baza): $sciezka"
            continue
        fi

        git -C "$GLOWNE" worktree remove "$sciezka" --force >/dev/null 2>&1 || true
        # `-d`, nie `-D`: gałąź z niescalonymi commitami zostaje. Do tego
        # miejsca dochodzą tylko gałęzie bez własnych commitów, ale wolę,
        # żeby to git był ostatnim strażnikiem, a nie mój warunek wyżej.
        git -C "$GLOWNE" branch -d "$galaz" >/dev/null 2>&1 || true
        ok "  usunięte: $sciezka"
        usuniete=$((usuniete + 1))
    done < <(git -C "$GLOWNE" worktree list --porcelain | awk '/^worktree /{print substr($0,10)}')

    git -C "$GLOWNE" worktree prune
    ok "Gotowe — usunięto $usuniete."
}

cmd_gdzie() {
    local tu
    tu="$(git rev-parse --show-toplevel 2>/dev/null || echo '')"
    if [[ -z "$tu" ]]; then
        blad "To nie jest katalog repozytorium."
        exit 1
    fi
    if [[ "$tu" == "$GLOWNE" ]]; then
        uwaga "Jesteś w GŁÓWNYM katalogu repozytorium."
        uwaga "Przy pracy równoległej załóż własną sesję: sesja.sh nowa <nazwa>"
        return 0
    fi

    local galaz baza z_tylu wlasne
    galaz="$(git rev-parse --abbrev-ref HEAD)"
    baza="$(baza_galezi "$galaz")"
    ok "Sesja: $(basename "$tu")  ·  gałąź: $galaz  ·  baza: $baza"

    # Ostrzeżenie zamiast cichego scalania. Dociąganie w środku pracy potrafi
    # wysypać konflikt w najgorszym momencie, więc decyzja zostaje przy Tobie —
    # skrypt ma tylko dopilnować, żebyś o zaległości wiedział.
    z_tylu="$(git rev-list --count "HEAD..$baza" 2>/dev/null || echo 0)"
    wlasne="$(git rev-list --count "$baza..HEAD" 2>/dev/null || echo 0)"
    [[ "$wlasne" != "0" ]] && info "  własnych commitów: $wlasne"
    if [[ "$z_tylu" != "0" ]]; then
        uwaga "  jesteś $z_tylu commitów za $baza — sprawdź bezpiecznie: sesja.sh proba"
    fi
}

# ---------------------------------------------------------------------------
# SAMOKONTROLA — „czy to w ogóle działa"
# ---------------------------------------------------------------------------
# Odpowiada na pytanie, które pada zaraz po wdrożeniu: skąd mam wiedzieć, że
# jest dobrze, bez czekania na kolejną kolizję.
cmd_sprawdz() {
    local bledy=0

    info "1. Izolacja katalogów roboczych"
    local ile
    ile="$(git -C "$GLOWNE" worktree list | wc -l | tr -d ' ')"
    ok "   worktree w repozytorium: $ile"

    info "2. Blokada tej samej gałęzi w dwóch miejscach"
    local tmp="$BAZA/.kamar-test-blokady"
    local biezaca
    biezaca="$(git -C "$GLOWNE" rev-parse --abbrev-ref HEAD)"
    if git -C "$GLOWNE" worktree add "$tmp" "$biezaca" >/dev/null 2>&1; then
        blad "   BLOKADA NIE DZIAŁA — udało się wypożyczyć „$biezaca” drugi raz"
        git -C "$GLOWNE" worktree remove "$tmp" --force >/dev/null 2>&1 || true
        bledy=$((bledy + 1))
    else
        ok "   git odmawia wypożyczenia zajętej gałęzi — działa"
    fi

    info "3. Wspólna pamięć agentów"
    local baza_projektow="$HOME/.claude/projects"
    local klucz_glowny
    klucz_glowny="$(printf '%s' "$GLOWNE" | tr '/_' '--')"
    if [[ -d "$baza_projektow/$klucz_glowny" ]]; then
        local podpiete=0
        while IFS= read -r sc; do
            [[ "$(basename "$sc")" == "$PREFIKS-"* ]] || continue
            local k
            k="$(printf '%s' "$sc" | tr '/_' '--')"
            [[ -L "$baza_projektow/$k" ]] && podpiete=$((podpiete + 1))
        done < <(git -C "$GLOWNE" worktree list --porcelain | awk '/^worktree /{print substr($0,10)}')
        ok "   sesji z podpiętą pamięcią: $podpiete"
    else
        uwaga "   główny projekt nie ma jeszcze katalogu pamięci — nic do podpięcia"
    fi

    info "4. Herdr"
    if command -v herdr >/dev/null 2>&1; then
        ok "   dostępny ($(herdr --version 2>/dev/null | head -1))"
        local agenci
        agenci="$(herdr agent list 2>/dev/null | grep -o '"cwd":"[^"]*"' | sed 's/"cwd":"//;s/"//' | sort -u || true)"
        if [[ -n "$agenci" ]]; then
            info "   agenci pracują w:"
            echo "$agenci" | sed 's/^/     /'
            local ilu
            ilu="$(echo "$agenci" | wc -l | tr -d ' ')"
            local unikalnych
            unikalnych="$(echo "$agenci" | sort -u | wc -l | tr -d ' ')"
            if [[ "$ilu" != "$unikalnych" ]]; then
                blad "   DWÓCH AGENTÓW W TYM SAMYM KATALOGU — to jest ten problem"
                bledy=$((bledy + 1))
            fi
        fi
    else
        uwaga "   brak w PATH — sesje powstaną, ale nie otworzą się w oknie"
    fi

    echo
    if [[ "$bledy" -eq 0 ]]; then
        ok "Wszystko sprawdzone — izolacja działa."
    else
        blad "Problemów: $bledy"
        exit 1
    fi
}

case "${1:-start}" in
    start|"") cmd_start ;;
    nowa)     shift; cmd_nowa "$@" ;;
    proba)    cmd_proba ;;
    sprawdz)  cmd_sprawdz ;;
    lista)    cmd_lista ;;
    sprzataj) cmd_sprzataj ;;
    gdzie)    cmd_gdzie ;;
    *)
        cat <<POMOC
Izolacja sesji roboczych (git worktree)

  sesja.sh                       ANKIETA — pyta o bazę, nazwę i agenta (domyślne)
  sesja.sh nowa <nazwa>          bez pytań: gałąź sesja/<nazwa> od origin/stage
  sesja.sh nowa <nazwa> prod     bez pytań: gałąź hotfix/<nazwa> od origin/prod
  sesja.sh lista          pokaż wszystkie katalogi robocze i kto w nich siedzi
  sesja.sh sprzataj       usuń worktree bez zmian i bez własnych commitów
  sesja.sh gdzie          w którym worktree jesteś, od czego odbity i ile zaległości
  sesja.sh proba          czy dociągnięcie bazy da konflikt (niczego nie zmienia)
  sesja.sh sprawdz        sprawdź, czy izolacja naprawdę działa

POMOC
        ;;
esac
