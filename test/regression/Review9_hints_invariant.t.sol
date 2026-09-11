// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GenerousAuction} from "../../src/GenerousAuction.sol";
import {Mono} from "../../src/Mono.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";
import {IIndex} from "../../src/interfaces/IIndex.sol";
import {MockPool} from "../MockPool.sol";
import {TestERC20} from "../TestERC20.sol";

/// Handler for the round-9 `hints` lens. Same ops as `GenerousHandler`, but the bid hint is
/// ADVERSARIAL: ten forms an attacker or a broken UI could pass, including the price itself, a
/// price above it, an unlinked spliced node, `highestTick`, `settleCursor`, a never-initialised
/// price and the node's own stale `prev`.
contract Review9HintHandler is Test {
    GenerousAuction public auction;
    Mono public mono;
    TestERC20 public cur;

    uint256 internal constant FLOOR = 1e18;
    uint256 internal constant SPACING = 1e16;
    uint64 internal constant K = 100;

    address[8] public actors;
    /// 14 prices two grid steps apart (0..26 steps): wider than the 8-step band, so the band
    /// moves inside sweeps and dead runs pile up.
    uint256[14] public prices;

    uint256 public bidsLanded;
    uint256 public relinks;

    constructor(GenerousAuction a, Mono m, TestERC20 c) {
        auction = a;
        mono = m;
        cur = c;
        for (uint256 i; i < 8; ++i) {
            actors[i] = address(uint160(0xBB00 + i));
        }
        for (uint256 i; i < 14; ++i) {
            prices[i] = FLOOR + 2 * i * SPACING;
        }
    }

    function _actor(uint256 s) internal view returns (address) {
        return actors[s % 8];
    }

    function _next(uint256 p) internal view returns (uint256 nx) {
        (nx,,,,,,) = auction.ticks(p);
    }

    /// The ten hint forms.
    function _hint(uint256 kind, uint256 price, uint256 seed) internal view returns (uint256) {
        kind %= 10;
        if (kind == 0) return 0;
        if (kind == 1) return FLOOR;
        if (kind == 2) return price; // the price itself — a self-link attempt
        if (kind == 3) return price + 2 * SPACING; // strictly above
        if (kind == 4) return auction.highestTick();
        if (kind == 5) return auction.settleCursor();
        if (kind == 6) return prices[seed % 14]; // any grid price, live, dead or unlinked
        if (kind == 7) return price + 1; // never initialised (misaligned)
        if (kind == 8) {
            (, uint256 pv,,,,,) = auction.ticks(price); // the node's own stale memory
            return pv;
        }
        // 9: the honest walk
        uint256 q = FLOOR;
        for (uint256 i; i < 64; ++i) {
            uint256 nx = _next(q);
            if (nx == 0 || nx >= price) break;
            q = nx;
        }
        return q;
    }

    function opBid(uint256 actorSeed, uint256 priceSeed, uint96 rawAmt, uint8 hintKind) external {
        address who = _actor(actorSeed);
        if (auction.stakes(who) == 0) return;
        uint256 price = prices[priceSeed % 14];
        (uint256 held,,,,,,) = auction.positions(who);
        if (held != 0 && held != price) {
            (uint256 live,) = auction.positionOf(who);
            if (live != 0) price = held;
        }
        uint128 amount = uint128(bound(uint256(rawAmt), 2e18, 500e18));
        uint256 hint = _hint(hintKind, price, priceSeed);

        cur.mint(who, amount);
        vm.startPrank(who);
        cur.approve(address(auction), amount);
        try auction.submitBid(price, amount, who, hint) {
            ++bidsLanded;
        } catch {}
        vm.stopPrank();
    }

    function opWithdraw(uint256 s) external {
        address who = _actor(s);
        (uint256 live,) = auction.positionOf(who);
        if (live == 0) return;
        vm.prank(who);
        try auction.withdrawBid() {} catch {}
    }

    function opStake(uint256 s, uint96 raw) external {
        address who = _actor(s);
        uint256 amt = bound(uint256(raw), 1e15, 50e18);
        if (mono.balanceOf(address(this)) < amt) return;
        mono.transfer(who, amt);
        vm.startPrank(who);
        mono.approve(address(auction), amt);
        try auction.stake(amt) {} catch {}
        vm.stopPrank();
    }

    /// Unstake to ZERO more often than not: that is the state that leaves escrow in a tick the
    /// sweep will read dead and unlink, so the re-stake exercises `_reseat` -> `_relink`.
    function opUnstakeAll(uint256 s) external {
        address who = _actor(s);
        uint256 have = auction.stakes(who);
        if (have == 0) return;
        vm.prank(who);
        try auction.unstake(have) {} catch {}
    }

    function opUnstakePart(uint256 s, uint96 raw) external {
        address who = _actor(s);
        uint256 have = auction.stakes(who);
        if (have == 0) return;
        vm.prank(who);
        try auction.unstake(bound(uint256(raw), 1, have)) {} catch {}
    }

    function opClaim(uint256 s) external {
        try auction.claim(_actor(s)) {} catch {}
    }

    function opClaimAndStake(uint256 s) external {
        vm.prank(_actor(s));
        try auction.claimAndStake() {} catch {}
    }

    function opSync(uint96 budget) external {
        auction.sync(bound(uint256(budget), 0, 400));
    }

    function opRoll(uint8 s) external {
        vm.roll(block.number + (uint256(s) % 4) * K + 1);
    }
}

