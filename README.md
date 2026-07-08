# XL300 DDS — types, topics, QoS (start here if you know MQTT but not DDS)

This folder is the **data contract** every XL300 binary shares: the IDL types, the QoS
profiles, and how they map to topics. It implements `../DDS_Topic_Contract.md`.

```
dds/
├── idl/        the message types (.idl) — one struct per message shape
├── qos/        xl300_profiles.xml — the named QoS profiles (STATE/CONTROL/SAFETY/…)
├── gen.sh      run Fast DDS Gen over all IDLs (code, or a runnable demo)
└── README.md   this file
```

## 1. DDS for an MQTT person (the 10-minute mental model)

You already know pub/sub. DDS is pub/sub too — but **typed, brokerless, and with rich QoS.**

| MQTT | DDS | What's different |
|---|---|---|
| Topic = free string (`nav/core`) | **Topic = name + a fixed TYPE** (`NavState`) | DDS messages are **strongly-typed structs** (IDL), not opaque JSON/bytes. |
| Broker relays everything | **No broker.** Peers talk directly (RTPS over UDP) | Discovery finds peers automatically. No broker = no SPOF, lower latency. |
| `publish()` / `subscribe()` | **DataWriter** / **DataReader** on a Topic, inside a **Participant** | A Participant ≈ one process's presence on a Domain. |
| QoS 0/1/2 | **~20 QoS policies** (reliability, durability, history, deadline, liveliness, ownership) | You pick per topic. Writer & reader QoS must be **compatible** or they won't connect (the "RxO" rule). |
| Retained message | **Durability = TRANSIENT_LOCAL** | A late-joining reader immediately gets the last sample (e.g. current `safety/state`). |
| Last Will (LWT) | **Liveliness + Deadline** | A writer that stops beating is detected via `on_deadline_missed`/liveliness — this is how SES detects a dead subsystem. |
| Topic wildcards `#` `+` | **Partitions** + content filters | Group topics with partitions (`nss-internal`, `navigation`); no hierarchical wildcard subscribe. |
| (no real equivalent) | **Keys / instances** (`@key`) | One topic carries many instances by key — e.g. `sensors/gnss` holds `sensor_id=1` and `=2` as independent streams. |
| (no equivalent) | **Ownership = EXCLUSIVE** | Two writers on one topic; readers auto-consume the **highest-strength live** one → the active-standby failover, no subscriber logic. |
| (no equivalent) | **Domain** (0 vs 1) | Hard traffic isolation — Tier-0 control (Domain 0) never mixes with payload (Domain 1). |

**The one gotcha that bites newcomers:** if a writer and reader don't show data, 90% of
the time their **QoS is incompatible** (e.g. reader wants RELIABLE, writer offers
BEST_EFFORT) or they're on **different domains/partitions**. Keep both ends on the same
profile from `qos/xl300_profiles.xml`.

## 2. Topic → Type → QoS profile (the map you'll use)

| Topic | IDL type (file) | QoS profile | Partition |
|---|---|---|---|
| `nav/core` | `NavState` (nav.idl) | STATE | navigation |
| `nav/aux` | `NavAux` (nav.idl) | STATE | navigation |
| `aiding/ins` | `InsAiding` (nav.idl) | CONTROL | nss-internal |
| `sensors/gnss` | `GnssFix` keyed (sensors.idl) | SENSOR | nss-internal |
| `sensors/usbl` | `UsblFix` keyed (sensors.idl) | SENSOR | nss-internal |
| `sensors/svp` | `SvpSample` (sensors.idl) | SENSOR | nss-internal |
| `sensors/sbes` | `Altitude` keyed (sensors.idl) | SENSOR | nss-internal |
| `sensors/ctd/depth` · `/sv` | `DepthSample` · `SoundVel` | SENSOR | nss-internal |
| `ctrl/*` | `ManeuverCmd`/`ThrustCmd`/`FinCmd`/`TrimCmd` (control.idl) | CONTROL | control |
| `feedback/*` | `ActuatorFb`/`PropulsionFb`/`TrimFb`/`PlatformFb` (feedback.idl) | STATE | control |
| `safety/state` | `SafetyState` (safety.idl) | SAFETY | control |
| `health/<sub>` | `Heartbeat` keyed (health.idl) | HEALTH | (all) |

## 3. Install Fast DDS + Fast DDS Gen (on a VM or your dev box)

Fast DDS is the runtime (C++); **Fast DDS Gen** turns `.idl` into code (needs Java).
Fastest reliable path on Ubuntu 24.04:

