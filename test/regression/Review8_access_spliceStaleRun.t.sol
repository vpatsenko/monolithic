// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Review8AccessBase} from "./Review8_access_Base.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";

/// Round-8 / access lens, NEW code: `_splice` is called twice per sync window — before the pour
/// (`_splice(price, w.tau)`) and after it, with `w.tau` moved down by the band-move
/// (`_splice(price, w.tau2)`). Both start their clearing walk at `ticks[price].prev`. When the
/// first call DROPS `price` (a dead ex-top: `next == 0 && capTokens == 0`) it zeroes
/// `ticks[price].prev` — so the second call walks nothing, and only sets `ticks[tau2].next = 0`.
/// The run that died in the pour (old `tau` and every dead-but-linked node between it and
/// `tau2`) keeps its `prev`/`next` pointers: exactly the "bypassed, not unlinked" state the
/// round-7 fix was meant to eliminate.
///
/// Reached organically: the top-of-book bidder withdraws (or unstakes to zero) — a dead ex-top
/// with `next == 0` that the next sync starts from — and that sync's pour kills the new top with
/// an already-dead interior tick still linked below it. Then a bid at the old top price passes
/// `_linked` via the stale interior node and is seated WITHOUT re-linking, `highestTick` rises to
/// it, and every later bid inserted through the live `next` chain (correct hint, `prev == tau2`)
/// sits on a fork the sweep's `prev` walk never visits.
contract Review8_access_spliceStaleRun is Review8AccessBase {
    address internal A = address(0xA1); // top of book, withdraws
    address internal B = address(0xA2); // second tick, dies in round 2
    address internal C = address(0xA3); // interior tick, dies in round 1 and stays linked
    address internal D = address(0xA4); // survivor
    address internal E = address(0xA5); // re-bids at the old top price
    address internal F = address(0xA6); // the victim: honest bid, correct hint, never poured

    function setUp() public {
        _deploy(40e18, 0);
    }

    /// Build the pre-condition: highestTick on a dead ex-top (A withdrew at P5), P4 live with a
    /// cap that dies under one round, P3 dead-but-linked, P1 live and deep.
    function _buildStaleRun() internal {
        _stakeFor(D, 1e18);
        _bid(D, P1, 1010e18, FLOOR); // cap 1000
        _stakeFor(C, 1e18);
        _bid(C, P3, uint128(103e16), P1); // cap 1: dies in round 1, stays linked below tau
        _stakeFor(B, 1e18);
        _bid(B, P4, uint128(208e17), P3); // cap 20: survives round 1, dies in round 2
        _stakeFor(A, 1e18);
        _bid(A, P5, 1050e18, P4); // cap 1000: the top

        _round(); // P3 dies (interior, below tau: NOT spliced). P5/P4/P1 survive.
        assertEq(_cap(P3), 0, "P3 exhausted in round 1");
        assertEq(_next(P3), P4, "...and is still linked (below the top, never in a walked run)");
        assertEq(auction.highestTick(), P5);

        vm.prank(A);
        auction.withdrawBid(); // honest exit at the top: P5 dead, highestTick still P5, P5.next == 0
        assertEq(_cap(P5), 0);
        assertEq(auction.highestTick(), P5, "high-water still on the dead ex-top");

        _round(); // walk starts at P5 (dead): splice #1 drops P5; pour kills P4; band moves to P1;
        // splice #2 starts at ticks[P5].prev == 0 and clears nothing.
        assertEq(_cap(P4), 0, "P4 exhausted in round 2");
        assertEq(auction.highestTick(), P1, "high-water shaved to the surviving top");
    }

    /// Characterisation of the pointer state after the double splice: the dead run P4 -> P3
    /// still points at itself, P1.next is 0, and `_linked(P4)` (as `_initializeTick` reads it)
    /// is TRUE through the stale interior node. FAILS on current code (asserts the sound state).
    function test_doubleSpliceLeavesStalePointers() public {
        _buildStaleRun();
        assertEq(_next(P1), 0, "P1 is the list top now");
        // The sound state `_splice` promises: every interior node of a walked dead run is
        // UNLINKED (prev = next = 0).
        assertEq(_next(P3), 0, "dead interior P3 must be unlinked: next");
        assertEq(_prev(P3), 0, "dead interior P3 must be unlinked: prev");
        assertEq(_prev(P4), 0, "dead ex-top P4 must be unlinked: prev");
    }

    /// The consequence, bug-form: F bids at P2 through the live `next` chain with the CORRECT
    /// hint (P1, whose next is 0), E re-bids at the old top P4 (accepted as linked via the stale
    /// P3.next). The sweep walks P4 -> P3 -> P1 and never visits P2. F earns nothing while P1,
    /// a lower price, is served. FAILS on current code.
    function test_honestBidOnForkIsNeverPoured() public {
        _buildStaleRun();

        _stakeFor(E, 1e18);
        _bid(E, P4, uint128(52e18), P1); // "the price that was top last round": cap 50
        assertEq(auction.highestTick(), P4);

        _stakeFor(F, 1e18);
        _bid(F, P2, uint128(51e18), P1); // correct hint per the next-chain: cap 50
        assertEq(_prev(P2), P1, "inserted above P1 on the next chain");
        assertEq(_next(P1), P2);
        assertTrue(_nextChainReaches(P2), "hint walk reaches P2");

        // The sweep's own walk (prev from highestTick) does not.
        emit log_named_string("P2 on the sweep's prev-walk", _sweepReaches(P2) ? "yes" : "no");
        emit log_named_uint("sweep walk: highestTick", auction.highestTick());
        emit log_named_uint("sweep walk: prev(P4)", _prev(P4));
        emit log_named_uint("sweep walk: prev(P3)", _prev(P3));

        _round(); // 40 tokens; honest split P4:P2:P1 = 1 : 1/4 : 1/8 -> P2 should get ~7.27
        emit log_named_uint("owed(E) at P4 (honest 29.09e18)", _owed(E));
        emit log_named_uint("owed(F) at P2 (honest 7.27e18)", _owed(F));
        emit log_named_uint("owed(D) at P1 (honest 3.64e18 + earlier rounds)", _owed(D));
        assertGt(_owed(F), 0, "honest bid at P2 with a correct hint is never poured");
        assertApproxEqAbs(_owed(F), 7272727272727272727, 1e15, "P2's q^2 share of the round");
        assertTrue(_sweepReaches(P2), "the sweep must reach a live tick between its top and P1");
    }

    /// Same fork, opposite order (victim first, re-bid second): still orphaned. And once the
    /// re-bid at P4 exhausts, the next splice cuts P1.next again, leaving P2 seated, live, and
    /// UNLINKED — un-poured until its owner happens to touch stake (which re-links). FAILS.
    function test_forkPersistsAndStrandsAfterTopDies() public {
        _buildStaleRun();

        _stakeFor(F, 1e18);
        _bid(F, P2, uint128(51e18), P1);
        _stakeFor(E, 1e18);
        _bid(E, P4, uint128(30e18), P1); // cap ~28.8: dies within one round

        _round();
        uint256 owedF1 = _owed(F);
        assertEq(_cap(P4), 0, "E's re-bid exhausted");
        // After P4 died the band moved to P1 and splice #2 cut P1.next: P2 is off both walks.
        bool onNext = _nextChainReaches(P2);
        bool onSweep = _sweepReaches(P2);
        emit log_named_uint("owed(F) after round 3", owedF1);
        emit log_named_string("P2 on next-chain", onNext ? "yes" : "no");
        emit log_named_string("P2 on sweep walk", onSweep ? "yes" : "no");

        _round();
        assertGt(_owed(F), 0, "a seated, staked, funded bid must be poured within two rounds");
    }

    /// Self-heal characterisation (PASSES): the victim's own 1-wei stake touch runs `_reseat`,
    /// which re-links the unlinked tick — but nothing tells the victim to do it.
    function test_victimStakeTouchRelinks() public {
        _buildStaleRun();
        _stakeFor(F, 1e18);
        _bid(F, P2, uint128(51e18), P1);
        _stakeFor(E, 1e18);
        _bid(E, P4, uint128(30e18), P1);
        _round();
        _round();
        uint256 before = _owed(F);

        _stakeFor(F, 1); // any stake move: `_reseat` sees `!_linked(P2)` and walks to re-link
        _round();
        emit log_named_uint("owed(F) before the touch", before);
        emit log_named_uint("owed(F) one round after", _owed(F));
        assertGt(_owed(F), before, "re-linked by the stake touch, poured again");
    }
}
