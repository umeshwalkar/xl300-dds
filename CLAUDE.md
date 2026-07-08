# xl300-dds — the data-bus interface contract

This repo is the **contract** every XL300 executable compiles against. It is submoduled
into each app at `dds/`. It contains both the machine-readable types and their normative
human documentation, versioned together so they never drift.

```
idl/                    the message types (.idl) — one struct per message shape
qos/xl300_profiles.xml  the named QoS profiles (STATE/CONTROL/SAFETY/SENSOR/HEALTH/…)
gen.sh                  run Fast DDS Gen over all IDLs -> generated/  (build product, .gitignored)
DDS_Topic_Contract.md   NORMATIVE contract: topics, types, QoS, publishers, subscribers, rates
```

## Rules (this repo is the single source of interface truth)
- **`DDS_Topic_Contract.md` is normative.** If any doc in `xl300-docs` disagrees with it
  about a topic/type/QoS, this file wins — fix the other doc.
- **Change discipline:** editing a type or topic here is a fleet-wide event. Every change
  must update the `.idl` **and** `DDS_Topic_Contract.md` **and** `docs/SYSTEM_MAP.md`
  (in xl300-docs) together, then be **version-tagged** (semver):
  - **MINOR** — appending a field to an `@extensibility(APPENDABLE)` struct, or adding a new
    topic/type. Backward-compatible: old readers ignore new fields. Safe.
  - **MAJOR** — removing/renaming/retyping a field, removing a topic, changing a key. Breaks
    existing consumers → coordinate a bump across all affected app repos.
  - **PATCH** — QoS profile tweak, comment/doc-only change.
- **Consumers pin a tag**, not a branch. Bumping = `git checkout <tag>` inside the app's
  `dds/` submodule + an app-side commit — the diff records exactly which contract version
  each app was built against.
- **Never commit `generated/`** — it's produced by `gen.sh` and depends on the Fast DDS Gen
  version. The `.idl` files are the source.

## When you change a type
1. Edit the `.idl` (keep `schema_version` + `@extensibility(APPENDABLE)`; append, don't reorder).
2. Update the matching row(s) + IDL sketch in `DDS_Topic_Contract.md`.
3. Update `docs/SYSTEM_MAP.md` if a publisher/subscriber relationship changed.
4. Bump semver, tag, and note the blast radius (which apps consume it) in the commit.
