# Performance-Analyse Top Bar (Basis: `gui_top_bar_alpha_0.4.010.lua`)

> **Hinweis:** Diese Analyse betrifft die alte BP-Version. Die Performance-Arbeit
> auf Basis der **offiziellen** Top Bar liegt in `topbar_performance/` (siehe README dort).

> Die im Screenshot gezeigte Version `0.4.011 light` ist nicht im Repo.
> Zeilennummern beziehen sich auf 0.4.010. Die Muster unten sind aber genau die,
> die "Optimierungen" typischerweise ins Gegenteil drehen.

## Kernaussage

**Im Spring/Recoil-Widget-Profiler ist nicht das Zeichnen teuer, sondern das
Erzeugen von Display-Listen (`gl.CreateList`).**
`glCallList` einer fertigen Liste kostet fast nichts. Beim `CreateList` läuft
dagegen der komplette Lua-Code der FlowUI-Funktionen (`RectRound`,
`TexturedRectRound`, `font:Print` …), der hunderte `gl.Vertex`-Aufrufe in Lua
erzeugt, plus Treiber-Overhead. Und der Profiler misst genau diese CPU-Zeit.

Jede Änderung, die "mehr in Display-Listen packt", hilft nur dann, wenn die
Liste **selten** neu gebaut wird. Wird sie in `DrawScreen` alle paar Frames neu
gebaut, ist es **teurer als direkt zu zeichnen**. Daher werden "Verbesserungen"
zu Verschlechterungen.

## Gefundene Ursachen (nach geschätztem Gewicht)

### 1. Energie-/BP-Flusseffekt: Display-Liste wird fast jeden Frame neu kompiliert (Hauptverdacht)
`drawResbarValues`, Z. 1543–1559, `createEffectDisplayList` Z. 1432.

```lua
local shouldUpdate = (currentTime - cache.timestamp >= UPDATE_INTERVAL)
                  or (cache.frameCount >= FRAMES_BETWEEN_UPDATES)
                  or (not cache.id)
```

* Das `or` bedeutet: neu bauen, sobald **eine** der Bedingungen erfüllt ist.
  Gedacht war vermutlich ein Drosseln, tatsächlich wird **mindestens alle 4 Frames**
  neu gebaut, bei 60 fps meist alle 2 Frames.
* Das passiert für `energy` **und** `BP`. Pro Neubau: 3× `TexturedRectRound`
  + 1× `RectRound` in Lua + `glTexture("LuaUI/Images/paralyzed.png")` per
  Dateiname + `DeleteList` + `CreateList`.
  → Bei 144 fps ≈ 70–100 Listen-Kompilierungen pro Sekunde nur für den Effekt.
* Das Scroll-Offset (`os.clock()/80` …) wird **in die Liste eingebrannt**.
  Deshalb muss sie überhaupt ständig neu gebaut werden.
* Seit 0.4.008 vorhanden, also auch in allen späteren Versionen.

**Richtige Lösung:** Die Geometrie einmal in eine **statische** Liste packen und
nur die Textur verschieben, z.B. über die Texturmatrix:
```lua
gl.MatrixMode(GL.TEXTURE); gl.PushMatrix(); gl.Translate(offset, 0, 0)
gl.MatrixMode(GL.MODELVIEW)
glCallList(staticEffectList[i])
gl.MatrixMode(GL.TEXTURE); gl.PopMatrix(); gl.MatrixMode(GL.MODELVIEW)
```
Die Liste wird dann nur neu gebaut, wenn sich `valueWidth` ändert (oder man
cached nach Breite wie bei `dlistResValuesBar`). Alternative: Effekt nur mit
~10 Hz statt pro Frame aktualisieren (`and` statt `or`) und so den Großteil sparen.

### 2. BP-Prozenttext: neue Display-Liste alle 100 ms + Speicherleck
`drawResbarValues`, Z. 1562–1599.

```lua
currentResValue[res] = short(cappedCurRes)          -- für BP: short(BP[1]) = "0"
if not dlistResValues[res][currentResValue[res]] then
    ...
    if res == 'BP' then currentResValue[res] = <Prozentzahl> end
    dlistResValues[res][currentResValue[res]] = glCreateList(...)  -- unter Prozent-Key!
```

Geprüft wird mit dem Key `"0"`, gespeichert wird unter dem Prozent-Key.
Der Cache trifft **nie**. Folge: alle 100 ms (`updateText`) ein
`font2:Begin/Print/End` kompiliert, und die alte Liste mit gleichem Prozentwert
wird **überschrieben, ohne `glDeleteList`**. Die Zahl lebender Display-Listen
wächst über das Spiel unbegrenzt (≈ 10 pro Sekunde, ≈ 36 000 pro Stunde).
Das kann den Treiber mit der Zeit langsamer machen, also mit **zunehmender
Spieldauer steigender DrawScreen-Wert**.

