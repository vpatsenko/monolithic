// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Index} from "../src/Index.sol";
import {IIndex} from "../src/interfaces/IIndex.sol";
import {MockFeed} from "./IndexMono.t.sol";
import {TestERC20} from "./TestERC20.sol";
import {MockPool, MockStable} from "./MockPool.sol";

/// @notice A stock the issuer can freeze — the verified power the deferred-leg ledger exists for.
contract FreezableERC20 is TestERC20 {
    bool public frozen;

    constructor(string memory name_, string memory symbol_) TestERC20(name_, symbol_) {}

    function setFrozen(bool frozen_) external {
        frozen = frozen_;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        require(!frozen, "FROZEN");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }
}

/// @notice A frozen stock must not hold the other legs hostage, and must not be forfeited either.
contract IndexFrozenLegTest is Test {
    Index internal index;
    TestERC20 internal aapl;
    FreezableERC20 internal gme;
    MockFeed internal aaplFeed;
    MockFeed internal gmeFeed;
    MockStable internal usdc;
    MockPool internal aaplPool;
    MockPool internal gmePool;

    address internal alice = address(0xA1);
    address internal bob = address(0xB2);

    function setUp() public {
        aapl = new TestERC20("Apple", "AAPLx");
        gme = new FreezableERC20("GameStop", "GMEx");
        aaplFeed = new MockFeed(200e8);
        gmeFeed = new MockFeed(100e8);
        usdc = new MockStable(6);
        aaplPool = new MockPool(address(aapl), address(usdc), 200e18);
        gmePool = new MockPool(address(gme), address(usdc), 100e18);

        IIndex.Stock[] memory genesis = new IIndex.Stock[](1);
        genesis[0] = IIndex.Stock({
            asset: address(aapl), allocationBips: 10_000, priceFeed: address(aaplFeed), pool: address(aaplPool)
        });
        index = new Index(genesis);

        _wrap(alice, 100e18);
        bytes memory add =
            abi.encodeCall(IIndex.addStock, (IIndex.Stock(address(gme), 4_000, address(gmeFeed), address(gmePool))));
        index.queue(add);
        vm.warp(block.timestamp + index.TIMELOCK_DELAY());
        aaplFeed.touch();
        gmeFeed.touch();
        index.execute(add);
        _fillChannel(bob);
    }

    function _wrap(address who, uint256 shares) internal {
        uint256[] memory cost = index.calculateAmountOfAssetsToMintIndex(shares);
        aapl.mint(who, cost[0]);
        vm.startPrank(who);
        aapl.approve(address(index), type(uint256).max);
        index.mint(shares, who);
        vm.stopPrank();
    }

    function _fillChannel(address who) internal {
        uint256 shares = index.deficitToMint();
        uint256[] memory cost = index.calculateAmountOfAssetsToMintIndex(shares);
        gme.mint(who, cost[1]);
        vm.startPrank(who);
        gme.approve(address(index), type(uint256).max);
        index.mint(shares, who);
        vm.stopPrank();
        assertFalse(index.reallocating(), "channel should have closed");
    }

    function _claim(address who, address asset) internal returns (uint256) {
        address[] memory one = new address[](1);
        one[0] = asset;
        vm.prank(who);
        return index.claim(one, who)[0];
    }

    /// FIRE-ESCAPE test 1: freeze one leg, the others still pay, the frozen one is booked not lost.
    function test_frozenLegDoesNotBlockTheOthers() public {
        uint256[] memory quote = index.proceedsOfRedeem(10e18);
        gme.setFrozen(true);

        vm.prank(alice);
        uint256[] memory got = index.burn(10e18, alice);

        assertEq(got[0], quote[0], "live leg pays in full");
        assertEq(aapl.balanceOf(alice), quote[0]);
        assertEq(got[1], 0, "deferred leg reports zero received");
        assertEq(gme.balanceOf(alice), 0);

        assertEq(index.owed(alice, address(gme)), quote[1], "frozen leg booked, not forfeited");
        assertEq(index.reserved(address(gme)), quote[1]);
        assertGt(quote[1], 0);
    }

    /// The booked sliver is nobody else's: the next redeemer must not be paid out of it.
    function test_reservedSliverIsNotPaidTwice() public {
        gme.setFrozen(true);
        vm.prank(alice);
        index.burn(10e18, alice);
        uint256 booked = index.owed(alice, address(gme));

        // Bob redeems everything he has while Alice's leg is still on the books.
        uint256 bobShares = index.balanceOf(bob);
        uint256 potGme = gme.balanceOf(address(index)) - booked;
        uint256 expected = potGme * bobShares / index.totalSupply();

        gme.setFrozen(false);
        vm.prank(bob);
        uint256[] memory got = index.burn(bobShares, bob);
        assertEq(got[1], expected, "bob is paid out of the pot, never out of alice's leg");

        // And Alice's leg is still there, in full.
        assertEq(_claim(alice, address(gme)), booked);
        assertEq(gme.balanceOf(alice), booked);
    }

    /// Unfreeze and collect. Claiming while still frozen reverts and leaves the books untouched.
    function test_claimWaitsForTheThaw() public {
        gme.setFrozen(true);
        vm.prank(alice);
        index.burn(10e18, alice);
        uint256 booked = index.owed(alice, address(gme));

        address[] memory one = new address[](1);
        one[0] = address(gme);
        vm.prank(alice);
        vm.expectRevert();
        index.claim(one, alice);
        assertEq(index.owed(alice, address(gme)), booked, "a failed claim stays on the books");

        gme.setFrozen(false);
        assertEq(_claim(alice, address(gme)), booked);
        assertEq(index.owed(alice, address(gme)), 0);
        assertEq(index.reserved(address(gme)), 0);
    }

    /// The same asset twice in one call must not pay twice.
    function test_claimCannotDoubleSpend() public {
        gme.setFrozen(true);
        vm.prank(alice);
        index.burn(10e18, alice);
        gme.setFrozen(false);

        address[] memory twice = new address[](2);
        twice[0] = address(gme);
        twice[1] = address(gme);
        vm.prank(alice);
        vm.expectRevert(IIndex.NothingOwed.selector);
        index.claim(twice, alice);
    }

    /// The pump test: a mint/burn round trip never returns more than it cost, reserves outstanding.
    function test_roundTripNeverProfitsWithLegsBooked() public {
        gme.setFrozen(true);
        vm.prank(alice);
        index.burn(10e18, alice);
        gme.setFrozen(false);

        uint256 shares = 5e18;
        uint256[] memory cost = index.calculateAmountOfAssetsToMintIndex(shares);
        aapl.mint(bob, cost[0]);
        gme.mint(bob, cost[1]);
        vm.startPrank(bob);
        aapl.approve(address(index), type(uint256).max);
        gme.approve(address(index), type(uint256).max);
        index.mint(shares, bob);
        uint256[] memory got = index.burn(shares, bob);
        vm.stopPrank();

        assertLe(got[0], cost[0], "aapl round trip must not profit");
        assertLe(got[1], cost[1], "gme round trip must not profit");
    }
}
