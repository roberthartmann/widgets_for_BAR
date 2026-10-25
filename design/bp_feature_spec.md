# Buildpower (BP) features of the forked top bar: specification for re-implementation

Status: reference spec, written 2026-10-25 from the code in this repo. No `.lua` file was changed.

Primary source: `gui_top_bar_alpha_0.4.010.lua` (here "0.4.010", widget name "Top Bar with Buildpower 0.4.010", Sep 2024).
All line numbers without a file name refer to that file. Other files are cited as `file:line`.

Short names used for the versions (oldest first, dates from git history and the in-file `versionString`):

| Short | File | Date | Notes |
|---|---|---|---|
| 2.0 | `old_versions/gui_top_bar_2.0.lua` | added 2024-02-04, content Dec 2023 | **Not stock.** Author line says "Floris ... and Robert82" and it holds the first BP bar (140 BP-related lines). It is the oldest BP version, not a clean base. |
| supBP | `old_versions/gui_top_bar_supplyable_BP.lua` | Jan 2024 | "Top Bar supplyable BP" |
| supClean | `old_versions/gui_top_bar_sup_BP_clean.lua` | 2024-01-13 | Same as supBP plus logging, stall-enlarged triangles, "seconds" text commented out |
| preBEHE | `old_versions/gui_top_bar_pre_BEHE.lua` | v0.1.7, 2024-02-26, uploaded 2024-04-09 | gmcnew's version plus Robert's "BEHE" design notes. **Does not compile** (bare `BEHE` token at line 1956). |
| 0.2 | `old_versions/gui_top_bar_alpha.lua` | v0.2.0 2024-02-29, last edited 2024-08-29 | The README describes this file |
| 0.3 | `WIP/gui_top_bar_alpha_0.3.lua` | 2024-08-29 | |
| 0.3.02 | `WIP/Top_Bar_alpha_0.3.02` | 2024-09-01 | |
| 0.4.008 | `old_versions/gui_top_bar_alpha_0.4.008.lua` | Sep 2024 | Same logic as 0.4.010 |
| 0.4.009u | `old_versions/agui_top_bar_alpha_0.4.009unstable.lua` | Sep 2024 | Experiment. **Does not compile** (a lone `-` at line 16) |
| 0.4.010 | `gui_top_bar_alpha_0.4.010.lua` | Sep 2024 | Primary source |

"BEHE" means Beherith, author of the stock *Builder Priority* gadget (`old_versions/unit_builder_priority.lua:27`). The "BEHE" plan was to get per-builder demand and stall data from that gadget instead of computing it in the widget (preBEHE:1944-1976). The `-- BeHe` comments in 0.2+ mark values that were meant to come from there.

Correction to the brief: there is no unmodified stock top bar from 2024 in this repo. `gui_top_bar_2.0.lua` already contains BP code. The only true stock copy is `stock_reference/gui_top_bar.lua` (2026-09-24), which is about 4900 lines away from the fork. In this spec, BP-specific code was found from its markers (`res == 'BP'`, `BP[...]`, `config.drawBPBar`, tracking functions) and by diffing consecutive fork versions.

Correction to the brief: the file `old_versions/unit_builder_priority.lua` in this repo does **not** publish `lowPrioNeededMetal/Energy` or `lowPrioExpenseMetal/Energy`. It sets only the unit rules param `builderPriorityLow` (line 38, 217, 392). It also has a debug restriction, `if teamID == 0` (line 503), so only team 0 is managed. The gadget build that published the four team rules params is not in the repo. Either way they do not exist in current BAR, so every feature that reads them is **dead** (see section 5.4 and section 9).

---

## 1. Data model

### 1.1 Tracked unit types

`TrackUnit(unitID, unitDefID, unitTeam)` (3102-3136) is the only place where units get classified.

* **Team filter:** only `unitTeam == myTeamID` (3103). For a spectator this is the team being watched.
* **Finished units only:** `local _, _, _, _, build = Spring.GetUnitHealth(unitID); local isBuilt = build >= 1` (3105-3106). Nanoframes are never tracked. The unit is added later, when `UnitFinished` fires.
* **Builder test** (3110), with Lua precedence written out:
  `(unitDef.buildSpeed and unitDef.buildSpeed > 0 and unitDef.canAssist) or unitDef.isFactory`
* **Sub-type** (3112-3119), stored as `unitType`:
  * `"factory"` if `unitDef.isFactory`
  * else `"nano"` if `unitDef.name:find("nano")`. This is a Lua pattern match on the def name, for example `armnanotc`, `cornanotcplat`, `legnanotc`.
  * else `"builder"`. This covers commanders, mobile constructors and air constructors.
* **Commanders** get no special handling in 0.4.010. They are ordinary `"builder"` entries with their `buildSpeed`. The `isCommander` table (467-472) is used only by the commander counter. Versions 2.0 to 0.3 replaced the commander's metal cost with `metalCostForCommander = 1250` for the "metal cost of builders" metric (2.0:15, 2.0:1443; 0.2 config). 0.3.02 removed that.
* **Stored record** (3123-3129):
  `trackedBuilders[unitID] = { buildSpeed = unitDef.buildSpeed, isBuilt = isBuilt, unitDefID = unitDefID, unitTeamID = unitTeam, unitType = unitType }`
* **Total BP:** `BP[4] = BP[4] + unitDef.buildSpeed`. This runs only if the unit was not tracked before (3120-3122). `BP[4]` is the sum of `buildSpeed` over all tracked finished builders, nanos and factories. Nothing is averaged.
* **Wind generators** (3130-3133): `elseif unitDef.name == "armwin" or unitDef.name == "corwin"` gives `trackedWinds[unitID] = 1; numWindGenerators += 1`. There is no "already tracked" guard (see bug B14). Legion (`legwin`), T2 and Scavenger variants are missed.
* `unitTracking.trackedNum` is incremented on every builder TrackUnit call, even for units already tracked. Only debug code reads it.

`UntrackUnit(unitID, unitDefID, unitTeam)` (3138-3155):
* It needs `myTeamID == unitTeam` and a valid `UnitDefs[unitDefID]`. Otherwise it does nothing (see bug B4).
* If the unit is in `trackedBuilders` and passes the builder test again, it does `BP[4] -= trackedBuilders[unitID].buildSpeed`, then removes the entry.
* If the unit is in `trackedWinds`, it removes it and decrements `numWindGenerators`.

`InitAdditionalValues()` (3157-3167) is the full rescan. It resets `BP[4]`, `trackedNum`, `trackedBuilders`, `trackedWinds` and `numWindGenerators`, then calls `TrackUnit(u, GetUnitDefID(u), myTeamID)` for every unit in `Spring.GetTeamUnits(myTeamID)`.

`unitCostData` (259, filled in `Initialize` 2998-3008) holds one entry per UnitDef:
```lua
unitCostData[unitDefID] = {
  buildTime = unitDef.buildTime, energy = unitDef.energyCost, metal = unitDef.metalCost,
  EperBP = unitDef.energyCost / unitDef.buildTime,
  MperBP = unitDef.metalCost  / unitDef.buildTime }
```
A builder with build speed `S` that works at full rate on a target `T` uses `S * MperBP(T)` metal per second and `S * EperBP(T)` energy per second. The widget reverses this formula to turn measured metal use back into "BP actually applied".

### 1.2 Call-ins that feed the model