**Fix:** Für BP den Prozentwert **vor** dem Cache-Lookup berechnen und als Key nutzen.

### 3. Unbegrenzter Balken-Cache für BP
`dlistResValuesBar[res][valueWidth*10000 + additionalWidth]`, Z. 1491.

Für BP gibt es zwei veränderliche Breiten. Die Kombinationen ergeben bis zu
~Breite² Listen (zehntausende). Jede neue Kombination wird **in DrawScreen**
kompiliert (5× RectRound + Glow + …). Freigegeben wird nur bei `ViewResize`.
→ Häufige Kompilierungen, solange der Balken sich bewegt, plus Leck.

**Fix:** Pro Schicht eine eigene, nach *einer* Breite gecachte Liste (Primärbalken,
Sekundärbalken getrennt), oder nur die letzten N Keys behalten.

### 4. `os.clock()` als Zeitbasis
`os.clock()` liefert **CPU-Zeit des Prozesses**, keine Echtzeit. Unter Linux
werden alle Threads summiert (Recoil ist multithreaded). Die Uhr läuft dann
schneller als die Wanduhr. Intervalle wie `0.033` oder `0.1` werden dadurch
**häufiger** ausgelöst als gedacht, und das Verhalten unterscheidet sich je nach
System und Last. Das erschwert Vorher/Nachher-Vergleiche zusätzlich.

**Fix:** `Spring.GetTimer()` / `Spring.DiffTimers()` verwenden.

### 5. Messfehler beim Vergleichen
* **Layer geändert** (0.4.009: `-99980`, 0.4.010: `-999999`). Die Reihenfolge in
  DrawScreen ändert sich. Synchronisationswartezeiten des Treibers (z.B. beim
  ersten `CreateList` im Frame) werden dem Widget zugerechnet, das sie auslöst.
  Bei geänderter Reihenfolge verschieben sich solche Kosten zwischen Widgets.
* **Spieldauer:** Wegen #2/#3 steigt der Wert über die Zeit. Ein Vergleich
  "alte Version nach 2 min" gegen "neue Version nach 20 min" ist wertlos.
* **FPS:** Die Prozentzahl ist ein Anteil an der Frame-Zeit. Bei höheren FPS
  steigt der Anteil fixer Kosten pro Frame, auch ohne dass sich Code ändert.
* **Hover/Situation:** Liegt die Maus über der Leiste, wird `updateResbar`
  aufgerufen, der Quit-Screen baut jeden Frame eine Liste, usw.

→ Immer gleiche Szene, gleiche Spielzeit, gleiche FPS-Begrenzung, Maus nicht über
der Leiste, und mehrere Messungen.

### 6. Kleinere Punkte (Update, 12,4 kB/s Allocs)
* `Update`: alle 33 ms `r = { metal = {…}, energy = {…}, BP = BP }` erzeugt 3
  neue Tabellen. Werte lieber in bestehende Tabellen schreiben.
* `currentWind = sformat(...)` jeden Frame, sobald `gameFrame ~= lastFrame`.
  `lastFrame` wird nie aktualisiert, die Bedingung ist also immer wahr.
* `Update`-Zweig für Overflow-Slider: in Teams mit nur einem Spieler (`isSingle`)
  bleiben `eneryOverflowLevel/metalOverflowLevel` `nil`. Der Vergleich ist dann
  immer wahr, und `updateResbar` (inkl. Tooltip-Registrierung) läuft 30×/s.
  Das betrifft nur den Spectator-Zweig, sollte aber abgesichert werden.

## Wie messen (genauer als der F11-Profiler)

`WIP/topbar_profiler_snippet.lua` in die zu testende Version einbauen (Anleitung
im Kopf der Datei). Es liefert alle 5 s:

```
[TopBarProf]   <CreateList compile>    0.2100 ms/frame   95.0 calls/s ...
[TopBarProf]   drawResBars             0.2600 ms/frame ...
[TopBarProf]   #CreateList                 95.0 /s
[TopBarProf]   live display lists: 4211  (steigt dieser Wert stetig -> Leck)
```

Erwartung, wenn die Analyse stimmt:
* `#CreateList` liegt bei ~50–150/s statt nahe 0–5/s.
* `<CreateList compile>` erklärt den Großteil von DrawScreen.
* `live display lists` steigt stetig.

Vorgeschlagene Markierungen für den Einbau:
* `drawResBars` (gesamt), darin `effect_energy`, `effect_BP` (Block um
  `createEffectDisplayList`), `valuesBar_<res>`, `text_<res>`
* `wind`, `tidal`, `coms`, `buttons`, `quit` in DrawScreen

Danach jeweils **eine** Änderung einbauen und erneut messen. So sieht man den
Effekt jeder einzelnen Änderung statt einer Summe.
