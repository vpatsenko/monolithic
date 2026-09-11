// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GenerousAuction} from "../src/GenerousAuction.sol";
import {Mono} from "../src/Mono.sol";
import {IGenerousAuction} from "../src/interfaces/IGenerousAuction.sol";
import {IIndex} from "../src/interfaces/IIndex.sol";
import {MockPool} from "./MockPool.sol";
import {TestERC20} from "./TestERC20.sol";

/// Staking and the stake-weighted intra-tick split of `src/GenerousAuction.sol`.
///
/// The anchor is the worked example of `docs/staked-generous-auction.md` §5: one tick at 1.00,
/// stakes 50/40/10 against budgets 5/100/100, a 95-token pour, published answer 5 / 72 / 18 —
/// the whale-by-stake dies on its own budget cap and its excess re-flows to its co-stakers.
contract GenerousStakingTest is Test {
    GenerousAuction internal auction;
    Mono internal mono;
    TestERC20 internal cur;

    uint256 internal constant GENESIS = 1_000_000e18;
    uint256 internal constant FLOOR = 1e18;
    uint256 internal constant SPACING = 1e16;
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant HALF = Q96 / 2;
    uint64 internal constant K = 100;

    uint256 internal constant P1 = FLOOR + SPACING;
    uint256 internal constant P0 = FLOOR;

    address internal aa = address(0xA1);
    address internal bb = address(0xA2);
    address internal cc = address(0xA3);

    function setUp() public {
        _deploy(95e18, 0);
    }

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
                admin: address(0xF1),
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

    function _owed(address who) internal view returns (uint256 owed) {
        (, owed) = auction.positionOf(who);
    }

    function _live(address who) internal view returns (uint256 live) {
        (live,) = auction.positionOf(who);
    }

    function _round() internal {
        vm.roll(block.number + K);
        auction.sync(64);
    }

    // ------------------------------------------------------------------ the strict rule

    /// Escrow without stake does not even enter the book.
    function test_noStakeNoBid() public {
        cur.mint(aa, 10e18);
        vm.startPrank(aa);
        cur.approve(address(auction), 10e18);
        vm.expectRevert(IGenerousAuction.NoStake.selector);
        auction.submitBid(P0, 10e18, aa, FLOOR);
        vm.stopPrank();
    }

    /// Un-staked escrow is not tick capacity: the tick goes zombie, the emission does NOT
    /// waterfall into it, and re-staking revives it — carry intact, nothing earned while dark.
    function test_unstakedEscrowIsNotCapacity() public {
        _deploy(50e18, 0);
        _stakeFor(aa, 1e18);
        _stakeFor(bb, 1e18);
        _bid(aa, P1, uint128(101e17), FLOOR); // capacity 10 tokens at 1.01
        _bid(bb, P0, 100e18, FLOOR);

        // bb goes dark before the first round settles.
        vm.prank(bb);
        auction.unstake(1e18);
        (,, uint256 cap0,,,,) = auction.ticks(P0);
        assertEq(cap0, 0, "un-staked escrow left the tick's capacity");

        _round();
        assertEq(_owed(aa), 10e18, "the staked tick filled to its cap");
        assertEq(_owed(bb), 0, "zero stake, zero fill, strictly");
        assertEq(auction.tokensSold(), 10e18, "the rest did NOT flow into the zombie tick");
        assertEq(auction.due(), 40e18, "it carried instead");

        // Re-stake: capacity returns, the carry pours, and nothing was earned retroactively.
        vm.prank(bb);
        mono.approve(address(auction), 0); // no-op, keeps the prank shape obvious
        _stakeFor(bb, 1e18);
        auction.sync(64);
        assertEq(_owed(bb), 40e18, "the carry, earned only once the stake was back");
    }

    // ------------------------------------------------------------------ the anchor

    /// `docs/staked-generous-auction.md` §5: stakes 50/40/10, budgets 5/100/100, pour 95 at 1.00.
    /// X's stake says 50% but its budget caps it at 5; the excess re-flows to Y and Z by stake.
    function test_stakeWeightedSplit_anchor() public {
        _stakeFor(aa, 50e18);
        _stakeFor(bb, 40e18);
        _stakeFor(cc, 10e18);
        _bid(aa, P0, 5e18, FLOOR);
        _bid(bb, P0, 100e18, FLOOR);
        _bid(cc, P0, 100e18, FLOOR);

        _round();

        assertApproxEqAbs(_owed(aa), 5e18, 2, "X: capped by budget, not stake");
        assertApproxEqAbs(_owed(bb), 72e18, 2, "Y: 40 + its share of X's excess");
        assertApproxEqAbs(_owed(cc), 18e18, 2, "Z: 10 + its share of X's excess");
        assertApproxEqAbs(auction.tokensSold(), 95e18, 4, "whole pour absorbed");
        assertApproxEqAbs(_live(aa), 0, 2, "X's escrow is spent");
        // Pay-as-bid at the tick price: raised covers exactly what was eaten, at 1.00.
        assertApproxEqAbs(auction.currencyRaised(), 95e18, 4, "raised = sold * price");
    }

    // ------------------------------------------------------------------ reweighing

    /// Stake moves reweigh FUTURE rounds only; settled rounds are untouchable by construction.
    function test_stakeReweighsBetweenRounds() public {
        _deploy(100e18, 0);
        _stakeFor(aa, 3e18);
        _stakeFor(bb, 1e18);
        _bid(aa, P0, 1000e18, FLOOR);
        _bid(bb, P0, 1000e18, FLOOR);

        _round();
        assertEq(_owed(aa), 75e18, "round 1 at 3:1");
        assertEq(_owed(bb), 25e18);

        vm.prank(aa);
        auction.unstake(2e18); // 3:1 -> 1:1, forward-only

        _round();
        assertEq(_owed(aa), 125e18, "75 + half of round 2");
        assertEq(_owed(bb), 75e18, "25 + half of round 2");
    }

    /// Going dark and coming back: rounds while inert are missed for good, never made up.
    function test_restakeEarnsNothingRetroactively() public {
        _deploy(100e18, 0);
        _stakeFor(aa, 1e18);
        _stakeFor(bb, 1e18);
        _bid(aa, P0, 1000e18, FLOOR);
        _bid(bb, P0, 1000e18, FLOOR);

        _round();
        assertEq(_owed(bb), 50e18, "round 1 split evenly");

        vm.prank(bb);
        auction.unstake(1e18);
        _round();
        assertEq(_owed(aa), 150e18, "round 2 went to the only staked position");
        assertEq(_owed(bb), 50e18, "inert earned nothing");

        _stakeFor(bb, 1e18);
        _round();
        assertEq(_owed(aa), 200e18, "round 3 split evenly again");
        assertEq(_owed(bb), 100e18, "back in, forward-only");
    }

    // ------------------------------------------------------------------ one bid per owner

    function test_oneBidPerOwner() public {
        _stakeFor(aa, 1e18);
        _bid(aa, P1, 50e18, FLOOR);

        // A second price with live escrow refuses; the same price tops up.
        cur.mint(aa, 60e18);
        vm.startPrank(aa);
        cur.approve(address(auction), 60e18);
        vm.expectRevert(IGenerousAuction.BidExists.selector);
        auction.submitBid(P0, 10e18, aa, FLOOR);
        auction.submitBid(P1, 50e18, aa, FLOOR);
        vm.stopPrank();
        assertEq(_live(aa), 100e18, "same price grew the one position");

        // Withdraw closes it; the next bid may sit anywhere.
        vm.prank(aa);
        auction.withdrawBid();
        _bid(aa, P0, 10e18, FLOOR);
        (uint256 price,,,,,,) = auction.positions(aa);
        assertEq(price, P0, "re-bound after withdraw");
    }

    /// Seats are unlimited: the heap pours by deaths, not by scans. Forty positions share one
    /// tick, split by stake, and the whole pour still lands exactly.
    function test_manySeatsOneTick() public {
        _deploy(80e18, 0);
        uint256 n = 40;
        for (uint256 i; i < n; ++i) {
            address who = address(uint160(0x2000 + i));
            _stakeFor(who, 1e18);
            _bid(who, P0, 100e18, FLOOR);
        }
        assertEq(auction.tickPositions(P0).length, n, "all forty seated");

        _round();
        // Equal stakes, ample budgets: an even 2-token split of the 80-token round.
        for (uint256 i; i < n; ++i) {
            assertApproxEqAbs(_owed(address(uint160(0x2000 + i))), 2e18, 2, "even split by stake");
        }

        // One whale-by-stake among the forty: 41 stakes of which one is 41x... keep it simple —
        // double one stake and check the next round splits 2 : 1 : ... : 1.
        address first = address(uint160(0x2000));
        _stakeFor(first, 1e18); // 2e18 total now
        _round();
        assertApproxEqAbs(_owed(first), 2e18 + (uint256(80e18) * 2) / 41, 3, "doubled stake, doubled share");
    }

    /// A pour owing more deaths than MAX_DEATHS_PER_POUR pauses at a death boundary and the
    /// cursor resumes the same tick: two syncs, one exact outcome. Budgets differ so the kappas
    /// do too — identical positions would all exhaust in one step with no pops at all.
    function test_deathBudgetPausesAndResumes() public {
        _deploy(12_000e18, 0);
        uint256 n = 150; // > MAX_DEATHS_PER_SYNC = 128
        for (uint256 i; i < n; ++i) {
            address who = address(uint160(0x4000 + i));
            _stakeFor(who, 1e18);
            _bid(who, P0, uint128((i + 1) * 1e18), FLOOR); // capacities 1..150 tokens
        }

        // The 12k-token round out-sizes the 11 325-token book: every position dies, in kappa
        // order, and the 129th death is deferred to the next call.
        vm.roll(block.number + K);
        auction.sync(10_000);
        assertEq(auction.settleCursor(), P0, "paused mid-tick, cursor holds the tick");

        auction.sync(10_000);
        assertEq(auction.settleCursor(), 0, "second call finishes the tick");
        for (uint256 i; i < n; ++i) {
            assertApproxEqAbs(_owed(address(uint160(0x4000 + i))), (i + 1) * 1e18, 2, "everyone got exactly their cap");
        }
        assertApproxEqAbs(auction.tokensSold(), 11_325e18, 500, "the whole book cleared across two calls");
    }

    // ------------------------------------------------------------------ heap mechanics

    /// Withdrawing from the middle of a populated heap must leave the death order intact:
    /// five distinct kappas, the middle one leaves, the pour still kills strictly by kappa.
    function test_withdrawFromHeapMiddle() public {
        _deploy(1_000e18, 0);
        for (uint256 i; i < 5; ++i) {
            address who = address(uint160(0x5000 + i));
            _stakeFor(who, 1e18);
            _bid(who, P0, uint128((i + 1) * 10e18), FLOOR); // caps 10/20/30/40/50
        }
        vm.prank(address(uint160(0x5002))); // cap-30 leaves from mid-heap
        auction.withdrawBid();
        assertEq(auction.tickPositions(P0).length, 4, "four seats left");

        _round(); // 1000 tokens >> remaining 120-token book: everyone dies, in kappa order
        assertApproxEqAbs(_owed(address(uint160(0x5000))), 10e18, 2, "cap 10 paid");
        assertApproxEqAbs(_owed(address(uint160(0x5001))), 20e18, 2, "cap 20 paid");
        assertEq(_owed(address(uint160(0x5002))), 0, "withdrawn earns nothing");
        assertApproxEqAbs(_owed(address(uint160(0x5003))), 40e18, 2, "cap 40 paid");
        assertApproxEqAbs(_owed(address(uint160(0x5004))), 50e18, 2, "cap 50 paid");
        // The last position exhausts exactly as the supply segment does — the documented
        // straggler: it keeps its seat (kappa == acc) until a later pour pops it for free.
        assertLe(auction.tickPositions(P0).length, 1, "at most the boundary straggler remains");
    }

    /// Both layers at once: the q-curve splits between ticks, stakes split within them.
    /// Hand-computed: W = 1.5, pour 90 -> 60/30; tick P1 (stakes 3:1) kills its cap-10 whale
    /// and hands the rest down; tick P0 (stakes 1:3) splits 7.5/22.5 with no deaths.
    function test_twoLevelWaterfall() public {
        _deploy(90e18, 0);
        _stakeFor(aa, 3e18);
        _stakeFor(bb, 1e18);
        _stakeFor(cc, 1e18);
        address dd = address(0xA4);
        _stakeFor(dd, 3e18);
        _bid(aa, P1, uint128(101e17), FLOOR); // cap 10 at 1.01
        _bid(bb, P1, uint128(202e18), FLOOR); // cap 200
        _bid(cc, P0, 40e18, FLOOR); // cap 40
        _bid(dd, P0, 400e18, FLOOR); // cap 400

        _round();

        assertApproxEqAbs(_owed(aa), 10e18, 2, "P1 whale-by-stake capped by its 10-token budget");
        assertApproxEqAbs(_owed(bb), 50e18, 2, "P1 partner takes the tick's other 50");
        assertApproxEqAbs(_owed(cc), 75e17, 2, "P0 at stake 1 of 4: 7.5");
        assertApproxEqAbs(_owed(dd), 225e17, 2, "P0 at stake 3 of 4: 22.5");
        assertApproxEqAbs(auction.tokensSold(), 90e18, 4, "whole round placed");
    }

    /// A cohort with identical kappas exhausts in ONE exhaust-step — no pops, stale seats,
    /// stale stakeSum. The next bidder into that tick must not inherit any of it: the next pour
    /// pops the stragglers for free before a single token moves.
    function test_staleCohortThenNewBid() public {
        _deploy(30e18, 0);
        for (uint256 i; i < 3; ++i) {
            address who = address(uint160(0x6000 + i));
            _stakeFor(who, 1e18);
            _bid(who, P0, 10e18, FLOOR); // identical: all three die together at 30 poured
        }
        _round();
        (,, uint256 cap0, uint256 stakeSum0,,,) = auction.ticks(P0);
        assertEq(cap0, 0, "tick capacity spent");
        assertEq(stakeSum0, 3e18, "stale stakeSum: the cohort died without pops");
        assertEq(auction.tickPositions(P0).length, 3, "stale seats linger");

        // A fresh bidder revives the tick; the stragglers are swept before the pour moves.
        _stakeFor(aa, 1e18);
        _bid(aa, P0, 100e18, FLOOR);
        _round();
        assertApproxEqAbs(_owed(aa), 30e18, 2, "the whole next round is the newcomer's");
        for (uint256 i; i < 3; ++i) {
            assertApproxEqAbs(_owed(address(uint160(0x6000 + i))), 10e18, 2, "cohort kept exactly its caps");
        }
        (,,, uint256 stakeSumAfter,,,) = auction.ticks(P0);
        assertEq(stakeSumAfter, 1e18, "stragglers swept from the weight");
        assertEq(auction.tickPositions(P0).length, 1, "and from the seats");
    }

    /// Winnings owed by a CLOSED bid still compound: withdraw keeps tokensOwed, claimAndStake
    /// credits them to the stake account with no seat to touch.
    function test_claimAndStakeWithoutBid() public {
        _deploy(100e18, 0);
        _stakeFor(aa, 1e18);
        _bid(aa, P0, 1000e18, FLOOR);
        _round();

        vm.prank(aa);
        auction.withdrawBid();
        assertGt(_owed(aa), 0, "winnings survive the withdraw");

        vm.prank(aa);
        uint256 got = auction.claimAndStake();
        assertEq(got, 100e18, "the round's winnings");
        assertEq(auction.stakes(aa), 101e18, "compounded onto the stake, no bid involved");
        assertEq(mono.balanceOf(aa), 0, "nothing left the contract");
    }

    /// A finalize that still sells keeps its progress and refuses; the next complete sweep that
    /// sells nothing passes. (`finalize(0)` is floored to the implicit budget, so it is a real
    /// sweep, not a zero-work park.)
    function test_finalizeNeedsACompleteSweep() public {
        uint64 end = uint64(block.number) + 2 * K;
        _deploy(100e18, end);
        _stakeFor(aa, 1e18);
        _bid(aa, P1, uint128(101e17), FLOOR); // cap 10: most of the 200 emitted will carry

        vm.roll(end + 1);
        assertFalse(auction.finalize(0), "this sweep still sold (the 10): progress kept, not done");
        assertFalse(auction.finalized());
        assertEq(auction.tokensSold(), 10e18, "floored budget: a real sweep, nothing parked");
        assertEq(auction.settleCursor(), 0);

        assertTrue(auction.finalize(1000), "a complete sweep selling nothing proves the rest is dead");
        assertTrue(auction.finalized());
    }

    // ------------------------------------------------------------------ review regressions

    /// Review finding (3 lenses converged): a tick revived above a dropped `highestTick` was
    /// unreachable forever. `_reseat` now restores the high-water on seating.
    function test_revivedTickAboveDroppedHighWaterEarns() public {
        _deploy(50e18, 0);
        _stakeFor(aa, 1e18);
        _stakeFor(bb, 1e18);
        _bid(aa, P1, uint128(101e17), FLOOR); // cap 10 at the top
        _bid(bb, P0, 100e18, FLOOR);

        vm.prank(aa);
        auction.unstake(1e18); // P1 goes zombie
        _round(); // sweep drops the high-water to P0; bb takes the whole 50
        assertEq(_owed(bb), 50e18);

        _stakeFor(aa, 1e18); // revival must re-raise the high-water
        _round();
        assertApproxEqAbs(_owed(aa), 10e18, 2, "revived top tick fills to its cap");
        assertApproxEqAbs(_owed(bb), 90e18, 2, "the rest waterfalls down as usual");
    }

    /// Review finding: the cumulative minted/sold claim ratio made payouts order-dependent after
    /// a NAV-clamped pack, dumping the whole deficit on the last claimant. Claims now take
    /// `owed * held / unclaimed` — the ratio is invariant under claiming, order cannot matter.
    function test_claimOrderIndependentAfterShortfall() public {
        _deploy(51e18, 0);
        address[3] memory who = [aa, bb, cc];
        for (uint256 i; i < 3; ++i) {
            _stakeFor(who[i], 1e18);
            _bid(who[i], P0, 100e18, FLOOR);
        }
        _round();
        auction.claim(aa); // 17e18 at full ratio, packs round 1

        cur.mint(address(mono), GENESIS); // donation: NAV doubles, the next pack will clamp
        _round();

        auction.claim(aa);
        auction.claim(bb);
        auction.claim(cc);
        // Equal up to the booking reserve: the pot books one token-wei less per extra seat, and
        // `claim` clamps the last claimant to what is left (`_pourTick`).
        assertApproxEqAbs(mono.balanceOf(bb), mono.balanceOf(cc), 2, "identical positions, identical payout, any order");
        // Nothing burned: every minted token reaches a claimant (dust aside).
        assertApproxEqAbs(
            mono.balanceOf(aa) + mono.balanceOf(bb) + mono.balanceOf(cc),
            auction.tokensMinted(),
            4,
            "the whole pot was paid out"
        );
    }

    /// Review finding: folding an already-effective pending generation used its raw boundary,
    /// materialising emission past `endBlock`. A generation can no longer be queued for a
    /// boundary at or past the end at all (`ScheduleFrozen`), so the frozen schedule stays exact.
    function test_setRoundParamsRefusesTheFrozenTail() public {
        uint64 end = uint64(block.number) + 10 * K;
        _deploy(10e18, end);

        // Inside the last round the next boundary IS `endBlock`: refused.
        vm.roll(end - K / 2);
        vm.prank(address(0xF1));
        vm.expectRevert(IGenerousAuction.ScheduleFrozen.selector);
        auction.setRoundParams(K, 99e18);

        vm.roll(end + 5 * K);
        vm.prank(address(0xF1));
        vm.expectRevert(IGenerousAuction.ScheduleFrozen.selector);
        auction.setRoundParams(K, 1e18);

        assertEq(auction.emittedToDate(), 100e18, "not a wei past the frozen schedule");
    }

    /// Review finding: a post-finalize re-stake could revive the book and vacuum the leftover
    /// carry at post-unlock weights. A finalized sale now reads `due() == 0` forever.
    function test_finalizedSaleStaysDead() public {
        uint64 end = uint64(block.number) + 2 * K;
        _deploy(100e18, end);
        _stakeFor(bb, 1e18);
        _bid(bb, P0, 100e18, FLOOR); // cap 100 of the 200 the schedule releases
        vm.prank(bb);
        auction.unstake(1e18); // inert before anything settles: the book is dead

        vm.roll(end + 1);
        assertTrue(auction.finalize(1000), "dead book finalizes");
        uint256 soldAt = auction.tokensSold();

        _stakeFor(bb, 1e18); // revival after the sale is over...
        auction.sync(1000);
        assertEq(auction.tokensSold(), soldAt, "...sells nothing: the carry died with the sale");
        assertEq(auction.due(), 0, "a finalized sale owes nothing");
    }

    /// Review finding: withdrawing escrow during the lock window repriced the frozen backlog
    /// onto the remaining stakers. Withdrawals now wait for the tail (or `finalize`).
    function test_withdrawWaitsForTheTail() public {
        uint64 end = uint64(block.number) + 2 * K;
        _deploy(100e18, end);
        _stakeFor(bb, 1e18);
        _bid(bb, P0, 100e18, FLOOR);
        vm.prank(bb);
        auction.unstake(1e18); // inert: carry will stand past the end

        vm.roll(end + 1);
        assertGt(auction.due(), 0);
        vm.prank(bb);
        vm.expectRevert(IGenerousAuction.StakeLocked.selector);
        auction.withdrawBid();

        auction.finalize(1000);
        vm.prank(bb);
        assertEq(auction.withdrawBid(), 100e18, "free once the sale is settled");
    }

    /// Review finding (PoC'd): the supply-exhaust branch booked the un-handed flooring remainder
    /// as sold and charged, leaving the contract short of live escrow and bricking the last
    /// withdrawal. Wei-scale, but an invariant break — now the remainder stays in `due()`.
    function test_pourFlooringStaysSolvent() public {
        _deploy(4, 0); // four WEI of emission per round against a three-wei stake
        mono.transfer(aa, 3);
        vm.startPrank(aa);
        mono.approve(address(auction), 3);
        auction.stake(3);
        vm.stopPrank();
        _bid(aa, P0, 10, FLOOR); // ten wei of escrow

        _round();
        uint256 got = auction.claim(aa); // packs: the vault is paid exactly what was charged
        assertEq(got, 4, "the whole booked pour reaches the position (ceil advance)");
        assertEq(auction.tokensUnclaimed(), 0, "nothing stranded behind the clamp");

        vm.prank(aa);
        uint256 back = auction.withdrawBid();
        assertEq(back, 6, "live escrow returns in full, no revert");
        assertEq(cur.balanceOf(address(auction)), 0, "solvent to the wei: escrow out, strike to the vault");
    }

    // ------------------------------------------------------------------ round-2 review

    function _assertHeapShape(uint256 price) internal view {
        address[] memory seats = auction.tickPositions(price);
        for (uint256 i = 1; i < seats.length; ++i) {
            (,,,, uint256 childK,,) = auction.positions(seats[i]);
            (,,,, uint256 parentK,,) = auction.positions(seats[(i + 1) / 2 - 1]);
            assertLe(parentK, childK, "heap order violated");
        }
    }

    /// Round-2 finding (both reviewers, PoC'd): a budget-truncated implicit sync let a same-call
    /// stake bump retro-capture the un-poured backlog (49.7/0.05 vs an honest 25/25). Weight
    /// changes now demand a settled tick: SettleFirst until a real sync clears the cursor.
    /// This is also the multi-tick pause regression: the cursor parks on the WINDOW top (P1),
    /// not the paused tick (P0) — on the pre-fix code the two were indistinguishable.
    function test_truncatedSyncCannotBeReweighed() public {
        _deploy(100e18, 0);
        address ss = address(0x51);
        _stakeFor(ss, 1e18);
        _bid(ss, P1, uint128(1010e18), FLOOR); // top survivor: cap 1000
        _stakeFor(aa, 1e18);
        _bid(aa, P0, 100e18, FLOOR);
        // 300 pending deaths: more than TWO death budgets, so even the guard-tripping call's
        // own internal sync cannot finish the drain. Real stakes, dust caps: kappa gaps are
        // tiny and the deaths cost almost no supply.
        for (uint256 i; i < 300; ++i) {
            address who = address(uint160(0x7000 + i));
            _stakeFor(who, 1e18);
            _bid(who, P0, uint128(i + 1), FLOOR);
        }

        vm.roll(block.number + K);
        auction.sync(10_000); // 150 pending deaths > budget: pauses mid-P0
        assertEq(auction.settleCursor(), P1, "cursor parks on the window TOP, not the paused tick");
        assertGt(auction.due(), 0);

        // The backlog below the cursor is un-poured: bumping weight there must refuse.
        mono.transfer(aa, 1e18);
        vm.startPrank(aa);
        mono.approve(address(auction), 1e18);
        vm.expectRevert(IGenerousAuction.SettleFirst.selector);
        auction.stake(1e18);
        vm.stopPrank();

        for (uint256 i; i < 4 && auction.settleCursor() != 0; ++i) {
            auction.sync(10_000); // real syncs drain the tail, one death budget per call
        }
        assertEq(auction.settleCursor(), 0);
        vm.startPrank(aa);
        auction.stake(1e18); // now honest
        vm.stopPrank();
        // Known pause semantics (ponytail in source): each pause returns the paused tick's
        // un-poured allocation to `due()`, and every resumed pour re-splits the remainder by
        // q-weight — so the surviving TOP tick re-takes 2/3 of each remainder and compounds
        // toward ~96.3 of the 100 instead of the single-pass 66.7. Forcing pauses costs the
        // attacker a sybil per death and the leak flows to the HIGHEST price payer.
        assertApproxEqAbs(_owed(ss), 96296296296296260054, 1e12, "top re-takes q-share on each resume");
        assertGt(_owed(aa), 3e18, "the paused tick still gets the tail of the tail");
    }

    /// The schedule stops at `saleSupply`: once sold out, `due()` is zero forever.
    function test_sellOutStopsTheSale() public {
        uint256 supply = auction.saleSupply();
        _deploy(uint128(supply), 0);
        supply = auction.saleSupply();
        _stakeFor(aa, 1e18);
        uint128 escrow = uint128(supply + 1e18);
        cur.mint(aa, escrow);
        vm.startPrank(aa);
        cur.approve(address(auction), escrow);
        auction.submitBid(P0, escrow, aa, FLOOR);
        vm.stopPrank();

        vm.roll(block.number + K);
        auction.sync(1000);
        assertEq(auction.tokensSold(), supply, "sold exactly the sale");
        assertEq(auction.remaining(), 0);
        vm.roll(block.number + 10 * K);
        assertEq(auction.due(), 0, "the schedule is over, not carrying");
    }

    /// A wrong hint never reverts: stale, above the price, or uninitialised, the bid still lands in
    /// the right place (the contract walks for the predecessor). Plus an insert between two ticks.
    function test_prevHintMatrix() public {
        _stakeFor(aa, 1e18);
        _bid(aa, P1, 10e18, FLOOR);
        uint256 p2 = FLOOR + 2 * SPACING;
        uint256 p3 = FLOOR + 3 * SPACING;

        cur.mint(aa, 40e18);
        vm.startPrank(aa);
        cur.approve(address(auction), 40e18);
        vm.expectRevert(IGenerousAuction.BidExists.selector); // aa already sits at P1
        auction.submitBid(p3, 10e18, aa, P1);
        vm.stopPrank();

        _stakeFor(bb, 1e18);
        cur.mint(bb, 40e18);
        vm.startPrank(bb);
        cur.approve(address(auction), 40e18);
        auction.submitBid(p3, 10e18, bb, FLOOR); // stale: skips initialized P1 — repaired
        vm.stopPrank();
        (uint256 nextOfP1a, uint256 prevOfP3,,,,,) = auction.ticks(p3);
        assertEq(prevOfP3, P1, "landed above P1 despite the stale hint");
        assertEq(nextOfP1a, 0);
        vm.prank(bb);
        auction.withdrawBid();

        _stakeFor(address(0xD1), 1e18);
        cur.mint(address(0xD1), 20e18);
        vm.startPrank(address(0xD1));
        cur.approve(address(auction), 20e18);
        auction.submitBid(p3, 10e18, address(0xD1), p3); // prev >= price — repaired
        vm.stopPrank();
        (, prevOfP3,,,,,) = auction.ticks(p3);
        assertEq(prevOfP3, P1);

        cur.mint(bb, 10e18);
        vm.startPrank(bb);
        cur.approve(address(auction), 10e18);
        auction.submitBid(p3, 10e18, bb, p2); // prev not initialized — p3 already linked, fine
        vm.stopPrank();

        _stakeFor(cc, 1e18);
        cur.mint(cc, 10e18);
        vm.startPrank(cc);
        cur.approve(address(auction), 10e18);
        auction.submitBid(p2, 10e18, cc, P1); // inserts BETWEEN P1 and p3
        vm.stopPrank();
        (uint256 nextOfP1,,,,,,) = auction.ticks(P1);
        (uint256 nextOfP2, uint256 prevOfP2,,,,,) = auction.ticks(p2);
        assertEq(nextOfP1, p2);
        assertEq(nextOfP2, p3);
        assertEq(prevOfP2, P1);
    }

    /// The submitBid validation wall, brick by brick.
    function test_bidValidationReverts() public {
        _stakeFor(aa, 1e18);
        cur.mint(aa, 100e18);
        vm.startPrank(aa);
        cur.approve(address(auction), 100e18);
        vm.expectRevert(IGenerousAuction.InvalidParams.selector);
        auction.submitBid(P0, 0, aa, FLOOR);
        vm.expectRevert(IGenerousAuction.InvalidParams.selector);
        auction.submitBid(P0, 1e18, address(0), FLOOR);
        vm.expectRevert(IGenerousAuction.BidTooLow.selector);
        auction.submitBid(FLOOR - SPACING, 1e18, aa, 0);
        vm.expectRevert(IGenerousAuction.BidTooHigh.selector);
        auction.submitBid(FLOOR * 1e4 + SPACING, 1e18, aa, FLOOR);
        vm.expectRevert(IGenerousAuction.TickNotAligned.selector);
        auction.submitBid(P0 + 1, 1e18, aa, FLOOR);
        vm.expectRevert(IGenerousAuction.BidTooSmall.selector);
        auction.submitBid(FLOOR + 200 * SPACING, uint128(1), aa, FLOOR); // 1 wei cannot buy a token wei at 3.0
        vm.stopPrank();
    }

    function test_stakingValidationReverts() public {
        vm.expectRevert(IGenerousAuction.InvalidParams.selector);
        auction.stake(0);
        vm.expectRevert(IGenerousAuction.InvalidParams.selector);
        auction.unstake(0);
        vm.expectRevert(IGenerousAuction.InsufficientStake.selector);
        auction.unstake(1);
    }

    /// Removing a mid-heap seat so the last leaf must sift UP (the up-loop of `_siftInto`).
    function test_heapSiftUpOnRemoval() public {
        _deploy(100_000e18, 0);
        uint8[6] memory caps = [1, 10, 2, 11, 12, 3];
        for (uint256 i; i < 6; ++i) {
            address who = address(uint160(0x8000 + i));
            _stakeFor(who, 1e18);
            _bid(who, P0, uint128(uint256(caps[i]) * 1e18), FLOOR);
        }
        _assertHeapShape(P0);

        // Withdraw the cap-11 owner: the last leaf (cap 3) lands in its slot under a cap-10
        // parent region and must sift upward.
        address mid;
        address[] memory seats = auction.tickPositions(P0);
        for (uint256 i; i < seats.length; ++i) {
            (, uint128 amt,,,,,) = auction.positions(seats[i]);
            if (amt == 11e18) mid = seats[i];
        }
        vm.prank(mid);
        auction.withdrawBid();
        _assertHeapShape(P0);

        _round(); // everyone dies; each gets exactly its cap
        for (uint256 i; i < 6; ++i) {
            address who = address(uint160(0x8000 + i));
            uint256 expect = caps[i] == 11 ? 0 : uint256(caps[i]) * 1e18;
            assertApproxEqAbs(_owed(who), expect, 2, "kappa order held through the sift");
        }
    }

    /// A position that exhausted in place (live == 0, never withdrawn) may re-bind elsewhere;
    /// its crystallised winnings survive the move.
    function test_rebindAfterExhaustion() public {
        _deploy(100e18, 0);
        _stakeFor(aa, 1e18);
        _bid(aa, P1, uint128(101e17), FLOOR); // cap 10, fully consumed by the round
        _round();
        (uint256 live,) = auction.positionOf(aa);
        assertEq(live, 0, "exhausted in place");

        _bid(aa, P0, 50e18, FLOOR); // no withdraw needed: nothing live to move
        (uint256 price,,,,,,) = auction.positions(aa);
        assertEq(price, P0, "re-bound");
        assertApproxEqAbs(_owed(aa), 10e18, 2, "winnings from the old tick survive");
        (,, uint256 oldCap, uint256 oldStake,,,) = auction.ticks(P1);
        assertEq(oldCap, 0, "abandoned tick holds no phantom capacity");
        assertEq(oldStake, 0, "nor phantom weight");
    }

    function test_withdrawTwiceReverts() public {
        _stakeFor(aa, 1e18);
        _bid(aa, P0, 10e18, FLOOR);
        vm.startPrank(aa);
        auction.withdrawBid();
        vm.expectRevert(IGenerousAuction.NoPosition.selector);
        auction.withdrawBid();
        vm.stopPrank();
        vm.prank(bb); // never bid at all
        vm.expectRevert(IGenerousAuction.NoPosition.selector);
        auction.withdrawBid();
    }

    /// The lock guard is `locked && due() != 0`: a drained tail frees withdrawals pre-finalize.
    function test_withdrawInLockWithDrainedTailSucceeds() public {
        uint64 end = uint64(block.number) + 2 * K;
        _deploy(100e18, end);
        _stakeFor(aa, 1e18);
        _bid(aa, P0, 303e18, FLOOR); // cap 303 >= the 200 emitted: no carry survives
        vm.roll(end + 1);
        auction.sync(64);
        assertEq(auction.due(), 0);
        vm.prank(aa);
        uint256 back = auction.withdrawBid();
        assertApproxEqAbs(back, 103e18, 2, "drained tail, withdrawal free before finalize");
    }

    /// Post-finalize life: claims still pay, and claimAndStake compounds again (stakes reopen).
    function test_claimAndStakeAfterFinalize() public {
        uint64 end = uint64(block.number) + 2 * K;
        _deploy(100e18, end);
        _stakeFor(aa, 1e18);
        _bid(aa, P0, 300e18, FLOOR);
        vm.roll(end + 1);
        assertTrue(auction.finalize(1000));

        vm.prank(aa);
        uint256 got = auction.claimAndStake();
        assertEq(got, 200e18, "both rounds");
        assertEq(auction.stakes(aa), 201e18, "compounding reopens after finalize");
    }

    /// Flat split: q == Q96 is exempt from the edge-weight gate and splits the window evenly.
    function test_flatQSplitsEvenly() public {
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
                decayQ: Q96, // flat
                windowTicks: 8,
                startBlock: uint64(block.number),
                endBlock: 0,
                roundBlocks: K,
                emissionPerRound: 90e18,
                minPremiumBips: 1_500,
                previousAuction: address(0)
            })
        );
        mono.grantRole(mono.MINTER_ROLE(), address(auction));
        mono.renounceRole(mono.MINTER_ROLE(), address(this));

        address[3] memory who = [aa, bb, cc];
        for (uint256 i; i < 3; ++i) {
            _stakeFor(who[i], 1e18);
            _bid(who[i], FLOOR + i * SPACING, 500e18, i == 0 ? FLOOR : FLOOR + (i - 1) * SPACING);
        }
        _round();
        for (uint256 i; i < 3; ++i) {
            assertApproxEqAbs(_owed(who[i]), 30e18, 2, "flat q: even thirds");
        }
    }

    /// Before `startBlock` the book accepts bids and stakes but the schedule is silent.
    function test_preStartAccumulatesNothing() public {
        cur = new TestERC20("Index", "INDEX");
        mono = new Mono(IIndex(address(cur)), 10 * GENESIS);
        cur.mint(address(this), GENESIS);
        cur.approve(address(mono), GENESIS);
        mono.mint(GENESIS, GENESIS, address(this));
        MockPool pool = new MockPool(address(mono), address(cur), 1.25e18);
        mono.setPool(address(pool));
        uint64 start = uint64(block.number + 1000);
        auction = new GenerousAuction(
            IGenerousAuction.Config({
                token: address(mono),
                currency: address(cur),
                admin: address(0xF1),
                floorPrice: FLOOR,
                tickSpacing: SPACING,
                decayQ: HALF,
                windowTicks: 8,
                startBlock: start,
                endBlock: 0,
                roundBlocks: K,
                emissionPerRound: 100e18,
                minPremiumBips: 1_500,
                previousAuction: address(0)
            })
        );
        mono.grantRole(mono.MINTER_ROLE(), address(auction));
        mono.renounceRole(mono.MINTER_ROLE(), address(this));

        _stakeFor(aa, 1e18);
        _bid(aa, P0, 500e18, FLOOR); // the book builds while the schedule sleeps
        auction.sync(64);
        assertEq(auction.emittedToDate(), 0);
        assertEq(auction.tokensSold(), 0);
        assertEq(auction.claim(aa), 0, "nothing accrued before start");

        vm.roll(start + K);
        auction.sync(64);
        assertEq(_owed(aa), 100e18, "the first round lands one K after start");
    }

    // ------------------------------------------------------------------ round-3 review

    /// Builds a wall of `n` initialized-but-dead ticks above the book (the free-cancel loop the
    /// round-3 critical PoC used), while the book is settled so every op passes the guard.
    function _buildWall(uint256 n) internal returns (uint256 top) {
        address wb = address(0x3AD);
        _stakeFor(wb, 1e18);
        uint256 prev = FLOOR;
        for (uint256 i = 1; i <= n; ++i) {
            uint256 p = FLOOR + 20 * SPACING + i * SPACING;
            _bid(wb, p, 2e18, prev == FLOOR ? FLOOR : prev);
            vm.prank(wb);
            auction.withdrawBid();
            prev = p;
            top = p;
        }
    }

    /// Round-3 CRITICAL regression: a latecomer bidding ABOVE a parked cursor used to become the
    /// new top and take a standing bidder's entire backlog. The guard is now price-independent:
    /// mid-sweep with something owed, NO weight moves anywhere — and wall-shaving makes the
    /// drain a one-time cost, after which the standing bidder is paid in full.
    function test_latecomerCannotJumpAMidSweepBook() public {
        _deploy(40e18, 0);
        _stakeFor(aa, 1e18);
        _bid(aa, P0, 1000e18, FLOOR); // the standing bidder the backlog belongs to
        uint256 wallTop = _buildWall(500); // deeper than the sum of every internal sync budget the test path spends

        vm.roll(block.number + 10 * K); // 400e18 of backlog accrues, nobody syncs
        auction.sync(64); // truncates inside the wall
        assertGt(auction.settleCursor(), 0, "parked mid-wall");
        assertLt(auction.highestTick(), wallTop, "the walked stretch is shaved off permanently");

        // The attack: a high bid above everything. Price-independent guard refuses.
        address atk = address(0xBAD);
        _stakeFor(atk, 1e18);
        cur.mint(atk, 500e18);
        vm.startPrank(atk);
        cur.approve(address(auction), 500e18);
        vm.expectRevert(IGenerousAuction.SettleFirst.selector);
        auction.submitBid(wallTop + SPACING, 500e18, atk, wallTop);
        vm.stopPrank();

        for (uint256 i; i < 12 && auction.settleCursor() != 0; ++i) {
            auction.sync(64); // each call shaves more wall, permanently
        }
        assertEq(auction.settleCursor(), 0, "drained");
        assertApproxEqAbs(_owed(aa), 400e18, 4, "the whole backlog reached the one who stood for it");

        // With the book settled the latecomer is welcome — for FUTURE rounds only. The wall is
        // gone from the list (walked dead runs are unlinked), so the live predecessor is the
        // standing bidder's tick.
        vm.startPrank(atk);
        auction.submitBid(wallTop + SPACING, 500e18, atk, P0);
        vm.stopPrank();
    }

    /// Round-3 lockout regression: the shaved wall is never re-walked. After one full drain, a
    /// fresh round settles in a single small-budget sync even though the wall is deeper than it.
    function test_wallIsShavedPermanently() public {
        _deploy(40e18, 0);
        _stakeFor(aa, 1e18);
        _bid(aa, P0, 1000e18, FLOOR);
        _buildWall(140);

        vm.roll(block.number + K);
        for (uint256 i; i < 6 && (auction.settleCursor() != 0 || auction.due() != 0); ++i) {
            auction.sync(64);
        }
        assertEq(auction.due(), 0, "first backlog drained across chunks");

        vm.roll(block.number + K); // a fresh round against the same book
        auction.sync(64); // 64 << 140-tick wall: only passes if the wall is truly gone
        assertEq(auction.settleCursor(), 0, "no re-walk: one small budget settles the round");
        assertApproxEqAbs(_owed(aa), 80e18, 4, "both rounds delivered");
    }

    /// All four guard arms + the claimAndStake degrade, on one parked-cursor state.
    function test_guardArmsWhileMidSweep() public {
        _deploy(40e18, 0);
        _stakeFor(aa, 2e18);
        _bid(aa, P0, 1000e18, FLOOR);
        _buildWall(260);
        vm.roll(block.number + K);
        auction.sync(64); // parked
        assertGt(auction.settleCursor(), 0);

        vm.startPrank(aa);
        vm.expectRevert(IGenerousAuction.SettleFirst.selector);
        auction.withdrawBid();
        vm.expectRevert(IGenerousAuction.SettleFirst.selector);
        auction.unstake(1e18);
        vm.stopPrank();
        mono.transfer(aa, 1e18);
        vm.startPrank(aa);
        mono.approve(address(auction), 1e18);
        vm.expectRevert(IGenerousAuction.SettleFirst.selector);
        auction.stake(1e18);
        vm.stopPrank();

        // claimAndStake degrades to a plain claim: winnings flow, the stake leg waits.
        uint256 stakeBefore = auction.stakes(aa);
        vm.prank(aa);
        auction.claimAndStake();
        assertEq(auction.stakes(aa), stakeBefore, "no weight change mid-sweep");
    }

    /// Mutation-audit hole: kill a position via a REAL head pop, then have the same owner come
    /// back. A forgotten `heapIdx = 0` on pop would corrupt the seat list on the return trip.
    function test_popThenComeBack() public {
        _deploy(200e18, 0);
        _stakeFor(aa, 1e18);
        _bid(aa, P1, uint128(101e17), FLOOR); // cap 10: dies by pop while bb survives
        _stakeFor(bb, 1e18);
        _bid(bb, P1, uint128(1010e18), FLOOR); // cap 1000
        _round();
        (uint256 liveA,) = auction.positionOf(aa);
        assertEq(liveA, 0, "aa popped dead");
        assertEq(auction.tickPositions(P1).length, 1, "only bb seated");

        _bid(aa, P1, uint128(101e17), FLOOR); // the return trip re-seats cleanly
        _assertHeapShape(P1);
        address[] memory seats = auction.tickPositions(P1);
        assertEq(seats.length, 2, "both seated, nobody twice");
        (,,, uint256 stakeSum,,,) = auction.ticks(P1);
        assertEq(stakeSum, 2e18, "aggregates track the return");
    }

    function test_setRoundParamsBoundsRoundBlocks() public {
        vm.startPrank(address(0xF1));
        vm.expectRevert(IGenerousAuction.InvalidParams.selector);
        auction.setRoundParams(uint64(type(uint32).max) + 1, 1e18);
        vm.stopPrank();
    }

    /// Round-4 HIGH regression: with chunked rounds, one block of doubled stake before the
    /// boundary captured a whole round's inflated share (2/3 of it). Accrual is block-linear
    /// now: the flicker earns exactly its one block of standing, nothing more.
    function test_boundaryStakeFlickerEarnsOneBlock() public {
        _deploy(100e18, 0);
        _stakeFor(aa, 1e18);
        _stakeFor(bb, 1e18);
        _bid(aa, P0, 1000e18, FLOOR);
        _bid(bb, P0, 1000e18, FLOOR);

        vm.roll(block.number + K - 1);
        _stakeFor(bb, 1e18); // the flicker: doubles for the round's last block only
        vm.roll(block.number + 1);
        vm.prank(bb);
        auction.unstake(1e18); // and exits right after the boundary

        // K-1 blocks split 1:1 (49.5 each), ONE block split 2:1 (0.667/0.333).
        assertApproxEqAbs(_owed(aa), 49833333333333333333, 10, "the committed staker keeps ~half");
        assertApproxEqAbs(_owed(bb), 50166666666666666666, 10, "one block of extra weight buys one block's share");
    }

    /// Round-5 CRITICAL regression: a same-price top-up of an exhausted position used to inherit
    /// a stale accAtEntry and instantly "own" its whole new cap as phantom winnings, draining
    /// co-stakers' pot. The early-return of _harvest re-anchors now.
    function test_topUpAfterExhaustionStealsNothing() public {
        _deploy(40e18, 0);
        _stakeFor(aa, 10e18);
        _bid(aa, P0, 2e18, FLOOR); // tiny cap: exhausts in round 1
        _stakeFor(bb, 10e18);
        _bid(bb, P0, 500e18, FLOOR);

        _round(); // aa dies at 2e18; bb takes 38e18
        _round();
        _round(); // 80e18 more, all bb's

        (uint256 liveA,) = auction.positionOf(aa);
        assertEq(liveA, 0, "attacker exhausted");
        assertApproxEqAbs(_owed(bb), 118e18, 4, "victim's accrual");

        _bid(aa, P0, 100e18, FLOOR); // the attack: same-price top-up over three rounds of stale index
        assertApproxEqAbs(_owed(aa), 2e18, 4, "top-up owns NOTHING it did not fill");

        uint256 gotB = auction.claim(bb);
        assertApproxEqAbs(gotB, 118e18, 4, "the victim's pot is intact");
    }

    /// Round-5 soak regression: an INTERIOR dead ridge (top of book above it) used to be
    /// re-walked by every sync; it is spliced out of the list on first walk now.
    function test_interiorRidgeSplicedOnce() public {
        _deploy(40e18, 0);
        _stakeFor(aa, 1e18);
        _bid(aa, P0, 1000e18, FLOOR); // live floor
        _buildWall(200); // dead ridge above the floor
        address hh = address(0x111);
        _stakeFor(hh, 1e18);
        uint256 top = FLOOR + 20 * SPACING + 201 * SPACING;
        _bid(hh, top, 500e18, FLOOR + 20 * SPACING + 200 * SPACING); // live top ABOVE the ridge

        vm.roll(block.number + K);
        for (uint256 i; i < 8 && (auction.settleCursor() != 0 || auction.due() != 0); ++i) {
            auction.sync(300); // first pass walks (and splices) the ridge
        }
        assertEq(auction.due(), 0);

        vm.roll(block.number + K); // fresh round against the same book
        auction.sync(32); // 32 << 200: only completes if the interior ridge is GONE from the list
        assertEq(auction.settleCursor(), 0, "no interior re-walk: the ridge was spliced out");
    }

    /// A price spliced out as part of a dead ridge can be re-initialised by a later bid: the
    /// back-pointer check spots the stale links and re-inserts via the hint.
    function test_rebidIntoSplicedTick() public {
        _deploy(40e18, 0);
        _stakeFor(aa, 1e18);
        _bid(aa, P0, 1000e18, FLOOR);
        _buildWall(200);
        vm.roll(block.number + K);
        for (uint256 i; i < 8 && (auction.settleCursor() != 0 || auction.due() != 0); ++i) {
            auction.sync(300);
        }

        uint256 mid = FLOOR + 20 * SPACING + 100 * SPACING; // deep inside the spliced ridge
        _stakeFor(bb, 1e18);
        _bid(bb, mid, 101e18, FLOOR); // hint: FLOOR is now its exact list predecessor
        vm.roll(block.number + K);
        auction.sync(64);
        assertGt(_owed(bb), 0, "re-initialised tick is reachable and earns");
    }

    // ------------------------------------------------------------------ the lock window

    /// Stakes move freely during the sale, freeze between `endBlock` and `finalize`, and move
    /// freely again after — the freeze is what keeps the lazy tail honest.
    function test_stakeLocksUntilFinalize() public {
        uint64 end = uint64(block.number) + 2 * K;
        _deploy(100e18, end);
        _stakeFor(aa, 2e18);
        _bid(aa, P0, 1000e18, FLOOR); // absorbs both rounds in full

        vm.startPrank(aa);
        auction.unstake(1e18); // free while the sale runs
        mono.approve(address(auction), 1e18);
        auction.stake(1e18);
        vm.stopPrank();

        vm.roll(end);
        vm.startPrank(aa);
        vm.expectRevert(IGenerousAuction.StakeLocked.selector);
        auction.stake(1e18);
        vm.expectRevert(IGenerousAuction.StakeLocked.selector);
        auction.unstake(1e18);
        vm.stopPrank();

        // Too early only while something is still owed: drain it, then finalize.
        auction.finalize(64);
        assertTrue(auction.finalized(), "backlog drained, lock lifted");

        vm.prank(aa);
        auction.unstake(2e18);
        assertEq(mono.balanceOf(aa), 2e18, "stake returned in full");
    }

    function test_finalizeRefusesEarlyAndDrainsFirst() public {
        uint64 end = uint64(block.number) + 2 * K;
        _deploy(100e18, end);
        _stakeFor(aa, 1e18);
        _bid(aa, P0, 1000e18, FLOOR);

        vm.expectRevert(IGenerousAuction.NotFinalizable.selector);
        auction.finalize(64); // the sale is still running

        vm.roll(end + 1);
        auction.finalize(64); // one call: syncs the tail, sees due()==0, flips
        assertTrue(auction.finalized());
        assertEq(_owed(aa), 200e18, "the tail was distributed on the way out");
    }

    /// A dead book cannot hold stakes hostage: past `endBlock` bids and stakes are frozen, so a
    /// complete sweep that sells nothing proves the carry will never move — and unlocks.
    function test_finalizeDeadBook() public {
        uint64 end = uint64(block.number) + 2 * K;
        _deploy(100e18, end);
        _stakeFor(cc, 5e18); // stakes, never bids

        vm.roll(end + 1);
        assertGt(auction.due(), 0, "carry stands");
        vm.prank(cc);
        vm.expectRevert(IGenerousAuction.StakeLocked.selector);
        auction.unstake(5e18);

        auction.finalize(1000);
        assertTrue(auction.finalized(), "nothing sellable, provably: unlock");

        vm.prank(cc);
        auction.unstake(5e18);
        assertEq(mono.balanceOf(cc), 5e18);
    }

    // ------------------------------------------------------------------ claim-and-stake

    /// One transaction from winnings to weight: the claim leg books exactly what `claim` would,
    /// the stake leg compounds it, and the next round already splits at the new ratio.
    function test_claimAndStake_compounds() public {
        _deploy(90e18, 0);
        _stakeFor(aa, 45e18);
        _stakeFor(bb, 45e18);
        _bid(aa, P0, 1000e18, FLOOR);
        _bid(bb, P0, 1000e18, FLOOR);

        _round();
        assertEq(_owed(aa), 45e18, "round 1 split evenly");

        vm.prank(aa);
        uint256 got = auction.claimAndStake();
        assertEq(got, 45e18, "the claim leg pays what claim would");
        assertEq(mono.balanceOf(aa), 0, "nothing left the contract");
        assertEq(auction.stakes(aa), 90e18, "winnings became weight");
        assertEq(_owed(aa), 0, "and the position was settled");

        _round();
        assertApproxEqAbs(_owed(aa), 60e18, 2, "round 2 at the compounded 2:1");
        assertApproxEqAbs(_owed(bb), 75e18, 2, "45 + a third of round 2");
    }

    /// Inside the lock window the stake leg is frozen but winnings must flow: it degrades to a
    /// plain claim, paying the wallet instead of the stake account.
    function test_claimAndStake_fallsBackDuringLock() public {
        uint64 end = uint64(block.number) + 2 * K;
        _deploy(100e18, end);
        _stakeFor(aa, 1e18);
        _bid(aa, P0, 1000e18, FLOOR);

        vm.roll(end); // schedule frozen, stakes locked, backlog not yet drained
        vm.prank(aa);
        uint256 got = auction.claimAndStake();
        assertEq(got, 200e18, "both rounds claimed");
        assertEq(mono.balanceOf(aa), 200e18, "paid to the wallet, not the stake");
        assertEq(auction.stakes(aa), 1e18, "stake untouched during the lock");
    }

    // ------------------------------------------------------------------ custody

    /// Staked MONO is bidders' property: claims are paid strictly out of minted packs, and the
    /// full stake walks out afterwards.
    function test_stakeNeverPaysClaims() public {
        _deploy(150e18, 0);
        _stakeFor(aa, 500e18);
        _bid(aa, P0, 20e18, FLOOR); // capacity 20 of the 150-token round

        _round();
        uint256 got = auction.claim(aa);
        assertApproxEqAbs(got, 20e18, 2, "paid what the escrow bought");
        assertGe(mono.balanceOf(address(auction)), auction.totalStaked(), "stake untouched by the pack");

        vm.prank(aa);
        auction.unstake(500e18);
        assertEq(mono.balanceOf(aa), got + 500e18, "claim plus the whole stake, separately");
    }
}
