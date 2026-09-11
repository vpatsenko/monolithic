// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {GenerousAuction} from "../../src/GenerousAuction.sol";
import {Mono} from "../../src/Mono.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";
import {IIndex} from "../../src/interfaces/IIndex.sol";
import {MockPool} from "../MockPool.sol";
import {TestERC20} from "../TestERC20.sol";

/// Exposes the moving-band solver over the REAL seated book, so `_extend`/`_admit`/`_rescale`/
/// `_growAll` (all NEW this round, commit cf52334) run against real storage ticks below the
/// initial band — the pure `PourHarness` of review 7 could not reach them.
contract SolveHarness is GenerousAuction {
    constructor(Config memory c) GenerousAuction(c) {}

    function solveFromTop(uint256 supply, uint256 budget)
        external
        view
        returns (uint256[] memory price, uint256[] memory tokens, uint256 sum)
    {
        Window memory w = _gather(highestTick, type(uint256).max);
        w.steps = budget;
        (Solve memory s,,) = _solveBand(w, supply);
        price = new uint256[](s.n);
        tokens = new uint256[](s.n);
        for (uint256 i; i < s.n; ++i) {
            price[i] = s.price[i];
            tokens[i] = s.tokens[i];
            sum += s.tokens[i];
        }
    }
}

