# Maerica Sync

Read-only Classic Forever addon for [WoW Forever](https://github.com/Maerica-server/wow-forever-service). Records a character snapshot into SavedVariables; the collector on your PC posts it to the service.

## Install

The collector installs this from GitHub Releases when the service catalog points at `Maerica-server/maerica-sync`. You can also unzip a release into `Interface\AddOns\`.

## Release

Bump `## Version:` in `maerica-sync/maerica-sync.toc` and push to `main`. Actions zips the folder and publishes tag `v<version>`.

## On disk

| | |
| --- | --- |
| Folder / TOC | `maerica-sync` / `maerica-sync.toc` |
| Interface | `16001` (Classic Forever) |
| SavedVariables | `MaericaSyncDB` per character |

The addon only uses Blizzard's addon API. It does not talk to the network.
