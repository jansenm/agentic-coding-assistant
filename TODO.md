<!--
SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>

SPDX-License-Identifier: MPL-2.0
-->

# TODO — der aktive Backlog (Features)

Stand: 2026-10-04, Branch `dev/mjansen`. Diese Datei ist der **kurzfristige
Feature-Backlog**: was als Nächstes gebaut oder entschieden werden will.
Der große Plan steht in `ROADMAP.md` (Phasen, Produktthese, „Later“-Ideen,
Ground Rules), **Entscheidungen** in den ADRs (`docs/source/decisions/`).

**Erledigtes fällt hier raus.** Die Commits und die ADRs sind der Record —
es gibt bewusst keine „Erledigt“-Chronik mehr. Review-Befunde und
Harness-Feedback sind **Issues im GitHub-Projekt** (ein Issue je Befund, die
Nummer im Titel ist die ID, Konvention in `review-process.md`); sie gehören
nicht in diese Datei.

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
  → Fortschritt: `Sidebar`, `Dialogs`, `Stats`, `Overlay`, `Display`, `Tabs`
  sind eigene Module; `tui.ex` 6044 → **4803**. Der Mount-State ist **offen**
  (siehe „Maps → Structs", Punkt 1).
  → Struct-Zug 2026-11-25 (`UI.State`): der benannte Rest der Stelle — der
  Mount-State — ist **einmal** definiert, `mount_picker` ganz weg,
  `mount_session` 148 Zeilen (der Rest ist IO/Start, kein Felder-Literal),
  `tui.ex` 4803 → **4600**. Offen ist der Rest der Abschnitte (Picker,
  Menu-Modus, `@`-Picker, `/`-Palette, Session-Events, Agent-Slots), dazu
  die vier Value-Maps im State als Dictionary-Kandidaten („Maps → Structs",
  Punkt 1).
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

## Maps → Structs

**Regel (Owner-Entscheidung 2026-11-01):** ein Record, dessen Keys zur
Compile-Zeit feststehen, ist eine **Struct**, keine Map. Maps bleiben nur
**Wörterbücher** (Keys nicht vorher bekannt). Die Regel steht in `AGENTS.md`
(„Maps become structs when the shape is known"); hier steht, **was noch offen
ist**.

Zählung auf `dev/mjansen @ 4bf6063`:
`grep -rl defstruct lib/ | wc -l` → **17 Module** (18 Vorkommen; `ui/tabs.ex`
hat zwei), und `grep -rn '@type [A-Za-z_]* :: %{' lib/ | wc -l` → **26
Map-Shapes**. Davon sind **4 Wörterbücher** (`Permissions.entries`,
`Permissions.layer`, `Question.question`, `Keymap.t` — Keys nicht vorher
bekannt), also **22 Records**, die eine Struct sein sollten.

Zwischenstand (`refactor/tui-state-struct`, 2026-11-25): `UI.State` ist
Struct. Die `@type`-Zahl bleibt 26 — der TUI-State stand nie in ihr (er
hatte kein `@type`, nur zwei anonyme Literale), und die Value-Maps im State
(`menu_popup`, `file_popup`, `command_popup`, `question_prompt`) sind neue
Dictionary-Kandidaten, die bislang in keinem `@type` standen (Punkt 1).

### 1. Der TUI-State — erledigt (`UI.State`, 2026-11-25)

`ui/tui.ex` hielt den State als zwei anonyme Map-Literale — `mount_picker/4`
(53 Felder) und `mount_session/3` (64 Felder), Union **67**. Zwei Literale
derselben Form heißt: ein neues Feld einzutragen ist ein Edit an zwei
Stellen, und ein Feld, das nur in einem steht, ist ein `nil` an der anderen.
Dazu kam ein Feld, das in **keinem** der beiden Literale stand: `:last_pane_rect`
wurde von `remember_pane_rect/1` per `Map.put/3` geschrieben und von
`last_pane_rect/1` per `Map.get/2` gelesen (Poll-Erkennung, `68b9ecd`) — es
funktionierte, weil Maps jedes Key aufnehmen; eine Struct hätte den Fehler
beim ersten Compile gezeigt.

Belege für den Preis (gleiche Zählung auf `4bf6063`):

| Maß | Zahl |
| --- | --- |
| `%{state \| …}`-Updates | 123 |
| `state.x`-Lesezugriffe | 176 |
| `Map.get(state, :k)` | 80 (davon 33 **mit** Default) |

Die 33 Defaults waren der eigentliche Befund: sie sind die Stellen, an denen
der Code *nicht wusste*, ob das Feld existiert.

Was daraus geworden ist (`lib/coding_agent/ui/state.ex`, 261 Zeilen): die
68 Felder der Union plus `:last_pane_rect` in den Gruppen Sitzung /
Agent-Slots / Transkript/Eingabe / Dialoge / Overlays / View / Picker / Meta,
mit `@type t`; die Feld-Kommentare der alten Literale leben im `defstruct`.
Ein `base/1` trägt die Neutralwerte UND die Opts-Entscheidungen (die
`textarea_new`-Referenz pro Mount, test_mode — die eine Lesung, die früher
`test_session?/1` in beiden Mounts doppelt las); `picker/4` und `session/2`
sind die beiden Mount-Formen darüber. `session/2` füllt per `struct!`, ein
Feld, das die Struct nicht kennt, kracht am Mount statt still als `nil`.
Die 33 `Map.get(state, :k, default)`-Idiome sind ihre Struct-Defaults
geworden: `Map.get(state…)` steht in `tui.ex` noch **einmal** (das
Width-Map von `menu_popup` — ein Wörterbuch, keine State-Gruppe),
`Map.put(state…)` nullmal. Der eine dynamische Put (`open_pause/3`, review
P3) geht durch `struct!/2`, der falschen Key laut verweigert, wo `Map.put/3`
ihn still in die Struct-Map graftiert hätte. Die Snapshot-Lesestellen
(`restored.usage`, `restored.timing`) sind direkte Feldzugriffe: das
Heilen alter Formen passiert am Load-Edge (`Store.load`), nicht in der
Mitte.

Offen aus diesem Schnitt: die vier Value-Maps im State sind weiterhin Maps —
jede ist ein Dialogwert (ein Dictionary-of-the-moment), keine State-Gruppe;
ein eigener Struct je Dialog ist ein eigener Eintrag, nicht ein Teilpunkt.

### 2. Die Records mit den meisten Aufrufstellen

Gemessen als Vorkommen von `Modul.typ` in `lib/` + `test/`:

| Ort | Form | Refs | Warum es sich lohnt |
| --- | --- | --- | --- |
| `Core.Tools.scope` | `%{required(:root) => …, optional…}` | **30** | `%{root: …}` steht **15×** in **9** Dateien (davon `%{root: root}` 9×); jede Tool-Datei baut ihren Scope selbst, und `Tools.in_scope?/2`, `FileExec` und `Sandbox` lesen ihn unterschiedlich. Eine `Scope`-Struct mit `new/1` macht die 5 optionalen Felder (`mounts`, `session_id`, `shell_mode`, `depth`, `subagents`) zu benannten Feldern statt zu `Map.get`-Raten. **Größter Einzelgewinn.** |
| `Core.Sandbox.profile` | `required`/`optional`-Map | 11 | Produzent (`Sandbox`) und Verbraucher (`Bwrap`, `Spill`, `Shell`) sind getrennte Module; ein Tippfehler im Grant-Namen fällt heute nur als „Grant fehlt" auf — also als stiller Rechteverlust (ADR 015: „must refuse, never silently widen"). |
| `Core.Session.Export.data` | 7-Feld-Record | 7 | Wird nach JSON gerendert; die Feldnamen sind Vertrag. Struct + `Jason.Encoder`-Ableitung wäre **eine** Wahrheit statt String-Keys im Renderer. |
| `Core.Costs.snapshot` | 6-Feld-Record | 6 | Zählerstände, die im Sidebar/`stats` landen. |
| `Core.Sandbox.Mounts.t` | 3 Listen | 4 | Schon ein Record, nur ohne Struct — `%Mounts{}` wäre ein Ein-Zeilen-Umbau. |
| `Core.Costs.balance` **und** `Core.Session.Usage.balance` | **zwei** identische 5-Feld-Shapes | 3 + 0 | Der Produzent (`Costs`) und der Speicher (`%Usage{balance:}`) definieren denselben Typ doppelt. Eine Struct (`Costs.Balance`) löscht die Kopie. |
| `Core.Interrupt.snapshot` | 3-Feld-Record | 3 | Nur Diagnose/Test, aber der einzige Weg, den Interrupt-Zustand zu lesen. |

### 3. Die kleinen Records (mechanisch, ein Record pro Commit)

`Core.Region.result` (6 Felder, wird von `MoveRegion` in Fehlermeldungen
zerlegt), `Core.Session.Gate.plan` (5 Buckets), `Core.Session.Timing.round`
(`%{round, llm_ms, tool_ms}` — der Typ existiert, `Timing.last` speichert ihn
aber als Map), `Core.Checkpoint.t`, `Core.Spill.writer` (10 Felder,
`File.io_device()` darin), `Core.Session.Subagent.result`,
`Core.Providers.Discovery.model_entry`,
`Core.Providers.Catalog.Refresh.report`, `UI.Styles.status_badge_t`
(3 Felder, an 7 Stellen als Map gebaut), `UI.Commands.t` (16 Records über
`cmd/6`), `UI.Keymap.event` und `UI.Keymap.pattern` (je 2 Felder — der
Tastendruck-Pfad, also der heißeste; ein Struct ist hier vertretbar, aber
nicht wichtig).

**`UI.Menu.t` / `UI.Menu.item` sind der Sonderfall:** der Typ existiert,
**keine** Stelle im Baum referenziert ihn (`Menu.t`/`Menu.item`: 0 Treffer),
und der TUI hängt ein Feld an, das der Typ nicht kennt — der `/stats`-Popup
setzt `width: 74` und liest es als `Map.get(menu_popup, :width, 60)`. Genau
dieses „ein Feld, das nur der Aufrufer kennt" ist der Fehler, den eine Struct
verhindert.

### 4. Was **Map bleiben soll** (Wörterbuch oder Fremdform)

* `Permissions.entries` / `Permissions.layer` (`tool => pattern => decision`)
  — Keys kommen aus der Policy-Datei.
* `UI.Keymap.t` (`action => [pattern]`) — Nachschlagetabelle.
* `Core.Session.Question.question` (`%{String.t() => …}`) — **die Form
  diktiert das Modell** (die Keys sind die Felder des `ask`-Arguments). Eine
  Struct erst am Rand, wo wir sie lesen (`Dialogs`/`question_type/2`), nicht
  als Speicherform.
* `Usage.marker` (`map() | nil`) — was der Provider zurückgibt.
* `todos` und die Tool-Argumente — wie `question`, JSON des Modells. Eine
  Struct erst am Rand (`Prompt.fit_todos/1` liest heute
  `todo["content"] || todo[:content]`), nicht als Speicherform.
* `ReqLLM`-Strukturen (`pending_round_calls`/`_results`, `Context`) — fremde
  Module.

### 5. Der Rand, an dem ein Struct-Upgrade passiert

`Core.Session.State` wird als `term_to_binary` persistiert. Ein Feld, das von
Map zu Struct wechselt, braucht `new/0` + `from_map/1` **an der Ladestelle**
(`State.from_map/1`, wie `Usage.from_map/1` es vormacht) — nie eine Migration
mitten im Code, und nie ein `Map.get` als Krücke an den Aufrufstellen.


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
