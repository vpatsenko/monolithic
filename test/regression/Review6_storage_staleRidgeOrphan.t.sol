// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GenerousAuction} from "../../src/GenerousAuction.sol";
import {Mono} from "../../src/Mono.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";
import {IIndex} from "../../src/interfaces/IIndex.sol";
import {MockPool} from "../MockPool.sol";
import {TestERC20} from "../TestERC20.sol";

/// Review 6 / storage lens. `_splice` (GenerousAuction.sol:725-730) cuts a walked dead run out
/// of the list but leaves every interior node's `prev`/`next` intact. `_initializeTick`
/// (GenerousAuction.sol:1228-1234) decides "still linked" by `ticks[ticks[price].prev].next ==
/// price` — which is TRUE for every interior node of a spliced run except the lowest one, because
/// the neighbour it points at is another spliced node whose `next` still points back. So a bid
/// at any such price returns early, is never re-linked into the live list, and the sweep never
/// visits it (or, when it becomes `highestTick`, the sweep follows its stale chain and skips the
/// live list). Both tests below FAIL on current code.
contract Review6StorageStaleRidgeOrphanTest is Test {
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant FLOOR = 1e18;
    uint256 internal constant SPACING = 1e16;
    uint64 internal constant K = 100;
    uint256 internal constant GENESIS = 1_000_000e18;

    GenerousAuction internal auction;
    Mono internal mono;
    TestERC20 internal cur;

    address internal att = address(0xA77);
    address internal hh = address(0xB1); // honest floor bidder
    address internal hh2 = address(0xB2); // honest bidder who lands on a spliced price
    address internal hh3 = address(0xB3);

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
                emissionPerRound: 100e18,
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

    function _prev(uint256 price) internal view returns (uint256 p) {
        (, p,,,,,) = auction.ticks(price);
    }

    /// Dead ridge at grid steps `idx[]` (ascending), each tick bid-and-withdrawn by `att`.
    function _ridge(uint256[] memory idx) internal {
        _stake(att, 1e18);
        uint256 prev = FLOOR;
        for (uint256 i; i < idx.length; ++i) {
            _bid(att, P(idx[i]), 2e18, prev);
            vm.prank(att);
            auction.withdrawBid();
            prev = P(idx[i]);
        }
    }

    /// An honest bidder re-uses a price that an earlier (now spliced) ridge once occupied, with
    /// the CORRECT predecessor hint read off the live list. The bid is accepted, never linked,
    /// and never poured.
    function test_orphan_bidAtSplicedInteriorPriceIsNeverPoured() public {
        uint256[] memory idx = new uint256[](20);
        for (uint256 i; i < 20; ++i) {
            idx[i] = i + 1; // P1..P20
        }
        _ridge(idx);
        _stake(hh, 1e18);
        _bid(hh, FLOOR, 1000e18, FLOOR);

        vm.roll(block.number + K);
        auction.sync(type(uint256).max); // walks P20..P1, splices: F <-> P20
        assertEq(auction.settleCursor(), 0);
        assertEq(_next(FLOOR), 0, "the whole dead ridge, its top included, is gone from the list");

        // hh2 walks the live list (F.next == P20 > P10) and bids at P10 with prev = F.
        _stake(hh2, 1e18);
        _bid(hh2, P(10), 200e18, FLOOR);
        (,,,,,, bool init) = auction.ticks(P(10));
        assertTrue(init);
        assertEq(auction.highestTick(), P(10), "P10 became the high-water");

        // A later honest bid above the old ridge top makes P10 invisible for good.
        _stake(hh3, 1e18);
        _bid(hh3, P(25), 10e18, P(10)); // cap = 8 tokens, dries in one pour

        vm.roll(block.number + K);
        auction.sync(type(uint256).max);
        assertEq(auction.settleCursor(), 0, "sweep completed");

        // Live list from the floor: F -> P20 -> P25 -> 0. P10 is not in it.
        emit log_named_uint("F.next", _next(FLOOR));
        emit log_named_uint("P20.next", _next(P(20)));
        emit log_named_uint("P25.next", _next(P(25)));
        emit log_named_uint("owed hh3 (P25)", _owed(hh3));
        emit log_named_uint("owed hh  (F)", _owed(hh));
        emit log_named_uint("owed hh2 (P10)", _owed(hh2));

        // Correct behaviour: after P25 dries (8 tokens), the remaining ~92 tokens belong to the
        // next window whose top is P10 (F is 10 steps below P10, outside the 8-step window).
        assertEq(_next(FLOOR), P(10), "P10 re-linked into the live list");
        assertGt(_owed(hh2), 0, "the re-bid at P10 is poured");
    }

    /// The mirror image: a bid at a stale interior node ABOVE the live top becomes `highestTick`,
    /// and the sweep then follows the stale chain instead of the live list — an honest tick that
    /// was inserted after the splice, one grid step below, is skipped entirely.
    function test_orphan_staleTopHidesHonestLiveTick() public {
        // Sparse ridge on even steps 2..40 so odd prices are NOT on the stale chain.
        uint256[] memory idx = new uint256[](20);
        for (uint256 i; i < 20; ++i) {
            idx[i] = 2 * (i + 1);
        }
        _ridge(idx);
        _stake(hh, 1e18);
        _bid(hh, FLOOR, 1000e18, FLOOR);

        vm.roll(block.number + K);
        auction.sync(type(uint256).max); // splices: F <-> P40
        assertEq(_next(FLOOR), 0, "dead ridge gone, its top included");

        // Honest hh3 bids at P29 (odd: never a ridge node), hint F (F.next == P40 > P29).
        _stake(hh3, 1e18);
        _bid(hh3, P(29), 200e18, FLOOR);
        assertEq(_next(FLOOR), P(29), "P29 linked above the floor");

        // Attacker re-bids at P30: the splice unlinked it, so it re-inserts between P29 and P40.
        _bid(att, P(30), 200e18, P(29));
        assertEq(auction.highestTick(), P(30));
        assertEq(_next(P(29)), P(30), "P30 linked above P29");
        assertEq(_next(P(30)), 0, "and is the top of the list");

        vm.roll(block.number + K);
        auction.sync(type(uint256).max);
        assertEq(auction.settleCursor(), 0, "sweep completed");

        emit log_named_uint("owed att (P30, orphan top)", _owed(att));
        emit log_named_uint("owed hh3 (P29, honest, one step below top)", _owed(hh3));
        emit log_named_uint("owed hh  (F)", _owed(hh));

        // With q = 1/2 and P29 one step below the top, hh3 is owed 1/3 of the 100-token pour.
        assertGt(_owed(hh3), 0, "honest P29 one step below the top is served");
    }
}
