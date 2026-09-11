// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Review8LifecycleBase} from "./Review8_lifecycle_Base.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";

/// REVIEW 8 / lifecycle — the NEW `_splice` (GenerousAuction.sol:811) called twice per sweep
/// iteration with the same `hi` (:756 before the pour, :769 after it).
///
/// `_sync` shaves the walked run twice: from the walk's start down to the band's top BEFORE the
/// pour, and from the SAME start down to the top still standing AFTER the pour (the band may
/// have moved). `_splice(hi, lo)` unlinks the interior by walking `ticks[hi].prev`, then — when
/// `hi` is a dead ex-top (`next == 0 && capTokens == 0`) — drops `hi` in O(1):
/// `hi.prev = 0; ticks[lo].next = 0`.
///
/// When the walk STARTS on a dead ex-top — any withdrawn or un-staked bid above the book, e.g.
/// the previous top bidder pulling out — the first splice drops it. The second splice then finds
/// `ticks[hi].prev == 0`, walks nothing, and re-runs the drop branch against the NEW lower `lo`:
/// it zeroes `ticks[lo].next` without unlinking the ticks that died between the two tops. Those
/// keep `prev`/`next` pointers among themselves and a `prev` INTO the live list, while nothing in
/// the live list points up at them. With two or more of them, `_linked` reads TRUE for the upper
/// one (its lower neighbour — itself half-linked — points at it).
///
/// Downstream, honest bids only: a re-bid at that upper price is seated WITHOUT re-insertion
/// (`_initializeTick`'s early return), and the next bid above it — with the exact hint the live
/// `next` chain gives — links above the live top instead, leaving the re-bid's funded, staked
/// capacity UNREACHABLE by the sweep. The round-6 orphan class (#1/#2), re-opened through the
/// round-7 splice rewrite. In a bounded sale the orphan also re-arms round-7 #8: `finalize`'s
/// "complete sweep sold nothing" short-circuit destroys the victim's carry.
///
/// Found by the lifecycle invariant handler (`Review8_lifecycle_invariants.t.sol`, bounded
/// variant, `--fuzz-seed 12`, shrunk to 8 calls: stake, ridge, stake, bid, bid, ridge, roll, bid).
contract Review8LifecycleDoubleSpliceHalfLink is Review8LifecycleBase {
    address internal ee = address(0xA5);

    function setUp() public {
        _deploy(30e18, 0); // 30 per round: P9 (7) and P7 (5) die, P5 survives -> band moves
    }

    /// bb big at P5; ee small at P7; aa small at P9 (top); cc bids P20 above and withdraws.
    function _book() internal {
        _bidCap(bb, P(5), 250e18, FLOOR);
        _bidCap(ee, P(7), 5e18, P(5));
        _bidCap(aa, P(9), 7e18, P(7));
        _bidCap(cc, P(20), 2e18, P(9));
        vm.prank(cc);
        auction.withdrawBid(); // an honest top-of-book withdrawal: a dead ex-top above the book
        assertEq(auction.highestTick(), P(20));
        assertEq(_cap(P(20)), 0);
    }

    /// FAILS on current code: after one sync the dead band ticks P7 and P9 must be fully
    /// unlinked; instead they keep P7.prev = P5, P7.next = P9, P9.prev = P7 while P5.next == 0.
    function test_BUG_secondSpliceLeavesDeadBandTicksHalfLinked() public {
        _book();
        vm.roll(block.number + K);
        auction.sync(200);

        assertEq(_owed(aa), 7e18, "P9 filled to its cap and died");
        assertEq(_owed(ee), 5e18, "P7 filled to its cap and died");
        assertApproxEqAbs(_owed(bb), 18e18, 1, "P5 took the rest");
        assertEq(auction.highestTick(), P(5), "high-water shaved to the surviving top");

        emit log_named_uint("P20.prev", _prev(P(20)));
        emit log_named_uint("P9.prev", _prev(P(9)));
        emit log_named_uint("P9.next", _next(P(9)));
        emit log_named_uint("P7.prev", _prev(P(7)));
        emit log_named_uint("P7.next", _next(P(7)));
        emit log_named_uint("P5.next", _next(P(5)));

        assertEq(_next(P(5)), 0, "P5 is the top of the live list");
        assertEq(_prev(P(7)), 0, "spliced P7 must be fully unlinked (prev)");
        assertEq(_next(P(7)), 0, "spliced P7 must be fully unlinked (next)");
        assertEq(_prev(P(9)), 0, "spliced P9 must be fully unlinked (prev)");
    }

    /// FAILS on current code: two honest bids after that sync orphan a live, staked, funded
    /// top-of-book position from the sweep — it is never poured while a higher bid stands.
    function test_BUG_honestRebidThenHigherBidOrphansTheTop() public {
        _book();
        vm.roll(block.number + K);
        auction.sync(200);

        // aa refills at P9 (100 more) with the hint a UI reads off the live list — P5 is the
        // top of the `next` chain. `_linked(P9)` is TRUE via half-linked P7: no re-insertion.
        _bid(aa, P(9), uint128(100e18 * P(9) / WAD), P(5));
        assertEq(auction.highestTick(), P(9));
        assertEq(_next(P(5)), P(9), "P9 re-inserted above P5: the run was unlinked, not half-linked");

        // dd bids above, with the exact live-list hint (P5.next == 0 makes P5 a valid hint).
        _bidCap(dd, P(12), 1e18, P(5));
        assertEq(auction.highestTick(), P(12));
        assertEq(_prev(P(12)), P(9), "P12 links above P9 (the stale hint was repaired by the walk)");
        bool reach = _reachable(P(9));
        emit log_named_string("P9 (live, staked, 100 of capacity) reachable from highestTick", reach ? "yes" : "NO");

        // One round: P12 (cap 1) dies, then P9 is the top of book and must take the lion's share
        // of the remaining 29 (weights P9:1, P5:1/16 -> ~27.3 vs ~1.7).
        uint256 aaBefore = _owed(aa);
        uint256 bbBefore = _owed(bb);
        vm.roll(block.number + K);
        auction.sync(200);
        emit log_named_uint("aa (P9, top of book) filled this round", _owed(aa) - aaBefore);
        emit log_named_uint("bb (P5, 4 steps below) filled this round", _owed(bb) - bbBefore);
        assertTrue(reach, "a live staked funded tick must be reachable by the sweep");
        assertGt(_owed(aa) - aaBefore, 27e18, "the top of book takes its q-share");
    }

    /// FAILS on current code — bounded sale: the orphaned top makes the frozen tail's complete
    /// sweep sell nothing once P5 is full, so `finalize` declares the book dead and the victim's
    /// carry is destroyed (`due()` reads 0 forever), with the victim's stake frozen meanwhile.
    function test_BUG_boundedSale_orphanLetsFinalizeDestroyTheTail() public {
        uint64 end = uint64(block.number) + 6 * K;
        _freshMono();
        _deployWith(_config(30e18, end));
        _book();
        vm.roll(block.number + K);
        auction.sync(200);
        _bid(aa, P(9), uint128(1_000e18 * P(9) / WAD), P(5)); // deep, funded for the whole tail
        _bidCap(dd, P(12), 1e18, P(5));
        // bb withdraws the bulk so the reachable book is thin (honest exit).
        vm.prank(bb);
        auction.withdrawBid();

        vm.roll(end);
        uint256 tail = auction.due();
        emit log_named_uint("due() at endBlock", tail);
        bool done;
        for (uint256 i; i < 8 && !done; ++i) {
            done = auction.finalize(400);
        }
        assertTrue(auction.finalized(), "finalize completed");
        emit log_named_uint("tokensSold at finalize", auction.tokensSold());
        emit log_named_uint("aa (P9) owed", _owed(aa));
        emit log_named_uint("due() after finalize (destroyed)", auction.due());
        assertGt(_owed(aa), tail / 2, "the live funded top must receive the frozen tail");
    }

    /// Characterisation of the orphan's exits. `_reseat` lifts `highestTick` only ABOVE the
    /// current mark, so the victim cannot self-recover while a higher bid stands; once that bid
    /// dies (and is dropped, `highestTick` -> P5) the victim's stake move lifts the mark to P9
    /// and it fills — until the next higher bid, which re-orphans it because `P5.next` is 0.
    function test_CHAR_orphanRecoversOnlyUntilTheNextHigherBid() public {
        _book();
        vm.roll(block.number + K);
        auction.sync(200);
        _bid(aa, P(9), uint128(100e18 * P(9) / WAD), P(5));
        _bidCap(dd, P(12), 1e18, P(5));
        vm.roll(block.number + K);
        auction.sync(200); // P12 dies and is dropped; highestTick -> P5
        emit log_named_uint("highestTick after P12 died", auction.highestTick());
        emit log_named_string("P9 reachable", _reachable(P(9)) ? "yes" : "no");
        uint256 owed0 = _owed(aa);

        _stakeFor(aa, 1); // a weight move lifts the mark onto the half-linked chain
        emit log_named_string("P9 reachable after the victim's own stake", _reachable(P(9)) ? "yes" : "no");
        vm.roll(block.number + K);
        auction.sync(200);
        emit log_named_uint("aa filled in the round after re-staking", _owed(aa) - owed0);

        // A fresh higher bid with the live-list hint (P5.next == 0 still) re-orphans it.
        address ff = address(0xA6);
        _bidCap(ff, P(17), 1e18, P(5));
        emit log_named_string("P9 reachable after a fresh higher bid", _reachable(P(9)) ? "yes" : "no");
        assertEq(_prev(P(17)), P(9), "P17 links above P9: nothing to re-orphan");
    }
}
