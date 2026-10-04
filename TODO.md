# TODO — der aktive Backlog (Features)

Stand: 2026-10-04, Branch `dev/mjansen`. Diese Datei ist der **kurzfristige
Feature-Backlog**: was als Nächstes gebaut oder entschieden werden will.
Der große Plan steht in `ROADMAP.md` (Phasen, Produktthese, „Later“-Ideen,
Ground Rules), **Entscheidungen** in den ADRs (`docs/source/decisions/`).

**Erledigtes fällt hier raus.** Die Commits und die ADRs sind der Record —
es gibt bewusst keine „Erledigt“-Chronik mehr. Review-Befunde und
Harness-Feedback stehen in **`review.md`** (eine Liste für alles Offene,
Konvention in `review-process.md`); sie gehören nicht in diese Datei.

Querverweise der ADRs („T4“, „B3“, „the rival-opencode list“) beziehen sich
auf die Nummern in dieser Datei; die historische Herkunft ist im jeweiligen
ADR vermerkt.

## Offene Aufgaben (Owner)

* **TUI: volle Breite.** Der Owner kann die Tabelle nicht lesen — der
  „reading measure“ (`@measure 100` in `lib/coding_agent/ui/tui.ex`,
  `content_width/1 min(w, @measure)`) deckelt jede breite Ansicht
  (Transkript, Composer, Overlays) auf ~100 Spalten und zentriert sie.
  Wunsch: die **volle Breite** nutzen. Betrifft mehrere Stellen
  (`content_width/1`, `min(@measure + 2, …)` in den Overlays, die
  Composer-Split-Logik) — ein gemeinsamer Ort statt sechs Literale.
* **Ask-Dialog: ALT/Shift+Enter im Freitext.** Im Frage-Dialog
  („type your own“, `question_prompt.custom`) sind ALT+Enter/Shift+Enter
  laut Keymap `:insert_newline`; der Wizard routet aber nur
  `:enter`/`:esc`/`:backspace`/Pfeile und **verwirft** das Newline —
  unklar, ob es dabei auch den Custom-Puffer leert (Owner-Report:
  „löscht was ich geschrieben habe“). Reproduzieren, dann entscheiden:
  Newline einfügen (mehrzeiliger Freitext) oder Tastenkombination
  ignorieren, ohne den Puffer anzufassen.
* **Teil-Repo (`workdir`):** geplant, aber noch nicht gebaut — `scope_root`
  bleibt das aktuelle Verzeichnis (Kontext), ein **explizit konfiguriertes**
  Unterverzeichnis (`[scope] workdir` in `config.toml`) soll die Schreibgrenze
  sein (nur Schreiben scope-beschränkt, Lesen bleibt scope-weit), mit klarer
  Fehlermeldung außerhalb. Undo/Checkpoint bekommt damit seinen Umfang;
  Alternative „eigenes Shadow-`.git` statt Nutzer-Repo" besprochen,
  zurückgestellt.
* **Projekt-`ui.toml`-Pfad ist tot.** `Keymap.load/0` liest nur global; ein
  Projekt-`ui.toml` wird nicht gelesen. Entweder verdrahten oder den Pfad
  entfernen. Dazu: `Prompt.git_repo?/1` prüft nur den Scope-Root.
* **Pro-Modell-Fenstertabelle?** Die Auflösung ist heute Key plus Katalog;
  offen ist, ob eine `[context_windows]`-Tabelle gewünscht ist (ADR 037).

## Zuerst: Live-Smoke

