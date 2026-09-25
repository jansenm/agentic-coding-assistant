# TODO — der aktive Backlog

Stand: 2026-09-25, Branch `devel` @ `1b78de4`. Gegen den Baum verifiziert;
die beiden Zeilenmaße im P4-Punkt gegen den Commit korrigiert, in dem sie
falsch waren (Folge-Commit). Die Sidebar-Einträge O4/O5 in Runde 5 auf
`dev/mjansen` gegen den dortigen Baum nachgezogen (noch nicht auf `devel`).

Der **große Plan** steht in `ROADMAP.md` (Phasen, Produktthese,
„Later“-Ideen, Ground Rules). **Entscheidungen** stehen in den ADRs
(`docs/source/decisions/`). Diese Datei ist der kurzfristige Backlog: die
nächsten Schritte plus alles, was nach der Konsolidierung vom 2026-09-25
aus `code_review.md`, `ui_redesign.md`, `übersicht.md` und
`frage-tool-befund.md` offen geblieben ist. Erledigtes fällt hier raus —
Git-Historie und ADRs sind der Record.

Querverweise der ADRs („T4“, „B3“, „the rival-opencode list“) beziehen
sich auf die Nummern in dieser Datei; die historische Herkunft ist dort
im jeweiligen ADR vermerkt.

## Zuerst: Live-Smoke

* **Frage-Dialog doppelt gestellt?** Der Race-Fix (ADR 027 Amendment)
  muss live bestätigt werden: der Dialog darf nach der Antwort bleiben,
  wenn der Agent nachfragt; der zweite identische Ask sollte ausbleiben.
  Nur mit echtem Provider prüfbar.
* **Subagent (`task`) live.** Seam und Tab sind gebaut (ADR 018 Amendment
  (ii), 2026-09-25), aber nur mit `test_mode`/Seam-Runner getestet: ein
  echter Lauf startet den Provider im Kind, persistiert nicht, sein
  Summary landet als Tool-Result im Parent, sein Stream im Tab. Live
  prüfen: reale Läufe starten sauber (auch mehrere parallel), die
  Tab-Leiste/crtl-x a zeigen sie, das Band nennt den Leaf, und der
  Parent-Kontext sieht nur die Zusammenfassung.
* **esc stoppt ein laufendes Kind.** Jetzt weitergeleitet: die TUI ruft
  `Session.interrupt/1` für jedes aktive Kind (ADR 018 Amendment (ii)).
  Live bestätigen, dass ein esc-Doppeldruck einen langen `task`-Lauf
  wirklich abbricht; der Parent-Worker blockiert weiter im Task-Call, das
  Kind wird aber über seine eigene Interrupt-Id gestoppt. Ein „mid-tool
  hard cancel“ bleibt als `ROADMAP.md`-Notiz offen.

## Nächste Schritte (priorisiert)

1. **`todowrite`/Plan-Tool (T4).** opencodes Weg, Mehrschritt-Arbeit
   sichtbar zu halten; dem Plan-Agenten fehlt sonst ein dauerhaftes
   Artefakt. Braucht eine kleine UI-Fläche.
2. **Dateien anhängen (`@`-Trigger, B3).** Letzter offener
   Dogfooding-Blocker (Track C). Design: Wortanfang-Trigger `@`, der
   Picker/Menü-Fläche wiederverwendet, Quelle `Core.Tools` unter
   `Tools.scope/1` + `Mounts`.
3. **Slash-Commands / Command-Palette (T7).** `/new`, `/sessions`,
   `/models`, `/compact`, `/export`, `/undo`, `/help` machen die
   bestehenden Aktionen auffindbar statt Tastenkürzel-Archäologie.
4. **Undo/Redo via Git-Checkpoint + `/undo` (T8).** „Git ist das Undo“
   ist ADR-015-Prinzip, aber ohne Nutzer-Verb; ein Checkpoint pro Turn
   plus `/undo` paart mit der Permission-Story.

## Kern-Features gegen opencode (T-Liste)

