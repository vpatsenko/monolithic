// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Test} from "forge-std/Test.sol";
import {Index} from "../src/Index.sol";
import {IIndex} from "../src/interfaces/IIndex.sol";
import {MockFeed} from "./IndexMono.t.sol";
import {TestERC20} from "./TestERC20.sol";
import {MockPool, MockStable} from "./MockPool.sol";

/// @notice The notice period on composition and fee changes, and the fire-escape exit.
contract IndexTimelockTest is Test {
    Index internal index;
    TestERC20 internal aapl;
    TestERC20 internal nvda;
    MockFeed internal aaplFeed;
    MockFeed internal nvdaFeed;
    MockStable internal usdc;
    MockPool internal aaplPool;
    MockPool internal nvdaPool;

    address internal alice = address(0xA1);

    function setUp() public {
        aapl = new TestERC20("Apple", "AAPLx");
        nvda = new TestERC20("Nvidia", "NVDAx");
        aaplFeed = new MockFeed(200e8);
        nvdaFeed = new MockFeed(100e8);
        usdc = new MockStable(6);
        aaplPool = new MockPool(address(aapl), address(usdc), 200e18);
        nvdaPool = new MockPool(address(nvda), address(usdc), 100e18);

        IIndex.Stock[] memory genesis = new IIndex.Stock[](1);
        genesis[0] = IIndex.Stock({
            asset: address(aapl), allocationBips: 10_000, priceFeed: address(aaplFeed), pool: address(aaplPool)
        });
        index = new Index(genesis);
        _wrap(alice, 100e18); // $20_000 pot
    }

    function _wrap(address who, uint256 shares) internal {
        uint256[] memory cost = index.calculateAmountOfAssetsToMintIndex(shares);
        aapl.mint(who, cost[0]);
        vm.startPrank(who);
        aapl.approve(address(index), type(uint256).max);
        index.mint(shares, who);
        vm.stopPrank();
    }

    function _arm(bytes memory data) internal {
        index.queue(data);
        vm.warp(block.timestamp + index.TIMELOCK_DELAY());
        aaplFeed.touch();
        nvdaFeed.touch();
    }

    function _addNvda() internal {
        bytes memory add =
            abi.encodeCall(IIndex.addStock, (IIndex.Stock(address(nvda), 4_000, address(nvdaFeed), address(nvdaPool))));
        _arm(add);
        index.execute(add);
        // Fill the channel so the basket really holds both stocks.
        uint256 shares = index.deficitToMint();
        uint256[] memory cost = index.calculateAmountOfAssetsToMintIndex(shares);
        nvda.mint(alice, cost[1]);
        vm.startPrank(alice);
        nvda.approve(address(index), type(uint256).max);
        index.mint(shares, alice);
        vm.stopPrank();
        assertFalse(index.reallocating());
    }

    // ------------------------------------------------------------- timelock

    function test_cannotExecuteEarly() public {
        bytes memory data = abi.encodeCall(IIndex.setFeeRate, (uint256(50)));
        index.queue(data);

        vm.expectRevert(IIndex.TimelockPending.selector);
        index.execute(data);

        vm.warp(block.timestamp + index.TIMELOCK_DELAY() - 1);
        vm.expectRevert(IIndex.TimelockPending.selector);
        index.execute(data);

        vm.warp(block.timestamp + 1);
        aaplFeed.touch();
        index.execute(data);
        assertEq(index.feeRate(), 50);
    }

    function test_unqueuedCannotExecute() public {
        bytes memory data = abi.encodeCall(IIndex.setFeeRate, (uint256(50)));
        vm.expectRevert(IIndex.NotQueued.selector);
        index.execute(data);
    }

    function test_executeConsumesTheQueueSlot() public {
        bytes memory data = abi.encodeCall(IIndex.setFeeRate, (uint256(50)));
        _arm(data);
        index.execute(data);
        assertEq(index.queuedAt(keccak256(data)), 0);

        // Same call cannot be replayed without queueing again.
        vm.expectRevert(IIndex.NotQueued.selector);
        index.execute(data);
    }

    function test_cancelStopsIt() public {
        bytes memory data = abi.encodeCall(IIndex.setFeeRate, (uint256(50)));
        _arm(data);
        index.cancel(data);
        assertEq(index.queuedAt(keccak256(data)), 0);

        vm.expectRevert(IIndex.NotQueued.selector);
        index.execute(data);
        assertEq(index.feeRate(), 0);
    }

    function test_queueGuards() public {
        bytes memory data = abi.encodeCall(IIndex.setFeeRate, (uint256(50)));
        index.queue(data);
        vm.expectRevert(IIndex.AlreadyQueued.selector);
        index.queue(data);

        vm.expectRevert(IIndex.NotQueued.selector);
        index.cancel(abi.encodeCall(IIndex.setFeeRate, (uint256(60))));

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        index.queue(data);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        index.execute(data);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        index.cancel(data);
        vm.stopPrank();
    }

    /// A failed execute leaves the call queued, so it can be retried once the cause is fixed.
    function test_failedExecuteKeepsTheQueueEntry() public {
        bytes memory tooHigh = abi.encodeCall(IIndex.setFeeRate, (uint256(5_001)));
        _arm(tooHigh);
        vm.expectRevert(IIndex.FeeTooHigh.selector);
        index.execute(tooHigh);
        assertGt(index.queuedAt(keccak256(tooHigh)), 0, "still queued after a failed run");
    }

    // ---------------------------------------------------------- fire escape

    function test_fireEscapeRemovesAndPaysTheOwner() public {
        _addNvda();
        assertEq(index.assetCount(), 2);
        uint256 potNvda = nvda.balanceOf(address(index));
        assertGt(potNvda, 0);

        bytes memory esc = abi.encodeCall(IIndex.fireEscape, (address(nvda)));
        _arm(esc);
        index.execute(esc);

        assertEq(index.assetCount(), 1, "removed from the basket");
        assertEq(nvda.balanceOf(address(this)), potNvda, "whole pot balance to the owner");
        assertEq(nvda.balanceOf(address(index)), 0);
        (address asset,,,) = index.stocks(address(nvda));
        assertEq(asset, address(0), "delisted");

        // The freed weight lands on the survivor, so allocations still sum to 10_000.
        (, uint16 bips,,) = index.stocks(address(aapl));
        assertEq(bips, 10_000);
    }

    /// Mint and redeem both stop seeing the asset in the same transaction — no pump window.
    function test_fireEscapeMovesBothSidesAtOnce() public {
        _addNvda();
        bytes memory esc = abi.encodeCall(IIndex.fireEscape, (address(nvda)));
        _arm(esc);
        index.execute(esc);

        assertEq(index.proceedsOfRedeem(1e18).length, 1, "redeem side has one leg");
        assertEq(index.calculateAmountOfAssetsToMintIndex(1e18).length, 1, "mint side has one leg");

        uint256 cost = index.calculateAmountOfAssetsToMintIndex(10e18)[0];
        aapl.mint(alice, cost);
        vm.startPrank(alice);
        index.mint(10e18, alice);
        uint256 back = index.burn(10e18, alice)[0];
        vm.stopPrank();
        assertLe(back, cost, "round trip cannot profit across a removal");
    }

    /// Claimants' deferred legs and uncollected fees are not the owner's to take.
    function test_fireEscapeLeavesReservedAndFeesBehind() public {
        _addNvda();
        _arm(abi.encodeCall(IIndex.setFeeRate, (uint256(1_000))));
        index.execute(abi.encodeCall(IIndex.setFeeRate, (uint256(1_000))));

        // A mint collects a fee in both legs.
        uint256[] memory cost = index.calculateAmountOfAssetsToMintIndex(10e18);
        aapl.mint(alice, cost[0]);
        nvda.mint(alice, cost[1]);
        vm.prank(alice);
        index.mint(10e18, alice);

        uint256 collected = index.fees(address(nvda));
        assertGt(collected, 0);
        uint256 potNet = nvda.balanceOf(address(index)) - collected;

        bytes memory esc = abi.encodeCall(IIndex.fireEscape, (address(nvda)));
        _arm(esc);
        index.execute(esc);

        assertEq(nvda.balanceOf(address(this)), potNet, "only the pot's own balance left");
        assertEq(index.fees(address(nvda)), collected, "fee untouched");

        // And it is still withdrawable after delisting.
        address[] memory one = new address[](1);
        one[0] = address(nvda);
        index.withdrawFees(one, address(0xFEE));
        assertEq(nvda.balanceOf(address(0xFEE)), collected);
    }

    function test_fireEscapeGuards() public {
        // Not reachable without the timelock, by anyone.
        vm.expectRevert(IIndex.NotTimelocked.selector);
        index.fireEscape(address(aapl));
        vm.prank(alice);
        vm.expectRevert(IIndex.NotTimelocked.selector);
        index.fireEscape(address(aapl));

        // The last stock cannot leave — an empty basket has no NAV.
        bytes memory last = abi.encodeCall(IIndex.fireEscape, (address(aapl)));
        _arm(last);
        vm.expectRevert(IIndex.LastAsset.selector);
        index.execute(last);

        _addNvda();

        // An unlisted asset is not removable.
        bytes memory ghost = abi.encodeCall(IIndex.fireEscape, (address(0xDEAD)));
        _arm(ghost);
        vm.expectRevert(IIndex.InvalidAsset.selector);
        index.execute(ghost);
    }

    /// A removal cannot land while a deficit channel is open — it would strand the channel.
    function test_fireEscapeBlockedDuringCampaign() public {
        bytes memory add =
            abi.encodeCall(IIndex.addStock, (IIndex.Stock(address(nvda), 4_000, address(nvdaFeed), address(nvdaPool))));
        _arm(add);
        index.execute(add);
        assertTrue(index.reallocating());

        bytes memory esc = abi.encodeCall(IIndex.fireEscape, (address(aapl)));
        _arm(esc);
        vm.expectRevert(IIndex.ReallocationActive.selector);
        index.execute(esc);
    }
}
