# Top Bar Widget for BAR

Enhance your gaming experience with the new top bar widget for BAR (Beyond All Reason)! This widget offers a streamlined and informative interface, providing critical insights during gameplay.

## Features
- **Efficiency Indicator**: Easily understand your build power resource utilization with a color-coded system.
- **Time You Are Behind Calculation**: Instantly know how efficiently you're using your build power (BP).

## Versions
`gui_top_bar_alpha.lua` is the one that is described here, it is stable :)

## Installation Guide

### Step 1: Download the Widget
First, download the `gui_top_bar_supplyable_BP.lua` file from our [GitHub repository](https://github.com/roberthartmann/widgets_for_BAR/blob/main/gui_top_bar_alpha.lua).

### Step 2: Place the Widget File
Place the downloaded file into your widgets folder. The path should be `your_bar_folder/data/luaui/widgets`.

### Step 3: Activate the Widget
Start a game, then press `F11` to access the widget menu. Filter for the top bar, deactivate the original top bar, and activate the new one.

### Step 4: Adjust Other Widgets
After activating the new top bar, reactivate any widgets that are positioned beside the top bar. They need to be readjusted to fit alongside the new top bar.

### Step 5: Understanding the Widget
To fully benefit from the widget, it's crucial to understand its functionalities. Refer to the pictures and descriptions in our repository to get a comprehensive understanding.

Here is a picture for you to better understand how to read it.
![widget_explain](https://raw.githubusercontent.com/roberthartmann/widgets_for_BAR/main/readme_pics/widget_explain.png)

## Understanding "Time You Are Behind"
The widget calculates how much you're lagging in utilizing your build power (BP) effectively:

- **Calculation Logic**: It divides the total metal cost of unused build power by your current metal production.
- **Color Coding**: Green indicates good efficiency, while red indicates poor efficiency. Shades in between represent moderate levels of efficiency.
- **Detail Calculation**: It considers the type and metal cost of idle constructors to show how many seconds of metal income are wasted in unproductive build power. A simple example: A T2 factory (3k metal) and 5 con turrets (1k metal) are idling. Your income is 20metal/sec -> if you would reclaim all this your AFUS could be finished 200 seconds earlier.
- 
## Understanding the sliders

### Understanding the metal sliders
The sliders is the place where your eyes will go to a lot after a while.
They show you if you need more build power or you have to much. 
- **My personal goal is to have the metal slider about 70% and 90% on the right.** This means that your metal income can supply almost all your build power on the current projects. Why do you want it in that range?
- **Why do you want to try to have the metal slider at no more than 90%?** Because if you have less build power (the slider would be further at the right) you could not spend all of your metal. Units leaving a factory and cons walking towards the blue print are causing inefficiencies, so you need enough build power to spend all of your metal. 
- **Why do you want to try to have the metal slider at no less than 70%?** Because you are wasting your metal. That is what the "time you are behind" is pointing out aswell. In the heat of the battle it is quite common to just look at one of the indicators.

### Understanding the energy sliders
- **My personal goal is to have the energy slider about double of the metal slider or at 100%**
- **Energy is nothing you want to be short of!!!** High level players will begin their raids during low wind phases. So be aware that you need a healthy amount of energy income.
- **Energy is nothing you want to be short of!!! It is BAD!!!!** Even if you don't get raided. A rarely known fact ist: metal extractors will eventually produce no more metal. And that really hurts!
- **Energy is needed for resurrecting units. That can easily underestimated** Rez bots are cheap, they are cool. They suck the live out of your eco! The energy slider will you that. Be aware of that fact!

### A quick example
Here you can see that you are sucking your E-storage at an "not good" rate. You will stall on energy soon. Then your metal extractors might even produce less metal. After a while the metal storage will be empty, too. That is better normaly. The solution? Take your commander, build wind/solar. That will reduce your need for energy and it will raise your e-income. A win win situation :)
![sliders_01](https://raw.githubusercontent.com/roberthartmann/widgets_for_BAR/main/readme_pics/sliders_01.png)

## Feedback and Contributions
Your feedback and contributions are welcome! Feel free to raise issues or submit pull requests on our [GitHub repository](https://github.com/roberthartmann/widgets_for_BAR).