| # | Punkt | Stand |
| --- | --- | --- |
| T4 | `todowrite`/Plan-Tool (braucht UI-Fläche) | offen — nächste Schritte 1 |
| T5 | `task`/Subagent inkl. Tab (ADR 017/018) | **erledigt** (2026-09-25): Seam + Tabs (Amendment (ii)) — Wire-Tagging, in-memory Tabs, Tab-Leiste/ctrl-x, Parallel-Cap |
| T7 | Slash-Commands/Command-Palette | offen — nächste Schritte 3 |
| T8 | Undo/Redo via Git-Checkpoint + `/undo` | offen — nächste Schritte 5 |
| T9 | `websearch` neben `webfetch` | offen (Such-API-Abhängigkeit; `webfetch` ist da) |
| T10 | `apply_patch`, LSP, Skills, MCP — inkl. fuzzy-match-Kette für `edit` | offen; `edit` ist exakt-match-only (opencode hat 9 Fuzzy-Strategien + LSP-Diagnostik nach jedem Edit) |
| T13 | Verschachtelte `AGENTS.md` (Monorepo) | offen; wir lesen nur den Scope-Root einmal (`ProjectMemory.load/1`) |
| T14 | Truncation spült Volltext in eine abrufbare Datei | offen; `Exec.truncate/1` (head+tail), `grep`-Cap, `webfetch`-Cap verwerfen den Rest unwiederbringlich. Ablage existiert (`Scratch`, ADR 022) |
| T1/T2/T3/T6/T11/T12 | Framework-Prompt (ADR 024), Doom-Guard (ADR 026), Agentenfelder (ADR 024/025/029), `question` (ADR 027), Store-Flake, Provider-Prompts (ADR 024) | **erledigt** |

## Dogfooding-Blocker (B)

* **B3** Dateien anhängen — siehe nächste Schritte 2.
* **B5** Input-Auto-Wrap — **vom Owner vertagt** (2026-09-19), nicht
  anfassen, ohne dass es weh tut. Messung für die Wiederaufnahme:
  `%Textarea{}` hat **kein** `wrap`-Feld (die Crate
  `ratatui-textarea` 0.9.2 kann es nicht); eine lange Zeile rendert nur
  die ersten ~20 Spalten und scrollt horizontal zum Cursor;
  `input_height/1` misst nur Newline-Zeilen. Optionen: (a) Soft-Wrap im
  eigenen Render-Layer inkl. Cursor-Mapping und Höhen-Mathematik,
  (b) NIF patchen/vendorn (nicht landbar), (c) „mehr Text rechts“-
  Indikator (löst es nicht allein).

## Session-Storage (ADR 020)

Die Engine ist **umgestellt** (ADR 020 R16 + ADR 023): ein SQLite-DB pro
Store, `sessions`/`messages`/`display` als Tabellen, Listing liest
Metadaten-Spalten statt States zu dekodieren, Export ist im Picker.
Damit ist aus dem alten P3-Befund nur noch offen:

* **ADR 020 von `Proposed` auf `Accepted` heben** (der Doc-Status ist
  stale).
* **Import** existiert bewusst nicht: `binary_to_term` ohne `[:safe]`
  ist für lokale Eigentümer-Dateien ok, ein Fremd-Import bräuchte erst
  Safe-Decoding (ADR 020, Export). Nur anfassen, wenn Import gewollt ist.
* Offene Fragen R-Nummern siehe ADR 020 selbst.

## Struktur & Kosmetik (P4)

* `tui.ex` aufteilen (~4400 Zeilen; interner Aufbau nur durch
  `# --`-Kommentare getrennt) und den Mount-State **einmal** definieren
  (`mount_picker` ~114, `mount_session` ~212).
* `TranscriptView.metrics/…` als **eine** Heimat der Pane-Geometrie —
  derzeit verstreut (`content_width`, `pane_size`, Overlay-Raum).
* `test_mode?`-Branches durch injizierte Behaviours ersetzen, wo sie
  schon Bugs durchgelassen haben (8 Stellen in `tui.ex`).
* **P3: `shift+tab` (`back_tab`) ist ungebunden.** Die Bridge mappt den
  Code, der Keymap bindet ihn nicht; das Intent-Vokabular (ADR 021) muss
  entscheiden, was er bedeutet.
* **Glyph-Pässe** (kosmetisch, nur breitensichere geometrische Glyphen):
  Approval-Dialog druckt noch `y = approve …`; Info-/Warn-/Fehlerzeilen
  tragen `✖` als eingebackenen String statt eines rollen-gewählten
  Leitglyphs; Picker-Zeilen nutzen `to_string(status)` statt
  `Styles.status_badge/1`.

## UI-Redesign — offen

Die Runden 1–4 (Palette/Styles, `UI.Composer`, Bottom-Row-Wegfall,
`UI.LiveBand`) sind umgesetzt; Befunde und Entscheidungen stehen in
ADR 018 (Amendment „the running/next split gets its own row“) und im
`Styles`/`Palette`-Moduldoc. **Runde 5 (Sidebar-Neugliederung) ist
umgesetzt**: drei durch Leerzeilen getrennte Blöcke — Überschrift
(Scope), Identität (Agent/Modell/Provider/Session), Kosten (Effort mit
den Token-Zeilen) — plus die ctrl-Hinweise. Offen:

* **O2** Air pro Eintrag differenzieren (Vorschlag: tool 1 / info 1 /
  reasoning 2 / assistant 3) statt `@air 3` überall.
