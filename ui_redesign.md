# UI redesign — Befunde, Entscheidungen, Umsetzung

Stand: **Runde 1 umgesetzt und grün** (640 Tests). Dieses Dokument hält
fest, was gemessen wurde, was entschieden ist und was noch offen ist.

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
| F11 | Bottom-Row | Dialog und Picker rechnen gegen `area.height - h - 3`; beim Entfernen der Zeile muss diese Geometrie mitziehen (ein Test prüft, dass die Statuszeile unter dem Dialog sichtbar bleibt). |
| F12 | Placeholder | Der alte Placeholder war länger als die Input-Breite und wurde abgeschnitten (`… ctrl-t o│`). |

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
  * **bottom-left** — die Identity-Zeile (`you → agent · model …`),
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
| O1 | Bottom-Row ersatzlos entfernen; Dialog-/Picker-Geometrie nachziehen (F11); `menu_note` umziehen | entschieden, nicht gebaut |
| O2 | Air pro Eintrag (Vorschlag: tool 1 / info 1 / reasoning 2 / assistant 3) statt `@air 3` überall | Vorschlag offen |
| O3 | Sidebar-Werte rechtsbündig: Padding im `Paragraph` oder echte `Table` | offen |
| O4 | Sidebar-Titel `" status "` entfernen (F8); oberer Slot: leer oder Scope | „Wort weg" entschieden, Slot offen |
| O5 | ~15 leere Zeilen der Sidebar: kürzen / füllen / ruhig lassen | offen |
| O6 | Rail `▌` links + Provider/effort/Modell farbcodiert im Band | offen |
| O7 | Sidebar entdoppeln (Modell/Effort raus, wenn das Band sie zeigt) | offen |
| O8 | Markdown-Politur (F9): `#`-Präfixe, Fences, Inline-Code-bg | offen |
| O9 | `effort` (F10): entweder wirksam machen (Core-Thema) oder aus der UI nehmen | offen |
| O10 | „wide bar" aus dem ratatui-Beispiel: Picker-Auswahlzeile oder Vorbild für die Rail? | offen |
| O11 | Latente Duplikation: `Tui.entry_widgets/3` baut Reasoning/Tool/Info-Widgets nach, die `TranscriptView.widget_for/3` schon für die Messung baut — „measure = paint" hält nur zufällig | offen (P4) |

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
