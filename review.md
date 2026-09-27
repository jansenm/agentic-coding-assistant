# Review — `9dbfc00`, `935cf92`, `85daad9` (und `f830a8f`, Abschnitt 7)

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
Historie; die Korrektur dazu steht in `6ee2fab` (heute `e2c8955`;
Folge-Commit in `dev/mjansen`, Text only).

Diese Datei ist der Review-Record für `dev/mjansen` und in diesem Branch
getrackt — damit der Befund nicht wieder nur im Arbeitsbaum lebt. Sie
wird mit dem `docs/Makefile`-Fix zusammen committet. Ob sie mit dem
Branch auch auf `devel` landen soll, ist eine eigene Entscheidung: die
Konsolidierung `935cf92` hat die Review-Dokumente bewusst entfernt. Das
hier ist deren Nachfolger, nicht ihre Rückkehr.

Dieses Dokument trägt inzwischen **zwei** Reviews: die Abschnitte 1–6 zu
`9dbfc00`/`935cf92`/`85daad9` und — eingefaltet statt als eigene Datei
daneben — Abschnitt 7 zu `f830a8f` („subagent tabs, parallel delegation",
ADR 018 Teil 2), dem Commit, der `devel` unter den Branch geschoben hat.

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
> **Nachtrag 2026-09-27 (zweiter Rebase, auf `f830a8f`).** `devel` ist
> danach noch einmal weitergezogen — von `1b78de4` auf **`f830a8f`**
> („subagent tabs, parallel delegation", ADR 018 Teil 2) — und
> `dev/mjansen` ist erneut gefolgt. Die sechs Branch-Commits haben damit
> ein **zweites Mal** neue Hashes bekommen. Beide Spalten, damit die
> Zuordnung eindeutig bleibt:
>
> | vorher (Text) | nach dem 1. Rebase | heute |
> | --- | --- | --- |
> | `85daad9` | `78da98e` | `89ced6b` |
> | `6ee2fab` | `d58a681` | `e2c8955` |
> | `b4f6351` | `cc9cebf` | `75ec6df` |
> | `423cd0d` | `9e8ab6a` | `45d73ac` |
> | `09e2077` | `dad6c18` | `1751b53` |
> | `81be63a` | `756576b` | `6fa1b3b` |
>
> Dazu kommt der Record-Commit selbst: was als `9003cd8` geschrieben und
> committet wurde (der erste Rebase-Text), ist beim zweiten Rebase zu
> **`c53e427`** geworden. `935cf92`, `1b78de4` und `9dbfc00` liegen
> unverändert auf `devel` — die Spalte „heute" ist also nur für die sechs
> Branch-Commits eine andere.
>
> Kein Finding ändert sich dadurch. Die **Code-Patches** sind über beide
> Rebases hinweg zeichengleich, und das ist jetzt reproduzierbar belegt
> (md5 über die reinen `+`/`-`-Zeilen des Patches, ohne Datei- und
> Hunk-Köpfe, also ohne die wechselnden Offsets):
>
>     81be63a -> 756576b -> 6fa1b3b   52888e8394   (6 Dateien, +258/−67)
>     85daad9 -> 78da98e -> 89ced6b   34b028bf53   (3 Dateien,  +98/−28)
>
> Was sich ändert, ist der Boden darunter und — beim zweiten Rebase —
> mehr als beim ersten: dort war genau eine Datei betroffen (`TODO.md`),
> hier drei (`TODO.md`, `ROADMAP.md`,
> `docs/source/decisions/018-agent-ui-display.rst`), weil `f830a8f`
> dieselben drei Dokumente angefasst hat wie der Branch. Abschnitt 5
> nennt die neuen Hashes; Abschnitt 7 ist das Review zu `f830a8f`.
>
> **Anker-Regel (neu, ab hier).** Der zweite Rebase hat die eine Schwäche
> dieses Records sichtbar gemacht: Er beschreibt den Baum mit
> **Zeilennummern**, und jede Bewegung darunter macht sie falsch — genau
> das ist F6 in Abschnitt 7. Darum gilt jetzt:
> Zeilenangaben stehen nur noch, wo sie ausdrücklich *historisch* gemeint
> sind („im Tree von `935cf92`/`78da98e`"); Aussagen über einen
> **heutigen** Baum nennen den **Namen** (`resync_prompt/2`,
> `open_pause/3`, die Token-Zeilen in `sidebar_widget/1`) und dazu den
> Commit, auf dem gemessen wurde. Ein Name bleibt gültig, eine Zeile
> nicht. Abschnitte 1 und 3 sind gegen den Tree von `6fa1b3b` gerechnet —
> dem jüngsten Branch-Commit vor dem Doku-Commit `c53e427`. Er ist der
> einzige Punkt in der Tabelle, an dem sich der Blob von `tui.ex`
> (`e224f5a…`) gegenüber seinem Vorgänger wirklich bewegt: er trägt jetzt
> `f830a8f`s 433 Zeilen Tab-Code unter unserem 4-Zeilen-Patch. Ab dort
> sind `tui.ex` und `session.ex` bis HEAD zeichengleich. Die Zeilennummern
> in den Abschnitten 1 und 3 sind also Beispiele der *heutigen* Stelle,
> nicht ihr Name.

---

## 1. `9dbfc00` — fix(ui): the paused dialog survives a late reply (ADR 027)

Die Analyse trägt. Umsetzung gegen den Baum geprüft. Die Zeilenangaben
unten sind historisch und stehen für **zwei** Bäume: den nach dem ersten
Rebase (`756576b`, damals „heute") und den heutigen (`6fa1b3b`/HEAD;
der zweite Rebase hat keine Konfliktauflösung in `tui.ex` oder
`session.ex` gebraucht, die Dateien sind ab `6fa1b3b` bis HEAD
zeichengleich). Was der Befund jeweils meint, steht als **Name** daneben
— der überlebt den nächsten `devel`-Commit, die Zeile nicht:

| was | `756576b` | heute |
| --- | --- | --- |
| die drei `{:ok, _}`-No-Ops (`__budget_decided__`, `__doom_decided__`, `__question_answered__`) | `tui.ex:2357/2370/2384` | `tui.ex:2436/2449/2463` |
| die drei Fehlerpfade, alle über `note_failure(resync_prompt(state, kind), …)` | `tui.ex:2365/2375/2389` | `tui.ex:2443/2453/2467` |
| `resync_prompt/2` (fängt `:exit` ab) | `tui.ex:2818` | `tui.ex:2940` |
| `finish_wrap_up/1`, test_mode-Klausel broadcastet `:idle` | `session.ex:1765` | `session.ex:1794` |
| `pending: []` bei den Pause-Broadcasts | `tui.ex:2457/2481/2496/2519` | `tui.ex:2553/2577/2592/2615` |
| `pause_label/1` | `tui.ex:3617` | `tui.ex:3919` |
| Backspace, `String.slice(buf, 0..-2//1)` | `tui.ex:1527` | `tui.ex:1535` |
| Approval-Reply `handle_info({:__decided__, {:ok, status}}, …)` | `tui.ex:2341` | `tui.ex:2420` |
| `open_pause/3`, dreimal dieselbe Form | `tui.ex:2838/2845/2852` | `tui.ex:2960/2967/2974` |

- Keine Flakes: volle Läufe mit `--seed 0/1/2/3` und zufälligen Seeds →
  jeweils grün — zum Review-Zeitpunkt **849**, nach dem ersten Rebase
  (auf `1b78de4`) **870**, nach dem zweiten (auf `f830a8f`) **879** (der
  Seam und die Tab-Slice bringen eigene Tests mit).

**Freigabe: kann so bleiben.** Zwei Anmerkungen, keine Blocker:

1. **Der Approval-Reply ist als einziger nicht auf No-Op umgestellt.**
   `handle_info({:__decided__, {:ok, status}}, state)` (heute
   `tui.ex:2420`) schreibt weiterhin `status` und `pending` aus der
   Antwort. Nach der im Commit selbst formulierten Regel („die Broadcasts
   sind die Autorität") ist das die letzte Stelle, an der ein verspäteter
   Reply frischen Zustand überschreiben kann. In den erreichbaren
   Ordnungen ist der Reply-Status identisch mit dem Endzustand des
   Workers, also praktisch unauffällig — aber die Inkonsistenz bleibt.
   Entweder gleicher No-Op oder ein Kommentar, warum Approval bewusst
   anders ist. *Offen, Code.*
2. `open_pause/3` (`tui.ex:2960/2967/2974`) ist dreimal dieselbe
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
(`ROADMAP.md:50`, `:395`, `:405`, `:415`, `:502` — das sind die Stellen
in **`935cf92` selbst**, wo der Commit sie gesetzt hat; auf dem heutigen
`devel` liegen dieselben fünf Zeilen bei `:50`, `:402`, `:412`, `:422`,
`:509`, Text jeweils zeichengleich).

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
   **114** und **212**. *Erledigt in `6ee2fab`.*
   *Korrektur 2026-09-27:* hier stand ursprünglich **217** — die
   `mount_session`-Spanne ist 212, nachgerechnet auf allen Bäumen
   (`935cf92`: 180–293/315–526; `78da98e`: 180–298/320–538; `f830a8f`:
   186–307/329–548). Die Zahl des Folge-Commits `d58a681` (`~114, ~212`)
   war die richtige; falsch war dieser Record. Details in Abschnitt 7 (F6).
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
es (`tui.ex:3693-3697` im Tree von `85daad9`, so wie der Commit gelandet
ist; im Tree von `78da98e` 3755-3758; nach der Sidebar-Neugliederung
`756576b` 3746-3749, `session`/`effort` in eigenen Blöcken; auf dem
heutigen Baum stehen sie unverändert in `sidebar_widget/1`,
`tui.ex:4089-4092`), `session`/`effort` bleiben Text, eine Liste ohne
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

Nach dem **zweiten** Rebase (Nachtrag oben) heißen die Commits des Branch
so — die dritte Spalte der Nachtrag-Tabelle ist diese Liste:

```
6fa1b3b feat(ui): the sidebar is three blocks, headed by the scope  (dev/mjansen)
1751b53 review: correct my own stale bits in the record             (dev/mjansen)
45d73ac review: the record for 9dbfc00, 935cf92 and 85daad9         (dev/mjansen)
75ec6df docs(makefile): a cold checkout can build the docs          (dev/mjansen)
e2c8955 docs(todo): the two stale line counts and O3's done half    (dev/mjansen)
89ced6b feat(ui): the sidebar's token values align on the decimal point (dev/mjansen)
c53e427 docs: the review record and the ADR after the rebase onto devel (dev/mjansen)
f830a8f feat(ui): subagent tabs, parallel delegation (ADR 018 part 2)   (devel)
1b78de4 feat(agents): the task tool — subagents return a summary    (devel)
935cf92 docs: consolidate the backlog into TODO.md, ROADMAP stays the plan (devel)
```

Zum Review-Zeitpunkt hießen dieselben Commits `423cd0d`, `b4f6351`,
`6ee2fab`, `85daad9`, `09e2077` (nach dem ersten Rebase dann `9e8ab6a`,
`cc9cebf`, `d58a681`, `78da98e`, `dad6c18`); die Zuordnung steht in der
Tabelle im Nachtrag. **Sieben** Branch-Commits sind es jetzt, nicht
sechs: `c53e427` ist der Record-Commit selbst, der nach dem ersten Rebase
noch nicht existierte.

**Der Baum des jeweiligen Commits ist *nicht* unverändert** — hier stand
das vorher falsch, und es ist die einzige Stelle, an der die Rebases
etwas anderes als Adressen geändert haben. Unverändert ist der
**Code-Patch**: die `lib/`- und `test/`-Änderung ist über beide Rebases
hinweg zeichengleich (Beleg und Hashes im Nachtrag). Die **Trees**
unterscheiden sich, weil die Konfliktauflösung bei jeder Auflösung in
`TODO.md` und ADR 018 (beim zweiten Rebase zusätzlich `ROADMAP.md`)
Text neu schreibt. Wer also „ist doch derselbe Commit" sagen will, muss
den Patch meinen, nicht den Tree.

`e2c8955` (nur Text, 1 Datei, +8/−4): die zwei Zeilenmaße korrigiert (P4),
O3 in „punktausgerichtet erledigt / rechtsbündig offen" geteilt, `Stand`-
Zeile von `9dbfc00` auf `935cf92` gezogen. In dieser Datei steht die
dort gesetzte Zahl `~212` richtig; die falsche `217` stand hier
(Abschnitt 2, Punkt 3 — nachgezogen).

`75ec6df` (eine Zeile im `docs/Makefile`): macht den Bootstrap-Pfad
gangbar (siehe Abschnitt 4) — der eigentliche Fund hinter „sphinx builds
clean". Verifiziert mit `make -n html` gegen ein leeres `VIRTUALENV` und
einem echten `make html` in `docs/`. Dieser Commit liegt weiterhin
**nur** auf `dev/mjansen` (`git diff devel...HEAD` → `docs/Makefile`);
der `devel`-Stand hat ihn nicht, das ist eine Owner-Entscheidung, kein
Versäumnis des Branch.

`45d73ac` ist dieser Text (Review-Teil, Abschnitte 1–6). `c53e427` ist
der Rebase-Nachtrag dazu. `devel` steht inzwischen auf `f830a8f`;
`git rev-list --left-right --count devel...HEAD` → `0 7`. Abschnitt 7 ist
das Review zu `f830a8f` (eingefaltet statt als eigene Datei daneben); der
letzte Teil von Abschnitt 7 — „Was daraus als Commit werden sollte" —
nennt die Textliste, die aus ihm folgt, und **dieser** Commit löst sie
ein. Die Code-Findings F1–F4 daraus bleiben offen.

## 6. Offen

Code, nicht Text — bewusst nicht angefasst:

- Approval-Reply (`tui.ex:2420`) auf No-Op oder Kommentar (Abschnitt 1.1).
  Dasselbe Finding steht als F5 in Abschnitt 7; die Nicht-Anfassen-
  Entscheidung ist dort dieselbe.
- `open_pause/3` entdoppeln (`tui.ex:2960/2967/2974`, Abschnitt 1.2).

Text, offen auf Ansage:

- `935cf92`s „Vier Dokumente gelöscht" steht so noch in der `devel`-
  Historie; wenn das dort auch sichtbar korrigiert werden soll, braucht es
  dieselbe Art Folge-Commit wie `e2c8955`.
- `review.md` selbst: ob dieser Record auf `devel` soll, ist eine
  Produktentscheidung, keine Frage der Richtigkeit. `935cf92` hat die
  Review-Dokumente bewusst entfernt; dann sollte die Einordnung „einmalig
  für diesen Branch" irgendwo stehen, sonst wächst hier `code_review.md`
  wieder nach. (Abschnitt 7 kam auf dieselbe Frage zurück; sie ist
  weiterhin offen.)
- Die Code-Findings aus Abschnitt 7 (F1–F4) sind **nicht** angefasst —
  sie gehören dem Owner, und F1 ist ein belegter Crash-Pfad, nicht
  Kosmetik.

---

## 7. `f830a8f` (devel) — feat(ui): subagent tabs, parallel delegation (ADR 018 part 2)

Datum: 2026-09-27. Gegengeprüft gegen den Baum im Worktree
`agentic-coding-assistant-mjansen`, `dev/mjansen` auf `devel` @ `f830a8f`
rebased (HEAD `c53e427`).

**Bereich:** der auf `devel` neu gelandete Commit `f830a8f` (15 Dateien,
+879/−109) — sein Code, seine Tests, seine Doku-Anhänge (ADR 018
Amendment (ii), TODO/ROADMAP) und die Frage, ob die Branch-Commits
darunter noch stimmen.

**Grenze:** unverändert. `devel` wird nicht angefasst; Korrekturen gehen
als Folge-Commit in `dev/mjansen`. Findings hier sind *Text*, bis der
Owner über die Code-Punkte entscheidet.

**Kurzfassung:** die Slice ist sauber gebaut (Wire-Tagging, in-memory
Tab, Tab-Leiste/Cap, Parallel-Cap, esc-Weiterleitung), die ADR (ii)
beschreibt sie in allen sechs Schritten zutreffend, und die
„drei Seam-Fakten“ sind am Baum belegt. Vier Code-Punkte bleiben —
einer davon (F1) ist ein belegter Live-Crash-Pfad, drei sind Hygiene.
Dazu ein Befund außerhalb des Commits: **der Git-Editor**.

*Anker-Hinweis:* die Zeilenangaben in diesem Abschnitt sind auf
`f830a8f`/`c53e427` gerechnet, wo nicht anders gesagt; die
Symbol-Namen daneben sind die belastbare Form (siehe die Anker-Regel im
Nachtrag oben).

### 7.1 Was `f830a8f` behauptet — und was am Baum steht

| Behauptung (Message/ADR (ii)) | Prüfung | Ergebnis |
| --- | --- | --- |
| `Events.publish/2` → `{:agent, id, event}`, der TUI-Router routet darauf | `events.ex:66-71`; Router `tui.ex:2499/2503/2508` | ✅ Der Tag ist der ROUTER, nicht bloß Doku; ein unbekannter Absender wird verworfen (`2508`), nichts blutet in den Parent-Transcript |
| Kind-Transcript lebt im TUI-Speicher, nur das Summary persistiert | `child_state/2` `tui.ex:3777`, `accumulate_child/3` `3795`; `Subagent.cleanup/1` `subagent.ex:236` (`Session.stop` + `Store.delete`) | ✅ `persist?: false` + `cleanup` sind unverändert; der Tab sammelt nur im Prozessgedächtnis |
| Kein `Session.unsubscribe/1`; die TUI macht `Registry.unregister` | `grep unsubscribe lib/` → nur ein Kommentar; `tui.ex:2815` | ✅ Es gibt wirklich kein `Session.unsubscribe/1`; der `Registry.unregister/2`-Aufruf steht im Client-Prozess, wo `Session.subscribe/1` registriert hat (`session.ex:138-141`, der Kommentar dort begründet genau das) |
| „Ein Round-`task` läuft parallel unter einem Cap“ | `run_subagents/2` `session.ex:1725-1747` (`Task.async_stream`, `max_concurrency: cap`, `ordered: true`); `Config.subagent_concurrency/0,1` `config.ex:159-172` | ✅ Default 3, `config.toml` (project über global) → app env → Default, `is_integer(n) and n > 0`; Tests `config_test.exs:207-219` |
| „esc leitet an jedes aktive Kind weiter (eigene Interrupt-Id)“ | `esc_stop/1` `tui.ex:2232` (die Weiterleitung `2232-2246`) | ✅ `Interrupt` ist id-basiert (`interrupt.ex`, ETS-Key pro Session-Id), das Kind ist eine eigene Session-Id — die Weiterleitung greift, ohne den Parent-Worker zu brauchen |
| „Results keep call order“ | `ordered: true` + `Enum.zip(task_calls)` | ✅ |
| „Tabs werden bei Session-Wechsel verworfen“ | `mount_session/3` baut den Initial-State neu (`tui.ex:451-453`); `attach_selected_session/2` ersetzt den ganzen State | ✅ |
| „Der Renderer misst wie er malt“ (Tab-Leiste in `layout_overhead/1`) | `tui.ex:86-89` (+1 Zeile bei `subagents != %{}`), Bar-Split `3131`, `rederive_pane/1` bei `:subagent_started` `2797` und beim Resize-Poll `2897` | ✅ Der Pfad ist vollständig; unser Sidebar-Commit hat `layout_overhead`/`last_pane_height` **nicht** angefasst (`git show 6fa1b3b -- …` → kein Treffer), es gibt also keine zweite Meinung über die Pane-Höhe |

**Nicht belegt (und nicht behauptet korrekt):** die Message nennt
`Config.subagent_concurrency/2`; die Funktion hat die Aritäten **0 und 1**
(`config.ex:158-166`, verifiziert über `Config.__info__(:functions)`).
Kosmetisch, aber im Commit-Text und in der ADR (ii) (`018…rst:390`) steht
zweimal `/2`. *(`session.ex` selbst schreibt an der Aufrufstelle
`/1` — richtig; falsch sind die beiden Doku-Stellen.)*

### 7.2 F1 — **Blocker:** ein werfender `Subagent.run/2` reißt den Parent-Turn mit (und die TUI verliert den Tab)

`run_subagents/2` fängt genau einen Fall ab: `{:exit, reason}` aus dem
`Task.async_stream` — mit dem Kommentar „`Subagent.run/2` never raises“
(`session.ex:1738`). Der Kommentar trägt nicht, und die Ausnahme erreicht
den `Enum.map` nie.

**Mechanik (nachgemessen, Erlang/OTP 28, Elixir 1.20.4):**

1. `Task.async_stream/3` **linkt** seine Task-Prozesse mit dem Aufrufer
   (im Gegensatz zu `Task.Supervisor.async_stream_nolink/6`).
2. Wirft die Task, dann liefert `async_stream` `{:exit, reason}` **nur,
   wenn der Aufrufer `:trap_exit` gesetzt hat**. Ohne `trap_exit` bekommt
   der Aufrufer ein `EXIT`-Signal und **stirbt**, bevor irgendein Element
   durchs Enumerable läuft. Gemessen: derselbe Ablauf einmal mit
   `Process.flag(:trap_exit, true)` → `[exit: %RuntimeError{…}, ok: :ok]`,
   einmal ohne → „caller died“ (kein Result). `trap_exit` ist im Repo
   nirgends gesetzt (`grep -rn trap_exit lib/ test/ priv/` → leer).
   Ergänzend: `function_exported?(Task, :async_stream_nolink, 6)` →
   `false`; **nur** `Task.Supervisor.async_stream_nolink/6` existiert.
3. Der Aufrufer ist der Turn-Worker des Parents (`Session.spawn_turn/2`,
   `Task.Supervisor.async_nolink`). Er wird zum `{:exit, reason}`, also
   greift `Session.handle_info({:DOWN, ref, …})` (`session.ex:1053-1058`):
   `fail_turn(state, {:turn_worker_exit, reason})`. Der Parent-Turn ist
   damit **failed**, nicht „ein Tool-Result mit einer Fehlermeldung“.
   `subagent_exit_result/2` (`session.ex:1750`) ist auf diesem Pfad toter
   Code.
4. Die Kind-Session hat zu diesem Zeitpunkt schon `{:subagent_started, …}`
   publiziert (`subagent.ex:222`), `{:subagent_finished, …}` kommt aber nie.
   Die TUI behält eine Kind-Id in `subagents`, für die nie ein
   `Registry.unregister` läuft; der Tab bleibt dauerhaft „running“, die
   Tab-Leiste zählt ihn als laufend (`@tab_bar_cap`), und ein esc-Stopp
   schickt weiter Interrupts an eine beendete Id.

**Live nachgestellt** (test_mode, Seam-Runner, der wirft bzw. `exit/1`
ruft, `debug_gate` mit einem `task`-Call): in beiden Fällen
`status=running`, `last_error=nil` — der Parent-Worker ist weg, die
Session wurde per `:DOWN` abgeräumt, der Turn endet nie sauber. Also kein
theoretischer Fall: der Runner ist der dokumentierte Test-Seam
(`subagent_runner`), und ein Seam-Runner ist genau die Stelle, an der ein
`raise` vorkommt.

**Warum es bisher „geht“:** die Tests decken den Fehlerpfad über den
**Rückgabewert** ab (`failing = fn state -> {state, {:error, :boom}} end`,
`subagent_test.exs:142-159`) — das ist der Pfad, der funktioniert. Für
„das Kind wirft“ gibt es keinen Test.

**Vorschlag (zwei Zeilen, kein Umbau):** die Supervisor-Variante nehmen —
sie linkt nicht und liefert die `{:exit, _}`-Tupel ohne `trap_exit`:

    Task.Supervisor.async_stream_nolink(task_supervisor(), task_calls,
      fn call -> CodingAgent.Core.Session.Subagent.run(state, call) end,
      max_concurrency: cap, ordered: true, timeout: :infinity)

Der vorhandene `{:exit, reason} -> subagent_exit_result(call, reason)`
-Zweig wird damit erstmals erreichbar (gemessen: mit dem echten
`Enum.zip`/`Enum.map`-Mapping kommt `[c1: :crashed, c2: {:ok, :res}]`
heraus). Nachziehen muss die Doku: der Kommentar „`Subagent.run/2` never
raises“ ist falsch — es gibt einen Grund, warum hier gefangen wird.
*Offen, Code.*

### 7.3 F2 — Kind-Tabs sind für die Session **unsichtbar**: der Parent-Delta-Pfad rendert pro Delta weiter

`handle_info({:agent, {:llm_deltas, delta}}, …)` (`tui.ex:2524-2531`)
setzt `stream_dirty?: true` und liefert `render?: false`; der
Kind-Zweig (`2503`) geht direkt in `accumulate_child/3` (`touch` + Fold)
und liefert `{:noreply, state}` — also den **Default** `render?: true`.
Jedes Kind-Delta bemalt damit einen vollen Frame.

**Gemessen** (`:erlang.trace` auf `Tui.render/2`, 100 Deltas je Sender,
identische Länge):

    parent: 100 deltas ->   0 render/2-Aufrufe
    child:  100 deltas -> 100 render/2-Aufrufe
    parent:   1 delta  ->   0 render/2-Aufrufe

**Gemessen** (Wanduhr, dieselbe Maschine, gleicher Test-Modus; Kind-Tab
mit wachsendem Stream-Buffer):

    1000 Parent-Deltas:     3,2 – 6,2 ms   (Fold + `render?: false`)
    1000 Kind-Deltas, 250er-Buffer:   88 ms
    1000 Kind-Deltas, 1000er-Buffer: 434 ms
    1000 Kind-Deltas, 1000er-Buffer: 346 ms
    1000 Kind-Deltas, 15000er-Buffer: 1,9 s

Der Preis wächst mit der Buffer-Länge, weil `append_stream/3`
(`tui.ex:3539-3547`) den gesamten angesammelten Block kopiert
(`prev <> delta`) — O(n) pro Delta, O(n²) pro Stream, jetzt einmal **pro
Frame** statt einmal pro Delta.

Ein zweites, davon unabhängiges Problem: `subscriptions/1`
(`tui.ex:2995-2997`) deklariert den Stream-Tick nur, wenn
`state.stream_dirty?` **und** `state.stream` nicht leer sind. Der
**Parent**-Tick ist damit der einzige Repaint-Takt. Bei einem Parent, der
im `task`-Call blockiert (genau der Zustand, den die Slice für den
Subagenten-Fall beschreibt), ist `state.stream` typischerweise leer und
`stream_dirty?` false → **kein Takt**; die Kind-Panels hängen dann an der
Spinner-Subscription (`Styles.busy?(state.status)`) bzw. am
Delta-pro-Frame-Zufall. Der Kind-Pfad hat also *zufällig* einen Antrieb,
und der ist der teure.

**Vorschlag:** im Kind-Zweig `touch` + `Map.put(:stream_dirty?, true)` +
`render?: false`, und `subscriptions/1` so erweitern, dass ein laufendes
Kind den Takt ebenfalls anfordert (z. B. „es gibt einen Child mit
`finished?: false` und nicht-leerem `stream`“). Das ist genau die
`@stream_render_ms`-Disziplin, die der Parent schon hat. *Offen, Code.*

### 7.4 F3 — `child_state/2` legt einen toten Zustand an

`child_state/2` (`tui.ex:3777-3789`) setzt `active_agent`, und
`fold_child(child, {:turn_started, agent})` (`tui.ex:3800`) pflegt ihn.
Gelesen wird er nirgends: `child_display_entries/1` (`3841`) attribuiert
jede Assistant-/Info-Zeile mit `Map.get(child, :agent)`, nicht mit
`active_agent`. Ein Zustandsfeld ohne Leser ist genau das, wogegen ADR
029 argumentiert. Entweder lesen (die Attribution darauf umstellen) oder
entfernen — plus die zugehörige `fold_child`-Klausel. *Offen, Code.*

### 7.5 F4 — `active_tab` wird nie zurückgesetzt, wenn der gewählte Tab verschwinden kann

Heute kann ein Tab nur durch einen Session-Wechsel verschwinden, und der
ersetzt den ganzen State (`tui.ex:451-453`) — also ist nichts kaputt.
Aber `active_tab` ist ein **Zeiger ohne Lebensdauer-Regel**: `put_scroll`
(`3333-3337`) und `put_open_id` (`3353-3357`) behandeln „Id nicht mehr in
`subagents`“ nur als Rückfall (`active_tab: nil`, Wert in den Parent).
Es gibt keinen Aufräumpfad, der `active_tab` beim Entfernen eines Tabs
mitzieht. Wenn die naheliegende nächste Slice kommt („letzten Tab beim
nächsten Delegieren ersetzen“, ADR 018 offene Frage 4 — oder ein Cap auf
die *gehaltenen* Tabs), zeigt die Pane auf einen nicht existierenden
Eintrag und fällt still auf den Parent-Transcript zurück. Klein, aber es
ist eine Regel, die nur im Kopf existiert. *Offen, Code.*

### 7.6 F5 — Text-Kleinkram (im selben Commit)

1. „never raises“ (`session.ex:1738`): siehe F1 — die Begründung ist
   falsch, der Fang ist richtig.
2. `Config.subagent_concurrency/2` — Message und `018…rst:390` nennen
   Arity 2, es gibt 0 und 1.
3. `Session.subscribe/1` Doc (`session.ex:127-129`): „Events arrive as
   `{:agent, event}` messages“ — seit `f830a8f` sind sie getaggt. Genau die
   eine Zeile, die man liest, wenn man einen Subscriber schreibt.
4. ADR 018 Amendment (ii) ist **im selben Commit** in sich widersprüchlich:
   der Kopf sagt „**Status: planned, not yet built.**“ (`018…rst:292`), der
   Abschnitt darunter „**SHIPPED 2026-09-25.** All six steps … implemented“
   (`:378`). Wer nur den Kopf liest, hält die Slice für Zukunftsmusik; wer
   nur den SHIPPED-Block liest, für erledigt. Eine Statuszeile, zwei
   Antworten. Auch das „Three things in the seam are not tab-ready“-Präsens
   (Punkt 1 „the wire carries no source id“) beschreibt jetzt einen
   Zustand, den derselbe Commit geändert hat — es ist als *Befund vor der
   Entscheidung* korrekt, liest sich ohne diesen Hinweis aber als Ist-Stand.
5. Unser Nachbar-Commit `6fa1b3b` (Sidebar) sagt im ADR-Text „the tab
   **will** add a bounded tab bar“ (Zukunftsform) — seit `f830a8f` ist er
   da, und der Satz steht erst seit `c53e427` in dieser Form im Dokument.
   Unser Fehler, unser Fix, gehört in denselben Nachtrag wie der
   Rebase-Kram. *Mit diesem Commit erledigt.*
6. `events.ex:8` — `Events`-Moduldoc: „Before this module, five call sites
   each re-implemented the same `Registry.dispatch/3` + `send(pid,
   {:agent, event})` dance“. Der **erste** Teil ist historisch korrekt
   (genau so war es vor ADR 008); der zitierte Code ist aber das *alte*
   Wire-Shape und liest sich ohne Zeitangabe wie der heutige. Ein
   Halbsatz („damals `{:agent, event}`“) macht es eindeutig. *Offen, Text
   im `devel`-Commit; dasselbe Muster wie Punkt 3 — und genau das Paar
   aus der Zusammenfassung vom 2026-09-25: `session.ex:129` und
   `events.ex:8` sind die zwei Stellen, die den ungetaggten Draht
   beschreiben.*
7. `session.ex:1718` sagt an der Aufrufstelle `Config.subagent_concurrency/1`
   — richtig, aber im selben Doc-Block steht direkt daneben die falsche
   Arity in Message/ADR. Nach dem `/2`-Fix oben ist das konsistent.

### 7.7 F6 — Doku nach dem Aufsetzen: unser Folge-Commit ist wieder stale

`c53e427` (unser Doku-/Record-Commit) beschreibt den **ersten** Rebase auf
`1b78de4`. Nach dem zweiten Rebase auf `f830a8f` gilt:

* `review.md`: Nachtrag-Tabelle und §5-Block nannten
  `78da98e/d58a681/cc9cebf/9e8ab6a/dad6c18/756576b`; §5 sagte „`devel`
  steht inzwischen auf `1b78de4`“.
* `TODO.md`: `Stand`-Zeile sagte HEAD `756576b`; gemeint sind jetzt
  `devel` @ `f830a8f`, HEAD `c53e427`.
* `review.md` §1 versprach, die Zeilenangaben seien „auf den heutigen
  Baum gezogen“. Für den Seam-Baum (`1b78de4`) stimmt das nachgerechnet —
  die genannten Stellen sitzen auf `devel`@`1b78de4` exakt so (2341,
  2357, 2370, 2384, 2365, 2375, 2389, 2818, 2838, 2845, 2852, 3617,
  3746-3749, `session.ex:1765`). Auf dem **jetzigen** Baum (`f830a8f`)
  sitzen sie woanders (z. B. `open_pause/3` jetzt 2960/2967/2974,
  `pause_label/1` 3919, `resync_prompt/2` 2940, die drei No-Ops
  2436/2449/2463, Token-Zeilen 4089-4092, `finish_wrap_up/1` in
  `session.ex` 1794) — und die im Text genannten `2341`/`2357`/
  `2365`/`2370` sind heute zufällig *andere* Dinge. Genau deshalb steht
  jetzt die **Anker-Regel** im Nachtrag: Symbol statt Zeile.
* `review.md` §2 zitiert `ROADMAP.md:50`, `:395`, `:405`, `:415`, `:502`
  als die Stellen, die `935cf92` geändert hat — und auf **`935cf92`
  selbst stimmen alle fünf exakt** (nachgerechnet). Sie sind also nicht
  falsch, sie sind nur *nicht* in derselben Zeitachse wie §1: §1
  versprach „heutiger Baum", §2 bleibt beim Review-Commit. Auf `1b78de4`
  liegen sie bei 50/399/409/419/506, auf `f830a8f` bei 50/402/412/422/509
  (Text zeichengleich, nachgerechnet).
* `TODO.md` P4 nennt `mount_picker ~114, mount_session ~212`. Gemessen
  (Funktionsspanne, Zeile `defp` bis `end`): `935cf92` 114/**212**,
  `81be63a` 114/**216**, `1b78de4` 119/**219**, `f830a8f` 122/**220**,
  HEAD 122/**224**. „~114/~212“ ist also die Zahl des Original-Commits,
  nicht des Baums, auf dem sie steht — und in der **Vorlage** `935cf92`
  standen `~180`/`~315`. Der **falsche Wert war unser Record**: er sagte
  `mount_session ~217`; `d58a681` (heute `e2c8955`) schrieb korrekt
  `~114, ~212`. §2.3 ist entsprechend korrigiert.
* `review.md` §5 sagte „Der Baum des jeweiligen Commits ist unverändert“ —
  das gilt für den **Patch** (zeichengleich, s. u.), nicht für die Trees;
  §5 ist entsprechend umformuliert.
* Unser Commit `75ec6df` `docs(makefile): a cold checkout can build the docs`
  liegt immer noch **nicht** auf `devel` (`git diff devel...HEAD` →
  `docs/Makefile`), obwohl der Nachtrag ihn als erledigt führt. Das ist
  dem Owner zu melden, nicht von uns zu landen.

**Beleg für „nichts Inhaltliches verloren“:** die lib+test-Patches sind über
beide Rebases hinweg inhaltsgleich — reproduzierbar als md5 über die
reinen `+`/`-`-Zeilen (ohne Datei- und Hunk-Köpfe, also ohne die
wechselnden Offsets; `git show <c> --format= -- lib test | grep '^[+-]' |
grep -v '^\(---\|+++\) '`):

    81be63a -> 756576b -> 6fa1b3b   52888e8394   (6 Dateien, +258/−67)
    85daad9 -> 78da98e -> 89ced6b   34b028bf53   (3 Dateien,  +98/−28)

Nur die Bäume unterscheiden sich (Konfliktauflösung in `TODO.md` und der
ADR, beim zweiten Rebase zusätzlich `ROADMAP.md`), nicht die
Code-Änderung — und die Zahl der Branch-Commits ist von sechs auf sieben
gestiegen (`c53e427` ist der Record-Commit).

Verifiziert am HEAD `c53e427`: `mix format --check-formatted` ok,
`MIX_ENV=test mix compile --warnings-as-errors` sauber, `MIX_ENV=test mix
test --seed 0` **879 grün**, `--seed 1 test/coding_agent/ui/` **274 grün**,
Sphinx `build succeeded, 1 warning` (nur die bekannte
intersphinx-`NameResolutionError` ohne Netz).

`935cf92` und `9dbfc00` bleiben unverändert; `devel` steht weiter auf
`f830a8f`, `git rev-list --left-right --count devel...HEAD` → `0 7`.

### 7.8 F7 — Nebenbefund, außerhalb des Commits: **der Git-Editor**

Der Owner sah „editors mit commit messages“ aufgehen. Ursache, gemessen:

    EDITOR=vim
    VISUAL=gvim -f
    core.editor: (unset)          sequence.editor: (unset)

Git startet die Editor-Kette, sobald ein Aufruf eine Nachricht **braucht**,
und jeder Agent-Aufruf in diesem Worktree erbt diese Umgebung. Konkret
sind das alle `commit`-Formen ohne `-m`, `commit --amend`, `tag -a`,
`merge`, `rebase -i` — im letzten Durchlauf war das `git rebase
--continue`. Die `dconf-CRITICAL … Read-only file system`-Zeilen, die
bisher als „harmlos“ abgehakt wurden, waren genau dieses `gvim`.

**Lösung ohne Config-Änderung** (der Agent ruft git selbst auf, also in
*dessen* Aufruf): `GIT_EDITOR=true` bzw. gleichwertig
`git -c core.editor=true …`. Damit bleibt die Umgebung des Owners
unberührt, und **kein** Commit, kein Worktree und keine geteilte Config
ändert sich für den Menschen. Für ein Skript im Sandbox-`shell`/`git`-Tool
ist außerdem `Terminal-Prompt/Editor hart deaktivieren` die eigentliche
Lehre — ein Werkzeug, das `git commit` für einen Agenten ausführt, darf
nie auf einen Editor warten:

    GIT_EDITOR=true GIT_TERMINAL_PROMPT=0 GIT_PAGER=cat PAGER=cat

`Core.Exec.run/4` gibt heute **keine** `{:env, …}`-Option mit
(`Port.open` in `exec.ex:33` kann das, nachgemessen; `Tools.Git` und
`Tools.Shell` laufen beide darüber). Das ist **kein** Befund zu `f830a8f`
und keine Empfehlung, es in dieser Slice zu bauen; es ist die Antwort auf
„können wir das dort lösen“ — und es ist noch **nicht** gebaut.

### 7.9 F8 — Was daraus als Commit werden sollte

Text (jetzt, in diesem Branch, als **ein** Folge-Commit — nie ein
`--amend` auf gelandete Commits):

1. `review.md`: Nachtrag „zweiter Rebase auf `f830a8f`“ mit der neuen
   alte↔neue-Tabelle (`89ced6b, e2c8955, 75ec6df, 45d73ac, 1751b53,
   6fa1b3b, c53e427`), §5-Block nachziehen, §1-Anker über die neue
   Anker-Regel (Symbol + Commit) statt als reine Zeilennummern, §2 die
   ROADMAP-Anker als „auf `935cf92`“ kennzeichnen, §2.3 `217` → `212`.
2. `TODO.md`: `Stand`-Zeile auf `devel @ f830a8f`, HEAD `c53e427`; P4-
   Maße nachgezogen (P4 nennt `~114/~212`, die Zahl des Original-Commits
   `935cf92`; auf `f830a8f` sind es 122/220, auf dem Branch-HEAD
   122/224 — siehe F6).
3. Der eine Satz Zukunftsform im Sidebar-Text (`6fa1b3b`s ADR-Anhang,
   Stand `c53e427`), den die neue Slice sachlich überholt hat: „the tab
   **will** add a bounded tab bar and, possibly, rows in this panel“.
   Jetzt: die Leiste ist mit dem Subagenten-Amendment da (eine Zeile über
   dem Transcript, `@tab_bar_cap` 5), das Panel selbst blieb unberührt —
   beides nachgerechnet (`layout_overhead/1` setzt +1 Zeile, sobald
   `subagents` nicht leer ist; `sidebar_widget/1` liest `subagents` nicht).

Code (offen, Owner-Entscheidung — nicht von mir angefasst):
F1 (Blocker), F2, F3, F4. F5.1–3 und F5.6 sind Kommentar-/Doku-Zeilen,
die im `devel`-Commit stehen und als Folge-Commit korrigiert werden
müssten — dieselbe Regel wie bei `935cf92`s „Vier Dokumente gelöscht“.
F5.4 (die zwei Statuszeilen im selben Amendment) und F5.5 sind
Textstellen, die in der eigenen Hand liegen; F5.5 ist mit diesem Commit
erledigt, F5.4 ist eine Entscheidung des Owners, welche der beiden
Statuszeilen gelten soll.

**Erledigt mit diesem Commit** (drei Dateien, Text only):
`review.md` (Punkte 1, inkl. §2.3 `217` → `212`), `TODO.md` (Punkt 2, die
`Stand`-Zeile und die P4-Maße) und `docs/source/decisions/018-agent-ui-display.rst`
(Punkt 3, der Zukunftsform-Satz). Verifiziert: `MIX_ENV=test mix test
--seed 0` → **879 grün**, `mix format --check-formatted`,
`MIX_ENV=test mix compile --warnings-as-errors`. Die Punkte unter „Code“
bleiben ausdrücklich offen — allen voran F1.

Dieser Commit ist der achte des Branch (sieben vor ihm, s. §5) und trägt
den Betreff `docs: the review of f830a8f, and the record after the second
rebase`. Ein Commit kann seinen eigenen Hash nicht nennen; dasselbe gilt
für die Tabelle im Nachtrag, in der er die erste Zeile der Spalte
„vorher" wäre. Wer ihn adressieren will, adressiert `HEAD`.
