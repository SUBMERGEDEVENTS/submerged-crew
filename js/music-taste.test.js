#!/usr/bin/env node
var assert = require('assert');
var mt = require('./music-taste.js');

// Account data format
var account = [
  { endTime: '2026-03-01 20:15', artistName: 'Artist A', trackName: 'Song 1', msPlayed: 200000 },
  { endTime: '2026-03-01 20:20', artistName: 'Artist A', trackName: 'Song 1', msPlayed: 200000 },
  { endTime: '2026-03-02 09:00', artistName: 'Artist B', trackName: 'Song 2', msPlayed: 10000 },
  { endTime: '2025-12-02 09:00', artistName: 'Artist B', trackName: 'Song 3', msPlayed: 3600000 }
];
// Extended format, one row duplicates an account row, one podcast, one video, one has IP data
var extended = [
  { ts: '2026-03-01T20:15:44Z', master_metadata_album_artist_name: 'Artist A', master_metadata_track_name: 'Song 1',
    ms_played: 200000, ip_addr: '203.0.113.9', platform: 'iOS', conn_country: 'US', username: 'someone' },
  { ts: '2026-03-03T10:00:00Z', master_metadata_album_artist_name: 'Artist C', master_metadata_track_name: 'Song 4', ms_played: 120000 },
  { ts: '2026-03-03T11:00:00Z', master_metadata_album_artist_name: null, master_metadata_track_name: null,
    episode_name: 'Ep', episode_show_name: 'Show', spotify_episode_uri: 'spotify:episode:x', ms_played: 999999 },
  { ts: '2026-03-03T12:00:00Z', master_metadata_album_artist_name: null, master_metadata_track_name: null, ms_played: 5 }
];

var s = mt.summarize(account.concat(extended));
assert.strictEqual(s.top_artists[0].name, 'Artist B');        // 1h10s beats others
assert.strictEqual(s.top_artists[0].plays, 1);                // the 10s play is not a counted play
assert.strictEqual(s.top_artists[1].name, 'Artist A');
assert.strictEqual(s.top_artists[1].plays, 2);                // duplicate across formats removed
assert.strictEqual(s.listening_totals.distinct_artists, 3);
assert.strictEqual(s.listening_totals.first_year, 2025);
assert.strictEqual(s.listening_totals.last_year, 2026);
assert.strictEqual(s.rows_used, 5);

// Nothing sensitive leaks into the aggregate
var blob = JSON.stringify(s);
['203.0.113.9', 'iOS', 'someone', 'conn_country', 'ip_addr', '20:15', 'spotify:episode'].forEach(function (bad) {
  assert.strictEqual(blob.indexOf(bad), -1, 'leaked ' + bad);
});
assert.deepStrictEqual(Object.keys(s).sort(), ['listening_totals', 'rows_used', 'top_artists', 'top_tracks']);

// Caps
var many = [];
for (var i = 0; i < 100; i++) many.push({ endTime: '2026-01-01 00:00', artistName: 'A' + i, trackName: 'T' + i, msPlayed: 1000 * (i + 1) });
var m = mt.summarize(many);
assert.strictEqual(m.top_artists.length, 20);
assert.strictEqual(m.top_tracks.length, 20);
assert.strictEqual(m.top_artists[0].name, 'A99');

// Bad input is ignored, not thrown
assert.strictEqual(mt.summarize([null, 1, 'x', {}, { artistName: 'x' }]).rows_used, 0);
assert.deepStrictEqual(mt.rowsFromJsonText('not json'), []);
assert.deepStrictEqual(mt.rowsFromJsonText('{"a":1}'), []);

// File name detection
assert.ok(mt.isStreamingHistoryName('Spotify Account Data/StreamingHistory_music_0.json'));
assert.ok(mt.isStreamingHistoryName('Spotify Extended Streaming History/Streaming_History_Audio_2019-2021_0.json'));
assert.ok(!mt.isStreamingHistoryName('Spotify Account Data/Payments.json'));
assert.ok(!mt.isStreamingHistoryName('Spotify Account Data/SearchQueries.json'));
assert.ok(!mt.isStreamingHistoryName('Spotify Account Data/UserData.json'));
assert.ok(!mt.isStreamingHistoryName('Spotify Account Data/StreamingHistory0.txt'));

// Missing-table detection
assert.ok(mt.isMissingTableError({ code: '42P01' }));
assert.ok(mt.isMissingTableError({ code: 'PGRST205', message: "Could not find the table 'public.rep_music_profiles' in the schema cache" }));
assert.ok(!mt.isMissingTableError({ code: '42501', message: 'permission denied' }));
assert.ok(!mt.isMissingTableError(null));

// Quiz
var q = mt.sanitizeQuiz({ genres: ['House', 'Nope', 'House'], favorite_artists: 'A, b;A\nC', show_frequency: 'Most weeks', event_types: ['Festivals'] });
assert.deepStrictEqual(q.genres, ['House']);
assert.deepStrictEqual(q.favorite_artists, ['A', 'b', 'C']);
assert.ok(mt.quizComplete(q));
assert.ok(!mt.quizComplete(mt.sanitizeQuiz({})));

console.log('music-taste tests passed');
