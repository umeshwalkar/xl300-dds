# UUV DDS Topic Contract

Companion to [Software_Architecture_Plan.md](Software_Architecture_Plan.md). This is the **interface contract** between every producer and consumer on the vehicle — the one document both Tier-0 (systemd/RT) and Tier-1 (k3s) sides code against. Topic names, types, QoS, publishers, subscribers and rates are normative; change them only by changing this file.

> Rates/deadlines below are confirmed against the **navigation SAD-to-software derivation report + sensor datasheets**: **INS/DVL (SPRINT-Nav Mini) up to 200 Hz ingest**, **GNSS (AsteRx-U3) 100 Hz position / 50 Hz heading**, **SVP (uvSVP) 30 Hz**, **SBES (ISA200) 1–10 Hz**, **control loops @ 10/20 ms**. `nav/core` is *published* at 100 Hz (10 ms) — NSS ingests the INS at its full rate without loss, but fuses/publishes at the control loop's consumption rate, not the INS's max. Remaining ⚠️ marks values still to verify (safety deadline, payload frame sizes — payload sensor selection pending).

---

## 1. Conventions

### 1.1 Naming
`<domain>/<entity>[/<instance>][/<signal>]` — lower-case, `/`-separated.
Examples: `nav/core`, `sensors/gnss/1`, `ctrl/fins/cmd`, `health/mnss`.

