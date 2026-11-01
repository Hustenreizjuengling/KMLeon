# Exploratory / break-it scripts

Not part of `run_all.sql`. These scripts probe the engine with hostile or extreme input
and **print what happened** (`ok` / `LOOK`) instead of asserting, so a human can judge new
behaviour. Every finding they produced so far has a hard regression check in
`../smoke_test_hostile.sql`.

| Script | What it throws at KMLeon |
|---|---|
| `fuzz_api_edges.sql` | NULL/oversized/invalid job + asset attributes, XML/Unicode-hostile text (`<script>`, `]]>`, emoji), nested ExtendedData |
| `fuzz_geometry_query.sql` | degenerate/corrupt `SDO_GEOMETRY`, arcs, circles, 4D/LRS, out-of-range coordinates, GeoJSON oddities, 20k-vertex lines; QUERY sources with DDL/DML/PLSQL, missing geometry, bad binds, unsupported types, info leaks |
| `fuzz_states_config.sql` | illegal status transitions, 8 parallel `run_async` + duplicate run, dispatcher batch with a failing job, config abuse (bad calendar, negative retention, non-terminal statuses, bogus engines) |
| `load_profile.sql` | 10k GeoJSON features, 1 MB description + 2000 ExtendedData keys, 50k streamed points → KMZ, 1000 styles / 1000-deep folders, temp-LOB accounting |

Run them as the KMLeon schema on a **test** instance (they create and delete jobs, and
`fuzz_states_config.sql` toggles cleanup settings — restoring them at the end). The load
script needs `grant select on v_$temporary_lobs` for its last line (optional).
