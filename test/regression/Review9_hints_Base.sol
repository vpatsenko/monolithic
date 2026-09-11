// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GenerousAuction} from "../../src/GenerousAuction.sol";
import {Mono} from "../../src/Mono.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";
import {IIndex} from "../../src/interfaces/IIndex.sol";
import {MockPool} from "../MockPool.sol";
import {TestERC20} from "../TestERC20.sol";

/// Shared harness for the round-9 `hints` lens (insertion + re-link).
/// Deployment shape matches test/GenerousStaking.t.sol: Index/Mono at NAV 1.0, pool 1.25,
/// floor 1e18, spacing 1e16, q = Q96/2, windowTicks 8, roundBlocks 100.
abstract contract Review9HintsBase is Test {
    GenerousAuction internal auction;
    Mono internal mono;
    TestERC20 internal cur;

    uint256 internal constant GENESIS = 1_000_000e18;
    uint256 internal constant FLOOR = 1e18;
    uint256 internal constant SPACING = 1e16;
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant HALF = Q96 / 2;
    uint64 internal constant K = 100;
    address internal constant ADMIN = address(0xF1);

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
            })
        );
        mono.grantRole(mono.MINTER_ROLE(), address(auction));
        mono.renounceRole(mono.MINTER_ROLE(), address(this));
    }

    // ------------------------------------------------------------- actions

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
        try auction.submitBid(price, amount, who, prev) {
            ok = true;
        } catch {
            ok = false;
        }
        vm.stopPrank();
    }

    // ------------------------------------------------------------- reads

    function _next(uint256 price) internal view returns (uint256 nx) {
        (nx,,,,,,) = auction.ticks(price);
    }

    function _prev(uint256 price) internal view returns (uint256 pv) {
        (, pv,,,,,) = auction.ticks(price);
    }

    function _cap(uint256 price) internal view returns (uint256 c) {
        (,, c,,,,) = auction.ticks(price);
    }

    function _init(uint256 price) internal view returns (bool i) {
        (,,,,,, i) = auction.ticks(price);
    }

    function _owed(address who) internal view returns (uint256 owed) {
        (, owed) = auction.positionOf(who);
    }

    function _live(address who) internal view returns (uint256 live) {
        (live,) = auction.positionOf(who);
    }

    function _pos(address who) internal view returns (uint256 price) {
        (price,,,,,,) = auction.positions(who);
    }

    /// The honest UI hint: walk `next` up from the floor to the last node strictly below `price`.
    function _hintFor(uint256 price) internal view returns (uint256 q) {
        q = FLOOR;
        for (uint256 i; i < 512; ++i) {
            uint256 nx = _next(q);
            if (nx == 0 || nx >= price) return q;
            q = nx;
        }
        return q;
    }

    // ------------------------------------------------------------- the checker

    /// Full structural audit of the doubly-linked tick list, over BOTH chains.
    /// `grid` must be every price the test ever touches (initialised or not).
    /// Reverts with a named assertion the moment any of these fail:
    ///   D1  the `prev` walk from `highestTick` is strictly decreasing and terminates at the floor
    ///   D2  every node it visits is `init` and mutually linked with its neighbours
    ///   U1  the `next` walk from the floor is strictly increasing and terminates
    ///   U2  every node it visits is mutually linked
    ///   U3  the `next` walk's top is at or above `highestTick`
    ///   S1  every grid price is EITHER cleanly unlinked (prev == next == 0, not the floor)
    ///       OR fully mutually linked in both directions
    ///   S2  every tick with capacity is reachable by the `prev` walk from `highestTick`
    ///       (i.e. is on the sweep's chain)
    ///   S3  every tick with capacity is reachable by the `next` walk from the floor
    ///       (i.e. is on the hint/`_predecessor` chain)
    ///   S4  the two chains agree as SETS
    function _checkList(uint256[] memory grid, string memory tag) internal view {
        uint256 hi = auction.highestTick();
        require(hi != 0, "no high-water");
        (uint256[] memory down, uint256 dn) = _walkDown(hi, tag);
        (uint256[] memory up, uint256 un) = _walkUp(hi, tag);
        _scanGrid(grid, down, dn, up, un, tag);
        for (uint256 i; i < un; ++i) {
            if (up[i] > hi) continue;
            assertTrue(_inSet(down, dn, up[i]), string.concat(tag, ": S4 next-chain node off the prev chain"));
        }
    }

    function _walkDown(uint256 hi, string memory tag) internal view returns (uint256[] memory down, uint256 dn) {
        down = new uint256[](1024);
        uint256 p = hi;
        uint256 last = type(uint256).max;
        while (p != 0) {
            assertLt(p, last, string.concat(tag, ": D1 prev walk not strictly decreasing"));
            assertTrue(_init(p), string.concat(tag, ": D2 prev walk hit an uninitialised tick"));
            uint256 pv = _prev(p);
            uint256 nx = _next(p);
            if (pv != 0) assertEq(_next(pv), p, string.concat(tag, ": D2 prev.next != self"));
            if (nx != 0) assertEq(_prev(nx), p, string.concat(tag, ": D2 next.prev != self"));
            down[dn++] = p;
            last = p;
            p = pv;
            assertLt(dn, 1000, string.concat(tag, ": D1 prev walk did not terminate"));
        }
        assertEq(last, FLOOR, string.concat(tag, ": D1 prev walk did not end at the floor"));
    }

    function _walkUp(uint256 hi, string memory tag) internal view returns (uint256[] memory up, uint256 un) {
        up = new uint256[](1024);
        uint256 q = FLOOR;
        up[un++] = q;
        while (true) {
            uint256 nx = _next(q);
            if (nx == 0) break;
            assertGt(nx, q, string.concat(tag, ": U1 next walk not strictly increasing"));
            assertEq(_prev(nx), q, string.concat(tag, ": U2 next.prev != self"));
            q = nx;
            up[un++] = q;
            assertLt(un, 1000, string.concat(tag, ": U1 next walk did not terminate"));
        }
        assertGe(q, hi, string.concat(tag, ": U3 next walk stops below the high-water mark"));
    }

    function _scanGrid(
        uint256[] memory grid,
        uint256[] memory down,
        uint256 dn,
        uint256[] memory up,
        uint256 un,
        string memory tag
    ) internal view {
        for (uint256 i; i < grid.length; ++i) {
            uint256 price = grid[i];
            if (!_init(price)) continue;
            _scanOne(price, tag);
            if (_cap(price) != 0) {
                assertTrue(_inSet(down, dn, price), string.concat(tag, ": S2 live tick off the sweep chain"));
                assertTrue(_inSet(up, un, price), string.concat(tag, ": S3 live tick off the hint chain"));
            }
        }
    }

    function _scanOne(uint256 price, string memory tag) internal view {
        uint256 pv = _prev(price);
        uint256 nx = _next(price);
        if (price != FLOOR && pv == 0 && nx == 0) return; // cleanly unlinked
        if (price != FLOOR) {
            assertTrue(pv != 0, string.concat(tag, ": S1 half-linked (next set, prev zero)"));
            assertEq(_next(pv), price, string.concat(tag, ": S1 half-linked prev does not point back"));
        }
        if (nx != 0) assertEq(_prev(nx), price, string.concat(tag, ": S1 half-linked next does not point back"));
    }

    function _inSet(uint256[] memory a, uint256 n, uint256 v) internal pure returns (bool) {
        for (uint256 i; i < n; ++i) {
            if (a[i] == v) return true;
        }
        return false;
    }

    function _grid(uint256 n) internal pure returns (uint256[] memory g) {
        g = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            g[i] = FLOOR + i * SPACING;
        }
    }
}
