# Issue #3 — Partial-commit behaviour: why a failed commit still changed the configuration

**Status:** kernel rollback **PASS**, full configuration atomicity **FAIL**. Found on the physical
EdgeRouter X during the Phase 5.4 deterministic-failure test. Analysed here from the vendor's
`vyatta-cfg` source. No router state was changed during this analysis.

---

## 1. What was observed

On the physical ER-X, the disposable `vxlan901` was changed from VNI 901 to 902 **and** given `mtu
64` in one commit.

* **Kernel rollback PASSED.** The kernel refused the MTU with `RTNETLINK answers: Invalid argument`.
  The reconciler reported a successful rollback and the interface was restored: VNI 901, UDP port
  4791, MTU 1430, correct IPv6 endpoints, `UP`. Its ifindex changed 27 → 29 (expected — the index is
  not promised across recreation). Unrelated `vxlan900` stayed at ifindex 20 throughout.
* **Configuration atomicity FAILED.** After the failed commit:

  | Where | VNI | MTU |
  |---|---|---|
  | Candidate configuration | 902 | 64 |
  | Active EdgeOS configuration | 901 | **64** |
  | Actual kernel interface | 901 | 1430 |

  The MTU change reached the active configuration even though the commit failed and the kernel was
  rolled back — so the active configuration described an interface that did not exist.
* **Recovery.** Setting the candidate back to VNI 901 / MTU 1430 and committing made the active
  configuration and the kernel consistent again, with **no interface recreation**. That is the
  expected outcome of the mechanism below, not luck: with the identity back in agreement with the
  live interface the reconciler takes its mutable-only path and finds the MTU already correct.

This is recorded as **kernel rollback PASS / full configuration atomicity FAIL**.

## 2. Why it happens — the engine commits per priority subtree, without a transaction

The commit engine is `commit::doCommit()` (`src/commit/commit-algorithm.cpp:1219`, vendor
`vyatta-cfg` source drop for EdgeOS 3.0):

1. It builds the tree of changed nodes and splits it into **priority subtrees**
   (`_get_commit_prio_subtrees`, line 152). Any non-tag node that declares a `priority` becomes its
   own subtree; a child whose priority is not above its parent's triggers a "priority inversion"
   warning and is forced to parent+1.
2. Each subtree is then processed **independently** (`_commit_exec_prio_subtree`, line 657):
   validation first (`_commit_check_cfg_node`, line 508, which runs the `syntax:expression` and
   `commit:expression` checks), then the actions (`_commit_exec_cfg_node`, line 554), and **only if
   both succeed** are that subtree's paths marked committed
   (`cs.markCfgPathCommitted`, lines 682-687).
3. `doCommit` counts successes and failures and, on any failure, prints `Commit failed` and sets
   `COMMIT_STATUS` to **`PARTIAL`** when some subtree succeeded and `FAILURE` when none did
   (lines 1295-1301). `COMMIT_STATUS` is a first-class outcome the config daemon reads
   (`src/ubnt/ubnt-cfgd.cpp:370,497`).
4. **Then it writes the configuration anyway** — `cs.commitConfig(proot)` at line 1312, outside any
   failure check. There is no rollback of the configuration store: the successfully marked subtrees
   are written, the failed ones are not.

So "commit failed" means *the commit was not fully applied*, not *nothing was applied*. Partial
application is designed engine behaviour.

### Why this particular commit drifted

Our templates decide where the boundaries fall:

| Node | `priority` | Consequence |
|---|---|---|
| `interfaces vxlan` (`node.def`) | 459 | its own subtree — contains `vni`, `port`, `local-ip`, `remote-ip` and the **`end:` action that runs the reconciler** |
| `mtu`, `address`, `bridge-group` | 460 | each is its **own sibling subtree**, committed independently of the reconciler |

The failed commit changed exactly two things: `vni` (in the vxlan subtree) and `mtu` (its own
subtree). The sequence was:

