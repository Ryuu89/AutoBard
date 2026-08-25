# AutoBard

Precision Bard automation for Matcha LuaVM.

## Quick start

Run the following loader in Matcha:

    loadstring(game:HttpGet("https://raw.githubusercontent.com/Ryuu89/AutoBard/main/AutoBard.lua"))()

## Features

- Accurate OuterRing tracking with configurable click timing.
- One-note display-scale calibration for fullscreen and windowed playback.
- Configurable autoplay and Resolve hotkeys.
- Camera-safe input handling while holding right click or using Shift Lock.
- Live accuracy, error, completion, and click-timing statistics.

## Controls

- Toggle autoplay: X by default.
- Trigger Resolve: R by default.
- Both shortcuts can be changed in the AutoBard tab.
- Click Calibrate Display Scale, start a song, and click the center of the first Bard note.
- The detected display scale is saved automatically; autoplay resumes after calibration.

## Requirements

- Matcha LuaVM.
- The Bard interface must be available in the current Roblox experience.

Made by Ryuu89
