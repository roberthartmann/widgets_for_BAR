# Top Bar Widget for BAR

Enhance your gaming experience with the new Top Bar Widget for BAR (Beyond All Reason)! This widget offers a streamlined and informative interface, providing critical insights during gameplay.

## Features
- **Efficiency Indicator**: Easily monitor your build power resource utilization with a color-coded system.
- **Time Behind Calculation**: Instantly understand how efficiently you're using your build power (BP).

## Versions
- **`gui_top_bar_buildpower.lua`** is the current version (Oct 2026). It is the stock BAR top bar
  (new skewed design, render-to-texture) plus the buildpower bar. Use this one.
- `gui_top_bar_alpha_0.4.010.lua` and everything in `old_versions/` and `WIP/` are the previous forks
  (2023 to 2024) of a much older stock top bar. They are kept for reference only and no longer match the game.
- `stock_reference/` holds the unmodified stock files the current version was forked from, `design/`
  the specification and integration design, `tools/` a headless syntax check and lifecycle test.

## Installation Guide

### Step 1: Download the Widget
Download `gui_top_bar_buildpower.lua` from this repository.

### Step 2: Place the Widget File
Place the file into your widgets folder: `your_bar_folder/data/LuaUI/Widgets`.

### Step 3: Activate the Widget
Start a game, press `F11` to open the widget list, filter for "top bar", **disable "Top Bar"** (the stock one)
and **enable "Top Bar with Buildpower"**. Keep "Top Bar Buttons" enabled; it works with both.
Both bars use the same spot, so if you see two bars on top of each other the stock one is still on.

### Step 4: Settings
The options are in the settings menu under *Custom* > *Top Bar with Buildpower*: buildpower bar on/off,
its width, the eco support indicators, the wind range indicator, the alerts, the icon and a debug tooltip.

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

## Feedback and Contributions
Your feedback and contributions are welcome! Feel free to raise issues or submit pull requests on our [GitHub repository](https://github.com/roberthartmann/widgets_for_BAR).
