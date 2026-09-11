// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Review7ConfigBase} from "./Review7_config_Base.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";
import {GenerousAuction} from "../../src/GenerousAuction.sol";

/// HAZARD: `tickSpacing` as low as 2 wei is ACCEPTED (MIN_TICK_SPACING = 2, src/GenerousAuction.sol
/// L87-90 / L226), and the window is a PRICE band `[tau - windowTicks*tickSpacing, tau]`
/// (`_gather` L728-730). The only pairing check is `q^windowTicks <= 1%` (L232-234), which is
/// measured in GRID STEPS, not in price. So at spacing 2 wei / windowTicks 8 the whole q-curve
/// spans 16 wei of price: any bid more than 16 wei above the book is a separate window, and windows
/// are solved top-down in full (`_sync` L611-660) - i.e. the "generous" geometric split degenerates
/// into a strict price-priority pay-as-bid fill, and the `(1 - q)` soft anti-whale cap is escaped
/// for +18 wei (1.8e-15 %) with NO dust trick, no sybil, nothing but an honest bid.
contract Review7ConfigNarrowBandPriority is Review7ConfigBase {
    uint256 internal constant FLOOR = 1e18;

    function _deploySpacing(uint256 spacing) internal {
        _freshMono();
        IGenerousAuction.Config memory c = _defaultConfig();
        c.tickSpacing = spacing;
        c.emissionPerRound = 100e18;
        c.roundBlocks = 100;
        _deployWith(c);
    }

    /// Same book shape, two grids. On the script's 1e16 grid a bid ONE tick above the floor is in
    /// the floor's window and the floor keeps q/(1+q) = 1/3. On the 2-wei grid a bid 18 wei above
    /// the floor (0.0000000000000018 % more) is OUTSIDE the band; the floor gets 0 until the
    /// higher bid is fully filled.
    function test_twoWeiSpacing_isRejected_referenceGridSplitsByQ() public {
        // ---- reference: the deploy script's grid ------------------------------------------
        _deploySpacing(1e16);
        _stakeFor(aa, 1e18);
        _stakeFor(bb, 1e18);
        _bid(aa, FLOOR, 1000e18, FLOOR);
        _bid(bb, FLOOR + 1e16, 1000e18, FLOOR); // one grid step up
        vm.roll(block.number + 100);
        auction.sync(64);
        uint256 refFloor = _owed(aa);
        uint256 refTop = _owed(bb);
        assertApproxEqAbs(refFloor, uint256(100e18) / 3, 2, "reference grid: floor keeps q/(1+q) = 1/3");
        assertApproxEqAbs(refTop, uint256(200e18) / 3, 2, "reference grid: top gets 1/(1+q) = 2/3");

        // ---- hazard: the 2-wei grid is now rejected at deploy (band = 16 wei of price) --------
        _freshMono();
        IGenerousAuction.Config memory c = _defaultConfig();
        c.tickSpacing = 2;
        c.emissionPerRound = 100e18;
        c.roundBlocks = 100;
        vm.expectRevert(IGenerousAuction.WindowTooNarrow.selector);
        new GenerousAuction(c);
    }

    /// The guard: the band must be at least 1% of the floor in PRICE terms
    /// (`windowTicks * tickSpacing >= floorPrice / 100`; the script's own pairing gives 8%).
    function test_bandBelowOnePercentOfFloorIsRejected() public {
        _freshMono();
        IGenerousAuction.Config memory c = _defaultConfig();
        c.tickSpacing = 2;
        c.windowTicks = 8;
        vm.expectRevert(IGenerousAuction.WindowTooNarrow.selector);
        new GenerousAuction(c);
        // Exactly 1% passes.
        c.tickSpacing = c.floorPrice / 800;
        GenerousAuction a = new GenerousAuction(c);
        assertEq(a.windowTicks() * a.tickSpacing(), c.floorPrice / 100);
    }
}