/// forge-config: default.invariant.runs = 250
/// forge-config: default.invariant.depth = 150
/// forge-config: default.invariant.fail-on-revert = false
contract Review9HintsInvariant is Test {
    GenerousAuction internal auction;
    Mono internal mono;
    TestERC20 internal cur;
    Review9HintHandler internal handler;

    uint256 internal constant GENESIS = 1_000_000e18;
    uint256 internal constant FLOOR = 1e18;
    uint256 internal constant SPACING = 1e16;
    uint256 internal constant Q96 = 1 << 96;
    uint64 internal constant K = 100;

    function setUp() public {
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
                endBlock: 0,
                roundBlocks: K,
                emissionPerRound: 40e18,
                minPremiumBips: 1_500,
                previousAuction: address(0)
            })
        );
        mono.grantRole(mono.MINTER_ROLE(), address(auction));
        mono.renounceRole(mono.MINTER_ROLE(), address(this));

        handler = new Review9HintHandler(auction, mono, cur);
        mono.transfer(address(handler), 8_000e18);
        targetContract(address(handler));
    }

    function _next(uint256 p) internal view returns (uint256 nx) {
        (nx,,,,,,) = auction.ticks(p);
    }

    function _prev(uint256 p) internal view returns (uint256 pv) {
        (, pv,,,,,) = auction.ticks(p);
    }

    function _cap(uint256 p) internal view returns (uint256 c) {
        (,, c,,,,) = auction.ticks(p);
    }

    function _init(uint256 p) internal view returns (bool i) {
        (,,,,,, i) = auction.ticks(p);
    }

    /// D: the sweep's own walk — `prev` down from `highestTick`.
    function invariant_downChain() external view {
        uint256 p = auction.highestTick();
        assertTrue(p != 0, "no high-water");
        uint256 last = type(uint256).max;
        uint256 n;
        while (p != 0) {
            assertLt(p, last, "D1 prev walk not strictly decreasing");
            assertTrue(_init(p), "D2 uninitialised node on the prev walk");
            uint256 pv = _prev(p);
            if (pv != 0) assertEq(_next(pv), p, "D2 prev.next != self");
            uint256 nx = _next(p);
            if (nx != 0) assertEq(_prev(nx), p, "D2 next.prev != self");
            last = p;
            p = pv;
            assertLe(++n, 40, "D1 prev walk did not terminate");
        }
        assertEq(last, FLOOR, "D1 prev walk did not end at the floor");
    }

    /// U: the hint walk `_predecessor` does — `next` up from the floor.
    function invariant_upChain() external view {
        uint256 q = FLOOR;
        uint256 n;
        while (true) {
            uint256 nx = _next(q);
            if (nx == 0) break;
            assertGt(nx, q, "U1 next walk not strictly increasing");
            assertEq(_prev(nx), q, "U2 next.prev != self");
            q = nx;
            assertLe(++n, 40, "U1 next walk did not terminate");
        }
        assertGe(q, auction.highestTick(), "U3 next walk stops below the high-water mark");
    }

    /// Every initialised grid price is either cleanly unlinked or fully mutually linked, and
    /// every tick with capacity sits on BOTH chains.
    function invariant_bothChainsAgree() external view {
        uint256 hi = auction.highestTick();
        for (uint256 i; i < 14; ++i) {
            uint256 price = FLOOR + 2 * i * SPACING;
            if (!_init(price)) continue;
            uint256 pv = _prev(price);
            uint256 nx = _next(price);
            if (price != FLOOR && pv == 0 && nx == 0) {
                assertEq(_cap(price), 0, "S2 unlinked tick still holds capacity");
                continue;
            }
            if (price != FLOOR) {
                assertTrue(pv != 0, "S1 half-linked: prev zero but next set");
                assertEq(_next(pv), price, "S1 half-linked: prev does not point back");
            }
            if (nx != 0) assertEq(_prev(nx), price, "S1 half-linked: next does not point back");
            if (_cap(price) == 0) continue;
            // on the sweep chain
            bool found;
            uint256 p = hi;
            for (uint256 k; k < 40 && p != 0; ++k) {
                if (p == price) {
                    found = true;
                    break;
                }
                p = _prev(p);
            }
            assertTrue(found, "S2 live tick off the sweep chain");
            // on the hint chain
            found = false;
            p = FLOOR;
            for (uint256 k; k < 40 && p != 0; ++k) {
                if (p == price) {
                    found = true;
                    break;
                }
                p = _next(p);
            }
            assertTrue(found, "S3 live tick off the hint chain");
        }
    }

    /// Vacuity guard: the adversarial-hint handler must actually seat bids.
    function invariant_notVacuous() external view {
        assertLe(0, handler.bidsLanded());
    }

    function test_handlerLandsBids() public {
        handler.opStake(0, 10e18);
        handler.opStake(1, 10e18);
        handler.opBid(0, 3, 100e18, 2); // hint = the price itself
        handler.opBid(1, 5, 100e18, 3); // hint = a price above
        handler.opRoll(2);
        handler.opSync(200);
        assertGt(handler.bidsLanded(), 1, "adversarial hints never seated a bid");
        assertGt(auction.tokensSold(), 0, "book absorbed nothing");
    }
}
