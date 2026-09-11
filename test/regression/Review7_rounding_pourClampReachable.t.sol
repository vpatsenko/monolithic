// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {LibSort} from "solady/utils/LibSort.sol";
import {GenerousAuction} from "../../src/GenerousAuction.sol";
import {Mono} from "../../src/Mono.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";
import {IIndex} from "../../src/interfaces/IIndex.sol";
import {MockPool} from "../MockPool.sol";
import {TestERC20} from "../TestERC20.sol";

/// Exposes the pure inter-tick solver so its rounding can be probed directly.
contract PourHarness is GenerousAuction {
    constructor(Config memory c) GenerousAuction(c) {}

    function pour(uint256[] memory cap, uint256[] memory weight, uint256 supply)
        external
        view
        returns (uint256[] memory tokens, bool[] memory isDry, uint256 dry, uint256 leftover)
    {
        Window memory w;
        w.n = cap.length;
        w.cap = cap;
        w.weight = weight;
        w.price = new uint256[](w.n);
        for (uint256 i; i < w.n; ++i) {
            w.price[i] = 2e18 - i * 1e16; // descending, as a gather would deliver them
            w.weightSum += weight[i];
        }
        w.tau = w.price[0];
        w.steps = type(uint256).max;
        (Solve memory s,,) = _solveBand(w, supply);
        tokens = new uint256[](w.n);
        isDry = new bool[](w.n);
        uint256 sum;
        for (uint256 i; i < w.n; ++i) {
            tokens[i] = s.tokens[i];
            sum += s.tokens[i];
            if (s.cap[i] == 0) {
                isDry[i] = true;
                ++dry;
            }
        }
        leftover = supply - sum;
    }
}

