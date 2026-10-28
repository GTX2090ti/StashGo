# StashGo (iOS / HarmonyOS)

StashGo is a Flutter client for the [Stash](https://github.com/stashapp/stash) media manager, compatible with **Stash 0.31.x**. One Dart codebase builds both the **iOS** and **HarmonyOS NEXT** apps.

[中文说明](README.md) | [iOS 构建说明（中文）](BUILD_IOS_ZH.md) | [iOS Build Guide (EN)](BUILD_IOS_EN.md) — binaries are attached to this repository's Releases (IPA for iOS, HAP for HarmonyOS, under the same tag)

---

## Repository layout

| Path | Contents |
|---|---|
| `lib/` | All Dart code, shared by both platforms |
| `ios/` | iOS project (Runner + Info.plist + Podfile) |
| `ohos/` | HarmonyOS project (DevEco template: `AppScope/`, `entry/`, hvigor config) |
| `codemagic.yaml` | Cloud iOS build config |
| `BUILD_IOS_*.md` | iOS local build & IPA packaging details |

From v1.6.90 both platforms live in this single repository. Before the merge iOS and HarmonyOS each had their own repo and `lib/` was synced by hand; now there is one copy, and the version number is a single build number that moves for both platforms together.

## Features

### Scenes
- Two-column grid cards: cover, duration, resolution, favorite star, **subtitle badge** (shown when external captions are detected)
- Infinite scroll with position restore on back; no paging buttons
- Combined search: title / path / details + performer name + tag + studio
- Sort: date added / date modified / title / file size / duration / rating / studio, etc. (0.31.1 enums)
- Filters: rating / date / duration / organized / studio / performer / tag (multi-select + search)
- Batch actions: favorite, rating, tags, **merge**, **generate covers**, **set studio**, **add performers**, select all — the studio / performer / tag pickers all have a search box
- Detail page: cover (manual cover takes priority, shown complete without cropping), info, links to performers / studio / tags, edit, scrape, generate cover, favorite, **clear all scrape**, copy file path
- Performer chips show the **age at filming** ("name · N years") whenever the performer has a birth date — a year alone is enough; when the scene has no date it falls back to the death date, then to today; no birth date means no age at all
- **File section**: full path on its own line with size / duration / modified time; multi-file blocks; set default file

### Performers · Studios · Tags
- Grid/list cards + infinite scroll + search + **sort**; portrait performer / studio cards (3 columns on phones)
- Performer detail grouped into *Basic / Body / Career / Images / Social / Archive*, collapsible, with filled-field counts on collapsed headers; age derived from the birth (or death) date, shown as age at death when a death date exists
- Edit and add share that one grouped form; saving submits only changed fields, and a field you clear is really cleared server-side
- **Performer merge**: from the detail page, multi-select source performers and merge into the current one — resolves duplicates / name clashes
- Studio detail shows parent / child studios (tappable); **Add** (list page) / **Delete** (detail page, with confirmation)
- Tags: browse all tags + scenes carrying a tag; related scenes on the detail page

### Scraping
- Three modes: fragment / name / URL scraping
- Sources: local scrapers + **Stash-box** (StashDB etc.); fragment mode auto-queries box using the local performer name
- Preview: name / aliases / birthdate / country / measurements / career / tags + image, "Apply & write back" on top
- Keeps the original performer name by default; write-back compatible with 0.31.1 (`height_cm` / `alias_list` / `performer_input`)
- **Tags and studios are never overwritten**: write-back unions the scraped tags with the ones already stored (the server treats `tag_ids` as a full replacement, so the merge happens client-side), and keeps the current studio when one is already set
- **Name-clash protection on write-back**: if another performer already has the same name, the name field is skipped and the rest are saved
- **Clear all scrape** (scene detail page): empties details / date / URLs / studio / performers / tags and refills the title from the file name (directory and extension stripped); rating, O-count and cover are untouched, and it asks for confirmation first
- Localized error messages (404 / timeout / not implemented / site fetch failure)

### Scan · Jobs · Generate · Identify · Duplicates
- Scan: all or **selected sub-folders**; optional cover / preview / sprite / phash generation
- Live Stash job queue: scan / generate / clean task progress
- **Generate covers**: single (detail page) / batch (multi-select) / global (tasks page) — 0.31.1 `metadataGenerate` + `sceneIDs`
- Full generate options: markers / marker screenshots / transcodes / image phashes / image thumbnails / clip previews, etc.
- **Batch identify**: auto-match scene metadata from multiple scraper sources (local scrapers / Stash-box) by priority
- **Duplicates**: find duplicate scenes by phash distance + duration difference, multi-select and merge

### Stats · Plugins
- Stats page: library-wide totals (scenes / images / performers / studios / tags, etc.)
- Plugins page: installed plugins, enabled state, task / hook counts
- Scraper packages page: installed list, browse and multi-select install from a package index, dependency auto-completion, install-job progress, scrapers reloaded when it finishes

### Servers & Settings
- Multiple server profiles (LAN / WAN address + API key, path prefixes supported) with one-tap switching in the toolbar and automatic routing by latency
- **Test connection**, network log, diagnostics page (profile / routing / latency / Stash version)
- Favorites page with three tabs: scenes (organized) / performers (starred) / studios (starred)
- **Safe mode**: thumbnails auto-blurred, long-press to peek
- **Biometric lock**: face unlock first, fingerprint fallback (HarmonyOS uses a custom `local_auth_ohos` fork)
- Theme: system / light / dark

### Search & Input
- **Clear button** on every search bar (scenes / performers / studios / tags / filters / merge / jobs / scrape)
- **Auto date dashes**: type 20261003 → automatically formatted as 2026-10-03

## Build

Same source, two channels.

Artifact names follow one rule: `StashGo-<iOS|HarmonyOS>-v<version>-<unsigned|signed>.<ipa|hap>` (e.g. `StashGo-iOS-v1.6.92-unsigned.ipa`, `StashGo-HarmonyOS-v1.6.92-signed.hap`) — the same name is used for Release assets and in the local `archive/{ipa,hap}` folders. Historical assets uploaded before the rename keep the old `StashScrubber-*` names.

**iOS** — Codemagic in the cloud (`codemagic.yaml`, `flutter: stable` / `xcode: latest`). Pushing `main` does **not** trigger a build; trigger it from the dashboard and poll that build id. The artifact is an unsigned IPA. For local builds and re-signing see [BUILD_IOS_EN.md](BUILD_IOS_EN.md).

```bash
flutter pub get
flutter build ios --release --no-codesign
```

**HarmonyOS** — built locally, needs the DevEco OpenHarmony SDK plus the Flutter-OH toolchain. `hvigorw`'s incremental check skips `flutter assemble` when artifacts already exist, so edited Dart silently stays out of the HAP; releases therefore run a two-step "AOT first, then package" script instead of plain `flutter build hap`.

```bash
flutter pub get
flutter analyze
cd ohos && hvigorw assembleHap -p product=default -p buildMode=release
```

## Install

**iOS**: the unsigned IPA must be re-signed and sideloaded yourself (AltStore / Sideloadly / enterprise certificate).

**HarmonyOS**: requires HarmonyOS NEXT (API 18+).

```bash
hdc install -r StashGo-HarmonyOS-vX.Y.Z-signed.hap     # overwrite install keeps your data
```

## Changelog

- **v1.6.96** (rolls up everything from 1.6.93–1.6.96): **Localisation**: every UI string now lives in three language dictionaries, and Settings can follow the system or force 简体中文 / English / 日本語 with immediate effect; **Watched**: scene detail and the multi-select bar gain "mark watched" (Stash `sceneAddPlay`, +1 per tap, with a reset action), and the watch (play) count appears in lists and detail while staying separate from the O counter; **Collections**: the library gains a Collections tab with search, sorting by name / date / scene count / rating / added or updated time and infinite scroll, a collection detail page lists its scenes, the scene edit page can toggle collection membership and create one inline, and a new "Add collection" page covers name, date, rating, studio, tags, aliases, director, URLs and synopsis; **Batching**: "add to collections" and "mark watched" join the multi-select bar, while favourite / rating / tags / studio / performers / collections now use chunked `bulkSceneUpdate` calls (100 ids per request) instead of one mutation per scene; favourite / watched / tag / collection / studio / performer / rating batch writes move to a background task queue that keeps running after leaving multi-select, with a top-bar task button for progress, cancel and clearing finished tasks, and the list refreshes silently while keeping its scroll position (merge and cover generation stay in the foreground); **Scrape write-back**: tags, performers and studios returned by external scrapers are no longer created blindly — existing entities are reused by name first (Stash enforces unique names), and an unresolvable entry is skipped on its own while the remaining fields are still written, so the whole apply no longer fails with `already exists`; **Versioning**: builds read the version from `pubspec.yaml` and inject it as `APP_VERSION` (Codemagic for iOS, the packaging script for HarmonyOS), so the about page shows the real build version instead of a hand-edited constant
- **v1.6.92**: Batch identify no longer fails with a 422 on Stash 0.31 — the identify options are no longer sent flat on `IdentifyMetadataInput`; they are nested under `options` per server introspection, sources are wrapped as `IdentifySourceInput.source`, and fields are trimmed to what the server reports (older servers keep working). The scene list no longer jumps back to the top after editing inside a scene and returning: the reload is deferred until the detail route pops and the list is visible again, so the grid is never emptied while covered and the scroll position survives. Related scenes on the studio / performer / tag detail pages remember the scroll offset from before a scene was opened and restore it on return (pulling more pages first when needed); those pages now refresh silently instead of tearing down the loaded list. The HarmonyOS versionCode is aligned from 601 to 691, matching the iOS build number
- **v1.6.91**: The studio detail page gains **Edit** (pencil in the app bar): add and edit now share one form with the Stash 0.31 fields (name, aliases, URLs, parent studio, favourite, rating, tags, details, ignore auto-tagging); only changed fields are submitted, clearing a field really clears it server-side (a cleared parent studio is sent as `null`), and the parent picker excludes the studio itself and its direct children; the studio query now trims its fields from server introspection, so an older Stash missing one no longer breaks the whole query. The scene multi-select batch bar no longer greys every button while a batch is running (only the selected count drives it, and the busy flag is always cleared in `finally`); batch writes now run 6-way concurrent and abort after 3 consecutive failures with the selection kept, instead of a long serial loop that left the buttons dead
- **v1.6.90**: The age at filming is now derived much more loosely — a birth date filled in only as a year (`2000`) or only to the month still yields "N years" (an exact day is no longer required; the birthday-not-reached correction only applies when both ends are exact), and when the scene has no date it falls back to the performer's death date, then to today; masked birth years such as `199X` still can't be located, so they stay hidden. The HarmonyOS launcher icon now uses the same artwork as iOS (replacing the placeholder SVGs shipped with the project template). The app is named **Stash** everywhere (lock-screen title, unlock prompt, about page). **The iOS and HarmonyOS repositories were merged into this one**: a single `lib/`, and a single build number shared by both platforms
- **v1.6.89**: The scene detail page gains **Clear all scrape** next to the cover button — after a confirmation dialog it wipes details / date / URLs / studio / performers / tags and sets the title to the file name (directory and extension stripped), leaving rating, O-count and cover alone. Performer chips now carry the age at filming ("name · N years") when the scene has a date and the performer has a birthdate.
- **v1.6.88**: New "Scraper packages" page (Settings → below Plugins): lists the scraper packages installed on the server and loads the ones available from a package index (the source configured on the server by default, falling back to the community index), with search over long lists and multi-select install; selections automatically pull in `requires` dependencies such as `py_common`, which the server does not install for you; installation is an async background job, so the page polls it by job id and shows progress, then reloads scrapers on completion — no container restart needed. Package fields, the `PackageType` enum spelling and the `PackageSpecInput` key names are all trimmed from server introspection, so older Stash versions missing a field no longer break the whole query
- **v1.6.87**: Scraped results no longer clobber saved tags — applying a scrape to a scene or performer unions the scraped tags with the ones already stored (the server treats `tag_ids` as a full replacement, so the merge happens client-side), and the scrape preview says so; the existing "keep current studio" and "keep performer name" behaviours are unchanged
- **v1.6.86**: The studio, performer and tag pickers inside the scene multi-select batch bar now share one searchable selection sheet (filter long lists directly, multi-select with a clear button), replacing the three duplicated search-less sheets; the about-page version label follows the build version
- **v1.6.85**: Performer records now cover every Stash 0.31.1 field (alias list, gender, birth / death date, height, weight, measurements, fake tits, penis length, circumcision, eye and hair colour, career start / end, tattoos, piercings, URLs, ignore auto-tagging, tags, rating, favourite); edit and add share one grouped, collapsible form whose collapsed headers show how many fields are filled; saving submits only changed fields, and a field you clear is really cleared server-side; the performer detail page uses the same collapsible groups and adds an age derived from the birth date (shown as age at death when a death date exists); performer queries trim themselves against server introspection, so an older Stash missing a field no longer fails the whole query
- **v1.6.84**: Batch identify page (auto-match metadata from multiple scraper sources by priority); duplicates page (find by phash distance + duration diff, merge); stats page (library-wide totals); plugins page (list / enabled state / task & hook counts); new batch actions "set studio" and "add performers" (performers appended, not replaced); full generate options (markers / marker screenshots / transcodes / image phashes / image thumbnails / clip previews); fix auto-tag 422 (field type now `[String!]`); manual cover takes priority and detail covers show complete without cropping; portrait performer / studio cards (3 columns on phones)
- **v1.6.70**: Synced all iOS features: safe mode (blurred thumbnails), favorites page, infinite scroll; biometric lock (face first, fingerprint fallback, via a custom local_auth_ohos fork)
- **v1.6.58**: Tablet-adaptive column counts; two-column detail layout on wide screens; player-style cover background (fill + bottom gradient)
- **v1.6.57**: Performer merge (⧉ button on detail page — multi-select source performers, merge into the current one; resolves duplicates / name clashes); name-clash protection on write-back (UNIQUE conflict → skip the name, save the rest)
- **v1.6.55**: Friendly scrape errors (404 / timeout / not implemented / site fetch failure); auto date dashes (YYYY-MM-DD); file-section divider
- **v1.6.52**: Performer fragment scraping fixed (0.31.1 returns not implemented for performer_id → now sends performer_input)
- **v1.6.51**: Clear button on every search bar (scenes / performers / studios / tags / filters / merge / jobs / scrape)
- **v1.6.50**: Simplified Chinese terminology (phash / sprite / preview); generate-cover query field fix (interactiveHeatmaps)
- **v1.6.48**: Sort for performer / studio main lists; sort for related scenes; scene detail file section (full path wrapping, size / duration / modified time, multi-file blocks, set default file)
- **v1.6.46**: Generate covers for scenes (detail + batch); Stash-box fragment scraping (uses local performer name); keep original performer name on scrape by default; performer aliases on detail (5 shown, expandable); subtitle badge on scene covers; add/delete performers & studios; fix performer detail 422 (`Performer.alias_list`)
- Earlier: bottom navigation, infinite scroll, paging removed, favorites, 0.31.1 sort enums, scrape write-back field compatibility, Chinese-localized copy & paste

> Note: Starting from v1.6.46 this repository hosts the full Flutter source code; the earlier ArkTS version remains in git history (tag v1.6.1 and before). The original SwiftUI native iOS app (v1.6.0) is archived on branch `backup/native-ios-1.6.0`.
