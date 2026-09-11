// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GenerousAuction} from "../../src/GenerousAuction.sol";
import {Mono} from "../../src/Mono.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";
import {IIndex} from "../../src/interfaces/IIndex.sol";
import {MockPool} from "../MockPool.sol";
import {TestERC20} from "../TestERC20.sol";

/// Review 9 / SWEEP lens — randomised handler aimed at the window loop and the single
/// `_splice(price, w.tau)`. Ops chosen for the cursor/high-water pair: unstake-to-zero (the tick
/// reads dead but keeps escrow), re-stake after a sweep unlinked the tick, the permissionless
/// `claim` whose new `_reseat` has no `SettleFirst` guard, dust bids, syncs at every budget,
/// and rolls that make the backlog span many windows.
contract Review9SweepHandler is Test {
    GenerousAuction public auction;
    Mono public mono;
    TestERC20 public cur;

    uint256 internal constant FLOOR = 1e18;
    uint256 internal constant SPACING = 1e16;
    uint64 internal constant K = 100;

    address[10] public actors;
    uint256[24] public prices;
    uint256 public immutable step;

    uint256 public bids;
    uint256 public withdrawals;
    uint256 public zeroUnstakes;
    uint256 public syncs;
    uint256 public claims;
    uint256 public parkedSeen;
    uint256 public shavedSeen;
    uint256 public unlinkedSeen;

    constructor(GenerousAuction a, Mono m, TestERC20 c, uint256 step_) {
        auction = a;
        mono = m;
        cur = c;
        step = step_;
        for (uint256 i; i < 10; ++i) {
            actors[i] = address(uint160(0xC000 + i));
        }
        for (uint256 i; i < 24; ++i) {
            prices[i] = FLOOR + step_ * i * SPACING;
        }
    }

    function _actor(uint256 s) internal view returns (address) {
        return actors[s % 10];
    }

    function _next(uint256 p) internal view returns (uint256 n) {
        (n,,,,,,) = auction.ticks(p);
    }

    function _uiHint(uint256 price) internal view returns (uint256 q) {
        q = FLOOR;
        for (uint256 i; i < 64; ++i) {
            uint256 nx = _next(q);
            if (nx == 0 || nx >= price) return q;
            q = nx;
        }
    }

    function _observe() internal {
        if (auction.settleCursor() != 0) ++parkedSeen;
        for (uint256 i; i < 24; ++i) {
            (, uint256 pv,,,,,) = auction.ticks(prices[i]);
            (uint256 nx,,,,,,) = auction.ticks(prices[i]);
            (,,,,,, bool init) = auction.ticks(prices[i]);
            if (init && prices[i] != FLOOR && pv == 0 && nx == 0) ++unlinkedSeen;
        }
    }

    function opBid(uint256 aSeed, uint256 pSeed, uint96 raw, uint8 mode) external {
        address who = _actor(aSeed);
        if (auction.stakes(who) == 0) return;
        uint256 price = prices[pSeed % 24];
        (uint256 held,,,,,,) = auction.positions(who);
        if (held != 0 && held != price) {
            (uint256 live,) = auction.positionOf(who);
            if (live != 0) price = held;
        }
        // Dust bids (exactly the minimum that buys a wei) sit alongside whales.
        uint128 amount = mode % 4 == 3 ? uint128(price / 1e18 + 1) : uint128(bound(uint256(raw), 2e18, 400e18));
        uint256 hint;
        if (mode % 3 == 0) hint = _uiHint(price);
        else if (mode % 3 == 1) hint = prices[(pSeed + 11) % 24];
        cur.mint(who, amount);
        vm.startPrank(who);
        cur.approve(address(auction), amount);
        try auction.submitBid(price, amount, who, hint) {
            ++bids;
        } catch {}
        vm.stopPrank();
        _observe();
    }

    function opWithdraw(uint256 aSeed) external {
        vm.prank(_actor(aSeed));
        try auction.withdrawBid() {
            ++withdrawals;
        } catch {}
        _observe();
    }

    function opStake(uint256 aSeed, uint96 raw) external {
        address who = _actor(aSeed);
        uint256 amt = bound(uint256(raw), 1e15, 40e18);
        if (mono.balanceOf(address(this)) < amt) return;
        mono.transfer(who, amt);
        vm.startPrank(who);
        mono.approve(address(auction), amt);
        try auction.stake(amt) {} catch {}
        vm.stopPrank();
        _observe();
    }

    /// Unstake to ZERO with a live bid: the tick reads dead but keeps escrow — the shape that
    /// gets the tick spliced out from under a standing position.
    function opUnstakeAll(uint256 aSeed) external {
        address who = _actor(aSeed);
        uint256 have = auction.stakes(who);
        if (have == 0) return;
        vm.prank(who);
        try auction.unstake(have) {
            ++zeroUnstakes;
        } catch {}
        _observe();
    }

    function opUnstakePart(uint256 aSeed, uint96 raw) external {
        address who = _actor(aSeed);
        uint256 have = auction.stakes(who);
        if (have == 0) return;
        vm.prank(who);
        try auction.unstake(bound(uint256(raw), 1, have)) {} catch {}
        _observe();
    }

    /// Permissionless: anyone claims for anyone. `_claim`'s new re-seat has no settle guard.
    function opClaimFor(uint256 aSeed, uint256 callerSeed) external {
        vm.prank(_actor(callerSeed));
        try auction.claim(_actor(aSeed)) {
            ++claims;
        } catch {}
        _observe();
    }

    function opClaimAndStake(uint256 aSeed) external {
        vm.prank(_actor(aSeed));
        try auction.claimAndStake() {} catch {}
        _observe();
    }

    function opSync(uint96 budget) external {
        uint256 hiBefore = auction.highestTick();
        try auction.sync(bound(uint256(budget), 0, 400)) {
            ++syncs;
            if (auction.highestTick() < hiBefore) ++shavedSeen;
        } catch {}
        _observe();
    }

    function opRoll(uint8 s) external {
        vm.roll(block.number + (uint256(s) % 5) * K + 1);
    }
}

