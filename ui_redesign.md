# UI redesign — Befunde, Entscheidungen, Umsetzung

Stand: **Runde 1–4 umgesetzt und grün** (813 Tests). Dieses Dokument hält
fest, was gemessen wurde, was entschieden ist und was noch offen ist.
Runde 2 (Abschnitt 6) zieht die Konsequenz aus F6: die Meta-Zeile ist kein
`Block`-Titel mehr, sondern echter Inhalt im eigenen Modul `UI.Composer`.
Runde 3 (Abschnitt 7) entfernt die Bottom-Row ersatzlos und zieht F11 nach.
Runde 4 (Abschnitt 8) trennt die zwei Fragen, die eine Zeile nicht
gleichzeitig beantworten konnte: Status und Identität des **laufenden**
Turns ziehen in ein eigenes Band **über** dem Feld (`UI.LiveBand`), die
Meta-Zeile im Composer ist nur noch **Setup** („was der nächste Input
nimmt").

Leitregel (Owner-Entscheidung):

> Wir bleiben bei **semantischen Namen**. Wir ändern maximal die *vorhandene*
> Rolle (`:text`) oder definieren eine **neue semantische Rolle** (wenn nötig)
> — niemals eine Farbe an der Aufrufstelle.

Harter Test für jede Änderung: **kein Hex-Wert, kein `{:rgb, …}` und kein
`{:indexed, …}` außerhalb von `Palette`.** Aufrufstellen nennen Rollen und
Surfaces.

---

## 1. Befunde (headless gemessen, nicht aus der Doku übernommen)

Alle Werte wurden mit `ExRatatui.CellSession.take_cells/1` aus dem echten
gerenderten Zellenpuffer gelesen — `get_buffer_content/1` liefert nur Zeichen
und kann **keine** Farben prüfen. Das ist die einzige Methode, Farbe zu
behaupten; sie ist jetzt als Test-Helfer vorhanden
(`TuiCase.start_cell_tui/2`, `cells/1`, `cell/3`, `row_text/2`).

| # | Befund | Messung |
|---|---|---|
| F1 | Luft nach Einträgen | `@air = 3` (`transcript_view.ex:51`) für **jeden** Nicht-User-Eintrag. Ein 8-Einträge-Turn: 33 Zeilen, 24 davon (72 %) Luft. Nach einem Tool-Call also **drei** Leerzeilen. |
| F2 | Textfarbe | Zelle trug `:white` = ANSI 15. Was das Terminal daraus malt, bestimmt dessen Theme (tmux: ≈ #c0c0c0) — daher „getempert". `:muted`/`:reasoning` = `:dark_gray` = ANSI 8, auf dunklem Grund kaum sichtbar. |
| F3 | Indexed-Farben | `{:indexed, n}` und `{:rgb, …}` gehen sauber bis in die Zelle durch — der einzige Weg, Kontrast unabhängig vom Terminal-Theme zu steuern. |
| F4 | Textarea-Füllung | `style.bg` füllt **nur die benutzten Zeilen**. Der `block` muss den Fill tragen, sonst bleibt das Rect teils leer. |
| F5 | Borderlose Titles | `Block.titles` funktioniert bei `borders: []` — `top`- und `bottom`-Titles mit `alignment: :right` liegen auf der ersten bzw. letzten Zeile des Rects. |
| F6 | Kollision | Ein `bottom`-Title wird auf die **letzte Zeile des Rects** gezeichnet und **übermalt Text**, der dort steht (gerendert verifiziert). Die Texthöhe muss die Title-Zeile also freihalten. |
| F7 | Padding-Tupel | `padding` ist `{left, right, top, bottom}` — **nicht** CSS-Reihenfolge. `{0,0,0,1}` isst die Textzeile (bottom), `{1,0,0,0}` rückt den Text um eine Spalte ein. Gemessen; der erste Entwurf hatte es falsch. |
| F8 | Sidebar-Titel | `" status "` liegt bei `borders: [:right]` auf Zeile 0 **ohne obere Border** → es sieht wie eine Listenzeile aus, nicht wie ein Titel. |
| F9 | Markdown-Renderer | `# `-Präfix bleibt sichtbar; H1 bekommt einen **cyan Hintergrundbalken** (Theme ist in der Crate fest verdrahtet); ` ``` `-Fences bleiben stehen; Inline-Code bg ist hart `:black`; Tabellenrahmen `:dark_gray`; HR als literales `---`. |
| F10 | `effort` | Wird aus der Config gelesen und in der Sidebar gezeigt, aber **nie** an `Request.build/2` oder die Agent-Definition gegeben — reine Dekoration. |
| F11 | Bottom-Row | Dialog und Picker rechnen gegen `area.height - h - 3` — 3 Zeilen „unter sich", weil die Statuszeile am Fensterboden lag. Beim Entfernen der Zeile (Runde 3) muss diese Geometrie mitziehen: sonst steht ein Dialog **auf** der Composer-Meta-Zeile und verdeckt genau den Status, den er erklärt. Ein Test prüft, dass die Meta-Zeile unter dem Dialog sichtbar bleibt. |
| F12 | Placeholder | Der alte Placeholder war länger als die Input-Breite und wurde abgeschnitten (`… ctrl-t o│`). |
| F13 | Notes vs. Status | Ein `note` (esc-Hinweis, Menü-Prompt) **ersetzt** die Status-Worte, aber nicht den Glyph: `⠋ esc again to stop` — der laufende Turn bleibt sichtbar, der Hinweis ist dringlicher als das Wort „thinking". Auf einer schmalen Pane (100 Spalten) kollidieren beide sonst: Identity + `⏸ approval needed (y/n/e)` füllen die Zeile bereits. |
| F14 | Laufend vs. nächste | Die Meta-Zeile trug **zwei verschiedene Aussagen** gleichzeitig: links die Identität des *nächsten* Inputs (`next_agent`/`next_agent_model`), rechts den Status des *laufenden* Turns. Solange beides gleich ist, fällt es nicht auf; nach Tab (`running=build`, `next=plan`) nennt eine Zeile zwei Subjekte. Gemessen (100×30, `{:turn_started, "build"}` + Tab): Band `agent build · model … · ⠋ thinking`, Setup-Zeile `build · model …` — beide Zeilen sind unterscheidbar, weil sie **verschiedene Werte** tragen. |
| F15 | Overlay-Raum | Das Menü-Popup rechnete gegen `area.height - 4` (Fixwert), der Dialog gegen `area.height - h - 3`. Das Band nahm 5 Zeilen (3 + 2 Luft) weg, das Popup ist aber 26 Zeilen hoch: bei 100×30 blieb eine negative `rect.y` stehen → `ExRatatui draw error: "rect.y: unexpected value"` (im Log sichtbar, ohne Testfehler, weil der Frame danach nur noch alt war). |

---

## 2. Entscheidungen

### 2.1 Farben: **keine** neue Rolle (die kleinere Änderung gewinnt)

Ein erster Entwurf führte eine neue Rolle `:panel` **und** ein neues Surface
`:panel` ein („Text, der auf dem Composer steht"). Verworfen, und zwar aus
einem inhaltlichen Grund:

* `:chrome` bedeutet bereits „eine Fläche, die die App selbst malt" (Menü,
  Picker, Dialog, Statuszeile). Der Composer **ist** so eine Fläche. Ein
  zweites Surface für dieselbe Sache wäre eine Vokabel zu viel.
* Der Composer braucht also *keine* neue Rolle — er braucht dieselbe Rolle
  wie der Rest des Textes, nur auf einem gefüllten Surface.
* Damit bleibt genau **eine** Änderung an der Semantik: `:text` bekommt
  einen **stated** Farbwert. Alles andere sind Werte in `Palette`.

Was das kostet und warum es vertretbar ist: `:text` auf `:base` war bewusst
„die Terminal-Vorgabe" (der Transcript-Körper passt sich dem Theme an). Ein
Named ANSI colour ist aber keine Farbe, sondern ein **Platzhalter im Theme des
Nutzers**: `:white` = ANSI 15, und die beobachtete Belegung rendert das als
≈ `#c0c0c0` — gelesen als „getempert", „ausgewaschen". Deshalb:

| Rolle / Fill | Wert | Begründung |
|---|---|---|
| `:text` (base) | `{:indexed, 255}` (#eeeeee) | Der Körpertext wird **gesagt**, nicht geerbt. Ein Schritt weg von Reinweiß, damit langer Text nicht blendet. Betrifft Transcript **und** Composer — genau das ist gewollt: ein Textbegriff. |
| `:emphasis` | derselbe Wert + `:bold` | Die Rollen-Trennung bleibt: Emphasis ist die Betonung, nicht eine andere Farbe. |
| `:warning` / `:error` / `:agent` / `:model` / `:user` / `:accent` | unverändert benannt | Diese Rollen **bedeuten** „was dieses Terminal gelb/rot/cyan nennt". Theme-Anpassung ist hier ein Feature, nicht ein Fehler. |
| `:muted` / `:reasoning` | unverändert | Nicht Teil dieser Runde. |
| Fill `:chrome` | `{:indexed, 235}` (#262626 ≈ 90 % Schwarz) | Owner-Wunsch „90 % Grau"; dunkel genug, um als Fläche zu lesen statt als „einfach nur grau". |
| Fill `:sidebar` | derselbe Wert | Die Flächen, die die App malt, sind **ein** Material. |

Der Grey-Bear-Wächter (`styles_test`: `fg != bg` für jede Rolle × jedes
gefüllte Surface) deckt die neuen Kombinationen automatisch mit ab; ein
zusätzlicher Test prüft, dass der Composer-Text ein `{:indexed, _}`-Weiß ist
und sich vom Fill unterscheidet.

### 2.2 Eingabefeld: kein Rahmen

* `borders: []` — keine `╭ ╰ │`-Kiste mehr („looks so … c64").
* Der Block ist jetzt **Fill- und Titel-Träger**, und `Styles.panel/1` setzt
  `style` per Default auf den Fill des Surfaces. Das ist tragend, nicht
  kosmetisch: ein Widget-Style füllt nur die Zeilen, die das Widget schreibt
  (F4), der Block deckt sein ganzes Rect.
* `padding: {1, 0, 0, 0}` — eine Spalte Einzug links, damit der Text die
  linke Kante nicht berührt (F7).
* Titel auf dem Block statt auf der Border:
  * **bottom-left** — die Identity-Zeile (`agent · model …`),
  * **bottom-right** — Status/Spinner (vorher top-right).
* `title_style: nil`, damit jeder Span seine eigene Rolle trägt.
* Der Composer-Text ist `Styles.role(:text, :chrome)` — dieselbe Weiß-Stufe
  wie der Transcript-Körper, auf dem Fill.

Bewusste Nebenwirkung (F6): die untere Title-Zeile ist die letzte Zeile des
Rects und **übermalt Text**, wenn die Textarea sie belegt. `input_height/1`
reserviert deshalb **eine** Zeile: Texthöhe + 1 (statt vorher 2 Border-Bögen).
`@layout_overhead` und `input_height/1` wurden gemeinsam geändert
(`measure = paint`).

Nebenbei: der Placeholder wurde gekürzt (`Message the agent… (alt-enter sends)`) —
er lief sonst aus dem Feld heraus (F12).

### 2.3 Was in dieser Runde *nicht* passiert

Bottom-Row, Air pro Eintrag, Sidebar-Rechtsbündigkeit, Sidebar-Titel,
Rail/Provider/effort im Band, Markdown-Politur. Alle bleiben offen — unten
als Liste geführt, nicht stillschweigend verworfen.

---

## 3. Umgesetzt (Runde 1)

### 3.1 `lib/coding_agent/ui/palette.ex`

* `@type color` (neu): `atom() | {:indexed, 0..255} | {:rgb, r, g, b}`;
  `t`, `resolve/3`, `fill/2` reichen den Typ durch.
* `:text` / `:emphasis` auf `{:indexed, 255}`; `fills` für `:chrome` und
  `:sidebar` auf `{:indexed, 235}`.
* Werte als private Modul-Attribute (`@body_white`, `@surface_grey`) mit
  einem Moduldoc-Abschnitt, der benannte vs. indexed Farben erklärt.

### 3.2 `lib/coding_agent/ui/styles.ex`

* `Styles.panel/1` setzt `style` auf `surface_bg(surface)` (Default), damit
  der Block sein ganzes Rect füllt. Überschreibbar über `:style`.

### 3.3 `lib/coding_agent/ui/tui.ex`

* `@input_height`/`@input_max_height` → `@input_lines`/`@input_max_lines`
  (Linien, nicht Zeilen mit Border); `input_height/1` = `min(lines, max) + 1`.
* `input_widget/1`: `borders: []`, `surface: :chrome`, `padding {1,0,0,0}`,
  zwei Bottom-Titles, `style: role(:text, :chrome)`, kürzerer Placeholder.
* Alle Spans des Identity-Strangs auf `:chrome` (statt `:panel`).

### 3.4 Tests

* `test/support/tui_case.ex`: `start_cell_tui/2`, `cells/1`, `cell/3`,
  `row_text/2` — farbige Assertions (vorher unmöglich: `buffer/1` liefert nur
  Symbole).
* `test/coding_agent/ui/tui_cells_test.exs` (**neu**): Composer ist gefüllt,
  Text stated weiß, keine Frame-Glyphen; Identity und Status teilen die letzte
  Zeile; Sidebar/Composer/Statuszeile tragen **denselben** Fill; der
  Transcript-Körper bleibt ungefüllt.
* `palette_test` / `styles_test`: neue Fill-Werte, „stated not themed",
  Composer-Kontrast, User-Theme-Seam für indexed Fills.
* `tui_agent_test` / `track_b_status_test`: die alten `╰`/`╯`/`╭`-Asserts
  am Input sind auf die neue Form umgezogen (Identity-Zeile = letzte Zeile
  des Input-Rects; Status auf derselben Zeile rechts).

---

## 4. Offene Punkte

| # | Punkt | Stand |
|---|---|---|
| O1 | ~~Bottom-Row ersatzlos entfernen; Dialog-/Picker-Geometrie nachziehen (F11); `menu_note` umziehen~~ | **umgesetzt in Runde 3** (Abschnitt 7) |
| O2 | Air pro Eintrag (Vorschlag: tool 1 / info 1 / reasoning 2 / assistant 3) statt `@air 3` überall | Vorschlag offen |
| O3 | Sidebar-Werte rechtsbündig: Padding im `Paragraph` oder echte `Table` | offen |
| O4 | Sidebar-Titel `" status "` entfernen (F8); oberer Slot: leer oder Scope | „Wort weg" entschieden, Slot offen |
| O5 | ~15 leere Zeilen der Sidebar: kürzen / füllen / ruhig lassen | offen |
| O6 | Rail `▌` links + Provider/effort/Modell farbcodiert im Band | offen |
| O7 | Sidebar entdoppeln (Modell/Effort raus, wenn das Band sie zeigt) | offen — das Band zeigt das Modell nur im Busy-Fall, die Sidebar also weiterhin im Idle |
| O8 | Markdown-Politur (F9): `#`-Präfixe, Fences, Inline-Code-bg | offen |
| O9 | `effort` (F10): entweder wirksam machen (Core-Thema) oder aus der UI nehmen | offen |
| O10 | „wide bar" aus dem ratatui-Beispiel: Picker-Auswahlzeile oder Vorbild für die Rail? | offen |
| O11 | Latente Duplikation: `Tui.entry_widgets/3` baut Reasoning/Tool/Info-Widgets nach, die `TranscriptView.widget_for/3` schon für die Messung baut — „measure = paint" hält nur zufällig | offen (P4) |
| O12 | Band interaktiv machen (Rail `▌`, Provider/effort farbcodiert) — berührt das Padding-Entscheid aus §8.2 | offen |
| O13 | Overlay-Höhe jenseits des Popups: `budget`/`doom`/`question` klemmen weiterhin (ihre Höhe ist auf `div(area.height, 2)` begrenzt, bleibt also unter dem Raum), das Menü fenstert | offen, falls ein Overlay je höher wird |

---

## 5. Nicht verhandelbar

* Keine Farbe an der Aufrufstelle — nur Rollen/Surfaces.
* `measure = paint`: jede Höhen-Rechnung, die sich ändert, muss gemeinsam mit
  dem Renderer geändert werden (die Datei hat diese Bug-Klasse schon dreimal
  erwischt).
* Der Transcript-**Hintergrund** bleibt die Terminal-Vorgabe; nur die Flächen,
  die die App selbst malt, sind gefüllt.
* Farb-Asserts nur über `CellSession` — `get_buffer_content/1` kann keine
  Farbe prüfen, und ein Text-Assert kann eine Farb-Regression nicht fangen.
* Zusammengehöriges wird getrennt implementiert (Owner-Entscheidung): was
  eigene Daten *und* eigene Funktionen hat, bekommt ein eigenes Modul.

---

## 6. Runde 2 — der Composer als eigenes Panel (`UI.Composer`)

### 6.1 Befund (live, nicht geraten)

Zwei Beobachtungen am gerenderten Frame (Zellpuffer, 120×30):

* „Das sieht so gepresst aus da unten." — Der Composer war *eine* Textarea mit
  einem `Block`, dessen zwei Titel auf der **letzten Zeile** saßen (F6). Text
  und Meta teilten sich also eine Zeile, und der Text begann in Spalte 1 direkt
  an der Fill-Kante.
* „Die Statuszeile ist auch nicht links ein Zeichen eingerückt." — Der rechte
  Titel hatte gar kein Padding; der linke nur `{1, 0, 0, 0}` (F7), also nur
  links, nicht unten.

Zusätzlich: die Meta-Zeile war ein `bottom`-Titel auf dem Textfeld — also
ständig in Kollisionsgefahr mit dem getippten Text (genau das Problem, für das
`input_height/1` eine Zeile freihielt).

### 6.2 Entscheidung

* **Kein Rahmen** (Owner: „definitiv keine Rahmen"). Das Panel ist eine reine
  **Fill-Fläche**; sie geht eine Zelle **über die Felder hinaus**, damit der
  Hintergrund als Fläche lesbar ist und die Felder *darin* stehen.
* **Echtes Padding rundum** (1 Zelle) — links/rechts/oben/unten. Der Text
  berührt keine Kante mehr.
* **Eigene Modul** `CodingAgent.UI.Composer` (Owner: „sofort dabei"). Alles,
  was zusammengehört — Geometrie, Aussehen, die Meta-Daten — liegt dort; `Tui`
  reicht nur die **Werte** durch.

Layout (Höhe = Padding(2) + Zeilen + Luft(1) + Meta(1)):

```
      +------------------------------------------+  Fill :chrome, ganzes Rect
      |  <Textarea>                               |  1 Zelle Einzug
      |                                           |  eine Leerzeile
      |  build · model …                  ○ idle    |  Meta: Identity | Status
      +------------------------------------------+
```

### 6.3 Umsetzung

* `lib/coding_agent/ui/composer.ex` (**neu**): `new/1` (Struct), `height/1`
  (die Measure-Seite), `min_height/0` (State-Mathe ohne Render), `placements/2`
  (Fill + Textarea + Meta-Zeile als `{widget, rect}`). Die Meta-Zeile ist ein
  borderless `Block`-Titelpaar (links/rechts) auf einer **eigenen** Zeile, nicht
  mehr auf dem Textfeld. Die Uhr bleibt in `Tui` (silence/tool_elapsed werden
  als Werte übergeben), damit `Composer` Layout und nichts Zeitliches kennt.
* `tui.ex`: `input_widget/1` + `status_line_for_input/1` entfernt;
  `composer/1` baut nur noch das Struct aus dem State, `render_main` ruft
  `Composer.placements/2`. `@layout_overhead` und `input_height/1` rechnen über
  `Composer` (`measure = paint`). Tote Aliase (`Style`, `Textarea`) entfernt.
* `test/coding_agent/ui/composer_test.exs` (**neu**): Höhe (Floor, Wachstum,
  Cap), Reihenfolge und Einzug der Platzierungen, der rahmenlose Fill, der
  sichtbare Cursor, Aufbau der Meta-Zeile (Identity links, Status rechts,
  Rollen pro Span).

Die bestehenden Farb-/Geometrie-Tests (`tui_cells_test`, `tui_agent_test`,
`track_b_status_test`, `tui_cursor_test`) bleiben unverändert grün — die
Form (gefülltes Feld, gestellte Farbe, Identity+Status auf einer Zeile) ist
dieselbe, die Mechanik darunter ist jetzt getrennt.

---

## 7. Runde 3 — die Bottom-Row fällt ersatzlos weg

### 7.1 Befund

Die Statuszeile am Fensterboden war **reine Wiederholung**: die Meta-Zeile im
Composer trug bereits Glyph + Spinner + Label + Elapsed. Vier Dinge hatte die
Bottom-Row noch zu sagen: Session-Id, esc-Hinweise, das debug-gestellte
Diagnose-Text und das statische `badge.label`.

Gemessen (Zellpuffer, 110×30) hieß das: `⠋ thinking` stand zweimal auf dem
Schirm, und die Statuszeile war nicht auf den Composer eingerückt (sie lief
über die ganze Breite, während das Feld bei Spalte 37 begann) — der
„links ein Zeichen eingerückt"-Befund aus Runde 2.

Auch die **Session-Id** war dort schon die zweite Anzeige derselben Sache:
die Sidebar nennt sie seit `f89dbf5` (2026-09-06). Die Streichung der Row hat
sie nicht vom Schirm genommen — die Berichtigung steht in §7.5 (dort stand
zeitweise das Gegenteil).

### 7.2 Entscheidung

* **Zeile weg**, nicht umgebaut. Der Composer beantwortet „was passiert
  gerade" direkt bei der Eingabe; der Fensterboden ist dafür der falsche Ort.
* Der transiente Text zieht in die **rechte Hälfte der Meta-Zeile** (den
  äußersten Row des Composers) — als zwei neue Werte im Struct:
  * `note` — esc-Hinweis (`esc again to quit` / `esc again to stop`) oder
    `menu_note` (Menü-Prompt, `model → …`, `agent → …`);
  * `diagnostics` — die Scroll-Diagnostik, nur bei `debug_visible?`
    (ctrl-x d).
  Priorität: `note` → `diagnostics` → Status. Das Modul kennt weiterhin
  **keine** Zeit und **keine** Config: `Tui` reicht die Strings durch, genau
  wie die Uhr.
* Das **statische `badge.label`** fällt ersatzlos weg — es war genau die
  Duplikation. Damit die Zeile bei einem Hinweis nicht überläuft, wird bei
  gesetztem `note` nur das **Wort** des Status weggelassen, **nicht der
  Glyph** (F13): `⠋ esc again to stop` zeigt weiterhin, dass ein Turn läuft.

### 7.3 F11 — die Geometrie, die mitziehen muss

Dialog und Picker rechneten gegen `area.height - h - 3` (drei Zeilen
„unter sich": Margin + Spacing + Statuszeile). Ohne Nachziehen hätte der
Dialog auf der Meta-Zeile gesessen und den Status verdeckt, den er erklärt.

Nachgerechnet statt geraten: die Composer-Meta-Zeile liegt bei 30 Zeilen auf
**27**; `area.height - h - 3` setzt den Dialog jetzt mit seiner Unterkante auf
**26**, also *eine* Zeile darüber. Gemessen bei 100/110/160 Spalten (der
Dialog bleibt auf Zeile 19–26, die Meta-Zeile bei 27). Der Picker war schon
zentriert (`div(area.height - h, 2)`) und bleibt es; der Menü-Popup rechnet
gegen `area.height - h - 3` weiterhin richtig, weil die drei Zeilen unter dem
Popup jetzt *Composer*-Zeilen sind (Composer + Rand) statt Composer + Status.

### 7.4 Geändert

* `lib/coding_agent/ui/composer.ex`: Felder `note` / `diagnostics`; `slot/1`
  (Priorität `note` → `diagnostics` → Status); `status/1` liefert jetzt auch
  idle einen `nil`-Label-Lauf, damit der Glyph-Rest der Note-Regel gilt.
* `lib/coding_agent/ui/tui.ex`: `@layout_overhead` und `layout_overhead/1`
  ohne `+1`; `render_main/2` splittet nur noch `[{:min, 0}]`; die ganze
  `status_widget*`-Familie entfernt; `esc_hint/1` neu (die Hinweise, die
  vorher in `status_widget_plain/1` standen); `scroll_diagnostics/1` liefert
  jetzt einen String an den Composer statt ein Widget zu bauen.
* `lib/coding_agent/ui/styles.ex`: `surface_bg/1`-Doc auf „eine Zeile, deren
  Spans schon Rollen tragen" — die Bottom-Row als Beispiel ist weg.
* Tests:
  * `composer_test`: die **Not-Regel** als Unit-Test (Wort weg, Glyph bleibt;
    `note` schlägt `diagnostics` schlägt Status) — inkl. Gate-Fall `⏸ esc again
    to quit`, damit die gepausete Zeile sichtbar bleibt.
  * `tui_cells_test`: die Status-Zeilen-Asserts zeigen jetzt auf die
    **Meta-Zeile** (`meta_row/1` nimmt die *letzte* `model `-Zeile, weil die
    Sidebar auch ein Modell nennt); ein neuer Test pinnt den Composer bis zur
    letzten Chrome-Zeile fest (Padding-Zeile trägt den Fill, die Fensterzeile
    selbst ist Rand und bleibt `:reset`).
  * `tui_visual_test`: der feste `Enum.at(28)`-Index ist weg — der Assert
    sucht den letzten `approval needed`-Treffer und prüft dort die Identity,
    also genau „der Dialog verdeckt den Status nicht".

### 7.5 Was jetzt fehlt (bewusst)

**Berichtigung (nachgemessen).** ~~Die **Session-Id** ist aus dem Sichtfeld
verschwunden. Sie war in der Bottom-Row sichtbar; sie bleibt im State und im
Picker (ADR 020), aber nicht mehr im Composer — die Meta-Zeile ist voll
(Identity links, Status/Note rechts). Wenn sie zurück soll, dann als eigenes
Entscheidungsstück (Sidebar-Slot oder Picker-Kopf), nicht als weitere Spans in
diese Zeile.~~ Der erste Satz war **falsch**, und die daraus gezogene
Konsequenz („eigener Slot nötig") ebenso: die Id war nie nur in der Bottom-Row.

Tatsächlich stand sie dort **und** gleichzeitig in der **Sidebar** — die führt
sie seit deren erster Fassung (`f89dbf5`, 2026-09-06), heute als
`definition_list`-Zeile `{"session", String.slice(state.session_id, 0, 22)}`
(`tui.ex:3556`, im 36 breiten Panel `@sidebar_width`, `tui.ex:133`; als
Definitionsliste seit `bbd7f2f`, 2026-09-19), also **vor** Runde 3 und
unabhängig von ihr. Die Bottom-Row trug die **zweite** Anzeige derselben Id;
Runde 3 hat nur diese zweite entfernt.

Gemessen (Zellpuffer, 100×30, Id `tui-` + 30 Ziffern, Zeile 5):
` session:     tui-999999999999999999│` — die Id ist also weiterhin auf dem
Schirm, auf die 22 Zeichen des `String.slice/3` gekürzt. Sie verschwindet nur,
wenn das Panel **abgeschaltet** ist: `ctrl-x p` (`Menu :toggle_sidebar`) oder
`sidebar: false` beim Mount. Die Breite entscheidet nicht darüber — das Panel
ist ein fester 36-Spalten-Split und bleibt auch auf 40 Spalten stehen
(nachgemessen, 40×12: Spalte 37 ist die Trennkante, Zeile 5 trägt die Id).

Damit ist die Frage **erledigt**, nicht offen: kein eigener Slot, kein
Sidebar-Slot, kein Picker-Kopf. Der P4-Backlog-Eintrag in `code_review.md`
(„the session id left the frame with the bottom row") ist gestrichen — er
beschrieb dieselbe Fehlannahme. **Kein Code-Change**, nur die Korrektur der
Aufzeichnung.

Dieselbe Fehlannahme steht im Commit-Text von `53b5817` („Consequence worth
naming: the session id is no longer on screen … it needs its own slot (sidebar
or picker head)"). Git-History wird hier nicht umgeschrieben; korrigiert ist
sie dort, wo sie gelesen wird — in diesem Dokument und im Backlog.

Was bleibt, ist die **Entscheidung zur Meta-Zeile** (unabhängig von der
Sidebar): die Id gehört **nicht** in die Composer-Meta-Zeile. Die Zeile
beantwortet genau eine Frage („was nimmt der nächste Input"), und die Id ist
keine — sie ist eine Kennung, kein Setup.

**Nachtrag (Runde 4):** die Meta-Zeile ist *nicht mehr voll* — der Status ist
aus ihr heraus in das Band gewandert (Abschnitt 8). Der frei gewordene Platz
ist trotzdem kein Session-Id-Slot, aus demselben Grund.

---

## 8. Runde 4 — das Live-Band über dem Feld

### 8.1 Befund

Die Meta-Zeile des Composers trug seit Runde 1/3 **zwei verschiedene
Aussagen** auf einer Zeile (F14):

* links die Identität des **nächsten** Inputs (`next_agent`,
  `next_agent_model`) — die, die Tab und das Modell-Menü ändern;
* rechts den Status des **laufenden** Turns (Glyph, Spinner, Wort,
  Elapsed-Reset).

Solange beide gleich sind, fällt es nicht auf. Sobald sie divergieren, nennt
eine Zeile zwei Subjekte: nach `tab` (im Test `running=build`, `next=plan`)
liest sich `build · model …   ⠋ thinking` als „plan denkt". Das ist die
Lüge, die die Zeile vorher nur *nicht sichtbar* erzählt hat.

Dazu kam ein Befund an der Geometrie (F15): das Menü-Popup rechnete gegen den
Fixwert `area.height - 4`, der Dialog gegen `area.height - h - 3`. Das Band
nimmt 5 Zeilen weg (3 Band + 2 Luft), das Popup ist aber 26 Zeilen hoch — bei
100×30 ergab `area.height - 4 - 26` eine **negative** `rect.y`. Sichtbar war
das nur als Log-Zeile `ExRatatui draw error: "rect.y: unexpected value"` (der
Frame blieb danach der alte, kein Test schlug fehl).

### 8.2 Entscheidung (Owner)

* Der Status **gehört über das Feld**, als **Kopie** der laufenden Session —
  er kann sich vom nächsten Agenten/Modell unterscheiden, und genau das muss
  man sehen können.
* Mindestens **1 Zelle Padding auf allen vier Seiten**.
* Unterscheidbar vom Eingabefeld **über den Hintergrund**: das Band malt auf
  `:base` (dem ungefüllten Terminal-Hintergrund des Transcripts), **nicht**
  auf dem Chrome-Grau des Composers.
* Der Status ist **immer** sichtbar — das Layout bewegt sich nie, auch nicht
  im Idle.
* Die Meta-Zeile darunter ist **Setup**: nur noch das, was der nächste Input
  nimmt.

Daraus folgt die Modul-Teilung: `UI.LiveBand` hat eigene Daten (Identität des
laufenden Turns, Status, Elapsed-Kontext) und eigene Funktionen (Höhe,
Platzierung, Zeilenaufbau) — also ein eigenes Modul (die Leitregel „was eigene
Daten *und* eigene Funktionen hat, bekommt ein eigenes Modul"). Der Composer
**verliert** die Status-Felder ersatzlos: `Composer.new(status: …)` schlägt
jetzt fehl (`KeyError`). Ein zweiter Ort für dieselbe Aussage wäre genau die
Duplikation, die Runde 3 (Bottom-Row) entfernt hat.

Die Status-Vokabel bleibt **eine**: `Styles.status_line/6` komponiert Glyph +
Wort + Ellapsed, und das Band ist der einzige Aufrufer. Das Band entscheidet
nur, **welches Label** es übergibt (`"running mix"` bei laufendem Tool,
`"thinking"` während eines stillen Turns, `nil` = Badge-Wort). Ihr führender
Space ist weg (das Band bringt sein Padding mit) und ihr Moduldoc nennt jetzt
den Aufrufer statt der Composer-Zeile.

Die **Identität im Band** erscheint nur, während ein Turn läuft
(`Styles.busy?/1`): das ist der Fall, in dem „läuft" von „nimmt der nächste
Input" abweichen *kann*. Im Idle würde sie die Setup-Zeile zwei Zeilen weiter
unten wörtlich wiederholen. Der Status selbst steht immer.

### 8.3 Geometrie (F15) — ein Raum, nicht zwei Offsets

Der Raum, den ein Overlay nutzen darf, ist **definiert** als „alles über dem
Band":

```elixir
defp overlay_room(state, area) do
  max(area.height - input_height(state) - LiveBand.height() - 2, 1)
end
```

und `overlay_rect/4` setzt die Unterkante jedes Overlays auf dessen letzte
Zeile und **klemmt die Höhe** auf denselben Wert. Das ist der Kern der
Reparatur: Höhe und Position sind *dieselbe* Zahl; zwei getrennte Offsets (ein
`area.height - 4`-Cap hier, ein `area.height - h - 3` dort) sind genau die
Bauform, die eine negative `rect.y` erzeugt. Geklemmt wird, weil ein Popup
legitim höher ist als der Transcript-Pane (Menü: 9 Zeilen, Keymap-Liste: 21)
— es darf dann nur nicht mehr über das Band laufen.

Gemessen bei 100×30 (CellSession): Band-Zeilen 19 (Padding) / 20
(Padding) / **21 (Status)** / 22, 23 (Padding); Composer 24–28, Meta-Zeile 27;
Fensterzeile 29 = App-Rand (`:reset`). Alle Overlays enden jetzt auf Zeile 19.
Bei 160×30 liegt der Approval-Dialog auf 15–19 und das Band darunter
unverändert sichtbar.

Die Höhen sind **gemessen**, nicht angenommen: `input_height(state)` wächst
mit dem getippten Text, `LiveBand.height()` ist konstant 3. Wächst das Feld,
wandert das Band nach oben und die Overlays mit.

### 8.4 Geändert

* `lib/coding_agent/ui/live_band.ex` (**neu**): `new/1`, `height/0` (3),
  `placements/2` (Fill auf `:base` + Status-Paragraph, 1 Zelle Inset auf allen
  Seiten). Zeilenaufbau: Identität (nur busy, `Styles.badge/3`) → Trenner →
  `Styles.status_line/6`; ohne Identität nur der Status; die Zeile ist nie leer.
* `lib/coding_agent/ui/composer.ex`: Struct auf `textarea, placeholder, agent,
  model, note, diagnostics, max_lines` reduziert (die Status-Felder sind weg);
  `slot/1` ist `note` → `diagnostics` → **leer**; Moduldoc: diese Zeile ist
  SETUP, der Status ist das Band. Geometrie unverändert (`measure = paint`).
* `lib/coding_agent/ui/tui.ex`: `LiveBand` in `@layout_overhead`,
  `layout_overhead/1` und in `render_main/2` (die Midthälfte splittet jetzt in
  fünf Regionen: Transcript, Luft, Band, Luft, Composer); `live_band/1`,
  `band_elapsed_s/1` (Tool-Laufzeit bzw. Stille) und `band_label/1` neu;
  `overlay_room/2` + `overlay_rect/4` ersetzen `area.height - 4` /
  `area.height - h - 3` in Menü, Approval, Budget, Doom und Question;
  `handle_info({:agent, {:turn_started, agent}})` löst zusätzlich das
  **Modell** des laufenden Turns neu auf (eine resumed Session, deren
  Definition sich auf der Platte geändert hat, muss das zeigen, was läuft).
* Tests:
  * `test/coding_agent/ui/live_band_test.exs` (**neu**): der Zeilenaufbau als
    Unit-Test — Identität + Spinner + Caller-Label, `nil`-Label fällt auf das
    Badge-Wort zurück, ohne Identität kein hängender Trenner, ein laufendes
    Tool nennt sich mit **seiner** Laufzeit, Idle zeigt nur den Status.
  * `composer_test`: die Meta-Zeile neu geschrieben — links `build · model
    glm`, **rechts leer** ohne Note/Diagnostics, mit Note wörtlich (kein
    Glyph), Diagnostics nur ohne Note.
  * `track_b_status_test`: der Abschnitt „Status am Input" heißt „the live
    band (A)" — das Band trägt den Status **über** der Setup-Zeile, Idle
    wiederholt keine Identität, `tool_started` nennt das Tool, `tool_executed`
    fällt auf „thinking" zurück, und nach `tab` zeigt das Band den **laufenden**
    Agenten, die Setup-Zeile den **nächsten**.
  * `tui_cells_test`: das Band ist auf `:reset` (inklusive Randzellen), hat
    links/rechts/oben/unten 1 Zelle Padding, und `last_pane_height == 30 - 2 -
    2 - 3 - 5` beweist `measure = paint` für die neue Zeile.
  * `tui_visual_test`: der Approval-Dialog liegt **über** dem Band und dem
    Feld, die Pause steht im Band und **nicht** in der Setup-Zeile (der alte
    Assert suchte `approval needed` und dann `model ` auf *derselben* Zeile —
    die Zeilen sind jetzt getrennt).
  * `tui_menu_test`: ein Popup, das höher ist als der Raum über dem Band
    (Keymap-Liste: 21 Zeilen), fenstert um die Auswahl und nennt den
    Ausschnitt im Titel; ein passendes Popup trägt keinen Bereich.

### 8.5 Was jetzt fehlt (bewusst)

* Das Band ist **nicht** interaktiv: es zeigt Zustand, es nimmt keine
  Tastendrücke. (Der Rail `▌` links aus O6 wäre der nächste visuelle Schritt,
  dann muss die Kollision mit dem Padding entschieden werden.)
* Die Setup-Zeile und das Band nennen im Idle **dasselbe** Modell — das Band
  aber nur den Status, nicht die Identität; die Duplikation ist damit
  weggeschnitten, nicht nur umgeformt.
* Ein `note` (esc-Hinweis) steht in der Setup-Zeile, der laufende Turn im Band
  — zwei Zeilen, zwei Aussagen. Auf einer sehr flachen Pane (60×8) liegen sie
  direkt untereinander, ohne Luft dazwischen; gemessen wird dort nichts
  verdeckt, aber die Trennung ist dann nur noch der Hintergrund.
* **Lange Popups werden gefenstert, nicht geklemmt.** Die Keymap-Liste ist
  21 Zeilen hoch (`menu_popup`: 9), der Raum über dem Band bei 100×30 ist 20
  Zeilen. Zuerst kürzte `overlay_rect/4` die Liste auf 20 — gemessen fielen
  damit die **letzten** Einträge weg, und der Auswahlmarker wäre aus dem
  gemalten Bereich gelaufen. Jetzt ist der Popup ein **Fenster** um die
  Auswahl (`window_offset/3`, absolut gezählter Index, Titel zeigt
  `(1-17/21)` → `(5-21/21)`). Der übrige Overlay-Bestand (`budget`, `doom`,
  `question`) bleibt beim Klemmen: deren Höhe ist auf `div(area.height, 2)`
  begrenzt und damit bei jedem Fenster ≥ 20 Zeilen kleiner als der Raum.
