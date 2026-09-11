// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GenerousAuction} from "../src/GenerousAuction.sol";
import {Mono} from "../src/Mono.sol";
import {IGenerousAuction} from "../src/interfaces/IGenerousAuction.sol";
import {IIndex} from "../src/interfaces/IIndex.sol";
import {MockPool} from "./MockPool.sol";
import {TestERC20} from "./TestERC20.sol";

/// Random walks over the whole surface — bid, withdraw, stake, unstake, claim, claimAndStake,
/// sync, time — with the money and structure invariants checked after every step. The
/// deterministic anchors (A.9, the §5 stake split, the two-level waterfall) pin exact numbers;
/// this suite pins that NO reachable sequence breaks conservation, custody, or the heap.
contract GenerousHandler is Test {
    GenerousAuction public auction;
    Mono public mono;
    TestERC20 public cur;

    uint256 internal constant FLOOR = 1e18;
    uint256 internal constant SPACING = 1e16;
    uint64 internal constant K = 100;

    address[6] public actors;
    /// 12 prices two grid steps apart (0..22 steps): wider than the 8-step band, so the band
    /// MOVES inside sweeps and dead ex-tops pile up above the book — the round-8 shapes.
    uint256[12] public prices;

    // Ghosts: every unit of value that crossed the boundary, by direction.
    uint256 public deposited; // currency in via bids
    uint256 public refunded; // currency out via withdrawals
    uint256 public claimedTokens; // MONO out via claims (both flavours)
    uint256 public stakedIn; // MONO into the stake ledger (transfers + compounded claims)
    uint256 public stakedOut; // MONO out of the stake ledger
    uint256 public navHigh; // NAV high-water: must never fall

    constructor(GenerousAuction auction_, Mono mono_, TestERC20 cur_) {
        auction = auction_;
        mono = mono_;
        cur = cur_;
        for (uint256 i; i < 6; ++i) {
            actors[i] = address(uint160(0xAA00 + i));
        }
        for (uint256 i; i < 12; ++i) {
            prices[i] = FLOOR + 2 * i * SPACING;
        }
        navHigh = mono.nav();
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 6];
    }

    /// NAV monotonicity is asserted here, on every step, rather than as an invariant — it is a
    /// high-water property, and the handler is where the water rises.
    function _navCheck() internal {
        uint256 nav = mono.nav();
        assertGe(nav, navHigh, "NAV fell");
        navHigh = nav;
    }

    function opBid(uint256 actorSeed, uint256 priceSeed, uint96 rawAmt) external {
        address who = _actor(actorSeed);
        if (auction.stakes(who) == 0) return; // the strict rule would just revert
        uint256 price = prices[priceSeed % 12];
        (uint256 held,,,,,,) = auction.positions(who);
        if (held != 0 && held != price) {
            (uint256 live,) = auction.positionOf(who);
            if (live != 0) price = held; // one bid per owner: top up instead of reverting
        }
        uint128 amount = uint128(bound(uint256(rawAmt), 2e18, 500e18));

        // The exact predecessor hint, read off the LIVE list (what a UI does): walk `next` up
        // from the floor until the next node would pass `price`.
        uint256 prev = FLOOR;
        for (uint256 i; i < 16; ++i) {
            (uint256 nx,,,,,,) = auction.ticks(prev);
            if (nx == 0 || nx >= price) break;
            prev = nx;
        }

        cur.mint(who, amount);
        vm.startPrank(who);
        cur.approve(address(auction), amount);
        try auction.submitBid(price, amount, who, prev) {
            deposited += amount;
        } catch {}
        vm.stopPrank();
        _navCheck();
    }

    function opWithdraw(uint256 actorSeed) external {
        address who = _actor(actorSeed);
        (uint256 live,) = auction.positionOf(who);
        if (live == 0) return;
        vm.prank(who);
        try auction.withdrawBid() returns (uint256 out) {
            refunded += out;
        } catch {}
        _navCheck();
    }

    function opStake(uint256 actorSeed, uint96 rawAmt) external {
        address who = _actor(actorSeed);
        uint256 amount = bound(uint256(rawAmt), 1e15, 50e18);
        if (mono.balanceOf(address(this)) < amount) return;
        mono.transfer(who, amount);
        vm.startPrank(who);
        mono.approve(address(auction), amount);
        try auction.stake(amount) {
            stakedIn += amount;
        } catch {}
        vm.stopPrank();
        _navCheck();
    }

    function opUnstake(uint256 actorSeed, uint96 rawAmt) external {
        address who = _actor(actorSeed);
        uint256 have = auction.stakes(who);
        if (have == 0) return;
        uint256 amount = bound(uint256(rawAmt), 1, have);
        vm.prank(who);
        try auction.unstake(amount) {
            stakedOut += amount;
        } catch {}
        _navCheck();
    }

    function opClaim(uint256 actorSeed) external {
        address who = _actor(actorSeed);
        try auction.claim(who) returns (uint256 got) {
            claimedTokens += got;
        } catch {}
        _navCheck();
    }

    function opClaimAndStake(uint256 actorSeed) external {
        address who = _actor(actorSeed);
        uint256 balBefore = mono.balanceOf(who);
        vm.prank(who);
        try auction.claimAndStake() returns (uint256 got) {
            // Either staked in place or (settle-pending / lock window) paid out; what left the
            // contract is a claim, what stayed is a stake credit.
            uint256 paidOut = mono.balanceOf(who) - balBefore;
            claimedTokens += paidOut;
            stakedIn += got - paidOut;
        } catch {}
        _navCheck();
    }

    function opSync(uint96 budget) external {
        auction.sync(bound(uint256(budget), 1, 300));
        _navCheck();
    }

    function opRoll(uint8 roundsSeed) external {
        vm.roll(block.number + (uint256(roundsSeed) % 3) * K + 1);
    }

    // ---------------------------------------------------------------- read helpers

    function actorCount() external pure returns (uint256) {
        return 6;
    }

    function priceCount() external pure returns (uint256) {
        return 12;
    }
}

