# Top Bar Widget for BAR

Enhance your gaming experience with the new Top Bar Widget for BAR (Beyond All Reason)! This widget offers a streamlined and informative interface, providing critical insights during gameplay.

## Features
- **Efficiency Indicator**: Easily monitor your build power resource utilization with a color-coded system.
- **Time Behind Calculation**: Instantly understand how efficiently you're using your build power (BP).

## Versions
The `gui_top_bar_alpha.lua` version is the one described here. It is stable :)

## Installation Guide

### Step 1: Download the Widget
First, download the `gui_top_bar_alpha.lua` file from our [GitHub repository](https://github.com/roberthartmann/widgets_for_BAR/blob/main/gui_top_bar_alpha.lua).

### Step 2: Place the Widget File
Place the downloaded file into your widgets folder. The path should be `your_bar_folder/data/luaui/widgets`.

### Step 3: Activate the Widget
Start a game, then press `F11` to access the widget menu. Filter for the top bar, deactivate the original top bar, and activate the new one.

### Step 4: Adjust Other Widgets
After activating the new top bar, reactivate any widgets that are positioned beside it. They may need to be readjusted to fit alongside the new top bar.

### Step 5: Understanding the Widget
To fully benefit from the widget, it's crucial to understand its functionalities. Refer to the images and descriptions in our repository to get a comprehensive overview.

Here is an image to help you better understand how to read it:
![widget_explain](https://raw.githubusercontent.com/roberthartmann/widgets_for_BAR/main/readme_pics/simplified_BP_bar.png)

## Understanding the Sliders

### Metal Slider
The slider are a focal point where your eyes will often go.
It shows whether you need more build power or have too much.
- **Aim to keep the metal slider between 70% and 90% on the right.** This indicates that your metal income can supply almost all of your build power on current projects. Why aim for this range?
- **Avoid exceeding 90% on the metal slider.** If you have less build power (slider further to the right), you won’t spend all of your metal. Units leaving a factory and constructors moving toward blueprints can cause inefficiencies, so you need sufficient build power to spend all your metal.
- **Avoid dropping below 70% on the metal slider.** If you're below this threshold, you're wasting metal in unused BP. In the heat of battle, it’s common to rely on these indicators.

### Energy Slider
- **Aim to keep the energy slider at around double the metal slider or at 100%.**
- **Never run short on energy!** High-level players will often begin raids during low wind phases, when your LLTs won't shoot, so maintaining a healthy energy income is crucial.
- **Running out of energy is BAD!!!** Even if you're not raided, a lesser-known fact is that metal extractors will eventually stop producing metal if you run out of energy, which can be devastating.
- **Energy is vital for resurrecting units, which can easily be underestimated.** Rez bots are cheap and effective but can drain your economy. The energy slider will show you this. Be mindful of your energy needs!

### A Quick Example
(older version) In this example, you can see that you're depleting your energy storage at an unhealthy rate. You will soon stall on energy, which might cause your metal extractors to produce less metal. Eventually, your metal storage will also be empty, which is generally undesirable. The solution? Use your commander to build wind or solar energy structures. This will reduce your energy consumption and increase your energy income—a win-win situation! 
![sliders_01](https://raw.githubusercontent.com/roberthartmann/widgets_for_BAR/main/readme_pics/sliders_01.png)

## Nano Stall Indicator (TA-style stall display)

In Total Annihilation you could *see* a stall: a builder's nanolathe beam was only drawn in the frames in which the builder actually got resources. At a 90% stall the beam was on 10% of the time. That on-time **is** the ratio of served to demanded buildpower, and it was readable per builder just by looking at it.

For BAR this was considered "not possible". It is, because the Recoil engine still works exactly like TA at the simulation level and already measures the on-time per builder:

- `CBuilder::UpdateBuild` calls `AddBuildPower()` every frame; it returns `false` when the team cannot pay that frame's resource step (`CTeam::HaveResources`). `CreateNanoParticle()` is only called on success (`rts/Sim/Units/UnitTypes/Builder.cpp`, `rts/Sim/Units/Unit.cpp`). Factories do the same (`Factory.cpp`).
- Every successful frame sets a bit in a 15 bit mask that is shifted once per frame (`rts/Sim/Misc/NanoPieceCache.h`). `GetBuildPower()` is `popcount(mask) / 15`: the share of the last half second in which the beam was "on".
- `Spring.GetUnitCurrentBuildPower(unitID)` returns that number to Lua for builders, nano turrets and factories. The engine's own nano particle emitter and BAR's `gfx_nano_particles_gl4` gadget already scale the spray density with it, so the information is technically in the picture today, just too subtle to read.

A widget therefore only has to read that value for every own builder with a construction job, weight it by `buildSpeed` and display it. No income/pull estimate is needed.

### Files

| File | Purpose |
| --- | --- |
| `gui_nano_stall_poc.lua` | Proof of concept. Plain `gl.Text` output under the top bar: buildpower weighted duty cycle (instant, 1 s average, unweighted mean), number of working builders, demanded/served buildpower and a resource based estimate (`income / pull`) for cross-checking. A percentage above every working builder. `/nanostall_poc_echo` logs the same numbers to the console every 2 s, `/nanostall_poc_labels` toggles the unit labels. Disabled by default. |
| `gui_nano_stall.lua` | The widget in BAR style. A small `nano` element in the free area of the top bar (FlowUI element, BAR fonts, guishader blur, tooltip) with the percentage and a bar coloured green (served) to red (starved). Labels in BuildETA style above builders that get less than 90% of their buildpower, fading with camera distance. `/nanostall_element` and `/nanostall_labels` toggle the two parts; settings are saved. Works with the stock top bar and with "Top Bar with Buildpower" (both expose `WG.topbar.GetFreeArea`). |

### Installation

Copy the file(s) into `your_bar_folder/data/luaui/widgets`, press `F11` in game and enable "Nano Stall Indicator" (and/or "Nano Stall PoC").

### What is counted

- Only construction tasks (building, assisting, factory production) go into the ratio. Reclaim, repair, capture and terraform do not pay per frame and cannot stall, so they are ignored.
- Builders with a `wait` order and stunned builders are ignored as well; they do not ask for resources.
- Spectators need full view (the engine only answers for allied units).
- The engine value is a half second window; the widget averages one more second for a calm display.

### Checking it in game

Build a factory and a few nano turrets, queue expensive units until metal hits zero and compare: the element should show roughly `metal income / metal pull` from the top bar, and `/nanostall_poc_echo` prints both numbers side by side. They will not match exactly: shared/received resources, overflow and the half second window all shift the estimate, while the duty cycle is the ground truth of what the builders really got.

One thing the per-unit labels show that no team-wide number can: the engine serves builders in unit update order, so during a stall some builders can be fed almost fully while others starve. That is the same thing TA players saw when one beam flickered and another did not.

### Possible next steps

- Show the measured duty cycle inside "Top Bar with Buildpower" next to the estimated buildpower bar (measured vs. predicted).
- If an exact per-frame beam state is ever needed: sampling `GetUnitCurrentBuildPower` every frame gives the popcount delta, from which the newest bit can be reconstructed once the mask has been fully 0 or fully 1 once.

## Feedback and Contributions
Your feedback and contributions are welcome! Feel free to raise issues or submit pull requests on our [GitHub repository](https://github.com/roberthartmann/widgets_for_BAR).
