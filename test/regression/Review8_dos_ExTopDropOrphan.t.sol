// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Review8DosBase} from "./Review8_dos_Base.sol";

/// Review 8 / DoS lens — the NEW O(1) ex-top drop in `_splice` (round-8 code) leaves a
/// bypassed-but-not-zeroed run behind, and the next honest bid lands OUTSIDE the sweep.
///
/// Mechanism, all in `_sync` + `_splice`:
///   - `_sync` calls `_splice(price, w.tau)` TWICE per window with the SAME `hi = price`: once
///     after the gather, once after the pour (the band may have moved, `w.tau` is lower now).
///   - When `hi` is a dead ex-top (`next == 0`, `capTokens == 0` — e.g. the top bidder just
///     withdrew), the FIRST splice takes the O(1) branch: `hi.prev = 0; ticks[tau0].next = 0`.
///   - The pour then kills `tau0` and moves the band to `tau1`. The SECOND splice starts its
///     walk from `ticks[hi].prev`, which is now 0, so it walks NOTHING — and its O(1) branch
///     fires again: `ticks[tau1].next = 0`. The run `tau0 .. X .. tau1` between the two taus is
///     bypassed from `next` but every node in it keeps its `prev`/`next` pointers.
///   - `_linked(tau0)` = `ticks[X].next == tau0` reads TRUE for the stale pair, so a bid at
///     `tau0` skips re-linking, while the live list's `next` chain ends at `tau1`. A bid at any
///     price above `tau1` with the hint the docs tell a UI to compute (walk `next` from the
///     floor: it ends at `tau1`) is inserted at `tau1.next` — and the sweep, which starts at
///     `highestTick = tau0` and walks `prev`, never sees it.
///
/// Everything here is honest: a top bidder withdrawing, an interior tick withdrawing, a small
/// tick exhausting, and two later bids with the documented hint. Round 6 #1/#2 were the same
/// symptom through the OLD bypass-only splice; the fix (zeroing interiors) is what this new
/// branch bypasses again.
contract Review8DosExTopDropOrphan is Review8DosBase {
    uint256 internal constant P1 = FLOOR + 1 * SPACING; // tau1: big, survives
    uint256 internal constant P2 = FLOOR + 2 * SPACING; // Y: the victim's later bid
    uint256 internal constant P3 = FLOOR + 3 * SPACING; // X: dead interior (withdrew)
    uint256 internal constant P4 = FLOOR + 4 * SPACING; // tau0: small, exhausts in the pour
    uint256 internal constant P5 = FLOOR + 5 * SPACING; // H: dead ex-top (withdrew)
    uint256 internal constant P6 = FLOOR + 6 * SPACING;

    address internal a1 = address(0xA1);
    address internal a3 = address(0xA3);
    address internal a4 = address(0xA4);
    address internal a5 = address(0xA5);
    address internal victim = address(0xB0B);
    address internal late = address(0xCA7);

    function setUp() public {
        _deploy(10e18, 0);
        address[6] memory all = [a1, a3, a4, a5, victim, late];
        for (uint256 i; i < 6; ++i) {
            _stakeFor(all[i], 1e18);
        }
        _bid(a1, P1, uint128(101e18), FLOOR); // cap 100 tokens
        _bid(a3, P3, uint128(103e17), P1); // cap 10
        _bid(a4, P4, uint128(104e16), P3); // cap 1
        _bid(a5, P5, uint128(105e17), P4); // cap 10
        assertEq(auction.highestTick(), P5);
    }

    /// Arm the state organically: H and X withdraw, one round elapses, one sync pours
    /// `tau0` dry and moves the band to `tau1`.
    function _arm() internal {
        vm.prank(a5);
        auction.withdrawBid(); // H: dead top, still linked, highestTick stays at P5
        vm.prank(a3);
        auction.withdrawBid(); // X: dead interior, still linked
        assertEq(_cap(P5), 0);
        assertEq(_cap(P3), 0);

        vm.roll(block.number + K);
        auction.sync(64);
        assertEq(_cap(P4), 0, "tau0 exhausted in the pour");
        assertGt(_cap(P1), 0, "tau1 survives");
        assertEq(auction.settleCursor(), 0, "sweep completed");
        assertEq(auction.highestTick(), P1, "high-water shaved to tau1");
    }

    /// The structural claim: after the sweep the `next` chain from the floor and the `prev`
    /// chain agree — no node is bypassed from one side and reachable from the other.
    function test_spliceLeavesNoHalfLinkedRun() public {
        _arm();
        // The list should be floor <-> P1 and nothing else linked.
        assertEq(_next(P1), 0, "P1 is the top of the live list");
        // A node that is not on the live list must be fully unlinked (prev == next == 0).
        // On current code P4 keeps prev = P3 and P3 keeps next = P4: a stale pair.
        assertEq(_prev(P4), 0, "P4 (dead ex-band-top) must be unlinked, not bypassed");
        assertEq(_next(P3), 0, "P3 (dead interior) must be unlinked, not bypassed");
    }

    /// The economic claim: an honest bid at the recent top price (P4) plus an honest bid at
    /// P2 with the documented hint — the P2 bidder is the second-highest live tick, two grid
    /// steps below the top, weight q^2 = 1/4, and must receive a share of the next round.
    function test_honestBidWithDocumentedHintIsOrphaned() public {
        _arm();

        // The hint a UI computes for P2 (walk `next` from the floor): ends at P1.
        uint256 hint = _uiHint(P2);
        assertEq(hint, P1, "documented hint for P2 is P1");
        _bid(victim, P2, uint128(102e18), hint); // cap 100
        assertEq(_next(P1), P2, "P2 linked above P1");

        // A fresh bidder at the recent top price P4. `_linked(P4)` reads true off the stale
        // P3.next pointer, so no re-link happens.
        _bid(late, P4, uint128(104e16), _uiHint(P4)); // cap 1
        assertEq(auction.highestTick(), P4);

        // The sweep starts at highestTick = P4 and walks prev: P4 -> P3 -> P1 -> floor.
        emit log_named_string("P2 on the sweep path", _sweepReaches(P2) ? "yes" : "NO (orphaned)");

        vm.roll(block.number + K);
        auction.sync(64);
        assertEq(auction.settleCursor(), 0, "sweep completed");
        emit log_named_uint("sold this round", auction.tokensSold());
        emit log_named_uint("P4 (late, cap 1) owed", _owed(late));
        emit log_named_uint("P1 (a1, weight 1/8 below P4) owed", _owed(a1));
        emit log_named_uint("P2 (victim, weight 1/4 below P4) owed", _owed(victim));
        // Correct behaviour: P4 (cap 1) dies, band moves to P2: P2 (w=1) vs P1 (w=1/2) -> P2 takes
        // 2/3 of the remaining 9 tokens. On current code P2 gets 0 and P1 takes everything.
        assertGt(_owed(victim), 0, "victim's bid never fills: orphaned from the sweep");
    }

    /// Amplification (round-7 #8 shape on this NEW root cause): with a bounded sale the orphan
    /// is not just starved — its escrow is frozen through the whole settlement tail
    /// (`withdrawBid` reverts `StakeLocked` while `due() != 0`), and when every REACHABLE tick
    /// is dry a full sweep sells 0, `finalize` flips and the carry is destroyed while a live,
    /// staked, funded bid was standing the whole time.
    function test_orphanFreezesEscrowThroughTailThenFinalizeDestroysCarry() public {
        // Same book, bounded life: 5 rounds.
        uint64 end = uint64(block.number + 5 * K);
        _deploy(10e18, end);
        address[6] memory all = [a1, a3, a4, a5, victim, late];
        for (uint256 i; i < 6; ++i) {
            _stakeFor(all[i], 1e18);
        }
        _bid(a1, P1, uint128(101e17), FLOOR); // cap 10 — will run dry
        _bid(a3, P3, uint128(103e17), P1);
        _bid(a4, P4, uint128(104e16), P3); // cap 1
        _bid(a5, P5, uint128(105e17), P4);
        _arm();

        _bid(victim, P2, uint128(102e18), _uiHint(P2)); // cap 100, orphan-to-be
        _bid(late, P4, uint128(104e16), _uiHint(P4)); // cap 1, re-bid at the old top

        // Run out the sale: the reachable book (P4: 1, P1: ~8.9 left) absorbs ~10 of 40.
        vm.roll(end);
        auction.sync(1000);
        emit log_named_uint("due() at endBlock", auction.due());
        emit log_named_uint("victim escrow live", _live(victim));
        emit log_named_uint("victim owed", _owed(victim));

        // The victim cannot leave: the tail is "owed" and the lock holds.
        vm.prank(victim);
        (bool ok,) = address(auction).call(abi.encodeWithSignature("withdrawBid()"));
        emit log_named_string("victim withdrawBid during tail", ok ? "ok" : "REVERTED (StakeLocked)");

        // Anyone finalizes: a full sweep sells 0 -> flips -> due() = 0 forever.
        bool done = auction.finalize(1000);
        emit log_named_string("finalize", done ? "FLIPPED with a live staked bid unfilled" : "not done");
        emit log_named_uint("due() after finalize (carry destroyed)", auction.due());

        assertFalse(done && _owed(victim) == 0, "finalized with a live, staked, funded bid that never filled");
    }

    /// The mirror case: a bid ABOVE the stale run with hint 0 (the contract walks `next` from
    /// the floor itself) lands at `tau1.next`, and a later honest re-bid at the old top P4 is
    /// then orphaned below it.
    function test_rebidAtOldTopIsOrphanedBelowANewTop() public {
        _arm();

        _bid(late, P6, uint128(106e17), 0); // cap 10; contract-side walk ends at P1
        assertEq(_prev(P6), P1, "P6 was inserted directly above P1");
        assertEq(auction.highestTick(), P6);

        _bid(victim, P4, uint128(104e18), _uiHint(P4)); // cap 100 at the old top price
        assertTrue(_sweepReaches(P4), "P4 (live, staked) must be on the sweep path");

        vm.roll(block.number + K);
        auction.sync(64);
        // Correct behaviour: band from P6: P6 (w=1), P4 (d=2, w=1/4), P1 (d=5, w=1/32).
        // P6 gets 10 / 1.28125 * 1 = 7.8 of the 10 -> the rest lands on P4/P1.
        assertGt(_owed(victim), 0, "re-bid at the old top never fills: orphaned from the sweep");
    }
}
