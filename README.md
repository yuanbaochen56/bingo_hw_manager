# Bingo Hardware Task Manager

A hardware task scheduler for heterogeneous multi-core, multi-chiplet SoCs. It accepts a stream of task descriptors with encoded dependency information, resolves inter-task dependencies through a per-cluster dependency matrix, and dispatches ready tasks to execution cores. The dependency matrix is an **identity-aware tagged scoreboard** — a consumer waits for *its* producer rather than any signal from a producer core. See **Identity-Aware Dependencies**.

**Authors:** Fanchen Kong, Xiaoling Yi, Yunhao Deng  
**Affiliation:** KU Leuven (MICAS)

## Architecture Overview

```
Host / Software Runtime
         |
         | Task descriptors (64-bit packed structs)
         v
  +--------------+       +------------------------------------------+
  | Task Queue   |       |  Per-Chiplet HW Manager                  |
  | (AXI-Lite or |------>|                                          |
  |  Master)     |       |  +-- stream_demux (by core_id) ------+  |
  +--------------+       |  |                                    |  |
                         |  v                                    |  |
                +--------+----------+   +--------+----------+   |  |
                | Waiting Queue     |   | Waiting Queue     |...|  |
                | Core 0 (depth 8)  |   | Core 1 (depth 8)  |   |  |
                +--------+----------+   +--------+----------+   |  |
                         |                       |               |  |
                    dep_check_manager FSM    dep_check_manager   |  |
                    (IDLE->CHECK->QUEUE->FINISH)                 |  |
                         |                       |               |  |
                +--------v-----------+-----------v---------+     |  |
                |  Counter-Based Dependency Matrix         |     |  |
                |  (per cluster, 8-bit saturating counters)|     |  |
                |  set: counter++ (always accepts)         |     |  |
                |  check: all required counters >= 1       |     |  |
                |  clear: counter-- (on successful check)  |     |  |
                +--------+-----------+---------------------+     |  |
                         |                                       |  |
          +--------------+--------------+                        |  |
          v                             v                        |  |
  +-------+--------+   +-------+--------+                       |  |
  | Ready Queue    |   | Checkout Queue |                       |  |
  | [core][cluster]|   | [core][cluster]|                       |  |
  | -> Device Core |   | -> dep_set     |                       |  |
  +----------------+   +-------+--------+                       |  |
          |                     |                                |  |
     (execute)        +---------+----------+                     |  |
          |           |                    |                     |  |
          v      Local dep_set      Remote dep_set (H2H)        |  |
  +-------+--------+  |           +-------------------+         |  |
  | Done Queue     |  |           | Chiplet Dep Set   |         |  |
  | [core][cluster]|  |           | AXI-Lite Master   |------+  |  |
  | (per-pair FIFO)|  |           | -> remote chiplet |      |  |  |
  +-------+--------+  |           +-------------------+      |  |  |
          |            |                                      |  |  |
          +----> Arbiter -> dep_matrix.set_column()           |  |  |
                                                              |  |  |
  +-----------------------------------------------------------+  |  |
  | From Remote Chiplets (H2H)                                   |  |
  |   -> Chiplet Done Queue -> Arbiter -> dep_matrix.set_column()|  |
  +--------------------------------------------------------------+  |
  +------------------------------------------------------------------+
```

## Task Descriptor Format

Each task is a 64-bit packed struct pushed into the task queue:

| Field | Width | Description |
|-------|-------|-------------|
| `task_type` | 1 | 0 = normal (executes on core), 1 = dummy (synchronization only) |
| `task_id` | 12 | Unique identifier (0-4095) |
| `assigned_chiplet_id` | 8 | Target chiplet |
| `assigned_cluster_id` | log2(clusters) | Target cluster within chiplet |
| `assigned_core_id` | log2(cores) | Target core within cluster |
| `dep_check_en` | 1 | Enable dependency checking before dispatch |
| `dep_check_code` | N_CORES | Bitmask: which core columns to check in dep matrix |
| `dep_set_en` | 1 | Enable dependency signaling after completion |
| `dep_set_all_chiplet` | 1 | Broadcast dep_set to all chiplets |
| `dep_set_chiplet_id` | 8 | Target chiplet for dep_set |
| `dep_set_cluster_id` | log2(clusters) | Target cluster for dep_set |
| `dep_set_code` | N_CORES | Bitmask: which core rows to signal in dep matrix |
| `dep_check_tag` | `DepTagWidth` | Per-edge identity tag this check expects |
| `dep_set_tag` | `DepTagWidth` | Per-edge identity tag this set carries |

The two tag fields are carved from the descriptor's reserved bits, so the
64-bit layout is unchanged. See **Identity-Aware Dependencies** below.

