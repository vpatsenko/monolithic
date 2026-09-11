// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Review9SweepBase} from "./Review9_sweep_Base.sol";

/// Review 9 / SWEEP lens — enumerate every exit of the window loop in `_sync` and assert the
/// tick list is sound afterwards AND that no tick with capacity was unlinked or left above the
/// point the next sweep starts from.
contract Review9SweepExits is Review9SweepBase {
    uint256[] internal universe;

    function _grid(uint256 n) internal {
        delete universe;
        for (uint256 i; i <= n; ++i) {
            universe.push(FLOOR + i * SPACING);
        }
    }

    function _u() internal view returns (uint256[] memory) {
        return universe;
    }

    function _actor(uint256 i) internal pure returns (address) {
        return address(uint160(0xB000 + i));
    }

    // ------------------------------------------------------------------ E1: normal window

    function test_E1_normalWindow() public {
        _deploy(40e18, 0);
        _grid(30);
        for (uint256 i; i < 5; ++i) {
            address a = _actor(i);
            _stakeFor(a, 10e18);
            uint256 price = FLOOR + (i + 1) * SPACING;
            _bid(a, price, 50e18, _uiHint(price));
        }
        vm.roll(block.number + K + 1);
        auction.sync(300);
        emit log_named_uint("E1 highestTick", auction.highestTick());
        emit log_named_uint("E1 settleCursor", auction.settleCursor());
        emit log_named_uint("E1 tokensSold", auction.tokensSold());
        _assertSound(_u(), "E1");
    }

    // ------------------------------------------------------------------ E2: band moved

    /// Deep top ticks with small caps: the band's top dries mid-pour and the anchor walks down
    /// several ticks inside one window.
    function test_E2_bandMoved() public {
        _deploy(400e18, 0);
        _grid(30);
        // Twelve ticks two steps apart: wider than the 8-step band, so the band moves.
        for (uint256 i; i < 12; ++i) {
            address a = _actor(i);
            _stakeFor(a, 10e18);
            uint256 price = FLOOR + (2 * i + 1) * SPACING;
            _bid(a, price, 3e18, _uiHint(price)); // small escrow: dies fast
        }
        uint256 hiBefore = auction.highestTick();
        vm.roll(block.number + 3 * K + 1);
        auction.sync(300);
        emit log_named_uint("E2 highestTick before", hiBefore);
        emit log_named_uint("E2 highestTick after", auction.highestTick());
        emit log_named_uint("E2 settleCursor", auction.settleCursor());
        emit log_named_uint("E2 tokensSold", auction.tokensSold());
        _assertSound(_u(), "E2");
    }

    // ------------------------------------------------------------------ E3: drained

    function test_E3_drained() public {
        _deploy(1e18, 0); // tiny emission: the first band eats it all
        _grid(30);
        for (uint256 i; i < 6; ++i) {
            address a = _actor(i);
            _stakeFor(a, 10e18);
            uint256 price = FLOOR + (i + 1) * SPACING;
            _bid(a, price, 100e18, _uiHint(price));
        }
        vm.roll(block.number + K + 1);
        auction.sync(300);
        assertEq(auction.settleCursor(), 0, "drained parks no cursor");
        emit log_named_uint("E3 sold", auction.tokensSold());
        _assertSound(_u(), "E3");
    }

    // ------------------------------------------------------------------ E4: w.n == 0, list ran out

    /// Everything withdrawn: the gather walks off the bottom, `w.resume` is 0, no splice at all.
    function test_E4_listRanOut() public {
        _deploy(40e18, 0);
        _grid(30);
        for (uint256 i; i < 5; ++i) {
            address a = _actor(i);
            _stakeFor(a, 10e18);
            uint256 price = FLOOR + (i + 1) * SPACING;
            _bid(a, price, 50e18, _uiHint(price));
        }
        vm.roll(block.number + K + 1);
        for (uint256 i; i < 5; ++i) {
            vm.prank(_actor(i));
            auction.withdrawBid();
        }
        uint256 hiBefore = auction.highestTick();
        auction.sync(300);
        emit log_named_uint("E4 highestTick before", hiBefore);
        emit log_named_uint("E4 highestTick after", auction.highestTick());
        emit log_named_uint("E4 settleCursor", auction.settleCursor());
        // Count how many dead nodes are still linked on the prev chain.
        uint256 n;
        uint256 p = _sweepStart();
        while (p != 0) {
            ++n;
            p = _prev(p);
        }
        emit log_named_uint("E4 nodes still on the prev chain", n);
        _assertSound(_u(), "E4");
    }

    // ------------------------------------------------------------------ E5: w.n == 0, budget out

    /// A dead ridge deeper than `SYNC_TICKS` (128): the gather's skip walk budgets out, `w.n`
    /// comes back 0 with a live `w.resume`, the wall is shaved and the cursor parks on it.
    function test_E5_gatherBudgetOut() public {
        _deploy(40e18, 0);
        // 160 dead ticks above one live tick at the floor+1 step.
        address ridge = _actor(90);
        _stakeFor(ridge, 10e18);
        for (uint256 i; i < 160; ++i) {
            uint256 price = FLOOR + (i + 5) * SPACING;
            _bid(ridge, price, 2e18, _uiHint(price));
            vm.prank(ridge);
            auction.withdrawBid();
        }
        address honest = _actor(0);
        _stakeFor(honest, 10e18);
        _bid(honest, FLOOR + SPACING, 100e18, _uiHint(FLOOR + SPACING));

        _grid(200);
        uint256 hiBefore = auction.highestTick();
        vm.roll(block.number + K + 1);
        auction.sync(1); // floored to SYNC_TICKS = 128
        emit log_named_uint("E5 highestTick before", hiBefore);
        emit log_named_uint("E5 highestTick after", auction.highestTick());
        emit log_named_uint("E5 settleCursor", auction.settleCursor());
        emit log_named_uint("E5 sold", auction.tokensSold());
        assertTrue(auction.settleCursor() != 0, "E5 must park the cursor");
        _assertSound(_u(), "E5");

        // And the resumed sweep finishes the job.
        auction.sync(1);
        _assertSound(_u(), "E5 resumed");
        auction.sync(500);
        _assertSound(_u(), "E5 full");
        emit log_named_uint("E5 sold after full sweep", auction.tokensSold());
        emit log_named_uint("E5 cursor after full sweep", auction.settleCursor());
        emit log_named_uint("E5 honest owed", _owed(honest));
        assertGt(_owed(honest), 0, "the honest bid below the ridge was poured");
    }
}
