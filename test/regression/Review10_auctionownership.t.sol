// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {GenerousAuction} from "../../src/GenerousAuction.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";
import {Mono} from "../../src/Mono.sol";
import {IIndex} from "../../src/interfaces/IIndex.sol";
import {MockPool} from "../MockPool.sol";
import {TestERC20} from "../TestERC20.sol";

contract Review10AuctionOwnership is Test {
    GenerousAuction internal auction;
    TestERC20 internal currency;
    Mono internal mono;
    address internal constant ALICE = address(0xA11CE);
    address internal constant STRANGER = address(0xBAD);
    address internal constant BOB = address(0xB0B);
    uint256 internal constant FLOOR = 1e18;
    uint256 internal constant HOSTILE_PRICE = 10_000e18;

    function setUp() public {
        currency = new TestERC20("Index", "INDEX");
        mono = new Mono(IIndex(address(currency)), 1_000_000e18);
        currency.mint(address(this), 1_000_000e18);
        currency.approve(address(mono), type(uint256).max);
        mono.mint(1_000_000e18, 1_000_000e18, address(this));
        mono.setPool(address(new MockPool(address(mono), address(currency), 1.25e18)));
        auction = new GenerousAuction(
            IGenerousAuction.Config({
                token: address(mono),
                currency: address(currency),
                admin: address(this),
                floorPrice: FLOOR,
                tickSpacing: 1e16,
                decayQ: (1 << 96) / 2,
                windowTicks: 8,
                startBlock: uint64(block.number),
                endBlock: 0,
                roundBlocks: 100,
                emissionPerRound: 100e18,
                minPremiumBips: 1500,
                previousAuction: address(0)
            })
        );
        mono.grantRole(mono.MINTER_ROLE(), address(auction));
        mono.transfer(ALICE, 1e18);
        currency.mint(ALICE, 100e18);
        currency.mint(STRANGER, 10_000);
        vm.startPrank(ALICE);
        mono.approve(address(auction), type(uint256).max);
        currency.approve(address(auction), type(uint256).max);
        auction.stake(1e18);
        vm.stopPrank();
        vm.prank(STRANGER);
        currency.approve(address(auction), type(uint256).max);
    }

    function _unsolicitedBid(uint256 price, uint128 amount) internal returns (bool accepted) {
        vm.prank(STRANGER);
        (accepted,) = address(auction).call(abi.encodeCall(IGenerousAuction.submitBid, (price, amount, ALICE, FLOOR)));
    }

    // Every bid must be submitted by its owner, including the first one.
    function test_strangerCannotChooseFirstPrice() public {
        bool accepted = _unsolicitedBid(HOSTILE_PRICE, 10_000);
        (uint256 price,,,,,,) = auction.positions(ALICE);
        emit log_named_uint("unsolicited price", price);
        assertFalse(accepted, "stranger selected the staker's first bid price");
    }

    // Reproduce the user's actual operation after three rounds. The unsolicited floor bid
    // is outside Bob's band, so time and sync do not clear it. No attacker stake is needed.
    // An honest withdrawal resets p.price to zero and reopens this authorization gap.
    function test_withdrawnOwnerCanRebidDespiteUnsolicitedDust() public {
        vm.startPrank(ALICE);
        auction.submitBid(FLOOR, 100e18, ALICE, FLOOR);
        auction.withdrawBid();
        vm.stopPrank();
        mono.transfer(BOB, 1e18);
        currency.mint(BOB, 1000e18);
        vm.startPrank(BOB);
        mono.approve(address(auction), type(uint256).max);
        currency.approve(address(auction), type(uint256).max);
        auction.stake(1e18);
        auction.submitBid(1.2e18, 1000e18, BOB, FLOOR);
        vm.stopPrank();

        _unsolicitedBid(FLOOR, 1);
        vm.roll(block.number + 300);
        auction.sync(128);
        assertGt(auction.tokensSold(), 0, "control: auction kept settling normally");
        vm.prank(ALICE);
        (bool ok, bytes memory reason) =
            address(auction).call(abi.encodeCall(IGenerousAuction.submitBid, (1.21e18, uint128(100e18), ALICE, FLOOR)));
        if (!ok) {
            assertEq(bytes4(reason), IGenerousAuction.BidExists.selector, "failure must be the poisoned position");
        }
        assertTrue(ok, "one currency-wei outside the band still blocks the owner's rebid after three rounds");
    }

    function test_strangerCannotTopUpEvenAtOwnerSelectedPrice() public {
        vm.prank(ALICE);
        auction.submitBid(FLOOR, 10e18, ALICE, FLOOR);
        uint256 paidBefore = currency.balanceOf(STRANGER);
        vm.prank(STRANGER);
        vm.expectRevert(IGenerousAuction.Unauthorized.selector);
        auction.submitBid(FLOOR, 10_000, ALICE, FLOOR);
        (uint256 live,) = auction.positionOf(ALICE);
        assertEq(live, 10e18);
        assertEq(currency.balanceOf(STRANGER), paidBefore);
    }

    function test_ownerCanTopUpAndWithdrawOwnEscrow() public {
        vm.startPrank(ALICE);
        auction.submitBid(FLOOR, 10e18, ALICE, FLOOR);
        auction.submitBid(FLOOR, 5e18, ALICE, FLOOR);
        (uint256 live,) = auction.positionOf(ALICE);
        assertEq(live, 15e18);
        assertEq(auction.withdrawBid(), 15e18);
        assertEq(currency.balanceOf(ALICE), 100e18);
        vm.stopPrank();
    }

    function test_control_ownerCanCreateFirstPosition() public {
        vm.prank(ALICE);
        auction.submitBid(FLOOR, 10e18, ALICE, FLOOR);
        (uint256 live,) = auction.positionOf(ALICE);
        assertEq(live, 10e18);
    }
}
