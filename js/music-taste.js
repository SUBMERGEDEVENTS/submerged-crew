/**
 * Music taste helpers: summarize a Spotify data export in the browser.
 *
 * Everything here is pure and runs on the rep's device. Raw streaming rows are
 * read, counted, and thrown away. Only the aggregate returned by summarize()
 * is ever shown to the rep for preview and, after they confirm, saved.
 *
 * Fields used (from Spotify's documented export formats):
 *   Account data  (StreamingHistory*.json): endTime, artistName, trackName, msPlayed
 *   Extended      (Streaming_History_Audio*.json): ts, master_metadata_album_artist_name,
 *                 master_metadata_track_name, ms_played
 * Never read or kept: IP address, user agent, platform, country, username,
 * offline / incognito flags, search queries, payments, profile data.
 */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) {
    module.exports = factory();
  } else {
    root.MusicTaste = factory();
  }
})(typeof window !== 'undefined' ? window : globalThis, function () {
  var MIN_PLAY_MS = 30000;      // Spotify counts a stream after 30 seconds
  var MAX_ARTISTS = 20;
  var MAX_TRACKS = 20;
  var MAX_NAME = 120;

  function clean(v) {
    if (typeof v !== 'string') return '';
    return v.replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, MAX_NAME);
  }

  // Normalize one raw row from either export format. Returns null for rows we
  // do not use (podcasts, video, rows with no artist or track).
  function normalizeRow(o) {
    if (!o || typeof o !== 'object') return null;
    if (o.episode_name || o.episode_show_name || o.spotify_episode_uri) return null;
    var artist = clean(o.master_metadata_album_artist_name != null ? o.master_metadata_album_artist_name : o.artistName);
    var track = clean(o.master_metadata_track_name != null ? o.master_metadata_track_name : o.trackName);
    if (!artist || !track) return null;
    var ms = Number(o.ms_played != null ? o.ms_played : o.msPlayed);
    if (!isFinite(ms) || ms < 0) return null;
    var when = String(o.ts != null ? o.ts : (o.endTime != null ? o.endTime : ''));
    var m = /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})/.exec(when);
    return {
      artist: artist,
      track: track,
      ms: ms,
      year: m ? Number(m[1]) : null,
      // Used only to drop duplicates when a rep uploads both export types.
      dedupe: m ? (m[1] + m[2] + m[3] + m[4] + m[5] + '|' + artist + '|' + track) : null
    };
  }

  // rows: array of raw row objects (any mix of both formats). Returns the aggregate.
  function summarize(rows) {
    var seen = Object.create(null);
    var artists = Object.create(null);
    var tracks = Object.create(null);
    var totalMs = 0, plays = 0, minYear = null, maxYear = null, used = 0;
    for (var i = 0; i < rows.length; i++) {
      var r = normalizeRow(rows[i]);
      if (!r) continue;
      if (r.dedupe) {
        if (seen[r.dedupe]) continue;
        seen[r.dedupe] = 1;
      }
      used++;
      totalMs += r.ms;
      if (r.year) {
        if (minYear === null || r.year < minYear) minYear = r.year;
        if (maxYear === null || r.year > maxYear) maxYear = r.year;
      }
      var counted = r.ms >= MIN_PLAY_MS;
      if (counted) plays++;
      var a = artists[r.artist] || (artists[r.artist] = { name: r.artist, plays: 0, ms: 0 });
      a.ms += r.ms; if (counted) a.plays++;
      var tk = r.artist + '\u0001' + r.track;
      var t = tracks[tk] || (tracks[tk] = { track: r.track, artist: r.artist, plays: 0, ms: 0 });
      t.ms += r.ms; if (counted) t.plays++;
    }
    function byMs(x, y) { return (y.ms - x.ms) || (y.plays - x.plays) || (x.name || x.track).localeCompare(y.name || y.track); }
    var artistList = Object.keys(artists).map(function (k) { return artists[k]; });
    var trackList = Object.keys(tracks).map(function (k) { return tracks[k]; });
    artistList.sort(byMs); trackList.sort(byMs);
    return {
      top_artists: artistList.slice(0, MAX_ARTISTS).map(function (a) {
        return { name: a.name, plays: a.plays, hours: Math.round(a.ms / 360000) / 10 };
      }),
      top_tracks: trackList.slice(0, MAX_TRACKS).map(function (t) {
        return { track: t.track, artist: t.artist, plays: t.plays };
      }),
      listening_totals: {
        plays: plays,
        hours: Math.round(totalMs / 360000) / 10,
        distinct_artists: artistList.length,
        distinct_tracks: trackList.length,
        first_year: minYear,
        last_year: maxYear
      },
      rows_used: used
    };
  }

  // Which zip entries / uploaded files hold streaming history.
  function isStreamingHistoryName(name) {
    var base = String(name || '').split('/').pop();
    return /\.json$/i.test(base) && /streaming[_ ]?history/i.test(base) && !/^\._/.test(base);
  }

  // Parse the text of one file into an array of rows (or [] if not a row array).
  function rowsFromJsonText(text) {
    var data;
    try { data = JSON.parse(text); } catch (e) { return []; }
    return Array.isArray(data) ? data : [];
  }

  // The table is not applied yet in preview environments. Detect that case.
  function isMissingTableError(err) {
    if (!err) return false;
    var code = String(err.code || '');
    var msg = String(err.message || '');
    return code === '42P01' || code === 'PGRST205' || /rep_music_profiles/.test(msg) && /(does not exist|schema cache|not find)/i.test(msg);
  }

  // Quiz answers: clamp to the allowed option lists / lengths.
  var QUIZ = {
    genres: ['House', 'Deep House', 'Tech House', 'Techno', 'Melodic', 'Progressive', 'Trance', 'Drum and Bass',
             'Dubstep and Bass', 'Hip Hop', 'R&B', 'Pop', 'Latin', 'Afrobeats', 'Indie and Rock', 'Country'],
    frequency: ['Rarely', 'A few times a year', 'About once a month', 'Most weeks'],
    eventTypes: ['Club nights', 'Festivals', 'Day parties', 'Concerts', 'Warehouse and underground', 'Rooftop and lounge'],
    discovery: ['Friends', 'Playlists', 'Social media', 'Radio and mixes', 'Live shows']
  };
  function pick(list, values) {
    var out = [];
    (Array.isArray(values) ? values : []).forEach(function (v) {
      if (list.indexOf(v) !== -1 && out.indexOf(v) === -1) out.push(v);
    });
    return out;
  }
  function sanitizeQuiz(a) {
    a = a || {};
    var favs = String(a.favorite_artists || '').split(/[,\n;]+/).map(clean).filter(Boolean);
    var uniq = [];
    favs.forEach(function (f) { if (uniq.map(function (u) { return u.toLowerCase(); }).indexOf(f.toLowerCase()) === -1) uniq.push(f); });
    return {
      genres: pick(QUIZ.genres, a.genres),
      favorite_artists: uniq.slice(0, 10),
      show_frequency: QUIZ.frequency.indexOf(a.show_frequency) !== -1 ? a.show_frequency : null,
      event_types: pick(QUIZ.eventTypes, a.event_types),
      discovery: pick(QUIZ.discovery, a.discovery)
    };
  }
  function quizComplete(q) {
    return !!(q && q.genres.length && q.favorite_artists.length && q.show_frequency && q.event_types.length);
  }

  return {
    MIN_PLAY_MS: MIN_PLAY_MS,
    QUIZ: QUIZ,
    normalizeRow: normalizeRow,
    summarize: summarize,
    isStreamingHistoryName: isStreamingHistoryName,
    rowsFromJsonText: rowsFromJsonText,
    isMissingTableError: isMissingTableError,
    sanitizeQuiz: sanitizeQuiz,
    quizComplete: quizComplete
  };
});