## Task Lifecycle

```
1. PUSH      Host writes task descriptor to task queue
2. ROUTE     Demux routes task to assigned core's waiting queue
3. CHECK     dep_check_manager reads dep_matrix:
             - dep_check_en=0: bypass (immediate pass)
             - dep_check_en=1: wait until the expected tag is present in
               every required column
4. CLEAR     On pass, clear the checked (column, tag) presence bits
5. DISPATCH  Task enters ready queue; core reads and executes
6. COMPLETE  Core writes done_info to per-(core,cluster) done queue
7. SIGNAL    Done queue + checkout queue match triggers dep_set:
             - Local: set the tag's presence bit in target cluster's dep matrix
             - Remote: AXI-Lite write to target chiplet's H2H mailbox
```

## Tagged Dependency Matrix

Each cluster has a dependency matrix with `N_CORES x N_CORES` cells, where each cell is a `2**DepTagWidth` **presence-bit scoreboard** over per-edge identity tags.

```
             Column (signal source core)
             core 0    core 1    core 2
Row 0 (co0)  [tags]    [tags]    [tags]   <- what core 0 waits for
Row 1 (co1)  [tags]    [tags]    [tags]   <- what core 1 waits for
Row 2 (co2)  [tags]    [tags]    [tags]   <- what core 2 waits for
```

**Operations:**
- `set_column(col, mask, tag)`: For each row in mask, set the presence bit `[row][col][tag]`. **Always succeeds** (no overlap rejection, `dep_set_ready = '1`).
- `check_row(row, mask, tag)`: True if bit `[row][c][tag]` is set for every column `c` in the mask.
- `clear_row(row, mask, tag)`: Clear bit `[row][c][tag]` for each column `c` in the mask.

There is no overlap rejection or backpressure, so the deadlock of the historical 1-bit overlap-detecting design (a second `set` to an already-set bit was rejected, creating circular backpressure through the done queue) cannot occur.

## Identity-Aware Dependencies (per-edge tags)

An identity-blind cell (one shared counter per `(consumer_core, producer_core)`
pair) knows the *number* of pending signals from a producer core, not *which*
producer raised them. Because one cell is shared by **every** producer→consumer
edge that maps to the same pair, a consumer could drain a stray signal meant for
a different consumer and dispatch **before its own input is ready** (the
counter-sharing hazard; see `COUNTER_SHARING_BUG.md`). That legacy counter
matrix — and the even older `serialize_shared_counter_consumers` software
mitigation — have been **removed**; per-edge identity tags are the design.

- **Hardware:** each cell is a `2**DepTagWidth` **presence-bit scoreboard**. A
  `set` writes the bit at its `dep_set_tag`; a `check` passes only on its own
  `dep_check_tag`; `clear` clears that one bit. A stray set carries a tag no
  consumer expects, so it can never satisfy an unrelated check. `DepTagWidth=4`
  (default) sizes the scoreboard to a layer's natural concurrency.
- **Software (mini-compiler):** `bingo_transform_dfg_allocate_dep_tags(W)` assigns
  each edge a tag via an optimal **minimum chain-cover** of the happens-before
  partial order per cell (edges that can never be live at once share a tag). The
  order accounts for **same-core HOL** execution (each core dispatches its tasks in
  topological order), which collapses same-core/diagonal cells to a single chain →
  one tag. This reuse is what lets a tiny fixed `DepTagWidth` suffice with **no
  separate concurrency-bounding pass**: if a cell ever needs more than `2**W`
  simultaneously-live edges the allocator **raises** (a placement signal —
  co-locate/serialize those producers, or widen `DepTagWidth`), rather than
  silently aliasing. The compiler does the heavy lifting; the hardware stays tiny.
  See [docs/identity_aware_dependency_matrix.md](docs/identity_aware_dependency_matrix.md)
  for a worked tutorial.

The tags ride the existing datapath: they live inside `dep_check_info`/
`dep_set_info` in the descriptor, flow through the dep-matrix set arbiter/demux in
the `dep_matrix_set_meta` struct, and are checked by the per-core
`dep_check_manager`. End-to-end RTL test: `test/tb_bingo_hw_manager_tagged.sv`.

## Per-(Core, Cluster) Done Queues

Each `(core, cluster)` pair has its own independent done queue FIFO:

```
Done Queues: [NUM_CORES][NUM_CLUSTERS] independent FIFOs

done_q[0][0]   done_q[0][1]     <- core 0, clusters 0..1
done_q[1][0]   done_q[1][1]     <- core 1, clusters 0..1
done_q[2][0]   done_q[2][1]     <- core 2, clusters 0..1
```

