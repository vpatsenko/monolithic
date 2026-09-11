// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GenerousAuction} from "../../src/GenerousAuction.sol";
import {Mono} from "../../src/Mono.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";
import {IIndex} from "../../src/interfaces/IIndex.sol";
import {MockPool} from "../MockPool.sol";
import {TestERC20} from "../TestERC20.sol";

/// Review 8 / DoS lens — shared harness. Index/Mono/MockPool at NAV 1.0, pool 1.25, floor 1e18,
/// spacing 1e16, q = Q96/2, windowTicks 8, roundBlocks 100 unless a test overrides.
abstract contract Review8DosBase is Test {
    GenerousAuction internal auction;
    Mono internal mono;
    TestERC20 internal cur;

    uint256 internal constant GENESIS = 1_000_000e18;
    uint256 internal constant FLOOR = 1e18;
    uint256 internal constant SPACING = 1e16;
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant HALF = Q96 / 2;
    uint64 internal constant K = 100;

    function _deployWith(uint256 windowTicks_, uint256 q, uint128 emission, uint64 end) internal {
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
                decayQ: q,
                windowTicks: windowTicks_,
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

    function _deploy(uint128 emission, uint64 end) internal {
        _deployWith(8, HALF, emission, end);
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

    function _tryBid(address who, uint256 price, uint128 amount, uint256 prev)
        internal
        returns (bool ok, bytes memory ret)
    {
        cur.mint(who, amount);
        vm.startPrank(who);
        cur.approve(address(auction), amount);
        (ok, ret) = address(auction).call(abi.encodeCall(IGenerousAuction.submitBid, (price, amount, who, prev)));
        vm.stopPrank();
    }

    function _owed(address who) internal view returns (uint256 owed) {
        (, owed) = auction.positionOf(who);
    }

    function _live(address who) internal view returns (uint256 live) {
        (live,) = auction.positionOf(who);
    }

    function _next(uint256 p) internal view returns (uint256 n) {
        (n,,,,,,) = auction.ticks(p);
    }

    function _prev(uint256 p) internal view returns (uint256 n) {
        (, n,,,,,) = auction.ticks(p);
    }

    function _cap(uint256 p) internal view returns (uint256 c) {
        (,, c,,,,) = auction.ticks(p);
    }

    /// The predecessor hint the docs tell a UI to compute: walk `next` up from the floor on the
    /// public getter and return the highest linked tick below `price`.
    function _uiHint(uint256 price) internal view returns (uint256 q) {
        q = FLOOR;
        for (uint256 i; i < 100_000; ++i) {
            uint256 nx = _next(q);
            if (nx == 0 || nx >= price) return q;
            q = nx;
        }
    }

    /// Is `price` visited by a sweep that starts where the next `_sync` starts (cursor or
    /// high-water) and walks `prev`?
    function _sweepReaches(uint256 price) internal view returns (bool) {
        uint256 p = auction.settleCursor();
        if (p == 0) p = auction.highestTick();
        for (uint256 i; i < 100_000 && p != 0; ++i) {
            if (p == price) return true;
            p = _prev(p);
        }
        return false;
    }

    /// Is `price` reachable by walking `next` up from the floor (what a hint walk sees)?
    function _listReaches(uint256 price) internal view returns (bool) {
        uint256 p = FLOOR;
        for (uint256 i; i < 100_000 && p != 0; ++i) {
            if (p == price) return true;
            p = _next(p);
        }
        return false;
    }
}