| Call-in | Line | Action |
|---|---|---|
| `Initialize` | 2951-3017 | registers options, `ViewResize`/`init`, `InitAdditionalValues()`, fills `unitCostData`, calls `GameStart` if the game is running |
| `UnitFinished` | 2929 | `TrackUnit` |
| `UnitGiven` | 2925 | `TrackUnit(unitID, unitDefID, unitTeam)`. `unitTeam` is the new owner |
| `UnitTaken` | 2921 | `UntrackUnit(unitID, unitDefID, unitTeam)`. `unitTeam` is the old owner |
| `UnitDestroyed` | 2933 | `UntrackUnit`, then the commander counter |
| `UnitCreated` | 2908 | commander counter only. Since 0.3.02 it does not track |
| `PlayerChanged` | 2891-2906 | `checkSelfStatus()` (updates `myTeamID` etc.), then `InitAdditionalValues()` (full rescan, on every player change of anyone), then `init()` when we just stopped spectating |
| `Update` | 2108-2115 | if `spec` and `GetMyTeamID()` changed: `checkSelfStatus(); init()`. **No rescan here** (see bug B6) |
| `GameFrame` | 1882-2040 | coroutine walk, see section 2 |

Spectators: all computation runs for the watched team. Hover handling (2150) and all BP alerts (906) are disabled when `spec`.

### 1.3 The `BP` table (200-234)

`BP` serves both as the bar's "resource row" (`r.BP = BP`, 1607 and 2149, so the generic metal/energy code can index it) and as a bag of named values.

| Key | Meaning | Written by |
|---|---|---|
| `BP[1]` | constant 0 ("current", unused) | init |
| `BP[2]` | constant 1 (dummy "storage", so the generic code does not divide by 0) | init |
| `BP[3]` | averaged **reserved** BP, integer | `calculateAverages` 1780 |
| `BP[4]` | **total** BP (sum of `buildSpeed`) | Track/Untrack |
| `BP[5]` | averaged **used** BP, integer | `calculateAverages` 1781 |
| `reservedBP_instant`, `usedBP_instant`, `usedBPMetalExpense`, `usedBPEnergyExpense`, `usedBPExceptStalled`, `usedBPIfNoStall` | sums of one full walk | `updateBPValues` 1757-1775 |
| `realWindStrength_instant` | E/s of one wind generator | `GameFrame` 2018-2028 |
| `energyIncomeNoWind` | `E_income - nWind*realWind` (debug only) | 1783-1785 |
| `metalExpensePerBP`, `energyExpensePerBP`, `metalExpenseIfAllBPUsed`, `energyExpenseIfAllBPUsed`, `metalSupportedBP`, `energySupportedBP` | projections | `calculateAverages` |
| `mSliderPosition`, `eSliderPosition` | 0..1 positions of the grey and yellow markers | `calculateAverages` 1876-1879 |
| `eSliderPosition_minWind`, `eSliderPosition_maxWind` | 0..1 wind strip ends, start at 0 | `calculateAverages` 1853-1860 |
| `history_*` | circular buffers, section 3 | |

---

## 2. Per-GameFrame computation

### 2.1 Scheduling (246-252, 1882-2017)

```lua
unitTracking = { frameCheckInterval = 3, maxUnitsPerFrame = 20, nextCheckFrame = 0,
                 totalUnits = 0, unitsPerFrame = 20, trackedNum = 0 }
```
* `GameFrame(n)` returns at once when `not config.drawBPBar or n < nextCheckFrame` (1891). Wind blade rotation is updated before that check.
* A coroutine yields `(unitID, record)` for each entry of `pairs(trackedBuilders)` (1907-1913). It is recreated whenever it is missing or `"dead"`.
* Each processed frame resumes it `unitsPerFrame` times (1915). The `break` on end-of-iteration is commented out (1917-1919), so after the walk ends the remaining iterations keep resuming a finished or dead coroutine (see bug B2).
* When the coroutine is `"dead"` after the loop (2008-2017):
  `totalUnits = #trackedBuilders`, `unitsPerFrame = min(20, ceil(totalUnits / 3))`, `nextCheckFrame = n + 3`, then `updateBPValues()` copies the accumulated sums into `BP` and zeroes the cache.
* Result: up to 60 builders take about 3 to 4 frames of work, then a 3-frame pause. N > 60 builders take `ceil(N/20)+1` frames. One "pass" gives one set of instant values.
* `calculateAverages()` and `updateResbar('BP')` run on **every processed frame** (2029-2030), not once per pass. Each pass therefore pushes the same instant values into the averages 3 or more times (see section 3 and bug B9).

### 2.2 Per-builder logic (1924-1992)

For each yielded builder with `S = buildSpeed`:

1. `if not spValidUnitID(unitID) then UntrackUnit(unitID)`. This passes no def or team, so it does nothing (bug B4).
2. `if not isBuilt then break`. This never triggers, because only built units are tracked.
3. Command count: `GetUnitCommands(unitID, 0)` for builders and nanos, `GetFactoryCommands(unitID, 0)` for factories. With 0 the engine returns a count.
4. `numCommands == 0` means idle and contributes nothing.
5. **Nano fight exclusion** (1941-1945): if `unitType == "nano"` and `numCommands == 1` and `GetUnitCommands(unitID,1)[1].id == 16`, the nano is idle. `16` is the literal for `CMD.FIGHT`; **use `CMD.FIGHT`**. A nano that only has its default fight/area-assist order is not "reserved". `CMD.PATROL` (15) is not excluded.
6. Otherwise the builder is **reserved**: `unitsReservedBP[unitID] = S`. Any command counts, including MOVE, PATROL, WAIT and factory queues. This matches the tooltip text "assigned to tasks or moving to jobs".
7. `builtUnitID = GetUnitIsBuilding(unitID)`. If there is one, `builtUnitDefID = GetUnitDefID(builtUnitID)` and:
   ```lua
   local _, mUse, _, eUse = spGetUnitResources(unitID)
   usedBPMetalExpense  += mUse
   usedBPEnergyExpense += eUse
   usedBP_unit  = mUse / unitCostData[builtUnitDefID].MperBP      -- "BP actually applied", stall-aware
   buildingBP  += S                                               -- "building BP if no stall"
   wantedM = MperBP(target) * S ; wantedE = EperBP(target) * S
   rateM = (wantedM > 0) and mUse / wantedM or 1
   rateE = (wantedE > 0) and eUse / wantedE or 1
   nonStalledBuildingBP += S * min(rateM, rateE)                  -- "non-stalled building BP"
   if usedBP_unit >= 0 then usedBP += usedBP_unit end
   ```
   Reclaim, resurrect, capture and repair of a finished unit have no build target with metal use, so they add 0 to "used". Their resource cost shows up as **non-builder expense** (resurrect energy is mentioned in the README).

At the end of the frame, the frame's sums are added to `cacheDataBase` (`reservedBP_instant`, `usedBP_instant`, `usedBPMetalExpense`, `usedBPEnergyExpense`, `usedBPExceptStalled` = nonStalled, `usedBPIfNoStall` = buildingBP) (1995-2005). `updateBPValues` moves them into `BP[...]` when the pass ends.

