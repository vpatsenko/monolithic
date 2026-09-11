// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GenerousAuction} from "../../src/GenerousAuction.sol";
import {Mono} from "../../src/Mono.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";
import {IIndex} from "../../src/interfaces/IIndex.sol";
import {MockPool} from "../MockPool.sol";
import {TestERC20} from "../TestERC20.sol";

/// Review 9 / SWEEP lens — shared harness. Index/Mono/MockPool at NAV 1.0, pool 1.25,
/// floor 1e18, spacing 1e16, q = Q96/2, windowTicks 8, roundBlocks 100.
abstract contract Review9SweepBase is Test {
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

    function _tryBid(address who, uint256 price, uint128 amount, uint256 prev) internal returns (bool ok) {
        cur.mint(who, amount);
        vm.startPrank(who);
        cur.approve(address(auction), amount);
        (ok,) = address(auction).call(abi.encodeCall(IGenerousAuction.submitBid, (price, amount, who, prev)));
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- list readers

    function _next(uint256 p) internal view returns (uint256 n) {
        (n,,,,,,) = auction.ticks(p);
    }

    function _prev(uint256 p) internal view returns (uint256 n) {
        (, n,,,,,) = auction.ticks(p);
    }

    function _cap(uint256 p) internal view returns (uint256 c) {
        (,, c,,,,) = auction.ticks(p);
    }

    function _init(uint256 p) internal view returns (bool i) {
        (,,,,,, i) = auction.ticks(p);
    }

    function _heapSize(uint256 p) internal view returns (uint32 h) {
        (,,,,, h,) = auction.ticks(p);
    }

    function _live(address who) internal view returns (uint256 l) {
        (l,) = auction.positionOf(who);
    }

    function _owed(address who) internal view returns (uint256 o) {
        (, o) = auction.positionOf(who);
    }

    /// Where the NEXT `_sync` starts its walk.
    function _sweepStart() internal view returns (uint256 p) {
        p = auction.settleCursor();
        if (p == 0) p = auction.highestTick();
    }

    /// Walk `prev` down from `start`; true when `price` is on it.
    function _prevReaches(uint256 start, uint256 price) internal view returns (bool) {
        uint256 p = start;
        for (uint256 i; i < 5000 && p != 0; ++i) {
            if (p == price) return true;
            p = _prev(p);
        }
        return false;
    }

    /// Walk `next` up from the floor; true when `price` is on it.
    function _listReaches(uint256 price) internal view returns (bool) {
        uint256 p = FLOOR;
        for (uint256 i; i < 5000 && p != 0; ++i) {
            if (p == price) return true;
            p = _next(p);
        }
        return false;
    }

    /// The predecessor hint a UI computes (walk `next` up from the floor).
    function _uiHint(uint256 price) internal view returns (uint256 q) {
        q = FLOOR;
        for (uint256 i; i < 5000; ++i) {
            uint256 nx = _next(q);
            if (nx == 0 || nx >= price) return q;
            q = nx;
        }
    }

    // ---------------------------------------------------------------- the checker
    //
    // Everything the sweep machinery must keep true, over a caller-supplied universe of prices.

    /// A. `prev` from the sweep start terminates at the floor, strictly decreasing, mutual links.
    /// B. `next` from the floor terminates, strictly increasing, mutual links.
    /// C. Every price with capacity is on BOTH walks (the sweep must reach it; a hint walk must
    ///    place a bid relative to it).
    /// D. No initialised price is half-linked.
    function _assertSound(uint256[] memory universe, string memory tag) internal view {
        // A
        uint256 p = _sweepStart();
        uint256 last = type(uint256).max;
        uint256 steps;
        while (p != 0) {
            require(p < last, string.concat(tag, ": prev walk not strictly decreasing"));
            require(_init(p), string.concat(tag, ": prev walk hit an uninitialised tick"));
            uint256 pv = _prev(p);
            if (pv != 0) require(_next(pv) == p, string.concat(tag, ": prev.next != self"));
            uint256 nx = _next(p);
            if (nx != 0) require(_prev(nx) == p, string.concat(tag, ": next.prev != self"));
            last = p;
            p = pv;
            require(++steps < 4000, string.concat(tag, ": prev walk did not terminate"));
        }
        require(last == FLOOR, string.concat(tag, ": prev walk did not end at the floor"));

        // B
        uint256 up = FLOOR;
        uint256 upSteps;
        while (true) {
            uint256 nx = _next(up);
            if (nx == 0) break;
            require(nx > up, string.concat(tag, ": next walk not strictly increasing"));
            require(_prev(nx) == up, string.concat(tag, ": next.prev != self on the up walk"));
            up = nx;
            require(++upSteps < 4000, string.concat(tag, ": next walk did not terminate"));
        }

        for (uint256 i; i < universe.length; ++i) {
            uint256 q = universe[i];
            if (!_init(q)) continue;
            // D
            uint256 pv = _prev(q);
            uint256 nx = _next(q);
            if (q != FLOOR && !(pv == 0 && nx == 0)) {
                require(_next(pv) == q, string.concat(tag, ": half-linked (prev does not point back)"));
                if (nx != 0) require(_prev(nx) == q, string.concat(tag, ": half-linked (next does not point back)"));
            }
            // C
            if (_cap(q) == 0) continue;
            require(_prevReaches(_sweepStart(), q), string.concat(tag, ": LIVE TICK NOT REACHED BY THE SWEEP"));
            require(_listReaches(q), string.concat(tag, ": live tick not on the next chain from the floor"));
        }
    }
}
