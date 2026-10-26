# Vereinfachungskonzept für die neue Top Bar (gui_top_bar_new_design.lua)

Stand: 2026-10-26, Basis ist der Commit "Top Bar New Design: round 2 review fixes" (c0a2889).
Gelesen wurden `gui_top_bar_new_design.lua` (bpUi / bpTrack), `design/bp_feature_spec.md`,
`design/mockup_measurements.md` und das Mockup `tools/assets/mockup_new_design.png`.
Die Bilder in diesem Ordner stammen aus dem Software-Renderer (`tools/render_widget.py`)
und einer Pillow-Skizze; sie sind Illustration, kein fertiges Pixel-Design.

* `simplification_concept_current.png`: der heutige Zustand (Renderer, Mockup-Werte).
* `simplification_concept_mockup.png`: links der heutige Kreis, rechts der vorgeschlagene Kreis in drei Spielsituationen.

---

## 1. Was die Bar heute anzeigt (Inventar)

Jede Zeile ist ein eigenes sichtbares Element. Die Spalte "Frage" sagt, was der Spieler daraus liest.

| Nr. | Element | Ort | Datenquelle | Frage, die es beantwortet |
|---|---|---|---|---|
| 1 | heller Teal-Bogen | Ring | `bp.usedRatio` | Wie viel BP baut gerade wirklich? |
| 2 | dunkler Teal-Bogen | Ring | `bp.reservedRatio` | Wie viel BP hat Aufträge (inkl. Anmarsch, inkl. verhungernd)? |
| 3 | grauer Rest | Ring | 1 - reserved | Wie viel BP ist untätig? |
| 4 | Prozenttext "51%" | Kreisöffnung | `bp.usedRatio` | dasselbe wie 1, als Zahl |
| 5 | weißer Zeiger innen | Kreisloch | `bp.mSupportRatio` | Bis wohin könnte mein Metall-Einkommen die BP versorgen? |
| 6 | oranges Dreieck außen | außerhalb des Rings | `bp.eSupportRatio` | Bis wohin könnte mein Energie-Einkommen die BP versorgen? |
| 7 | dünner Goldbogen außen ("Solar-Band") | außerhalb des Rings | `bp.eSupportMinWind` .. `eSupportMaxWind` | Wie wandert 6 mit dem Wind? |
| 8 | Marker 1.2x größer | 5 / 6 | `bp.stallingMetal` / `stallingEnergy` | Es fehlt gerade Metall / Energie |
| 9 | Blitz-Tönung des ganzen Gauge-Panels (rot / orange) | Panel | `stallingMetal` / `stallingEnergy` | dasselbe wie 8 |
| 10 | Box "Need metal" / "Need energy" | unter dem Gauge | `stallingMetal` / `stallingEnergy` | dasselbe wie 8 und 9 |
| 11 | Box "Idle buildpower" | unter dem Gauge | `bp.idleAlert` (reserved <= 50 %, > 300 BP frei) | dasselbe wie 3, als Text |
| 12 | Box "Need buildpower" | unter dem Gauge | `bp.surplusBP < 0` | Eco könnte mehr BP füttern als ich habe |
| 13 | Box "Too much buildpower" | unter dem Gauge | `surplusBP > 400` und eine Support-Ratio < 0.4 | dasselbe wie 5 / 6 weit links |
| 14 | graue Marker (stale) | 5 / 6 / 7 | `bp.supportStale` | Seit 2 s wird nichts gebaut, Werte sind alt |
| 15 | Hexagon-Icon | Kreismitte | fest | Dekoration / "das ist Buildpower" |
| 16 | Tooltip | Hover | alles | Erklärung plus Zahlen |
| 17 | Metall / Energie: +Einkommen, -Pull, Vorrat, Kapazität, Füllbalken | Panels links / rechts | stock `r[res]` | stock |
| 18 | Overflow- / Wasting-Banner | unter Metall / Energie | stock | Ich überlaufe / verschwende |
| 19 | Low-Storage-Tönung (violett) | Metall / Energie-Panel | stock | Vorrat fast leer |
| 20 | roter Share-Knopf auf Metall, auch im Einzelspieler | Metall-Balken | stock-Logik, im Mockup immer gezeichnet | Teilen mit Verbündeten (ohne Verbündete ohne Funktion) |
| 21 | Wind "15.2" und Bereich "1-25" | Wind-Panel | stock | aktueller Wind, Kartenbereich (statisch) |

---

## 2. Welche Anzeigen sich am ähnlichsten sind

Sortiert nach Redundanz, die größte zuerst.

### Cluster A: "Meine Eco deckelt meine Bauleistung" (Nr. 5, 6, 7, 8, 9, 10, 12, 13, 14)