Definitions to keep:
* **reserved BP** = sum of `S` over builders that have orders (minus nanos with only FIGHT).
* **used BP** = sum of `metalUse / MperBP(target)` over builders with a build target. This is the BP that actually turned metal into progress in that frame, so stall lowers it.
* **building BP if no stall** (`usedBPIfNoStall`) = sum of `S` over builders with a build target.
* **non-stalled building BP** (`usedBPExceptStalled`) = sum of `S * min(mUse/wantedM, eUse/wantedE)`. It is computed but only shown in debug text, and only as `usedBPIfNoStall`. `buildingBP - nonStalledBuildingBP` gives "stalled BP", a good replacement for the dead low-priority correction.
* 0.4.009u tried another split: "used" = non-stalled BP, and per-BP cost = `totalWantedM / totalWantedBP` (0.4.009u:1810, 1974). `totalWantedBP` is never incremented (0.4.009u:1901, 1993), so it divides by 0. The idea is sound, though. Computing per-BP cost from **wanted** demand instead of actual pull makes the projection independent of the current stall.

### 2.3 Wind (2018-2028)

When `config.drawBPWindRangeIndicators` is on, every processed frame reads `GetUnitResources(u)` for the first entry in `pairs(trackedWinds)` that returns non-nil, and stores its `energyMake` as `BP['realWindStrength_instant']`. This is "E/s per wind generator right now". `cacheDataBase['realWindStrength']` is reset in `updateBPValues` but never used.

Better: `select(4, Spring.GetWind())` clamped to the generator's cap. The widget already reads that value for the wind box (2216).

### 2.4 Dead low-priority correction (2032-2039, 876-881)

Every processed frame reads the four team rules params `lowPrioNeededEnergy`, `lowPrioExpenseEnergy`, `lowPrioNeededMetal` and `lowPrioExpenseMetal`. If all four exist, it stores `stalling.lowPrioX = needed + expense`. `updateResbarText` then adds them to the displayed **pull** of metal and energy (`r[res][3] += stalling[...]`). The params no longer exist, so the values stay 0. **Dead, drop.** 0.3.02:2201-2202 reads them without a nil guard and would raise an error on every frame.

---

## 3. Averaging (152-195, 217-234)

`initWeightedAverage(maxN)` creates a circular buffer `{maxn, i=1, curn=0, sum_vw=0, sum_w=0, v={}, w={}}`.

`addValueAndGetWeightedAverage(t, value, weight)`: if `value ~= nil`, it overwrites the oldest slot, subtracting that slot's `v*w` and `w` once the buffer is full. It adds `value*weight` and `weight`, then advances `i`. It returns `nil` when `|sum_w| < 0.01`, otherwise `sum_vw / sum_w`. A sample with weight 0 still occupies a slot and pushes out an old sample. The preBEHE comment "if weight is 0 the table won't be altered" is wrong. Running sums can drift slightly from float subtraction, which is harmless at size 30.

Series in 0.4.010 (all `maxN = 30`):

| Buffer | Value pushed | Weight | Called from |
|---|---|---|---|
| `history_reservedBP` | `reservedBP_instant` | 1 | every processed frame |
| `history_usedBP` | `usedBP_instant` | 1 | every processed frame |
| `history_nonBuilderMetalExpense` | `M_expense - usedBP_instant * metalExpensePerBP(previous)` | 1 | only if `usedBP_instant >= 1` |
| `history_nonBuilderEnergyExpense` | same for E | 1 | only if `usedBP_instant >= 1` |
| `history_mSliderPosition` | `bpRatioSupportedByMIncome` (1 if nothing is building) | `usedBP_instant` | every processed frame |
| `history_eSliderPosition` | `bpRatioSupportedByEIncome` | `usedBP_instant` | every processed frame |

Commented out in 0.4.010 but used in preBEHE to 0.3.02: `history_eSliderPosition_minWind`, `_maxWind` and `history_eIncomeNoWind` (all 30). preBEHE used 100 samples for the two non-builder series (preBEHE:263-264). 2.0 used a plain 10-sample list (2.0:1487-1515) and supBP used 5 samples (supBP:1443-1466), both with `table.remove(…,1)`.

Effective window: 30 calls, at about 3-4 calls per pass for 60 or fewer builders, covers about 52 game frames (about 1.7 s). It also holds only about 8 distinct passes. With 400 builders a pass takes 21 frames, so the 30 calls cover only about 1.5 passes. Smoothing depends on unit count (bug B9). Push once per pass and define the window in seconds.

---

## 4. `calculateAverages` (1777-1880): exact formulas

Notation: `T = BP[4]` (total BP), `U = usedBP_instant`, `I_M = r.metal[4]`, `X_M = r.metal[5]` (team metal income and expense from `GetTeamResources`), and the same for E. `nW = numWindGenerators`, `w = realWindStrength_instant`, `Wmax = Game.windMax`.

```text
BP[3] = floor(WA(history_reservedBP, reservedBP_instant, 1) + 0.5)
BP[5] = floor(WA(history_usedBP,     U,                  1) + 0.5)
if windOption: energyIncomeNoWind = I_E - nW * w                     -- unused except old debug text

mRatio = 1 ; eRatio = 1
if U >= 1 then
  m_prev = metalExpensePerBP or 0 ; e_prev = energyExpensePerBP or 0   -- value from the PREVIOUS call
  nonBuilderM = WA(history_nonBuilderMetalExpense,  X_M - U * m_prev, 1)
  nonBuilderE = WA(history_nonBuilderEnergyExpense, X_E - U * e_prev, 1)

  metalExpensePerBP  = usedBPMetalExpense  / U       -- = BP-weighted mean MperBP of current targets
  energyExpensePerBP = usedBPEnergyExpense / U

  metalExpenseIfAllBPUsed  = nonBuilderM + metalExpensePerBP  * T
  energyExpenseIfAllBPUsed = nonBuilderE + energyExpensePerBP * T

  if metalExpensePerBP > 0:
     metalSupportedBP = I_M / metalExpenseIfAllBPUsed * T
     mRatio = clamp01(metalSupportedBP / T)              -- = I_M / metalExpenseIfAllBPUsed
  if energyExpensePerBP > 0:
     energySupportedBP = I_E / energyExpenseIfAllBPUsed * T
     eRatio = clamp01(energySupportedBP / T)

  if windOption:
     target_min = (I_E - nW * w)               / (energyExpensePerBP * T)
     target_max = (I_E + nW * (Wmax - w))      / (energyExpensePerBP * T)
     eSliderPosition_minWind = clamp01(prev_min + (target_min - prev_min) * 0.1)   -- smoothingFactor 0.1
     eSliderPosition_maxWind = clamp01(prev_max + (target_max - prev_max) * 0.1)
  -- minSupportedBP is computed (1869-1873) and never used
end
mSliderPosition = WA(history_mSliderPosition, mRatio, U)
eSliderPosition = WA(history_eSliderPosition, eRatio, U)
```

Points the re-implementer must decide on:

1. **Two supported-BP models exist.**
   * 0.2 to 0.4.010 (model B, above): `ratio = income / (nonBuilderExpense + perBP*T)`. This is the share of total demand that income could feed if every builder worked. It matches how the engine rations resources proportionally on a stall. It never reaches 0, even when income is below non-builder expense.
   * preBEHE:2203-2211 (model A): `supportedBP = (income - nonBuilderExpense) / perBP`, then `ratio = clamp01(supportedBP / T)`. This is the marginal BP the leftover income could feed after non-builders are fully supplied. It is more pessimistic and linear.
   * Both give the same result when nonBuilderExpense = 0.
   * Model A also gives a meaningful **BP surplus/deficit** `T - supportedBP` (preBEHE:2232-2234, rounded up to 10). Recommendation: keep B for the markers, because that is what users learned, and compute A for the surplus number.
