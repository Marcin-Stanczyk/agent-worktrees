# agent-sesje

**Jeden agent, jeden katalog roboczy.** Narzędzie do izolowania równoległych sesji
pracy nad tym samym repozytorium — własne dla każdego projektu, nie tylko dla
jednego.

```bash
git clone git@github.com:Marcin-Stanczyk/agent-sesje.git
cd agent-sesje && ./install.sh
```

Potem `sesja` z wnętrza **dowolnego** repozytorium git.

---

## Co poszło nie tak 29.07.2026

Dwóch agentów pracowało w **jednym katalogu roboczym**. Commit jednego wciągnął
niezacommitowane pliki drugiego, a rebase przepisał hashe już wypchniętych
commitów. Moduł Finanse ocalał tylko dlatego, że ktoś to w porę zauważył —
istniał wyłącznie w gałęzi, którą za chwilę miałem skasować.

To nie była niczyja nieuwaga. Przy jednym katalogu roboczym `git add` **nie ma
jak** odróżnić moich plików od cudzych — widzi jeden indeks.

## Rozwiązanie: `git worktree`

Jedno repozytorium (wspólne obiekty i refy), ale **wiele niezależnych katalogów
roboczych**, każdy z własnym checkoutem i własnym indeksem.

Kluczowe: git **nie pozwoli** wypożyczyć tej samej gałęzi do dwóch worktree
naraz. To wbudowana blokada, nie nasza konwencja — nie da się jej przypadkiem
obejść.

### Czego worktree NIE załatwia

Obiekty i refy są wspólne, więc `rebase`, `commit --amend` i `push --force`
na **wypchniętej** gałęzi nadal popsują pracę drugiej osoby. Worktree chroni
katalog roboczy, nie historię. Stąd druga zasada, już ludzka: **nie przepisujemy
historii tego, co poszło na zdalne repo**.

## Codzienne użycie

```bash
sesja.sh nowa finanse   # własny katalog + gałąź sesja/finanse
sesja.sh lista          # kto gdzie siedzi
sesja.sh gdzie          # w której sesji jestem
sesja.sh sprawdz        # czy izolacja naprawdę działa
sesja.sh sprzataj       # usuń nietknięte worktree sesyjne
```

`sprzataj` rusza **wyłącznie** katalogi z prefiksem sesji i tylko takie, które
nie mają ani zmian, ani własnych commitów. Bez tego ograniczenia potrafiło
skasować cudze worktree razem z gałęziami — sprawdzone boleśnie 29.07.2026.

Każda sesja startuje od świeżego `origin/stage`. Odbicie od lokalnej gałęzi
zaciągnęłoby cudze niezacommitowane decyzje i praca zaczynałaby się od stanu,
którego nikt nie zna.

## Herdr robi to natywnie

Herdr (`herdr 0.7.5`) to menedżer przestrzeni roboczych **dla agentów AI** i ma
własne polecenia `worktree` oraz `agent`. Widzi każdy worktree tego repozytorium
— także utworzony spoza niego — i pokazuje przy agentach ich `cwd` oraz status.

```bash
herdr worktree list     # wszystkie katalogi robocze
herdr agent list        # kto gdzie pracuje i w jakim stanie
herdr worktree create --branch sesja/finanse --base origin/stage
```

Dlatego `sesja.sh nowa` **oddaje tworzenie Herdrowi**, gdy jest dostępny —
inaczej katalog by powstał, ale nie otworzyłby się w oknie. Sam skrypt dokłada
dwie rzeczy, których Herdr nie robi: bazuje zawsze na świeżym `origin/stage`
i podpina wspólną pamięć agentów (niżej).

## Pułapka: agenty traciły pamięć

Claude Code trzyma historię i pamięć projektu w katalogu nazwanym od **ścieżki**
(`~/.claude/projects/-Users-marcin-...`). Każdy worktree ma inną ścieżkę, więc
bez dodatkowego kroku agent w nowej sesji startuje z **pustą pamięcią**: nie
widzi `MEMORY.md` ani ustaleń z poprzednich rozmów.