/// forge-config: default.invariant.runs = 15
/// forge-config: default.invariant.depth = 60
/// forge-config: default.invariant.fail-on-revert = false
contract GenerousInvariantsTest is Test {
    GenerousAuction internal auction;
    Mono internal mono;
    TestERC20 internal cur;
    GenerousHandler internal handler;

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

        handler = new GenerousHandler(auction, mono, cur);
        mono.transfer(address(handler), 5_000e18); // the stake pool the handler hands out
        targetContract(address(handler));
    }

    /// Guards the suite against vacuity: a scripted pass through the handler must actually move
    /// value, or every invariant above would hold over a book where nothing ever happened.
    function test_handlerMovesValue() public {
        handler.opStake(0, 10e18);
        handler.opStake(1, 10e18);
        handler.opBid(0, 2, 100e18);
        handler.opBid(1, 2, 100e18);
        handler.opRoll(4);
        handler.opSync(100);
        handler.opClaim(0);
        handler.opWithdraw(1);
        handler.opClaimAndStake(1);

        assertGt(handler.deposited(), 0, "bids landed");
        assertGt(handler.refunded(), 0, "a withdrawal landed");
        assertGt(handler.claimedTokens(), 0, "a claim paid");
        assertGt(auction.tokensSold(), 0, "the book absorbed emission");
    }

    /// Stake is custody: the ledger matches the ghost flows exactly (a self-referential
    /// balance-vs-own-ledger check would miss an over-decremented ledger), and the contract
    /// holds at least that much.
    function invariant_stakeCustody() external view {
        assertEq(auction.totalStaked(), handler.stakedIn() - handler.stakedOut(), "stake ledger drifted");
        assertGe(mono.balanceOf(address(auction)), auction.totalStaked(), "stake was spent");
    }

    /// Currency is conserved to the wei: everything that came in is still here, was refunded,
    /// or was paid into the vault by a pack. There is no fourth door.
    function invariant_currencyConserved() external view {
        assertEq(
            cur.balanceOf(address(auction)),
            handler.deposited() - handler.refunded() - auction.currencyMinted(),
            "escrow leaked"
        );
    }

    /// Tokens flow one way through three gates, each no wider than the last.
    function invariant_tokenGates() external view {
        assertLe(handler.claimedTokens(), auction.tokensMinted(), "paid out more than was minted");
        assertLe(auction.tokensMinted(), auction.tokensBooked(), "minted more than was booked");
        assertLe(auction.tokensBooked(), auction.tokensSold(), "booked more than was sold");
        assertLe(auction.tokensSold(), auction.saleSupply(), "sold past the sale size");
    }

    /// What the positions think they are owed never exceeds the pot that backs them — up to
    /// per-segment flooring dust: a position reads its consumption with ONE floor over its whole
    /// span, while the pour books each segment's floor separately, so the sum can run a few wei
    /// ahead. `claim` clamps `owed` to `tokensUnclaimed`, so the dust is uncollectable, never
    /// insolvent; the slack here is that bound, not a fudge.
    function invariant_owedCovered() external view {
        uint256 sum;
        for (uint256 i; i < 6; ++i) {
            (, uint256 owed) = auction.positionOf(handler.actors(i));
            sum += owed;
        }
        assertLe(sum, auction.tokensUnclaimed() + 1_000, "positions owed more than the unclaimed pot");
    }

    /// Escrow actually held covers every position's live escrow AND the unpacked booking, with
    /// NO slack: the pot books a lower bound of what positions are charged (`_pourTick`), so a
    /// pack can never pull a wei that still belongs to a live bidder. The round-7 whole-number-
    /// price shortfall (a 1000-wei slack used to hide it) fails here.
    function invariant_escrowSolvent() external view {
        uint256 sumLive;
        for (uint256 i; i < 6; ++i) {
            (uint256 live,) = auction.positionOf(handler.actors(i));
            sumLive += live;
        }
        uint256 unpacked = auction.currencyRaised() - auction.currencyMinted();
        assertGe(cur.balanceOf(address(auction)), sumLive + unpacked, "live escrow + unpacked booking not covered");
    }

    /// The tick list is sound: the downward walk from `highestTick` — the exact walk `_gather`
    /// does — terminates at the floor with strictly decreasing prices and mutually consistent
    /// links, every tick with capacity is on it, and the upward walk from the floor is its
    /// mirror. A stale pointer, a self-loop, or an orphaned live tick (round-6/7 splice
    /// findings) all fail here.
    function invariant_tickListSound() external view {
        uint256 p = auction.highestTick();
        assertTrue(p != 0, "no high-water");
        uint256 steps;
        uint256 last = type(uint256).max;
        while (p != 0) {
            assertLt(p, last, "downward walk is not strictly decreasing");
            (uint256 nx, uint256 pv,,,,, bool init) = auction.ticks(p);
            assertTrue(init, "walk reached an uninitialised tick");
            if (pv != 0) {
                (uint256 pvNext,,,,,,) = auction.ticks(pv);
                assertEq(pvNext, p, "prev.next != self");
            }
            if (nx != 0) {
                (, uint256 nxPrev,,,,,) = auction.ticks(nx);
                assertEq(nxPrev, p, "next.prev != self");
            }
            last = p;
            p = pv;
            assertLe(++steps, 13, "downward walk did not terminate");
        }
        assertEq(last, FLOOR, "downward walk did not end at the floor");

        // The upward walk from the floor is the mirror image and ends where the downward one
        // began or above (a dead ex-top still linked above `highestTick` is allowed; a node with
        // capacity that the upward walk reaches but the downward one does not is not — round-8
        // half-linked run). Every node on it must be linked both ways.
        uint256 up = FLOOR;
        uint256 upSteps;
        while (true) {
            (uint256 nx,,,,,,) = auction.ticks(up);
            if (nx == 0) break;
            assertGt(nx, up, "upward walk is not strictly increasing");
            (, uint256 nxPrev,,,,,) = auction.ticks(nx);
            assertEq(nxPrev, up, "next.prev != self on the upward walk");
            up = nx;
            assertLe(++upSteps, 13, "upward walk did not terminate");
        }
        assertGe(up, auction.highestTick(), "upward walk stops below the high-water mark");
        // And no initialised price with capacity is off BOTH walks or half-linked: a node whose
        // prev points into the list while nothing on the list points back at it.
        for (uint256 pi; pi < 12; ++pi) {
            uint256 price = FLOOR + 2 * pi * SPACING;
            (uint256 nx, uint256 pv,,,,, bool init) = auction.ticks(price);
            if (!init || price == FLOOR) continue;
            if (pv == 0 && nx == 0) continue; // cleanly unlinked
            (uint256 pvNext,,,,,,) = auction.ticks(pv);
            assertEq(pvNext, price, "half-linked: prev does not point back");
            if (nx != 0) {
                (, uint256 nxPrev,,,,,) = auction.ticks(nx);
                assertEq(nxPrev, price, "half-linked: next does not point back");
            }
        }

        // Every tick with capacity is reachable from the high-water mark.
        for (uint256 pi; pi < 12; ++pi) {
            uint256 price = FLOOR + 2 * pi * SPACING;
            (,, uint256 cap,,,,) = auction.ticks(price);
            if (cap == 0) continue;
            bool found;
            uint256 q = auction.highestTick();
            for (uint256 i; i < 13 && q != 0; ++i) {
                if (q == price) {
                    found = true;
                    break;
                }
                (, q,,,,,) = auction.ticks(q);
            }
            assertTrue(found, "live tick not reachable by the sweep");
        }
    }

    /// Every tick's heap is well-formed: sizes match the seat list, seats point back at their
    /// index, and every parent's kappa is at most its children's.
    function invariant_heapWellFormed() external view {
        for (uint256 pi; pi < 12; ++pi) {
            uint256 price = FLOOR + 2 * pi * SPACING;
            address[] memory seats = auction.tickPositions(price);
            (,,,,, uint32 heapSize,) = auction.ticks(price);
            assertEq(seats.length, heapSize, "seat list vs heapSize");
            for (uint256 i; i < seats.length; ++i) {
                (uint256 pPrice,,,, uint256 kappa,, uint32 idx) = auction.positions(seats[i]);
                assertEq(idx, i + 1, "seat points at its index");
                assertEq(pPrice, price, "seat belongs to this tick");
                if (i > 0) {
                    (,,,, uint256 parentKappa,,) = auction.positions(seats[(i + 1) / 2 - 1]);
                    assertLe(parentKappa, kappa, "heap order violated");
                }
            }
        }
        // Reverse check: an actor CLAIMING a seat must actually hold it — a stale heapIdx left
        // behind by a pop would corrupt the next swap that lands on it.
        for (uint256 i; i < 6; ++i) {
            address who = handler.actors(i);
            (uint256 pPrice,,,,,, uint32 idx) = auction.positions(who);
            if (idx != 0) {
                address[] memory seatList = auction.tickPositions(pPrice);
                assertLe(idx, seatList.length, "heapIdx beyond the heap");
                assertEq(seatList[idx - 1], who, "stale heapIdx");
            }
        }
    }
}
