# Regression suite for the round-6/7 review findings of `GenerousAuction.sol`

Every test here pins a defect found by the two tests-first review rounds (57 findings, dossiers in
the research repo) and asserts the *correct* behaviour. The suite was committed RED on
`staking-hardening` (`764b051`: 21 failing tests) and turned green defect by defect on the fix
branch; it stays as the regression net. Tests that used to assert the buggy intermediate state
were rewritten to the fixed expectation, scenarios unchanged.

```
forge test --match-path 'test/regression/*'
```

Every scenario uses the deploy script's own parameters (floor 1.00, tick 1e16, q = 1/2, window 8,
`emissionPerRound` 50-100 MONO per 100 blocks) unless the test is *about* a parameter.

## Map: defect -> test (all green after the fixes)

### A. Tick-list splice leaves stale interior links (blocker)

| Test | Failing function | Scenario | Adversary |
| --- | --- | --- | --- |
| `Review7_organic_selfLoopBrick` | `test_honestRebidSelfLoopsTheBookAndBricksEverything` | 5 bidders, 4 small seats exhaust, two honest re-bids at old prices with the hint the book itself shows: `ticks[p].prev == p`, every entry point panics 0x32 forever | none |
| `Review7_organic_unbiddablePrices` | `test_oldPriceHasNoUsableHint` | Same book one step earlier: an initialised price has no hint that is accepted without corrupting the list | none |
| `Review6_integration_splicedHintOrphan` | `test_splicedTickAcceptedAsPrevHint`, `test_orphanedTickNeverFills` | Two bidders withdraw, one sync splices; a bid using the event-derived hint is accepted instead of `BadPrevHint`, and a later correct re-insert orphans it | none |
| `Review6_storage_staleRidgeOrphan` | `test_orphan_bidAtSplicedInteriorPriceIsNeverPoured`, `test_orphan_staleTopHidesHonestLiveTick` | Re-bid at a spliced interior price with the correct live-list hint: accepted, never linked, never poured; as `highestTick` it hides a live tick below | ridge built by bid+withdraw (any user) |
| `Review6_storage_ridgeReexposure` | `test_ridgeReexposure_oneDustBidRewalksWholeRidge` | One dust bid at a stale interior node re-exposes a 1000-tick dead ridge to every sweep and locks bids out with `SettleFirst` | yes (cheap) |
| `Review7_chain_orphanFinalizeDestroysCarry` | `test_chain_finalizeDestroysHiddenCarry` | Orphaned `highestTick` makes a full sweep sell nothing; `finalize` flips and the hidden live tick's emission is destroyed | yes |

### B. Fixed window band is not shift-invariant

| Test | Failing function | Scenario | Adversary |
| --- | --- | --- | --- |
| `Review7_fairness_syncCadence` | `test_cadenceChangesAllocation` | Top tick dries; a tick just under the band gets 0 with one sync and 29.67% with per-block syncs | none |
| `Review6_whale_dust-top-excludes-band` | `test_strategy_dustTopStarvesHonestTick` | A 2-wei dust bid `windowTicks` above the whale pushes the honest tick out of the band: 1/3 -> 0 | yes (2 wei) |
| `Review7_config_narrowBandPriority` | `test_twoWeiSpacing_turnsGenerousIntoPriority` | `tickSpacing = 2 wei` is accepted; the band is 16 wei and a +18 wei bid takes 100% | none (config) |

### C. Rounding direction: escrow shortfall

| Test | Failing function | Scenario | Adversary |
| --- | --- | --- | --- |
| `Review7_rounding_integralPriceShortfall` | `test_oneRound_atFloor_bricksEveryClaim`, `test_oneRound_atFloor_claimReverts` | Three bidders at the 1.00 floor, one round, all withdraw: `currencyRaised` exceeds escrow by 2 wei, `mintPack` and every `claim` revert until someone donates | none |
| `Review7_rounding_pourClampReachable` | `testFuzz_sumOfFloorsClaim` | The "unreachable" budget clamp in `_pour` binds on ~1 in a few hundred windows and shorts the lowest tick | none |