### 1.2 DDS domain & partition strategy
- **Domain 0 — Tier-0 (control/safety/nav).** Joined by all systemd Tier-0 services + the few Tier-1 pods that legitimately touch Tier-0 data: consumers (TMS reads `nav/core`) **and** the aiding-sensor adaptor pods (GNSS/SVP/SBES) that *publish* onto the private `nss-internal` partition. Their reschedulability is why `nss-internal` is on-fabric multicast, not SHM-only (below). **USBL(1,2) are owned by CMS**, not NSS (§3) — CMS joins Domain 0 only to publish the derived `aiding/usbl-position` feed.
- **Domain 1 — Tier-1 (mission/payload/telemetry).** Joined by k3s pods.
- **Partitions** within a domain mirror the namespaces/VLANs: `control`, `navigation`, `payload`, `comms`, `power`, `infra`.
- **`nss-internal` (private partition).** Raw nav-sensor measurements (INS, GNSS×2, SVP, SBES×2, bridged CTD) feed **NSS** (the consolidated fusion+enrichment component, formerly "NSS-integrity") over this private partition — they are **not** on the public vehicle bus, so raw position/depth/orientation never traverse the shared fabric. See §1.4. **Transport, revised now that NSS runs 3-way across 3 separate physical nodes (plan §8.7):**
  - **INS ↔ NSS: via `ins_manager`, not SHM.** SHM only works within one host, and 3 NSS replicas live on 3 different nodes, so a single physical INS can't be SHM-shared to all of them. `ins_manager` (Tier-0, 2-way active-standby) holds the actual wire connection to the INS and republishes onto `sensors/ins` — **all 3 NSS replicas subscribe identically** (SHARED ownership), which is also what keeps the 3 independent fusion computations converged without needing an explicit inter-replica state-sync channel. Read path: INS's **UDP broadcast output** (confirmed supported, SPRINT-Nav Mini manual §6.15) — `ins_manager` just listens, no connection-limit concern. Write path (aiding): **TCP** to the INS's aiding-input port — single-client behavior unconfirmed, so `ins_manager`'s own primary/standby pair uses **sequenced failover** (standby only opens its connection after detecting the primary's `health/ins-manager` heartbeat has lapsed), gated by the same DDS `EXCLUSIVE`-ownership arbitration already used for `aiding/ins` itself. See §3 notes and plan §8.7/§10.
  - **GNSS/SVP/SBES adaptors: Tier-1 k3s pods** that are freely rescheduled, so they reach `nss-internal` over **hostNetwork multicast**, not SHM. Coastable → their reschedule gap is tolerable. **This means `nss-internal` is a real on-fabric multicast partition, not purely intra-node** — so it depends on **IGMP snooping** on the Peplink switches (open verify item, plan §7/§10) and must be scoped to the navigation VLAN. Being a *private* partition (raw sensor data, sole subscriber = NSS) it still satisfies §1.4: no *fused* vehicle-state is duplicated on the public bus.
  - **`aiding/usbl-position` (CMS → NSS):** CMS owns `usbl-manager` (both USBL units — their primary role is the acoustic comms link to the topside GUI) and publishes one consolidated position+time feed onto this same private partition; NSS treats it as one more aiding input, gated the same as GNSS/SVP.
- Cross-tier topics (`nav/core`, `ctrl/setpoints/*`, `health/*`, `safety/state`) are bridged by an explicit **DDS Router** instance with an allow-list — nothing else crosses the Tier-0/Tier-1 boundary. This keeps Tier-0 transport-isolated while exposing exactly the agreed topics.
- Transport isolation is reinforced at the network layer by VLANs + IGMP snooping (see plan §7).

### 1.4 Single-source-of-truth rule (no duplicated vehicle state)

> **Exactly one topic on the public bus carries fused vehicle state — `nav/core` — produced by exactly one publisher, NSS (Tier-0, 3-way hot-standby).** No other producer publishes position, depth, altitude, orientation, or rates. The INS is an *input* (a sensor with its own validity flags), ingested **inside** NSS (via `ins_manager`, never republished as a competing vehicle-state topic). The enrichment topic `nav/aux` is published by the **same** NSS component (folded in — no separate "NSS-enrich" process) and carries **only fields not already in `nav/core`** (course/speed-over-ground, seabed trim, absolute-fix quality) — it never repeats depth/position/orientation. Any consumer needing vehicle state reads `nav/core`, full stop.

### 1.3 Keys
Multi-instance topics carry a key so DDS tracks instances independently. Keyed fields are noted in §6 IDL (e.g. `sensor_id`, `obstacle_id`).

---

## 2. QoS profiles (named, reusable)

### 2.0 DDS implementation — recommendation: **eProsima Fast-DDS**

Both Fast-DDS and Cyclone DDS are solid, ROS 2-compatible, and OMG-DDS conformant. For *this* vehicle I recommend **Fast-DDS**, for four concrete reasons that map onto decisions already in this contract:

1. **Discovery Server** — with this many nodes/topics across VLANs, default multicast SPDP discovery generates a lot of chatter. Fast-DDS's Discovery Server centralizes discovery (one or two redundant servers, e.g. on the CPU nodes), cutting cross-VLAN discovery traffic — a real benefit on the segmented switch fabric.
2. **Shared-memory transport** — the GPU payload nodes move high-bandwidth sonar/EO-IR frames between co-located pods/processes; Fast-DDS SHM avoids the loopback network stack intra-node.
3. **eProsima DDS Router** — directly implements the cross-tier bridge in §1.2 (allow-listed topics between Domain 0 and Domain 1) as a supported product, not a hand-rolled relay.
4. **XML QoS profiles + DDS-Security** — the named profiles in §2.1 map one-to-one to Fast-DDS `<profiles>` XML, and its DDS-Security plugins cover the (optional) intra-vehicle auth/encryption story.

*Cyclone DDS remains a fine alternative* if you prioritize a leaner footprint and exact alignment with the ROS 2 default RMW — its latency/determinism on Tier-0 is excellent. The QoS *semantics* in §2.1 are vendor-neutral, so the contract holds either way; only the profile-file syntax differs. **Decision: Fast-DDS unless a later constraint (footprint, ROS 2 RMW default) forces Cyclone.**

### 2.1 Profiles

Reference these by name in the tables instead of repeating settings.

| Profile | Reliability | Durability | History | Deadline / Liveliness | Ownership | Use for |
|---|---|---|---|---|---|---|
| **SAFETY** | RELIABLE | TRANSIENT_LOCAL | KEEP_LAST(1) | deadline 50 ms ⚠️ · liveliness AUTOMATIC 100 ms | **EXCLUSIVE** | emergency / safe-state commands |
| **CONTROL** | RELIABLE | TRANSIENT_LOCAL | KEEP_LAST(1) | deadline = 2× period · liveliness 200 ms | **EXCLUSIVE** | setpoints / actuator commands (redundant publishers) |
| **STATE** | RELIABLE | VOLATILE | KEEP_LAST(1) | deadline = 2× period | EXCLUSIVE | nav solution, feedback streams (latest-value) |
| **SENSOR** | BEST_EFFORT | VOLATILE | KEEP_LAST(1) | deadline = 2× period | SHARED | raw high-rate sensor streams (stale = useless) |
| **HEALTH** | BEST_EFFORT | VOLATILE | KEEP_LAST(1) | **deadline = failure detector** · liveliness | SHARED | heartbeats (SES watches deadline misses) |
| **PAYLOAD** | BEST_EFFORT | VOLATILE | KEEP_LAST(2) | deadline = 2× period | SHARED | high-bandwidth sonar/EO-IR frames |
| **MISSION** | RELIABLE | TRANSIENT_LOCAL | KEEP_LAST(8) | — | EXCLUSIVE | mission plans, configs (infrequent, must arrive) |
| **LOG** | RELIABLE | VOLATILE | KEEP_ALL | — | SHARED | data to NAS recorder |

**Why `EXCLUSIVE` ownership matters:** for redundant subsystems (PCS primary/replica, SES, NSS), all replicas publish the *same* topic; subscribers automatically consume from the **highest-strength live writer** and fail over to the next when it stops asserting liveliness — redundancy with no subscriber-side logic. Set `ownership_strength` = primary > replica.

**Why `deadline` on HEALTH/STATE matters:** SES and consumers arm a DDS `on_deadline_missed` callback. A missed deadline *is* the failure detector — no polling, no broker.

---

## 3. Navigation domain (`nav/`, `sensors/`, `aiding/`) — Domain 0

| Topic | Type | Profile | Rate ⚠️ | Publisher | Subscribers | Partition / Tier |
|---|---|---|---|---|---|---|
| `nav/core` | `NavState` | STATE | published **100 Hz (10 ms)**; deadline 20 ms | **NSS (T0, 3-way)** | MNSS, PCS, SES, TMS(bridged), CMS | `navigation` (public) / **T0** |
| `nav/aux` | `NavAux` | STATE | 10–50 Hz | **NSS** (same component as `nav/core`) | TMS, MPSS | `navigation` (public) / T0 |
| `nav/payload` | `NavPayload` | STATE | 10 Hz (bridged) | **NSS** | sa-fusion, pathplan (GPU, bridged) | `payload` (public) / T1, bridged from T0 |
| `aiding/ins` | `InsAiding` | CONTROL | on update (GNSS ≤1 Hz, USBL ~0.1–1 Hz, SVP ≤1 Hz) | **NSS** | `ins_manager` (delivers to physical INS) | `nss-internal` / T0 |
| `aiding/usbl-position` | `UsblAiding` | SENSOR | ~0.1–1 Hz (acoustic link, ≤6.9 kbit/s) | **CMS** (`usbl-manager`) | NSS | `nss-internal` / T0 (published from Domain 1/comms) |
| `sensors/ins` | `InsSample` | SENSOR | up to 200 Hz ingest | `ins_manager` (T0, 2-way) | **NSS** (all 3 replicas, identical feed) | **`nss-internal`** (private) |
| `sensors/svp` | `SvpSample` | SENSOR | 30 Hz | svp adaptor | NSS | **`nss-internal`** (private) |
| `sensors/sbes/bow` | `Altitude` (key) | SENSOR | 1–10 Hz | sbes-bow adaptor | NSS | **`nss-internal`** |
| `sensors/sbes/aft` | `Altitude` (key) | SENSOR | 1–10 Hz | sbes-aft adaptor | NSS | **`nss-internal`** |
| `sensors/gnss/{1,2}` | `GnssFix` (key) | SENSOR | 100 Hz position / 50 Hz heading (sensor_id=1 only) | gnss adaptors | NSS | **`nss-internal`** |
| `sensors/ctd/{depth,sv}` | `DepthSample`/`SoundVel` | SENSOR | 1 Hz | ctd-adaptor (MPSS) | NSS (3rd depth vote / SV x-check) | **`nss-internal`** (bridged from MPSS) |
| `payload/ctd` | `CtdSample` (water props) | SENSOR | 1 Hz | ctd-adaptor (MPSS) | MPSS | `payload` (public) |

**Notes**
- **`nav/core` is NSS's validated single source of truth (§1.4), not raw INS.** NSS ingests the INS (via `sensors/ins`, never on the public bus) plus the Tier-0 depth/altitude backups, applies per-field validity, **substitutes** depth/altitude/SV from backups when the INS flags them INVALID, computes the consolidated **`nav_state`** integrity band (below), and publishes one authoritative vehicle-state topic. The INS is an input sensor, never a competing publisher.
- **Field handling:** *substitute* where an independent backup exists — depth ← SVP (+CTD vote), altitude ← SBES, SV ← SVP; *flag + degrade* where none does — attitude/heading, angular & linear rates (INS-only → if INVALID, signal SES). Position absolute-correction is done in `nav/aux` (GNSS/USBL), not `nav/core`.
- **Consolidated integrity banding (`NavState.nav_state`, per SAD §4.4/§8):** an aggregate `NavIntegrityState { NAV_NORMAL, NAV_DEGRADED, NAV_INVALID }` computed from `NavState`'s `sigma_*` uncertainty fields against hysteresis thresholds T0<T1<T2:

  | Quantity | T0 (Normal→Degraded) | T1 (recover to Normal) | T2 (Degraded→Invalid) |
  |---|---|---|---|
  | Horizontal position | 100 m | ≤T1 to recover | 1500 m / abort at 1850 m ⚠️ |
  | Vertical (depth) | 2 m | — | 3 m / 5 m ⚠️ |
  | Heading | 0.1° | — | 0.5° / 1° ⚠️ |
  | Velocity | 0.3 m/s | — | 0.5 m/s / 1 m/s ⚠️ |

  Escalate at T0 and T2 (increasing error); recover at T1 and T0 (decreasing error) — standard hysteresis, avoids chatter at a boundary. ⚠️ Exact per-quantity T1/T2 pairing and the abort/emergency threshold need final confirmation with the safety authority (plan §10).
- **Degraded-mode guarantee:** as long as the INS lives and `ins_manager` + (redundant) NSS live, `nav/core` is available and validated, independent of k3s. NSS is the redundant Tier-0 core (3-way active-standby, plan §8.7), not the reschedule pool.
- `aiding/ins` is integrity-critical ("reject-on-doubt"): NSS withholds rather than forward suspect aids. CONTROL profile so a dropped sample is retried, not lost. **`ins_manager` is the only thing that ever writes to the physical INS** — it subscribes `aiding/ins` as a plain `EXCLUSIVE`-ownership reader, so DDS's own ownership arbitration guarantees it only ever sees the current highest-strength-live NSS replica's aiding stream, with zero extra leader-election code. **Gating logic by aid source:**

  | Aid | Fed to INS when | Submerged? | Surface? |
  |---|---|---|---|
  | **GNSS** | fix is valid **and** vehicle on surface | ✗ (no fix) | ✓ when fixed |
  | **USBL** (via CMS `aiding/usbl-position`) | quality good **and** vehicle submerged | ✓ primary absolute aid | (USBL is the submerged position aid) |
  | **SVP** | always available (improves acoustic ranging / SV) | ✓ | ✓ |

  So absolute-position aiding hands off cleanly: **GNSS on the surface → USBL when submerged**, with SVP feeding continuously throughout. If neither GNSS nor USBL qualifies, no position aid is sent and the INS coasts on inertial + native DVL (`nav/core` stays valid, drifts slowly).
- Depth/SV integrity is **opportunistic** (SVP and CTD are optional): 2-of-3 vote when INS+SVP+CTD present, down to INS-only worst case. Computed **inside NSS** from `sensors/ins`, `sensors/svp`, and `sensors/ctd/depth` (when present) — the voted result is the depth field of `nav/core`; raw inputs are not re-published as separate vehicle-depth topics.
- **INS accepts aiding only from NSS** — NSS is also the **INS protocol content decider** (arbitrated GNSS×2/USBL/SVP → aiding content), gated reject-on-doubt; `ins_manager` is purely the wire-protocol formatter/relay, it makes no gating decisions itself.
- **`ins_manager` transport (plan §8.7/§10):** read path is the INS's **UDP broadcast output** (confirmed supported — SPRINT-Nav Mini manual §6.15; note "if a UDP broadcast port is used as output, input is not accepted on that same port," so aiding must be a separate channel) — any number of listeners, no connection-limit concern, so both `ins_manager` replicas (and in principle NSS directly) could listen, though only `ins_manager` does, to keep the physical-INS-facing code in one place. Write path (aiding) is **TCP** to the INS's aiding-input port; whether the INS accepts more than one simultaneous TCP client on that port is **unconfirmed** (⚠️ open item, §7) — `ins_manager`'s own primary/standby pair is therefore designed for the conservative case: sequenced failover (standby only connects after detecting the primary is dead via `health/ins-manager` heartbeat), upgradeable to hot-hot if multi-client is later confirmed.
- **USBL ownership:** USBL(1,2) are **owned by CMS**, not NSS — their primary role is the acoustic comms link to the topside GUI; position is a derived byproduct. CMS's `usbl-manager` performs its own comms-quality arbitration between the two units and publishes one consolidated `aiding/usbl-position` feed; NSS consumes it purely as an aiding input, subject to NSS's own reject-on-doubt gating.
- **GNSS asymmetry:** GNSS-1 has 2 antennas (also provides heading, `GnssFix.heading`/`heading_valid`); GNSS-2 has 1 antenna (position only). This does **not** create a new redundancy gap — attitude/heading in `nav/core` is already INS-only by design (flag+degrade, no substitute); GNSS-1's heading is purely an **aiding** signal that improves INS heading accuracy/alignment speed during surface transit, not a replacement authority.
- **Payload nav bridge (`nav/payload`):** perception-fusion (`sa-fusion`) and path-planning (`pathplan`) need current position/orientation/speed for geo-referencing (SAD EIF-06). NSS publishes a reduced `NavPayload` subset (no validity/provenance detail) bridged onto Domain 1's `payload` partition — payload treats it as read-only geo-reference, never a competing vehicle-state authority.

---

## 4. Control & safety domain (`ctrl/`, `safety/`, `feedback/`) — Domain 0

| Topic | Type | Profile | Rate ⚠️ | Publisher | Subscribers | Tier/VLAN |
|---|---|---|---|---|---|---|
| `safety/state` | `SafetyState` | SAFETY | on change + 5 Hz keepalive | **SES** | MNSS, HYSS, PCSS, PNS, T&B, PCS, CMS | T0 / Control |
| `ctrl/setpoints/mnss` | `ManeuverCmd` | CONTROL | 10–50 Hz | TMS | MNSS | T1→T0 (bridged) |
| `ctrl/thrust/cmd` | `ThrustCmd` | CONTROL | 50–100 Hz | MNSS | PCSS | T0 / Control |
| `ctrl/fins/cmd` | `FinCmd` | CONTROL | 50–100 Hz | MNSS | HYSS | T0 / Control |
| `ctrl/trim/cmd` | `TrimCmd` | CONTROL | 1–10 Hz | MNSS | Trim & Ballast, PNS | T0 / Control |
| `feedback/hyss` | `ActuatorFb` | STATE | 50–100 Hz | HYSS | MNSS, SES | T0 / Control |
| `feedback/pcss` | `PropulsionFb` | STATE | 50–100 Hz | PCSS | MNSS, SES | T0 / Control |
| `feedback/trim` | `TrimFb` | STATE | 1–10 Hz | Trim & Ballast | MNSS, SES | T0 / Control |
| `feedback/pcs` | `PlatformFb` | STATE | 10 Hz | PCS | TMS, SES | T0 / Control |

**Notes**
- `safety/state` uses **SAFETY** + EXCLUSIVE: SES replicas publish with descending strength; actuators always obey the live highest-strength SES. TRANSIENT_LOCAL so a late-joining/restarted actuator immediately learns current safe-state.
- The MNSS control chain (`nav/core` → MNSS → `ctrl/fins|thrust`) is entirely within Domain 0 / Control VLAN; only `ctrl/setpoints/mnss` from TMS is bridged in.

---

## 5. Payload, perception, mission, power, telemetry & logging — Domain 1

> ⚠️ **Payload sensor selection is not yet finalized** (EO/IR, SSS, FLS, TAS). The `payload/*` rows below are **provisional placeholders** — topic names and the one-adaptor-per-device pattern hold, but types (`ImageFrame`/`SonarFrame`), rates, and PAYLOAD history depth will be fixed once devices, interfaces, and frame sizes are chosen. Nothing in Domain 0 depends on these.

| Topic | Type | Profile | Rate ⚠️ | Publisher | Subscribers | Tier/VLAN |
|---|---|---|---|---|---|---|
| `payload/eoir` | `ImageFrame` | PAYLOAD | 10–30 Hz | eoir-adaptor | perception-fusion (GPU-1) | T1 / Payload |
| `payload/fls` | `SonarFrame` | PAYLOAD | 1–10 Hz | fls-adaptor | perception-fusion (GPU-1) | T1 / Payload |
| `payload/sss` | `SonarFrame` | PAYLOAD | ping rate | sss-adaptor | path-planning (GPU-2) | T1 / Payload |
| `payload/tas` | `SonarFrame` | PAYLOAD | ping rate | tas-adaptor | path-planning (GPU-2) | T1 / Payload |
| `payload/esm` | `EsmDetect` | SENSOR | on detect | esm-adaptor | perception-fusion | T1 / Payload |
| `payload/ctd` | `CtdSample` | SENSOR | 1 Hz | ctd-adaptor | MPSS, (NSS via `sensors/ctd/*`) | T1 / Payload |
| `perception/situational_awareness` | `SituationModel` | STATE | 5–10 Hz | perception-fusion | TMS | T1 / Payload |
| `perception/obstacles` | `ObstacleList` (key) | STATE | 5–10 Hz | perception-fusion | TMS | T1 / Payload |
| `mission/plan` | `MissionPlan` | MISSION | on update | CMS | TMS | T1 / Comms |
| `mission/route` | `RoutePlan` | MISSION | on replan | TMS | MNSS(bridged), CMS | T1 / Comms |
| `telemetry/shore` | `TelemetryPkt` | MISSION | 1 Hz | telemetry-agg | CMS → MQTT bridge | T1 / Comms |
| `power/status` | `PowerStatus` | STATE | 1 Hz | EPDS | TMS, SES, CMS | T1 / Power |
| `power/cmd` | `PowerCmd` | CONTROL | on change | TMS, SES | EPDS | T1 / Power |
| `health/<subsystem>` | `Heartbeat` (key) | HEALTH | 1–5 Hz | **every** subsystem | **SES**, telemetry-agg | both (bridged) |
| `log/#` (recorder taps) | per source | LOG | n/a | NAS recorder subscribes | — | T1 / Infra |

**Notes**
- `health/<subsystem>` is the universal heartbeat — *every* Tier-0 and Tier-1 component publishes one (e.g. `health/mnss`, `health/eoir`). SES arms `on_deadline_missed`; a miss is the failure signal that can trigger `safety/state`.
- Payload bulk stays on the **Payload VLAN / Domain 1** and never touches Domain 0 — a sonar burst can't perturb control traffic.
- The **DDS↔MQTT bridge** in CMS subscribes to `telemetry/shore` (and selected `health/*`) and republishes to the shore MQTT broker over TLS; inbound `mission/plan` is the reverse path.

---

## 6. Type catalog (IDL sketch)

Authoritative types live in versioned `.idl`; this is the shape. Keep a `schema_version` in every type for forward/backward compatibility (extensible types).

```idl
struct CommonHeader {  // NOT "Header": eProsima IDL parser is case-insensitive vs field "header" (see dds/idl/common.idl)
  unsigned long long stamp_device;   // device timestamp (preferred); INS UTC is the vehicle reference (PPS-disciplined)
  unsigned long long stamp_ingest;   // adaptor ingest stamp, NTP-disciplined ns (fabric is NTP, not PTP)
  unsigned short     schema_version;
};

enum Validity { VALID, DEGRADED, INVALID };
enum NavIntegrityState { NAV_NORMAL, NAV_DEGRADED, NAV_INVALID };   // consolidated banding, T0/T1/T2 (§3)

struct NavState {            // nav/core — NSS-validated single source of truth (§1.4)
  CommonHeader header;
  double lat, lon;           // deg   (INS; absolute-corrected in nav/aux)
  double depth, altitude;    // m     (VOTED/SUBSTITUTED: depth=INS/SVP/CTD vote, altitude=INS/SBES)
  double roll, pitch, heading;       // deg   (INS)
  double vx, vy, vz;                 // m/s   (INS x/y/z velocities)
  double wx, wy, wz;                 // rad/s (INS x/y/z angular rates)
  double water_temp;                 // degC
  double sound_velocity;             // m/s   (best-quality: INS/SVP/CTD)
  double sigma_horizontal, sigma_vertical, sigma_heading, sigma_velocity;  // 1-sigma uncertainty -> drives nav_state
  Validity v_position, v_depth, v_altitude, v_heading, v_velocity;  // NSS-consolidated per-field validity
  octet   src_depth;                 // which source provided depth (INS|SVP|CTD) — provenance
  NavIntegrityState nav_state;       // consolidated Normal/Degraded/Invalid (aggregate, SAD §4.4/§8)
};

// nav/aux carries ONLY fields not in nav/core — never repeats depth/position/orientation (§1.4)
struct NavAux {              // nav/aux — same publisher as nav/core (NSS), separate topic
  CommonHeader header;
  double cog, sog;                   // course/speed over ground — GNSS (surface)
  double altitude_bow, altitude_aft; // independent SBES (for trim, not vehicle altitude)
  double seabed_trim;                // derived bow vs aft
  double pos_fix_residual;           // GNSS/USBL absolute-fix residual
  Validity q_fix, q_trim;            // enrichment quality
};

// nav/payload — reduced geo-reference subset, bridged to Domain 1 payload partition (SAD EIF-06)
struct NavPayload {
  CommonHeader header;
  double lat, lon, depth;
  double roll, pitch, heading;
  double speed;                      // body-frame speed magnitude
  NavIntegrityState nav_state;
};

struct InsAiding {           // aiding/ins — NSS publishes, ins_manager subscribes+delivers (reject-on-doubt gated)
  CommonHeader header;
  string gpgga; string gpzda;        // NMEA aiding to INS
  double usbl_n, usbl_e, usbl_d;     // USBL position aid, sourced from CMS aiding/usbl-position
  double sound_velocity;             // SVP aid
  Validity gate;                     // VALID = forward, else withheld
};

// aiding/usbl-position — CMS (usbl-manager) -> NSS; USBL is CMS-owned (comms link), NSS gets only this derived feed
struct UsblAiding {
  CommonHeader header;
  double north, east, down;
  double quality;                    // CMS's own comms-link/fix quality
  boolean valid;
};

// sensors/ins — ins_manager -> NSS (all 3 replicas subscribe identically); NOT on the public bus
struct InsSample {
  CommonHeader header;
  double lat, lon, depth, altitude;
  double roll, pitch, heading;
  double vx, vy, vz, wx, wy, wz;
  double water_temp, sound_velocity;
  Validity v_position, v_depth, v_altitude, v_heading, v_velocity;   // INS's OWN flags, pre-NSS-consolidation
};

// sensors/gnss — GNSS-1 (2 antennas) also provides heading; GNSS-2 (1 antenna) position only
struct GnssFix {
  CommonHeader header;
  @key unsigned short sensor_id;     // 1 or 2
  double lat, lon, alt, cog, sog;
  double heading;                    // valid only for sensor_id=1
  boolean heading_valid;
  octet fix_quality, num_sats;
  boolean valid;
};

struct SafetyState {         // safety/state
  CommonHeader header;
  @key octet zone;
  enum State { NOMINAL, CAUTION, EMERGENCY_SURFACE, ABORT } state;
  unsigned long reason_bits;
};

struct Heartbeat {           // health/<subsystem>
  CommonHeader header;
  @key string node;
  enum Status { OK, DEGRADED, FAULT } status;
  unsigned long seq;
};
// + SoundVel, Altitude, DepthSample, ManeuverCmd, ThrustCmd,
//   FinCmd, TrimCmd, ActuatorFb, PropulsionFb, ImageFrame, SonarFrame,
//   SituationModel, ObstacleList, MissionPlan, RoutePlan, TelemetryPkt, PowerStatus ...
```

---

## 7. Status of open items

| # | Item | Status |
|---|---|---|
| 1 | **INS output rate / loop rate** | ✅ **Resolved (revised)** — INS/DVL ingest up to 200 Hz (SPRINT-Nav Mini datasheet, not the earlier assumed 100/50 Hz — that figure was actually GNSS's spec); `nav/core` **published** at 100 Hz/10 ms; control loops @ 10/20 ms. |
| 2 | **INS aiding inputs** | ✅ **Resolved** — GNSS (surface, valid fix) → USBL-via-CMS (submerged, good quality), SVP continuous. Gating table in §3. |
| 3 | **DDS vendor** | ✅ **Decided — Fast-DDS** (rationale §2.0); Cyclone fallback. QoS semantics vendor-neutral. |
| 4 | **Payload sensors** (EO/IR, SSS, FLS, TAS) | ⚠️ **Pending selection** — `payload/*` rows provisional (§5); types/rates/history depth TBD once devices chosen. Does not affect Domain 0. |
| 5 | **Domain split vs single domain + partitions** | ◻️ **Open** — confirm the DDS-Router bridge approach (§1.2) vs one domain + partitions; affects the cross-tier allow-list. |
| 6 | **Safety deadline** (`SAFETY` profile) | ⚠️ **To verify** — 50 ms placeholder; set from SES reaction-time budget. |
| 7 | **T0/T1/T2 threshold pairing + abort policy** | ⚠️ **To verify with safety authority** — escalation thresholds are confirmed (SAD §4.4); exact recovery-threshold pairing and the SES abort/envelope-protection policy on sustained INVALID are open (plan §10). |
| 8 | **INS aiding-input TCP client limit** | ◻️ **Open — needs SPRINT-Nav Mini ICD/bench confirmation.** Output is confirmed UDP-broadcast-capable (no listener limit); whether the aiding-input TCP port accepts >1 simultaneous client is unconfirmed. `ins_manager` is designed for the conservative case (sequenced failover) pending this; see §3 notes and plan §8.7. |
| 9 | **SPRINT-Nav Mini combined output-rate budget (325 Hz)** | ⚠️ **To verify** — datasheet caps combined output at 325 Hz across all configured output ports; confirm whether broadcasting one message counts once or is charged per configured destination before finalizing the output-port config. |

---

*This contract realizes the plan's stated rule: the only coupling between Tier-0 and Tier-1 is DDS topics. Setpoints down, telemetry/health up, everything keyed and QoS-typed, redundancy via EXCLUSIVE ownership, failure detection via deadline.*
