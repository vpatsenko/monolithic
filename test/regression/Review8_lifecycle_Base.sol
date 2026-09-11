// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GenerousAuction} from "../../src/GenerousAuction.sol";
import {Mono} from "../../src/Mono.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";
import {IIndex} from "../../src/interfaces/IIndex.sol";
import {MockPool} from "../MockPool.sol";
import {TestERC20} from "../TestERC20.sol";

/// Shared harness for the round-8 LIFECYCLE lens: Index/Mono/MockPool at NAV 1.0, pool 1.25,
/// floor 1e18, spacing 1e16, q = 1/2, windowTicks 8, roundBlocks 100.
abstract contract Review8LifecycleBase is Test {
    GenerousAuction internal auction;
    Mono internal mono;
    TestERC20 internal cur;
    MockPool internal pool;

    uint256 internal constant GENESIS = 1_000_000e18;
    uint256 internal constant FLOOR = 1e18;
    uint256 internal constant SPACING = 1e16;
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant HALF = Q96 / 2;
    uint256 internal constant WAD = 1e18;
    uint64 internal constant K = 100;
    address internal constant ADMIN = address(0xF1);

    address internal aa = address(0xA1);
    address internal bb = address(0xA2);
    address internal cc = address(0xA3);
    address internal dd = address(0xA4);

    function P(uint256 i) internal pure returns (uint256) {
        return FLOOR + i * SPACING;
    }

    function _freshMono() internal {
        cur = new TestERC20("Index", "INDEX");
        mono = new Mono(IIndex(address(cur)), 10 * GENESIS);
        cur.mint(address(this), GENESIS);
        cur.approve(address(mono), GENESIS);
        mono.mint(GENESIS, GENESIS, address(this));
        pool = new MockPool(address(mono), address(cur), 1.25e18);
        mono.setPool(address(pool));
    }

    function _config(uint128 emission, uint64 end) internal view returns (IGenerousAuction.Config memory c) {
        c = IGenerousAuction.Config({
            token: address(mono),
            currency: address(cur),
            admin: ADMIN,
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
        });
    }

    function _deployWith(IGenerousAuction.Config memory c) internal {
        auction = new GenerousAuction(c);
        mono.grantRole(mono.MINTER_ROLE(), address(auction));
        if (mono.hasRole(mono.MINTER_ROLE(), address(this))) mono.renounceRole(mono.MINTER_ROLE(), address(this));
    }

    function _deploy(uint128 emission, uint64 end) internal {
        _freshMono();
        _deployWith(_config(emission, end));
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

    /// Bid enough at `price` to buy exactly `capTokens` there (1e18 stake unless already staked).
    function _bidCap(address who, uint256 price, uint256 capTokens, uint256 prev) internal {
        if (auction.stakes(who) == 0) _stakeFor(who, 1e18);
        _bid(who, price, uint128((capTokens * price) / WAD), prev);
    }

    function _owed(address who) internal view returns (uint256 owed) {
        (, owed) = auction.positionOf(who);
    }

    function _live(address who) internal view returns (uint256 live) {
        (live,) = auction.positionOf(who);
    }

    function _next(uint256 price) internal view returns (uint256 n) {
        (n,,,,,,) = auction.ticks(price);
    }

    function _prev(uint256 price) internal view returns (uint256 p) {
        (, p,,,,,) = auction.ticks(price);
    }

    function _cap(uint256 price) internal view returns (uint256 c) {
        (,, c,,,,) = auction.ticks(price);
    }

    /// True when `price` is reachable by the sweep's downward walk from `highestTick`.
    function _reachable(uint256 price) internal view returns (bool) {
        uint256 q = auction.highestTick();
        for (uint256 i; i < 4096 && q != 0; ++i) {
            if (q == price) return true;
            q = _prev(q);
        }
        return false;
    }
}