2. Non-builder expense uses the per-BP value of the previous call. It is simpler and exact to compute `X_M - usedBPMetalExpense` directly.
3. The wind strip targets leave the non-builder E expense out of the denominator, unlike `eRatio`. The yellow marker can therefore sit outside its own strip (bug B11). "Min wind" assumes zero wind instead of `Game.windMin`. "Max wind" uses `Game.windMax` without the generator cap, while preBEHE used `math.min(25, Game.windMax)` (preBEHE:2217).
4. Everything is projected from what is being built right now. If the only active builds cost no energy, `energyExpensePerBP` is 0 and the E marker keeps its last average.

---

## 5. Stall and idle detection, and alerts

### 5.1 Flags (`updateAllyTeamOverflowing`, 2042-2099, runs once per second from `Update` 2203-2212)

For `teamID == myTeamID`, with `metal, metalPull` from `GetTeamResources` (current amount and pull):
```lua
playerStallingMetal  = (BP.mSliderPosition ~= nil and BP.mSliderPosition < 0.8 and metal  < 2 * metalPull)
playerStallingEnergy = (BP.eSliderPosition ~= nil and BP.eSliderPosition < 0.8 and energy < 2 * energyPull)
```
In words: projected support is below 80 %, and storage holds less than 2 seconds of current pull. The guard `if res ~= 'BP' or config.drawBPBar` (2077) reads an undefined global `res`, so it is always true.

Older definition (2.0:1344-1351, supBP:1548-1556): `usefulBPFactor = income / (pull + lowPrioStall) < 0.8 and storage < 2*pull`. There the energy flag was only set when metal was not stalling.

### 5.2 Idle flag (908-910, inside `updateResbarText`, once per second, not for spectators, after frame 90)

```lua
notifyBPIdle = BP[3] / BP[4] <= 0.5 and (BP[4] - BP[3]) > 300
```
That is: half or more of the BP is idle, and more than 300 BP is idle.

### 5.3 Alert boxes (912-1024, `showBuildpowerAlert` 1030-1037)

The alert fires when `config.drawBPBar and (playerStallingMetal or playerStallingEnergy or notifyBPIdle)`. It first appears after a 1.1 s delay (`showOverflowTooltip.BP = os.clock()+1.1`). It is rebuilt with the per-second text refresh and cleared when the condition ends.

Boxes are drawn below the BP section, right-aligned to its right edge and stacked to the left:

| Order | Text | Background gradient (bottom, top) |
|---|---|---|
| 1 | `Need metal` | warning `{0.35,0.1,0.1,1}` / `{0.25,0.05,0.05,1}` |
| 2 | `Need energy` | warning, same |
| 3 | `Idle buildpower` | info `{0.20,0.20,0.20,1}` / `{0.12,0.12,0.12,1}` |

`showBuildpowerAlert(area, text, fontSize, low, high, offset, pad)`:
* Text is padded to `'   '..text..'   '`. `textWidth = font2:GetTextWidth(text)*fontSize`.
* Box: `RectRound(area[3]-(offset+textWidth)+pad, area[2]-15.5*ws+pad, area[3]-offset-pad, area[2], 2.8*ws, 0,0,1,1, low, high)`.
* Text: `font2:Print(text, area[3]-offset, area[2]-9.3*ws, fontSize, 'or')`. The function returns `offset+textWidth`.
* `pad = 2.2*ws`. `fontSize = (46*(1+(ui_scale-1)/1.33)/4)*ws`. Text color `(1,0.88,0.88,1)`, outline `(0.2,0,0,0.6)`.
* The BP section is narrow, so the boxes run under the metal bar.

The alert texts are not localized. Older wording:
* 2.0 and supBP: `"Stalling on metal"` / `"Stalling on energy"` (2.0:746-751).
* supClean: just `"metal"` / `"energy"`.
* 0.2 to 0.3.02 also had `Too much buildpower` and `Need buildpower` (section 9). They showed `Need metal/energy` only in pro mode (0.2:1071-1085).

### 5.4 Bar highlight while stalling (2333-2337)

`if playerStallingMetal or playerStallingEnergy then glCallList(dlistResbar.BP[4])`. In 0.4.010 no `glColor` is set first, so the color is whatever was set last (bug B12). In 2.0 the highlight blinked: `glColor(0,-0.4,-0.4,0.5*blink)` for metal and `glColor(0.2,-0.2,-1,0.5*blink)` for energy (2.0:1719-1723).

---

## 6. Visual spec of the BP bar (0.4.010)

### 6.1 Placement and width (`init`, 1603-1700)

Shared by all sections: `ws = widgetScale`, `height = 46*(1+(ui_scale-1)/1.7)`, `ui_scale = config.barScale * ui_scale setting`.

```lua
totalWidth = topbarArea[3] - topbarArea[1]                   -- topbar starts at 0.3*vsx
width      = floor(totalWidth / 4.4) * config.barWidth
buttonWidth = floor(totalWidth / 4)
smallSectionsWidth = floor(height*1.18*ws + widgetSpaceMargin) * (#wind/tidal/coms boxes)
maxTopBarWidth = totalWidth - buttonWidth*1.5 - smallSectionsWidth - widgetSpaceMargin
mebCombinedWidth = min(width*2 - widgetSpaceMargin, maxTopBarWidth)   -- with BP bar
bpWidth = floor(mebCombinedWidth / 6)
width   = floor((mebCombinedWidth - bpWidth) / 2)                     -- metal and energy each
```
Order: **metal | BP | energy | wind | tidal | coms | ... buttons**, with `widgetSpaceMargin` between sections (1640-1654). Before 0.3.02 the order was metal | energy | BP. preBEHE and 0.2 used `bpWidth = mebCombinedWidth/3` in pro mode. 2.0 and supBP gave BP the same width as metal and energy. `WG.topbar.GetFreeArea()` starts after all sections, so it already accounts for BP.

### 6.2 Inside the BP section (`updateResbar`, 1039-1415)

* Bar height and vertical position are the same as metal and energy: `barHeight = floor(height*ws/7 + 0.5)`, bottom at `area[2] + floor(height/4.4*ws + 0.5)`.
* Horizontal: `barArea = { area[1] + 14.5*ws, ..., area[3] - 14.5*ws, ... }` (1094). It runs across the whole section because there is no icon column.
* **Icon:** `LuaUI/images/stripes.png` tinted `glColor(1,0.9,0.2,1)` (yellow hazard stripes). Size `height/3*ws`. Top-left at x = `area[1]+14.5*ws`, top edge `area[4]-bgpaddingHalf-iconPadding` (with `iconPadding = floor(areaH/9)`), drawn with `TexturedRectRound`, corner `iconSize*0.2`. The texture option string contains `", "` with a space (1133); verify that it loads. 2.0 to supClean used a custom `LuaUI/Widgets/topbar/BP.png`, which is not shipped.
* **Bar background:** generic dark rounded rect `{0,0,0,0.12}/{0,0,0,0.15}`, noise texture at alpha 0.16, frame and gloss (1150-1173).
* **Red idle background (regression):** the **intended** background is red `{1,0,0,0.22}` bottom and `{1,0,0,0.25}` top, so the idle (unreserved) part reads red. The variables are set (1153-1160) but never passed to `RectRound` (1161). The red background worked in preBEHE to 0.3.02 (for example 0.2:1339-1346) and was lost in 0.4.008. Restore it.
* **Fills** (`drawResbarValues`, 1469-1527). `total = max(1, BP[4])`, `reserved = min(total, BP[3])`, `used = min(total, BP[5])`:
  * `valueWidth = floor(used/total * barWidth)`, at least `ceil(barHeight*0.2)`.
  * `additionalWidth = floor(reserved/total * barWidth) - valueWidth`, set to 0 if below `ceil(barHeight*0.2)`.
  * **Used:** rounded rect from the bar start to `valueWidth`, gradient `{0.2,0.65,0,1}` to `{0.5,0.75,0,1}`, inner shade `{0,0,0,0.1}/{0,0,0,0.17}`.
  * **Reserved:** drawn after the glow, from the bar start to `valueWidth+additionalWidth`, translucent `{0.1,0.55,0,0.5}/{0.3,0.65,0,0.5}`. It covers the used part as well. In the tooltip this is the "dark green bar".
  * **Idle:** whatever is left (meant to be red).
