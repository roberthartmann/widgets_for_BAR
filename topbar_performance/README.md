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

### Wichtig: User-Widgets zahlen einen festen Sandbox-Aufschlag

`barwidgets.lua` legt um **jeden Callin eines User-Widgets** (`LuaUI/Widgets/`
im Datenordner) einen Memory Guard (`luaui/Include/memory_guard.lua`). Pro Aufruf
laufen dann 2× `collectgarbage("count")` und 2× `debug.sethook`, und die VM läuft
mit aktivem Count-Hook. Das offizielle **Mod**-Widget aus dem Spielarchiv zahlt
das nicht.

Ein Vergleich „Top Bar (Mod)“ gegen „Top Bar perf (User)“ im F11-Profiler
benachteiligt also immer die User-Kopie, auch wenn der Code identisch ist.
Bei ~285 fps (≈ 570 DrawScreen+Update-Aufrufe/s) reicht das für die
beobachteten +0,1 %. Fair vergleicht man nur zwei User-Widgets miteinander.

Außerdem dürfen User-Widgets andere Widgets nicht inspizieren
(`widgetHandler.widgets is not available to user widgets`). Ein externes
Mess-Widget ist daher nicht möglich.

### Im Spiel: Self-Bench-Varianten (empfohlen)

`bench/variants/` enthält zwei Dateien. Beide laufen als User-Widget, werden
also von der Sandbox gleich behandelt:

| Datei | Widget-Name | Code |
|-------|-------------|------|
| `gui_top_bar_BENCH_official.lua` | Top Bar BENCH official | offizielle Basis (Commit `57f4203`) |
| `gui_top_bar_BENCH_perf.lua` | Top Bar BENCH perf | Performance-Build |

Am Ende beider Dateien hängt derselbe Messblock (`bench/selfbench_block.lua`).
Er misst die eigenen Callins von innen, also **ohne** den Sandbox-Aufschlag, und
schreibt alle 30 s pro Callin Median, Mittelwert, p95, Maximum, Spitzen und ms/s
in Chat und infolog (`[TopBarSelfBench]`). Neu erzeugen:
`bench/make_bench_variants.sh`.

Ablauf:
1. Beide Dateien nach `LuaUI/Widgets/` kopieren (sie sind standardmäßig aus).
2. Replay laden. In F11 die normale „Top Bar“ **aus** und **nur eine**
   BENCH-Variante an.
3. Mindestens 2–3 Fenster zu je 30 s abwarten, Kamera fest, gleiches FPS-Limit.
4. Variante wechseln, an dieselbe Replay-Stelle springen, wiederholen.
5. Die `[TopBarSelfBench]`-Zeilen aus `infolog.txt` vergleichen.

Lesart: **Median** = feste Kosten pro Frame. **„spikes (% of time)“** = Anteil der
Zeit in teuren Einzelframes (Listen-Kompilierung, Render-to-Texture). Die bisherigen
Änderungen sollen genau diesen Anteil senken. Der Median sollte gleich bleiben.

### Im Spiel: Abschnitts-Profiler

`WIP/topbar_profiler_snippet.lua` zeigt pro Abschnitt ms/Frame und
Listen-Kompilierungen pro Sekunde. In der offiziellen Datei gehört er direkt
**vor** `-- Localized functions for performance` (also vor
`local glCreateList = gl.CreateList`). Zum Vergleich offiziell und Build nacheinander
messen, mit gleicher Szene, gleicher Spielzeit und gleichem FPS-Limit, Maus nicht
über der Leiste.
