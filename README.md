# AutoBard

Precision Bard automation for Matcha LuaVM.

## Quick start

Run the following loader in Matcha:

    loadstring(game:HttpGet("https://raw.githubusercontent.com/Ryuu89/AutoBard/main/AutoBard.lua"))()

## Features

- Accurate OuterRing tracking with configurable click timing.
- Verified display-scale detection with persistent, percentage-based cursor alignment.
- Configurable autoplay and Resolve hotkeys.
- Camera-safe input handling while holding right click or using Shift Lock.
- Live accuracy, error, completion, and click-timing statistics.

## Controls

- Toggle autoplay: X by default.
- Trigger Resolve: R by default.
- Both shortcuts can be changed in the AutoBard tab.
- Match Display Scale (%) to Windows Settings > System > Display > Scale; it is saved automatically.
- Detect Display Scale never overwrites a working value without reliable display data.

## Requirements

- Matcha LuaVM.
- The Bard interface must be available in the current Roblox experience.

Made by Ryuu89
