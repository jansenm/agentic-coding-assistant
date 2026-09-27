# Review — `9dbfc00`, `935cf92`, `85daad9`

Datum: 2026-09-25. Gegengeprüft gegen den Baum im Worktree
`agentic-coding-assistant-mjansen`.

**Bereich:** `dev/mjansen` — `935cf92` und `9dbfc00` (beide inzwischen auf
`devel`) plus der Branch-Commit `85daad9`. `devel` selbst wurde nicht
angefasst.

**Grenze:** `devel` ist die Hauptentwicklung; fremde Historie wird nicht
umgeschrieben. Korrekturen an einem bereits gelandeten Commit gehen als
Folge-Commit in den eigenen Branch, nicht als `--amend` auf `devel`.
Umgeschrieben wird nur der eigene, noch nicht gelandete WIP-Commit.

**Status:** Freigabe erteilt. `9dbfc00` bleibt. `85daad9` bleibt (nur die
Message wurde vor dem Landen korrigiert). `935cf92` bleibt in der
Historie; die Korrektur dazu steht in `6ee2fab` (Folge-Commit in
`dev/mjansen`, Text only).

Diese Datei ist der Review-Record für `dev/mjansen` und in diesem Branch
getrackt — damit der Befund nicht wieder nur im Arbeitsbaum lebt. Sie
wird mit dem `docs/Makefile`-Fix zusammen committet. Ob sie mit dem
Branch auch auf `devel` landen soll, ist eine eigene Entscheidung: die
Konsolidierung `935cf92` hat die Review-Dokumente bewusst entfernt. Das
hier ist deren Nachfolger, nicht ihre Rückkehr.

