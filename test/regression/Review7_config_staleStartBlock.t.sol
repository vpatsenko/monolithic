// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Review7ConfigBase} from "./Review7_config_Base.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";
import {GenerousAuction} from "../../src/GenerousAuction.sol";

/// HAZARD: the constructor bounds `startBlock` only on the FUTURE side (src/GenerousAuction.sol
/// L220-222: `startBlock > block.number + 2_628_000` reverts). A `startBlock` in the PAST is
/// accepted with no lower bound at all, and `_emittedAt` (L322-337) accrues from it in closed
/// form, clamped only at `saleSupply` (`due()`, L299-306). The deploy script's own comment
/// (script/DeployGenerousAuction.s.sol L100-101) says a START_BLOCK in the past "is not fatal -
/// it just accrues a backlog that the first sync releases in one lump". That lump is handed to
/// the first seated position at ITS price: with the script's schedule (100 MONO / 15 L1 blocks)
/// a START_BLOCK stale by ~2.3 days puts 100% of `saleSupply` in `due()` at deploy, and the
/// first bidder - 1 wei of stake, a bid at the floor - takes the entire sale at NAV in one
/// block, with a 25% pool premium standing. Round-6 #17 measured 7.7% for a dry week mid-sale;
/// this is the whole sale, at deploy, from a documented-as-harmless config.
contract Review7ConfigStaleStartBlock is Review7ConfigBase {
    uint64 internal constant K = 15;
    uint128 internal constant R = 100e18;
    uint256 internal constant DAY_L1 = 6_950; // the script's own conversion table

    function _deployStale(uint256 staleBy) internal {
        vm.roll(100_000);
        _freshMono();
        IGenerousAuction.Config memory c = _defaultConfig();
        c.roundBlocks = K;
        c.emissionPerRound = R;
        c.startBlock = uint64(block.number - staleBy);
        _deployWith(c);
    }

    /// A stale start is rejected at deploy: the sale must not open with supply already owed.
    function test_staleStartIsRejected() public {
        vm.roll(100_000);
        _freshMono();
        IGenerousAuction.Config memory c = _defaultConfig();
        c.roundBlocks = K;
        c.emissionPerRound = R;
        c.startBlock = uint64(block.number - 1);
        vm.expectRevert(IGenerousAuction.InvalidParams.selector);
        new GenerousAuction(c);
        c.startBlock = uint64(block.number - 16_000); // ~2.3 days: would have owed the whole sale
        vm.expectRevert(IGenerousAuction.InvalidParams.selector);
        new GenerousAuction(c);
    }

    /// The boundary: a start AT the deploy block (and any future one within the headroom) is
    /// fine and opens with nothing owed.
    function test_startAtDeployBlockOwesNothing() public {
        _deployStale(0);
        assertEq(auction.due(), 0, "nothing owed at deploy");
        assertEq(auction.emittedToDate(), 0);
        vm.roll(block.number + K);
        assertEq(auction.due(), R, "one round after one round");
    }
}
