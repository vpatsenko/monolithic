// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GenerousAuction} from "../../src/GenerousAuction.sol";
import {Mono} from "../../src/Mono.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";
import {IIndex} from "../../src/interfaces/IIndex.sol";
import {MockPool} from "../MockPool.sol";
import {TestERC20} from "../TestERC20.sol";

/// Review 6 / integration lens: the tick list an indexer rebuilds from `BidSubmitted` events
/// is NOT the on-chain list once `_splice` has run (no event), and `_initializeTick` ACCEPTS
/// a spliced-out dead tick as `prevTick` instead of reverting `BadPrevHint`. A later, correct
/// re-insert of that dead tick then rewires the list around the new bid and orphans it from
/// the downward walk `_gather` uses — its escrow never fills.
contract Review6IntegrationSplicedHintOrphan is Test {
    GenerousAuction internal auction;
    Mono internal mono;
    TestERC20 internal cur;

    uint256 internal constant GENESIS = 1_000_000e18;
    uint256 internal constant FLOOR = 1e18;
    uint256 internal constant SPACING = 1e16;
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant HALF = Q96 / 2;
    uint64 internal constant K = 100;

    uint256 internal constant F = FLOOR; // 1.00, aa, live throughout
    uint256 internal constant A = FLOOR + 1 * SPACING; // 1.01, bb: bid, withdraw (dead), re-bid
    uint256 internal constant C = FLOOR + 2 * SPACING; // 1.02, dd: the victim, bids with hint A
    uint256 internal constant B = FLOOR + 3 * SPACING; // 1.03, cc: bid, withdraw (dead), re-bid

    address internal aa = address(0xA1);
    address internal bb = address(0xA2);
    address internal cc = address(0xA3);
    address internal dd = address(0xA4);

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
                decayQ: HALF,
                windowTicks: 8,
                startBlock: uint64(block.number),
                endBlock: 0,
                roundBlocks: K,
                emissionPerRound: 50e18,
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

    function _prev(uint256 p) internal view returns (uint256 prev) {
        (, prev,,,,,) = auction.ticks(p);
    }

    function _next(uint256 p) internal view returns (uint256 next) {
        (next,,,,,,) = auction.ticks(p);
    }

    function _cap(uint256 p) internal view returns (uint256 cap) {
        (,, cap,,,,) = auction.ticks(p);
    }

    /// Book F < A < B, then A and B go dead (withdrawn) and one sync splices A out of the list.
    /// Nothing about that splice is emitted, so an event-driven indexer still believes F < A < B.
    function _buildAndSplice() internal {
        _stakeFor(aa, 1e18);
        _stakeFor(bb, 1e18);
        _stakeFor(cc, 1e18);
        _stakeFor(dd, 1e18);
        _bid(aa, F, 200e18, F); // 200 tokens of capacity at 1.00
        _bid(bb, A, 10e18, F);
        _bid(cc, B, 10e18, A);

        vm.prank(bb);
        auction.withdrawBid();
        vm.prank(cc);
        auction.withdrawBid();
        assertEq(_cap(A), 0, "A is dead");
        assertEq(_cap(B), 0, "B is dead");
        assertEq(auction.highestTick(), B, "high-water still on the dead ridge");

        // Event-derived list before the sync: B.prev = A, A.prev = F.
        assertEq(_prev(B), A);
        assertEq(_prev(A), F);

        vm.roll(block.number + K);
        auction.sync(64); // walks B, A (dead) -> F; splices A out: B.prev = F, F.next = B

        assertEq(_next(F), 0, "on-chain: the dead run A, B is gone (no event)");
        assertEq(_next(A), 0, "A was unlinked by the splice, not left stale");
        assertEq(_prev(A), 0);
        assertEq(_prev(B), 0, "B, the dead top, too");
        assertEq(auction.highestTick(), F, "high-water shaved to F (no event)");
    }

    /// The hint an event-replaying indexer hands out for a bid at C (A < C < B) is A — the
    /// last BidSubmitted price below C. On chain A is unlinked: the hint is ignored and the
    /// contract walks to the real predecessor, F.
    function test_splicedTickAcceptedAsPrevHint() public {
        _buildAndSplice();

        cur.mint(dd, 10e18);
        vm.startPrank(dd);
        cur.approve(address(auction), 10e18);
        auction.submitBid(C, 10e18, dd, A);
        vm.stopPrank();
        assertEq(_prev(C), F, "linked above the live floor, not under the dead A");
        assertEq(_next(F), C);
    }

    /// With the exact live-list hint (F) the bid at C is linked between F and B; a later correct
    /// re-insert of A (hint F) goes between F and C, and every one of the four ticks is served.
    function test_orphanedTickNeverFills() public {
        _buildAndSplice();

        // dd bids at C with the live-list hint F.
        _bid(dd, C, 10e18, F);
        assertEq(_prev(C), F, "C linked above F");
        assertEq(_next(C), 0);
        assertEq(_next(F), C);

        // bb comes back to A. The exact linked predecessor of A on chain is F (F.next = B > A).
        _bid(bb, A, 10e18, F);
        assertEq(_prev(A), F);
        assertEq(_next(F), A);
        assertEq(_next(A), C, "A sits between F and C");
        assertEq(_prev(C), A);

        // cc comes back to B (already linked, hint ignored) — top of book is B again.
        _bid(cc, B, 10e18, C); // B re-inserts above C
        assertEq(auction.highestTick(), B);

        vm.roll(block.number + K);
        auction.sync(64);

        // B (d=0), A (d=2), F (d=3) got the round. C had 10e18 of currency = about 9.8 tokens of
        // live, staked capacity and a weight of 0.5 — it should have been the second-largest
        // recipient in the window.
        assertGt(_owed(cc), 0, "B filled");
        assertGt(_owed(bb), 0, "A filled");
        assertGt(_owed(aa), 0, "F filled");
        assertEq(_cap(C), 0, "C was filled in full (its ~9.8 tokens fit in the round)");
        assertGt(_owed(dd), 0, "C was served by the sync");
    }
}