### D. Keeper / succession

| Test | Failing function | Scenario | Adversary |
| --- | --- | --- | --- |
| `Review6_keeper_zero-budget-sync-parks-cursor` | `test_zeroBudgetSyncBlocksBids` | `sync(0)` parks the cursor with no work; the next bid fast-fails `SettleFirst` | yes (~30k gas/block) |
| `Review6_succession_runbook_finalized_is_not_packed` | `test_runbookFollowedLiterally_claimStillBricks` | Following the succession runbook literally revokes the predecessor's minter role before its finalize-sold tail is packed; every claim reverts | none (operator) |

### E. Constructor sanity checks

| Test | Failing function | Scenario |
| --- | --- | --- |
| `Review7_config_staleStartBlock` | `test_BUG_staleStart_wholeSaleDueAtDeploy` | `startBlock` 2.3 days in the past: 100% of `saleSupply` is due at deploy |
| `Review7_config_roundLongerThanLife` | `test_BUG_adminRescheduleNeverTakesEffect` | `roundBlocks` longer than the sale: `setRoundParams` queues past `endBlock` forever |
| `Review7_config_unbiddableFloor` | `test_BUG_constructorAcceptsFloorBelowNavOverMaxMultiple` | `floor * 1e4 < nav()`: no price is biddable |
| `Review7_config_emissionExtremes` | `test_BUG_zeroEmissionAccepted`, `test_BUG_maxEmissionSentinel_secondRescheduleReverts` | `emissionPerRound = 0` accepted; `uint128.max` bricks `setRoundParams` after one change |

## Round 8 (tests-first review of the fixes themselves; committed RED, now green)

Fixed in `a9d0b79`: one `_splice` per window (after the pour, never twice); `_claim` re-seats after
harvesting; `finalize` propagates every pack failure except the revoked-role error; `previewWindow`
walks every window the sync would; moving an exhausted position to another price needs the owner.
The rows below keep their original scenarios with the assertions flipped to the fixed behaviour.