* **Glow:** bar color `{0,1,0,1}` (1069-1071). `glowAlpha = 0.035 + 0.06*min(1, BP[1]/BP[2]*40) = 0.035`, a constant. The glow rects come from `barTexRect`, which is computed from the generic barArea before the BP override (1074-1077 against 1092-1096). The glow is therefore shifted right of the BP fill (bug B13).
* **Effect display list** (1416-1455, 1543-1560). For **energy and BP**, `createEffectDisplayList(res, valueWidth, barHeight, barWidth)` builds a list that draws:
  * 3 scrolling layers of `LuaUI/Images/paralyzed.png` (color `1,1,1,0.33`, additive blend, offsets `-t/80`, `t/70`, `-t/55`, texture scales `barWidth/0.5`, `/0.33`, `/0.45`) over the used width;
  * a `{1,1,0,0.14}` yellow tint rect enlarged by `addedSize = floor(barH*0.15+0.5)`.
  * The list is rebuilt when ≥0.033 s (`UPDATE_INTERVAL`) have passed, or after 3 draw calls (`FRAMES_BETWEEN_UPDATES`), so in practice on most frames. Stock draws this effect directly, and only for energy. Recreating a display list every frame is slower than drawing directly. The yellow tint over a green bar is a leftover from the energy code. Drop it or make it green.
* **Eco-support markers** (1198-1261, only if `config.drawBPIndicators`). `indicatorH = barHeight`, `barIntrusion = 0.4*barHeight`, `indicatorW = 1.2*indicatorH`, `corner = indicatorH/2`. `multM` and `multE` are `1.4` when the matching stall flag is set, else `1`.
  * **Metal** (grey, bottom edge, pointing up). Centre x = `barArea[1] + mSliderPosition*barWidth`, half width `indicatorW*multM/2`. y runs from `barArea[2] + barIntrusion - indicatorH*multM` to `barArea[2] + barIntrusion`. Rounded TL/TR only (`1,1,0,0`), corner `corner*multM`, gradient `{0.6,0.6,0.6,1}` to `{1,1,1,1}`. Drawn only if the position is not nil.
  * **Wind range strip** (drawn first). Only if `drawBPWindRangeIndicators and numWindGenerators > 0` and both ends are non-nil. They are always non-nil, because they start at 0. x runs from `barArea[1] + minWind*barWidth - halfWE` to `barArea[1] + maxWind*barWidth + halfWE`. y runs from `barArea[4] + 0.4*barH` to `barArea[4] + 0.6*barH`, a thin band above the bar. No rounded corners. Gradient `{0.8,0.8,0,1}` to `{0.4,0.4,0,1}`.
  * **Energy** (yellow, top edge, pointing down). Centre x = `barArea[1] + eSliderPosition*barWidth`. y runs from `barArea[4] - barIntrusion` to `barArea[4] - barIntrusion + indicatorH*multE`. Rounded BR/BL only (`0,0,1,1`). Gradient `{0.8,0.8,0,1}` to `{1,1,0.2,1}`.
  * supBP and supClean drew both markers with a `triangle.png` texture of width `1.3*shareSliderWidth`, tinted `(0.8,0.8,0.8)` and `(1,1,0.6)`. supClean doubled the size when stalling (supClean:976-993).
* **Percent text** (1569-1579, position 1092-1093):
  * `value = min(100, round(BP[5]*100/BP[4]))` with suffix `%`. It shows nothing while `BP[4] == 0`.
  * Colors: `<40` gives `{0.82,0.39,0.39}` (red); `<60` gives `{1.0,0.39,0.39}` (named "orange" in the code, but actually light red); `<80` gives `{1.0,1.0,0.39}` (yellow); otherwise `{0.47,0.92,0.47}` (green). Use a real orange such as `{1,0.6,0.2}`.
  * Position: centred at `genericBarArea[1] + genericBarWidth/2 - 10*ws`, y `barArea[2] + barHeight*1.8`, size `height/2.5*ws`, `'ocd'`, black outline.
  * The displayed number is **used** BP %. `readme_pics/simplified_BP_bar.png` labels it "reserved BP in %". That label is out of date: it changed in commit e80ae91 (2024-08-27).
* **Hover** (2150-2161): `resbarHover = 'BP'` rebuilds the section with larger `sliderHeightAdd`, but nothing on the BP bar uses that value, so hover has no visible effect. Hover is disabled for spectators. `hoveringElement` (2229-2252) leaves out the BP area, so the cursor is not reset to normal over it.
* **Number text slots:** 0.4.010 prints no pull, expense, income or storage text for BP. Pro mode in preBEHE to 0.3.02 printed total BP in the storage slot (grey-green `0.45,0.6,0.45`), used BP in the pull slot (`\255\0\255\0`) and reserved BP in the expense slot (`\255\50\155\0`) (0.2:1010-1024).

---

## 7. Tooltip texts

Tooltips are registered in `updateResbar('BP')`, which runs on every processed frame (1305-1406). Area `BP_all` is the bar strip only.

`textColor = '\255\215\215\215'` and `highlightColor = '\255\255\255\255'`. Percentages are `floor(x/total*100+0.5)`, clamped to ≥0, and formatted `%3d%%`.

Normal tooltip (title `bpTooltipTitle`, an undefined global, so there is no title; preBEHE used `"Buildpower"`):
```
Your total buildpower (BP) is <total>, of which:
<assigned>% is assigned to tasks or moving to jobs (dark green bar).
<active>% is currently active and being used (green bar). This is the number shown.
<idle>% is idle with no BP tasks (red part).
```
The following is appended if `drawBPIndicators` is on and both positions are non-nil:
```

The grey and yellow indicators show you that, if all BP were fully engaged:
Metal income would support <ceil(mSlider*100)>% of BP.
Energy income would support <ceil(eSlider*100)>% of BP.
```
Debug block, appended if `config.debugTooltip` (default **true** in 0.4.010). `float_to_s` prints `%.3f`, or `"nil"` for nil:
```

DEBUG:<avgUsed> BP used (smoothed), <usedBP_instant> BP non-stalled <usedBPIfNoStall> if no stall 
<nBuilders> tracked builders
<nBuiltBuilders> built builders
<BP[4]> total BP 
<M expense> M, <E expense> E spent by all units
<usedBPMetalExpense> M spent by builders, 
<usedBPEnergyExpense> E spent by builders, 
<M expense> / <E expense> metal/energy expense, 
<metalExpensePerBP> / <energyExpensePerBP> M/E expense per BP, 
<E income> E income
<numWindGenerators> wind generators

projections:
<metalExpenseIfAllBPUsed> M spent if all BP is used, 
<energyExpenseIfAllBPUsed> E spent if all BP is used, 
<metalSupportedBP> BP supported by M income, 
<energySupportedBP> BP supported by E income,

```
The labels are misleading. "BP non-stalled" prints `usedBP_instant` (metal-derived used BP), not `usedBPExceptStalled`. `nBuiltBuilders` is always 0 because it reads `v[2]` from a record with named fields (1350-1356). Up to 0.3.02 the block also printed `M/E spent by non-builders`, `E income without wind` and `versionString`.

