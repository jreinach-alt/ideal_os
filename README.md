# Continuity

Cross-platform SRAM save sync for retro gaming handhelds. Uses git as its transport layer — your saves live in your own private GitHub repo.

## What It Does

- Syncs `.srm` (SRAM) save files across devices through your private GitHub repository
- Detects save changes automatically, commits and pushes when WiFi is available
- Preserves both versions on conflict — never silently overwrites your progress
- You own your data: your repo, your token, your saves

## Supported Platforms

| Platform | Device | Status |
|----------|--------|--------|
| NextUI | TrimUI Brick | In development |
| Onion OS | Anbernic RG40XX, Miyoo Mini | Planned |
| RetroDeck | Steam Deck | Planned |
| RetroArch | Android devices | Planned |

## How It Works

1. Create a private GitHub repo for your saves
2. Install Continuity on your device (PAK, app, or setup script depending on platform)
3. Saves sync automatically — git handles versioning and history

## Documentation

- [Architecture](docs/design/architecture.md) — how it works
- [Security Model](docs/design/security.md) — trust model and threat analysis
- [Roadmap](docs/roadmap.md) — development plan and sprint breakdown

## License

MIT — see [LICENSE](LICENSE).
