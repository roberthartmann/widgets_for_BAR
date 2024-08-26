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
In this example, you can see that you're depleting your energy storage at an unhealthy rate. You will soon stall on energy, which might cause your metal extractors to produce less metal. Eventually, your metal storage will also be empty, which is generally undesirable. The solution? Use your commander to build wind or solar energy structures. This will reduce your energy consumption and increase your energy income—a win-win situation!
![sliders_01](https://raw.githubusercontent.com/roberthartmann/widgets_for_BAR/main/readme_pics/sliders_01.png)

## Feedback and Contributions
Your feedback and contributions are welcome! Feel free to raise issues or submit pull requests on our [GitHub repository](https://github.com/roberthartmann/widgets_for_BAR).