> **Nachtrag 2026-09-25 (Rebase).** `dev/mjansen` ist kurz nach diesem
> Record auf `devel` neu aufgesetzt worden — `devel` war von `935cf92`
> auf **`1b78de4`** („the task tool — subagents return a summary")
> weitergezogen, und `dev/mjansen` ist dem gefolgt. Jeder Hash **im
> Fließtext** dieses Dokuments ist damit historisch: er benennt den
> Commit, wie er zum Review-Zeitpunkt hieß. Er heiße jetzt:
>
> | vorher (Text) | jetzt |
> | --- | --- |
> | `85daad9` | `78da98e` |
> | `6ee2fab` | `d58a681` |
> | `b4f6351` | `cc9cebf` |
> | `423cd0d` | `9e8ab6a` |
> | `09e2077` | `dad6c18` |
> | `81be63a` | `756576b` |
>
> `935cf92` und `9dbfc00` sind unverändert (sie liegen auf `devel`).
> Kein Finding ändert sich dadurch. Die **Trees der sechs Commits** sind
> unverändert — belegt: das Code-Patch von `756576b` (`lib/` + `test/`)
> ist zeichengleich mit dem von `81be63a`, nur die Hunk-Offsets
> verschieben sich. Was sich ändert, ist der Boden darunter: `devel` und
> damit `1b78de4` liegt jetzt unter dem Branch, und zwei Dateien tragen
> das Ergebnis der Konfliktauflösung — `TODO.md` (die `Stand`-Zeile) und
> `docs/source/decisions/018-agent-ui-display.rst`, wo beide Seiten einen
> Anhang an dasselbe Dateiende geschrieben hatten und jetzt **beide**
> Amendments stehen (das `task`-Seam-Amendment aus `1b78de4` und das
> Sidebar-Amendment aus `756576b`). Abschnitt 5 nennt die neuen Hashes.

---

## 1. `9dbfc00` — fix(ui): the paused dialog survives a late reply (ADR 027)

Die Analyse trägt. Umsetzung gegen den Baum geprüft — die Zeilenangaben
sind auf den **heutigen** Baum gezogen (Seam + Sidebar-Neugliederung
haben `tui.ex` verschoben); zum Review-Zeitpunkt lagen sie um ~5-20
Zeilen weiter oben (siehe Nachtrag):

- Die drei `{:ok, _}`-Reply-Handler sind tatsächlich No-Ops
  (`tui.ex:2357`, `:2370`, `:2384` — `handle_info` für `__budget_decided__`,
  `__doom_decided__`, `__question_answered__`).
- Alle drei Fehlerpfade laufen über
  `note_failure(resync_prompt(state, kind), …)` (`tui.ex:2365`, `:2375`,
  `:2389`); `resync_prompt/2` (`tui.ex:2818`) fängt `:exit` ab — eine tote
  Session nimmt die TUI nicht mit `:noproc` mit.
- `finish_wrap_up/1` (test_mode) broadcastet jetzt `:idle`
  (`session.ex:1765`) — konsistent mit `complete_turn/3`.
- `pending: []` wird bei den Pause-Broadcasts gesetzt (`tui.ex:2457`,
  `:2481`, `:2496`, `:2519`); `pause_label/1` (`tui.ex:3617`) ist da.
- Backspace: `String.slice(buf, 0..-2//1)` (`tui.ex:1527`) — greift nur im
  Nicht-`""`-Zweig, korrekt.
- Keine Flakes: volle Läufe mit `--seed 0/1/2/3` und zufälligen Seeds →
  jeweils grün — zum Review-Zeitpunkt **849**, nach dem Rebase auf
  `1b78de4` **870** (der Seam bringt eigene Tests mit).

**Freigabe: kann so bleiben.** Zwei Anmerkungen, keine Blocker:

1. **Der Approval-Reply ist als einziger nicht auf No-Op umgestellt.**
   `handle_info({:__decided__, {:ok, status}}, state)` (`tui.ex:2341`)
   schreibt weiterhin `status` und `pending` aus der Antwort. Nach der im
   Commit selbst formulierten Regel („die Broadcasts sind die Autorität")
   ist das die letzte Stelle, an der ein verspäteter Reply frischen
   Zustand überschreiben kann. In den erreichbaren Ordnungen ist der
   Reply-Status identisch mit dem Endzustand des Workers, also praktisch
   unauffällig — aber die Inkonsistenz bleibt. Entweder gleicher No-Op
   oder ein Kommentar, warum Approval bewusst anders ist.
   *Offen, Code.*
2. `open_pause/3` (`tui.ex:2838`, `:2845`, `:2852`) ist dreimal dieselbe
   Form mit einem anderen Prompt-Feld. Nach der Duplikat-Regel im
   `AGENTS.md` könnte das eine Funktion mit Feldnamen-Mapping sein.
   Kosmetisch. *Offen, Code.*

---

## 2. `935cf92` — docs: consolidate the backlog into TODO.md

Inhaltlich richtig, die Konsolidierung selbst sauber: alle 8 ADR-/
Glossary-Querverweise zeigen jetzt auf `TODO.md`
(`017`, `022`, `024`, `025`, `026`, `027` ×2, `029`,
`docs/source/glossary.rst`), `exqlite` steht in `mix.exs`, der Store IST
die SQLite-Engine (`lib/coding_agent/core/session/store.ex`, Migrationen
v1/v2, `PRAGMA user_version`). Die ROADMAP-Korrekturen sind korrekt
(`ROADMAP.md:50`, `:395`, `:405`, `:415`, `:502`).

Fünf Punkte gegen die Message-Behauptungen: drei Korrekturen (1, 3, 4)
stehen in `6ee2fab`, einer (2) hat sich erledigt, einer (5) ist bewusst
so gelassen. Der gelandete Commit selbst wurde in keinem Fall angefasst.

1. **„Vier Dokumente gelöscht" stimmt nicht.** `git show --name-status`
   zeigt nur `D code_review.md` und `D ui_redesign.md`. `übersicht.md`
   und `frage-tool-befund.md` waren nie im Git
   (`git log --all --reflog --diff-filter=AD -- 'übersicht.md'
   'frage-tool-befund.md'` → leer, auch in keinem Dangling-WIP-Commit).
   Die Message beschreibt den Arbeitsbaum, nicht die Historie.
   *Erledigt: die Aussage steht in `6ee2fab` richtig (zwei getrackte,
   zwei untracked) — die Formulierung in `935cf92` bleibt als das, was
   sie war: eine Ungenauigkeit in einem gelandeten Commit.*
2. **„sphinx builds clean" stimmt — nur war der Bootstrap-Pfad kaputt.**
   Siehe Abschnitt 4: `cd docs && make html` → `build succeeded.` Der
   frühere Fehlschlag kam aus dem System-`python3` statt aus dem venv
   (das noch nicht existierte), nicht vom Repo. *Die Aussage selbst ist
   also eingelöst; der kalte Bootstrap war der eigentliche Fund — siehe
   `docs(makefile)` in Abschnitt 4.*
3. **„Every claim was re-verified against the tree" hat mindestens eine
   Ausnahme.** `TODO.md` (Struktur & Kosmetik) nannte
   `mount_picker ~180` / `mount_session ~315` Zeilen; gemessen sind es
   **114** und **217** (`tui.ex` Zeilen 180–296 und 315–531). Die
   Gesamtzahl „~4360 Zeilen" stimmt (4356). *Erledigt in `6ee2fab`.*
4. **O3 ist mit dem WIP-Commit darunter schon teilweise erledigt.**
   `TODO.md` forderte „Sidebar-Werte rechtsbündig (Padding im `Paragraph`
   oder echte `Table`)" — `85daad9` richtet sie punktausgerichtet aus,
   also die halbe Forderung. *Erledigt in `6ee2fab`.*
5. Kleinigkeit, bewusst **nicht** geändert: `TODO.md` ist als einziges
   Dokument im Repo deutsch (ROADMAP, ADRs, Glossary sind englisch), und
   die beiden untracked Dateien werden in der Kopfnote weiter namentlich
   genannt. Wenn die Nachvollziehbarkeit gewollt ist, ist beides in
   Ordnung.

---

## 3. `85daad9` — feat(ui): the sidebar's token values align on the decimal point

`Styles.definition_list/2` nimmt `{:decimal, number, suffix}`: der
Ganzzahl-Teil wird auf den breitesten der Liste gepolstert, Dezimalteil
und Suffix folgen ungepolstert. Die vier Token-Zeilen der Sidebar nutzen
es (`tui.ex:3693-3697` im Tree von `78da98e`; nach der Sidebar-
Neugliederung `756576b` stehen sie in `tui.ex:3746-3749`, `session`/`effort`
in eigenen Blöcken), `session`/`effort` bleiben Text, eine Liste ohne
Decimal-Wert hat keine Zahlenspalte.

    tokens in:      0
    tokens out:  10.0k
    context:    480.0k (96% win)
    compacts at: 180.0k tok

Korrektur vor dem Landen, die ich selbst gemacht habe: die erste Message
behauptete vier Beispielzeilen („0", „10.0k", „480.0k (96% win)",
„180.0k tok") — das ist aber keine Sidebar-Ausgabe, sondern das
Formatierungsbeispiel von `context`. Kein Zahlenfehler, aber ein Beispiel,
das so nicht gerendert wird. Der Commit ist inzwischen neu getextet
(Hash `85daad9`, gleicher Tree wie vorher) und beschreibt jetzt die
**vier** Sidebar-Zeilen. Tests: zwei neue in `styles_test.exs` (17 statt
15 Tests in der Datei, 849 statt 847 insgesamt).

Verifiziert: `mix format --check-formatted`, `MIX_ENV=test mix compile
--warnings-as-errors`, `mix test` → **849 grün** (auch `--seed 0/1/2/3`).

---

## 4. Dokumentation — läuft jetzt

Der Review hatte notiert, `sphinx builds clean` sei nicht nachprüfbar.
Das war eine Aussage über **den Zustand des Arbeitsbaums**, nicht über
das Repo — und sie ist erledigt. Es lag an einer Verwechslung von venv
und Systemumgebung, nicht an `sphinxcontrib-mermaid` (das ist
installiert):

    cd docs && make html
    → writing additional pages... search done
    → build succeeded.
    → The HTML pages are in build/html.

- `docs/.venv` war zum Prüfzeitpunkt nicht da — es wurde am 2026-09-25 um
  13:36 gerade erst angelegt, also *nach* `935cf92` (12:46). Genau darum
  scheiterte der frühere Build: er lief gegen das System-`python3`, dem
  furo, mermaid, `sphinx_adr`, copybutton und opengraph fehlen. Das venv
  ist die Antwort, und es ist vollständig: Sphinx 9.1.0, furo,
  `sphinxcontrib_mermaid-2.1.0`, `sphinx_adr-0.4.0`,
  `sphinx_copybutton-0.5.2`, `sphinxext_opengraph-0.13.0`.
- Genau eine Warnung beim **ersten, vollständigen** Build (`-E` bzw.
  leerem Environment): `intersphinx` kann
  `https://docs.python.org/3/objects.inv` nicht auflösen — kein Netz in
  der Sandbox, `NameResolutionError`. Das ist kein Befund: der Build
  behandelt es als Warning, und in einer Umgebung mit Netz verschwindet
  sie. Danach meldet `make html` `build succeeded.` ohne Warning.
- Der Build braucht ein schreibbares Zielverzeichnis. `docs/build/`
  liegt **außerhalb** der Session-Scope und ist dort read-only
  (`findmnt`: `/home … btrfs ro`), im Branch-Worktree derselbe Pfad `rw`.
  Das ist die Sandbox-Abgrenzung, kein Repo-Defekt — mit einem expliziten
  Ziel (`.venv/bin/sphinx-build -b html source /tmp/docsout`) geht es
  überall.

**Die Aussage in `935cf92` ist damit eingelöst** und muss nicht korrigiert
werden — sie war zum Commit-Zeitpunkt in dieser Umgebung nur nicht
belegt (kein venv, kein Netz). `docs/howtos/build-docs` beschreibt den
Weg bereits.

Nebenbefund, gehört nicht zu diesem Commit: `docs/Makefile` hatte im
Branch-Worktree eine uncommittete Änderung — `$(SPHINXBUILD)::` bekommt
`$(SPHINXPYTHON)` als Voraussetzung. Sie ist **notwendig, nicht
kosmetisch**, und das ist mit `make -n` belegbar:

    # alt: Voraussetzung ist nur $(SPHINXBUILD)
    $ make html VIRTUALENV=/tmp/fresh
    /tmp/fresh: installing dependencies
    /tmp/fresh/bin/python3 -m pip install -r requirements.txt
    make: /tmp/fresh/bin/python3: No such file or directory
    make: *** [Makefile:29: /tmp/fresh/bin/sphinx-build] Error 127

    # neu: $(SPHINXPYTHON) ist Voraussetzung
    $ make html VIRTUALENV=/tmp/fresh
    echo "/tmp/fresh: setting up the virtual environment"
    python3 -m venv /tmp/fresh
    echo "/tmp/fresh: installing dependencies"
    /tmp/fresh/bin/python3 -m pip install -r requirements.txt
    /tmp/fresh/bin/sphinx-build -M html "source" "build"

`setup-venv` → `install-deps` ist eine Kette, aber `$(SPHINXBUILD)::`
hatte nur `$(SPHINXBUILD)` als Eingang: der Install-Schritt lief, bevor
das venv existierte. Ein kalter Checkout konnte `make html` deshalb nie
bauen — der Docstring im `requirements.txt` sagt `python3 -m venv .venv`
explizit als Handgriff davor. Der Fix steht als eigener Commit unter
diesem (`docs(makefile): a cold checkout can build the docs`), verifiziert
mit `make -n html` gegen ein leeres `VIRTUALENV` und einem echten
`make html` in `docs/`.

---

## 5. Was als Commit draus geworden ist

Nach dem Rebase (Nachtrag oben) heißen die Commits des Branch so:

```
756576b feat(ui): the sidebar is three blocks, headed by the scope  (dev/mjansen)
dad6c18 review: correct my own stale bits in the record             (dev/mjansen)
9e8ab6a review: the record for 9dbfc00, 935cf92 and 85daad9         (dev/mjansen)
cc9cebf docs(makefile): a cold checkout can build the docs          (dev/mjansen)
d58a681 docs(todo): the two stale line counts and O3's done half    (dev/mjansen)
78da98e feat(ui): the sidebar's token values align on the decimal point (dev/mjansen)
1b78de4 feat(agents): the task tool — subagents return a summary    (devel)
935cf92 docs: consolidate the backlog into TODO.md, ROADMAP stays the plan (devel)
```

Vorher (zum Review-Zeitpunkt) hießen dieselben Commits `423cd0d`,
`b4f6351`, `6ee2fab`, `85daad9`, `09e2077`; die Zuordnung steht in der
Tabelle im Nachtrag. Der Baum des jeweiligen Commits ist unverändert.

`d58a681` (nur Text, 1 Datei, +8/−4): die zwei Zeilenmaße korrigiert (P4),
O3 in „punktausgerichtet erledigt / rechtsbündig offen" geteilt, `Stand`-
Zeile von `9dbfc00` auf `935cf92` gezogen.

`cc9cebf` (eine Zeile im `docs/Makefile`): macht den Bootstrap-Pfad
gangbar (siehe Abschnitt 4) — der eigentliche Fund hinter „sphinx builds
clean". Verifiziert mit `make -n html` gegen ein leeres `VIRTUALENV` und
einem echten `make html` in `docs/`.

`9e8ab6a` ist dieser Text. `devel` steht inzwischen auf `1b78de4` (dem
`task`-Seam, der nach diesem Record gelandet ist); die sechs Commits des
Branch liegen nur auf `dev/mjansen` und sitzen jetzt direkt darauf.

## 6. Offen

Code, nicht Text — bewusst nicht angefasst:

- Approval-Reply (`tui.ex:2341`) auf No-Op oder Kommentar (Abschnitt 1.1).
- `open_pause/3` entdoppeln (Abschnitt 1.2).

Text, offen auf Ansage:

- `935cf92`s „Vier Dokumente gelöscht" steht so noch in der `devel`-
  Historie; wenn das dort auch sichtbar korrigiert werden soll, braucht es
  dieselbe Art Folge-Commit wie `d58a681`.
- `review.md` selbst: ob dieser Record auf `devel` soll, ist eine
  Produktentscheidung, keine Frage der Richtigkeit. `935cf92` hat die
  Review-Dokumente bewusst entfernt; dann sollte die Einordnung „einmalig
  für diesen Branch" irgendwo stehen, sonst wächst hier `code_review.md`
  wieder nach.
