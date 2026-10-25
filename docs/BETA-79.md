# Beta 3.10 build 79 (local only)

Branch `beta-b79`, from `beta-b78`. Local beta: no GitHub release.

Fixes from an independent review of b77's own changes (three reviewers; the Scythe/PegasusXI/
FileDownload/window-mode slice found nothing):

| finding | fix |
| --- | --- |
| Olympus XI's client list (a third party's GitHub file) could name `USER` or `X/.`, and a folder there was deleted to make room for a file | their list may not name the player's `FINAL FANTASY XI/USER` or `.` components; and nowhere in RetailWorldSync is a folder ever deleted to put a file in its place (`RetailClient.replaceable`, five sites) |
| Olympus XI: an offset near `Int64.max` in their list trapped the launcher | offsets and sizes bounded (≤ 2 GiB, no overflow) |
| Vanadreams: a Repair stopped between two zips that share a file could leave the earlier zip's copy and be marked finished | queued zips are written down as pending before the first is fetched and cleared one by one; the next Play finishes the chain |
| Vanadreams: a Play-time update (or Repair) fetching an earlier zip did not bring back later zips that override it | the overlap rule applies to updates too; a zip whose files are unknown (no list, or not in the record) brings back every later zip in its folder |
| Vanadreams: a record that would not open was replaced by one line (every zip then fetched again) | created only when missing; otherwise the error is raised |
| Tests that could not fail (the retail pin, the Olympus viewer, Vanadreams' "fetching written down first") | each now fails on the old code: the pin against an independent script's vector, the viewer file by file (a file only their pack has, a donor file their list lacks), an update stopped part-way |

## Tests

- All 32 suites pass on the b79 app (`--selftest-retail-world` 43, `--selftest-vanadreams` 47).
