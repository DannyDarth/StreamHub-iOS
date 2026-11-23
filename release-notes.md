# StreamHub iOS 1.1.0

Ad-free Twitch playback, with the same rule as StreamHub desktop: **ads must not interrupt streams**.

- Twitch streams play through ad-free servers: the same proxy list as StreamHub Windows v2.0.0 (perfprod HTTP proxies first, then TTV.LOL-style playlist proxies)
- A server that's down is skipped; a server that serves ads is skipped
- If an ad shows up while you watch, StreamHub pauses and switches to the next server
- Never falls back to Twitch with ads on its own: if no server works you get "No ad-free stream", and the regular Twitch player is only used if you pick it in the menu
- A badge on the video shows the status (green: ad-free · via server; amber: ad detected; red: no ad-free stream)

Everything else stays as in 1.0.1: Twitch games, followed channels and search; Kick sign-in with your followed channels; chat.

## Install

**StreamHub-iOS-1.1.0-unsigned.ipa** isn't signed: sign and install it from Windows with a sideloading tool such as AltStore/AltServer or Sideloadly. The `.sha256` file is its checksum.

The ad-free servers are run by the TTV LOL PRO / Luminous community and see which channel you open and your IP address.
