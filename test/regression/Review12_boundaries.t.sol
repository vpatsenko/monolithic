// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Review7ConfigBase} from "./Review7_config_Base.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";

contract Review12Boundaries is Review7ConfigBase {
    function setUp() public {
        _freshMono();
        IGenerousAuction.Config memory c = _defaultConfig();
        c.startBlock += 100;
        c.endBlock = c.startBlock + 101; // one block past a whole round: a life of exactly one round is refused
        _deployWith(c);
        _stakeFor(aa, 1e18);
        _stakeFor(bb, 1e18);
        _bid(aa, 1e18, 500e18, 1e18);
        _bid(bb, 1e18, 500e18, 1e18);
    }

    function test_preStartOperationsCannotEarnOrLeavePhantomWeight() public {
        vm.prank(aa);
        assertEq(auction.withdrawBid(), 500e18);
        vm.prank(aa);
        auction.unstake(1e18);
        assertEq(auction.claim(bb), 0);
        assertEq(auction.tokensSold(), 0);
        vm.roll(auction.startBlock());
        auction.sync(128);
        assertEq(auction.due(), 0);
        assertEq(auction.claim(bb), 0);
        vm.roll(block.number + 1);
        assertEq(auction.claim(bb), 1e18, "only the remaining stake earns the first block");
        assertEq(auction.claim(aa), 0);
    }

    function test_sameBlockUnstakeRestakeCannotRewriteAccruedEmission() public {
        vm.roll(auction.startBlock() + 50);
        vm.prank(aa);
        auction.unstake(1e18); // must settle the first 50 blocks using both old stakes
        vm.prank(aa);
        mono.approve(address(auction), 1e18);
        vm.prank(aa);
        auction.stake(1e18);
        assertEq(_owed(aa), 25e18);
        assertEq(_owed(bb), 25e18);
        vm.roll(block.number + 10);
        auction.sync(128);
        assertApproxEqAbs(_owed(aa), 30e18, 2);
        assertApproxEqAbs(_owed(bb), 30e18, 2);
    }

    function test_finalizedAuctionCannotSellAgainAfterStakeAndScheduleChanges() public {
        vm.roll(auction.endBlock());
        assertTrue(auction.finalize(128));
        uint256 sold = auction.tokensSold();
        uint256 raised = auction.currencyRaised();
        _stakeFor(cc, 1e18);
        vm.prank(cc);
        vm.expectRevert(IGenerousAuction.AuctionEnded.selector);
        auction.submitBid(1e18, 1e18, cc, 1e18);
        vm.prank(address(0xF1));
        vm.expectRevert(IGenerousAuction.ScheduleFrozen.selector);
        auction.setRoundParams(1, 100e18);
        vm.roll(block.number + 100_000);
        auction.sync(10_000);
        assertEq(auction.due(), 0);
        assertEq(auction.tokensSold(), sold);
        assertEq(auction.currencyRaised(), raised);
        vm.prank(cc);
        auction.unstake(1e18);
    }
}
