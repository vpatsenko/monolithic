// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Review8AccessBase} from "./Review8_access_Base.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";

/// Original round-8 defect: `submitBid(price, amount, owner, prevTick)` let ANY msg.sender fund a
/// bid for ANY owner. "One bid per owner" is keyed on `owner`, and a position whose live escrow
/// is 0 is re-bound to whatever price the CALLER names. So a third party with no stake and a
/// wei of currency can re-bind an exhausted position to a price its owner never chose, and
/// the owner's own next bid at their intended price then reverts `BidExists`.
///
/// Two regimes, both tested: in-band the stranger's 1-wei cap is eaten by the very next
/// emission block, so the block only holds inside one block (a front-run); OUT of the band
/// (more than `windowTicks` below the top) nothing ever pours into it, and the owner is locked
/// out of bidding until they withdraw — after which the stranger could re-bind again for 1 wei.
/// Round 10 requires owner == msg.sender for every bid, including same-price top-ups.
contract Review8_access_thirdPartyRebind is Review8AccessBase {
    address internal V = address(0xA1); // victim: staked, exhausted
    address internal W = address(0xA2); // deep top of book, 10 ticks up
    address internal ATK = address(0xBAD); // attacker: zero MONO, a few wei of INDEX

    uint256 internal constant P10 = FLOOR + 10 * SPACING;

    function setUp() public {
        _deploy(40e18, 0);
    }

    function _exhaustVictimAtP1() internal {
        _stakeFor(V, 1e18);
        _bid(V, P1, uint128(101e17), FLOOR); // cap 10 of a 40-token round: exhausts
        _round();
        assertEq(_live(V), 0, "victim exhausted in place");
        assertEq(_price(V), P1, "still bound at P1");
    }

    /// Moving an exhausted position to another price is the owner's call: a stranger's attempt
    /// reverts `Unauthorized`, whatever the price — out of the band, in the band, or the top of
    /// the range with the victim's stake behind it. The owner's own re-bind goes through.
    function test_strangerCannotRebindExhaustedPosition() public {
        _exhaustVictimAtP1();
        _stakeFor(W, 1e18);
        _bid(W, P10, 100_000e18, P1);
        assertEq(auction.stakes(ATK), 0, "the stranger has no stake");

        cur.mint(ATK, 1e4);
        vm.startPrank(ATK);
        cur.approve(address(auction), 1e4);
        vm.expectRevert(IGenerousAuction.Unauthorized.selector);
        auction.submitBid(P0, 1, V, FLOOR); // out of the band
        vm.expectRevert(IGenerousAuction.Unauthorized.selector);
        auction.submitBid(FLOOR * 1e4, uint128(1e4), V, P1); // top of the range on V's stake
        vm.expectRevert(IGenerousAuction.Unauthorized.selector);
        auction.submitBid(P1, 2, V, FLOOR); // even at the exhausted position's original price
        vm.stopPrank();
        assertEq(_price(V), P1, "still bound where the victim left it");

        cur.mint(V, 100e18);
        vm.startPrank(V);
        cur.approve(address(auction), 100e18);
        auction.submitBid(P0, 100e18, V, FLOOR); // the owner moves it
        vm.stopPrank();
        assertEq(_price(V), P0, "owner's bid at the owner's price");
    }

    /// A stranger cannot move live escrow or top up an active or inert position.
    function test_strangerCannotMoveLiveEscrowOrTopUpInert() public {
        _stakeFor(V, 1e18);
        _bid(V, P1, 100e18, FLOOR);

        cur.mint(ATK, 10);
        vm.startPrank(ATK);
        cur.approve(address(auction), 10);
        vm.expectRevert(IGenerousAuction.Unauthorized.selector);
        auction.submitBid(P0, 1, V, FLOOR);
        vm.expectRevert(IGenerousAuction.Unauthorized.selector);
        auction.submitBid(P1, 2, V, FLOOR);
        vm.stopPrank();

        _bid(V, P1, 5e18, FLOOR); // owner funds their own top-up
        assertEq(_live(V), 105e18, "owner's top-up lands in V's position");
        vm.prank(V);
        assertEq(auction.withdrawBid(), 105e18, "and only V can take it out");

        vm.prank(V);
        auction.unstake(1e18);
        cur.mint(ATK, 10);
        vm.startPrank(ATK);
        cur.approve(address(auction), 10);
        vm.expectRevert(IGenerousAuction.Unauthorized.selector);
        auction.submitBid(P1, 2, V, FLOOR);
        vm.stopPrank();
    }

    /// Owner-triggered top-ups retain the rounding regression: harvesting every other block
    /// changes nothing beyond dust against an identical untouched co-staker.
    function test_ownerTopUpHarvestCadenceIsRoundingOnly() public {
        address U = address(0xA3);
        _stakeFor(V, 1e18);
        _stakeFor(U, 1e18);
        _bid(V, P1, 1010e18, FLOOR);
        _bid(U, P1, 1010e18, FLOOR);

        uint256 n = 50;
        for (uint256 i; i < n; ++i) {
            vm.roll(block.number + 2);
            _bid(V, P1, 2, FLOOR); // owner syncs, harvests V, re-seats V; U untouched
        }
        vm.roll(block.number + K);
        auction.sync(64);
        uint256 ov = _owed(V);
        uint256 ou = _owed(U);
        emit log_named_uint("owed(V) harvested 50x", ov);
        emit log_named_uint("owed(U) never harvested", ou);
        uint256 diff = ov > ou ? ov - ou : ou - ov;
        emit log_named_uint("abs diff (wei)", diff);
        assertLe(diff, n + 2, "repeated harvests cost at most ~1 wei each");
        // The pot side: 51 pours with 2 seats each reserve 51 wei; what each claimant actually
        // receives against what it is owed.
        emit log_named_uint("tokensSold", auction.tokensSold());
        emit log_named_uint("tokensBooked", auction.tokensBooked());
        emit log_named_uint("tokensUnclaimed", auction.tokensUnclaimed());
        uint256 gotV = auction.claim(V);
        emit log_named_uint("tokensMinted after the pack", auction.tokensMinted());
        emit log_named_uint("held after V's claim", mono.balanceOf(address(auction)) - auction.totalStaked());
        uint256 gotU = auction.claim(U);
        emit log_named_uint("claim(V) paid", gotV);
        emit log_named_uint("claim(U) paid", gotU);
        emit log_named_uint("V shortfall vs owed (wei)", ov - gotV);
        emit log_named_uint("U shortfall vs owed (wei)", ou - gotU);
        assertLe(ov - gotV + (ou - gotU), 2 * (n + 1), "total dust within the documented reserve");
    }
}
