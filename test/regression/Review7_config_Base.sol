// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GenerousAuction} from "../../src/GenerousAuction.sol";
import {Mono} from "../../src/Mono.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";
import {IIndex} from "../../src/interfaces/IIndex.sol";
import {MockPool} from "../MockPool.sol";
import {TestERC20} from "../TestERC20.sol";

/// Shared harness for the round-7 CONFIGURATION lens: deploy a fresh Mono/INDEX/pool triple at
/// NAV 1.0 and pool price 1.25 (25% premium, saleSupply ~= 105.6k MONO from the MockPool's
/// default L = 1e24), then a GenerousAuction with whatever Config the hazard under test needs.
abstract contract Review7ConfigBase is Test {
    GenerousAuction internal auction;
    Mono internal mono;
    TestERC20 internal cur;
    MockPool internal pool;

    uint256 internal constant GENESIS = 1_000_000e18;
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant HALF = Q96 / 2;
    uint256 internal constant WAD = 1e18;

    address internal aa = address(0xA1);
    address internal bb = address(0xA2);
    address internal cc = address(0xA3);

    function _freshMono() internal {
        cur = new TestERC20("Index", "INDEX");
        mono = new Mono(IIndex(address(cur)), 10 * GENESIS);
        cur.mint(address(this), GENESIS);
        cur.approve(address(mono), GENESIS);
        mono.mint(GENESIS, GENESIS, address(this));
        pool = new MockPool(address(mono), address(cur), 1.25e18);
        mono.setPool(address(pool));
    }

    function _defaultConfig() internal view returns (IGenerousAuction.Config memory c) {
        c = IGenerousAuction.Config({
            token: address(mono),
            currency: address(cur),
            admin: address(0xF1),
            floorPrice: 1e18,
            tickSpacing: 1e16,
            decayQ: HALF,
            windowTicks: 8,
            startBlock: uint64(block.number),
            endBlock: 0,
            roundBlocks: 100,
            emissionPerRound: 100e18,
            minPremiumBips: 1_500,
            previousAuction: address(0)
        });
    }

    function _deployWith(IGenerousAuction.Config memory c) internal {
        auction = new GenerousAuction(c);
        mono.grantRole(mono.MINTER_ROLE(), address(auction));
        mono.renounceRole(mono.MINTER_ROLE(), address(this));
    }

    function _stakeFor(address who, uint256 amt) internal {
        mono.transfer(who, amt);
        vm.startPrank(who);
        mono.approve(address(auction), amt);
        auction.stake(amt);
        vm.stopPrank();
    }

    function _bid(address who, uint256 price, uint128 amount, uint256 prev) internal {
        cur.mint(who, amount);
        vm.startPrank(who);
        cur.approve(address(auction), amount);
        auction.submitBid(price, amount, who, prev);
        vm.stopPrank();
    }

    function _owed(address who) internal view returns (uint256 owed) {
        (, owed) = auction.positionOf(who);
    }

    function _live(address who) internal view returns (uint256 live) {
        (live,) = auction.positionOf(who);
    }
}
