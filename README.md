# StreamHub iOS

Native SwiftUI iPhone app for watching Twitch and Kick streams (ad-free on Twitch), YouTube without ads and with SponsorBlock, and Crunchyroll. The Windows app is [DannyDarth/StreamHub](https://github.com/DannyDarth/StreamHub).

## Features

- **Twitch:** games, followed channels and search, with ad-free playback (below)
- **Kick:** sign in to see your followed channels, games and streams
- **Chat** for Twitch and Kick
- **YouTube:** Google sign-in (kept across new versions), Home, Subscriptions grouped by day, History (with Remove from watch history), search and channel pages. Videos play in place in the list (or in a bigger player) in YouTube's own player with the ads taken out, blocked or covered and skipped, and **SponsorBlock** per category (Settings → YouTube · SponsorBlock)
- **Crunchyroll:** crunchyroll.com in its own tab with your sign-in and Crunchyroll's player (full screen in iPhone's player); **App** opens an episode in the Crunchyroll app
- **Sign-ins kept across new versions:** Twitch, Kick and Crunchyroll sign-ins are saved in the Keychain (this device only) and put back after a reinstall; Settings → Sign-ins signs out of everything
- **Update check:** a banner when a new version is out, with the IPA's link or download for your signing service

## Install

Download **StreamHub-iOS-…-unsigned.ipa** from the [latest release](https://github.com/DannyDarth/StreamHub-iOS/releases/latest), then sign and install it with a signing service or sideloading tool (Signulous, AltStore/AltServer, Sideloadly…). Keep the same bundle ID when you update, so the new version replaces the old one. An unsigned IPA can't launch without signing.

## Builds and releases

Every push to `main` builds an unsigned IPA on a GitHub-hosted Mac (XcodeGen creates the Xcode project from `project.yml`) and publishes it as a test build prerelease under **Releases** (the newest 5 are kept). To build by hand, open GitHub Actions, select **StreamHub iOS unsigned IPA** and choose **Run workflow** on `main`.

To publish a release, raise `MARKETING_VERSION` in `project.yml` and update `release-notes.md`: the first build of `main` with a new version is also published as release **StreamHub iOS <version>**.


## Ad-free Twitch playback

Ads must not interrupt streams. When you open a Twitch channel, StreamHub plays it through an ad-free route, the same way StreamHub desktop does with streamlink-ttvlol: the playback token and stream playlist are requested through a proxy in a country where Twitch doesn't show ads (perfprod HTTP proxies first, then TTV.LOL-style playlist proxies). The video itself then loads directly from Twitch.

- A server that's down, or whose stream starts with ads, is skipped.
- If an ad still shows up during playback, StreamHub switches to the next server.
- If no server works, the stream doesn't play. It never falls back to Twitch with ads on its own; the regular Twitch player is only used if you choose it in the menu.
- A badge in the corner of the video shows the status: green **Ad-free · via server**, amber when an ad was detected, red when no ad-free stream is available. Tap it to hide it.

The proxies are run by the TTV LOL PRO / Luminous community and see which channel you open and your IP address.

## Earlier experiments

Earlier builds had an opt-in "TwitchAdBlock engine (experimental)" button, adapted from [level3tjg/TwitchAdBlock](https://github.com/level3tjg/TwitchAdBlock) (MIT license, Copyright (c) 2025 level3tjg). The ad-free playback above replaced it; the experiment's code is still in `TwitchProxyPlayerView.swift` but isn't used by the app.

## History

This app was developed in the `ios/` folder of [DannyDarth/StreamHub](https://github.com/DannyDarth/StreamHub) and moved here with its full commit history. Older IPA builds remain on that repository's Releases page.

## License

[MIT](LICENSE).