Percent-text tooltip (`BP_Current`, over the number): `You are using <min(100, round(BP[5]*100/BP[4]))>% of your buildpower.` In pro mode, 0.2 to 0.3.02 showed one of these instead (0.2:1577-1586):
* `You have just enough buildpower to keep up with your income`
* `You have <surplus> buildpower more than you need to keep up with your income`
* `You need <-surplus> more buildpower to keep up with your income`

2.0 tooltips (2.0:993-998):
* `"<used> BP is actually used"`
* `"<reserved> BP is reserved for current and comming projects"`
* `"you've got <total> BP in total"`
* `"your idling BP is costing you <n>s of metal income. Consider less BP if this number is above 20"`

README wording to reuse in help text (`README.md`, section "Understanding the Sliders"):
* The metal slider shows "whether you need more build power or have too much". **Aim for 70-90 %.** Above 90 % you will not spend all your metal, because factory exits and walking constructors cause slack. Below 70 % you are "wasting metal in unused BP".
* Energy slider: "keep it at around double the metal slider or at 100 %". "Never run short on energy": LLTs stop firing in low wind, and metal extractors stop producing when energy runs out. Rez bots drain energy, and the energy slider shows this.
* Images: `readme_pics/simplified_BP_bar.png` (used / reserved / idle, out of date, see 6.2), `widget_explain.png` (2.0 layout: reserved, used, "time you are behind" in seconds, total metal cost of real builders), `sliders_01.png` (0.2-era "Stalling on energy").

---

## 8. Options and config persistence

`config` defaults (20-29) and `OPTION_SPECS` (34-85). They are registered in `Initialize` only if `WG['options']` exists (2955-2959) and removed in `shutdown` (3086-3090).

| id (`"top_bar_bp_" .. var`) | name | description | type | range | default |
|---|---|---|---|---|---|
| `top_bar_bp_drawBPBar` | buildpower bar | Draw the buildpower bar (requires reload) | bool | | true |
| `top_bar_bp_drawBPIndicators` | eco support indicators | Estimate how much buildpower is supported by your metal and energy income | bool | | true |
| `top_bar_bp_drawBPWindRangeIndicators` | wind range indicators | Show how energy-supported buildpower might vary with wind speed | bool | | true (false before 0.4) |
| `top_bar_bp_autoHideButtons` | auto hide buttons | "" | bool | | false |
| `top_bar_bp_debugTooltip` | debug data | Show debug data in tooltip when hovering over the buildpower bar | bool | | true (false before 0.4) |
| `top_bar_bp_barScale` | top bar height | height of the top bar (requires reload) | slider | 0.5-2, step 0.01 | 1 |
| `top_bar_bp_barWidth` | top bar width | width of the top bar (requires reload) | slider | 1-3, step 0.01 | 1 |

Options removed after older versions:
* `proMode` ("pro mode", "Show advanced buildpower statistics and debug info (requires reload)"): supBP to 0.3.02.
* `countStalledAsIdle` ("count stalled buildpower as idle", "Should stalled buildpower count as idle? (If not, it will count toward reserved buildpower.)"): preBEHE only.
* Non-menu config: `metalCostForCommander = 1250`, `includeFactories`, `includeConsBeingBuilt`, `guardingIdleBuilderCountsAsIdle`.

Mechanics (`addOptionFromSpec`, 98-121):
* The option table is copied. `configVariable` is cleared and `id` is set. `widgetname` = widget name. `value` is read from `config`, or an index for `select`. `onchange` writes `config[var] = value`.
* No `group` or `category` is set; check how the current options widget handles that.
* `Update` calls `configHasChanged()` (128-137) and runs `init()` when any value changed, so most options take effect without a reload.
* `GetConfigData()` returns the whole `config` table. `SetConfigData(data)` copies back only keys that exist in `config` (139-147).

---

## 9. Feature × version table

Legend: **Y** present and working, **y** present with caveats, **–** absent, **dead** code exists but does nothing, **!** broken.

