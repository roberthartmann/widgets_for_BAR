# Top Bar – Performance-Build (offizielle Version als Basis)

Dieser Ordner hat **nichts** mit den BP-/Buildpower-Funktionen zu tun.
Er enthält die **offizielle** BAR-Top-Bar mit reinen Performance-Verbesserungen.
Funktion und Aussehen sind unverändert.

* Basis: `beyond-all-reason/Beyond-All-Reason`, `master`, `luaui/Widgets/gui_top_bar.lua`
  (sha256 `ad4b3800…3974634`, abgerufen 2026-11-07). Die unveränderte Basis ist der
  erste Commit dieser Datei. `git diff 57f4203 -- topbar_performance/gui_top_bar.lua`
  zeigt **nur** die Performance-Änderungen.
* Name bleibt `"Top Bar"`, damit andere Widgets (Top Bar Buttons, Tooltips …)
  weiter funktionieren.

## Installation / Test im Spiel

1. `gui_top_bar.lua` nach `<BAR>/data/LuaUI/Widgets/` kopieren.
2. Im Spiel F11 öffnen. Bei „Top Bar“ muss `(local)` stehen.
3. Die Basis stammt von `master`. Ist die installierte Spielversion deutlich älter,
   kann die Datei inkompatibel sein (z.B. braucht sie das Widget „Top Bar Buttons“
   und `gl.R2tHelper`). In dem Fall: offizielle Datei der eigenen Spielversion
   nehmen und die Änderungen unten darauf übertragen.

## Änderungen

Alle Stellen sind im Code mit `-- PERF:` markiert.

| # | Wo | Problem in der offiziellen Version | Änderung |
|---|----|------------------------------------|----------|
| 1 | `updateResbarValues` | Die Breite des Füllbalkens ändert sich fast bei jedem 50-ms-Update um ein Pixel. Jedes Mal werden **1 (Metall) bzw. 5 (Energie: Balken + 4 Glow-Listen) Display-Listen neu kompiliert**. Dabei läuft der FlowUI-Lua-Code (`RectRound`, `TexturedRectRound` …) erneut, und zwar innerhalb von DrawScreen. | Listen werden **pro Pixelbreite gecacht**. Die Anzahl der Breiten ist durch die Balkenbreite begrenzt, der Wert pendelt meist in einem kleinen Bereich. Nach kurzer Aufwärmphase wird fast nichts mehr kompiliert. Der Cache wird geleert bei Änderung von Geometrie, Speicherkapazität oder ViewResize, sowie beim Shutdown. |
| 2 | `short()` | Die „Memoization“ baute bei **jedem** Aufruf einen Key-String `n..":"..f`, auch bei Cache-Treffern. Das kostete mehr als es sparte. | Cache mit der Zahl als Key (eine Untertabelle pro Präzision), ohne String-Allokation. |
| 3 | `drawResBars` | Alle 50 ms bis zu 7 neue Tabellen für Scissor-Rechtecke. | Vorab angelegte Tabellen werden wiederverwendet. |
| 4 | `updateResbarText` | Pull/Income-String wurde zweimal zusammengesetzt (4× `short` + 4 Konkatenationen). | Einmal berechnen, Strings direkt vergleichen. |
| 5 | `Update` | `provideButtonFallbacks()` lief jeden Frame. | Läuft im vorhandenen 33-ms-Block. |

### Bewusst NICHT geändert (würde Verhalten/Optik ändern)

* Textaktualisierung (Render-to-Texture) läuft weiterhin mit bis zu 20 Hz.
  Das sind ca. 16 FBO-Wechsel pro Sekunde. Mit 10 Hz würden diese Kosten etwa
  halbiert, die Zahlen wären dann aber träger. Kann man als Option einbauen.
* Glow-Alpha des Füllbalkens: Er ist jetzt pro Breite gecacht. Er hing minimal vom
  exakten Wert ab, sichtbar aber nur unter 2,5 % Füllstand (dort ist der Unterschied
  praktisch null).

## Messung

### Offline-Benchmark (reproduzierbar, ohne Spiel)

```bash
lua5.1 topbar_performance/bench/harness.lua <widget.lua> [sekunden] [fps]
```

Der Harness bildet die Spring-API nach, simuliert schwankende Ressourcen und ruft
`Update`/`GameFrame`/`DrawScreen` wie die Engine auf. Er zählt die Lua-seitige
Arbeit des Widgets: Listen-Kompilierungen, Lua-`gl.Vertex`-Aufrufe,
Render-to-Texture-Pässe und Allokationen. GPU- und Treiberkosten misst er nicht.
Die Zahlen taugen also für den **Vergleich** zweier Versionen, nicht als absolute Werte.

Ergebnis (120 s simuliert, 60 fps):

| Metrik | offiziell | Performance-Build |
|--------|----------:|------------------:|
| CreateList-Kompilierungen | 52,9 /s | 6,5 /s (nach 15 min: 0,9 /s) |
| Lua-Vertices gesamt | 4408 /s | 1517 /s |
| …davon in CreateList | 3288 /s | 398 /s |
| Lua-Allokationen | 36,6 kB/s | 9,2 kB/s (nach 15 min: 6,4 kB/s) |
| Render-to-Texture | 16,2 /s | 16,2 /s (unverändert) |
| Lebende Display-Listen | 18 | Plateau bei ~1000 |

Bei 144 fps: 55,8 → 6,3 Kompilierungen/s, 39,0 → 9,6 kB/s.

Kosten des Caches: maximal etwa 1000 kleine Display-Listen im Grafikspeicher
(wenige MB). Die Zahl ist durch die Balkenbreite begrenzt und steigt nicht mit der
Spieldauer.

### Im Spiel

`WIP/topbar_profiler_snippet.lua` zeigt pro Abschnitt ms/Frame und
Listen-Kompilierungen pro Sekunde. In der offiziellen Datei gehört er direkt
**vor** `-- Localized functions for performance` (also vor
`local glCreateList = gl.CreateList`). Zum Vergleich offiziell und Build nacheinander
messen, mit gleicher Szene, gleicher Spielzeit und gleichem FPS-Limit, Maus nicht
über der Leiste.