The pop condition for each FIFO depends ONLY on its own state:
```
done_q_pop[core][cluster] = checkout_pop[core][cluster]           // not a replay move
                          && checkout[core][cluster].task_type in {NORMAL, GATING}
```
An executing (normal / gating) checkout head only leaves its checkout queue when
its done is present (`!done_q_empty`), on the local dep_set path, the chiplet
dep_set path and the dep_set-disabled path alike, and its done leaves with it.

No cross-core or cross-cluster dependency in the pop logic. This eliminates head-of-line blocking where one core's completion stalls behind another core's entry in a shared FIFO.

## Module Hierarchy

```
bingo_hw_manager_top
 |
 +-- Task Queue (1x)
 |    +-- write_mailbox (AXI-Lite slave mode) OR
 |    +-- task_queue_master (AXI-Lite master mode)
 |
 +-- Per-Core Pipeline (NUM_CORES_PER_CLUSTER instances)
 |    +-- fifo_v3 (waiting_dep_check_queue, depth=8)
 |    +-- dep_check_manager (4-state FSM)
 |    +-- stream_filter (dep_check_en bypass)
 |    +-- stream_demux (route to cluster)
 |    +-- stream_filter (dummy task filter)
 |    +-- stream_demux (route to cluster, ready+checkout path)
 |
 +-- Per-Cluster Dep Matrix (NUM_CLUSTERS_PER_CHIPLET instances)
 |    +-- dep_matrix (tagged presence-bit scoreboard)
 |
 +-- Per-(Core, Cluster) Queues (N_CORES x N_CLUSTERS instances each)
 |    +-- Ready Queue: read_mailbox or fifo_v3
 |    +-- Checkout Queue: fifo_v3 (depth=CheckoutQueueDepth)
 |    +-- Done Queue: fifo_v3 (depth=DoneQueueDepth)
 |    +-- stream_demux (local vs H2H dep_set routing)
 |    +-- stream_filter (dep_set_en filtering)
 |
 +-- Dep Matrix Set Arbiter (1x)
 |    +-- stream_arbiter (N_CORES*N_CLUSTERS + 1 inputs)
 |    +-- stream_demux (route to cluster dep matrix)
 |    +-- stream_demux (route to core within cluster)
 |
 +-- H2H Communication
 |    +-- Chiplet Dep Set Master (AXI-Lite master, 1x)
 |    +-- stream_arbiter (chiplet dep set, from all cores)
 |    +-- Chiplet Done Queue (write_mailbox, 1x)
 |
 +-- Power Manager (1x)
 |    +-- bingo_hw_manager_pm (idle-based clock gating)
 |
 +-- Watchdog (1x)
 |    +-- bingo_hw_manager_watchdog (busy timer per (core, cluster), heartbeat reset)
 |
 +-- Replay Controller (1x)
 |    +-- bingo_hw_manager_replay_ctrl (moves a fenced core's checkout entries to live cores)
 |
 +-- Core Remap (NUM_CORES_PER_CLUSTER instances)
      +-- bingo_hw_manager_core_remap (retired logical core -> substitute core)
```

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `NUM_CORES_PER_CLUSTER` | 4 | Execution cores per cluster |
| `NUM_CLUSTERS_PER_CHIPLET` | 2 | Clusters per chiplet |
| `DepTagWidth` | 4 | Tag width (cell holds up to `2**DepTagWidth` concurrent edges) |
| `TaskIdWidth` | 12 | Task ID width (max 4096 tasks) |
| `ChipIdWidth` | 8 | Chiplet ID width (max 256 chiplets) |
| `HostAxiLiteAddrWidth` | 48 | Host-side AXI address width |
| `HostAxiLiteDataWidth` | 64 | Host-side AXI data width (task descriptor) |
| `DeviceAxiLiteAddrWidth` | 48 | Device-side AXI address width |
| `DeviceAxiLiteDataWidth` | 32 | Device-side AXI data width (done info) |
| `TaskQueueDepth` | 32 | Incoming task FIFO depth |
| `DoneQueueDepth` | 32 | Per-(core,cluster) done FIFO depth |
| `CheckoutQueueDepth` | 8 | Per-(core,cluster) checkout FIFO depth |
| `ReadyQueueDepth` | 8 | Per-(core,cluster) ready FIFO depth |
| `TASK_QUEUE_TYPE` | 1 | 0: AXI-Lite slave, 1: AXI-Lite master |
| `READY_AND_DONE_QUEUE_INTERFACE_TYPE` | 1 | 0: AXI-Lite, 1: CSR req/resp |
| `WatchdogHeartbeatTimeoutCycles` | 100000 | Cycles a busy core may go without heartbeat before it is `dead_suspect` |
| `WatchdogConfirmTimeoutCycles` | 0 | Cycles without heartbeat before a busy core is fenced and its tasks are replayed; must exceed the heartbeat timeout; `0` = detection only (no fence, replay or remap); CSR interface only |
| `WatchdogCoreMask` | `'1` | Per-(core, cluster) watchdog enable; masked slots are never `dead_suspect` |
| `CoreTypeIdWidth` | 4 | Width of one `CoreTypeId` entry |
| `CoreTypeId` | all `1` | `[core][cluster]` type id; a fenced core's replayed and later tasks may run on a live core with the same non-zero type (`0` = never hands over or takes over tasks) |
| `SubstituteLevelMask` | `3'b001` | Where a fenced core's tasks may go: bit 0 same cluster, bit 1 another cluster of the chiplet, bit 2 another chiplet (remote dispatch, see below) |
| `ImportSubstituteLevelMask` | `SubstituteLevelMask & 3'b011` | Levels an imported (level-3) task may use to find a live core here; a different value is a debug / loopback aid |
| `SubstitutePolicy` | 0 | Substitute chosen when a core dies: 0 = lowest live core of its type, 1 = least loaded (checkout occupancy); logical cluster first, fixed until that substitute dies |
| `CsrHeartbeatAddr` | `12'h5fd` | CSR number of the heartbeat write (e.g. `12'h5fe` = write to the ready CSR) |