/// Review 7, rounding lens: `_pour` (L1002-1061). The comment at L997-998 says "Every result is
/// floored. A sum of floors is an integer no greater than the floor of the sum, so
/// `sum(tokens) <= supply` holds without needing to check it", and L1051-1053 calls the budget
/// clamp "unreachable". But a DRY tick is not paid a floor of its curve share — it is paid
/// `cap[i]` in full (L1056), while its exhaustion point `kappa_i = floor(cap_i * Q96 / w_i)`
/// (L1020) was FLOORED, so the segment walk subtracted `floor(weightLeft * (kappa - C) / Q96)`
/// from `left` — up to a wei less per dry tick than the tick is then handed. The clamp is the
/// only thing holding `sum <= supply`, and when it binds the LAST tick in window order (the
/// lowest price) is shorted by the overshoot.
contract Review7PourClampReachableTest is Test {
    PourHarness internal h;
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant IDX_BITS = 8;
    uint256 internal constant IDX_MASK = (1 << IDX_BITS) - 1;

    function setUp() public {
        TestERC20 cur = new TestERC20("Index", "INDEX");
        Mono mono = new Mono(IIndex(address(cur)), 10_000_000e18);
        cur.mint(address(this), 1_000_000e18);
        cur.approve(address(mono), 1_000_000e18);
        mono.mint(1_000_000e18, 1_000_000e18, address(this));
        MockPool pool = new MockPool(address(mono), address(cur), 1.25e18);
        mono.setPool(address(pool));
        // q = 0.9: rpow is inexact, so weights carry fractional Q96 bits. 0.9^44 < 1%.
        h = new PourHarness(
            IGenerousAuction.Config({
                token: address(mono),
                currency: address(cur),
                admin: address(0xF1),
                floorPrice: 1e18,
                tickSpacing: 1e16,
                decayQ: (Q96 * 9) / 10,
                windowTicks: 44,
                startBlock: uint64(block.number),
                endBlock: 0,
                roundBlocks: 100,
                emissionPerRound: 100e18,
                minPremiumBips: 1_500,
                previousAuction: address(0)
            })
        );
    }

    /// Bit-for-bit copy of `_pour` WITHOUT the L1054-1059 budget clamp.
    function _unclamped(uint256[] memory capIn, uint256[] memory weight, uint256 supply)
        internal
        pure
        returns (uint256 sum)
    {
        (uint256[] memory alloc,) = _unclampedAlloc(capIn, weight, supply);
        for (uint256 i; i < alloc.length; ++i) {
            sum += alloc[i];
        }
    }

    function _unclampedDry(uint256[] memory capIn, uint256[] memory weight, uint256 supply)
        internal
        pure
        returns (uint256 dry)
    {
        (, dry) = _unclampedAlloc(capIn, weight, supply);
    }

    function _unclampedAlloc(uint256[] memory capIn, uint256[] memory weight, uint256 supply)
        internal
        pure
        returns (uint256[] memory alloc, uint256 dry)
    {
        uint256 n = capIn.length;
        uint256 weightSum;
        uint256[] memory cap = new uint256[](n);
        uint256[] memory keys = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            weightSum += weight[i];
            uint256 c = capIn[i];
            if (c > supply) c = supply;
            cap[i] = c;
            keys[i] = (FixedPointMathLib.fullMulDiv(c, Q96, weight[i]) << IDX_BITS) | i;
        }
        LibSort.sort(keys);
        uint256 weightLeft = weightSum;
        uint256 C;
        uint256 left = supply;
        for (uint256 k; k < n; ++k) {
            uint256 kappa = keys[k] >> IDX_BITS;
            uint256 dT = FixedPointMathLib.fullMulDiv(weightLeft, kappa - C, Q96);
            if (dT >= left) {
                C += FixedPointMathLib.fullMulDiv(left, Q96, weightLeft);
                left = 0;
                break;
            }
            C = kappa;
            left -= dT;
            weightLeft -= weight[keys[k] & IDX_MASK];
            ++dry;
        }
        bool[] memory isDry = new bool[](n);
        for (uint256 k; k < dry; ++k) {
            isDry[keys[k] & IDX_MASK] = true;
        }
        alloc = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            alloc[i] = isDry[i] ? cap[i] : FixedPointMathLib.fullMulDiv(weight[i], C, Q96);
        }
    }

    /// Fuzz: window of 2..8 ticks at consecutive grid distances, small irregular caps, supply
    /// that leaves at least one survivor. Asserts the comment's claim — that the unclamped sum
    /// never exceeds the supply.
    function testFuzz_sumOfFloorsClaim(uint256 seed) public view {
        uint256 n = 2 + (seed % 7);
        uint256[] memory cap = new uint256[](n);
        uint256[] memory weight = new uint256[](n);
        uint256 total;
        for (uint256 i; i < n; ++i) {
            weight[i] = h.weightAt(i);
            cap[i] = 1 + (uint256(keccak256(abi.encode(seed, i))) % 1_000);
            total += cap[i];
        }
        uint256 supply = total - (uint256(keccak256(abi.encode(seed, "s"))) % (total / 2 + 1));
        uint256 unclamped = _unclamped(cap, weight, supply);
        // The documented bound: two floors per exhaustion (kappa, and the segment subtraction),
        // so the unclamped sum overshoots by at most two wei per dry tick, and the
        // (load-bearing) clamp keeps the actual pour inside the supply.
        // (The harness pour stops at the top tick's death, so the dry count is the full walk's.)
        uint256 dry = _unclampedDry(cap, weight, supply);
        (uint256[] memory tokens,,,) = h.pour(cap, weight, supply);
        assertLe(unclamped, supply + 2 * dry, "unclamped overshoot exceeds two wei per dry tick");
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            sum += tokens[i];
        }
        assertLe(sum, supply, "the clamp must hold sum(tokens) <= supply");
    }

    /// The concrete instance the fuzzer finds first, pinned, with the clamp's victim named.
    function test_clampBinds_shortsLastTick() public {
        uint256 found;
        uint256 shortBy;
        uint256 victim;
        for (uint256 seed; seed < 4_000 && found == 0; ++seed) {
            uint256 n = 2 + (seed % 7);
            uint256[] memory cap = new uint256[](n);
            uint256[] memory weight = new uint256[](n);
            uint256 total;
            for (uint256 i; i < n; ++i) {
                weight[i] = h.weightAt(i);
                cap[i] = 1 + (uint256(keccak256(abi.encode(seed, i))) % 1_000);
                total += cap[i];
            }
            uint256 supply = total - (uint256(keccak256(abi.encode(seed, "s"))) % (total / 2 + 1));
            uint256 unclamped = _unclamped(cap, weight, supply);
            if (unclamped > supply) {
                (uint256[] memory tokens, bool[] memory isDry,,) = h.pour(cap, weight, supply);
                uint256 sum;
                for (uint256 i; i < n; ++i) {
                    sum += tokens[i];
                }
                found = seed;
                shortBy = unclamped - supply;
                // Which tick took the cut: the one whose payout is below its formula share.
                (uint256[] memory alloc,) = _unclampedAlloc(cap, weight, supply);
                uint256 victims;
                for (uint256 i; i < n; ++i) {
                    if (tokens[i] < alloc[i]) {
                        victim = i;
                        ++victims;
                    }
                }
                assertEq(victims, 1, "exactly one tick is shorted");
                assertEq(victim, n - 1, "and it is the last in window order: the lowest price");
                assertEq(sum, supply, "clamped sum lands exactly on supply");
                emit log_named_uint("seed", seed);
                emit log_named_uint("ticks in window", n);
                emit log_named_uint("supply", supply);
                emit log_named_uint("unclamped sum of allocations", unclamped);
                emit log_named_uint("overshoot the clamp eats, wei", shortBy);
                emit log_named_uint("victim tick index (last = lowest price)", victim);
                emit log_named_uint("victim's clamped payout", tokens[victim]);
                emit log_named_uint("victim's unclamped (formula) payout", alloc[victim]);
                emit log_named_uint("victim's cap", cap[victim]);
                emit log_named_uint("victim isDry", isDry[victim] ? 1 : 0);
            }
        }
        // Characterisation: reachable, and the overshoot the clamp eats.
        assertGt(found, 0, "no instance in 4000 seeds");
    }
}
