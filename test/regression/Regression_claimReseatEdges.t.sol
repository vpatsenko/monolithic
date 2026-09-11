// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GenerousAuction} from "../../src/GenerousAuction.sol";
import {Mono} from "../../src/Mono.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";
import {IIndex} from "../../src/interfaces/IIndex.sol";
import {MockPool} from "../MockPool.sol";
import {TestERC20} from "../TestERC20.sol";

/// `_claim` re-seats after harvesting (round-8 fix). `claim(owner)` is permissionless, so the
/// re-seat runs on positions the caller does not control: pin the edges it must survive — an
/// owner who un-staked to zero (not seated: the re-seat must be inert, not divide by zero), a
/// position that exhausted exactly (leaves the heap instead of lingering as a stale seat), and
/// `claimAndStake`, whose own re-seat must agree with the one `_claim` just did.
contract RegressionClaimReseatEdges is Test {
    GenerousAuction internal auction;
    Mono internal mono;
    TestERC20 internal cur;

    uint256 internal constant GENESIS = 1_000_000e18;
    uint256 internal constant FLOOR = 1e18;
    uint256 internal constant SPACING = 1e16;
    uint256 internal constant Q96 = 1 << 96;
    uint64 internal constant K = 100;
    uint256 internal constant P1 = FLOOR + SPACING;

    address internal aa = address(0xA1);
    address internal bb = address(0xA2);
    address internal stranger = address(0x5719);

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
                emissionPerRound: 100e18,
                minPremiumBips: 1_500,
                previousAuction: address(0)
            })
        );
        mono.grantRole(mono.MINTER_ROLE(), address(auction));
        mono.renounceRole(mono.MINTER_ROLE(), address(this));
        address[2] memory all = [aa, bb];
        for (uint256 i; i < 2; ++i) {
            mono.transfer(all[i], 10e18);
            cur.mint(all[i], 10_000e18);
            vm.startPrank(all[i]);
            mono.approve(address(auction), type(uint256).max);
            cur.approve(address(auction), type(uint256).max);
            auction.stake(1e18);
            vm.stopPrank();
        }
    }

    function _seat(address who) internal view returns (uint32 idx) {
        (,,,,,, idx) = auction.positions(who);
    }

    /// An owner who un-staked to zero keeps live escrow but no seat. A stranger's claim must be
    /// a no-op on the seat, not a revert.
    function test_claimOnUnstakedOwnerIsInert() public {
        vm.prank(aa);
        auction.submitBid(P1, 1_000e18, aa, FLOOR);
        vm.roll(block.number + K);
        auction.sync(64);
        vm.prank(aa);
        auction.unstake(1e18);
        assertEq(auction.stakes(aa), 0, "no stake");
        assertEq(_seat(aa), 0, "and no seat");
        (uint256 liveBefore, uint256 owedBefore) = auction.positionOf(aa);
        assertGt(liveBefore, 0, "escrow still bound");

        vm.roll(block.number + K);
        vm.prank(stranger);
        uint256 paid = auction.claim(aa);
        assertEq(paid, owedBefore, "the stranger's claim pays the owner what was owed");
        assertEq(_seat(aa), 0, "still unseated");
        (uint256 liveAfter,) = auction.positionOf(aa);
        assertEq(liveAfter, liveBefore, "and nothing accrued while un-staked");

        vm.prank(aa);
        assertEq(auction.withdrawBid(), liveAfter, "escrow comes back in full");
    }

    /// A position that exhausted leaves the heap on the claim that harvests it, instead of
    /// lingering as a stale seat until some later pour pops it.
    function test_claimOnExhaustedPositionLeavesTheHeap() public {
        vm.prank(aa);
        auction.submitBid(P1, 50e18, aa, FLOOR); // small: fills inside one round
        vm.prank(bb);
        auction.submitBid(FLOOR, 5_000e18, bb, FLOOR);
        vm.roll(block.number + 10 * K);
        auction.sync(64);
        (uint256 live,) = auction.positionOf(aa);
        assertEq(live, 0, "aa's escrow is spent");

        auction.claim(aa);
        assertEq(_seat(aa), 0, "exhausted position left the heap");
        (,,, uint256 stakeSum,, uint32 heapSize,) = auction.ticks(P1);
        assertEq(heapSize, 0, "tick's heap is empty");
        assertEq(stakeSum, 0, "and carries no stake");
    }

    /// `claimAndStake` reads the stake AFTER `_claim` re-seated at it, so the two re-seats agree
    /// and the compounded stake weighs from the claim onward.
    function test_claimAndStakeAgreesWithTheClaimReseat() public {
        vm.prank(aa);
        auction.submitBid(P1, 5_000e18, aa, FLOOR);
        vm.prank(bb);
        auction.submitBid(P1, 5_000e18, bb, FLOOR);
        vm.roll(block.number + K);
        auction.sync(64);

        uint256 stakeBefore = auction.stakes(aa);
        vm.prank(aa);
        uint256 got = auction.claimAndStake();
        assertGt(got, 0, "claimed something");
        assertEq(auction.stakes(aa), stakeBefore + got, "compounded");
        assertGt(_seat(aa), 0, "still seated");
        (,,, uint256 stakeSum,,,) = auction.ticks(P1);
        assertEq(stakeSum, auction.stakes(aa) + auction.stakes(bb), "tick's stakeSum matches the ledger");

        // And the compounded weight is forward-only: the next round splits by the NEW stakes.
        vm.roll(block.number + K);
        auction.sync(64);
        (, uint256 owedA) = auction.positionOf(aa);
        (, uint256 owedB) = auction.positionOf(bb);
        assertGt(owedA, owedB, "the compounded stake earns more from here on");
    }
}
