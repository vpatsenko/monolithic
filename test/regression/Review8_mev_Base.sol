// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GenerousAuction} from "../../src/GenerousAuction.sol";
import {Mono} from "../../src/Mono.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";
import {IIndex} from "../../src/interfaces/IIndex.sol";
import {MockPool} from "../MockPool.sol";
import {TestERC20} from "../TestERC20.sol";

/// Shared harness for the round-8 MEV / ordering lens. Same deployment as
/// `GenerousStaking.t.sol`: NAV 1.0, pool 1.25, floor 1e18, spacing 1e16, q = 1/2, window 8,
/// round 100 blocks.
abstract contract Review8MevBase is Test {
    GenerousAuction internal auction;
    Mono internal mono;
    TestERC20 internal cur;

    uint256 internal constant GENESIS = 1_000_000e18;
    uint256 internal constant FLOOR = 1e18;
    uint256 internal constant SPACING = 1e16;
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant HALF = Q96 / 2;
    uint64 internal constant K = 100;

    function P(uint256 i) internal pure returns (uint256) {
        return FLOOR + i * SPACING;
    }

    /// Smallest escrow that clears `submitBid`'s `amount*WAD >= price` gate at `price`, plus a
    /// wei so the tick has a token-wei of capacity. A "dust" bid that stays live below the band.
    function _dustAmt(uint256 price) internal pure returns (uint128) {
        return uint128(price / 1e18 + 2);
    }

    function _deploy(uint128 emission, uint64 end) internal {
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
                decayQ: HALF,
                windowTicks: 8,
                startBlock: uint64(block.number),
                endBlock: end,
                roundBlocks: K,
                emissionPerRound: emission,
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

    function _bid(address who, uint256 price, uint128 amount, uint256 prev) internal {
        cur.mint(who, amount);
        vm.startPrank(who);
        cur.approve(address(auction), amount);
        auction.submitBid(price, amount, who, prev);
        vm.stopPrank();
    }

    /// Bid with gas measured (the hint path is what this lens quantifies).
    function _bidGas(address who, uint256 price, uint128 amount, uint256 prev) internal returns (uint256 gas) {
        cur.mint(who, amount);
        vm.startPrank(who);
        cur.approve(address(auction), amount);
        gas = gasleft();
        auction.submitBid(price, amount, who, prev);
        gas -= gasleft();
        vm.stopPrank();
    }

    function _owed(address who) internal view returns (uint256 owed) {
        (, owed) = auction.positionOf(who);
    }

    function _live(address who) internal view returns (uint256 live) {
        (live,) = auction.positionOf(who);
    }

    function _cap(uint256 price) internal view returns (uint256 cap) {
        (,, cap,,,,) = auction.ticks(price);
    }

    function _next(uint256 price) internal view returns (uint256 n) {
        (n,,,,,,) = auction.ticks(price);
    }

    function _prev(uint256 price) internal view returns (uint256 p) {
        (, p,,,,,) = auction.ticks(price);
    }

    /// The contract's own `_linked` test, replayed on the public getter.
    function _linkedView(uint256 price) internal view returns (bool) {
        return price == FLOOR || _next(_prev(price)) == price;
    }

    /// Is `price` reachable by walking `next` up from the floor (the documented hint read)?
    function _reachableFromFloor(uint256 price) internal view returns (bool) {
        uint256 q = FLOOR;
        for (uint256 i; i < 10_000; ++i) {
            if (q == price) return true;
            q = _next(q);
            if (q == 0) return false;
        }
        return false;
    }

    /// Is `price` reachable by walking `prev` down from `highestTick` (the sweep's read)?
    function _reachableFromTop(uint256 price) internal view returns (bool) {
        uint256 q = auction.highestTick();
        for (uint256 i; i < 10_000; ++i) {
            if (q == price) return true;
            q = _prev(q);
            if (q == 0) return false;
        }
        return false;
    }

    /// The exact predecessor of `price` on the live list, as a UI would compute it.
    function _hint(uint256 price) internal view returns (uint256 q) {
        q = FLOOR;
        while (true) {
            uint256 nx = _next(q);
            if (nx == 0 || nx >= price) return q;
            q = nx;
        }
    }
}
