// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Review9LinksBase} from "./Review9_links_Base.sol";

/// ROUND 14, lens `splice`: how wide the `mark = w.resume` strand actually is.
///
/// A deterministic sweep over the shape "two dust rungs (cap 2 wei, cap 1 wei) at grid distances
/// (dAB, dBW) above one whale (cap 1e24 >> supply)", one fresh deployment per cell, one sync per
/// deployment, at the standard harness config (floor 1e18, spacing 1e16, windowTicks 8,
/// decayQ Q96/2, roundBlocks 100, emission 40e18/round). Reports counts; the assertion is on the
/// COUNT, so the test is a characterisation with a measured number rather than a claim.
contract Review14SplicePrevalenceTest is Review9LinksBase {
    address internal constant A = address(0xA1);
    address internal constant B = address(0xA2);
    address internal constant W = address(0xA3);

    function _fund(address who, uint256 stakeAmt, uint256 currencyAmt) internal {
        mono.transfer(who, stakeAmt);
        cur.mint(who, currencyAmt);
        vm.startPrank(who);
        mono.approve(address(auction), stakeAmt);
        auction.stake(stakeAmt);
        cur.approve(address(auction), currencyAmt);
        vm.stopPrank();
    }

    function _bid(address who, uint256 price, uint128 amount, uint256 hint) internal {
        vm.prank(who);
        auction.submitBid(price, amount, who, hint);
    }

    /// @return stranded 1 when the whale ended unlinked with capacity, 0 otherwise
    /// @return highStep  the high-water mark, in grid steps above the floor, after the sync
    function _cell(uint256 dAB, uint256 dBW) internal returns (uint256 stranded, uint256 highStep) {
        _deploy(0, 40e18);
        uint256 top = FLOOR + 100 * SPACING;
        uint256 mid = top - dAB * SPACING;
        uint256 bot = mid - dBW * SPACING;

        _fund(A, 10e18, 1_000e18);
        _fund(B, 10e18, 1_000e18);
        _fund(W, 10e18, 4e24);
        _bid(W, bot, 1.9e24, FLOOR);
        _bid(B, mid, uint128(2 * mid / 1e18), bot); // cap = 1
        _bid(A, top, uint128(2 * top / 1e18 + 2), mid); // cap = 2

        vm.roll(block.number + 100);
        auction.sync(1_000);

        (uint256 nxW, uint256 pvW, uint256 capW,,,,) = auction.ticks(bot);
        stranded = (capW != 0 && pvW == 0 && nxW == 0) ? 1 : 0;
        highStep = (auction.highestTick() - FLOOR) / SPACING;
        vm.roll(block.number + 1);
    }

    function test_splice_prevalenceGrid() public {
        uint256 hits;
        uint256 cells;
        for (uint256 dAB = 1; dAB <= 8; ++dAB) {
            for (uint256 dBW = 1; dBW <= 8; ++dBW) {
                (uint256 s, uint256 h) = _cell(dAB, dBW);
                cells++;
                hits += s;
                if (s == 1) {
                    emit log_named_string(
                        "STRANDED",
                        string.concat(
                            "dAB=", vm.toString(dAB), " dBW=", vm.toString(dBW), " highestTick step=", vm.toString(h)
                        )
                    );
                }
            }
        }
        emit log_named_uint("cells driven", cells);
        emit log_named_uint("cells that stranded the whale", hits);
        assertEq(cells, 64, "grid size");
        // 23 of these 64 (dAB, dBW) cells stranded the whale before the fix. The splice now
        // keeps any tick that still has capacity and the high-water is never shaved under one,
        // so no cell strands it — a grid-wide regression net for that shape.
        assertEq(hits, 0, "a cell stranded a live tick");
    }
}