Neun Elemente beschreiben eine einzige Größe: `min(mSupportRatio, eSupportRatio)`, also die
Stelle auf dem Ring, ab der Einkommen die BP nicht mehr versorgen kann.

* 8, 9 und 10 sind **dreimal derselbe Bool** (`stallingMetal` / `stallingEnergy`): Marker wächst,
  Panel blinkt, Textbox erscheint. Das ist der auffälligste Doppelt-und-dreifach-Fall.
* 5 und 6 sind dieselbe Information für zwei Ressourcen, aber mit **zwei verschiedenen Formen an
  zwei verschiedenen Orten** (Zeiger innen, Dreieck außen). Der Spieler muss zwei Vokabeln lernen.
  Relevant ist fast immer nur das Minimum der beiden.
* 7 (Goldbogen) ist nur die **Unschärfe von 6**. Der Bogen liegt noch weiter außen als das Dreieck,
  ragt am 12-Uhr-Punkt über die Panel-Oberkante (siehe Renderer-Bild) und ist das Element, das Du
  als "Solar-Band" wahrnimmst.
* 12 und 13 sind **Textfassungen der Markerposition**: "Need buildpower" = beide Marker am
  Ringende, "Too much buildpower" = ein Marker weit links. 13 wird heute schon unterdrückt, sobald
  10 zu sehen ist, weil es dasselbe sagt (Kommentar in `bpUi.slowUpdate`).

### Cluster B: "Wie viel BP arbeitet" (Nr. 1, 4, 3, 11)

* 1 und 4: Bogenlänge und Prozentzahl zeigen exakt denselben Wert. Das ist die akzeptable Art von
  Redundanz (Form für den Blick, Zahl für die Genauigkeit), sollte aber bewusst bleiben.
* 3 und 11: der graue Rest ist die "Idle buildpower"-Box. Bei 50 % Grau sieht man das ohne Text.

### Cluster C: Zwei Banner-Systeme nebeneinander (Nr. 10 bis 13 und 18)

Unter Metall und Energie hängen die stock-Banner, unter dem Gauge die BP-Boxen, in zwei Stilen,
mit eigener Reihenfolge und eigenem Debounce. Im Renderer-Bild stehen "Idle buildpower" und
"Need energy" zusammen unter dem Metall-Balken, obwohl beide den Ring kommentieren.

### Cluster D: "Ressource ist knapp" (Nr. 9, 10, 19)

Die violette Low-Storage-Tönung (stock), der BP-Stall-Blitz und die "Need"-Box leuchten bei
einem Energie-Stall gleichzeitig in drei Farben an drei Orten.

### Cluster E: Wind (Nr. 7 und 21)

Der Kartenbereich "1-25" ist statisch und steht bereits im Wind-Tooltip (mit Durchschnitt und
Risiko). Der Goldbogen zeigt die **Folge** desselben Sachverhalts für die Bauleistung.
Eine der beiden Anzeigen reicht; die am Gauge ist die nützlichere, weil sie eine Handlung nahelegt.

---

## 3. Vorschlag: der Kreis trägt die Deckelung selbst

Kern Deiner Idee, hier ausformuliert: die neun Elemente aus Cluster A werden durch **eine rote
Kappe** ersetzt, die vom Ringende (3 Uhr) **gegen den Uhrzeigersinn** bis zur Deckelung reicht.

Siehe `simplification_concept_mockup.png`, Zustände A bis C.

### 3.1 Ring-Segmente (von unten nach oben gezeichnet)

| Reihenfolge | Segment | Von .. bis (Sweep 0..1) | Farbe | Bedeutung |
|---|---|---|---|---|
| 1 | Schatten | 0 .. 1 | wie heute | |
| 2 | Rest | 0 .. 1 | grau | untätige BP |
| 3 | reserviert | 0 .. `reservedRatio` | dunkles Teal | hat Aufträge, baut (noch) nicht |
| 4 | genutzt | 0 .. `usedRatio` | helles Teal | baut gerade |
| 5 | **Kappe** | `limit` .. 1 | rot, deckend | BP, die Einkommen nicht füttern kann |
| 6 | **Flauten-Schatten** (optional) | `limitLowWind` .. `limit` | rot, ca. 45 % Alpha | fällt bei Flaute zusätzlich weg |
| 7 | **Tick** | bei `limit`, innen im Loch | weiß (Metall) oder gelb (Energie) | welche Ressource deckelt |

mit

```
limit        = min(mSupportRatio, eSupportRatio)              -- Modell B, wie die heutigen Marker
limitLowWind = min(mSupportRatio, eSupportMinWind)            -- nur wenn Windgeneratoren vorhanden
bottleneck   = mSupportRatio <= eSupportRatio and "metal" or "energy"
```