```bash
sudo apt update
sudo apt install -y cmake g++ python3-pip libasio-dev libtinyxml2-dev \
                    openjdk-17-jdk git

# Fast CDR + Fast DDS + Fast DDS Gen via colcon (official build)
# --break-system-packages: Ubuntu 24.04's system pip is "externally managed" (PEP 668).
pip install --break-system-packages -U colcon-common-extensions vcstool
mkdir -p ~/fastdds/src && cd ~/fastdds
# IMPORTANT: on the 2.x line the manifest is named 'fastrtps.repos', NOT 'fastdds.repos'
# (a legacy name held over from before the project's Fast-RTPS -> Fast-DDS rename; 3.x
# renamed the file too). 'master' tracks 3.x latest; for a REPRODUCIBLE 2.14.x build pin
# a release tag instead, e.g.:
#   wget https://raw.githubusercontent.com/eProsima/Fast-DDS/v2.14.6/fastrtps.repos -O fastrtps.repos
wget https://raw.githubusercontent.com/eProsima/Fast-DDS/2.14.x/fastrtps.repos -O fastrtps.repos
vcs import --recursive src < fastrtps.repos
colcon build
echo 'source ~/fastdds/install/setup.bash' >> ~/.bashrc && source ~/.bashrc
# fastddsgen: build the generator
cd ~/fastdds/src/fastddsgen && ./gradlew assemble
# DO NOT symlink scripts/fastddsgen into /usr/local/bin: it computes its own directory as
# `dirname "$0"` with no symlink resolution, so a symlinked invocation looks for the jar
# relative to /usr/local/bin and fails with "Unable to access jarfile ...". Put the REAL
# directory on PATH instead:
echo 'export PATH="$HOME/fastdds/src/fastddsgen/scripts:$PATH"' >> ~/.bashrc && source ~/.bashrc
```
(Full/alternate instructions: eProsima Fast DDS "Installation from sources" docs. Note: on
2.x the CMake package this installs is named `fastrtps`, not `fastdds` — see each app's
`CMakeLists.txt`, which tries both.)

## 4. See it work in 3 commands (do this first!)

Let Fast DDS Gen generate a **complete runnable pub/sub demo** from `nav.idl`:

```bash
cd dds && ./gen.sh -example          # generates code + a CMake demo per type
cd generated && cmake -B build && cmake --build build
# terminal 1:                         # terminal 2:
./build/nav_subscriber                ./build/nav_publisher
```
You'll see `NavState` samples flow between two processes over DDS — no broker. Run the
publisher on cpu-1 and subscriber on cpu-2 (same command) and it works **across VMs**
via SIMPLE discovery. That's your "DDS hello world."

## 5. Applying the XL300 QoS (the production bits the demo skips)

The generated demo uses default QoS. Your real binaries load our profiles instead:

```bash
export FASTRTPS_DEFAULT_PROFILES_FILE=$PWD/qos/xl300_profiles.xml
```
Then create entities **by profile name** (C++ DDS API):

```cpp
// participant on Domain 0, using the xl300_domain0 profile
auto* dpf = DomainParticipantFactory::get_instance();
auto* participant = dpf->create_participant_with_profile("xl300_domain0");

// nav/core writer on the STATE profile
TypeSupport type(new xl300::NavStatePubSubType());
type.register_type(participant);
auto* topic = participant->create_topic("nav/core", "xl300::NavState", TOPIC_QOS_DEFAULT);
auto* pub   = participant->create_publisher(PUBLISHER_QOS_DEFAULT);
auto* writer = pub->create_datawriter_with_profile(topic, "STATE");

// active-standby: set THIS replica's ownership strength (primary 100 > standby 90)
DataWriterQos qos = writer->get_qos();
qos.ownership_strength().value = std::stoi(std::getenv("XL300_OWNERSHIP_STRENGTH"));
writer->set_qos(qos);
```
That `ownership_strength` line + the EXCLUSIVE profile **is** the Tier-0 failover
mechanism — primary and standby publish the same `nav/core`; readers follow the live
highest-strength writer automatically.

## 6. Rules to keep the contract intact
- **One publisher for `nav/core`** (NSS integrity-core). Never publish vehicle state from anywhere else (contract §1.4).
- **Bump `schema_version`** and only **append** fields (types are `@extensibility(APPENDABLE)`) so old readers keep working.
- **Writer and reader share the profile** for a topic, else RxO mismatch = silence.
- Raw sensors stay on the **`nss-internal`** partition; only `nav/core`/`nav/aux` are public.