## Interface Modes

**Task Queue:**
- **Mode 0 (Slave):** Host pushes task descriptors via AXI-Lite writes to a mailbox
- **Mode 1 (Master):** HW manager fetches task descriptors from host memory at `task_list_base_addr_i`

**Ready/Done Queues:**
- **Mode 0 (AXI-Lite):** Cores read ready tasks and write completions via AXI-Lite
- **Mode 1 (CSR):** Cores use lightweight CSR req/resp interface (lower latency)

## Cross-Chiplet Communication

When a task's `dep_set_chiplet_id != chip_id_i`, the dependency signal is routed to a remote chiplet via the H2H path:

1. Checkout queue entry routed to chiplet dep_set arbiter
2. `bingo_hw_manager_chiplet_dep_set` module sends AXI-Lite write to remote chiplet's mailbox
3. Remote chiplet receives via `from_remote_axi_lite_req_i` into its chiplet done queue
4. Remote chiplet processes the signal through its dep matrix set arbiter

Broadcast mode (`dep_set_all_chiplet = 1`) sends the signal to all chiplets simultaneously.

## Watchdog, Heartbeat, Replay and Core Remap

**CSR map (CSR interface mode):** read `0x5fe` pops the core's ready queue, write `0x5ff`
reports a done task, write `CsrHeartbeatAddr` (default `0x5fd`) is a heartbeat. A heartbeat
never enters the done queue. With `CsrHeartbeatAddr = 12'h5fe`, a write to the ready CSR is the
heartbeat (useful when the core's CSR path only forwards `0x5fe`/`0x5ff`). A request with any
other address is never served; simulation reports it as `[BINGO_CSR]`.

**Watchdog:** a core becomes busy when it pops a task and idle again when its done arrives.
While busy, a timer counts cycles since the last dispatch/heartbeat; reaching
`WatchdogHeartbeatTimeoutCycles` marks the core `dead_suspect`. Idle cores are never timed.
A late done clears the suspicion (the core was slow, not dead). Long kernels must write the
heartbeat CSR periodically. The counter width is derived from the timeouts.

**Fence (confirmed dead):** with `WatchdogConfirmTimeoutCycles != 0`, a busy core that reaches
that second, longer timeout is fenced, sticky until reset (`core_fenced_o`, e.g. for the system
to reset or isolate it). A done, dispatch or heartbeat in the same cycle wins. A fenced core no
longer gets tasks (its ready reads stall), and its done writes and heartbeats are accepted and
dropped, so a slow core that comes back cannot retire a task a second time.

**Replay:** a fenced core's checkout queue holds every task dispatched to it and not yet
retired, in order: the task it was running, then the tasks queued behind it. Their dep checks
already passed. `bingo_hw_manager_replay_ctrl` migrates one fenced core at a time:
1. flush its ready queue and let a done that arrived before the fence retire its task;
2. move its checkout entries, in order, into the ready + checkout queues of a live core
   (per entry, `bingo_hw_manager_substitute_sel`: the entry's logical core if it is live, else
   the lowest live core with the same non-zero `CoreTypeId`, first in the logical cluster, then
   in the other clusters if `SubstituteLevelMask[1]`; dummy-set / CERF-skipped entries only go
   to the checkout queue);
3. mark the core retired.

A replayed task keeps its logical core id, so its dep_set releases the same dependents as
before, including a same-core sequencing edge behind the lost task. If no live core may run an
entry, that core is marked stuck (sticky; `replay_stuck_o` is raised): its remaining entries stay
in its checkout queue, which retires nothing more except entries that run on no core (see CERF
degradation below), and the replay controller moves on to the other fenced cores. The other
cores keep running.
While a replay step may push into a cluster, normal dispatch into that cluster pauses.

**Remap (only once retired):**
- A logical core that is not fenced always keeps its tasks, whether it is busy, polling or
  `dead_suspect`. The compiler relies on per-core in-order execution, and a dummy-set task only
  waits for its source task because both sit in the same core's checkout FIFO.
- A fenced logical core's new tasks wait until it is retired and no other slot of its cluster
  is still being replayed, so its replayed (older) tasks reach their new core first.
- Once retired, an executing task (normal/gating) goes to the same substitute as its replayed
  entries (`bingo_hw_manager_substitute_sel`, same cluster first); without one, it waits (or is
  exported, level 3).
  The choice only depends on the set of fenced cores, so a dead core's tasks go to one
  substitute, in order. Dependencies still use the logical core (dep-matrix column =
  `assigned_core_id`); ready/checkout/done queues are those of the physical core.
- Dummy-set and CERF-skipped tasks are never remapped. They also wait until all earlier
  tasks of their logical core that run elsewhere have left their checkout queues.
- `CoreTypeId` describes which cores can run each other's kernels, per cluster, so clusters
  may differ. Give a core type that appears only once in its cluster a unique id or `0` (e.g.
  HeMAiA's accelerator core and DM core): a fenced core without a same-type live core stops at
  `replay_stuck_o`.

**Limitations:**
- Replay assumes that re-running a task gives the same result (its inputs are intact and it
  overwrites its outputs). In-place updates or buffers reused before the task finished break
  this; the compiler has to ensure it (no `replayable` marking yet).
- A fenced core's memory side effects are not stopped by the manager; the system has to reset
  or isolate it (`core_fenced_o`).
- A core that dies while idle is not detected (only busy cores are timed).
- Level 3 assumes the executing chiplet can run the task by its id (same task tables, reachable
  arguments and data); see "Levels 2 and 3" for what the transport does and does not cover.
- A fenced core is only released by reset.
- Replay needs the CSR ready/done interface (`READY_AND_DONE_QUEUE_INTERFACE_TYPE = 1`).
- The waiting queues are per core index and shared by the clusters, so a held task of a
  fenced core also holds the tasks of the same core index in other clusters queued behind it.
- The load monitor keeps counting a fenced core's last task as pending.

Simulation prints `[BINGO_WD]` on every `dead_suspect` / `fenced` change, `[BINGO_FENCE]` for
every dropped done, `[BINGO_REPLAY]` for every moved checkout entry, `[BINGO_RETIRED]` when a
fenced core's migration is complete, `[BINGO_REPLAY_STUCK]` when no core may run an entry, and
`[BINGO_REMAP]` for every remapped task. Level 3 adds `[BINGO_EXPORT]`, `[BINGO_IMPORT]`,
`[BINGO_REMOTE_DONE_OUT/IN]` and `[BINGO_REMOTE_REJECT_OUT/IN]`. `[BINGO_ASSERT]` errors flag
replay invariant violations.

### Control plane (`bingo_hw_manager_ctrl`)

Replay, remap and power management share one module that holds their common state and makes
the decisions that move work between cores; the mechanisms (queues, replay engine, PM bus
master, CERF, remote link) only execute them.
- **Slot mapping table (SMT).** For every logical slot, the live slot that runs its tasks once
  it is fenced. `core_remap` (new tasks) and `replay_ctrl` (outstanding tasks) read it. It is a
  register written only when a slot is fenced (entries whose logical slot or current substitute
  was just fenced are recomputed; readers wait that one cycle), so a dead core's tasks always go
  to one substitute, in order, whatever the policy (`SubstitutePolicy`).
- **Fault-aware power.** A fenced core no longer keeps its power domain at the normal level, and
  its load (pending tasks) is cleared.
- **Frequency-aware watchdog.** The PM levels are clock dividers; while a slot's domain runs at a
  level L above the normal level N, its watchdog timer advances only N/L of the cycles, so the
  timeouts count cycles of the normal clock.
- **Recovery boost.** While a substitute of a fenced core is busy, its domain runs at
  `bingo_hw_manager_boost_power_level_i` (0 = off).
- **Idle entry delay.** A slot only counts as idle for the PM after
  `bingo_hw_manager_idle_entry_delay_i` idle cycles (0 = at once), so short gaps between
  tasks keep the normal level and avoid the wake-up cost.
- **External access wake.** A cluster runs its memory on its own clock, so a cluster whose
  memory is accessed from outside (`bingo_hw_manager_cluster_access_i`, e.g. the host reading
  its L1) does not count as idle while accessed and for `bingo_hw_manager_access_wake_hold_i`
  cycles after the last access (0 = off), fenced slots included. It only delays the idle
  level: the idle entry delay keeps counting the cores' own idle time.
- **Core parking.** `bingo_hw_manager_park_req_i` bit `core + cluster*NUM_CORES` (0 = off)
  holds new tasks of that live slot until its checkout and ready queues have drained, then
  writes the slot mapping table with the usual substitute (the slot itself and slots in
  HOLD or PARKED masked out; not another chiplet). Later executing tasks follow that entry;
  dummy-set and CERF-skipped tasks stay on the logical core. No substitute, or a slot that
  runs another slot's tasks (it could not drain), raises `bingo_hw_manager_park_fail_o`
  for that bit until the request drops; so does the CSR-less AXI-Lite queue mode. A fence
  drops the park and uses the existing replay; if the substitute dies, the entry moves on
  (or back to the slot), and the slot's new tasks wait for the replay of its older ones.
  Clearing the request of a parked slot moves it back: its new tasks wait (on neither core)
  until none of its tasks is left on another core, then run on the slot again; the
  substitute's own tasks are not held. Setting the request again meanwhile keeps it parked.

The PM prints `[BINGO_PM]` for every level it applies (simulation only).

### Levels 2 and 3: other clusters and other chiplets

`SubstituteLevelMask` widens the search for a substitute. Level 1 (bit 0) is the logical
cluster, level 2 (bit 1) the other clusters of the chiplet (same `CoreTypeId`, lowest cluster
index first). Dependencies keep using the descriptor's logical core and cluster; done and
checkout queues are those of the physical slot.

Level 3 (bit 2, CSR interface only) sends a task to another chiplet when no live core of its
type is left on this one:
- **Export.** The dead core's slot stays the *proxy* of its tasks. During replay, an entry
  without a local substitute is rotated to the tail of the proxy's own checkout queue (marked
  exported) and copied to the export stream; new tasks of the retired core are exported the
  same way. Only types the transport can deliver are exported (`remote_export_type_en_i`, e.g.
  `bingo_hw_manager_remote_link` `target_valid_o`); any other type is stuck as without level 3.
  There is one export queue per peer of the transport (`RemoteNumPeers`, each
  `RemoteExportFifoDepth` deep, a whole checkout queue by default); a task goes to the queue
  of its type's peer (`remote_export_type_peer_i`), and only queues whose peer can take an
  export at once (`remote_export_peer_ready_i`, a free credit) compete, round robin. A peer
  that is out of credits therefore only holds its own exports. A proxy exports one type only,
  so its tasks stay in order.
- **Import.** The receiving chiplet runs the task on a live core of the same type (home slot =
  lowest slot of the type, substitute by `ImportSubstituteLevelMask`), with its dependency
  fields cleared, and returns a remote done when it retires. Imported tasks are never exported
  again.
- **Remote done.** It enters the proxy's done queue; the proxy's checkout head then retires in
  order, with its normal dep_set. The dones of a proxy come back in export order; a done that
  does not belong to the proxy's exported head sets `remote_done_mismatch_o` and stops the slot.
- **Reject.** If the receiving chiplet has no live core of the type (on arrival, or because the
  core running its imports died and none is left), it returns a reject instead of holding the
  link. The proxy slot then stops retiring and exporting, and `replay_stuck_o` is raised, as
  when no local core may run a task (it still retires entries that run on no core, see CERF
  degradation below).
- **Timeout.** A proxy slot whose exported head waits `remote_proxy_timeout_i` cycles for its
  remote done (0 = forever) takes the done as lost (a dropped packet, a dead chiplet or link)
  and stops as on a reject; `remote_timeout_o` tells the two apart. The task is not resent: it
  may only be slow, and would then run twice.

`bingo_hw_manager_remote_link` carries these streams between chiplets as one 64-bit AXI-Lite
write per message (dispatch page and done page of an 8 KiB mailbox region): a static
`RemoteTargetChip[core type]` table picks the destination, per-peer credits keep the receive
FIFOs from overflowing, and sequence numbers, unknown peers and write errors set sticky
`error_o` bits. A write that answers an error is resent with the same sequence number, up to
`RetryLimit` times `RetryBackoff` cycles apart; after that the packet is dropped and `error_o[5]`
is set (a dropped dispatch returns its credit; a dropped done or reject leaves the origin's proxy
waiting). This relies on the receiving mailbox not enqueuing a write it answers with an error
(true for `bingo_hw_manager_write_mailbox`), or a resend would duplicate the packet. The
receive mailboxes, and the top's chiplet done-queue mailbox, accept remote writes only to their
write register: the others answer SLVERR, so a peer cannot flush them.
Level 3 also needs the executing chiplet to be able to run a task given only its id: task
tables, argument records and data must be reachable from there (not true for chiplet-local
task tables or 32-bit L1 pointers).

## Dependencies

- [AXI](https://github.com/pulp-platform/axi) v0.39.1 — AXI-Lite definitions, crossbar
- [common_cells](https://github.com/pulp-platform/common_cells) v1.37.0 — FIFO, stream arbiter/demux/filter, counters

## DARTS: Dynamic Adaptive Runtime Task Scheduling

DARTS extends the static scheduler with conditional execution support for data-dependent workloads (MoE routing, early exit). See `dev_doc/` for full architecture documentation.

### Conditional Execution (CERF)

A 16-entry Conditional Execution Register File (CERF) per chiplet enables runtime task skipping. Tasks marked as conditional are either executed or skipped based on the CERF state, which is written by **gating tasks** on completion.

The user expresses conditional execution through **conditional edges** in the DFG:

```python
# Router conditionally activates each expert (compiler handles the rest)
dfg.bingo_add_edge(router, expert_0, cond=True)
dfg.bingo_add_edge(router, expert_1, cond=True)
dfg.bingo_add_edge(expert_0, aggregator)          # unconditional

# Compile: auto-assigns CERF groups, promotes router to gating task
compile_dfg(dfg)

# Simulate: specify which nodes are active
run_sim(dfg, config, active_nodes={expert_0})
```

The compiler pass `bingo_compile_conditional_regions()`:
1. Scans edges for `cond=True`
2. Auto-promotes source nodes to gating tasks (`task_type=2`)
3. Groups conditional targets by connected components (unconditional edges between targets = shared CERF group)
4. Assigns CERF group IDs (0-15) automatically

Skipped tasks still propagate dependency signals (via the checkout queue as dummies), preserving graph correctness.

**Degradation (stuck or rejected core type).** A host table, one entry per core type
(`cerf_fb_en_i`, `cerf_fb_clear_i`, `cerf_fb_set_i`, default off), lets the manager switch to a
backup branch on its own: once any slot of an enabled type is stuck or rejected, it clears one
CERF group and sets another (read-modify-write, other groups unchanged) and raises
`cerf_fb_evt_o` for that type. One update per cycle, lowest type first; a host write of the
whole mask in the same cycle wins and the update follows a cycle later. One update per enable:
later host writes are left alone, and dropping the enable clears the event and re-arms the type.
For the graph to finish, the stuck core's own tasks of the cleared group must still release
their dependents. A stuck or rejected slot therefore retires its checkout head the way a skipped
task retires (dep_set, no done, nothing runs) when the head runs on no core anyway (dummy-set or
skipped at dispatch) or the current CERF skips it, as long as the head belongs to the slot's own
logical core and that core has no task in another slot. The stuck core's later dummy-set and
skipped tasks join its checkout for the same reason. Any other head (a lost task the CERF still
needs) keeps blocking, so nothing overtakes it. This only depends on the CERF state, so a host
that switches the groups itself after reading the stuck status gets the same behaviour.

### Additional Modules

| Module | Purpose |
|--------|---------|
| `bingo_hw_manager_cond_exec_controller.sv` | 16-entry CERF register file |
| `bingo_hw_manager_load_monitor.sv` | Per-core pending task counters (load monitoring) |

### Evaluation Results

Evaluated via cycle-accurate Python simulator (`scripts/eval_darts.py`):

| Workload | Configuration | Speedup |
|----------|---------------|---------|
| MoE 8 experts, top-2 | 1 cluster, 3 cores | 2.29x |
| MoE 16 experts, top-1 | 1 cluster, 3 cores | 4.15x |
| MoE 8 experts, top-2 | 2 chiplets | 1.84-1.95x |
| Early exit (stage 0/4) | 1 cluster, 3 cores | 3.28x |

## Source Files

| Level | File | Description |
|-------|------|-------------|
| 0 | `bingo_hw_manager_mailbox_adapter.sv` | AXI-Lite to mailbox adapter |
| 0 | `bingo_hw_manager_read_mailbox.sv` | FIFO-to-AXI-Lite read bridge |
| 0 | `bingo_hw_manager_write_mailbox.sv` | AXI-Lite-to-FIFO write bridge |
| 0 | `bingo_hw_manager_task_queue_master.sv` | AXI-Lite master for task fetching |
| 0 | `bingo_hw_manager_csr_to_fifo*.sv` | CSR interface adapters |
| 1 | `bingo_hw_manager_dep_matrix.sv` | Dependency matrix: identity-aware tagged presence-bit scoreboard |
| 1 | `bingo_hw_manager_chiplet_dep_set.sv` | H2H AXI-Lite master |
| 1 | `bingo_hw_manager_dep_check_manager.sv` | Dependency check FSM |
| 1 | `bingo_hw_manager_pm.sv` | Power manager |
| 1 | `bingo_hw_manager_cond_exec_controller.sv` | CERF (conditional execution) |
| 1 | `bingo_hw_manager_load_monitor.sv` | Load monitoring |
| 1 | `bingo_hw_manager_watchdog.sv` | Heartbeat watchdog: `dead_suspect` and fence |
| 1 | `bingo_hw_manager_substitute_sel.sv` | Substitute choice (levels 1 and 2; lowest index or lowest weight) |
| 1 | `bingo_hw_manager_ctrl.sv` | Control plane: slot mapping table, power / load view, watchdog ticks, boost |
| 1 | `bingo_hw_manager_replay_ctrl.sv` | Replay of a fenced core's outstanding tasks (move, rotate, bounce) |
| 1 | `bingo_hw_manager_core_remap.sv` | Placement of new tasks of a retired core |
| 1 | `bingo_hw_manager_remote_link.sv` | Level-3 transport over AXI-Lite (next to the top, not inside it) |
| 2 | `bingo_hw_manager_top.sv` | Top-level integration |

## Testing

Two layers, both self-contained in this repo:

- **Cycle-accurate Python model** (`model/`) mirroring the RTL pipeline, with a
  pytest suite in `model/tests/`:
  - `test_dep_matrix.py` — the matrix primitive (tagged presence-bit scoreboard)
  - `test_single_chiplet.py`, `test_multi_chiplet.py` — pipeline / H2H integration
  - `test_cross_cluster_handoff_guard.py` — cross-cluster placement guard
  - `test_identity_stray_increment.py` — reproduces the counter-sharing hazard and shows the tag fix closes it
  - `test_dep_tag_allocator.py` — the tag allocator (min-chain-cover): edge pairing, tag reuse, distinct tags for concurrent edges, capacity backstop
  - `test_dep_sync.py` — multi-cluster dispatch-before-producer gate (must be clean under tags); also runnable as a CLI
- **RTL testbench harness** (`test/tb_bingo_hw_manager_harness.svh`) with deadlock
  detection, dep-matrix monitoring, and trace logging, driving the testbenches:
  `tb_bingo_hw_manager_top` (multi-chiplet), `tb_bingo_hw_manager_cerf_basic/skip`
  (CERF), `tb_bingo_hw_manager_dep_matrix` (matrix unit), and
  `tb_bingo_hw_manager_tagged`/`_tagged_mc` (identity-aware deps end-to-end).
- **DFG compiler** (`sw/bingo_dfg.py`) with automatic dummy task insertion and the
  identity-aware per-edge tag allocator (min-chain-cover).

```bash
# RTL: compile + simulate one testbench (requires QuestaSim)
make compile.log
make sim-bingo_hw_manager_top.log           # or _tagged / _dep_matrix / _cerf_basic / _cerf_skip

# ESAT servers: compile once, run tests by short name (logs in build/)
scripts/sim.sh remap_full_flow rlink_reject
# Full regression: every Bender test tb, then the random replay / level-3 tests with seeds
scripts/run_regression.sh 40 mytag

# Python model + compiler tests
make test-model                             # python3 -m pytest model/tests/

# Dependency-sync gate as a standalone report
python3 model/tests/test_dep_sync.py --seeds 20 --clusters 2
```

All Python model tests and all RTL testbenches pass; the per-edge identity tags
drive the dispatch-before-producer hazard to zero.

The Python model covers the dependency pipeline (dep matrix, tags, chiplet
dep sets, CERF). It does not model the fault-tolerance and control-plane parts:
watchdog fencing, replay, remap, substitute levels 2 and 3, the remote link
and rejects, the slot mapping table and the power policies (a core that is
dead from the start is only modelled as a core that never gets work). Those are
verified by the RTL testbenches (`replay_*`, `remap_*`, `xcl_*`, `remote_*`,
`rlink_*`, `pm_*`, `substitute_*`) and the random tests in
`scripts/run_regression.sh`.
