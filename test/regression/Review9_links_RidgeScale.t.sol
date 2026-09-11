// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Review9LinksBase} from "./Review9_links_Base.sol";

/// SCALE MEASUREMENT for the "one splice per window" leak.
///
/// `_sync` splices exactly once per window, `_splice(price_k, tau_k)`, and window k+1 starts at
/// `resume_k` — BELOW window k's band. So the stretch `(resume_k, tau_k]` — window k's whole band,
/// up to `windowTicks + 1` nodes — is covered by no splice at all. `highestTick` is then shaved to
/// the LAST window's `tau`, so every later sweep starts below all of them and `_gather` never
/// walks them again. `_splice`'s O(1) dead-ex-top drop cannot help: it fires only when the WALK
/// START is a dead top, and after the first sweep the walk start is always below the leftovers.
contract Review9LinksRidgeScaleTest is Review9LinksBase {
    uint256 internal constant CLUSTERS = 40;
    uint256 internal constant PER = 4;
    uint256 internal constant GAP = 14; // > windowTicks (8): forces a new window per cluster
    uint256 internal constant N = CLUSTERS * PER;

    address[] internal owners;

    function _step(uint256 i) internal pure returns (uint256) {
        return (i / PER) * (PER + GAP) + (i % PER);
    }

    function setUp() public {
        _deploy(0, 300e18);
        _registerGrid(_step(N - 1) + 8);
        for (uint256 i; i < N; ++i) {
            owners.push(address(uint160(0xD000 + i)));
        }
        uint256 prev = FLOOR;
        for (uint256 i; i < N; ++i) {
            address who = owners[i];
            uint256 price = FLOOR + _step(i) * SPACING;
            mono.transfer(who, 1e18);
            cur.mint(who, 20e18);
            vm.startPrank(who);
            mono.approve(address(auction), 1e18);
            auction.stake(1e18);
            cur.approve(address(auction), 20e18);
            auction.submitBid(price, 20e18, who, prev);
            vm.stopPrank();
            prev = price;
        }
    }

    function _lens() internal view returns (uint256 sweepLen, uint256 uiLen, uint256 strandedAbove) {
        uint256 p = auction.highestTick();
        while (p != 0) {
            sweepLen++;
            (, p,,,,,) = auction.ticks(p);
        }
        uint256 hi = auction.highestTick();
        uint256 q = FLOOR;
        uiLen = 1;
        while (true) {
            (uint256 nx,,,,,,) = auction.ticks(q);
            if (nx == 0) break;
            uiLen++;
            if (nx > hi) strandedAbove++;
            q = nx;
        }
    }

    /// After the book is fully drained, count the nodes no future sweep can ever unlink.
    function test_links_ridgeScale() public {
        vm.roll(block.number + 200_000);
        for (uint256 i; i < 12; ++i) {
            auction.sync(1);
        }
        assertEq(auction.settleCursor(), 0, "sweep finished");
        assertEq(auction.due() > 0, true, "book is dry with supply left");
        _checkList();

        (uint256 sweepLen, uint256 uiLen, uint256 stranded) = _lens();
        emit log_named_uint("bids placed", N);
        emit log_named_uint("highestTick step", (auction.highestTick() - FLOOR) / SPACING);
        emit log_named_uint("sweep chain (down from highestTick)", sweepLen);
        emit log_named_uint("UI chain (up from floorPrice)", uiLen);
        emit log_named_uint("nodes linked above highestTick, never unlinkable", stranded);

        // Another dozen sweeps change nothing: they all start at or below `highestTick`.
        for (uint256 i; i < 12; ++i) {
            auction.sync(1);
        }
        (,, uint256 stranded2) = _lens();
        emit log_named_uint("after 12 more sweeps", stranded2);
        uint256 deadLinked;
        for (uint256 i; i < gridPrices.length; ++i) {
            (uint256 nx, uint256 pv, uint256 c,,,, bool init) = auction.ticks(gridPrices[i]);
            if (init && gridPrices[i] != FLOOR && (nx != 0 || pv != 0) && c == 0) deadLinked++;
        }
        emit log_named_uint("dead-but-linked nodes", deadLinked);
        assertEq(stranded2, stranded, "sweeps never reclaim them");
        assertEq(stranded, 0, "dead nodes stranded on the floor chain forever");
    }

    /// The cost the leftovers impose: a later high bid whose hint is stale or absent pays
    /// `_predecessor` over the whole stale chain, and the sweep that follows must walk it too.
    function test_links_ridgeCost() public {
        vm.roll(block.number + 200_000);
        for (uint256 i; i < 12; ++i) {
            auction.sync(1);
        }
        (,, uint256 stranded) = _lens();
        emit log_named_uint("stranded nodes", stranded);

        address late = address(0xE001);
        uint256 price = FLOOR + (_step(N - 1) + 4) * SPACING;
        mono.transfer(late, 1e18);
        cur.mint(late, 60e18);
        vm.startPrank(late);
        mono.approve(address(auction), 1e18);
        auction.stake(1e18);
        cur.approve(address(auction), 60e18);
        // exact hint a UI computes off the SAME chain: the highest linked node below `price`
        uint256 uiHint = FLOOR;
        while (true) {
            (uint256 nx,,,,,,) = auction.ticks(uiHint);
            if (nx == 0 || nx >= price) break;
            uiHint = nx;
        }
        uint256 snap = vm.snapshotState();
        uint256 g1 = gasleft();
        auction.submitBid(price, 60e18, late, uiHint);
        uint256 goodHintGas = g1 - gasleft();
        vm.revertToState(snap);
        uint256 g0 = gasleft();
        auction.submitBid(price, 60e18, late, 0); // no hint: `_predecessor` walks it all
        emit log_named_uint("high bid gas, exact hint", goodHintGas);
        emit log_named_uint("high bid gas, hint 0", g0 - gasleft());
        vm.stopPrank();
        _checkList();

        // The sweep now starts at the new top and must walk every stranded node before it can
        // reach the book. Count the syncs needed to settle again.
        vm.roll(block.number + 200);
        uint256 syncs;
        uint256 gasTotal;
        while (auction.settleCursor() != 0 || syncs == 0) {
            uint256 g = gasleft();
            auction.sync(1);
            gasTotal += g - gasleft();
            syncs++;
            _checkList();
            if (syncs > 40) break;
        }
        emit log_named_uint("syncs to settle after the high bid", syncs);
        emit log_named_uint("gas spent settling", gasTotal);
        (uint256 sl2, uint256 ul2, uint256 above2) = _lens();
        emit log_named_uint("sweep chain after", sl2);
        emit log_named_uint("UI chain after (total linked nodes)", ul2);
        emit log_named_uint("linked above highestTick after", above2);
        uint256 deadLinked;
        for (uint256 i; i < gridPrices.length; ++i) {
            (uint256 nx, uint256 pv, uint256 c,,,, bool init) = auction.ticks(gridPrices[i]);
            if (init && gridPrices[i] != FLOOR && (nx != 0 || pv != 0) && c == 0) deadLinked++;
        }
        emit log_named_uint("dead-but-linked nodes after", deadLinked);
    }
}