| # | Feature | 2.0 | supBP | supClean | preBEHE | 0.2 | 0.3 | 0.3.02 | 0.4.008 | 0.4.009u | 0.4.010 | Carry over? |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | File compiles | Y | Y | Y | ! (1956) | Y | Y | Y | Y | ! (16) | Y | |
| 2 | Big number = "seconds behind" (idle builders' metal cost ÷ M income; 2.0:1108-1128; colors >120 red, >80 orange, >40 yellow, >20 bright yellow, else green) | Y | Y | – (commented) | – | – | – | – | – | – | – | No. Abstract and confusing; README already moved away from it |
| 3 | Big number = % BP | – | – | – | reserved % | used % | used % | used % | used % | used % | used % | **Yes** (used %) |
| 4 | Pro mode: total / used / reserved numbers + BP surplus as big number | – | flag only | flag only | Y | Y | Y | Y | – | – | – | Partly: put numbers in tooltip, no mode switch |
| 5 | BP surplus/deficit, alerts `Too much buildpower` (surplus > 400 and a marker < 0.4) / `Need buildpower` (surplus < 0) (0.2:1046-1067, 1190-1196) | – | – | – | Y | Y | Y | Y | – | – | – | **Yes**, with model A from section 4. "Need buildpower" (income exceeds what all BP can use) is otherwise invisible |
| 6 | "Supplyable BP" triangles: `pos = min(1, income/(pull+lowPrioStall) * avgReserved/total)` (supBP:1422-1431), `triangle.png` | – | Y | Y (×2 on stall) | – | – | – | – | – | – | – | No as markers (superseded). Keep `income/pull` as a cheap *current* supply ratio field |
| 7 | Eco-support markers, projection model (RectRound) | – | – | – | Y (model A) | Y (B) | Y (B) | Y (B) | Y (B) | ! (div 0) | Y (B) | **Yes** |
| 8 | Marker ×1.4 when stalling | – | – | ×2 | Y | Y | Y | Y | Y | Y | Y | Yes |
| 9 | Wind range strip | – | – | – | WA(30), off | WA, off | WA, off | WA, off | 0.1 smoothing, on | same | same | Yes, after fixing B11 and generator detection |
| 10 | Weighted circular averages | 10-list | 5-list | 5-list | Y (30/100) | Y (30) | Y | Y | Y | Y | Y | Yes, once per pass |
| 11 | Reserved = any order (nano FIGHT excluded) | – | – | – | any first cmd | – | – | – | Y | Y | Y | Yes, with `CMD.FIGHT` |
| 12 | Reserved = REPAIR/RECLAIM/CAPTURE/GUARD/build cmd (`findBPCommand`) | Y (+ resource use) | Y (+ factory queue) | Y | – | Y | Y | Y | – | – | – | No. "Moving to a job" should count as reserved |
| 13 | Guard chains of idle builders count as idle (preBEHE:2031-2093, cycle-safe) | – | – | – | Y | config only, code removed | same | same | – | – | – | **Yes**. Cheap, and stops guarding cons from inflating "reserved" |
| 14 | `countStalledAsIdle` option | – | – | – | Y | – | – | – | – | – | – | No. Expose `stalledBP` instead |
| 15 | Unfinished cons count as total/reserved | – | – | – | option | y (tracked as built at UnitCreated) | y | – (fixed) | – | – | – | No |
| 16 | Factories counted | y (only if canAssist) | y | y | y | Y (`or isFactory`) | Y | Y | Y | Y | Y | Yes |
| 17 | Used BP = `GetUnitCurrentBuildPower × buildSpeed` | Y | overwritten | overwritten | commented | – | – | – | – | – | – | **Evaluate.** One engine call per builder and stall-aware; check its meaning in current Recoil |
| 18 | Used BP = `metalUse / MperBP(target)` | – | Y | Y | Y | Y | Y | Y | Y | (non-stalled) | Y | Yes (or 17) |
| 19 | Per-BP cost from wanted demand (stall-independent) | – | – | – | – | – | – | – | – | ! | – | Yes, fix the denominator |
| 20 | Low-prio stall via `CMD_PRIORITY` (34571) cmdDesc lookup | Y | Y | Y | Y | Y | Y | – | – | – | – | No. Use per-builder wanted-vs-used (`stalledBP`) |
| 21 | Low-prio stall via team rules params `lowPrio*` | – | – | – | – | – | – | ! (no nil guard) | dead | dead | dead | **Dead, drop.** Replacement: `stalledBP` from 2.2 |
| 22 | Commander metal cost override 1250 | Y | Y | Y | Y | Y | Y | – | – | – | – | No |
| 23 | Batching | every 15 frames, inside `Update` (runs several times per frame at high fps) | index window 100 per 2 frames (`pairs` bug, preBEHE:1913-1915) | same | same | coroutine 100 per 2 frames | same | same | coroutine ≤20 per frame + 3-frame pause | same | same | Coroutine-free cursor or full pass every N frames, see 11 |
| 24 | Alerts `Need metal` / `Need energy` | "Stalling on …" | same | "metal"/"energy" | pro mode only | pro only | pro only | pro only | always | always | always | Yes, always |
| 25 | Alert `Idle buildpower` | – | – | – | Y | Y | Y | Y | Y | Y | Y | Yes |
| 26 | Stall flag uses projected marker < 0.8 and storage < 2 s pull | – (uses income/pull) | – | – | Y | Y | Y | Y | Y | Y | Y | Yes |
| 27 | Blinking bar tint while stalling | Y | Y | Y | tint commented out, highlight drawn with no color (B12) | same | same | same | same | same | same | Optional; set an explicit color |
| 28 | Red idle background | – | – | – | Y | Y | Y | Y | dead | dead | dead | **Yes**, restore |
| 29 | Icon | BP.png (not shipped) | same | same | stripes.png | same | same | same | same | same | same | stripes or a stock build icon |
| 30 | Bar order | M E BP | M E BP | M E BP | M E BP | M E BP | M E BP | M BP E | M BP E | M BP E | M BP E | Not applicable to an attachment widget |
| 31 | Ring gauge prototype ("Rumble", `DrawPartialRing`) | – | – | – | – | function only | commented | **drawn at fixed (300,300)** (0.3.02:2549-2589) | – | – | – | No |
| 32 | `createEffectDisplayList` for E and BP | – (direct draw) | – | – | – | – | – | – | Y | Y | Y | No |
| 33 | WG options menu | – | – | – | Y | Y | Y | Y | Y (unguarded) | Y | Y (guarded) | Yes, fewer options |
| 34 | Disables stock "Top Bar" in Initialize | – | – | – | – | – | – | – | Y | Y | commented | Not applicable |
| 35 | `builderUpdateInterval` sync with gadget (0.3:1963-1968, read commented) | – | – | – | – | – | dead | dead | – | – | – | No |
| 36 | BEHE plan: take per-builder data from the Builder Priority gadget | – | – | – | notes only (1944-1976) | `-- BeHe` markers | same | same | same | same | same | No. The gadget never published it and the stock gadget changed |

---

## 10. Known bugs and fragile spots in 0.4.010

| ID | Where | Problem | Fix |
|---|---|---|---|
| B1 | 1944 | Literal `16` | `CMD.FIGHT`. Consider `CMD.PATROL` too |
| B2 | 1915-1921 | After the walk ends the loop keeps resuming. Then `unitID` is `nil` or the string `"cannot resume dead coroutine"`, which is passed to `spValidUnitID` and `UntrackUnit` | Restore `if not success or not unitID then break end`, or drop the coroutine for a key cursor |
| B3 | 1907-1913 | `pairs()` over `trackedBuilders` while units are added between resumes. Adding keys during traversal is undefined in Lua 5.1, so units can be skipped or seen twice | Iterate over a snapshot array taken at pass start |
| B4 | 1920-1921 | `UntrackUnit(unitID)` without def or team does nothing, so dead units stay tracked and `BP[4]` stays too high if a destroy event is missed | Store def and team in the record and untrack by ID |
| B5 | 3109 | `name:find("nano")` classification | `isBuilder and not isFactory and not canMove` (static assist turret) |
| B6 | 2108-2115 | Spectator team switch in `Update` calls `init()` but no rescan; correctness relies on `PlayerChanged` | Rescan whenever `myTeamID` changes |
| B7 | 2896 | `PlayerChanged` does a full rescan for any player's change | Rescan only if `myTeamID` or spec state changed |
| B8 | 1959, 3004-3005 | Division by `MperBP`, and `unitCostData[builtUnitDefID]` not nil-guarded. The engine clamps metalCost and buildTime to ≥1 (verify), so this is safe today but fragile | Guard and skip |
| B9 | 2029-2030 | `calculateAverages` and `updateResbar('BP')` run on every processed frame. Averages get duplicate samples and window length depends on unit count. `updateResbar` recreates 3 display lists, re-registers the guishader dlist, rebuilds tooltip strings and loops over all builders for debug, about 20 times per second | Average once per pass. Redraw only when the pixel values change |
| B10 | 1813-1814, 1804 | Non-builder expense uses the previous call's per-BP value | `X - usedBPMetalExpense` |
| B11 | 1853-1857 | Wind strip ignores non-builder E expense, uses zero wind instead of windMin and uncapped windMax, so the E marker can lie outside the strip. Wind strength is taken from one arbitrary generator, wrong if that one is paralysed | Use the same model as `eRatio`; wind from `GetWind()` with the cap from the UnitDef |
| B12 | 2335-2336 | Stall highlight drawn with an undefined current color (the tint was commented out in preBEHE) | Set the color explicitly |
| B13 | 1074-1077 | BP glow positioned from the pre-override barArea; glow alpha is constant | Compute glow from the BP barArea, or drop it |
| B14 | 3130-3133 | Wind gens are not guarded against double-tracking; only armwin/corwin are detected | `if not trackedWinds[id]`; detect by `unitDef.windGenerator > 0` |
| B15 | 3105-3106 | `GetUnitHealth` returning nil makes `build >= 1` raise an error | Guard |
| B16 | 908-910 | `BP[3]/BP[4]` with total 0 gives NaN or inf (harmless only by luck); computed for metal and energy too | Guard `total > 0` |
| B17 | 1491-1492 | `dlistResValuesBar.BP` keyed by `valueWidth*10000 + additionalWidth` grows without bound, up to barWidth² lists, until `ViewResize` | Draw fills directly or cache by a small key |
| B18 | 1432-1560 | Effect display list recreated about every frame | Draw directly |
| B19 | 3019-3091 | `shutdown` removes neither guishader `topbar_BP` nor tooltips `BP_all` / `BP_Current`, and leaves the BP effect list in `displayListCache` | Clean up |
| B20 | 1391 | `bpTooltipTitle` is an undefined global, so the tooltip has no title | Define it |
| B21 | 1350-1356 | Debug loop reads `v[1]`/`v[2]` from named-field records and writes globals `currentUnitBP`, `unitIsBuilt`; `nBuiltBuilders` is always 0 | Fix or remove |
| B22 | 2077 | `res` is an undefined global in `updateAllyTeamOverflowing` | Remove the condition |
| B23 | 1133 | Texture option string `":lr"..n..", "..n` contains a space; path `LuaUI/images` is lower case | Verify, then normalise |
| B24 | 2229-2252 | BP area missing from `hoveringElement` | Add it |
| B25 | 1574-1575 | "Orange" color is light red | Use a real orange |
| B26 | 1955-1957 | `GetUnitResources` returns the builder's whole use, including cloak, shield or other upkeep, which inflates per-BP E | Accept, or subtract `UnitDef` upkeep |
| B27 | 2.2 | Repairing a damaged finished unit: `GetUnitIsBuilding` probably returns the repair target (verify). That adds `S` to `buildingBP` with 0 metal, so it counts as fully stalled | Treat a target that is not being built (`GetUnitIsBeingBuilt` false) as "reserved, not building" |
| B28 | all | `Spring.I18N` is used for stock strings; BP strings are hardcoded English | `BAR.I18N` guarded, or plain strings |
| B29 | 1880 / 2080 | When nothing is building for 30 samples, the marker positions become nil, which hides the markers and disables the stall flags. Intended, but the "projection" silently disappears in a full stall where nothing is being built | Show the last value greyed out |

---

## 11. Proposed public data interface for the new implementation

One table, `bp`, owned by the data widget (suggested `api_buildpower.lua`) and published read-only as `WG.buildpower = { GetData = function() return bp end, version = 1 }`. No drawing in that widget. The UI widget only reads `bp`.

Update cadence:
* **E**: event (`UnitFinished`, `UnitGiven`, `UnitTaken`, `UnitDestroyed`, team change).
* **P**: once per completed pass (`finishPass()`), with pass length about 3 to 6 frames.
* **S**: once per second (`updateFlags()`).

| Field | Type | Meaning (formula, section) | Updated by | When |
|---|---|---|---|---|
| `teamID` | int | team being measured (own, or watched as spectator) | `rescan()` | E |
| `total` | number | sum of `buildSpeed` of finished builders, nanos and factories (1.1) | `trackUnit` / `untrackUnit` / `rescan` | E |
| `numBuilders`, `numNanos`, `numFactories` | int | counts by type | same | E |
| `numWindGenerators` | int | count of finished generators with `windGenerator > 0` | same | E |
| `reservedInstant` | number | sum of `S` of builders with orders, excluding nanos with only `CMD.FIGHT` and idle guard chains (2.2, 9 #13) | `processBatch` → `finishPass` | P |
| `usedInstant` | number | sum of `metalUse/MperBP(target)` (2.2) | same | P |
| `buildingInstant` | number | sum of `S` with a build target ("if no stall") | same | P |
| `stalledInstant` | number | `buildingInstant - Σ S·min(mUse/wantedM, eUse/wantedE)` | same | P |
| `builderMetalExpense`, `builderEnergyExpense` | number | sum of `GetUnitResources` use of building builders | same | P |
| `reserved` | number | `WA(reservedInstant)`, window about 2 s | `updateAverages` | P |
| `used` | number | `WA(usedInstant)` | `updateAverages` | P |
| `idle` | number | `max(0, total - reserved)` | `updateAverages` | P |
| `usedRatio` | 0..1 | `min(1, used/total)`, 0 if total = 0 (the shown %) | `updateAverages` | P |
| `reservedRatio` | 0..1 | `min(1, reserved/total)` | `updateAverages` | P |
| `metalPerBP`, `energyPerBP` | number or nil | `builderXExpense / usedInstant` when `usedInstant ≥ 1`, else last value. Option: from wanted demand (9 #19) | `updateAverages` | P |
| `nonBuilderMetalExpense`, `nonBuilderEnergyExpense` | number | `WA(teamExpense - builderExpense)` | `updateAverages` | P |
| `metalExpenseIfAllUsed`, `energyExpenseIfAllUsed` | number | `nonBuilderX + XPerBP*total` | `updateAverages` | P |
| `mSupportRatio`, `eSupportRatio` | 0..1 or nil | model B: `WA(clamp01(income / XExpenseIfAllUsed), weight = usedInstant)` (section 4) | `updateAverages` | P |
| `metalSupportedBP`, `energySupportedBP` | number or nil | model A: `(income - nonBuilderX) / XPerBP` | `updateAverages` | P |
| `surplusBP` | number or nil | `total - min(metalSupportedBP, energySupportedBP)`, rounded up to 10 (preBEHE) | `updateAverages` | P |
| `eSupportMinWind`, `eSupportMaxWind` | 0..1 or nil | same model as `eSupportRatio`, with wind income replaced by `nW·windMin` and `nW·min(windMax, cap)`. Smoothed with the same WA, not a separate 0.1 factor | `updateAverages` | P |
| `windStrength` | number | `select(4, Spring.GetWind())` clamped to the generator cap | `updateAverages` | P |
| `currentSupplyMetal`, `currentSupplyEnergy` | 0..1 | `min(1, income/pull)`, the engine-truth supply right now (supBP idea) | `updateFlags` | S |
| `stallingMetal`, `stallingEnergy` | bool | `mSupportRatio < 0.8 and storage < 2·pull` (same for E) (5.1) | `updateFlags` | S |
| `idleAlert` | bool | `total > 0 and reserved/total ≤ 0.5 and total - reserved > 300` (5.2) | `updateFlags` | S |
| `needBuildpower`, `tooMuchBuildpower` | bool | `surplusBP < 0`; `surplusBP > 400 and (mSupportRatio < 0.4 or eSupportRatio < 0.4)` (9 #5) | `updateFlags` | S |
| `lastPassFrame` | int | game frame of the last finished pass | `finishPass` | P |
| `hasData` | bool | at least one pass done and `total > 0` | `finishPass` | P |

Implementation notes for the data widget:
* Use a snapshot array of builder IDs per pass instead of a coroutine over `pairs`. Process `min(20, ceil(n/3))` per frame, and call `finishPass()` exactly once at the end.
* Keep the per-frame budget (20 units, 3-frame pause). Stock reviewers care about it.
* Run averages once per pass, with a time-based window of about 2 s. Do not resample on every frame.
* Do not read any `lowPrio*` team rules params.
* Use `CMD.FIGHT`. Classify nanos by UnitDef fields. Detect wind generators by `windGenerator`.
* Re-scan when `GetMyTeamID()` changes, not on every `PlayerChanged`.
* The UI widget (see `TOP_BAR_REVIVAL_NOTES.md`, option B) draws, from `bp`:
  * used fill, reserved fill, red idle background;
  * the grey and yellow markers (×1.4 while stalling);
  * the wind strip;
  * the percent text with the 40/60/80 thresholds;
  * alerts `Need metal`, `Need energy`, `Idle buildpower`, and optionally `Need buildpower` / `Too much buildpower`;
  * the tooltips from section 7.
* The UI widget redraws only when a rounded pixel value or a flag changes.
