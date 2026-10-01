# TODO — der aktive Backlog

Stand: 2026-09-30, Branch `devel`. **ADR 030 ist umgesetzt** (Slices
1–7, gelandet); seither sind ADR 031 (`todowrite`), 032 (`@`-Picker),
033 (Provider-Retry), 034 (Slash-Commands), 035 (ex_ratatui-Source-Build),
036 (Undo/Checkpoint), 037 (Compaction: zwei Limits), 038 (Truncation-Spill),
039 (Modell-Katalog als Prozess), 040 (Kontext-Budget sichtbar) und
041 (expliziter Provider-Timeout) gelandet. Seither: ADR 042
(`subagent_model` + der Built-in `explore`, damit der `task`-Pfad live
erreichbar wird) mit dem Amendment zu ADR 017. Die
Review-Records (`review.md`, `review-2026-09-28.md`) sind aus dem
`-mjansen`-Worktree entfernt; ihre offenen Befunde stehen unten im
Abschnitt „Review-Befunde“. Der Merge `dev/mjansen` landete als `ca6f734`
(Sidebar-Blöcke, Decimal-Alignment, Review-Record).

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

## Offene Aufgaben (2026-10-01, Owner)

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
* **`.coding-agent`-Fundort entscheiden** — **erledigt (2026-10-01).**
  Owner-Regel: `scope_root` = das aktuelle Verzeichnis, **kein Suchen**
  aufwärts oder abwärts. `UserConfig.project_dir/1` löst die Projekt-Config
  wieder am Scope-Root auf (der `Repo.root`-Aufruf aus `ee7343b` ist raus),
  `ProjectMemory` liest nur `<scope_root>/AGENTS.md`, `Repo.dirs/1` ist
  entfernt (`Repo.root/1` bleibt **nur** für den Sandbox-`.git`-Bind, der
  den Worktree-Gitfile findet). Offen und bewusst nicht jetzt: der tote
  Projekt-`ui.toml`-Pfad (`Keymap.load/0` liest nur global) und
  `Prompt.git_repo?/1` (prüft nur den Scope-Root).
* **Teil-Repo (`workdir`):** geplant, aber noch nicht gebaut — `scope_root`
  bleibt das aktuelle Verzeichnis (Kontext), ein **explizit konfiguriertes**
  Unterverzeichnis (`[scope] workdir` in `config.toml`) soll die Schreibgrenze
  sein (nur Schreiben scope-beschränkt, Lesen bleibt scope-weit), mit
  klarer Fehlermeldung außerhalb. Undo/Checkpoint bekommt damit seinen
  Umfang; Alternative „eigenes Shadow-`.git` statt Nutzer-Repo" besprochen,
  zurückgestellt.

## Zuerst: Live-Smoke

