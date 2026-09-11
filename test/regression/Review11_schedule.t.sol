// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Review7ConfigBase} from "./Review7_config_Base.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";

contract Review11Schedule is Review7ConfigBase {
    function setUp() public {
        _freshMono();
        IGenerousAuction.Config memory c = _defaultConfig();
        c.admin = address(this);
        _deployWith(c);
    }

    function test_roundCountUsesEffectiveScheduleWithoutAnotherAdminCall() public {
        uint256 start = auction.startBlock();
        vm.roll(start + 50);
        auction.setRoundParams(200, 100e18); // first new round starts at start + 100
        vm.roll(start + 300); // one 100-block round, then one 200-block round
        assertEq(auction.emittedToDate(), 200e18, "control: accrual adopted the new rate");
        assertEq(auction.roundsElapsed(), 2, "round count still uses the old schedule");
    }

    function test_queuingFutureChangeCannotRewriteCompletedRoundCount() public {
        uint256 start = auction.startBlock();
        vm.roll(start + 50);
        auction.setRoundParams(200, 100e18);
        vm.roll(start + 300);
        uint256 countBefore = auction.roundsElapsed();
        uint256 emittedBefore = auction.emittedToDate();
        auction.setRoundParams(50, 100e18); // applies in the future; folds the previous generation
        assertEq(auction.emittedToDate(), emittedBefore, "control: emission history is unchanged");
        assertEq(auction.roundsElapsed(), countBefore, "queuing a future change rewrote past rounds");
    }
}
