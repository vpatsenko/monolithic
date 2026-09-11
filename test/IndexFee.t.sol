// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Test} from "forge-std/Test.sol";
import {Index} from "../src/Index.sol";
import {IIndex} from "../src/interfaces/IIndex.sol";
import {MockFeed} from "./IndexMono.t.sol";
import {TestERC20} from "./TestERC20.sol";
import {MockPool, MockStable} from "./MockPool.sol";

/// @notice P7 in-kind fee: charged each way, kept in the pot, capped at 5%.
contract IndexFeeTest is Test {
    Index internal index;
    TestERC20 internal aapl;
    MockFeed internal aaplFeed;
    MockStable internal usdc;
    MockPool internal aaplPool;

    address internal alice = address(0xA1);
    address internal bob = address(0xB2);

    /// @dev 1.755%, the scale the fee is quoted in: per 100_000, not per 10_000.
    uint256 internal constant RATE = 1_755;
    uint256 internal constant FEE_SCALE = 100_000;

    function setUp() public {
        aapl = new TestERC20("Apple", "AAPLx");
        aaplFeed = new MockFeed(200e8);
        usdc = new MockStable(6);
        aaplPool = new MockPool(address(aapl), address(usdc), 200e18);
        IIndex.Stock[] memory genesis = new IIndex.Stock[](1);
        genesis[0] = IIndex.Stock({
            asset: address(aapl), allocationBips: 10_000, priceFeed: address(aaplFeed), pool: address(aaplPool)
        });
        index = new Index(genesis);
    }

    /// @dev Queue and wait, re-stamping the feed the warp would otherwise have staled.
    function _arm(bytes memory data) internal {
        index.queue(data);
        vm.warp(block.timestamp + index.TIMELOCK_DELAY());
        aaplFeed.touch();
    }

    function _run(bytes memory data) internal {
        _arm(data);
        index.execute(data);
    }

    function _setRate(uint256 rate) internal {
        _run(abi.encodeCall(IIndex.setFeeRate, (rate)));
    }

    function _wrap(address who, uint256 shares) internal returns (uint256 paid) {
        uint256[] memory cost = index.calculateAmountOfAssetsToMintIndex(shares);
        aapl.mint(who, cost[0]);
        vm.startPrank(who);
        aapl.approve(address(index), type(uint256).max);
        index.mint(shares, who);
        vm.stopPrank();
        return cost[0];
    }

    function test_defaultsToZeroAndChargesNothing() public {
        assertEq(index.feeRate(), 0);
        _wrap(alice, 1_000e18);
        uint256[] memory got = index.proceedsOfRedeem(100e18);
        assertEq(got[0], 100e18, "no fee set, slice is exactly pro-rata");
    }

    function test_rateIsPerHundredThousand() public {
        _setRate(RATE);
        _wrap(alice, 1_000e18); // genesis: exempt, 1_000 AAPL in the pot

        // 1.755% on top of a 100-AAPL mint.
        uint256 cost = index.calculateAmountOfAssetsToMintIndex(100e18)[0];
        assertEq(cost, 100e18 * (FEE_SCALE + RATE) / FEE_SCALE);
        assertEq(cost, 101.755e18, "1755 must mean 1.755%, not 17.55%");
    }

    /// The fee is charged on the way in only — redemption pays the full pro-rata slice.
    function test_burnIsFree() public {
        _setRate(RATE);
        _wrap(alice, 1_000e18);
        _wrap(bob, 100e18);

        uint256 collected = index.fees(address(aapl));
        uint256[] memory got = index.proceedsOfRedeem(100e18);
        assertEq(got[0], 100e18, "full slice out, no haircut on exit");

        vm.prank(bob);
        index.burn(100e18, bob);
        assertEq(aapl.balanceOf(bob), 100e18);
        assertEq(index.fees(address(aapl)), collected, "burn collects nothing");
    }

    function test_capIsFivePercent() public {
        _setRate(5_000);
        assertEq(index.feeRate(), 5_000);

        // Over the ceiling — surfaced through `execute`, not swallowed.
        bytes memory tooHigh = abi.encodeCall(IIndex.setFeeRate, (uint256(5_001)));
        _arm(tooHigh);
        vm.expectRevert(IIndex.FeeTooHigh.selector);
        index.execute(tooHigh);

        // Not the owner: cannot even start the clock.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        index.queue(abi.encodeCall(IIndex.setFeeRate, (uint256(10))));

        // The owner cannot skip the queue.
        vm.expectRevert(IIndex.NotTimelocked.selector);
        index.setFeeRate(10);
    }

    function test_genesisIsExemptButLaterMintsAreNot() public {
        _setRate(RATE);
        uint256 genesisCost = _wrap(alice, 1_000e18);
        assertEq(genesisCost, 1_000e18, "founding deposit pays no fee");

        uint256 later = index.calculateAmountOfAssetsToMintIndex(100e18)[0];
        assertEq(later, 100e18 * (FEE_SCALE + RATE) / FEE_SCALE, "later mints pay the fee");
    }

    /// The fee is collected, not accreted: it is netted out of the pot the moment it lands, so a
    /// fee-charging mint leaves NAV per share exactly where it was.
    function test_feeIsCollectedNotAccreted() public {
        _setRate(RATE);
        _wrap(alice, 1_000e18);
        uint256 navBefore = index.proceedsOfRedeem(1e18)[0];

        uint256 paid = _wrap(bob, 100e18);
        assertEq(paid, 100e18 * (FEE_SCALE + RATE) / FEE_SCALE);
        assertEq(index.fees(address(aapl)), paid - 100e18, "the gross-up is booked as fee");
        assertEq(index.proceedsOfRedeem(1e18)[0], navBefore, "NAV per share unmoved");
    }

    /// Sweeping cannot move NAV either — the fee was never counted as backing.
    function test_withdrawDoesNotTouchNav() public {
        _setRate(RATE);
        _wrap(alice, 1_000e18);
        _wrap(bob, 100e18);

        uint256 navBefore = index.proceedsOfRedeem(1e18)[0];
        uint256 collected = index.fees(address(aapl));
        assertGt(collected, 0);

        address[] memory one = new address[](1);
        one[0] = address(aapl);
        uint256[] memory swept = index.withdrawFees(one, address(0xFEE));

        assertEq(swept[0], collected);
        assertEq(aapl.balanceOf(address(0xFEE)), collected);
        assertEq(index.fees(address(aapl)), 0);
        assertEq(index.proceedsOfRedeem(1e18)[0], navBefore, "sweep is invisible to holders");
    }

    function test_withdrawIsOwnerOnlyAndNeedsABalance() public {
        address[] memory one = new address[](1);
        one[0] = address(aapl);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        index.withdrawFees(one, alice);

        // Nothing collected yet.
        vm.expectRevert(IIndex.NothingOwed.selector);
        index.withdrawFees(one, address(this));
    }

    /// The sweep reaches `fees` and nothing else: the pot's own stock stays put.
    function test_withdrawCannotReachThePot() public {
        _setRate(RATE);
        _wrap(alice, 1_000e18);
        _wrap(bob, 100e18);

        uint256 collected = index.fees(address(aapl));
        uint256 potBefore = aapl.balanceOf(address(index));

        address[] memory one = new address[](1);
        one[0] = address(aapl);
        index.withdrawFees(one, address(0xFEE));

        assertEq(aapl.balanceOf(address(index)), potBefore - collected, "only the fee left");
        // A second sweep has nothing to take, even though the pot is full.
        vm.expectRevert(IIndex.NothingOwed.selector);
        index.withdrawFees(one, address(0xFEE));
    }

    /// A round trip pays the rate once, on the way in. Measured against what was spent rather than
    /// the pro-rata base, 1.755% shows up as 1_724 per 100_000 (1_755 / 1.01755).
    function test_roundTripPaysTheMintLegOnly() public {
        _setRate(RATE);
        _wrap(alice, 1_000e18);

        uint256 spent = _wrap(bob, 100e18);
        vm.prank(bob);
        uint256[] memory got = index.burn(100e18, bob);

        assertLt(got[0], spent, "round trip must lose");
        uint256 loss = (spent - got[0]) * FEE_SCALE / spent;
        assertApproxEqAbs(loss, 1_724, 2);
        assertEq(index.fees(address(aapl)), spent - got[0], "the mint fee is collectable");
    }

    function test_channelMintPaysHaircutNotFee() public {
        TestERC20 nvda = new TestERC20("Nvidia", "NVDAx");
        MockFeed nvdaFeed = new MockFeed(100e8);
        MockPool nvdaPool = new MockPool(address(nvda), address(usdc), 100e18);
        // solhint-disable-next-line no-unused-vars
        _wrap(alice, 100e18); // $20_000 pot, $200 per INDEX
        _setRate(RATE);
        bytes memory add =
            abi.encodeCall(IIndex.addStock, (IIndex.Stock(address(nvda), 4_000, address(nvdaFeed), address(nvdaPool))));
        index.queue(add);
        vm.warp(block.timestamp + index.TIMELOCK_DELAY());
        aaplFeed.touch();
        nvdaFeed.touch();
        index.execute(add);

        // 10 INDEX at $200 = $2_000, grossed up by the 1% haircut only, at $100/NVDA.
        uint256 cost = index.calculateAmountOfAssetsToMintIndex(10e18)[1];
        uint256 haircutOnly = uint256(2_000e18) * 10_000 / 9_900 / 100;
        assertApproxEqAbs(cost, haircutOnly, 2, "channel charges the haircut, not the fee");
    }
}