* **`compact`-Tool: nutzt der Agent es, und wann?** Das Tool ist seit
  `28c4403` da (ADR 040 OQ1), aber noch **nicht live beobachtet**. Der
  nächste lange Lauf zeigt zwei Dinge: (a) findet das Modell den Hebel
  überhaupt (der Budget-Block nennt ihn jetzt), und (b) zieht es ihn am
  richtigen Punkt — **viel Rauschen rein, wenig Ergebnis raus**, nach
  einem erledigten, suchlastigen Schritt, *nachdem* der Ertrag in
  `notes` steht — statt zu früh oder statt `notes`. **Entschieden
  (2026-09-30): erst messen, dann genau eine Nachschärfung.** Wenn nötig,
  dann in der **Tool-Beschreibung** (der Ort, an dem die Entscheidung
  fällt): den Randfall „nach einem lauten, abgeschlossenen Schritt" und
  die notes-first-Regel explizit machen. *Keine* Fahrplan-Semantik
  („nach jedem Todo compacten") — das wäre schlechter als nichts, weil
  jeder Compact Minuten Provider-Zeit blockiert und Detail wegwirft.
  Verworfene größere Option (nicht jetzt): ein dynamisches
  Rausch-Signal im Budget-Block (Anteil Tool-Ausgaben aus erledigten
  Schritten) — eigener Hebel, eigenes Design.

* **Frage-Dialog doppelt gestellt?** Der Race-Fix (ADR 027 Amendment)
  muss live bestätigt werden: der Dialog darf nach der Antwort bleiben,
  wenn der Agent nachfragt; der zweite identische Ask sollte ausbleiben.
  Nur mit echtem Provider prüfbar.
* ~~**Subagent (`task`) live**~~ — **bestätigt (2026-10-01).** Reale
  `task`-Läufe funktionieren: Umschalten in den Tab geht, der Leaf-Report
  kommt an. Der Pfad war bis 2026-09-30 überhaupt erst erreichbar (vorher
  kein delegierbarer Agent → leere Liste, unbekannter `subagent_type`;
  ADR 017 Amendment, ADR 042: `explore` + `subagent_model`). Kein
  offener Punkt mehr.
* **esc stoppt ein laufendes Kind.** Weitergeleitet: die TUI ruft
  `Session.interrupt/1` für jedes aktive Kind (ADR 018 Amendment (ii)).
  Live bleibt zu bestätigen, dass ein esc-Doppeldruck einen langen
  `task`-Lauf wirklich abbricht; der Parent-Worker blockiert weiter im
  Task-Call, das Kind wird über seine eigene Interrupt-Id gestoppt.
  **Mid-tool hard cancel ist erledigt (ADR 043, 2026-09-30):** `Core.Exec`
  liest das Stop-Flag während des Wartens und killt den laufenden Prozess
  binnen eines 250-ms-Ticks — ein hängender `shell` (bis 1800 s),
  `grep`/`glob` oder eine Datei-Operation endet also jetzt auf esc. Live
  noch zu bestätigen: der Doppeldruck beendet einen hängenden `shell`
  wirklich, und der Parent bekommt `STOPPED by the user` statt eines
  Timeouts.
* **ADR 030 live.** Der Umbau ist test-verifiziert (910 grün), aber der
  bwrap-Datei-Pfad lief nur in den Integrationstests: live prüfen, dass
  `read_file`/`write_file`/`edit`/`list_dir` unter echtem bwrap sauber
  arbeiten (inkl. `hide`/`ro`), der Session-Start auf einem Host ohne
  bwrap verständlich verweigert, und `shell`/`git` ohne Rückfrage laufen.
* **hide für Dateien mit `--dev-bind`** wurde live gefunden und gefixt
  (Nodev-EACCES); ein Live-Lauf über die Mount-Konfiguration bestätigt es.

**Erledigt (OOM-Freeze, 2026-09-30):** Ein laufender Befehl, der
unbegrenzt ausgibt (`while true; do echo; done`, `yes`, ein `find` ohne
Ende), brachte den BEAM auf 11 GB; vier OOM-Kills in 26 Minuten füllten
Swap und ließen den Desktop 3–4 Minuten einfrieren (`journald`
Watchdog-Timeout). Ursache: `Core.Exec.collect` puffert **jeden** Chunk
und kürzt erst am Prozessende — auch `read_file` (Cap-Prüfung nach
vollem `cat`) und `grep`/`glob` (`truncate: false` hält alles). Jetzt
**streamt** der Akkumulator: bis 256 KiB puffern, danach Kopf einfrieren,
Tail-Fenster rollen und **während des Laufs** in die Session-Scratch
(ADR 038) schreiben → Speicher O(Cap), nicht O(output). Regressionstest
misst den Peak-RSS eines 40-MB-Produzenten (<30 MB). `read_file` bricht
über seinem eigenen Cap ab (`:max_output`), `grep`/`fd` bekommen bei
einem Runaway ein ehrliches `:raw_too_large` statt OOM. ADR 038
Amendment.

**Erledigt (stiller Turn-Ende, 2026-09-30):** Ein Turn endete `:idle`
**ohne** Abschluss-Message und ohne Fehler. Ursache: der
`{:interrupted, partial}`-Pfad im Loop rief immer `complete_turn(partial,
[])` — kam der Stop **während des Reasonings** (oder vor dem ersten
Delta), war `partial == ""`, und es wurde eine **leere**
Assistant-Message angehängt plus ein leeres `llm_message` gesendet:
sichtbar passierte nichts, als hätte der Agent „einfach aufgehört".
`interrupted_turn/2` trennt jetzt: nicht-leerer Text bleibt die Antwort
(esc-Parität), leerer Text geht auf denselben Pfad wie der Stop
zwischen Rounds (`stop_at_boundary`: idle + „· turn stopped (esc)" +
Flag gelöscht). Beide Aufrufer (Haupt-Loop und Wrap-up) laufen dadurch.
Test über die `@doc false`-Naht. Commits `e8281f0`, `36611d2`.

**Erledigt (Review-Abarbeitung 2026-09-30, `review-devel-2026-09-30b.md`):**
der Record bestätigte die zwei Fixes und brachte 8 neue Befunde — alle
abgearbeitet. **Korrektheit:** `N33` (der Stop-/Deadline-Check lag nur im
`after`-Tick, der bei einem **redseligen** Befehl nie feuert; gemessen:
20-ms-Takt mit 60-s-Deadline stoppte erst bei 60068 ms. `check_stop/5`
läuft jetzt **auch nach jedem Chunk** — Stop in <500 ms, Deadlines exakt;
ADR 043 Entscheidung 4 korrigiert), `N33b` (Saturations-Deadline greift),
`N34` (`Process.info(:memory)` sieht refc-Binaries nicht → der OOM-Test
war auf der fehlerhaften Fassung grün; jetzt `Process.info(:binary)` +
langsamer Produzent, Peak flach ~3–16 MB statt O(output)), `N36`
(Whitespace-`partial` → `String.trim`), `N37` (`read_file` nahm cap+1),
`N38` (`:raw_too_large` materialisierte den 64-MiB-Puffer). **Spill:**
`N35` (der streamende Writer verlor den Schwanz; hält jetzt Kopf **und**
Schwanz wie `spill/3`, Tail amortisiert gerollt). **Doku/Typen:** `N39`
(`@type outcome`, ADR 038s `Exec.truncate/1`→Accumulator, `collect/4`→`/5`).
`N40` (fremder Report im Exec-Commit) bewusst gelassen: der Report bleibt
(Owner-Wunsch), landet aber nicht rückwirkend in einen eigenen Commit
(landed commits werden nicht amended). Commits `82f3000`, `ef7af3a`.

**Erledigt (live `:empty_summary`, 2026-09-30):** Ein erfolgreicher Turn,
dann `compaction failed (:empty_summary)`. Der Turn-Pfad retried einen
leeren Provider-Response (ADR 033), der Summarizer nicht — ein
sporadisch leerer Response übersprang die Compaction bei übervollem
Kontext für 3 Turns. `do_compact` retried `:empty_summary` jetzt einmal
an der `summarize_fn`-Naht. Commit `2664034`.

**Erledigt (Review-Abarbeitung 2026-10-01, `review-devel-2026-09-30c.md`):**
der dritte Record bestätigte N33–N40 per Messung und brachte 12 neue — alle
abgearbeitet, dazu der live gefundene Reasonung-Tab-Bug (`5559f07`).
**Hoch:** `N41` (`compact_now/2` gab für „nichts zu compacten" und „Summary
fehlgeschlagen" dasselbe `{state, false}` — das Modell las bei einem Timeout
wörtlich „no older exchange"; jetzt ein getaggtes `outcome` `:changed |
:nothing | :interrupted | {:failed, reason}`, und der Tool-Pfad respektiert
`compaction_backoff`), `N42` (die „reclaimed"-Zahl zog den `projected_tokens`
ab, der Framework-Prompt **und** Tool-Schemas enthält → jeder Report trug die
~4k Overhead, konnte bei kleinem Kontext einen **Zuwachs als Gewinn** melden;
jetzt der Delta des gespeicherten Kontexts), `N43` (ein modell-initiierter
Compact war nicht abbrechbar — bis ~600 s mit totem esc, die Form, die ADR 043
verhindern soll; die Warteschleife pollt jetzt `Interrupt` alle 250 ms).
**Mittel:** `N44` (Tool-Text versprach „the detail you still need stays",
`split` hält nur die letzten ~3 Exchanges), `N45` (keine Policy konnte das
Tool fencen; die Interception prüft jetzt das beworbene Toolset).
**Niedrig:** `N46` (der Empty-Retry duplizierte die „compacting…"-Note),
`N47` (Doc „must not block"), `N48` (ADR 040s Eröffnungsnote widersprach
Decision 5), `N49` (zwei Spill-Marker → einer), `N50` (`{:raw_too_large,
size}` zählte den überlaufenden Chunk nicht), `N51` (staler `cap + 1`-Satz).
**Flake:** `N52` (der N28-Test maß die Wall-Clock einer kalten Session, der
einmalige ~3–4-s-llm_db-Load lag darin → ~1/3 rot; jetzt ab dem Accept
gemessen, 8 Seeds stabil). Commits `5559f07`, `01f0ec2`, `39cf26e`, `3534b93`,
`5381796`, `214a000`.

> **Prozessfehler, festgehalten (N57):** Diesen Record hat der Triage-Agent
> **gelöscht** (`rm -f`) statt umbenannt — mit einem angehängten **Teil 6**
> (N53–N56), der nie triagiert war. Er überlebte nur, weil ein Checkpoint-Blob
> ihn hielt. Die vier Befunde sind in `review-checkpoints-adr036.md` neu
> geschrieben und unten abgearbeitet. **Ab jetzt gilt `review-process.md`:
> umbenennen (`review-<subject>.md.triaged`), nie löschen; die Review-Artefakte
> bleiben liegen. Löschen ist die Entscheidung des Owners.** Commit `e2aa831`
> ist genau der `rm`-und-`TODO.md`-Commit.

**Erledigt (Review-Abarbeitung 2026-10-01, `review-checkpoints-adr036.md`,
N53–N57):** Der verlorene Teil-6-Record, neu geschrieben und vollständig
abgearbeitet. **Hoch:** `N53` (die Checkpoint-Kette `-p previous` hielt jeden
getrimmten Snapshot ewig als Vorfahr, `git gc` konnte ihn nie freigeben —
`checkpoint_depth` begrenzte Refs, nicht Objekte; gemessen 65 nur-über-Refs
erreichbare Objekte/109 kB, 7 von 14 Refs mit >1 Commit bei Tiefe 1. Jetzt
**Root-Commits**, kein Parent; nichts traversiert die Kette), `N54` (Refs per
Commit benannt, kein Owner, kein Reconcile — ein Ref einer gelöschten/gekillten
Session lebte ewig. Session-ID zurück in den Ref-Namen
`<prefix><session-id>/<commit>` wie ADR 036 Schritt 4 es schon behauptete, plus
`Checkpoint.reconcile/2` beim Session-Start, das Refs verwitweter Sessions
verwirft. Bewusst konservativ: nur Refs im neuen, attribuierbaren Format sind
Kandidaten — ein unattribuierbarer Legacy-Ref, genau die Form, die den
verlorenen Record hielt, wird **nie** angefasst; live verifiziert: 0 von 14
verworfen). **Mittel:** `N55` (`checkpoints_for_cleanup/1` gab `nil` sowohl für
„keine Refs" als auch „State nicht lesbar" → stiller Leak; jetzt geloggt,
Reconcile als Backstop), `N57` (Prozess, s.o. — `review-process.md`). **Niedrig:**
`N56` (ADR 036 Schritt 3 begründete eine Kette, die niemand traversiert;
`State.t()`-Doc nannte `index_backup`, das es nicht gibt). Commit `857190e`.
Der uncommittete Prompt-Feinschliff im Review-Worktree
(`agents/plan.md`, `prompts/{default,claude}.txt`) ist separat und bleibt dem
Owner.

## ADR 030 — One boundary (umgesetzt 2026-09-27)

Der Umbau aus `docs/source/decisions/030-one-boundary.rst`: **eine**
Grenze (bwrap), Datei-Tools als confined Prozesse, kein Session-Start
ohne confinement. Alle sieben Slices sind gelandet:

1. **Session-Start verweigert ohne confining Sandbox.** ✅ `Sandbox.impl/0`
   ohne `None`-Fallback; `Sandbox.refusal_message/0`; `Session.init/1`
   verweigert. `Sandbox.None` ist Test-Seam; `config/test.exs` pinnt den
   confining Stub, `SandboxCase.put_sandbox/1` restauriert.
2. **`Exec` bekommt stdin + env.** ✅ `run/5` mit `:stdin` (als
   `{:stdin, count, spec}`; der Pipe-Close ist EOF) und `:env`.
3. **Datei-Tools über `Exec`.** ✅ `Tools.FileExec`: `cat`/`tee`/`ls -
   1 -p`; `edit` = confined read + BEAM-Ersetzung + confined write.
4. **Allow-by-default für `shell`/`git`.** ✅ `Gate.fallback_for/2` ohne
   Confinement-Probe; Escalations fragen weiter; die Allow-Klasse umfasst
   shell/git.
5. **`in_scope?/2` ist Discovery.** ✅ Moduldocs und der Path-Hardening-Test
   sagen das; die Tool-Escapes laufen über die echte Profil-Semantik
   (`Sandbox.FileToolsConfinementTest`). `check_scope!/2` und
   `Containment.walk/3` wurden im Aufräumschritt gelöscht (keine
   Produktionsnutzer mehr); `Containment` hält nur noch die
   hidden-Regeln und `default_skip_dirs/0`.
6. **`grep`/`glob`-Fallback entfernt.** ✅ `rg`/`fd` sind Pflicht; ein
   fehlendes Binary ist ein klarer Fehler. Die Referenz-DIALEKT lebt als
   Filter (`Glob.file_match?`, hidden-Regeln), die fd-Enumeration ist
   breit + gefiltert.
7. **F7 (Git-Editor).** ✅ `Exec.agent_env/0` (GIT_EDITOR/GIT_PAGER/…),
   von `git` und `shell` genutzt.

## Nächste Schritte (priorisiert)

0. **Doku: Reference-Quadrant — erledigt (2026-10-01).**
   `reference/{index,configuration,commands}.rst` existierten; ergänzt um
   `reference/cli.rst` (`mix tui`-Flags, Env-Vars, Datei-Orte) und
   `reference/tools.rst` (Read-only/Gated/Delegation-Buckets, Scope,
   Caps), beide in der `index.rst`-Toctree. Drift-Tests decken die
   Config-Fläche ab (`test/coding_agent/docs/config_reference_test.exs`);
   CLI/Tools sind (noch) nicht drift-getestet. Anwender-Doku = Reference
   (Fakten); Tutorials/How-tos bleiben später.
1. **Nächster offener Feature-Punkt.** T14 ist erledigt (ADR 038); die
   verbleibenden T-Punkte sind T9 (`websearch`) und T10
   (`apply_patch`/LSP/Skills/MCP/Fuzzy-Edit, der größte Brocken). T13
   (verschachtelte `AGENTS.md`) ist erledigt (2026-10-01).

2. **Compaction: zwei Limits + verlustfreie Summaries (ADR 037).**
   **erledigt (2026-09-29):** Der Trigger ist jetzt prozentual vom
   Modell-Fenster (soft 50 %, idle-Hintergrund) mit absoluter Reserve
   unter dem Top (hard, pre-call); `Compaction.render/1` trägt
   Tool-Namen/-Argumente, der System-Prompt überlebt, die Tail-Grenze
   ist exchange-sicher. Details in
   `docs/source/decisions/037-compaction-two-limits.rst`.
   ~~**Reminder / bewusst vertagt (Owner 2026-09-29):** das Fenster wird
   einmal beim Init aufgelöst; ein Modellwechsel löst es nicht neu auf.~~
   **Erledigt (N9):** `Session.recompute_window/1` löst bei jedem
   Modell-/Agentenwechsel und beim Katalog-Warm neu auf. Offen bleibt nur
   die Frage, ob eine Pro-Modell-Tabelle (`[context_windows]`) gewünscht
   ist — die einzelne Key-plus-Katalog-Kette reicht derzeit.

   **Owner-Befund „the compact window is once again too big to compact"
   (2026-10-01) — adressiert.** Ursache: Das Live-Modell
   `ollama_cloud:deepseek-v4.1-flash` steht **nicht** im Katalog
   (`Catalog.context_window/1` → `:unknown`), also fiel die Auflösung
   still auf den 500 000-Token-Default: soft 250k, hard 436k, während die
   Live-Session bei `last_input_tokens = 152 290` erst 61 % des soft-Limits
   erreicht hatte. Die `300090 chars rendered` aus früheren Läufen waren
   das separate Span-Cap, nicht das Fenster. **Behandlung (Owner-Wahl:
   „konfigurieren + sichtbar machen"):** `Config.context_window_resolved/2`
   nennt jetzt die Herkunft (`:configured | {:catalog, n} | :loading |
   :fallback`); ein `:fallback` loggt einmal pro Session eine
   handlungsfähige Warnung (Modell, angenommenes Fenster, Config-Key) und
   markiert die Sidebar-Zeile `soft at` als `(assumed)`. `context_window`
   in `config.toml` setzen behebt es. Getestet: `Catalog`/`Config`; das
   Owner-Feedback war zuerst in opencode beobachtet, die hiesige TUI ist
   dort überlegen, die Absicherung bleibt trotzdem sinnvoll.

## Kern-Features gegen opencode (T-Liste)

| # | Punkt | Stand |
| --- | --- | --- |
| T4 | `todowrite`/Plan-Tool | **erledigt** (2026-09-28, ADR 031) |
| T5 | `task`/Subagent inkl. Tab (ADR 017/018) | **erledigt** (2026-09-25): Seam + Tabs (Amendment (ii)) — Wire-Tagging, in-memory Tabs, Tab-Leiste/ctrl-x, Parallel-Cap |
| T7 | Slash-Commands/Command-Palette | **erledigt** (2026-09-29, ADR 034): `/`-Palette, `/help`, `ctrl-x`-Menü aus einer Registry. `/compact` (ADR 037) nachgezogen |
| T8 | Undo/Redo via Git-Checkpoint + `/undo` | **erledigt** (2026-09-29, ADR 036): Checkpoint pro Turn, `/undo` stellt Dateien wieder her |
| T9 | `websearch` neben `webfetch` | offen (Such-API-Abhängigkeit; `webfetch` ist da) |
| T10 | `apply_patch`, LSP, Skills, MCP — inkl. fuzzy-match-Kette für `edit` | offen; `edit` ist exakt-match-only (opencode hat 9 Fuzzy-Strategien + LSP-Diagnostik nach jedem Edit) |
| T13 | Verschachtelte `AGENTS.md` | **erledigt (2026-10-01), überarbeitet:** `ProjectMemory` liest **nur** `<scope_root>/AGENTS.md` — kein Aufwärts-Walk (oberhalb des Scope existiert für uns nicht). Unterordner-Dateien werden **nicht** rekursiv gelesen, sondern im Abschnitt „Deeper files" erwähnt (der Agent liest sie selbst). Eine dynamische Injektion beim Datei-Zugriff (opencode-Stil) wurde erwogen und **verworfen**: Pull über den Zeiger deckt den Bedarf, Injektion hätte ein Shell-Loch und Kosten. |
| T14 | Truncation spült Volltext in eine abrufbare Datei | **erledigt** (2026-09-29, ADR 038): Overflow aus `Exec`/`grep`/`webfetch` landet im Scratch (als `/tmp/...` sichtbar), der Hinweis nennt den Pfad; `read_file` liest per `offset`/`limit` fensterweise auch Dateien >256 KiB |
| T1/T2/T3/T6/T11/T12 | Framework-Prompt (ADR 024), Doom-Guard (ADR 026), Agentenfelder (ADR 024/025/029), `question` (ADR 027), Store-Flake, Provider-Prompts (ADR 024) | **erledigt** |

## Dogfooding-Blocker (B)

* ~~**B3** Dateien anhängen~~ — **erledigt (ADR 032, 2026-09-28):**
  `@` am Wortanfang öffnet einen menü-artigen Picker (confined `fd` via
  `Core.Tools.ListFiles`, Profil/Mounts beachtet); Auswahl fügt den Pfad
  ein. Inhalt-Anhängen bleibt eine offene Frage in ADR 032.
* **B5** Input-Auto-Wrap — **vom Owner vertagt** (2026-09-19), nicht
  anfassen, ohne dass es weh tut. Messung für die Wiederaufnahme:
  `%Textarea{}` hat **kein** `wrap`-Feld (die Crate
  `ratatui-textarea` 0.9.2 kann es nicht); eine lange Zeile rendert nur
  die ersten ~20 Spalten und scrollt horizontal zum Cursor;
  `input_height/1` misst nur Newline-Zeilen. Optionen: (a) Soft-Wrap im
  eigenen Render-Layer inkl. Cursor-Mapping und Höhen-Mathematik,
  (b) NIF patchen/vendorn (nicht landbar), (c) „mehr Text rechts“-
  Indikator (löst es nicht allein).
* ~~**B6** Provider-Timeout ohne Retry / stiller leerer Abschluss~~ —
  **erledigt (ADR 033, 2026-09-29):** `call_llm/2` wiederholt einen
  Transport-Timeout (max `provider_retries`, Default 3, Delay
  `provider_retry_delay_ms`, Default 5000 ms) und verbucht einen leeren
  „sauberen“ Stream-Abschluss als benannten Fehler statt als idle-Turn.
  Zusätzlich: `Session.state/1` fängt `:exit` ab (kein TUI-Absturz mehr
  bei einem `:state`-Timeout).

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

## Review-Befunde (offen; aus `review.md` / `review-2026-09-28.md`)

Die beiden Review-Records sind aus dem `-mjansen`-Worktree entfernt — der
Record selbst bleibt in der Historie (`review.md` via `ca6f734`). Anker
sind **Symbol + Commit**, keine Zeilennummern (die Lehre aus den Rebases).

**Erledigt (Review-Abarbeitung 2026-10-01, `review-devel-2026-10-01.md`,
N58–N66):** der Record bestätigte N53–N56 per Messung (Root-Commits,
Reconcile lässt 0/14 Legacy-Refs liegen, `:internal` nicht wählbar) und
brachte neun neue — alle abgearbeitet. **Mittel:** `N58` (ein **gepinnter**
Compaction-Modell wurde mit dem vollen 300k-Zeichen-Cap vertraut, solange
der Katalog `:loading`/`:unknown` ist — genau das kleine-Fenster-Versagen,
das ADR 044 verhindern soll, und der Zweig, den ein erster Over-Limit-Turn
trifft; jetzt fällt ein unverifiziertes Pin auf das **Session-Modell**
zurück), `N61` (Checkpoint-Refs hingen an `System.unique_integer`, das in
jeder VM gleich beginnt, während `.git` und Default-Store über Worktrees
geteilt sind; `Session.new_id/0` liefert jetzt eine ULID, und der Ref ist
zusätzlich nach **Store** namespaced — fremde Stores verwirft Reconcile
nie), `N64` (`.gitignore review-*.*` verschluckte auch
`review-process.md`; `!review-process.md` ergänzt und die Konvention ins
Repo geholt). **Niedrig:** `N62` (der N55-Skip war `Logger.debug`,
gefiltert; jetzt `warning`, aber nur für einen **kaputten** State — ein
lesbarer ohne Refs und ein nie persistierter Subagent bleiben still), `N63`
(Reconcile lief synchron in `Session.init/1` über einen 60-s-Git-Call;
jetzt ein crash-sicheres `Task.start/1` **off** dem Startpfad), `N65`
(veraltete Handover-Zeile in `review-process.md`), `N66` (Budget-Block und
Guard lasen `tool_budget` über zwei Funktionen; der Block nutzt jetzt
dieselbe wie `gate_tools`), `N59` (`bound_summary`-Kommentar zitterte den
entfernten `max_tokens`-Cap), `N60` (`explanation/memory.rst` nannte den
Summarize-Call „non-streaming … on the same model"). Commit `323c187`;
der Record liegt als `review-devel-2026-10-01.md.triaged` daneben.

**Erledigt (Review-Abarbeitung 2026-09-30, das zweite `review.md`):** alle
15 neuen Befunde `N1`–`N15` sind abgearbeitet — `N2` (grep verlor eine
benannte Einzeldatei; `-H`), `N1` (`hard` kollabierte bei Fenstern unter
der Reserve; Floor auf 75 % des Fensters), `N7` (tote Session riss die TUI
aus den Aktionsverben; ein `safe_call/5`), `N5` (die Katalog-Hälfte des
Modell-Menüs war leer; String-vs-Atom **und** `available_models`-Arity —
dazu `Catalog.ready?`-Guard gegen den Kalt-Lock, N12), `N9` (Fenster wurde
beim Modellwechsel nicht neu aufgelöst; `Session.recompute_window/1`),
`N3` (1-MiB-Walk-Cap dokumentiert), `N12/N13/N14` (Doku), `N6/N10/N11`
(Nits), `N8` (Doku-Zeile, wo man die Notizen liest), `N4`/`N15` waren
schon erledigt bzw. bestätigt. Commits `a244f99`…`e78cc94`.

**Erledigt (Review-Abarbeitung 2026-09-30, `review-fdbeaed.md`):** die
sieben neuen Befunde aus dem Summary-Vorlagen-Commit — `N16`/`N20b` (nach
einer Compaction bestand der einzige „alte" Span aus der Summary selbst;
`render/1` leerte ihn und ein Provider-Call überschrieb die Summary;
`trim/1` fraß sie zuerst — `take_pinned/1` pinnt System **und** Summary),
`N17` (die Vorlage ließ „numbers measured"/Testzahlen fallen; wieder
drin), `N18` (`max_tokens` im Summarize-Aufruf + Cap in `apply/2`), `N19`
(Doku), `N21` (Marker-Randfälle), `N22` (Prior-Einrahmung getestet).
Commits `bbcbd88`…`4e49557`.

**Erledigt (Review-Abarbeitung 2026-09-30, `review-devel-2026-09-30.md`):**
der Record bestätigte alle 22 vorigen Befunde als behoben und brachte 10
neue — alle abgearbeitet. **Korrektheit:** `N26` (der idle
Agenten-Wechsel löste Fenster/Limits nicht neu auf; `recompute_window/1`
in der idle-`set_agent`-Klausel — beide Richtungen getestet), `N29`
(`req_llm` wiederholt den Idle-Transport-Timeout doch, über
`Streaming.Retry`'s Finch-Loop; der verworfene Stream lief hinter dem
Fehler weiter — gemessen **11 Sockets mit Bug, 4 mit Fix**;
`stream_attempt/2` schließt ihn jetzt im Fehlerpfad, Regressionstest
zählt Sockets), `N23` (`provider_receive_timeout_ms` las die
Projekt-Schicht nicht; `Request.build/3` mit `scope_root`), `N24` (ein
Menü im ~2 s-Kaltfenster pinnte die leere Katalog-Hälfte für den
Prozess; nicht cachen, solange `!Catalog.ready?`). **Kappen:** `N30`
(der Summary-Cap warf Kopf-first `Next Move`/`Relevant Files` weg; jetzt
Kopf **und** Schwanz wie `bound_input/1`), `N31` (Cap in Bytes gedeckelt,
in Graphemen geschnitten → bis 4×; `binary_part` + UTF-8-Rand). **Doku:**
`N25` (Standardinstallation hat keinen Katalog-Provider — Erwartung
ehrlich gemacht), `N27` (der 0.75-Floor regiert für **41,2 %** des
Katalogs, 3198/7758; der Hard-Trim kann trotzdem über `W` bleiben),
`N28` (ADR 041: 495 s statt 375 s — `retries + 1` Versuche; Prämisse als
Idle-Test festgehalten), `N32` (doppelter Kommentar, Marker-Form). Commits
`684f682`…`795a59d`.

**Erledigt (Code-Review-Abarbeitung 2026-09-29):** die Korrektheits-
Befunde aus `review-2026-09-28.md` sind abgearbeitet —
`Exec.run/5 :truncate` (F2/F5: die Maschinensicht auf `fd` wird nicht
mehr von einem Banner verfälscht), `FdSearch.parse_paths/2` verwirft
Banner/Diagnostik, `Glob`-Wide-Branch ohne Vor-Filter-Deckel (F1),
`ListFiles` ohne stillen Deckel (F4), der Picker besitzt die Tastatur
(F6: popups vor der `ctrl-x`-Klausel), `@` wird beim Fehler
zurückgeschrieben (F7), die Dateiliste kommt asynchron (F8), `todowrite`
hat Anzahl-/Längen-Deckel (ADR 031). Aus `review.md`: Approval-Reply ist
jetzt ein No-Op wie seine Geschwister, `open_pause/3` ist eine Funktion,
die Doku-Staleness (External, ADR 016/015, README, about-tools, `Stand`)
ist gefixt.

**Offen:**

* ~~**`scope_root` ungleich Git-Wurzel**~~ — **erledigt (2026-10-01).**
  Ursprünglicher Fix (neues `Core.Repo`, Aufwärtssuche zu Git-Root für
  `Bwrap.git_dirs` und `UserConfig.project_dir`) wurde am selben Tag
  **revidiert**: Owner-Regel ist `scope_root` = aktuelles Verzeichnis,
  **kein** Aufwärtssuchen. `UserConfig.project_dir/1` löst die Config
  wieder am Scope-Root auf, `ProjectMemory` liest nur
  `<scope_root>/AGENTS.md`, `Repo.dirs/1` ist weg; `Repo.root/1` bleibt
  allein für den Sandbox-`.git`-Bind (findet auch den Worktree-Gitfile).
  **`scope_root` bleibt bewusst das Arbeitsverzeichnis**.

* **`active_tab`-Lebensdauer.** Der Zeiger wird bei Session-Wechsel neu
  gebaut und fällt überall über `active_child/1` sauber auf den Parent
  zurück (Test da), aber es gibt **keinen** Aufräumpfad beim Entfernen
  eines Tabs. Erst scharf, wenn gehaltene Tabs ersetzt/gedeckelt werden
  (ADR 018 offene Frage 4). Bewusst nicht vorab gebaut: ohne ein
  Entfernungs-Event wäre der Cleanup toter Code.

## Struktur & Kosmetik (P4)

* `tui.ex` aufteilen (`4865` Zeilen auf `devel@ca6f734`; der interne
  Aufbau ist nur durch `# --`-Kommentare getrennt) und den Mount-State
  **einmal** definieren (`mount_picker` 122 Zeilen, `mount_session` 224 —
  Funktionsspanne `defp` bis `end`). Die früheren Maße (`~114/~212`)
  waren die von `935cf92`, dem Commit, in dem sie falsch waren.
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

* ~~**ADR 020** steht auf `Proposed`~~ — **erledigt (2026-10-01):**
  auf `Accepted` (die SQLite-Engine läuft seit dem Merge).
* ~~**ADR 018** steht auf `Proposed`~~ — **erledigt (2026-10-01):** auf
  `Accepted` (Teil 1 und der Tab sind shipped).
* **ADR 007** bleibt bewusst `Proposed`: die Spezialisten-Matrix ist
  ungebaut (ROADMAP „6c“), der Record ist ein Plan, keine Entscheidung.

## Offene ADR-Fragen

Nicht duplizieren — sie stehen in den ADRs selbst: 025 q3, 026 q1–3,
027 q1–3, 028 q1–3, 029 q1–3, 024 q2–3, 020 q2, 022, 018 (Tab-Design in
Amendment (ii) beantwortet; offen nur die Keys/Cap-Config), 007 (Proposed:
Spezialisten-Matrix, Produktthese, ungebaut).
