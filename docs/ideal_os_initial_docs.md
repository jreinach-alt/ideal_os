# Ideal OS – Initial Project Documents

This document consolidates the **initial design artifacts** for the Ideal OS project so they can be handed off to an implementation agent (Claude Code) and stored in the repository.

---

# 1. Project Charter

## Mission

Ideal OS is a curated appliance‑style operating system for the TrimUI Brick designed to deliver the **ideal retro handheld experience**.

Users should be able to:

Flash the device\
Copy ROMs\
Play games

with no emulator configuration required.

---

## Design Philosophy

Ideal OS follows the **Curated Appliance Model**.

Key ideas:

• Defaults are chosen for the user\
• Configuration is minimized\
• Gameplay resumes instantly\
• Every system behaves consistently

The device should feel like a **console**, not a Linux project.

---

## Design Principles

### Appliance First

The system behaves like a finished consumer product.

Requirements:

• fast boot • instant resume • minimal menus

---

### Curated Defaults

Ideal OS ships with pre‑selected emulator cores and settings.

Users should not need to:

• choose emulator cores • adjust shaders • tune performance

---

### Consistent Controls

All emulators use the same hotkeys.

Example scheme:

Menu + R1 → Save state Menu + L1 → Load state Menu + Start → Exit game Menu + Left/Right → Volume Menu + Up/Down → Brightness

---

### Resume‑Centric Gameplay

Players can suspend games and return instantly.

Multiple suspended games are supported.

---

## Versioning

Ideal OS uses a **Stardate versioning scheme**.

Format:

Stardate YYMM.R

Example:

Stardate 2601.1

---

## Mission Statement

To explore strange old games\
To seek out forgotten cartridges and new homebrew\
To boldly emulate what no handheld has emulated before

---

# 2. Feature Specification

## Core Experience

Required features:

• Fast boot • Suspend / resume • Resume last played game • Multi‑game resume stack • Game switcher UI

---

## Library Management

• ROM scanning • Boxart support • Metadata support • Favorites • Recently played • Collections • Optional search

---

## Emulator Integration

Curated emulator cores.

Example defaults:

SNES → snes9x2005\_plus\
Genesis → genesis\_plus\_gx\
GBA → mgba\
PS1 → pcsx\_rearmed

---

## Power Management

• Deep sleep • Auto‑save on suspend • Auto‑save on shutdown

---

## Port Support

PortMaster runtime support.

Optional port browser UI.

---

## Optional Future Features

• OTA updates • RetroAchievements • Netplay • Theme engine

---

# 3. Architecture Overview

Ideal OS is built on top of **NextUI** as the hardware compatibility layer.

Architecture layers:

Hardware Layer\
NextUI Base System\
Ideal OS Core Modules\
Launcher UI

---

## Core Modules

### Session Manager

Handles suspend / resume and multi‑game state.

---

### Library Manager

Maintains game database including:

• favorites • collections • recently played

---

### Launcher

Main UI responsible for:

• browsing library • launching games • switching sessions

---

### Emulator Layer

Launches emulators using curated configs.

---

## Boot Flow

Power On\
TrimUI Logo\
Ideal OS Boot Animation\
Launcher UI\
Resume Last Game or Show Library

---

# 4. Session Manager Specification

The Session Manager enables resume‑centric gameplay.

---

## Responsibilities

• Save emulator state • Restore emulator state • Track suspended games

---

## Session Lifecycle

Launch Game\
Game Running\
Suspend Event\
Save State\
Store Session\
Resume Later

---

## Resume Stack

Example stack:

1. Metroid
2. Mario
3. Zelda

Switching restores the correct state.

---

## Session Storage

Example structure:

sessions/

game\_id/

```
state.sav

metadata.json
```

Metadata includes:

• Game identifier • Emulator core • Save state file • Timestamp

---

## Suspend Events

Suspend triggers:

• power button • launcher switch • manual suspend

---

# 5. Development Roadmap

## Phase 1 – Foundation

• Fork NextUI • Build dev environment • Analyze hardware integration

---

## Phase 2 – Core Features

• Curated emulator defaults • Library manager • Favorites • Recent games

---

## Phase 3 – Session System

• Suspend / resume • Session persistence • Resume stack

---

## Phase 4 – Game Switcher

UI for switching between sessions.

---

## Phase 5 – Polish

• Boot animation • UI refinement • Stability testing

---

## Phase 6 – Public Release

Ideal OS

Stardate 2601.1

---

# 6. Feature Matrix (NextUI vs Ideal OS)

Legend:

✓ Implemented\
\~ Partial\
✗ Missing

---

## Core Experience

Fast Boot NextUI ✓ Ideal OS ✓

Sleep Mode NextUI ✓ Ideal OS ✓

Suspend Current Game NextUI \~ Ideal OS ✓

Resume Last Game NextUI \~ Ideal OS ✓

Multi‑Game Resume Stack NextUI ✗ Ideal OS ✓

Game Switcher NextUI \~ Ideal OS ✓

Auto Save on Sleep NextUI ✗ Ideal OS ✓

---

## Library Management

ROM Scanning NextUI ✓

Boxart NextUI ✓

Metadata NextUI \~

Favorites NextUI \~

Recent Games NextUI \~

Collections NextUI ✗

Search NextUI ✗

---

## Emulator Layer

Curated Core Defaults NextUI \~

Shader Defaults NextUI \~

Unified Controls NextUI \~

System Tuning NextUI \~

---

## Power & Session

Deep Sleep NextUI ✓

Session Persistence NextUI ✗

Resume Stack NextUI ✗

Quick Resume Menu NextUI ✗

---

## System Features

Brightness Control NextUI ✓

Volume Control NextUI ✓

File Manager NextUI \~

WiFi Transfer NextUI \~

OTA Updates NextUI ✗

---

## Developer Tools

Performance Overlay NextUI ✗

System Profiles NextUI ✗

---

# Conclusion

NextUI already solves:

• hardware compatibility • drivers • power management • emulator launching

Ideal OS focuses on adding:

• session manager • resume stack • library improvements • curated defaults

These features create the **appliance experience** that defines Ideal OS.

