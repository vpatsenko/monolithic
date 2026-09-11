// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Review9LinksBase} from "./Review9_links_Base.sol";

/// ROUND 14, lens `splice`: adversarial re-check of the round-9 change
///
///     uint256 mark = (drained || pausedAt != 0 || w.resume == 0) ? w.tau : w.resume;
///     if (mark < highestTick) highestTick = mark;
///     _splice(price, mark);
///
/// whose load-bearing claim is: "otherwise the band ran DRY: every tick from the walk's start
/// down to (not including) `w.resume` is dead".
///
/// FALSIFICATION. `_solveBand` marks a tick dead-in-model when the sorted walk reaches its
/// `kappa`, and a tick whose on-chain capacity outran the supply is keyed at
/// `capK = min(cap, supply | left)` — the comment on that clamp says "a tick capped here would
/// need more tokens than exist, so the supply runs out before it does", i.e. it assumes reaching
/// such a tick's `kappa` always trips `drained`. It does not. The segment cost
/// `dT = floor(weightLeft * (kappa - C) / Q96)` is FLOORED, and a tick that joined the walk at
/// `entry = C0` and then watched `C` advance across a segment worth LESS THAN ONE TOKEN-WEI at
/// its own weight pays that floor: its `dT` comes back one wei short of `left`, `dT >= left` is
/// false, `drained` stays false — and the walk falls out of the loop on `s.head == s.n` with
/// `left != 0`, a tick still holding capacity, and `mark = w.resume` BELOW it.
///
/// The tick is then unlinked by `_splice` while funded, staked and full of capacity, and
/// `highestTick` is shaved under it. Nobody's sweep can reach it again.
contract Review14SpliceResumeMarkTest is Review9LinksBase {
    address internal constant A = address(0xA1); // dust top, cap 2 wei
    address internal constant B = address(0xA2); // dust rung, cap 1 wei
    address internal constant W = address(0xA3); // the whale, cap 1e24

    uint256 internal constant STEP_A = 93; // 1.93e18
    uint256 internal constant STEP_B = 89; // 1.89e18
    uint256 internal constant STEP_W = 82; // 1.82e18

    uint256 internal pA;
    uint256 internal pB;
    uint256 internal pW;

    function setUp() public {
        _deploy(0, 40e18); // roundBlocks = 100 -> 40e18 per 100 blocks
        _registerGrid(120);
        pA = FLOOR + STEP_A * SPACING;
        pB = FLOOR + STEP_B * SPACING;
        pW = FLOOR + STEP_W * SPACING;
    }

    function _fund(address who, uint256 stakeAmt, uint256 currencyAmt) internal {
        mono.transfer(who, stakeAmt);
        cur.mint(who, currencyAmt);
        vm.startPrank(who);
        mono.approve(address(auction), stakeAmt);
        auction.stake(stakeAmt);
        cur.approve(address(auction), currencyAmt);
        vm.stopPrank();
    }

    function _bid(address who, uint256 price, uint128 amount, uint256 hint) internal {
        vm.prank(who);
        auction.submitBid(price, amount, who, hint);
    }

    /// Build the book: two dust ticks inside one 8-step band, a whale 7 steps under the second
    /// one (so it is reached only by `_extend`, after the band moves).
    function _book() internal {
        _fund(A, 10e18, 1_000e18);
        _fund(B, 10e18, 1_000e18);
        _fund(W, 10e18, 4e24);

        // cap = floor(amount * 1e18 / price)
        _bid(W, pW, 1.82e24, FLOOR); // cap = 1e24
        _bid(B, pB, 2, pW); //           cap = floor(2e18/1.89e18)  = 1
        _bid(A, pA, 4, pB); //           cap = floor(4e18/1.93e18)  = 2

        (,, uint256 capA,,,,) = auction.ticks(pA);
        (,, uint256 capB,,,,) = auction.ticks(pB);
        (,, uint256 capW,,,,) = auction.ticks(pW);
        assertEq(capA, 2, "book: cap(A) != 2");
        assertEq(capB, 1, "book: cap(B) != 1");
        assertEq(capW, 1e24, "book: cap(W) != 1e24");
        emit log_named_uint("saleSupply", auction.saleSupply());
    }

    // ------------------------------------------------------------------ the finding

    /// BUG FORM. One `sync` over that book strands the whale: `capTokens` still ~1e24, both link
    /// pointers zeroed, `highestTick` shaved to the floor.
    function test_splice_liveWhaleUnlinkedByResumeMark() public {
        _book();

        vm.roll(block.number + 100); // exactly one round -> due() == 40e18
        uint256 supply = auction.due();
        assertEq(supply, 40e18, "precondition: supply != 40e18");
        emit log_named_uint("supply", supply);

        auction.sync(1_000);

        (uint256 nxW, uint256 pvW, uint256 capW,,,,) = auction.ticks(pW);
        emit log_named_uint("after sync: cap(W)", capW);
        emit log_named_uint("after sync: W.next", nxW);
        emit log_named_uint("after sync: W.prev", pvW);
        emit log_named_uint("after sync: highestTick step", (auction.highestTick() - FLOOR) / SPACING);
        emit log_named_uint("after sync: tokensSold", auction.tokensSold());
        emit log_named_uint("after sync: settleCursor", auction.settleCursor());

        // measured: capW == 1e24 - (40e18 - 3), highestTick == FLOOR, W.prev == W.next == 0
        assertTrue(capW != 0, "sanity: the whale really did keep capacity");

        // THE CLAIM UNDER TEST: a tick the splice unlinked must be dead.
        assertTrue(!(pvW == 0 && nxW == 0) || capW == 0, "SPLICE: a tick with live capacity was unlinked by _splice");
        // and the wall must never be shaved under live capacity
        assertGe(auction.highestTick(), pW, "SPLICE: highestTick shaved below a tick with capacity");
    }

    /// The round-9 structural checker, driven on the same state, so the finding is expressed in
    /// the predicates that round already agreed on (L14 / L18 / L20).
    function test_splice_review9StructuralCheckerTrips() public {
        _book();
        vm.roll(block.number + 100);
        auction.sync(1_000);
        _checkList(); // expected: L14 "unlinked tick still carries capacity"
    }

    /// Same state, the round-9 POSITION-side predicate.
    function test_splice_review9PositionCheckerTrips() public {
        _book();
        vm.roll(block.number + 100);
        auction.sync(1_000);
        address[] memory owners = new address[](3);
        owners[0] = A;
        owners[1] = B;
        owners[2] = W;
        _checkPositionsReachable(owners); // expected: L20 "funded, staked bid off the sweep chain"
    }

    /// IMPACT, as a characterisation (this one PASSES): once stranded, the whale is invisible to
    /// every later sweep. Emission stops flowing entirely and the backlog piles up in `due()`.
    function test_splice_strandedWhaleStopsTheSale() public {
        _book();
        vm.roll(block.number + 100);
        auction.sync(1_000);

        uint256 soldAfterFirst = auction.tokensSold();
        emit log_named_uint("sold, round 1", soldAfterFirst);

        for (uint256 i; i < 5; ++i) {
            vm.roll(block.number + 100);
            auction.sync(1_000);
        }
        emit log_named_uint("sold, after 5 more rounds", auction.tokensSold());
        emit log_named_uint("due() carried", auction.due());
        emit log_named_uint("highestTick step", (auction.highestTick() - FLOOR) / SPACING);

        // FIXED: the whale keeps its place, so the sale keeps selling and nothing is carried.
        assertGt(auction.tokensSold(), soldAfterFirst, "the sale stalled after the first round");
        assertEq(auction.due(), 0, "a backlog was carried instead of poured");
        assertGt(auction.highestTick(), FLOOR, "the high-water was shaved under the live whale");

        // The whale still holds the escrow and the capacity, and `previewWindow` — the UI's
        // view of the book — cannot see it either.
        (,, uint256 capW,,,,) = auction.ticks(pW);
        (uint256 live,) = auction.positionOf(W);
        emit log_named_uint("whale escrow still live", live);
        emit log_named_uint("whale capacity still standing", capW);
        assertGt(live, 0, "whale escrow gone");
        assertGt(capW, 0, "whale capacity gone");
    }

    /// IMPACT 2 (characterisation, PASSES): a latecomer bidding one tick above the FLOOR — five
    /// steps of grid BELOW the stranded whale — becomes the top of book and takes the entire
    /// carried backlog that the whale's escrow was standing behind.
    function test_splice_latecomerBelowTheWhaleTakesTheBacklog() public {
        _book();
        vm.roll(block.number + 100);
        auction.sync(1_000);

        for (uint256 i; i < 5; ++i) {
            vm.roll(block.number + 100);
        }
        uint256 backlog = auction.due();
        emit log_named_uint("backlog before the latecomer", backlog);

        address late = address(0xBEEF);
        _fund(late, 10e18, 1_000e18);
        _bid(late, FLOOR + SPACING, 500e18, FLOOR); // 1.01e18: far under the whale's 1.82e18

        vm.roll(block.number + 1);
        auction.sync(1_000);

        (, uint256 owedLate) = auction.positionOf(late);
        (, uint256 owedWhale) = auction.positionOf(W);
        emit log_named_uint("latecomer tokensOwed", owedLate);
        emit log_named_uint("whale tokensOwed", owedWhale);
        emit log_named_uint("highestTick step now", (auction.highestTick() - FLOOR) / SPACING);

        // FIXED: the backlog is real (five rounds accrued with nobody syncing) but it belongs to
        // the book that stood behind it. The whale is still the top of book — highestTick is on
        // its tick, not the floor — so the deep latecomer five grid steps BELOW it gets only its
        // q^d share, not the lot.
        assertGt(backlog, 0, "the test did not build a backlog");
        assertEq(auction.highestTick(), FLOOR + 82 * SPACING, "the whale is no longer the top of book");
        assertLt(owedLate, owedWhale, "the latecomer outearned the top of book it undercut");
        // the whale is owed only what round 1 paid it before the strand; it earned nothing since
        assertGt(owedWhale, 200e18, "the whale was not served across the six rounds");
    }

    // ------------------------------------------------------------------ the A/B control

    /// CONTROL (PASSES): the SAME arithmetic, the same three caps, the same grid distances
    /// (d(A->B) = 4, d(B->W) = 7) — only the book is slid down so the whale sits ON the floor.
    /// `_extend` then walks off the bottom of the list, `w.resume` comes back 0, and the
    /// `w.resume == 0` arm of the ternary picks the conservative `mark = w.tau` — which IS the
    /// whale. It stays linked, keeps its capacity, stays the top of book, and the sale carries on.
    ///
    /// So the strand above is caused by the `mark = w.resume` arm alone, not by the model walk:
    /// the model stops in exactly the same state in both runs.
    function test_splice_control_resumeZeroKeepsTheWhaleLinked() public {
        uint256 cA = FLOOR + 11 * SPACING; // 1.11e18
        uint256 cB = FLOOR + 7 * SPACING; //  1.07e18
        uint256 cW = FLOOR; //                1.00e18, and the list's bottom node

        _fund(A, 10e18, 1_000e18);
        _fund(B, 10e18, 1_000e18);
        _fund(W, 10e18, 4e24);
        _bid(W, cW, 1e24, 0); //  cap = 1e24
        _bid(B, cB, 2, cW); //    cap = floor(2e18/1.07e18) = 1
        _bid(A, cA, 3, cB); //    cap = floor(3e18/1.11e18) = 2

        (,, uint256 capA0,,,,) = auction.ticks(cA);
        (,, uint256 capB0,,,,) = auction.ticks(cB);
        assertEq(capA0, 2, "control book: cap(A) != 2");
        assertEq(capB0, 1, "control book: cap(B) != 1");

        vm.roll(block.number + 100);
        auction.sync(1_000);

        (uint256 nxW, uint256 pvW, uint256 capW,,,,) = auction.ticks(cW);
        emit log_named_uint("control: cap(W)", capW);
        emit log_named_uint("control: W.next", nxW);
        emit log_named_uint("control: highestTick step", (auction.highestTick() - FLOOR) / SPACING);
        assertGt(capW, 0, "control: whale lost its capacity");
        assertEq(auction.highestTick(), cW, "control: high-water is not the whale");

        uint256 sold1 = auction.tokensSold();
        vm.roll(block.number + 100);
        auction.sync(1_000);
        emit log_named_uint("control: sold in round 2", auction.tokensSold() - sold1);
        assertGt(auction.tokensSold() - sold1, 39e18, "control: the sale stalled anyway");
    }

    /// RECOVERY (characterisation, PASSES): what it costs the victim. Only the whale's OWN touch
    /// heals it — `_claim` -> `_reseat` -> `_relink` (a hintless walk up from the floor) plus the
    /// `highestTick` bump. Everything the sale emitted while it was stranded is already gone to
    /// whoever bid in the meantime; the whale cannot recover that, and it can be re-stranded by
    /// the same two dust bids on the next sweep.
    function test_splice_onlyTheVictimsOwnTouchHeals() public {
        _book();
        vm.roll(block.number + 100);
        auction.sync(1_000);
        // FIXED: there is nothing to heal — the whale was never stranded, so the high-water
        // stays on it through a stranger's sync and through its own claim.
        assertEq(auction.highestTick(), pW, "the whale lost the high-water");

        // A third party syncing does nothing.
        vm.roll(block.number + 100);
        auction.sync(1_000);
        assertEq(auction.highestTick(), pW, "a stranger's sync moved the high-water");

        // The victim's own claim relinks and lifts the wall back.
        vm.prank(W);
        auction.claim(W);
        emit log_named_uint("after claim: highestTick step", (auction.highestTick() - FLOOR) / SPACING);
        (uint256 nxW, uint256 pvW, uint256 capW,,,,) = auction.ticks(pW);
        emit log_named_uint("after claim: W.prev", pvW);
        emit log_named_uint("after claim: W.next", nxW);
        emit log_named_uint("after claim: cap(W)", capW);
        assertEq(auction.highestTick(), pW, "claim moved the high-water");
        assertTrue(pvW != 0, "the whale is linked");

        // ...and the round that elapsed while it was stranded is still carried, not lost.
        emit log_named_uint("carry after healing", auction.due());
        assertEq(auction.due(), 0, "nothing should have been carried");
    }
}