| Test | Failing function(s) | Scenario | Adversary |
| --- | --- | --- | --- |
| `Review8_access_spliceStaleRun` | `test_doubleSpliceLeavesStalePointers`, `test_honestBidOnForkIsNeverPoured`, `test_forkPersistsAndStrandsAfterTopDies` | The post-pour `_splice` starts from the `prev` the pre-pour dead-top drop already zeroed: dead ticks between the old and new band top stay half-linked, a re-bid at the old top passes `_linked`, a higher bid forks the list, an honest bid in the gap is never poured | none |
| `Review8_dos_ExTopDropOrphan` | `test_spliceLeavesNoHalfLinkedRun`, `test_honestBidWithDocumentedHintIsOrphaned`, `test_rebidAtOldTopIsOrphanedBelowANewTop`, `test_orphanFreezesEscrowThroughTailThenFinalizeDestroysCarry` | Same root; the victim uses the documented floor-walk hint; in a bounded sale finalize destroys its tail | none |
| `Review8_lifecycle_doubleSpliceHalfLink` | `test_BUG_secondSpliceLeavesDeadBandTicksHalfLinked`, `test_BUG_honestRebidThenHigherBidOrphansTheTop`, `test_BUG_boundedSale_orphanLetsFinalizeDestroyTheTail` | Same root; a live top-of-book tick with 100 MONO of capacity becomes unreachable | none |
| `Review8_mev_DeadTopDoubleSplice` | `test_bug_doubleDrop_leavesStaleLinkedDeadTick`, `test_bug_bidAtStaleLinkedPrice_isOrphaned` | Same root reached by four honest bidders in the block a sync zeroed `due()` | none |
| `Review8_accounting_claimCapShrink` | `test_singleSeat_claimShrink_currencyDeficit`, `test_singleSeat_claimShrink_bricksClaims`, `test_singleSeat_claimShrink_bricksWithdraw` | A plain `claim` harvests without `_reseat`; the ceil charge shrinks real capacity a wei below the seat; the next pour books a phantom wei; at a single-seat tick and price >= ~2.5 the pot goes short | none |
| `Review8_reentrancy_FinalizePackGrief` | `test_finalizedMeansPacked_forEveryStipend_mainnetGuard`, `test_noWindow_mainnetGuard_afterFix` | `try this.mintPack()` in `finalize` swallows the inner out-of-gas: on chainid 1 a 64k-gas band of stipends finalizes without packing | keeper gas limit (chainid 1 only) |
| `Review8_lifecycle_finalizeGasWindow` | `test_BUG_mainnet_finalizeAtEstimateGasDoesNotPack` | Same, measured from the estimator's side | chainid 1 only |
| `Review8_lifecycle_previewMultiWindow` | `test_BUG_previewOmitsTheWindowsBelowADriedStretch` | `previewWindow` runs one `_solveBand` stretch; when it dries with supply left the windows the same-block sync pours are missing | none |
| `Review8_lifecycle_dustPackStuck` | `test_CHAR_oneWeiBookingIsNeverPackable_checkpointIsOneNavWei` | A sub-NAV-wei booking never packs; as the last pour it leaves the runbook checkpoint unreachable by a wei | none |
| `Review8_access_thirdPartyRebind` | `test_strangerCannotRebindExhaustedPosition` | A stranger re-binding another owner's exhausted position (out of band, or at the top of the range on the victim's stake) reverts `Unauthorized`; the owner's own move goes through | yes (1 wei) |
| `Review8_arithmetic_solverModel` | (all PASS) | Regression net: the moving-band solver against an independent O(n^2) model, 0 wei, rescale included | — |

The invariant suite's `invariant_tickListSound` now also walks `next` from the floor and rejects
half-linked nodes, and the handler drives a 12-price grid spanning 22 grid steps (wider than the
8-step band) so bands move and dead ex-tops pile up — the shapes round 8 broke on.
`Regression_claimReseatEdges` pins the edges of the new re-seat inside `claim`.

## Round 9 (narrow review of the tick-list machinery; permanent checkers)

No medium-or-worse finding: three independent lenses built their own two-chain checkers and drove
them over ~26k randomised calls plus every hand-built splice edge case without a single
disagreement. Those checkers are kept here as the permanent net for this machinery — run them
after ANY change to `_splice`, `_sync`'s window loop, `_initializeTick`, `_predecessor` or
`_reseat`:

| Test | What it guards |
| --- | --- |
| `Review9_links_ListInvariant`, `Review9_links_DeepBook`, `Review9_links_Parked` | 21 predicates over both chains (monotone, mutually linked, terminates at the floor, sweep chain ⊆ floor chain, capacity always on the sweep chain, nothing with capacity above `settleCursor`), driven at three book shapes including one where every sync truncates |
| `Review9_sweep_Invariant`, `Review9_sweep_Exits` | Every one of the eight exits of `_sync`'s window loop leaves `w.tau` on `price`'s `prev` chain and never unlinks a tick with capacity |
| `Review9_hints_invariant`, `Review9_hints_adversarialHint` | Ten adversarial hint forms (0, the price itself, above, `highestTick`, `settleCursor`, spliced-out, misaligned, stale) never produce an out-of-order insert, self-link or cycle |
| `Review9_hints_parkedCursor` | The permissionless `claim`'s re-seat cannot add capacity above a parked cursor |
| `Review9_links_RidgeScale`, `Review9_links_Scenarios` | A window's dead band is unlinked once it runs dry (the round-9 fix) |
| `Review9_hints_predecessorWalk` | Characterises what the `next` chain still holds: the live book plus whatever no sweep has reached, ~2.3k gas per node to a hintless bid |