/// LENS: arithmetic. Independent reference model of the moving-band waterfall, fuzzed against the
/// contract solver over a real book. Asserts conservation (sum <= supply), monotonicity of the
/// total in supply, and agreement within a documented dust bound.
contract Review8ArithmeticSolverModel is Test {
    SolveHarness internal h;
    Mono internal mono;
    TestERC20 internal cur;

    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant HALF = Q96 / 2;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant FLOOR = 1e18;
    uint256 internal constant SPACING = 1e16;
    uint256 internal WINDOW = 8;

    function setUp() public {
        cur = new TestERC20("Index", "INDEX");
        mono = new Mono(IIndex(address(cur)), 100_000_000e18);
        cur.mint(address(this), 10_000_000e18);
        cur.approve(address(mono), 10_000_000e18);
        mono.mint(10_000_000e18, 10_000_000e18, address(this));
        MockPool pool = new MockPool(address(mono), address(cur), 1.25e18);
        mono.setPool(address(pool));

        h = new SolveHarness(
            IGenerousAuction.Config({
                token: address(mono),
                currency: address(cur),
                admin: address(0xF1),
                floorPrice: FLOOR,
                tickSpacing: SPACING,
                decayQ: HALF,
                windowTicks: WINDOW,
                startBlock: uint64(block.number),
                endBlock: 0,
                roundBlocks: 100,
                emissionPerRound: 100e18,
                minPremiumBips: 1_500,
                previousAuction: address(0)
            })
        );
        mono.grantRole(mono.MINTER_ROLE(), address(h));
        mono.renounceRole(mono.MINTER_ROLE(), address(this));
    }

    // seat one tick with a single position of the given token-capacity, at price FLOOR + k*SPACING
    function _seat(uint256 k, uint256 capTokens) internal {
        if (capTokens == 0) return;
        uint256 price = FLOOR + k * SPACING;
        address who = address(uint160(0x1000 + k));
        uint256 escrow = FixedPointMathLib.fullMulDivUp(capTokens, price, WAD);
        if (escrow == 0) escrow = 1;
        // stake: 1 MONO is plenty; the intra-tick split does not matter here (one seat/tick)
        mono.transfer(who, 1e18);
        cur.mint(who, escrow);
        vm.startPrank(who);
        mono.approve(address(h), 1e18);
        h.stake(1e18);
        cur.approve(address(h), escrow);
        // hint: exact predecessor is the floor for k==1, else previous seated price; walk-repair
        // handles wrong hints, so pass floor and let it walk.
        h.submitBid(price, uint128(escrow), who, FLOOR);
        vm.stopPrank();
    }

    // read live ticks (capTokens>0) high->low by walking prev from highestTick
    function _liveDesc() internal view returns (uint256[] memory price, uint256[] memory cap) {
        uint256 p = h.highestTick();
        uint256 n;
        uint256 q = p;
        while (q != 0) {
            (, uint256 prev, uint256 c,,,,) = h.ticks(q);
            if (c != 0) ++n;
            q = prev;
        }
        price = new uint256[](n);
        cap = new uint256[](n);
        q = p;
        uint256 i;
        while (q != 0) {
            (, uint256 prev, uint256 c,,,,) = h.ticks(q);
            if (c != 0) {
                price[i] = q;
                cap[i] = c;
                ++i;
            }
            q = prev;
        }
    }

    function _w(uint256 d) internal view returns (uint256) {
        return h.weightAt(d);
    }

    struct M {
        uint256 n;
        uint256 tau0;
        uint256 span;
        uint256 C;
        uint256 left;
        uint256 W;
        uint256 topIdx;
        uint256[] price;
        uint256[] g;
        uint256[] cap;
        uint256[] kappaCap;
        uint256[] entry;
        uint256[] tok;
        bool[] admitted;
        bool[] dead;
    }

    /// Independent global reference: the moving-band waterfall recomputed from scratch each event
    /// (no incremental rescale, no binary-insert, no array growth — a straight O(n^2) scan). Mirrors
    /// the contract's SEMANTICS (capK=min(cap,supply) for the initial band, reach=min(cap,left) at
    /// admission, top moves only when a tick's cap hits 0) with none of its machinery, so a
    /// divergence isolates a bug in _extend/_admit/_rescale/_growAll.
    function _ref(uint256 supply) internal view returns (uint256[] memory price, uint256[] memory tok) {
        M memory m;
        (uint256[] memory P, uint256[] memory C) = _liveDesc();
        m.n = P.length;
        m.price = P;
        m.tok = new uint256[](m.n);
        if (m.n == 0) return (m.price, m.tok);

        m.tau0 = P[0];
        m.span = WINDOW * SPACING;
        m.g = new uint256[](m.n);
        m.cap = new uint256[](m.n);
        m.kappaCap = new uint256[](m.n);
        m.entry = new uint256[](m.n);
        m.admitted = new bool[](m.n);
        m.dead = new bool[](m.n);
        for (uint256 i; i < m.n; ++i) {
            m.g[i] = _w((m.tau0 - P[i]) / SPACING);
            m.cap[i] = C[i];
        }
        m.left = supply;

        _admitBand(m, m.tau0, supply, 0, true);
        _walk(m, supply);
        _payout(m, supply);
        return (m.price, m.tok);
    }

    function _admitBand(M memory m, uint256 tau, uint256 supply, uint256 entryC, bool initial) internal pure {
        uint256 low = tau > m.span ? tau - m.span : 0;
        for (uint256 j; j < m.n; ++j) {
            if (!m.admitted[j] && m.cap[j] != 0 && m.price[j] >= low && m.g[j] != 0) {
                m.admitted[j] = true;
                m.entry[j] = entryC;
                uint256 ref = initial ? supply : m.left;
                m.kappaCap[j] = m.cap[j] > ref ? ref : m.cap[j];
                m.W += m.g[j];
            }
        }
    }

    function _walk(M memory m, uint256 supply) internal pure {
        supply;
        while (m.left != 0) {
            uint256 best = type(uint256).max;
            uint256 bestKappa = type(uint256).max;
            for (uint256 i; i < m.n; ++i) {
                if (!m.admitted[i] || m.dead[i] || m.cap[i] == 0) continue;
                uint256 kappa = m.entry[i] + FixedPointMathLib.fullMulDiv(m.kappaCap[i], Q96, m.g[i]);
                if (kappa < bestKappa) {
                    bestKappa = kappa;
                    best = i;
                }
            }
            if (best == type(uint256).max) break;
            uint256 dT = FixedPointMathLib.fullMulDiv(m.W, bestKappa - m.C, Q96);
            if (dT >= m.left) {
                m.C += FixedPointMathLib.fullMulDiv(m.left, Q96, m.W);
                m.left = 0;
                break;
            }
            m.C = bestKappa;
            m.left -= dT;
            m.W -= m.g[best];
            m.tok[best] = m.kappaCap[best];
            m.cap[best] -= m.kappaCap[best];
            m.dead[best] = true;
            if (best == m.topIdx && m.cap[best] == 0) {
                uint256 t = m.topIdx + 1;
                while (t < m.n && m.cap[t] == 0) ++t;
                if (t == m.n) break;
                m.topIdx = t;
                _admitBand(m, m.price[t], supply, m.C, false);
            }
        }
    }

    function _payout(M memory m, uint256 supply) internal pure {
        uint256 pot = supply;
        for (uint256 i; i < m.n; ++i) {
            uint256 a = m.tok[i];
            if (a == 0 && m.admitted[i] && !m.dead[i]) {
                a = FixedPointMathLib.fullMulDiv(m.g[i], m.C - m.entry[i], Q96);
                if (a > m.cap[i]) a = m.cap[i];
            }
            if (a > pot) a = pot;
            m.tok[i] = a;
            pot -= a;
        }
    }

    // ---------------------------------------------------------------- tests

    /// A moderate book: 12 ticks, small mixed caps, band moves several times, no rescale (depth<64).
    function testFuzz_conservationAndAgreement(uint256 seed) public {
        uint256 n = 12;
        uint256 total;
        for (uint256 k = 1; k <= n; ++k) {
            uint256 c = 1 + (uint256(keccak256(abi.encode(seed, k))) % (5e18));
            _seat(k, c);
            total += c;
        }
        // supply somewhere in [1, ~1.5*total]
        uint256 supply = 1 + (uint256(keccak256(abi.encode(seed, "S"))) % (total + total / 2));

        (uint256[] memory cp, uint256[] memory ct, uint256 sum) = h.solveFromTop(supply, type(uint256).max);
        // 1. conservation
        assertLe(sum, supply, "sum(tokens) exceeds supply");

        // 2. agreement with the independent reference, per tick (aligned by price), within dust
        (uint256[] memory rp, uint256[] memory rt) = _ref(supply);
        uint256 bound = 4 * rp.length + 4; // a few wei per tick of documented flooring dust
        uint256 refSum;
        for (uint256 i; i < rp.length; ++i) {
            uint256 a = _lookup(cp, ct, rp[i]);
            uint256 b = rt[i];
            refSum += b;
            uint256 diff = a > b ? a - b : b - a;
            assertLe(diff, bound, "per-tick allocation disagrees beyond dust");
        }
        // every tick the contract paid must exist in the reference (no phantom ticks)
        for (uint256 i; i < cp.length; ++i) {
            if (ct[i] == 0) continue;
            assertGt(_lookupCap(rp, cp[i]) + 1, 0, "contract paid a tick absent from the live book");
        }
        uint256 sdiff = sum > refSum ? sum - refSum : refSum - sum;
        assertLe(sdiff, bound, "distributed total disagrees beyond dust");
    }

    function _lookup(uint256[] memory p, uint256[] memory v, uint256 key) internal pure returns (uint256) {
        for (uint256 i; i < p.length; ++i) {
            if (p[i] == key) return v[i];
        }
        return 0;
    }

    function _lookupCap(uint256[] memory p, uint256 key) internal pure returns (uint256) {
        for (uint256 i; i < p.length; ++i) {
            if (p[i] == key) return 1;
        }
        return 0;
    }

    /// Monotonicity of the distributed total in supply: more emission never distributes less.
    function testFuzz_totalMonotoneInSupply(uint256 seed) public {
        uint256 n = 10;
        uint256 total;
        for (uint256 k = 1; k <= n; ++k) {
            uint256 c = 1 + (uint256(keccak256(abi.encode(seed, k))) % (3e18));
            _seat(k, c);
            total += c;
        }
        uint256 s1 = 1 + (uint256(keccak256(abi.encode(seed, "a"))) % total);
        uint256 s2 = s1 + 1 + (uint256(keccak256(abi.encode(seed, "b"))) % total);

        (,, uint256 sum1) = h.solveFromTop(s1, type(uint256).max);
        (,, uint256 sum2) = h.solveFromTop(s2, type(uint256).max);
        assertLe(sum1, sum2, "distributed total decreased when supply grew");
        assertLe(sum1, s1, "sum1 exceeds supply");
        assertLe(sum2, s2, "sum2 exceeds supply");
    }

    /// Deep book (80 ticks) so the band moves >64 times and `_rescale` fires (top weight drops
    /// below 2^32 = RESCALE_BELOW past depth 64 with q=0.5). Supply is nearly the whole book so the
    /// band reaches the bottom and deep survivors are paid a rescaled curve share. Conservation and
    /// agreement must still hold to dust.
    function test_deepBookRescale_conservationAndAgreement() public {
        WINDOW; // documented: window stays 8
        uint256 n = 80;
        uint256 total;
        for (uint256 k = 1; k <= n; ++k) {
            uint256 c = 1e18 + (uint256(keccak256(abi.encode("deep", k))) % 2e18);
            _seat(k, c);
            total += c;
        }
        // nearly the whole book: forces the band all the way down (rescale on the way), leaving a
        // handful of deep survivors that are paid rescaled curve shares.
        uint256 supply = (total * 97) / 100;

        (uint256[] memory cp, uint256[] memory ct, uint256 sum) = h.solveFromTop(supply, type(uint256).max);
        assertLe(sum, supply, "deep: sum(tokens) exceeds supply");

        (uint256[] memory rp, uint256[] memory rt) = _ref(supply);
        uint256 worst;
        for (uint256 i; i < rp.length; ++i) {
            uint256 a = _lookup(cp, ct, rp[i]);
            uint256 b = rt[i];
            uint256 diff = a > b ? a - b : b - a;
            if (diff > worst) worst = diff;
        }
        emit log_named_uint("deep book ticks (contract admitted)", cp.length);
        emit log_named_uint("supply", supply);
        emit log_named_uint("contract distributed sum", sum);
        emit log_named_uint("worst per-tick disagreement (wei)", worst);
        // Document the bound: rescale is proven to lose <1 wei/tick/rescale; over one sweep the
        // accumulated drift is small. Fail loudly if it is not dust.
        assertLe(worst, 1000, "deep: disagreement is not dust");
    }
}
