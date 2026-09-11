// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Review7ConfigBase} from "./Review7_config_Base.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";

contract Review13DoS is Review7ConfigBase {
    uint256 internal constant RIDGE = 512;

    function setUp() public {
        _freshMono();
        IGenerousAuction.Config memory c = _defaultConfig();
        c.startBlock += 1000;
        // Two rounds at the same 1e18/block rate: a life of exactly ONE round is refused by the
        // constructor (it would leave `setRoundParams` permanently frozen), and the totals below
        // are unchanged by the split.
        c.roundBlocks = 50;
        c.emissionPerRound = 50e18;
        c.endBlock = c.startBlock + 100;
        _deployWith(c);
        _stakeFor(aa, 1); // one attacker, one token wei of stake, reused for every price
        _stakeFor(bb, 1e18);
        _bid(bb, 1e18, 1000e18, 1e18);
        cur.mint(aa, 7); // currency is returned by every cancellation; max deposit is 7 wei
        vm.prank(aa);
        cur.approve(address(auction), type(uint256).max);
        for (uint256 i = 1; i <= RIDGE; ++i) {
            uint256 price = 1e18 + i * 1e16;
            uint128 amount = uint128((price + 1e18 - 1) / 1e18);
            vm.prank(aa);
            auction.submitBid(price, amount, aa, price - 1e16);
            vm.prank(aa);
            assertEq(auction.withdrawBid(), amount);
            vm.roll(block.number + 1); // the whole ridge fits in the scheduled pre-start period
        }
        assertEq(cur.balanceOf(aa), 7, "attacker recycles all escrow");
        assertEq(auction.stakes(aa), 1);
        assertEq(_live(aa), 0);
    }

    function test_cancelledRidgeBlocksOwnerActionsUntilExplicitSync() public {
        vm.roll(auction.startBlock() + 50);
        uint256 topBefore = auction.highestTick();
        for (uint256 attempt; attempt < 2; ++attempt) {
            vm.prank(bb);
            vm.expectRevert(IGenerousAuction.SettleFirst.selector);
            auction.submitBid(1e18, 1e18, bb, 1e18);
            vm.prank(bb);
            vm.expectRevert(IGenerousAuction.SettleFirst.selector);
            auction.withdrawBid();
            vm.prank(bb);
            vm.expectRevert(IGenerousAuction.SettleFirst.selector);
            auction.unstake(1e18);
            assertEq(auction.highestTick(), topBefore, "reverted user actions cannot retain cleanup progress");
            assertEq(auction.tokensSold(), 0);
        }

        uint256 calls;
        for (; calls < 6 && auction.tokensSold() == 0; ++calls) {
            uint256 oldTop = auction.highestTick();
            auction.sync(0); // zero is raised to 128; cleanup makes persistent progress
            assertTrue(auction.highestTick() < oldTop || auction.tokensSold() > 0);
        }
        emit log_named_uint("minimum-budget sync calls to clear 512 cancelled prices", calls);
        assertLe(calls, 5);
        assertEq(auction.settleCursor(), 0);
        assertEq(auction.tokensSold(), 50e18);
        assertEq(_owed(bb), 50e18);
        vm.prank(bb);
        assertEq(auction.withdrawBid(), 950e18);
        assertEq(auction.claim(bb), 50e18);
    }

    function test_biggerSyncClearsRidgeInOneCall() public {
        vm.roll(auction.startBlock() + 50);
        uint256 gasBefore = gasleft();
        auction.sync(1024);
        emit log_named_uint("sync(1024) execution gas", gasBefore - gasleft());
        assertEq(auction.settleCursor(), 0);
        assertEq(auction.tokensSold(), 50e18);
        vm.prank(bb);
        assertEq(auction.withdrawBid(), 950e18);
    }

    function test_cancelledRidgeCannotPermanentlyBlockFinalization() public {
        vm.roll(auction.endBlock());
        uint256 calls;
        bool done;
        for (; calls < 6 && !done; ++calls) {
            done = auction.finalize(128);
        }
        emit log_named_uint("finalize calls to clear 512 cancelled prices", calls);
        assertTrue(done);
        assertLe(calls, 5);
        assertEq(auction.tokensSold(), 100e18);
        assertEq(auction.tokensMinted(), 100e18);
        vm.prank(bb);
        auction.unstake(1e18);
        vm.prank(bb);
        assertEq(auction.withdrawBid(), 900e18);
        assertEq(auction.claim(bb), 100e18);
    }
}
