# Ideal OS – Base Platform Fork and Harvest Plan

## Purpose

This document defines how the Ideal OS project will establish its initial codebase by **forking an existing platform** and selectively harvesting useful components from related projects.

The goal is to:

- avoid rebuilding hardware integration from scratch
- prevent importing outdated or incompatible components
- maintain architectural consistency with the Ideal OS design documents

This plan ensures the initial repository is built intentionally rather than accumulating legacy decisions.

---

# Base Platform Decision

## Selected Base

**NextUI** will be used as the initial platform base for Ideal OS.

Reasons:

- actively maintained
- confirmed compatibility with TrimUI Brick
- includes working device drivers and firmware integration
- supports existing package/update mechanisms
- designed to be modular enough for customization

Using NextUI allows Ideal OS to start with a **stable hardware platform layer** rather than reinventing low-level device integration.

---

# Non‑Base Reference Projects

## CrossMix OS

CrossMix is treated as a **feature reference and component donor**, not the primary base.

Useful areas to review:

- curated emulator configurations
- compatibility scripts
- launcher UX patterns
- file layout conventions

Risks:

- stale driver integration
- historical assumptions about older TrimUI firmware
- code paths designed for different hardware targets

All CrossMix components must be evaluated before import.

---

## MinUI

MinUI is treated as a **design philosophy reference**, not a code dependency.

Reasons:

- repository archived
- not actively maintained
- incompatible with several modern firmware expectations

MinUI remains useful as inspiration for:

- appliance-style design
- minimal UX philosophy
- curated defaults

But no direct code import should occur.

---

# Architectural Layering

Ideal OS will maintain a clear separation between inherited platform layers and Ideal OS logic.

```
Hardware Layer

NextUI Platform Layer

Ideal OS Core Services

Ideal OS Launcher / UX
```

This layering prevents Ideal OS features from being tightly coupled to the underlying firmware.

---

# Platform Components to Inherit

These systems should initially be taken directly from NextUI with minimal modification.

## Hardware Support

- device boot integration
- hardware drivers
- input handling
- power management
- WiFi stack

These components are device‑specific and should remain stable.

---

## Emulator Runtime Integration

NextUI already contains working emulator launch infrastructure.

Initial inheritance should include:

- emulator launch scripts
- system folder mapping
- core loading logic

Ideal OS will later overlay **curated defaults** rather than replacing the runtime entirely.

---

## Storage Layout

NextUI directory structures for ROMs, saves, and system data should be used as the initial baseline.

Ideal OS will extend this layout with additional runtime directories.

---

## Network Stack

WiFi configuration and connectivity management should remain inherited from NextUI.

Ideal OS background services will depend on this subsystem.

---

# Components to Audit Before Adoption

The following systems must be carefully evaluated before Ideal OS adopts them.

## Update Mechanism

NextUI contains an update system, but Ideal OS defines its own OTA architecture.

Required actions:

- inspect current updater implementation
- determine compatibility with Ideal OS manifest model
- identify reusable components (download logic, package handling)

If incompatible, the updater will be replaced while preserving useful utilities.

---

## Launcher Implementation

NextUI’s launcher must be reviewed to determine whether it should be:

- extended
- replaced
- partially reused

Ideal OS introduces several features not present in standard launchers:

- resume stack
- session manager
- game switcher
- background services awareness

The launcher may ultimately become a new component.

---

## Package / PAK System

NextUI may include package conventions for apps and updates.

These must be audited to determine:

- compatibility with Ideal OS OTA design
- packaging structure
- update distribution compatibility

---

# Components to Harvest from CrossMix

Only selected components should be imported.

## Emulator Configuration

CrossMix may contain tuned configuration files for certain systems.

Potential harvest targets:

- RetroArch core settings
- emulator compatibility tweaks
- controller mappings

These must be validated against modern cores.

---

## Script Utilities

CrossMix scripts may include useful tooling for:

- system configuration
- emulator launching
- compatibility fixes

Each script should be evaluated for relevance and maintenance cost.

---

## UX Concepts

CrossMix launcher UX patterns may inform Ideal OS design decisions.

However, Ideal OS will implement its own launcher to support session‑centric gameplay.

---

# Components to Replace

Certain areas should be implemented from scratch to match the Ideal OS architecture.

## Session Manager

Entirely new subsystem.

Responsible for:

- suspend/resume
- resume stack
- session persistence

---

## Cloud Sync Engine

Entirely new subsystem.

Responsible for:

- artifact tracking
- background uploads
- cross‑device continuity

---

## Notification & Guardian Alert System

Entirely new subsystem.

Responsible for:

- notification policy engine
- escalation logic
- guardian alerts

---

## Background Task Scheduler

Entirely new subsystem.

Coordinates background services across the OS.

---

## Ideal OS Launcher

Launcher must integrate deeply with session manager and background services.

It may reuse selected UI components but should not inherit architectural limitations.

---

# Verification Checklist Before Fork

Before creating the Ideal OS fork, the following should be confirmed.

## Verify Active Upstream

Confirm the current NextUI repository state:

- latest release
- current development branch
- hardware compatibility claims

---

## Confirm Brick Compatibility

Ensure the NextUI version used is verified for TrimUI Brick hardware.

---

## Review Updater Implementation

Determine whether the existing updater logic should be:

- reused
- modified
- replaced

---

## Map Directory Layout

Document the existing NextUI filesystem structure so Ideal OS additions do not conflict.

---

# Repository Initialization Steps

Recommended initial workflow.

## Step 1

Fork NextUI repository into Ideal OS organization.

---

## Step 2

Create new directory structure for Ideal OS subsystems.

```
src/session/
src/sync/
src/notifications/
src/tasks/
```

---

## Step 3

Add runtime directories defined in earlier specs.

```
runtime/sessions/
runtime/sync/
runtime/tasks/
runtime/updater/
```

---

## Step 4

Disable conflicting subsystems from NextUI until audited.

Examples:

- updater
- launcher logic

---

## Step 5

Integrate minimal boot flow using existing platform layer.

Ensure device can boot into a simple Ideal OS launcher stub.

---

# Implementation Philosophy

Ideal OS should prefer **clean integration over aggressive reuse**.

Reusing too much legacy code can create hidden dependencies that make new features fragile.

When a subsystem conflicts with Ideal OS architecture, it should be replaced rather than heavily modified.

---

# Long‑Term Maintenance Strategy

The Ideal OS project should track upstream changes carefully.

Possible strategies:

- periodic rebase against NextUI platform layer
- isolate hardware drivers into a platform directory
- avoid modifying inherited hardware code unless necessary

This allows Ideal OS to benefit from upstream hardware fixes without breaking its architecture.

---

# Recommendation

The Ideal OS codebase should begin with a **clean NextUI fork**, preserving hardware compatibility while building new subsystems for:

- session management
- cloud sync
- notifications
- task scheduling

Selective harvesting from CrossMix should be performed only when the benefit clearly outweighs the maintenance burden.

This approach balances stability with the flexibility needed to build the Ideal OS experience.

