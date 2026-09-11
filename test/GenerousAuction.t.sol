// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Test} from "forge-std/Test.sol";
import {GenerousAuction} from "../src/GenerousAuction.sol";
import {Mono} from "../src/Mono.sol";
import {IMono} from "../src/interfaces/IMono.sol";
import {IGenerousAuction} from "../src/interfaces/IGenerousAuction.sol";
import {IIndex} from "../src/interfaces/IIndex.sol";
import {MockPool} from "./MockPool.sol";
import {TestERC20} from "./TestERC20.sol";

/// Checks for `src/GenerousAuction.sol`.
///
/// The anchor is the worked example in appendix A.9 of `generous-auction.md`: four ticks, `q = 0.5`,
/// a draw of 150 tokens, and the published answer 20 / 96 / 10 / 24. The prices below sit on this
/// contract's arithmetic grid rather than the paper's geometric ladder, which changes nothing that
/// matters — the allocation depends only on each tick's weight and its capacity in tokens, and both
/// are reproduced exactly.
contract GenerousAuctionTest is Test {
    GenerousAuction internal auction;
    Mono internal mono;
    TestERC20 internal cur;
    MockPool internal monoPool;

    address internal seller = address(0xF1);

    /// Opening book: NAV = 1.0 exactly, so `FLOOR` is the lowest non-dilutive price. Large enough
    /// that the claims in these tests move NAV by dust rather than by a visible amount.
    uint256 internal constant GENESIS = 1_000_000e18;

    uint256 internal constant FLOOR = 1e18;
    uint256 internal constant SPACING = 1e16;
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant HALF = Q96 / 2; // q = 0.5
    uint256 internal constant WINDOW = 8; // 0.5^8 = 0.4%, inside MAX_EDGE_WEIGHT
    uint64 internal constant K = 100; // blocks per emission round
    uint16 internal constant MIN_PREMIUM = 1_500; // 15%, the premium gate on the constructor

    // The A.9 book. One grid step apart, so distances below the top are 0/1/2/3 and the weights are
    // 1 / 0.5 / 0.25 / 0.125.
    uint256 internal constant P3 = FLOOR + 3 * SPACING; // top of book, paper's tick 3
    uint256 internal constant P2 = FLOOR + 2 * SPACING;
    uint256 internal constant P1 = FLOOR + 1 * SPACING;
    uint256 internal constant P0 = FLOOR;

    address internal b3 = address(0xB3);
    address internal b2 = address(0xB2);
    address internal b1 = address(0xB1);
    address internal b0 = address(0xB0);

    function setUp() public {
        cur = new TestERC20("Index", "INDEX");
        _deploy(_config(0));
    }

    /// The three-step bootstrap the mint path needs: `Mono` with this test as owner, first `mint`
    /// to set the opening NAV, then transfer ownership to the fresh auction. A second auction needs
    /// a second `Mono` — hence this runs per deployment.
    function _deploy(IGenerousAuction.Config memory c) internal {
        mono = new Mono(IIndex(address(cur)), 10 * GENESIS);
        cur.mint(address(this), GENESIS);
        cur.approve(address(mono), GENESIS);
        mono.mint(GENESIS, GENESIS, address(this));
        // NAV opens at 1.0; 1.25 in the pool is a 2500 bip premium, clear of the 1500 gate.
        monoPool = new MockPool(address(mono), address(cur), 1.25e18);
        mono.setPool(address(monoPool));

        c.token = address(mono);
        auction = new GenerousAuction(c);
        mono.grantRole(mono.MINTER_ROLE(), address(auction));
        mono.renounceRole(mono.MINTER_ROLE(), address(this));
    }

    // ---------------------------------------------------------------- sale succession

    /// The next sale closes the outgoing one out from its own constructor: no deployer step, no
    /// registry. The ordering that matters is the role — auction 1 must still hold `MINTER_ROLE`
    /// when auction 2 is deployed.
    function test_nextSaleConstructorPacksThePrevious() public {
        _a9Book();
        _settle();

        uint256 sold = auction.tokensSold();
        uint256 raised = auction.currencyRaised();
        assertEq(auction.tokensMinted(), 0, "auction 1 has sold but not packed");

        GenerousAuction first = auction;
        Mono firstMono = mono;

        // Deploying the successor packs the predecessor as a side effect of construction.
        IGenerousAuction.Config memory c = _config(0);
        c.previousAuction = address(first);
        _deploy(c);

        assertEq(first.tokensMinted(), sold, "auction 1 was packed by auction 2's constructor");
        assertEq(first.currencyMinted(), raised, "and its escrow reached the vault");
        assertEq(
            firstMono.balanceOf(address(first)),
            sold + first.totalStaked(),
            "the pack waits for auction 1's claimants, alongside the held-apart stake"
        );

        // Auction 1's bidders are still paid, out of a pack that is already bought and paid for.
        assertEq(first.claim(b3), 20e18, "a claim after the handoff is a plain transfer");
    }

    /// Revoking the outgoing sale's minter role before deploying the successor bricks the handoff —
    /// the constructor is what calls `mintPack`, and by then it is too late to grant it back.
    function test_revokingTheOldRoleTooEarlyBreaksSuccession() public {
        _a9Book();
        _settle();

        mono.revokeRole(mono.MINTER_ROLE(), address(auction));

        IGenerousAuction.Config memory c = _config(0);
        c.previousAuction = address(auction);
        c.token = address(mono);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(auction), mono.MINTER_ROLE()
            )
        );
        new GenerousAuction(c);
    }

    // ---------------------------------------------------------------- premium gate

    /// A sale only opens into a premium: the harvest sells the spread between NAV and the market,
    /// and at or below book there is no spread to sell.
    function test_saleWillNotOpenWithoutThePremium() public {
        Mono m = new Mono(IIndex(address(cur)), 10 * GENESIS);
        cur.mint(address(this), GENESIS);
        cur.approve(address(m), GENESIS);
        m.mint(GENESIS, GENESIS, address(this)); // NAV = 1.0

        IGenerousAuction.Config memory c = _config(0);
        c.token = address(m);

        // No pool at all: the gate cannot be read, so it cannot be skipped either.
        vm.expectRevert(IMono.PoolNotSet.selector);
        new GenerousAuction(c);

        MockPool p = new MockPool(address(m), address(cur), 1.1e18); // +1000 bips
        m.setPool(address(p));
        assertEq(m.premiumBips(), int256(1_000), "10% premium");
        vm.expectRevert(IGenerousAuction.PremiumTooLow.selector);
        new GenerousAuction(c);

        // Exactly at the bar passes — the check is `<`, not `<=`.
        p.setPrice(1.15e18);
        assertEq(m.premiumBips(), int256(uint256(MIN_PREMIUM)), "15% premium");
        GenerousAuction ok = new GenerousAuction(c);
        assertEq(ok.minPremiumBips(), MIN_PREMIUM, "the bar it cleared is readable on-chain");

        // A discount is a negative premium, not a zero one, so it fails the same comparison.
        p.setPrice(0.9e18);
        assertLt(m.premiumBips(), int256(0), "below book");
        vm.expectRevert(IGenerousAuction.PremiumTooLow.selector);
        new GenerousAuction(c);

        // The threshold is a knob, but zero does not disable the gate: it still requires the
        // market not to be under book.
        c.minPremiumBips = 0;
        vm.expectRevert(IGenerousAuction.PremiumTooLow.selector);
        new GenerousAuction(c);

        // And a premium of exactly zero clears that bar while sizing the sale at nothing — the
        // second gate catches what the first waves through.
        p.setPrice(1e18);
        assertEq(m.premiumCloseAmount(), 0, "no gap, no supply");
        vm.expectRevert(IGenerousAuction.NothingToSell.selector);
        new GenerousAuction(c);
    }

    /// The premium sizes the sale: the gap, restated as the MONO it would take to close it.
    function test_premiumSizesTheSale() public {
        // The book above is NAV 1.0 against a 1.25 pool, so the sale is the swap that walks the
        // pool back down to book. Sold out, `due()` is zero however long the schedule runs.
        uint256 supply = auction.saleSupply();
        assertEq(supply, mono.premiumCloseAmount(), "sized off the premium standing at deploy");
        assertGt(supply, 0);
        assertEq(auction.remaining(), supply, "nothing sold yet");

        // A wider gap is a bigger sale; a deeper pool needs more MONO to move the same distance.
        Mono m = new Mono(IIndex(address(cur)), 10 * GENESIS);
        cur.mint(address(this), GENESIS);
        cur.approve(address(m), GENESIS);
        m.mint(GENESIS, GENESIS, address(this));
        MockPool p = new MockPool(address(m), address(cur), 1.25e18);
        m.setPool(address(p));
        assertApproxEqRel(m.premiumCloseAmount(), supply, 1e12, "same gap, same size");

        p.setPrice(1.5e18);
        uint256 wider = m.premiumCloseAmount();
        assertGt(wider, supply, "a wider premium is a bigger sale");

        p.setLiquidity(2e24);
        assertApproxEqRel(m.premiumCloseAmount(), wider * 2, 1e12, "twice the depth, twice the MONO");

        // No liquidity in the active tick: the gap exists but nothing can be sold into it.
        p.setLiquidity(0);
        assertEq(m.premiumCloseAmount(), 0);
    }

    /// The cap binds even when the schedule would keep emitting forever.
    function test_scheduleStopsAtTheSaleSupply() public {
        uint256 supply = auction.saleSupply();
        // Far past any round boundary: the schedule alone would owe astronomically more.
        vm.roll(block.number + K * 1_000_000);
        assertEq(auction.emittedToDate(), supply, "the sale's own supply is the ceiling");
        assertEq(auction.due(), supply, "and only that is ever distributable");
        // The uncapped schedule is what the cap is holding back.
        assertGt(uint256(auction.emissionPerRound()) * 1_000_000, supply, "the schedule would owe more");
    }

    /// One round releases the paper's 150-token draw, so a single elapsed round reproduces A.9.
    /// @dev `token` is filled in by `_deploy`, which is what creates the `Mono` it points at.
    function _config(uint64 end) internal view returns (IGenerousAuction.Config memory) {
        return IGenerousAuction.Config({
            token: address(0),
            currency: address(cur),
            admin: seller,
            floorPrice: FLOOR,
            tickSpacing: SPACING,
            decayQ: HALF,
            windowTicks: WINDOW,
            startBlock: uint64(block.number),
            endBlock: end,
            roundBlocks: K,
            emissionPerRound: 150e18,
            minPremiumBips: MIN_PREMIUM,
            previousAuction: address(0)
        });
    }

    // ------------------------------------------------------------------ helpers

    /// Give `who` sale-token stake and stake it — the strict rule: no stake, no fill.
    /// 1e18 flat: within-tick weights only matter between positions sharing a tick, and every
    /// book in this file has one position per tick.
    function _stakeFor(address who, uint256 amt) internal {
        mono.transfer(who, amt);
        vm.startPrank(who);
        mono.approve(address(auction), amt);
        auction.stake(amt);
        vm.stopPrank();
    }

    /// Bid enough currency at `price` to buy exactly `capTokens` there.
    function _bidForCapacity(address who, uint256 price, uint256 capTokens) internal {
        _stakeFor(who, 1e18);
        uint128 amount = uint128((capTokens * price) / 1e18);
        cur.mint(who, amount);
        vm.startPrank(who);
        cur.approve(address(auction), amount);
        auction.submitBid(price, amount, who, FLOOR);
        vm.stopPrank();
    }

    function _a9Book() internal {
        _bidForCapacity(b3, P3, 20e18);
        _bidForCapacity(b2, P2, 200e18);
        _bidForCapacity(b1, P1, 10e18);
        _bidForCapacity(b0, P0, 100e18);
    }

    /// Let one emission round elapse and distribute it.
    function _settle() internal {
        vm.roll(block.number + K);
        auction.sync(64);
    }

    function _owed(address who) internal view returns (uint256 owed) {
        (, owed) = auction.positionOf(who);
    }

    // ------------------------------------------------------------------ the anchor

    /// The published A.9 answer, read straight off the preview: 20 / 96 / 10 / 24, summing to the
    /// full 150-token draw.
    /// @dev The preview is over `due()`, not the balance, so it reports what a `sync` in *this*
    ///      block would pay — which is nothing until a round has elapsed.
    function test_A9_preview() public {
        _a9Book();

        (,,, uint256[] memory beforeRound) = auction.previewWindow();
        assertEq(beforeRound[0], 0, "nothing emitted yet, so nothing to preview");

        vm.roll(block.number + K);
        (uint256 tau,, uint256[] memory price, uint256[] memory tokens) = auction.previewWindow();
        assertEq(tau, P3, "top of book");
        assertEq(price.length, 4, "four live ticks");

        // `_gather` walks the list downward, so index 0 is the top.
        assertEq(price[0], P3);
        assertEq(price[1], P2);
        assertEq(price[2], P1);
        assertEq(price[3], P0);

        assertEq(tokens[0], 20e18, "tick 3 (dies first, capped)");
        assertEq(tokens[1], 96e18, "tick 2 (survivor, 0.5 * C)");
        assertEq(tokens[2], 10e18, "tick 1 (dies second, capped)");
        assertEq(tokens[3], 24e18, "tick 0 (survivor, 0.125 * C)");
        assertEq(tokens[0] + tokens[1] + tokens[2] + tokens[3], 150e18, "whole draw allocated");

        // Survivors sit on the same envelope: a_2 / a_0 = q^(-2) = 4.
        assertEq(tokens[1], tokens[3] * 4, "survivors on the q-envelope");

        // The lens is the execution: syncing in this same block pays what was previewed. The only
        // gap is the per-position wei `positionOf` rounds the bidder's way, which `claim` clamps.
        auction.sync(64);
        assertEq(_owed(b3), tokens[0], "preview == payout, tick 3");
        assertApproxEqAbs(_owed(b2), tokens[1], 1, "preview == payout, tick 2");
        assertEq(_owed(b1), tokens[2], "preview == payout, tick 1");
        assertApproxEqAbs(_owed(b0), tokens[3], 1, "preview == payout, tick 0");
    }

    /// Settlement pays exactly what the preview promised, and the two dead ticks spend their whole
    /// budget while the survivors keep the unspent remainder.
    function test_A9_settlement() public {
        _a9Book();
        _settle();

        assertEq(_owed(b3), 20e18, "tick 3 tokens");
        assertApproxEqAbs(_owed(b2), 96e18, 1, "tick 2 tokens");
        assertEq(_owed(b1), 10e18, "tick 1 tokens");
        assertApproxEqAbs(_owed(b0), 24e18, 1, "tick 0 tokens");

        // Exhausted ticks have nothing left competing; survivors keep budget minus what they spent.
        (uint256 live3,) = auction.positionOf(b3);
        (uint256 live1,) = auction.positionOf(b1);
        assertEq(live3, 0, "tick 3 exhausted");
        assertEq(live1, 0, "tick 1 exhausted");

        (uint256 live2,) = auction.positionOf(b2);
        assertApproxEqAbs(live2, 204e18 - 96e18 * P2 / 1e18, 1, "tick 2 leftover escrow");

        // 20*1.03 + 96*1.02 + 10*1.01 + 24*1.00 = 152.62
        assertApproxEqAbs(auction.currencyRaised(), 15262e16, 4, "raised, pay-as-bid");
        assertEq(auction.settleCursor(), 0, "swept in one call");
    }

    function test_claim_paysOwner() public {
        _a9Book();
        _settle();

        uint256 owed = _owed(b2);
        uint256 got = auction.claim(b2); // permissionless; pays the owner
        assertEq(got, owed, "claim pays what the view promised");
        assertEq(mono.balanceOf(b2), owed, "tokens delivered to owner");
        assertEq(_owed(b2), 0, "nothing owed twice");
    }

    // ------------------------------------------------------------------ rounds

    /// Escrow that does not fill is not migrated, re-keyed, or rewritten — it is simply still there
    /// next round, and the accrual from both rounds resolves in one read.
    function test_unfilledEscrowCompetesNextRound() public {
        _bidForCapacity(b3, P3, 20e18); // wants 20, top of book
        _bidForCapacity(b0, P0, 1000e18); // wants 1000, three steps down — more than a round emits
        _settle();

        (uint256 liveAfter1, uint256 owedAfter1) = auction.positionOf(b0);
        assertGt(liveAfter1, 0, "low tick only partly filled");
        assertGt(owedAfter1, 0, "but it did get a share, unlike a high->low fill");

        // Round two: nobody bids again, the standing escrow just keeps competing.
        _settle();

        (uint256 liveAfter2, uint256 owedAfter2) = auction.positionOf(b0);
        assertLt(liveAfter2, liveAfter1, "escrow kept being consumed");
        assertGt(owedAfter2, owedAfter1, "accrual accumulates across rounds");

        // One division covers both rounds — the claim never walks history.
        assertEq(auction.claim(b0), owedAfter2, "single O(1) claim across rounds");
    }

    function test_withdrawReturnsLiveEscrow() public {
        _bidForCapacity(b3, P3, 20e18);
        _bidForCapacity(b0, P0, 1000e18);
        _settle();

        (uint256 live,) = auction.positionOf(b0);
        vm.prank(b0);
        uint256 out = auction.withdrawBid();
        assertEq(out, live, "withdraw returns exactly the live escrow");
        assertEq(cur.balanceOf(b0), out, "currency returned");
        assertGt(_owed(b0), 0, "tokens already won stay claimable");
    }

    // ------------------------------------------------------------------ accounting

    /// A win that has not been claimed yet is MONO that does not exist: nothing was pre-funded, so
    /// there is no balance for a later round or a sweep to reach into.
    function test_unclaimedTokensAreNotMintedYet() public {
        _a9Book();
        _settle();

        assertEq(auction.tokensUnclaimed(), 150e18, "the whole draw is owed");
        assertEq(mono.totalSupply(), GENESIS, "and none of it has been minted");
    }

    /// The conveyor: the FIRST claim packs the whole sale — minting every sold token at once and
    /// paying the entire escrow into the vault — and then hands this claimant their share out of it.
    /// Nothing is left for a `sweepCurrency` to collect, because there isn't one.
    function test_firstClaimPacksTheWholeSale() public {
        _a9Book();
        _settle();

        assertEq(auction.tokensMinted(), 0, "a sync sells but does not mint");
        assertEq(mono.totalSupply(), GENESIS, "nothing packed until someone claims");

        uint256 assetsBefore = mono.totalIndex();
        uint256 supplyBefore = mono.totalSupply();
        uint256 raised = auction.currencyRaised();
        uint256 sold = auction.tokensSold();

        uint256 owed = _owed(b2);
        uint256 got = auction.claim(b2);

        // The pack is the whole 150-token draw, not just this claimant's 96.
        assertEq(got, owed, "the claimant still gets exactly what the book owes");
        assertEq(auction.tokensMinted(), sold, "every sold token was minted");
        assertEq(mono.totalSupply() - supplyBefore, sold, "supply grew by the whole sale");
        assertEq(mono.totalIndex() - assetsBefore, raised, "and the whole escrow reached the vault");
        assertEq(auction.currencyMinted(), raised, "the ledger says so too");
        assertEq(
            mono.balanceOf(address(auction)),
            sold - got + auction.totalStaked(),
            "the rest waits here for its claimants; stake is held apart"
        );

        // Every later claim is a pure transfer: no mint, no currency movement.
        uint256 supplyAfterPack = mono.totalSupply();
        uint256 assetsAfterPack = mono.totalIndex();
        uint256 got3 = auction.claim(b3);
        assertEq(got3, 20e18, "tick 3 paid in full");
        assertEq(mono.totalSupply(), supplyAfterPack, "no second mint");
        assertEq(mono.totalIndex(), assetsAfterPack, "no second strike");
    }

    /// `mintPack` is idempotent and permissionless, which is what lets the next sale's constructor
    /// close this one out without the deployer doing anything.
    function test_mintPackIsIdempotent() public {
        _a9Book();
        _settle();

        uint256 minted = auction.mintPack();
        assertEq(minted, auction.tokensSold(), "packed the sale");
        assertEq(auction.mintPack(), 0, "a second call mints nothing");

        uint256 supply = mono.totalSupply();
        assertEq(auction.mintPack(), 0);
        assertEq(mono.totalSupply(), supply, "and moves no supply");
    }

    /// The invariant the whole thesis rests on, across the full book: every claim mints at or above
    /// backing, so NAV is monotonically non-decreasing.
    function test_navNeverFallsAcrossClaims() public {
        _a9Book();
        _settle();

        uint256 nav = mono.nav();
        assertEq(nav, 1e18, "opens at par");

        auction.claim(b3);
        assertGe(mono.nav(), nav, "1.03 strike");
        nav = mono.nav();
        auction.claim(b2);
        assertGe(mono.nav(), nav, "1.02 strike");
        nav = mono.nav();
        auction.claim(b1);
        assertGe(mono.nav(), nav, "1.01 strike");
        nav = mono.nav();
        auction.claim(b0);
        assertGe(mono.nav(), nav, "1.00 strike, exactly at NAV");
        assertGt(mono.nav(), 1e18, "the premium ratcheted the floor");
    }

    /// A bid under backing would be a dilutive mint, so the book refuses it. The live floor is
    /// `nav()`, not the immutable `floorPrice` — NAV only rises, so the two diverge.
    function test_bidBelowNavReverts() public {
        // A tax sweep: INDEX arriving with no mint lifts NAV straight past the floor.
        cur.mint(address(mono), GENESIS / 10); // NAV -> 1.1
        assertEq(mono.nav(), 11e17);

        cur.mint(b0, 100e18);
        vm.startPrank(b0);
        cur.approve(address(auction), 100e18);
        vm.expectRevert(IGenerousAuction.BelowNav.selector);
        auction.submitBid(P0, 100e18, b0, FLOOR); // 1.00, under the new floor
        vm.stopPrank();

        // Two grid steps above NAV is fine.
        uint256 ok = 11e17 + 2 * SPACING;
        _stakeFor(b1, 1e18);
        cur.mint(b1, 100e18);
        vm.startPrank(b1);
        cur.approve(address(auction), 100e18);
        auction.submitBid(ok, 100e18, b1, FLOOR);
        vm.stopPrank();
        (uint256 live,) = auction.positionOf(b1);
        assertEq(live, 100e18, "bid above NAV stands");
    }

    /// NAV can outrun a bid that already filled. The claim must not brick: it mints what the escrow
    /// buys at the current NAV instead, which is MONO backed by exactly the INDEX that was paid.
    function test_claimClampsRatherThanRevertingWhenNavRose() public {
        _a9Book();
        _settle();

        uint256 owed = _owed(b0); // filled at 1.00
        assertGt(owed, 0);

        // A big tax sweep between the fill and the claim: NAV doubles.
        cur.mint(address(mono), GENESIS);
        assertEq(mono.nav(), 2e18);

        uint256 assetsBefore = mono.totalIndex();
        uint256 raised = auction.currencyRaised();
        uint256 sold = auction.tokensSold();
        uint256 owed2 = _owed(b2);
        uint256 got = auction.claim(b0);

        assertGt(got, 0, "claim is not stranded");
        assertLt(got, owed, "but it is clamped: the escrow no longer buys a whole MONO each");
        // The whole escrow still reached the vault; it simply bought less than the book promised.
        assertEq(mono.totalIndex() - assetsBefore, raised, "the whole escrow still went to the vault");
        assertGe(mono.nav(), 2e18, "and NAV did not fall");
        assertEq(_owed(b0), 0, "the position is settled, not left dangling");

        // The haircut is POOLED and order-independent: every claimant is scaled by the same
        // remaining-pot ratio, whatever price they filled at and whenever they claim.
        assertLt(auction.tokensMinted(), sold, "the pack was clamped");
        uint256 gotB2 = auction.claim(b2);
        assertApproxEqRel(gotB2 * 1e18 / owed2, got * 1e18 / owed, 1e9, "identical haircut ratio for a later claimant");
    }

    /// After the handoff the auction is the only minter; the deployer cannot mint again.
    function test_ownershipHandedToAuction() public {
        assertTrue(mono.hasRole(mono.MINTER_ROLE(), address(auction)), "the auction holds the role");
        assertFalse(mono.hasRole(mono.MINTER_ROLE(), address(this)), "and it is the only holder");

        bytes32 minter = mono.MINTER_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), minter)
        );
        mono.mint(1e18, 1e18, address(this));
    }

    // ------------------------------------------------------------------ emission schedule

    /// Emission is a schedule, not a transaction — and BLOCK-LINEAR: `R/K` per block, nothing
    /// before `startBlock`, no boundary ever materialising a chunk atomically (the atomic chunk
    /// made the first post-boundary sync a gameable weight snapshot; round-4 review).
    function test_emissionAccruesPerRound() public {
        assertEq(auction.emittedToDate(), 0, "nothing at the start block");

        vm.roll(block.number + K - 1);
        assertEq(auction.emittedToDate(), 1485e17, "K-1 blocks accrue their exact pro-rata");

        vm.roll(block.number + 1);
        assertEq(auction.emittedToDate(), 150e18, "one full round at the boundary");
        assertEq(auction.roundsElapsed(), 1);

        vm.roll(block.number + 3 * K + K / 2);
        assertEq(auction.emittedToDate(), 675e18, "4.5 rounds, linearly");
        assertEq(auction.roundsElapsed(), 4, "roundsElapsed still floors: it counts boundaries");
    }

    /// A thousand silent rounds cost one sweep, and land where a thousand sweeps would: `_pour` is
    /// parameterised by the scalar `C` and relative weights do not depend on the anchor.
    function test_lazySyncEqualsRoundByRound() public {
        _a9Book();
        vm.roll(block.number + 3 * K); // three silent rounds, ONE sweep
        auction.sync(64);
        (uint256 lazyLive, uint256 lazyOwed) = auction.positionOf(b2);
        uint256 lazyRaised = auction.currencyRaised();

        // Same book, same emission, but settled round by round instead of in one sweep.
        setUp();
        _a9Book();
        vm.roll(block.number + K);
        auction.sync(64);
        vm.roll(block.number + K);
        auction.sync(64);
        vm.roll(block.number + K);
        auction.sync(64);
        (uint256 stepLive, uint256 stepOwed) = auction.positionOf(b2);

        assertEq(stepLive, lazyLive, "escrow left, bit for bit");
        assertEq(stepOwed, lazyOwed, "tokens won, bit for bit");
        assertEq(auction.currencyRaised(), lazyRaised, "raised, bit for bit");
    }

    /// Carry: a round the book cannot absorb is owed, not burned.
    function test_unabsorbedEmissionCarries() public {
        // Two rounds elapse over an empty book. Nothing is sold, but the debt stands.
        vm.roll(block.number + 2 * K);
        auction.sync(64);
        assertEq(auction.tokensSold(), 0, "empty book absorbs nothing");
        assertEq(auction.emittedToDate(), 300e18, "but the schedule ran anyway");
        assertEq(auction.due(), 300e18, "carried, not burned");

        // The book shows up and takes the backlog plus its own round.
        _a9Book();
        vm.roll(block.number + K);
        auction.sync(64);
        assertEq(auction.tokensSold(), 330e18, "whole demand met from 450 emitted");
        assertEq(auction.due(), 120e18, "the rest is still carried");
    }

    /// A rescheduled rate takes effect at the next boundary and never rewrites the past — even if
    /// nobody synced the rounds that elapsed under the old rate.
    function test_setRoundParamsIsNotRetroactive() public {
        vm.roll(block.number + 2 * K + 10); // two rounds at 150, ten blocks into the third

        vm.prank(seller);
        auction.setRoundParams(K, 10e18);
        assertEq(auction.emittedToDate(), 315e18, "elapsed blocks keep the old rate, linearly");

        // The round in flight still finishes at 150.
        vm.roll(block.number + K - 10);
        assertEq(auction.emittedToDate(), 450e18, "round three at the rate it started under");

        vm.roll(block.number + K);
        assertEq(auction.emittedToDate(), 460e18, "round four at the new rate");
    }

    /// A second reschedule before the boundary replaces the first.
    function test_pendingParamsAreReplaced() public {
        vm.prank(seller);
        auction.setRoundParams(K, 10e18);
        vm.prank(seller);
        auction.setRoundParams(K, 20e18);

        vm.roll(block.number + 2 * K);
        assertEq(auction.emittedToDate(), 150e18 + 20e18, "first round old rate, second the last queued");
    }

    function test_setRoundParamsIsAdminOnly() public {
        vm.expectRevert(IGenerousAuction.Unauthorized.selector);
        auction.setRoundParams(K, 1e18);
    }

    function test_biddingClosesAtEndBlock() public {
        uint64 end = uint64(block.number) + 2 * K;
        _deploy(_config(end));

        vm.roll(end);
        cur.mint(b3, 1e18);
        vm.startPrank(b3);
        cur.approve(address(auction), 1e18);
        vm.expectRevert(IGenerousAuction.AuctionEnded.selector);
        auction.submitBid(P3, 1e18, b3, FLOOR);
        vm.stopPrank();

        // The schedule froze at `endBlock`; later blocks add nothing.
        vm.roll(end + 10 * K);
        assertEq(auction.emittedToDate(), 300e18, "two rounds, then frozen");
    }

    /// Deployment pattern: ship with `emissionPerRound = 0` so nothing accrues while the sale is
    /// unfunded, then "start" it with `setRoundParams`. No carry can build up in the gap.
    function test_zeroEmissionThenStart() public {
        IGenerousAuction.Config memory c = _config(0);
        c.emissionPerRound = 0;
        _deploy(c);

        _a9Book();

        // Ten rounds pass with the sale unfunded and the rate at zero.
        vm.roll(block.number + 10 * K);
        assertEq(auction.emittedToDate(), 0, "zero rate emits nothing");
        assertEq(auction.due(), 0, "so no carry accumulates");

        vm.prank(seller);
        auction.setRoundParams(K, 150e18);
        assertEq(auction.emittedToDate(), 0, "not retroactive: the ten idle rounds stay at zero");

        // First full round under the new rate pays exactly one round, not a backlog.
        vm.roll(block.number + 2 * K);
        assertEq(auction.emittedToDate(), 150e18, "one round at the new rate");
        assertEq(auction.due(), 150e18, "and that is all that is owed");

        auction.sync(64);
        assertEq(_owed(b3), 20e18, "A.9 allocation, unchanged by the deferred start");
    }
}