abstract contract Review9SweepInvariantBase is Test {
    GenerousAuction internal auction;
    Mono internal mono;
    TestERC20 internal cur;
    Review9SweepHandler internal handler;

    uint256 internal constant GENESIS = 1_000_000e18;
    uint256 internal constant FLOOR = 1e18;
    uint256 internal constant SPACING = 1e16;
    uint256 internal constant Q96 = 1 << 96;
    uint64 internal constant K = 100;

    uint256 internal step;

    function _boot(uint256 windowTicks_, uint256 q, uint256 step_, uint128 emission) internal {
        step = step_;
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
                endBlock: 0,
                roundBlocks: K,
                emissionPerRound: emission,
                minPremiumBips: 1_500,
                previousAuction: address(0)
            })
        );
        mono.grantRole(mono.MINTER_ROLE(), address(auction));
        mono.renounceRole(mono.MINTER_ROLE(), address(this));

        handler = new Review9SweepHandler(auction, mono, cur, step_);
        mono.transfer(address(handler), 40_000e18);
        targetContract(address(handler));
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

    function _init(uint256 p) internal view returns (bool i) {
        (,,,,,, i) = auction.ticks(p);
    }

    function _sweepStart() internal view returns (uint256 p) {
        p = auction.settleCursor();
        if (p == 0) p = auction.highestTick();
    }

    /// Both chains, and the coverage of every tick that still has capacity.
    function invariant_sweepListSound() public view {
        uint256 start = _sweepStart();
        assertTrue(start != 0, "no sweep start");
        uint256 p = start;
        uint256 last = type(uint256).max;
        uint256 steps;
        while (p != 0) {
            assertLt(p, last, "prev walk not strictly decreasing");
            assertTrue(_init(p), "prev walk hit an uninitialised tick");
            uint256 pv = _prev(p);
            if (pv != 0) assertEq(_next(pv), p, "prev.next != self");
            uint256 nx = _next(p);
            if (nx != 0) assertEq(_prev(nx), p, "next.prev != self");
            last = p;
            p = pv;
            assertLe(++steps, 500, "prev walk did not terminate");
        }
        assertEq(last, FLOOR, "prev walk did not end at the floor");

        uint256 up = FLOOR;
        uint256 upSteps;
        while (true) {
            uint256 nx = _next(up);
            if (nx == 0) break;
            assertGt(nx, up, "next walk not strictly increasing");
            assertEq(_prev(nx), up, "next.prev != self on the up walk");
            up = nx;
            assertLe(++upSteps, 500, "next walk did not terminate");
        }

        for (uint256 i; i < 24; ++i) {
            uint256 q = FLOOR + step * i * SPACING;
            if (!_init(q)) continue;
            uint256 pv = _prev(q);
            uint256 nx = _next(q);
            if (q != FLOOR && !(pv == 0 && nx == 0)) {
                assertEq(_next(pv), q, "half-linked: prev does not point back");
                if (nx != 0) assertEq(_prev(nx), q, "half-linked: next does not point back");
            }
            if (_cap(q) == 0) continue;

            bool found;
            uint256 r = start;
            for (uint256 j; j < 500 && r != 0; ++j) {
                if (r == q) {
                    found = true;
                    break;
                }
                r = _prev(r);
            }
            assertTrue(found, "LIVE TICK NOT REACHED BY THE NEXT SWEEP");

            bool onList;
            r = FLOOR;
            for (uint256 j; j < 500 && r != 0; ++j) {
                if (r == q) {
                    onList = true;
                    break;
                }
                r = _next(r);
            }
            assertTrue(onList, "live tick off the next chain from the floor");
        }
    }
}