* **O3** Sidebar-Werte ausrichten: **punktausgerichtet erledigt**
  (`Styles.definition_list/2`, `{:decimal, number, suffix}`; die
  Token-Zeilen der Sidebar nutzen es). Offen bleibt **rechtsbündig**
  (Padding im `Paragraph` oder echte `Table`).
* **O4** Sidebar-Titel `" status "` **erledigt**: der Blocktitel ist weg,
  die erste Inhaltszeile ist der **Scope** (Basename von `scope_root`) in
  der Rolle `:emphasis` (`Styles.heading/2`) — eine Body-Zeile, flush mit
  den Zeilen darunter; ein Titel auf `borders: [:right]` stand eine Zelle
  eingerückt und las sich weder als Überschrift noch als Inhalt.
* **O5** ~15 leere Sidebar-Zeilen: **entschieden — ruhig lassen**. Das
  Panel ist fertig gegliedert, der Leerraum darunter trägt keine
  Information; Füllen wäre Dekoration.
* **O6/O12** Band interaktiv machen: Rail `▌` links, Provider/Effort
  farbcodiert; das Band nimmt heute keine Tastendrücke. Berührt das
  Padding-Entscheid (ADR 018 Amendment: 1 Zelle auf allen vier Seiten).
* **O7** Sidebar entdoppeln (Modell/Effort raus, wenn das Band sie
  zeigt) — das Band zeigt das Modell nur im Busy-Fall, die Duplikation
  im Idle bleibt. **Teilantwort aus Runde 5:** das Modell steht nicht
  mehr als ein geklipptes Badge (32 Zeichen, `model ollama_cloud:
  deepseek-v4.1-fl…`) da, sondern in seine zwei Hälften zerlegt
  (`model:` + `provider:`, dieselbe Regel wie `Request.build/2` und
  `ProviderHealth.probe_model/2`) — beide Hälften passen jetzt ganz;
  die Dublette zum Band selbst bleibt offen.
* **O8** Markdown-Politur: `#`-Präfixe bleiben sichtbar, Fences bleiben
  literal, Inline-Code-bg ist hart `:black` (F9-Messung; die Crate
  `tui-markdown` ist die Ursache, nicht `hard_breaks`).
* **O10** „wide bar“ aus dem ratatui-Beispiel: Picker-Auswahlzeile oder
  Vorbild für die Rail?
* **O11** Latente Duplikation: `Tui.entry_widgets/3` baut
  Reasoning/Tool/Info-Widgets nach, die `TranscriptView.widget_for/3`
  fürs Messen schon baut — „measure = paint“ hält nur zufällig.
* **O13** Overlay-Höhe jenseits des Popups: `budget`/`doom`/`question`
  klemmen (Höhe auf `div(area.height, 2)` begrenzt), nur das Menü
  fenstert. Erst relevant, wenn ein Overlay höher wird.

## TUI-Wunschliste (ROADMAP „Later“, Nutzerliste)

* **Navigator** (ctrl-g: Go To Questions / Blocks) — vom Owner als
  wertvollstes Stück bezeichnet; die Platzierungs-Mathematik existiert
  (`block_at_row/2`).
* **Frame-Scrolling-Artefakte** — der Owner fixt selbst, kein Stopper.
* **Approval-Arg-Editing** im Dialog (`e` ist reserviert, zeigt
  „soon“).

## UI-Leitplanken (bleiben; Heimatorte statt Alt-Doc)

* Keine Farbe an der Aufrufstelle — nur Rollen/Surfaces (`Styles`/
  `Palette`-Moduldoc).
* `measure = paint`: Höhen-Rechnungen nur gemeinsam mit dem Renderer
  ändern (ADR 028).
* Der Transcript-Hintergrund bleibt die Terminal-Vorgabe; nur
  App-Flächen sind gefüllt (`Palette`).
* Farb-Asserts nur über `CellSession` (`TuiCase`-Moduldoc zu
  `start_cell_tui/2`).
* Was eigene Daten **und** eigene Funktionen hat, wird ein eigenes Modul
  (Owner-Entscheidung; `Composer`/`LiveBand` sind die Präzedenzfälle).

## Doku-Staleness

* **ADR 020** steht auf `Proposed`, ist aber versendet (SQLite-Engine
  läuft, `exqlite` drin).
* **ADR 018** steht auf `Proposed` (das Amendment sagt Accepted; Teil 1
  ist shipped).

## Offene ADR-Fragen

Nicht duplizieren — sie stehen in den ADRs selbst: 025 q3, 026 q1–3,
027 q1–3, 028 q1–3, 029 q1–3, 024 q2–3, 020 q2, 022, 018 (Tab-Design in
Amendment (ii) beantwortet; offen nur die Keys/Cap-Config), 007 (Proposed:
Spezialisten-Matrix, Produktthese, ungebaut).
