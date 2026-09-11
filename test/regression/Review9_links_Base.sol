// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GenerousAuction} from "../../src/GenerousAuction.sol";
import {Mono} from "../../src/Mono.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";
import {IIndex} from "../../src/interfaces/IIndex.sol";
import {MockPool} from "../MockPool.sol";
import {TestERC20} from "../TestERC20.sol";

/// Shared deploy + the strongest two-chain tick-list checker for review round 9 (lens: links).
///
/// Stricter than the suite's `invariant_tickListSound`:
///   * both chains are materialised as SETS and compared, not spot-checked;
///   * `settleCursor` and `highestTick` are required to be nodes of the LIVE list;
///   * the sweep chain must be a suffix of the floor chain (so `_predecessor` and `_gather`
///     cannot disagree about where a price belongs);
///   * every tick with `capTokens != 0` must be on the SWEEP's chain (down from `highestTick`);
///   * a separate position-side predicate: a funded, staked bid must sit on the sweep chain.
abstract contract Review9LinksBase is Test {
    GenerousAuction internal auction;
    Mono internal mono;
    TestERC20 internal cur;

    uint256 internal constant GENESIS = 1_000_000e18;
    uint256 internal constant FLOOR = 1e18;
    uint256 internal constant SPACING = 1e16;
    uint256 internal constant Q96 = 1 << 96;
    uint64 internal constant K = 100;

    /// Prices the checker scans, registered once by the concrete test. Everything the list can
    /// possibly contain must be in here, or the walks below report "left the grid".
    uint256[] internal gridPrices;
    mapping(uint256 => uint256) internal gridIdx; // 1-based; 0 = not a registered price

    function _registerGrid(uint256 steps) internal {
        for (uint256 i; i <= steps; ++i) {
            _registerPrice(FLOOR + i * SPACING);
        }
    }

    function _registerPrice(uint256 price) internal {
        if (gridIdx[price] != 0) return;
        gridPrices.push(price);
        gridIdx[price] = gridPrices.length;
    }

    function _deploy(uint64 endBlock_, uint128 emission) internal {
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
                endBlock: endBlock_,
                roundBlocks: K,
                emissionPerRound: emission,
                minPremiumBips: 1_500,
                previousAuction: address(0)
            })
        );
        mono.grantRole(mono.MINTER_ROLE(), address(auction));
        mono.renounceRole(mono.MINTER_ROLE(), address(this));
    }

    function _idx(uint256 price) internal view returns (uint256) {
        uint256 i = gridIdx[price];
        require(i != 0, "checker: price outside the registered grid");
        return i - 1;
    }

    /// The whole structural contract, in one place. Reverts with a named assertion on any break.
    function _checkList() internal view {
        uint256 n = gridPrices.length;
        uint256 hi = auction.highestTick();
        assertTrue(hi != 0, "L0: no high-water");

        bool[] memory onDown = new bool[](n);
        bool[] memory onUp = new bool[](n);
        uint256 guard = n + 4; // cycle guard

        // ---- 1. downward walk from `highestTick` — exactly what `_gather` does
        uint256 last = type(uint256).max;
        uint256 steps;
        {
            uint256 p = hi;
            while (p != 0) {
                assertLt(p, last, "L1: down walk not strictly decreasing (cycle/self-loop)");
                (uint256 nx, uint256 pv,,,,, bool init) = auction.ticks(p);
                assertTrue(init, "L2: down walk reached an uninitialised tick");
                if (pv != 0) {
                    (uint256 pvNext,,,,,,) = auction.ticks(pv);
                    assertEq(pvNext, p, "L3: prev.next != self on the down walk");
                }
                if (nx != 0) {
                    (, uint256 nxPrev,,,,,) = auction.ticks(nx);
                    assertEq(nxPrev, p, "L4: next.prev != self on the down walk");
                }
                onDown[_idx(p)] = true;
                assertLt(++steps, guard, "L5: down walk did not terminate");
                last = p;
                p = pv;
            }
            assertEq(last, FLOOR, "L6: down walk did not end at the floor");
        }

        // ---- 2. upward walk from the floor — what `_predecessor` and a UI do
        uint256 top;
        {
            uint256 q = FLOOR;
            onUp[0] = true;
            uint256 us;
            while (true) {
                (uint256 nx,,,,,,) = auction.ticks(q);
                if (nx == 0) break;
                assertGt(nx, q, "L7: up walk not strictly increasing (cycle/self-loop)");
                (, uint256 nxPrev,,,,,) = auction.ticks(nx);
                assertEq(nxPrev, q, "L8: next.prev != self on the up walk");
                onUp[_idx(nx)] = true;
                assertLt(++us, guard, "L9: up walk did not terminate");
                q = nx;
            }
            top = q;
        }

        // ---- 3. the two chains must agree: everything the sweep walks is on the floor chain.
        //         The floor chain may run ABOVE `highestTick` (dead ex-tops the sweep shaved
        //         past) but never below it.
        for (uint256 i; i < n; ++i) {
            if (onDown[i]) assertTrue(onUp[i], "L10: node on the sweep chain is not on the floor chain");
        }
        assertGe(top, hi, "L11: up walk stops below the high-water mark");

        // ---- 4. anchors must be live nodes
        assertTrue(onUp[_idx(hi)], "L12: highestTick is not a linked node");
        uint256 sc = auction.settleCursor();
        if (sc != 0) {
            assertTrue(onUp[_idx(sc)], "L13: settleCursor is not a linked node");
            assertLe(sc, hi, "L13b: settleCursor above the high-water mark");
        }

        // ---- 5. the whole grid: cleanly unlinked, or linked both ways; capacity on the sweep.
        for (uint256 i; i < n; ++i) {
            uint256 price = gridPrices[i];
            (uint256 nx, uint256 pv, uint256 capTokens,,,, bool init) = auction.ticks(price);
            if (!init) continue;
            if (price != FLOOR) {
                if (pv == 0 && nx == 0) {
                    // cleanly unlinked. A SEATED but capacity-exhausted position may still sit
                    // here (`_pourTick` leaves the dust seat), but capacity may not.
                    assertEq(capTokens, 0, "L14: unlinked tick still carries capacity");
                } else {
                    (uint256 pvNext,,,,,,) = auction.ticks(pv);
                    assertEq(pvNext, price, "L16: half-linked (prev does not point back)");
                    if (nx != 0) {
                        (, uint256 nxPrev,,,,,) = auction.ticks(nx);
                        assertEq(nxPrev, price, "L17: half-linked (next does not point back)");
                    }
                }
            }
            if (capTokens != 0) {
                assertTrue(onDown[i], "L18: tick with capacity is off the sweep chain");
                // L21 -- the load-bearing assumption of the whole resume path: `_sync` restarts
                // at `settleCursor` and shaves `highestTick` down to each window's `tau`, which
                // is only sound if EVERYTHING above the cursor is already dry. If a tick above
                // the cursor still has capacity, the resumed sweep will shave the high-water
                // below it and strand it.
                if (sc != 0) assertLe(price, sc, "L21: live capacity ABOVE settleCursor");
            }
        }
    }

    /// The economic mirror of L18, driven from the POSITION side: an owner with stake and live
    /// escrow that still buys at least one token-wei must sit at a tick the sweep can reach.
    /// This is the "orphaned honest bid" predicate of rounds 6-8.
    function _checkPositionsReachable(address[] memory owners) internal view {
        uint256 n = gridPrices.length;
        bool[] memory onDown = new bool[](n);
        uint256 p = auction.highestTick();
        uint256 guard;
        while (p != 0 && guard++ <= n + 2) {
            onDown[_idx(p)] = true;
            (, p,,,,,) = auction.ticks(p);
        }
        for (uint256 i; i < owners.length; ++i) {
            (uint256 price,,,,,,) = auction.positions(owners[i]);
            if (price == 0) continue;
            if (auction.stakes(owners[i]) == 0) continue;
            (uint256 live,) = auction.positionOf(owners[i]);
            if (live * 1e18 < price) continue; // buys nothing: inert by the strict rule
            assertTrue(onDown[_idx(price)], "L20: a funded, staked bid sits off the sweep chain");
        }
    }
}
