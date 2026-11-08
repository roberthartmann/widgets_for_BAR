# Patches für BAR-Spielwidgets

Diese Patches betreffen Widgets, die im Beyond-All-Reason-Spielrepository liegen
(nicht in diesem Repo) und werden dort per `git apply` angewendet.

## bar_gui_pip_water_anim_refresh.patch

**Widget:** Picture-in-Picture Minimap (`luaui/Widgets/gui_pip/gui_pip.lua`)
**Basis:** Beyond-All-Reason master, Commit `349f9db8a156bbdf497a319dfb6d18b084f10143` (2026-11-08)

**Problem:** Auf Wasser- und Lavakarten setzt `widget:Update` die Boden/Wasser/LOS-Schicht
(`pipR2T.contentNeedsUpdate`) in jedem Aufruf auf "dirty", damit die Wasseranimation läuft.
Das umgeht den regulären Content-Timer (15 Hz im Minimap-Modus, bis 60 Hz gezoomt) und die
Stagger-Logik zwischen Units- und Content-Render. Die Schicht wird dadurch etwa doppelt so oft
komplett neu gerendert wie vorgesehen, in 2-facher Auflösung plus 15 % Rand.

**Änderung:** Neue Config-Option `waterAnimMinRate = 8`. Die Schicht wird nur noch dann
zusätzlich als dirty markiert, wenn der letzte Render älter als `1 / waterAnimMinRate` ist.
Da der reguläre Timer schneller läuft, greift die Animation darüber; die Option ist nur ein Boden.

**Erwartung:** Halbierung der Cheap-Layer-Renders auf Wasser-/Lavakarten. Wasser animiert mit
der Content-Rate (15 Hz bei Vollzoom statt ~30 Hz), gezoomt unverändert bis 60 Hz.

**Anwenden** (im BAR-Checkout):

```sh
git apply --check /pfad/zu/bar_gui_pip_water_anim_refresh.patch
git apply /pfad/zu/bar_gui_pip_water_anim_refresh.patch
```

Syntax wurde mit Lua 5.1 und LuaJIT 2.0/2.1 geprüft; ein Spieltest steht noch aus.