1. The **mtu subtree** is checked and executed. Its `update:` action is guarded by
   `vyatta-vxlan-addr identity-matches`, which compares the desired configuration with the live
   interface. At that moment the desired VNI is 902 and the live interface is still 901, so the guard
   is **false**, the action does nothing, and the shell returns success. The subtree is therefore
   **marked committed — MTU 64 enters the active configuration.**
2. The **vxlan subtree** reaches its `end:` action. The reconciler deletes and recreates the
   interface, the kernel refuses `mtu 64`, the reconciler rolls the *kernel* back and exits non-zero.
   The subtree is **not marked committed — VNI 902 never enters the active configuration.**
3. `commitConfig()` writes the partial result. Active configuration: VNI 901, MTU 64. Kernel:
   VNI 901, MTU 1430.

The identity guards that were added to the leaf handlers (so they cannot act out of order) are
exactly what makes the mtu subtree "succeed" here: a guarded no-op is indistinguishable from a
successful application as far as the engine is concerned.

## 3. Answers to the specific questions

### 3.1 Why did MTU 64 enter the active configuration despite the failed commit?

Because the engine commits per priority subtree and does not roll the configuration back. The `mtu`
leaf is its own subtree; its guarded action is a successful no-op during an identity change; so that
subtree was marked committed while the sibling subtree containing the reconciler failed and was not.
`commitConfig()` then wrote the successfully marked part.

### 3.2 Is this expected EdgeOS behaviour, or avoidable in our integration?

**Expected engine behaviour** — partial commit with `COMMIT_STATUS=PARTIAL` is explicitly modelled,
and the write-after-failure at line 1312 is unconditional. It is **not avoidable from inside a
handler**: a handler cannot influence whether sibling subtrees are marked committed.

It **is** avoidable for this class of value, in our integration, by keeping values the kernel can
never apply out of the configuration store in the first place — that is, by rejecting them during the
validation phase, which runs before the subtree's actions and before any marking (§4).

### 3.3 Is complete desired-state prevalidation before mutation the safest solution?

**No, and it would not have prevented this.** Two reasons:

* The drift is caused by a *sibling* subtree being committed independently of our handler.
  Prevalidation inside the reconciler runs after that has already happened, so it cannot undo it.
* Complete prevalidation is impossible in principle: whether the kernel accepts a step can only be
  discovered by attempting it (the rejected value here was accepted by every check we have).

Prevalidation still has value for *blast radius* — a reconciler that can prove the desired state
impossible fails without deleting the live interface — and the reconciler already does that for
everything it can check (endpoints, VNI/port ranges, address canonicalisation, bridge/address
conflict). It is not the fix for configuration drift, and "check everything first" should not be
sold as atomicity.

### 3.4 Could other failure paths leave similar drift?

**Yes — this is a class, not a one-off.** Any commit in which a value that lives in its own priority
subtree changes while the reconciler fails leaves that value active in the configuration and absent
from the kernel. Concretely:

* any reconciler failure during recreation — create, address application, bridge attachment, admin
  state, alias, MTU;
* the **mutable-only path** (`src/vyatta-vxlan:659`), which has no rollback at all: the commit fails,
  the kernel keeps whatever was already applied, and the leaf values are still committed;
* the **DELETE** action path, when interface deletion fails;
* and the mirror image: a guarded leaf action that *is* applied to the kernel in a commit that then
  fails leaves the kernel changed without the configuration reflecting it. That direction is the
  documented mutable-only semantics, and it is the less dangerous one — a later commit re-converges
  it, whereas the configuration-side drift is only visible after a `save` and a reboot.

**Operational consequence, and the reason this matters:** a `save` after a failed commit persists the
drifted value into `/config/config.boot`. On the next boot the boot-time reconciler would refuse the
same value, so the interface would come up without it — silently different from the configuration, at
the worst possible moment.

### 3.5 How to add regression coverage without unrealistic mock semantics?

The mocked harness fakes `ip`; it has no configuration engine, so simulating partial commits there
would test a fiction. Realistic layers, cheapest first:

