# AutoBard

Precision Bard automation for Matcha LuaVM.

## Quick start

Run the following loader in Matcha:

    loadstring(game:HttpGet("https://raw.githubusercontent.com/Ryuu89/AutoBard/main/AutoBard.lua"))()

## Features

- Accurate OuterRing tracking with configurable click timing.
- Two-note display calibration for fullscreen, small windows, and window offsets.
- Configurable autoplay and Resolve hotkeys.
- Camera-safe input handling while holding right click or using Shift Lock.
- Live accuracy, error, completion, and click-timing statistics.

## Controls

- Toggle autoplay: X by default.
- Trigger Resolve: R by default.
- Both shortcuts can be changed in the AutoBard tab.
- Click Detect Display Scale, start a song, and click the first note, then a different note.
- Display scale and window alignment are saved automatically; autoplay resumes after calibration.

## Requirements

- Matcha LuaVM.
- The Bard interface must be available in the current Roblox experience.

Made by Ryuu89