To najgorszy rodzaj izolacji — chcieliśmy rozdzielić pliki, a rozdzieliliśmy
wiedzę. `sesja.sh nowa` zakłada więc dowiązanie katalogu pamięci sesji do
katalogu głównego repozytorium. Sprawdzisz to przez `sesja.sh sprawdz`.

## Jedno hasło: `sesja`

Dopisz do `~/.zshrc`. Od tego momentu `sesja` uruchamia ankietę **z dowolnego
katalogu** — skrypt sam znajduje repozytorium po własnym położeniu.

```zsh
export KAMAR_REPO="$HOME/code/_my_projects/kamar"

sesja() {
    local skrypt="$KAMAR_REPO/sesja.sh"
    case "${1:-start}" in
        start|"")
            # Skrypt nie zmieni katalogu powłoki rodzica — to ograniczenie
            # procesów, nie niedoróbka. Dlatego oddaje nam ścieżkę i agenta,
            # a `cd` robimy tutaj. Dzięki temu po wyjściu z agenta zostajesz
            # w katalogu sesji, zamiast wracać tam, skąd startowałeś.
            local wynik katalog agent
            wynik="$(SESJA_WRAPPER=1 "$skrypt" start)" || return 1
            katalog="${wynik%%$'\t'*}"
            agent="${wynik##*$'\t'}"
            cd "$katalog" || return 1
            [[ "$agent" == "sama powłoka" ]] && return 0
            "$agent"
            ;;
        *) "$skrypt" "$@" ;;
    esac
}
```

Przeładuj: `source ~/.zshrc`.

### Jak to wygląda

```
$ sesja

Od czego odbić sesję?
   1) stage — praca bieżąca
   2) prod — HOTFIX na produkcję
   wybór [1]:

Nazwa sesji (katalog, gałąź i okno dostaną tę samą)
   nazwa: platnosci

Którego agenta uruchomić?
   1) claude
   2) gemini
   3) copilot
   4) sama powłoka
   wybór [1]:

Do zatwierdzenia:
   gałąź:    sesja/platnosci
   baza:     origin/stage
   katalog:  .../kamar-sesja-platnosci
   agent:    claude
   Enter = tak, cokolwiek innego = przerwij:
```

Enter — i jesteś w nowym katalogu z uruchomionym agentem.

Menu jest w czystym bashu: `gum`, `fzf` ani `whiptail` nie są potrzebne.
Domyślnego agenta zmienisz wpisem `agent = gemini` w `.sesje.conf` w korzeniu
repozytorium (plik jest parsowany ściśle, nie `source`'owany).

Pozostałe polecenia działają bez zmian: `sesja lista`, `sesja gdzie`,
`sesja proba`, `sesja sprzataj`, `sesja nowa <nazwa> [prod]` — to ostatnie
pomija ankietę, gdy wiesz, czego chcesz.

### Wyjścia awaryjne

- `KAMAR_BEZ_SESJI=1` w danym oknie — wyłącza automat (np. do operacji na
  samym repozytorium: `git worktree prune`, porządki w gałęziach).
- `kamar sprzataj` — usuwa worktree **bez zmian i bez własnych commitów**.
  Katalog z niezacommitowaną pracą nigdy nie zostanie ruszony.

## Zasady, których worktree nie wymusi za nas

1. **Jedna gałąź = jedna sesja.** Nigdy współdzielona.
2. **Nigdy `git add -A` ani `git commit -a`** — zawsze jawne ścieżki. To
   właśnie dzięki temu feralny commit dało się rozdzielić.
3. **Żadnego przepisywania historii** na tym, co wypchnięte.
4. **Kontrakt w kodzie bije protokół w pamięci.** Tamtego dnia druga osoba
   zarejestrowała pozycję menu warunkowo, na
   `function_exists('kamar_render_finance_page')`. Jej kod działał niezależnie
   od tego, czy mój już istnieje — i nie wymagał żadnej koordynacji.
