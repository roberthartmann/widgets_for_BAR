# Top Bar Widget for BAR

Enhance your gaming experience with the new top bar widget for BAR (Beyond All Reason)! This widget offers a streamlined and informative interface, providing critical insights during gameplay.

## Features
- **Efficiency Indicator**: Easily understand your build power resource utilization with a color-coded system.
- **Time You Are Behind Calculation**: Instantly know how efficiently you're using your build power (BP).

## Versions
`gui_top_bar_supplyable_BP.lua` is the one that is described here, it is stable :)

gui_top_bar_sup_BP_clean.lua
gets rid of most numbers

gui_top_bar_alpha.lua
is a test version. Its appearance will be changed frequently and drasically.
If you are interested in this version follow the discussion in discord. 

gui_top_bar_2.0.lua
Is an old version. It can get unstable after many hours of huge games.


## Installation Guide

### Step 1: Download the Widget
First, download the `gui_top_bar_supplyable_BP.lua` file from our [GitHub repository](https://github.com/roberthartmann/widgets_for_BAR/blob/main/gui_top_bar_supplyable_BP.lua).

### Step 2: Place the Widget File
Place the downloaded file into your widgets folder. The path should be `your_bar_folder/data/luaui/widgets`.

### Step 3: Download the Required Image
Download the necessary image, `BP.png` and `triangle.png`, from [here](https://github.com/roberthartmann/widgets_for_BAR/blob/main/BP.png) and [here](https://github.com/roberthartmann/widgets_for_BAR/blob/main/triangle.png) and store it in the `Widgets/topbar` folder.

### Step 4: Activate the Widget
Start a game, then press `F11` to access the widget menu. Filter for the top bar, deactivate the original top bar, and activate the new one.

### Step 5: Adjust Other Widgets
After activating the new top bar, reactivate any widgets that are positioned beside the top bar. They need to be readjusted to fit alongside the new top bar.

### Step 6: Understanding the Widget
To fully benefit from the widget, it's crucial to understand its functionalities. Refer to the pictures and descriptions in our repository to get a comprehensive understanding.

Here is a picture for you to better understand how to read it.
![widget_explain](https://raw.githubusercontent.com/roberthartmann/widgets_for_BAR/main/readme_pics/widget_explain.png)

## Understanding "Time You Are Behind"
The widget calculates how much you're lagging in utilizing your build power (BP) effectively:

- **Calculation Logic**: It divides the total metal cost of unused build power by your current metal production.
- **Color Coding**: Green indicates good efficiency, while red indicates poor efficiency. Shades in between represent moderate levels of efficiency.
- **Detail Calculation**: It considers the type and metal cost of idle constructors to show how many seconds of metal income are unproductive.

## Feedback and Contributions
Your feedback and contributions are welcome! Feel free to raise issues or submit pull requests on our [GitHub repository](https://github.com/roberthartmann/widgets_for_BAR).
