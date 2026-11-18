# Music data (first-party): PREVIEW, not approved to ship

Reps share music taste two ways, both optional:

1. **Spotify data export upload.** The rep downloads their own export from Spotify and drops the
   zip into the My Music tab. The browser reads it on the device (JSZip, self-hosted in
   `js/vendor/jszip.min.js`, MIT, v3.10.1), keeps only an aggregate, shows a preview of exactly what
   will be saved, and saves only after a consent checkbox.
2. **Quick taste questions.** Genres, favorite artists, how often they go to shows, event types,
   and (optional) how they find music.

Both award points (defaults: 100 for the upload, 50 for the quiz).

## What is saved (`public.rep_music_profiles`)

`top_artists` (20: name, plays, hours), `top_tracks` (20: track, artist, plays), `listening_totals`
(plays, hours, distinct artists, distinct tracks, first and last year), `top_genres` and `quiz` from the
quiz, and consent/upload/quiz timestamps. Never saved: the file, IPs, devices, countries, username,
playlists, search queries, payments, profile data, or listen timestamps.

## Spotify export facts (checked 2026-11-18)

Confirmed on Spotify's own pages:

- Format: the Download your data tool returns files in JSON, delivered as a ZIP.
  https://support.spotify.com/us/article/understanding-your-data/
  https://support.spotify.com/us/article/data-rights-and-privacy-settings/
- Three packages (account data, extended streaming history, technical log information), requestable
  separately or together. Same first page.
- Account data lists streaming history for the past year (end time in UTC, artist/creator name, item
  name, `msPlayed`), your library, playlists, search queries, Wrapped data (top artists, top genres,
  top tracks) and more. Same first page.
- Extended streaming history covers the life of the account and includes IP address, user agent,
  platform, country code, track and artist and album names, track URI, start/end reason, shuffle,
  skip, offline and private-session flags, `ms played`. Same first page.
- File names: `StreamingHistory.json` (past year, account data package), `YourLibrary.json`,
  `Playlist.json`, `SearchQueries.json`, `Inferences.json`, `Payments.json`, `UserAddress.json`,
  `Voiceinput.json`. https://www.spotify.com/us/legal/gdpr-article-15-information/
- The extended package ships a "Read Me First" file that describes each field (named on the
  understanding-your-data page).

Not confirmed from an official Spotify page (the request screen is behind login):

- Delivery times. Third-party sources quoting Spotify's request screen say about 5 days for account
  data and up to 30 days for extended streaming history. The portal copy therefore avoids stating
  numbers.
- Exact JSON field names in the extended files (`ts`, `master_metadata_album_artist_name`,
  `master_metadata_track_name`, `ms_played`) and in current account-data files (`endTime`,
  `artistName`, `trackName`, `msPlayed`). They match Spotify's field descriptions and widely used
  importers, but not an official schema page. The parser accepts both layouts, matches any
  `*streaming*history*.json`, and skips rows it does not recognize. If Spotify renames fields the
  upload shows a clear "could not find listening history" message.
- Spotify's export has no per-stream genre, so genres come from the quiz.

## Not applied

- `supabase/migrations/20261118120000_rep_music_profiles.sql` is a FILE ONLY. Nothing has been run
  against the live database. Rollback: `supabase/rollback/20261118_before_rep_music_profiles.sql`.
- Until it is applied the My Music tab loads, shows a "not switched on yet" notice, and disables
  saving.
- Points ride on `private.gam_rep_stats` (inside `content_points`), so leaderboard and tiers pick them
  up. Follow-ups: expose the two point values in the admin settings RPCs and in the `rules` object so
  the portal reads them from the server (today `MUSIC_POINTS` in `index.html` mirrors the defaults).

## Preview locally

```
cd submerged-crew && python3 -m http.server 8787
open http://localhost:8787/index.html?tenant=submerged
node js/music-taste.test.js
```

The migration has been syntax-checked with a Postgres parser but not run against a database.