* **`compact`-Tool: nutzt der Agent es, und wann?** Das Tool ist da (ADR 040
  OQ1), aber noch **nicht live beobachtet**. Der nächste lange Lauf zeigt:
  (a) findet das Modell den Hebel (der Budget-Block nennt ihn), und (b) zieht
  es ihn am richtigen Punkt — **viel Rauschen rein, wenig Ergebnis raus**,
  nach einem erledigten, suchlastigen Schritt, *nachdem* der Ertrag in
  `notes` steht — statt zu früh oder statt `notes`. **Entschieden
  (2026-09-30): erst messen, dann genau eine Nachschärfung**, wenn nötig in
  der **Tool-Beschreibung** (der Ort, an dem die Entscheidung fällt). *Keine*
  Fahrplan-Semantik („nach jedem Todo compacten") — jeder Compact blockiert
  Minuten Provider-Zeit und wirft Detail weg. Verworfene größere Option
  (nicht jetzt): ein dynamisches Rausch-Signal im Budget-Block.
* **Frage-Dialog doppelt gestellt?** Der Race-Fix (ADR 027 Amendment) muss
  live bestätigt werden: der Dialog darf nach der Antwort bleiben, wenn der
  Agent nachfragt; der zweite identische Ask sollte ausbleiben. Nur mit
  echtem Provider prüfbar.
* **esc stoppt ein laufendes Kind.** Die TUI ruft `Session.interrupt/1` für
  jedes aktive Kind (ADR 018 Amendment (ii)). Mid-tool hard cancel ist
  erledigt (ADR 043): ein hängender `shell`/`grep` endet binnen 250 ms. Live
  noch zu bestätigen: der Doppeldruck beendet einen hängenden `shell`
  wirklich, und der Parent bekommt `STOPPED by the user` statt eines
  Timeouts.
* **ADR 030 live.** Der Umbau ist test-verifiziert, aber der bwrap-Datei-Pfad
  lief nur in den Integrationstests: live prüfen, dass
  `read_file`/`write_file`/`edit`/`list_dir` unter echtem bwrap sauber
  arbeiten (inkl. `hide`/`ro`), der Session-Start auf einem Host ohne bwrap
  verständlich verweigert, und `shell`/`git` ohne Rückfrage laufen.
* **hide für Dateien mit `--dev-bind`** wurde live gefunden und gefixt
  (Nodev-EACCES); ein Live-Lauf über die Mount-Konfiguration bestätigt es.

## Offen gegen opencode (T-Liste)

| # | Punkt | Stand |
| --- | --- | --- |
| T9 | `websearch` neben `webfetch` | offen (Such-API-Abhängigkeit; `webfetch` ist da) |
| T10 | `patch_file` (mehrere exakte Ersetzungen in einem Call, **atomar**), danach Fuzzy-Match-Kette für `edit`/`patch_file` und LSP-Diagnostik | offen; hieß früher `apply_patch`. `edit` ist exakt-match-only (opencode hat 9 Fuzzy-Strategien + LSP-Diagnostik nach jedem Edit) |
| T15 | `copy_file` / Kopieren | zurückgestellt — bisher nie gebraucht (nur rename). Wenn doch: evtl. `rsync` statt `cp`; `rsync` ist aber nicht POSIX-garantiert, `cp` schon (ADR 045, Non-Goal) |

Erledigt und damit raus: T1–T8, T11–T14 (Commits und ADRs 024–044).

## Dogfooding-Blocker (B)

* **B5** Input-Auto-Wrap — **vom Owner vertagt** (2026-09-19), nicht
  anfassen, ohne dass es weh tut. Messung für die Wiederaufnahme:
  `%Textarea{}` hat **kein** `wrap`-Feld (die Crate `ratatui-textarea` 0.9.2
  kann es nicht); eine lange Zeile rendert nur die ersten ~20 Spalten und
  scrollt horizontal zum Cursor; `input_height/1` misst nur Newline-Zeilen.
  Optionen: (a) Soft-Wrap im eigenen Render-Layer inkl. Cursor-Mapping und
  Höhen-Mathematik, (b) NIF patchen/vendorn (nicht landbar), (c) „mehr Text
  rechts“-Indikator (löst es nicht allein).

## Session-Storage (ADR 020)

Die Engine ist umgestellt (ADR 020 R16 + ADR 023). Offen:

* **Import** existiert bewusst nicht: `binary_to_term` ohne `[:safe]` ist für
  lokale Eigentümer-Dateien ok, ein Fremd-Import bräuchte erst Safe-Decoding
  (ADR 020, Export). Nur anfassen, wenn Import gewollt ist.
* Offene Fragen R-Nummern siehe ADR 020 selbst.

## Struktur & Kosmetik (P4)

* `tui.ex` aufteilen (`4865` Zeilen auf `devel@ca6f734`; der interne Aufbau
  ist nur durch `# --`-Kommentare getrennt) und den Mount-State **einmal**
  definieren (`mount_picker` 122 Zeilen, `mount_session` 224 — Funktionsspanne
  `defp` bis `end`). Die früheren Maße (`~114/~212`) waren die von `935cf92`,
  dem Commit, in dem sie falsch waren.
* `TranscriptView.metrics/…` als **eine** Heimat der Pane-Geometrie — derzeit
  verstreut (`content_width`, `pane_size`, Overlay-Raum).
* `test_mode?`-Branches durch injizierte Behaviours ersetzen, wo sie schon
  Bugs durchgelassen haben (8 Stellen in `tui.ex`).
* **`shift+tab` (`back_tab`) ist ungebunden.** Die Bridge mappt den Code, der
  Keymap bindet ihn nicht; das Intent-Vokabular (ADR 021) muss entscheiden,
  was er bedeutet.
* **Glyph-Pässe** (kosmetisch, nur breitensichere geometrische Glyphen):
  Approval-Dialog druckt noch `y = approve …`; Info-/Warn-/Fehlerzeilen tragen
  `✖` als eingebackenen String statt eines rollen-gewählten Leitglyphs;
  Picker-Zeilen nutzen `to_string(status)` statt `Styles.status_badge/1`.

## UI-Redesign — offen

Die Runden 1–5 sind umgesetzt (Palette/Styles, `UI.Composer`, Bottom-Row-Wegfall,
`UI.LiveBand`, Sidebar-Neugliederung); Befunde und Entscheidungen stehen in
ADR 018 und im `Styles`/`Palette`-Moduldoc. Offen:

* **O2** Air pro Eintrag differenzieren (Vorschlag: tool 1 / info 1 /
  reasoning 2 / assistant 3) statt `@air 3` überall.
* **O3** Sidebar-Werte **rechtsbündig** ausrichten (Padding im `Paragraph`
  oder echte `Table`); die Punktausrichtung ist erledigt
  (`Styles.definition_list/2`).
* **O5 — entschieden: ruhig lassen.** Die ~15 leeren Sidebar-Zeilen bleiben:
  das Panel ist fertig gegliedert, der Leerraum darunter trägt keine
  Information; Füllen wäre Dekoration. (Nicht neu aufwerfen.)
* **O6/O12** Band interaktiv machen: Rail `▌` links, Provider/Effort
  farbcodiert; das Band nimmt heute keine Tastendrücke. Berührt das
  Padding-Entscheid (ADR 018 Amendment: 1 Zelle auf allen vier Seiten).
* **O7** Sidebar entdoppeln (Modell/Effort raus, wenn das Band sie zeigt) —
  das Band zeigt das Modell nur im Busy-Fall, die Duplikation im Idle bleibt.
* **O8** Markdown-Politur: `#`-Präfixe bleiben sichtbar, Fences bleiben
  literal, Inline-Code-bg ist hart `:black` (F9-Messung; die Crate
  `tui-markdown` ist die Ursache, nicht `hard_breaks`).
* **O10** „wide bar“ aus dem ratatui-Beispiel: Picker-Auswahlzeile oder
  Vorbild für die Rail?
* **O11** Latente Duplikation: `Tui.entry_widgets/3` baut Reasoning/Tool/Info-
  Widgets nach, die `TranscriptView.widget_for/3` fürs Messen schon baut —
  „measure = paint“ hält nur zufällig.
* **O13** Overlay-Höhe jenseits des Popups: `budget`/`doom`/`question` klemmen
  (Höhe auf `div(area.height, 2)` begrenzt), nur das Menü fenstert. Erst
  relevant, wenn ein Overlay höher wird.

## TUI-Wunschliste (ROADMAP „Later“, Nutzerliste)

* **Navigator** (ctrl-g: Go To Questions / Blocks) — vom Owner als
  wertvollstes Stück bezeichnet; die Platzierungs-Mathematik existiert
  (`block_at_row/2`).
* **Frame-Scrolling-Artefakte** — der Owner fixt selbst, kein Stopper.
* **Approval-Arg-Editing** im Dialog (`e` ist reserviert, zeigt „soon“).

## UI-Leitplanken (bleiben; Heimatorte statt Alt-Doc)

* Keine Farbe an der Aufrufstelle — nur Rollen/Surfaces
  (`Styles`/`Palette`-Moduldoc).
* `measure = paint`: Höhen-Rechnungen nur gemeinsam mit dem Renderer ändern
  (ADR 028).
* Der Transcript-Hintergrund bleibt die Terminal-Vorgabe; nur App-Flächen
  sind gefüllt (`Palette`).
* Farb-Asserts nur über `CellSession` (`TuiCase`-Moduldoc zu
  `start_cell_tui/2`).
* Was eigene Daten **und** eigene Funktionen hat, wird ein eigenes Modul
  (Owner-Entscheidung; `Composer`/`LiveBand` sind die Präzedenzfälle).

## Doku-Staleness

* **ADR 007** bleibt bewusst `Proposed`: die Spezialisten-Matrix ist ungebaut
  (ROADMAP „6c“), der Record ist ein Plan, keine Entscheidung.

## Offene ADR-Fragen

Nicht duplizieren — sie stehen in den ADRs selbst: 025 q3, 026 q1–3,
027 q1–3, 028 q1–3, 029 q1–3, 024 q2–3, 020 q2, 022, 018 (Tab-Design in
Amendment (ii) beantwortet; offen nur die Keys/Cap-Config), 007 (Proposed:
Spezialisten-Matrix, Produktthese, ungebaut).