/// Wide grid (2 steps apart over 46 steps) against an 8-step band: multi-window sweeps.
/// forge-config: default.invariant.runs = 40
/// forge-config: default.invariant.depth = 80
/// forge-config: default.invariant.fail-on-revert = false
contract Review9SweepWideTest is Review9SweepInvariantBase {
    function setUp() public {
        _boot(8, Q96 / 2, 2, 40e18);
    }
}

/// Narrow band (4 ticks) on a dense grid (1 step apart), 24 prices over 24 steps:
/// the band moves on nearly every exhaustion and the sweep runs many windows per call.
/// forge-config: default.invariant.runs = 40
/// forge-config: default.invariant.depth = 80
/// forge-config: default.invariant.fail-on-revert = false
contract Review9SweepNarrowBandTest is Review9SweepInvariantBase {
    function setUp() public {
        _boot(4, Q96 / 4, 1, 120e18);
    }

    function test_coverage() public {
        handler.opStake(0, 20e18);
        handler.opStake(1, 20e18);
        handler.opStake(2, 20e18);
        handler.opBid(0, 9, 100e18, 0);
        handler.opBid(1, 5, 100e18, 0);
        handler.opBid(2, 1, 100e18, 0);
        handler.opRoll(3);
        handler.opSync(300);
        handler.opUnstakeAll(0);
        handler.opSync(300);
        handler.opBid(1, 20, 100e18, 0);
        handler.opSync(300);
        assertGt(handler.bids(), 0, "bids landed");
        assertGt(handler.syncs(), 0, "syncs landed");
        assertGt(handler.shavedSeen(), 0, "the high-water was shaved");
        assertGt(handler.unlinkedSeen(), 0, "a tick was spliced out");
        invariant_sweepListSound();
    }
}

/// The SAME handler, but the book is booted with a 300-node dead ridge above it, so every
/// `sync` budget-outs in `_gather`'s skip walk (`SYNC_TICKS` is 128) and the sweep spends most
/// of the run in the PARKED state — the state the two other configurations never reach.
/// forge-config: default.invariant.runs = 8
/// forge-config: default.invariant.depth = 60
/// forge-config: default.invariant.fail-on-revert = false
contract Review9SweepParkedTest is Review9SweepInvariantBase {
    address internal constant RIDGE = address(0xEE01);

    function setUp() public {
        _boot(8, Q96 / 2, 2, 40e18);
        // 300 initialised-but-dead ticks above the handler's 24 prices (which top out at
        // FLOOR + 46 * SPACING). Built at block 0 of the schedule, so no pour happens yet.
        mono.transfer(RIDGE, 50e18);
        vm.startPrank(RIDGE);
        mono.approve(address(auction), 50e18);
        auction.stake(50e18);
        vm.stopPrank();
        for (uint256 i; i < 300; ++i) {
            uint256 price = FLOOR + (i + 60) * SPACING;
            cur.mint(RIDGE, 3e18);
            vm.startPrank(RIDGE);
            cur.approve(address(auction), 3e18);
            auction.submitBid(price, 3e18, RIDGE, price - SPACING);
            auction.withdrawBid();
            vm.stopPrank();
        }
        assertEq(auction.highestTick(), FLOOR + 359 * SPACING, "ridge built");
    }

    /// The ridge really does park the cursor, and a parked sweep never leaves capacity above
    /// where it will resume.
    function test_parkedCoverage() public {
        handler.opStake(0, 20e18);
        handler.opBid(0, 5, 100e18, 0);
        handler.opRoll(2);
        handler.opSync(128);
        assertTrue(auction.settleCursor() != 0, "the ridge parks the cursor");
        invariant_sweepListSound();
        handler.opClaimFor(0, 1);
        invariant_sweepListSound();
        handler.opSync(128);
        invariant_sweepListSound();
    }
}