## Rounds 10-13 (parallel session, folded in)

A second session ran four more rounds against `1b591db` and made one contract change; its findings
and tests are here. Its full write-ups are in the research repo
(`experiments/monolithic-review10-13/`).

| Test | What it covers |
| --- | --- |
| `Review10_auctionownership` | **Owner-only bids.** `submitBid` now requires `owner == msg.sender` for every bid. The round-8 rule only guarded a price change on an existing position, which left the FIRST bid and any bid after a `withdrawBid` open (`p.price == 0` in both), so a stranger could pick the price on someone else's stake. A narrower rule cannot work either: a same-price top-up restores `live != 0` and re-arms `BidExists` against the owner's own move. |
| `Review11_schedule` | `roundsElapsed()` counted under whatever `roundBlocks` was stored, so it over-counted across a length change and jumped when an admin queued something in the same block. Fixed by carrying completed rounds at the anchor; `Regression_roundsElapsed` adds a differential check against a per-generation model. |
| `Review11_cadence` | Cadence exactness is a property of `q`: exact for a power of one half (81 wei over a 96-price book), a relative error otherwise (6 parts per trillion at `q = 0.6`, `windowTicks = 64`). Characterisation with the bound, not a defect. |
| `Review11_accounting`, `Review11_arithmetic`, `Review11_lifecycle` | Negative results: 256-scenario conservation walks, deep books at four `q` values, 140-participant finalization across the death budget. |
| `Review12_*` | Negative results: external-call failure rollbacks, role revoke and restore, an independent intra-tick model, submission-order independence, an independent per-block emission model, `q = 1` with 255 window ticks. |
| `Review13_dos` | 512 withdrawn prices block user operations with `SettleFirst` until a separate settle; recovery via `sync(0)` (floored to 128), `sync(1024)` and `finalize(128)` all verified. Temporary, not a permanent halt. |

## Round 14 (the code rounds 8-13 wrote, reviewed by others)

Five lenses with the full history plus one deliberately without it. The headline was a regression in
round 9's own splice fix, now closed by construction.

| Test | What it guards |
| --- | --- |
| `Review14_splice_resumeMark`, `Review14_splice_prevalence`, `Review14_splice_edges` | `_splice` must never unlink a tick that still has capacity. The round-9 bound `w.resume` could land under a funded top-of-book bid: `_solveBand` keys a tick whose capacity outran the supply at `min(cap, supply)` and calls it dead-in-model, while per-segment flooring can reach its key without latching `drained`. The prevalence grid drove 64 (dAB, dBW) cells — 23 stranded the whale before the fix, 0 after |
| `Review14_preview_gas` | `previewWindow` allocated two fresh arrays per window, making memory O(W^2) and gas ~O(W^4): 640 windows cost 562M and a node's `eth_call` cap broke at ~245. Growth is amortised now; the same book is 26.4M |
| `Review14_schedule_frozen` | A bounded life of exactly one round is refused at deploy — it used to be accepted and left `setRoundParams` frozen for the whole sale, with `admin` immutable |

Accepted as characterised, not fixed: `sync` is not idempotent within a block (one wei of carry to
the top tick), a claim costs the claimer up to one token-wei of its own capacity (the round-8
re-seat re-derives capacity from ceil-charged escrow), and the two `previewWindow` caveats now in
its NatSpec (the per-tick figure is not a stake-proportional split, and the view is unbudgeted while
a sync is not).

## Not in this suite

Pause-leak (re-armable sybils, round-6 #6/#10), heap-depth gas, pooled-pack haircuts and the carry
ponytails are **characterisations** (they pass with measured numbers) and live in
`experiments/monolithic-review6` / `-review7` of the research repo, together with the organic
population simulations (need `--gas-limit 1000000000000 --threads 1`) and the 10k-pour rounding
drift measurements. Promote one here by flipping its assertion once the behaviour is declared a bug.