1. **Template-contract test (off-device, deterministic).** Assert in the template suite that the
   `mtu` lower bound equals the kernel's VXLAN minimum (68), so the 64/68 gap cannot silently
   reappear. This is the regression test for the recommended correction.
2. **Keep the existing mocked rollback scenario.** Mock scenario 25 already pins the reconciler's
   *kernel* rollback for a failed MTU step. That part is covered and should stay.
3. **Static assertion that the reconciler never writes configuration.** Grep-level check that
   `src/vyatta-vxlan*` never calls a configuration-writing API. It documents the rule that the
   integration must not try to paper over the engine, and it is cheap.
4. **Hardware procedure as the honest coverage for engine behaviour.** Partial commits cannot be
   unit-tested off-device. The executable coverage is a documented procedure with an explicit
   post-failure invariant — *active configuration agrees with the kernel, or the drift is recovered*
   — which is now written into Phase 5.4 of the validation runbook, together with the recovery
   commands that were proven on the hardware.

### 3.6 Should the MTU template minimum be tightened from 64 to 68?

**Yes.** It is the smallest correction that removes this drift instance, and it works precisely
because it moves the rejection into the validation phase:

* with the bound at 64, `mtu 64` passes validation, so the mtu subtree is executed and marked
  committed (its guard makes it a no-op) → **configuration drift**;
* with the bound at 68, `mtu 64` fails `_commit_check_cfg_node`, so the mtu subtree is never marked
  committed → **the active configuration keeps its previous value**; the commit still fails, and the
  reconciler still refuses to apply the impossible value.

`68` is the kernel's own bound (`dev->min_mtu = ETH_MIN_MTU` in `vxlan_setup()`; `dev_set_mtu_ext`
rejects anything below), so it is a correctness bound rather than a preference.

## 4. Recommended correction

**Recommended now (smallest robust correction).**

```
templates/interfaces/vxlan/node.tag/mtu/node.def
- syntax:expression: $VAR(@) >= 64 && $VAR(@) <= 8024; "Must be between 64-8024"
+ syntax:expression: $VAR(@) >= 68 && $VAR(@) <= 8024; "Must be between 68-8024"
```

Plus the template-contract test from §3.5.1, and the message updated to match.

**Proposed as a follow-up, needing its own hardware validation — do not bundle.** Consider removing
`priority: 460` from `mtu`, `address` and `bridge-group`. Without their own priority those nodes join
the vxlan node's subtree, so a reconciler failure leaves the whole vxlan configuration uncommitted
instead of half-committed. The action order is unchanged — `_commit_exec_cfg_node` still runs the
children's create/update actions top-down before the parent's `end` action, which is why the identity
guards remain necessary — so this should be a pure change of *commit granularity*. It is not free:
it changes commit grouping for the entire vxlan tree, it cannot be validated off-device, and it does
not help for values outside the vxlan tree.

**Operational rule until then (no code change).** After any failed commit: do **not** `save`.
Compare the active configuration with the kernel and put the correct values back before saving
again; the recovery below was executed successfully on the hardware.

## 5. Limitations of this analysis

* The engine source read here is the vendor GPL drop for **3.0.0-rc.9**. The router runs 3.0.1; the
  observed behaviour matches this code exactly, but line numbers refer to that drop.
* The mechanism is derived from the source plus one observed failure. The `PARTIAL` status itself was
  not captured from the router's own output during the test — the next run of Phase 5.4 should
  capture it.
* The recommended one-line change is **not applied**: it changes validation behaviour, so it needs a
  new package version and a hardware re-run of the affected phases. Applying it would also remove the
  injection Phase 5.4 currently uses, which is why that procedure documents an alternate injection.
* The follow-up proposal (commit granularity) is unvalidated and could change behaviour in ways not
  visible from the source alone.
* Even with both changes, a failed commit can still churn the kernel and can still leave the
  *documented* mutable-only residue. Neither change makes the system atomic; they remove the
  configuration-side drift for values our own validation can bound.
