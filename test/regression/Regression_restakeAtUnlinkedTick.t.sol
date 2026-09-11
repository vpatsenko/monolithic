// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GenerousAuction} from "../../src/GenerousAuction.sol";
import {Mono} from "../../src/Mono.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";
import {IIndex} from "../../src/interfaces/IIndex.sol";
import {MockPool} from "../MockPool.sol";
import {TestERC20} from "../TestERC20.sol";

/// Found while unlinking spliced ticks: a bid whose owner un-stakes to zero is inert (escrow, no
/// stake) and its tick reads dead, so a sweep may unlink the tick. When the owner stakes again,
/// `_reseat` seats capacity there — which must NOT leave a live tick outside every sweep's reach.
contract RegressionRestakeAtUnlinkedTick is Test {
    GenerousAuction internal auction;
    Mono internal mono;
    TestERC20 internal cur;

    uint256 internal constant GENESIS = 1_000_000e18;
    uint256 internal constant FLOOR = 1e18;
    uint256 internal constant SPACING = 1e16;
    uint256 internal constant Q96 = 1 << 96;
    uint64 internal constant K = 100;
    uint256 internal constant P5 = FLOOR + 5 * SPACING;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        cur = new TestERC20("Index", "INDEX");
        mono = new Mono(IIndex(address(cur)), 10 * GENESIS);
        cur.mint(address(this), GENESIS);
        cur.approve(address(mono), GENESIS);
        mono.mint(GENESIS, GENESIS, address(this));
        MockPool pool = new MockPool(address(mono), address(cur), 1.25e18);
        mono.setPool(address(pool));
        auction = new GenerousAuction(
            IGenerousAuction.Config({
                token: address(mono),
                currency: address(cur),
                admin: address(0xF1),
                floorPrice: FLOOR,
                tickSpacing: SPACING,
                decayQ: Q96 / 2,
                windowTicks: 8,
                startBlock: uint64(block.number),
                endBlock: 0,
                roundBlocks: K,
                emissionPerRound: 50e18,
                minPremiumBips: 1_500,
                previousAuction: address(0)
            })
        );
        mono.grantRole(mono.MINTER_ROLE(), address(auction));
        mono.renounceRole(mono.MINTER_ROLE(), address(this));
        address[2] memory all = [alice, bob];
        for (uint256 i; i < 2; ++i) {
            mono.transfer(all[i], 2e18);
            cur.mint(all[i], 10_000e18);
            vm.startPrank(all[i]);
            mono.approve(address(auction), type(uint256).max);
            cur.approve(address(auction), type(uint256).max);
            auction.stake(1e18);
            vm.stopPrank();
        }
    }

    function _next(uint256 p) internal view returns (uint256 n) {
        (n,,,,,,) = auction.ticks(p);
    }

    function _prev(uint256 p) internal view returns (uint256 n) {
        (, n,,,,,) = auction.ticks(p);
    }

    function test_restakeRelinksTheTick() public {
        vm.prank(bob);
        auction.submitBid(FLOOR, 5_000e18, bob, FLOOR);
        vm.prank(alice);
        auction.submitBid(P5, 1_000e18, alice, FLOOR);
        assertEq(auction.highestTick(), P5);

        // alice un-stakes to zero: her escrow stays bound to P5 but is not capacity — P5 is dead.
        vm.prank(alice);
        auction.unstake(1e18);
        (,, uint256 cap,,,,) = auction.ticks(P5);
        assertEq(cap, 0, "no stake, no capacity");

        // The sweep walks P5 (dead top) down to the floor and unlinks it.
        vm.roll(block.number + K);
        auction.sync(64);
        assertEq(auction.highestTick(), FLOOR, "high-water shaved to the floor");
        assertEq(_next(FLOOR), 0, "P5 dropped from the list");
        assertEq(_prev(P5), 0);

        // alice stakes again: her seat at P5 comes back — and so must the tick's place in the list.
        vm.prank(alice);
        auction.stake(1e18);
        assertEq(auction.highestTick(), P5, "P5 is the top again");
        assertEq(_next(FLOOR), P5, "P5 re-linked above the floor");
        assertEq(_prev(P5), FLOOR);

        vm.roll(block.number + K);
        auction.sync(64);
        (, uint256 owedA) = auction.positionOf(alice);
        (, uint256 owedB) = auction.positionOf(bob);
        assertGt(owedA, 0, "alice's revived seat is poured");
        assertGt(owedB, 0, "and the floor below it is still reached");
        assertApproxEqAbs(owedA, uint256(50e18) * 32 / 33, 1e6, "P5 (weight 1) vs floor (weight 1/32): 32/33");
    }
}
