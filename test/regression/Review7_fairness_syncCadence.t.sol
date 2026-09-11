// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GenerousAuction} from "../../src/GenerousAuction.sol";
import {Mono} from "../../src/Mono.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";
import {IIndex} from "../../src/interfaces/IIndex.sol";
import {MockPool} from "../MockPool.sol";
import {TestERC20} from "../TestERC20.sol";

/// Review 7 / fairness lens — sync-cadence invariance.
///
/// `_sync`'s docstring: "The whole backlog goes in as ONE supply figure rather than round by
/// round. That is not an approximation: `_pour` is parameterised by the scalar `C` and relative
/// weights are anchor-independent, so `N*R` in one sweep lands where `N` sweeps of `R` would."
///
/// That holds INSIDE the band, but the band `[tau - windowTicks*spacing, tau]` is fixed for the
/// whole sweep and only re-anchors on the NEXT sync. A tick just outside the band is therefore
/// admitted the moment the top dries if someone syncs then, and kept out until the whole window
/// exhausts if nobody does. The allocation is a function of who called `sync` when.
contract Review7FairnessSyncCadenceTest is Test {
    GenerousAuction internal auction;
    Mono internal mono;
    TestERC20 internal cur;

    uint256 internal constant GENESIS = 1_000_000e18;
    uint256 internal constant FLOOR = 1e18;
    uint256 internal constant SPACING = 1e16;
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant HALF = Q96 / 2;
    uint64 internal constant K = 100;
    uint128 internal constant R = 100e18; // 1e18 per block

    address internal top = address(0xA1); // tick 9: dries early
    address internal mid = address(0xA2); // tick 1: in the band of tick 9 (d = 8), ample
    address internal low = address(0xA3); // tick 0: OUTSIDE the band of tick 9, inside tick 1's

    function _deploy() internal {
        cur = new TestERC20("Index", "INDEX");
        mono = new Mono(IIndex(address(cur)), 10 * GENESIS);
        cur.mint(address(this), GENESIS);
        cur.approve(address(mono), GENESIS);
        mono.mint(GENESIS, GENESIS, address(this));
        MockPool pool = new MockPool(address(mono), address(cur), 1.25e18);
        pool.setLiquidity(1e27);
        mono.setPool(address(pool));
        auction = new GenerousAuction(
            IGenerousAuction.Config({
                token: address(mono),
                currency: address(cur),
                admin: address(0xF1),
                floorPrice: FLOOR,
                tickSpacing: SPACING,
                decayQ: HALF,
                windowTicks: 8,
                startBlock: uint64(block.number),
                endBlock: 0,
                roundBlocks: K,
                emissionPerRound: R,
                minPremiumBips: 1_500,
                previousAuction: address(0)
            })
        );
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

    function _bid(address who, uint256 price, uint256 amount, uint256 prev) internal {
        cur.mint(who, amount);
        vm.startPrank(who);
        cur.approve(address(auction), amount);
        auction.submitBid(price, uint128(amount), who, prev);
        vm.stopPrank();
    }

    function _owed(address who) internal view returns (uint256 owed) {
        (, owed) = auction.positionOf(who);
    }

    /// Same book, same emission (`blocks` tokens): one sync at the end vs. one sync per block.
    function _book() internal {
        _deploy();
        _stakeFor(top, 1e18);
        _stakeFor(mid, 1e18);
        _stakeFor(low, 1e18);
        _bid(low, FLOOR, 10_000e18, FLOOR);
        _bid(mid, FLOOR + SPACING, 10_000e18, FLOOR);
        // tick 9 holds 10 tokens of capacity at 1.09: dries after ~10 blocks of emission
        _bid(top, FLOOR + 9 * SPACING, 10.9e18, FLOOR + SPACING);
    }

    function test_cadenceChangesAllocation() public {
        uint256 blocks = 100;

        _book();
        vm.roll(block.number + blocks);
        auction.sync(1000);
        uint256 lowOne = _owed(low);
        uint256 midOne = _owed(mid);
        uint256 topOne = _owed(top);

        _book();
        for (uint256 i; i < blocks; ++i) {
            vm.roll(block.number + 1);
            auction.sync(1000);
        }
        uint256 lowMany = _owed(low);
        uint256 midMany = _owed(mid);
        uint256 topMany = _owed(top);

        emit log_named_uint("top  (tick 9): one sync", topOne);
        emit log_named_uint("top  (tick 9): per-block", topMany);
        emit log_named_uint("mid  (tick 1): one sync", midOne);
        emit log_named_uint("mid  (tick 1): per-block", midMany);
        emit log_named_uint("low  (tick 0): one sync", lowOne);
        emit log_named_uint("low  (tick 0): per-block", lowMany);
        emit log_named_uint("sold: one sync", auction.tokensSold());

        // The docstring's claim: N sweeps of R land where one sweep of N*R does.
        assertApproxEqAbs(lowMany, lowOne, 1e12, "tick 0's take depends on sync cadence");
        assertApproxEqAbs(midMany, midOne, 1e12, "tick 1's take depends on sync cadence");
    }

    /// Control: with tick 4 INSIDE tick 9's band (d = 5) the claim holds — q^d ratios are
    /// shift-invariant, so re-anchoring at tick 5 after tick 9 dries changes nothing.
    function test_cadenceInvariantInsideBand() public {
        uint256 blocks = 100;
        _deploy();
        _stakeFor(top, 1e18);
        _stakeFor(mid, 1e18);
        _stakeFor(low, 1e18);
        _bid(low, FLOOR + 4 * SPACING, 10_000e18, FLOOR);
        _bid(mid, FLOOR + 5 * SPACING, 10_000e18, FLOOR + 4 * SPACING);
        _bid(top, FLOOR + 9 * SPACING, 10.9e18, FLOOR + 5 * SPACING);
        vm.roll(block.number + blocks);
        auction.sync(1000);
        uint256 lowOne = _owed(low);
        uint256 midOne = _owed(mid);

        _deploy();
        _stakeFor(top, 1e18);
        _stakeFor(mid, 1e18);
        _stakeFor(low, 1e18);
        _bid(low, FLOOR + 4 * SPACING, 10_000e18, FLOOR);
        _bid(mid, FLOOR + 5 * SPACING, 10_000e18, FLOOR + 4 * SPACING);
        _bid(top, FLOOR + 9 * SPACING, 10.9e18, FLOOR + 5 * SPACING);
        for (uint256 i; i < blocks; ++i) {
            vm.roll(block.number + 1);
            auction.sync(1000);
        }
        emit log_named_uint("in-band low (tick 4): one sync", lowOne);
        emit log_named_uint("in-band low (tick 4): per-block", _owed(low));
        emit log_named_uint("in-band mid (tick 5): one sync", midOne);
        emit log_named_uint("in-band mid (tick 5): per-block", _owed(mid));
        assertApproxEqAbs(_owed(low), lowOne, 1e6, "inside the band the cadence does not matter");
        assertApproxEqAbs(_owed(mid), midOne, 1e6, "inside the band the cadence does not matter");
    }
}
