// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Review8MevBase} from "./Review8_mev_Base.sol";

/// ROUND 8 / mev — the O(1) dead-ex-top drop in `_splice` (NEW at HEAD e84d584, commit
/// "drop dead ex-tops, re-link on reseat") runs TWICE per window when the sweep starts on a
/// dead ex-top: once before the pour (l.756) and once after (l.769). The doc's soundness claim
/// (l.844-847: "Unlinked ticks have prev==0 ... Sound because `_splice` leaves no stale
/// pointers") assumes the interior of every walked dead run is unlinked. It is not, on this path:
///
///   - The first call `_splice(cursor, tauBefore)` finds `cursor` a dead ex-top (`next==0,
///     capTokens==0`) and takes the DROP branch: `cursor.prev = 0`, `tauBefore.next = 0`. Only
///     the run above `tauBefore` was unlinked (empty here).
///   - The pour then MOVES the band: its top `tauBefore` dries, a lower tick is admitted, and
///     `w.tau` ends at `tauAfter < tauBefore`, with dead ticks left BETWEEN them.
///   - The second call `_splice(cursor, tauAfter)` finds `cursor.prev == 0` (already dropped),
///     so its interior-unlink loop never runs; it drops again, writing `tauAfter.next = 0`.
///
/// The dead run strictly between `tauAfter` and `tauBefore` is never walked by either splice and
/// keeps its `prev`/`next` pointers. Its top then satisfies `_linked` (its dead lower neighbour
/// still points up at it) while being unreachable from the floor — exactly the stale-linked node
/// the round-8 splice rewrite was meant to make impossible, and the seed of the round-6/7 orphan
/// cluster (dossier A/A′), here through code those dossiers never saw.
///
/// Reached organically: a top bid that fills exactly a round (dead ex-top, book absorbs the
/// round so `due()==0`), then honest bids seated below it in the same block, then one ordinary
/// sync a round later in which two of them exhaust and one survives.
contract Review8MevDeadTopDoubleSpliceTest is Review8MevBase {
    address internal A = address(0xA1); // top; fills exactly the round -> dead ex-top
    address internal B = address(0xA2); // dies this pour (band's first top)
    address internal D = address(0xA3); // dies this pour (interior, between tops)
    address internal C = address(0xA4); // survives (band's final top)

    function setUp() public {
        _deploy(100e18, 0); // emission 100/round == A's cap, so the first round leaves due()==0
    }

    /// Drive the book into the corrupt state and return.
    function _corrupt() internal {
        _stakeFor(A, 1e18);
        _bid(A, P(9), uint128(109e18), FLOOR); // cap 100 tokens at 1.09 == the whole round
        vm.roll(block.number + K);
        auction.sync(64);
        assertEq(_owed(A), 100e18, "A absorbed the whole round");
        assertEq(auction.due(), 0, "round fully absorbed: nothing carries");
        assertEq(auction.highestTick(), P(9), "dead ex-top holds the high-water");
        assertEq(_next(P(9)), 0, "A's tick is the list top and dead");

        // Seat three bids below the dead top, all in this same block (due()==0 -> no pour).
        _stakeFor(B, 1e18);
        _stakeFor(D, 1e18);
        _stakeFor(C, 1e18);
        _bid(B, P(7), uint128(535e16), _hint(P(7))); // cap 5
        _bid(D, P(6), uint128(53e17), _hint(P(6))); // cap 5
        _bid(C, P(5), uint128(1050e18), _hint(P(5))); // cap 1000
        // Chain intact before the corrupting sync.
        assertTrue(_reachableFromFloor(P(5)) && _reachableFromFloor(P(6)) && _reachableFromFloor(P(7)));
        assertEq(auction.highestTick(), P(9), "high-water still the dead ex-top");

        // One ordinary sync a round later: 100 due, band starts at P7, moves P7->P6->P5.
        vm.roll(block.number + K);
        auction.sync(64);
        assertEq(_owed(B), 5e18, "B exhausted (first band top)");
        assertEq(_owed(D), 5e18, "D exhausted (interior, between the two tops)");
        assertGt(_live(C), 0, "C survived (final band top)");
    }

    /// BUG-FORM. The list-soundness invariant the doc asserts: no tick is `_linked` while off the
    /// live list. The double drop leaves P7 stale-linked and unreachable from the floor.
    function test_bug_doubleDrop_leavesStaleLinkedDeadTick() public {
        _corrupt();

        emit log_named_uint("P7 next", _next(P(7)));
        emit log_named_uint("P7 prev", _prev(P(7)));
        emit log_named_uint("P6 next", _next(P(6)));
        emit log_named_uint("P6 prev", _prev(P(6)));
        emit log_named_uint("P5 next", _next(P(5)));
        emit log_named_uint("highestTick", auction.highestTick());
        emit log_named_uint("P7 _linked?", _linkedView(P(7)) ? 1 : 0);
        emit log_named_uint("P7 reachableFromFloor?", _reachableFromFloor(P(7)) ? 1 : 0);

        assertFalse(
            _linkedView(P(7)) && !_reachableFromFloor(P(7)),
            "a tick reads _linked while off the live list: _splice left stale pointers (doc l.844-847 violated)"
        );
    }

    /// BUG-FORM, the material consequence. An honest newcomer bids at the stale-linked price with
    /// the exact floor-walked hint. Because P7 reads `init && _linked`, `_initializeTick` returns
    /// early and seats the bid at the orphaned tick WITHOUT re-linking it onto the floor chain —
    /// the round-6 orphan (dossier A) resurrected through the new drop path. It then fills only
    /// by re-exposing the stale run into the sweep (submitBid raises `highestTick` to P7 and the
    /// sweep walks the stale `prev` chain), which is exactly the reachability corruption the
    /// splice rewrite claims to prevent. We assert the clean property: a freshly-bid, funded,
    /// staked tick must be reachable from the floor right after the bid.
    function test_bug_bidAtStaleLinkedPrice_isOrphaned() public {
        _corrupt();
        address E = address(0xB1);
        _stakeFor(E, 1e18);
        // hint = exact predecessor by the documented floor walk.
        _bid(E, P(7), uint128(1070e18), _hint(P(7))); // cap ~1000 at 1.07

        emit log_named_uint("after E bids P7: highestTick", auction.highestTick());
        emit log_named_uint("P7 prev (stale?)", _prev(P(7)));
        emit log_named_uint("E reachableFromFloor?", _reachableFromFloor(P(7)) ? 1 : 0);

        assertTrue(
            _reachableFromFloor(P(7)),
            "E's funded staked bid must sit on the live list; it was seated at an orphaned tick instead"
        );
    }
}
