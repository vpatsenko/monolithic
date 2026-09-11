// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Review7ConfigBase} from "./Review7_config_Base.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";

contract Review11Lifecycle is Review7ConfigBase {
    function test_claimBetweenFinalizeCallsPreservesPayoutsAndStake() public {
        _freshMono();
        IGenerousAuction.Config memory c = _defaultConfig();
        c.endBlock = c.startBlock + 101; // one block past a whole round: a life of exactly one round is refused
        c.emissionPerRound = 9970e18; // 140 distinct capacities sum to 9870 MONO
        _deployWith(c);
        address[] memory owners = new address[](140);
        for (uint256 i; i < owners.length; ++i) {
            owners[i] = address(uint160(0x44000 + i));
            _stakeFor(owners[i], 1e18);
            _bid(owners[i], 1e18, uint128((i + 1) * 1e18), 1e18);
        }
        vm.roll(c.endBlock);
        assertFalse(auction.finalize(128), "control: first call must exhaust the death budget");
        assertFalse(auction.finalized());
        assertGt(auction.settleCursor(), 0);
        vm.prank(owners[139]);
        vm.expectRevert(IGenerousAuction.StakeLocked.selector);
        auction.unstake(1e18);

        // A permissionless claim continues the tail, harvests and re-seats a large position.
        uint256 paid = auction.claim(owners[139]);
        assertGt(paid, 0);
        assertEq(auction.totalStaked(), 140e18);
        assertGe(mono.balanceOf(address(auction)), 140e18);
        assertTrue(auction.finalize(128), "a completed dead book must unlock");
        assertEq(auction.due(), 0);
        assertEq(auction.currencyMinted(), auction.currencyRaised());
        for (uint256 i; i < owners.length; ++i) {
            paid += auction.claim(owners[i]);
            vm.prank(owners[i]);
            auction.unstake(1e18);
        }
        assertEq(paid, auction.tokensMinted(), "every minted claim token is paid");
        assertEq(auction.totalStaked(), 0);
        assertEq(mono.balanceOf(address(auction)), 0, "neither stake nor minted tokens are stranded");
        assertLe(9870e18 - paid, 300, "shortfall exceeds the two pours' integer reserve");
    }
}