Die Kappe hat am Ringende die runde Kappe wie heute, an der Deckelungs-Grenze aber einen **geraden
radialen Schnitt**. So ragt sie nicht halb in das Teal hinein, und die Grenze ist auf ein Grad genau
ablesbar. (`bpUi.ring` zeichnet heute immer beide Enden rund; ein Parameter `flatStart` genügt.)

Die Kappe liegt **über** dem Teal. Wenn das helle Teal die Kappe berührt, ist die BP gedeckelt. Der
Spieler sieht sofort: "Energie reduziert meine maximale Baugeschwindigkeit auf 62 %" (Zustand B),
ohne Zeiger, Dreieck oder Box. Weil `usedRatio` aus tatsächlich gezogenem Metall berechnet wird,
schrumpft das helle Teal bei einem Stall von selbst auf die Kappe zurück; der Rest des reservierten
Bogens verschwindet unter Rot. Das ist inhaltlich richtig: diese Bauer sind zugeteilt, aber
verhungern.

### 3.2 Was aus Cluster A wird

| heute | neu |
|---|---|
| weißer Zeiger (5), oranges Dreieck (6) | rote Kappe plus ein Tick in Ressourcenfarbe. Der Wert der nicht-limitierenden Ressource steht nur noch im Tooltip. |
| Goldbogen Wind (7) | halbtransparente Verlängerung der Kappe nach links bis `eSupportMinWind`. Keine Anzeige mehr für "bester Wind": darauf kann der Spieler nicht reagieren. Option `windRange` bleibt und schaltet nur noch diesen Teil. |
| Marker 1.2x (8), Panel-Blitz (9), Boxen "Need metal / energy" (10) | **ein** Signal: die Kappe blinkt mit `blinkProgress` (hell / dunkel), solange `stallingMetal` oder `stallingEnergy` gilt, und der Prozenttext wird rot. Kein Panel-Blitz, keine Box. |
| "Need buildpower" (12) | keine Kappe plus Ring voll = "bau mehr Bauer". Keine Box. Die Zahl `surplusBP` bleibt im Tooltip. |
| "Too much buildpower" (13) | große Kappe. Keine Box. |
| stale (14) | Kappe und Tick werden grau mit 60 % Alpha, wie heute die Marker. |

Ergebnis: aus neun Elementen werden drei (Kappe, Flauten-Schatten, Tick), alle **innerhalb** des
Rings bzw. des Lochs. Außerhalb des Rings liegt nichts mehr, also auch nichts mehr über der
Panel-Oberkante.

### 3.3 Cluster B bis E

* **Prozenttext (4)** bleibt. Er ist die gelernte Kennzahl und liefert die Genauigkeit, die der Bogen
  nicht hat. Neu: Farbe als Zustand. Teal normal, rot bei Stall, grau bei stale. Die Schwellenfarben
  40 / 60 / 80 aus 0.4.010 würde ich nicht wiederbeleben; sie bewerten, was der Ring schon zeigt.
* **"Idle buildpower" (11)** entfällt als Box. Wer die Grau-Warnung will, bekommt sie über die
  Option `alerts` (siehe unten).
* **Banner (Cluster C):** eine einzige Banner-Zeile unter der Bar, stock-Stil, maximal zwei Boxen,
  Priorität: Wasting > Overflowing > BP-Hinweis. Die BP-Boxen nutzen `bpUi.drawAlerts` schon im
  stock-Stil; es fehlt nur die gemeinsame Zeile und die Priorität.
* **Option `alerts`** wird standardmäßig **aus**. Sie schaltet dann nur noch "Idle buildpower" und
  "Need buildpower" als Lernhilfe für neue Spieler. "Need metal / energy" und "Too much buildpower"
  entfallen ganz, weil der Ring sie trägt.
* **Low-Storage-Tönung (19)** bleibt (stock-Verhalten, andere Aussage: Vorrat, nicht Einkommen).
* **Share-Knopf (20):** im Einzelspieler ausblenden, wie stock. Das Mockup zeigt ihn, aber ohne
  Verbündete ist er ein totes Bedienelement.
* **Wind-Bereich "1-25" (21):** nur bei Hover oder ganz in den Tooltip. Der Flauten-Schatten am
  Gauge zeigt die Konsequenz, die der Spieler braucht.
* **Hexagon-Icon (15):** bleibt (Option `icon` existiert). Wer es ausschaltet, hat Platz für den
  Tick und einen größeren Prozenttext.

### 3.4 Legende danach

Fünf Vokabeln statt zwölf:

1. helles Teal: baut
2. dunkles Teal: zugeteilt, baut nicht
3. grau: untätig
4. rot: kann nicht versorgt werden (blinkt: jetzt gerade nicht); halbtransparent: bei Flaute
5. Tick weiß / gelb: Metall / Energie ist der Engpass

---

## 4. Umsetzung (Skizze, keine Codeänderung in diesem Commit)

Alles liegt in `gui_top_bar_new_design.lua`; die Datenseite muss nicht angefasst werden.

1. **`bpUi.refreshValues`**: statt `s.m`, `s.e`, `s.wMin`, `s.wMax` werden `s.limit`, `s.limitLow`
   und `bottleneck` geglättet und in ganze Grad quantisiert (`bpUi.deg`). Rebuild-Bedingung
   entsprechend: `limitA`, `limitLowA`, `bottleneck`, `stall`, `stale`, `hover`.
2. **`bpUi.buildValueList`**: nach dem hellen Teal `ring(a0 - limitA, 0, C.cap, nil, 0, 0, flatStart)`,
   davor bei `windRange` `ring(a0 - limitLowA, a0 - limitA, C.capSoft, ...)`. Die beiden
   Dreiecks-Blöcke (Energie-Marker, Metall-Zeiger) und der `bpUi.arc`-Aufruf für den Windbogen
   entfallen. Der Tick übernimmt die Geometrie des heutigen Metall-Zeigers (`D.pointR`, `D.pointA`),
   gedreht auf `limitA`, Farbe nach `bottleneck`.
3. **`bpUi.ring`**: Parameter für einen flachen Start (kein Cap am Anfangswinkel).
4. **Stall-Blinken**: die Kappe wird im Per-Frame-Pfad (`drawResbarValues`-Block, heute "stall flash")
   mit `glColor(1,1,1, 0.6 + 0.4 * blinkProgress)` moduliert statt der Panel-Tönung. Dazu kommt die
   Kappe in eine eigene kleine Liste, der Rest des Rings bleibt in `dlist.resValuesBar.BP`.
5. **`bpUi.drawPct`**: Farbe nach `stallingMetal or stallingEnergy` (rot) bzw. `supportStale` (grau).
6. **`bpUi.slowUpdate`**: `on[1]`, `on[2]`, `on[5]` entfallen; `on[3]`, `on[4]` nur bei `cfg.alerts`
   (Default false). Alert-Tabelle auf zwei Einträge kürzen.
7. **`bpUi.tooltipText`**: Absatz "grey and yellow ticks" durch "red cap" ersetzen, beide Support-Werte
   weiterhin nennen.
8. **Konstanten**: `D.windR`, `D.windT`, `D.markApex`, `D.markBase`, `D.markHalf` entfallen;
   `C.cap = { 0.88, 0.22, 0.18, 1 }`, `C.capSoft = { 0.88, 0.22, 0.18, 0.45 }`, `C.tickM = C.pointHi`,
   `C.tickE = { 1, 0.9, 0.33, 1 }`.
9. **Prüfen** mit dem vorhandenen Harness:

```
python3 -I tools/luacheck51.py gui_top_bar_new_design.lua
python3 -I tools/run_widget.py gui_top_bar_new_design.lua
python3 -I tools/render_widget.py gui_top_bar_new_design.lua --calm --bp-used 0.5 --bp-reserved 0.77 \
    --bp-msupport 0.9 --bp-esupport 0.62 --bp-wind-min 0.38 --bp-wind-max 0.8 --out nd.png --scale 3
```

Der Renderer braucht keine Erweiterung: `--bp-msupport`, `--bp-esupport`, `--bp-wind-min` und
`--bp-wind-max` setzen bereits die Felder, aus denen `limit` und `limitLowWind` folgen.

---

## 5. Entscheidungen, die bei Dir liegen

1. **Engpass-Kennzeichnung**: Tick in Ressourcenfarbe (Vorschlag, oben) oder stattdessen das
   Hexagon-Icon in der Mitte durch das Metall-Plättchen / den Blitz ersetzen, solange eine Kappe
   sichtbar ist. Der Tick ist kleiner und stört den Ring nicht; das Icon ist auffälliger.
2. **Flauten-Schatten** standardmäßig an oder aus. Vorschlag: an, weil er auf Windkarten die
   eigentliche Frage beantwortet ("reicht es auch bei Flaute?"), und er ist mit 45 % Alpha ruhig.
3. **Prozenttext**: `usedRatio` behalten (Vorschlag) oder stattdessen `surplusBP` als Zahl mit
   Vorzeichen ("-120 BP" = zu wenig Bauer, "+400" = zu viele). Die zweite Variante ersetzt die
   Boxen 12 und 13 durch eine Zahl, bricht aber mit der gelernten Prozentanzeige.
