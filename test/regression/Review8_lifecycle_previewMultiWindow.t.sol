// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Review8LifecycleBase} from "./Review8_lifecycle_Base.sol";

/// REVIEW 8 / lifecycle — `previewWindow` vs the `sync` that follows in the same block.
///
/// `previewWindow` (GenerousAuction.sol:1651) runs ONE `_solveBand` from the top of book and
/// documents itself as "the whole stretch's" figures. `_sync` (:729) loops: when a band dries
/// entirely with supply to spare (`_solveBand` breaks at `t == s.n`, :1011 — no standing tick
/// to move the band onto) it sets `price = w.resume` and gathers a NEW window further down.
/// The preview never takes that second step, so whenever the first stretch dries it reports
/// only the first stretch and the sync pays strictly more, to ticks the preview did not list.
///
/// Reachable by an honest book: a small top-of-book bid more than `windowTicks` grid steps
/// above the bulk of the demand.
contract Review8LifecyclePreviewMultiWindow is Review8LifecycleBase {
    function setUp() public {
        _deploy(150e18, 0);
    }

    /// FAILS on current code: preview says 10, the sync in the same block sells 150.
    function test_BUG_previewOmitsTheWindowsBelowADriedStretch() public {
        _bidCap(aa, P(9), 10e18, FLOOR); // 9 steps above the floor: outside the floor's band
        _bidCap(bb, P(0), 1000e18, FLOOR);
        vm.roll(block.number + K);
        assertEq(auction.due(), 150e18);

        (uint256 tau,, uint256[] memory price, uint256[] memory tokens) = auction.previewWindow();
        assertEq(tau, P(9));
        uint256 previewed;
        for (uint256 i; i < tokens.length; ++i) {
            previewed += tokens[i];
            emit log_named_uint(string.concat("preview price idx ", vm.toString(i)), price[i]);
            emit log_named_uint(string.concat("preview tokens idx ", vm.toString(i)), tokens[i]);
        }
        emit log_named_uint("preview total", previewed);

        auction.sync(200);
        uint256 sold = auction.tokensSold();
        emit log_named_uint("sync sold (same block)", sold);
        emit log_named_uint("bb owed (not in the preview)", _owed(bb));
        assertEq(auction.settleCursor(), 0, "complete sweep");

        assertEq(previewed, sold, "previewWindow must report what the sync in this block sells");
    }

    /// Negative control: when the stretch does NOT dry (the band moves onto a standing tick),
    /// preview == sync exactly, band moves included.
    function test_previewMatchesSyncWhenTheBandMoves() public {
        _bidCap(aa, P(9), 10e18, FLOOR);
        _bidCap(cc, P(8), 5e18, FLOOR);
        _bidCap(bb, P(0), 1000e18, P(0));
        vm.roll(block.number + K);

        (,,, uint256[] memory tokens) = auction.previewWindow();
        uint256 previewed;
        for (uint256 i; i < tokens.length; ++i) {
            previewed += tokens[i];
        }
        auction.sync(200);
        assertEq(previewed, auction.tokensSold(), "band moves are previewed");
    }
}
