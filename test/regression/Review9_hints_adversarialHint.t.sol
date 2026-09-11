// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Review9HintsBase} from "./Review9_hints_Base.sol";

/// Round-9 `hints` lens: every hint an adversary or a confused UI could pass, at every list
/// shape reachable without a keeper. The structural checker in the base walks BOTH chains and
/// asserts they agree as sets, that every tick with capacity is on both, and that neither walk
/// can be out of order or non-terminating.
contract Review9HintsAdversarialHint is Review9HintsBase {
    address internal constant A = address(0xA1);
    address internal constant B = address(0xB1);
    address internal constant C = address(0xC1);
    address internal constant D = address(0xD1);
    address internal constant E = address(0xE1);
    address internal constant F = address(0xF2);

    uint256 internal P0;
    uint256 internal P2;
    uint256 internal P4;
    uint256 internal P6;
    uint256 internal P8;
    uint256 internal P10;
    uint256 internal P12;
    uint256 internal P20;

    function setUp() public {
        _deploy(40e18, 0);
        P0 = FLOOR;
        P2 = FLOOR + 2 * SPACING;
        P4 = FLOOR + 4 * SPACING;
        P6 = FLOOR + 6 * SPACING;
        P8 = FLOOR + 8 * SPACING;
        P10 = FLOOR + 10 * SPACING;
        P12 = FLOOR + 12 * SPACING;
        P20 = FLOOR + 20 * SPACING;
        _stakeFor(A, 20e18);
        _stakeFor(B, 20e18);
        _stakeFor(C, 20e18);
        _stakeFor(D, 20e18);
        _stakeFor(E, 20e18);
        _stakeFor(F, 20e18);
    }

    /// EMPTY BOOK (floor only). Every hint form must still seat the bid in order.
    function test_emptyBook_everyHint() public {
        uint256[] memory g = _grid(32);
        // hint 0
        _bid(A, P4, 20e18, 0);
        _checkList(g, "empty/hint0");
        assertEq(_next(FLOOR), P4, "empty/hint0: floor.next");
        // hint = the price itself (self-link attempt)
        _bid(B, P8, 20e18, P8);
        _checkList(g, "empty/hintSelf");
        assertEq(_prev(P8), P4, "hintSelf: out of order");
        // hint ABOVE the price
        _bid(C, P6, 20e18, P8);
        _checkList(g, "empty/hintAbove");
        assertEq(_prev(P6), P4, "hintAbove: wrong predecessor");
        assertEq(_next(P6), P8, "hintAbove: wrong successor");
        // hint = a never-initialised price
        _bid(D, P2, 20e18, FLOOR + 3 * SPACING);
        _checkList(g, "empty/hintUninit");
        assertEq(_prev(P2), FLOOR, "hintUninit: wrong predecessor");
        assertEq(_next(P2), P4, "hintUninit: wrong successor");
        // hint = highestTick (which is ABOVE the new price)
        _bid(E, P10, 20e18, auction.highestTick());
        _checkList(g, "empty/hintHighest");
        // hint = floor for a price far above
        _bid(F, P20, 20e18, FLOOR);
        _checkList(g, "empty/hintFloor");
        assertEq(_prev(P20), P10, "hintFloor: wrong predecessor");
    }

    /// A SPLICED RUN: build a ridge, kill it, sync so the sweep unlinks it, then bid back into
    /// the dead run with the stale hint a UI read a block earlier.
    function test_splicedRun_staleHint() public {
        uint256[] memory g = _grid(32);
        _bid(A, P2, 20e18, FLOOR);
        _bid(B, P4, 20e18, P2);
        _bid(C, P6, 20e18, P4);
        _bid(D, P8, 20e18, P6);
        _checkList(g, "built");

        // Kill the top three; only P2 keeps capacity.
        vm.prank(B);
        auction.withdrawBid();
        vm.prank(C);
        auction.withdrawBid();
        vm.prank(D);
        auction.withdrawBid();
        _checkList(g, "killed");

        vm.roll(block.number + K);
        auction.sync(256);
        _checkList(g, "swept");
        // The run P4..P8 is unlinked now.
        assertEq(_prev(P8), 0, "P8 still linked");
        assertEq(_next(P2), 0, "P2.next not cleared");

        // A stale hint pointing INTO the dead run.
        _bid(E, P6, 20e18, P4);
        _checkList(g, "rebid into dead run, hint P4");
        assertEq(_prev(P6), P2, "P6 seated out of order");

        // A hint that is an unlinked init tick, for a price above it.
        _bid(F, P10, 20e18, P8);
        _checkList(g, "hint = unlinked init tick");
        assertEq(_prev(P10), P6, "P10 seated out of order");
    }

    /// HALF-DROPPED EX-TOP: the O(1) drop in `_splice` leaves `hi` unlinked with `init` true and
    /// `ticks[lo].next == 0`. Bid at the dropped price, and at prices around it, with every hint.
    /// The exact predecessor of `price` on the live list: what a correct insert must produce.
    function _livePredecessor(uint256 price) internal view returns (uint256 q) {
        q = FLOOR;
        while (true) {
            (uint256 nx,,,,,,) = auction.ticks(q);
            if (nx == 0 || nx >= price) return q;
            q = nx;
        }
    }

    function test_droppedExTop_everyHint() public {
        uint256[] memory g = _grid(32);
        _bid(A, P2, 20e18, FLOOR);
        _bid(B, P8, 20e18, P2);
        // B leaves: P8 is a dead ex-top with nothing above it.
        vm.prank(B);
        auction.withdrawBid();
        vm.roll(block.number + K);
        auction.sync(256);
        _checkList(g, "dropped");
        assertEq(auction.highestTick(), P2, "high-water not shaved");
        assertEq(_prev(P8), 0, "ex-top not dropped");
        assertEq(_next(P2), 0, "lo.next not cleared");

        // hint = the dropped ex-top, for a price above it. The bid's own implicit sync may
        // have unlinked whatever ran dry, so the insert is checked against the LIVE list: the
        // predecessor must be the highest linked tick below the price, and nothing between.
        _bid(C, P10, 20e18, P8);
        _checkList(g, "dropped/hint=exTop");
        assertEq(_prev(P10), _livePredecessor(P10), "P10 out of order");

        // re-bid AT the dropped price with a hint above it
        _bid(D, P8, 20e18, P10);
        _checkList(g, "dropped/rebid at exTop");
        assertEq(_prev(P8), _livePredecessor(P8), "P8 out of order");
        assertEq(_next(_prev(P8)), P8, "P8 not linked back");
    }

    /// RIGHT AFTER A BAND MOVE: pour so the band walks down several ticks, then bid into the
    /// range the splice just cut out, with hints taken from before the sync.
    function test_afterBandMove_staleHints() public {
        uint256[] memory g = _grid(40);
        // A 26-step spread: wider than the 8-step band, so the band MOVES during the pour.
        _bid(A, FLOOR + 24 * SPACING, 3e18, 0);
        _bid(B, FLOOR + 16 * SPACING, 3e18, 0);
        _bid(C, FLOOR + 8 * SPACING, 200e18, 0);
        _bid(D, FLOOR + 2 * SPACING, 200e18, 0);
        _checkList(g, "band/built");

        uint256 hintTop = FLOOR + 24 * SPACING;
        uint256 hintMid = FLOOR + 16 * SPACING;

        vm.roll(block.number + 3 * K);
        auction.sync(256);
        _checkList(g, "band/after sync");

        // Both stale hints, both possibly unlinked now.
        _bid(E, FLOOR + 20 * SPACING, 20e18, hintTop);
        _checkList(g, "band/hint=old top");
        _bid(F, FLOOR + 12 * SPACING, 20e18, hintMid);
        _checkList(g, "band/hint=old mid");

        // And the honest walk still lands exactly.
        uint256 want = _hintFor(FLOOR + 20 * SPACING);
        assertEq(_prev(FLOOR + 20 * SPACING), want, "band: seated off the next-chain predecessor");
    }

    /// UN-STAKE TO ZERO -> sweep unlinks the tick -> RE-STAKE, with other ticks created in
    /// between and the position's price now above `highestTick`.
    function test_relinkAfterUnstake_otherTicksMeanwhile() public {
        uint256[] memory g = _grid(32);
        _bid(A, P2, 20e18, FLOOR);
        _bid(B, P10, 20e18, P2);
        // B's tick reads dead but keeps escrow.
        vm.prank(B);
        auction.unstake(20e18);
        assertGt(_live(B), 0, "B lost escrow");
        assertEq(_cap(P10), 0, "P10 still has capacity");

        vm.roll(block.number + K);
        auction.sync(256);
        assertEq(_prev(P10), 0, "P10 not unlinked by the sweep");
        assertEq(auction.highestTick(), P2, "high-water not shaved");
        _checkList(g, "relink/unlinked");

        // Other ticks appear meanwhile, BOTH below and above P10.
        _bid(C, P6, 20e18, 0);
        _bid(D, P12, 20e18, 0);
        _checkList(g, "relink/others");

        // B re-stakes: `_reseat` must re-link P10 between P6 and P12.
        _stakeFor(B, 5e18);
        _checkList(g, "relink/restaked");
        assertEq(_prev(P10), P6, "relink: wrong predecessor");
        assertEq(_next(P10), P12, "relink: wrong successor");
        assertGt(_cap(P10), 0, "relink: no capacity seated");
    }

    /// The same, but the re-linked price is ABOVE everything else: `_predecessor` must return
    /// the top of the next-chain and `highestTick` must rise to it.
    function test_relinkAboveHighestTick() public {
        uint256[] memory g = _grid(32);
        _bid(A, P2, 20e18, FLOOR);
        _bid(B, P20, 20e18, P2);
        vm.prank(B);
        auction.unstake(20e18);
        vm.roll(block.number + K);
        auction.sync(256);
        assertEq(auction.highestTick(), P2, "high-water not shaved");
        _checkList(g, "aboveHigh/unlinked");

        _stakeFor(B, 5e18);
        _checkList(g, "aboveHigh/restaked");
        assertEq(auction.highestTick(), P20, "high-water did not rise to the revived tick");
        assertEq(_prev(P20), P2, "aboveHigh: wrong predecessor");
        assertEq(_next(P2), P20, "aboveHigh: floor chain not repaired");
    }

    /// The floor tick itself: drain it, sweep, and check it is never unlinked or dropped, and
    /// that a bid back at the floor still works with every hint.
    function test_floorNeverUnlinked() public {
        uint256[] memory g = _grid(32);
        _bid(A, FLOOR, 20e18, 0);
        vm.prank(A);
        auction.withdrawBid();
        vm.roll(block.number + K);
        auction.sync(256);
        _checkList(g, "floor/swept");
        assertEq(auction.highestTick(), FLOOR, "high-water off the floor");

        _bid(B, FLOOR, 20e18, FLOOR);
        _checkList(g, "floor/rebid hint=self");
        _bid(C, P2, 20e18, 0);
        _checkList(g, "floor/above");
        assertEq(_prev(P2), FLOOR, "floor: successor mis-seated");
    }
}
