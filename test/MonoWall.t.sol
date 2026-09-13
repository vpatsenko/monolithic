// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {MonoHookTest} from "./MonoHook.t.sol";
import {IMono} from "../src/interfaces/IMono.sol";
import {IMonoHook} from "../src/interfaces/IMonoHook.sol";
import {IIndex} from "../src/interfaces/IIndex.sol";
import {Mono} from "../src/Mono.sol";

/// @notice The wall of HANDBOOK §3.3: the hook fills the part of a sell the pool cannot take above
///         `NAV x (1 - wallTick)` and burns it, so the one outflow the vault has raises the floor.
///
///         Inherits `MonoHookTest`'s harness — same pool, same genesis at NAV 1.0, same
///         orientation trick — so `MonoWallFlippedTest` at the bottom runs all of it again with
///         MONO as `currency1`, where every price read inverts.
contract MonoWallTest is MonoHookTest {
    using StateLibrary for IPoolManager;

    /// @dev Comfortably past the ~5e18 that carries this book from 1.0 down to the wall.
    uint256 constant BIG_SELL = 50e18;

    function _arm() internal {
        mono.setWall(address(hook));
    }

    /// @dev The live pool price in INDEX per MONO, WAD — `nav()`'s unit, whichever way the pair
    ///      sorted. Written here rather than read off the hook so the assertions do not depend on
    ///      the same code they are checking.
    function _spot() internal view returns (uint256) {
        (uint160 sp,,,) = IPoolManager(address(manager)).getSlot0(id);
        uint256 ratioX96 = FixedPointMathLib.fullMulDiv(sp, sp, 1 << 96);
        return monoIsCurrency0
            ? FixedPointMathLib.fullMulDiv(ratioX96, 1e18, 1 << 96)
            : FixedPointMathLib.fullMulDiv(1e18, 1 << 96, ratioX96);
    }

    // ================================================================ arming

    /// The wall is code in the hook, but the vault decides when it is live: until `setWall` grants
    /// the one allowance, a sell is exactly the plain taxed swap it was before.
    function test_wallIsInertUntilTheVaultArmsIt() public {
        assertFalse(hook.wallArmed());
        uint256 potBefore = mono.totalIndex();
        uint256 wall = hook.wallPrice();

        _swapExactIn(true, BIG_SELL);

        assertEq(mono.totalIndex(), potBefore, "an unarmed wall must not touch the pot");
        assertLt(_spot(), wall, "and must not defend the price either");
    }

    function test_armingIsOneShot() public {
        _arm();
        assertTrue(hook.wallArmed());
        assertEq(mono.wall(), address(hook));

        vm.expectRevert(IMono.WallAlreadySet.selector);
        mono.setWall(address(hook));
    }

    /// The allowance is unbounded, so the address it is granted to is the whole of the protection.
    function test_armingRejectsAHookBuiltForAnotherVault() public {
        Mono other = new Mono(IIndex(address(idx)), 1e27);
        idx.approve(address(other), type(uint256).max);
        other.mint(1e24, 1e24, address(this));

        vm.expectRevert(IMono.InvalidWall.selector);
        other.setWall(address(hook)); // `hook.mono()` is the first vault, not this one
    }

    function test_armingRequiresAdmin() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        mono.setWall(address(hook));
    }

    // ================================================================ the split fill

    /// The law: a sell may take the pool down to the wall and no further, however big it is.
    /// Asserted against the wall as it stood WHEN THE SWAP RAN — the fill itself lifts NAV, so the
    /// wall the next swap meets is a higher one.
    function test_thePoolNeverEndsBelowTheWall() public {
        _arm();
        uint256 wall = hook.wallPrice();

        _swapExactIn(true, BIG_SELL);

        assertGe(_spot(), wall, "the pool was left under the wall");
    }

    function testFuzz_thePoolNeverEndsBelowTheWall(uint256 amount) public {
        amount = bound(amount, 1e12, 500e18);
        _arm();
        uint256 wall = hook.wallPrice();

        _swapExactIn(true, amount);

        assertGe(_spot(), wall, "the pool was left under the wall");
    }

    /// The mechanism, end to end: the pool takes what it can above the wall, the vault buys the
    /// rest at the wall price, and every MONO it buys is retired in the same transaction.
    function test_theWallBuysTheRemainderAndBurnsIt() public {
        _arm();
        uint256 supplyBefore = mono.totalSupply();
        uint256 potBefore = mono.totalIndex();

        vm.recordLogs();
        _swapExactIn(true, BIG_SELL);

        (uint256 burned, uint256 paid) = _lastWallFill();
        assertGt(burned, 0, "the wall must have engaged on a sell this size");
        // The hook holds the sell tax and nothing else: what it bought, it burned.
        assertEq(mono.balanceOf(address(hook)), (BIG_SELL * 5_000) / 1e6, "only the tax may remain");
        assertEq(mono.totalSupply(), supplyBefore - burned, "every MONO the wall bought is retired");
        assertEq(mono.totalIndex(), potBefore - paid, "and paid for out of the pot");
    }

    /// The whole point `[LAW]`. The vault's only outflow raises the floor it drains, because the
    /// bid is under NAV and the shares come off supply: `(I - R*w)/(S - R) > I/S` for `w < NAV`.
    function test_aWallFillRaisesNav() public {
        _arm();
        uint256 navBefore = mono.nav();

        _swapExactIn(true, BIG_SELL);

        assertGt(mono.nav(), navBefore, "the wall must be accretive, not a redemption");
    }

    function testFuzz_navNeverFallsAcrossASell(uint256 amount) public {
        amount = bound(amount, 1e12, 500e18);
        _arm();
        uint256 navBefore = mono.nav();

        _swapExactIn(true, amount);

        assertGe(mono.nav(), navBefore, "no sell may lower the floor");
    }

    /// A sell the book can absorb above the wall is untouched by the vault — the wall is the bid
    /// of last resort, not a toll on every trade.
    function test_aSellTheBookCanTakeNeverReachesTheVault() public {
        _arm();
        uint256 potBefore = mono.totalIndex();
        uint256 supplyBefore = mono.totalSupply();

        _swapExactIn(true, 1e16);

        assertEq(mono.totalIndex(), potBefore, "the pot must not move");
        assertEq(mono.totalSupply(), supplyBefore, "and nothing is burned");
        assertGt(_spot(), hook.wallPrice(), "the pool never got near the wall");
    }

    /// The day-0 shape, and the shape the pool drifts back into every time NAV rises: no bid under
    /// the wall at all. The pool leg is zero and the wall takes the entire sale.
    function test_aBookWithNoBidIsFilledEntirelyByTheWall() public {
        _arm();
        _swapExactIn(true, BIG_SELL); // parks the pool at the wall and lifts NAV past it
        uint256 spotBefore = _spot();

        vm.recordLogs();
        _swapExactIn(true, 10e18);

        (uint256 burned,) = _lastWallFill();
        // 10 MONO less the 0.5% sell tax, all of it bought by the vault.
        assertEq(burned, 10e18 - (10e18 * 5_000) / 1e6, "the wall must take the whole sale");
        assertEq(_spot(), spotBefore, "with no pool leg, the price does not move at all");
    }

    /// The middle case, and the one the other two bracket: the book has real depth, the sale eats
    /// ALL of it, and the price would still have further to fall. Both legs are non-zero — a
    /// genuine split rather than one side taking everything.
    ///
    /// `_wall` never computes where that boundary is; it hands the whole sale to `poolManager.swap`
    /// under the wall price limit and lets v4 stop wherever the liquidity does. This is the test
    /// that "let the pool figure it out" holds when the pool runs dry first.
    function test_aBookThatRunsDryAboveTheWallSplitsBothWays() public {
        _arm();
        _narrowBook(2e21);

        uint256 wall = hook.wallPrice();
        uint256 net = BIG_SELL - (BIG_SELL * 5_000) / 1e6; // post-tax, what the split divides

        vm.recordLogs();
        _swapExactIn(true, BIG_SELL);

        (uint256 burned,) = _lastWallFill();
        assertGt(burned, 0, "the wall must have taken the part the book could not");
        assertLt(burned, net, "but NOT all of it -- the book had depth and it was used");
        assertGe(_spot(), wall, "and the pool still ended at the wall, not under it");
    }

    /// The ceiling on the above, and it is not obvious: the hook can only BUY MONO the PoolManager
    /// is already holding. `take` moves real ERC-20, and mid-swap the manager's MONO is the pools'
    /// reserves — the seller's own input does not arrive until the router settles, which is after
    /// every hook has run. A book too MONO-poor to cover the fill therefore gets the plain taxed
    /// swap, exactly as §3.3 prescribes for a failed vault pull: degraded, never bricked.
    ///
    /// This is slack in the shipped shape — §3.5's POL is one-sided MONO, so the book the wall
    /// defends is the book that is full of MONO — but it is real, and it is why the "no bid at
    /// all" test above is not on its own proof that a thin book works.
    function test_aBookTooMonoPoorToCoverTheFillStandsDown() public {
        _arm();
        // Symmetric and small: this band holds only ~3e18 MONO, far under the ~46e18 fill.
        liq.modifyLiquidity(key, ModifyLiquidityParams(-60000, 60000, -1e21, bytes32(0)), "");
        liq.modifyLiquidity(key, ModifyLiquidityParams(-60, 60, 1e21, bytes32(0)), "");

        uint256 potBefore = mono.totalIndex();
        uint256 wall = hook.wallPrice();

        vm.recordLogs();
        _swapExactIn(true, BIG_SELL); // must NOT revert

        (uint256 burned,) = _lastWallFill();
        assertEq(burned, 0, "the wall must have stood down, not half-executed");
        assertEq(mono.totalIndex(), potBefore, "and must not have touched the pot");
        assertLt(_spot(), wall, "the price went under the wall -- that is the cost of standing down");
    }

    /// @dev Replace setUp's full-range book with one that is deep in MONO but shallow in INDEX, so
    ///      a sale exhausts what it can buy long before the wall while leaving the manager holding
    ///      plenty of MONO for the fill. The long leg points AWAY from the direction a sale drives
    ///      the tick, which flips with the pair ordering — hence the branch.
    function _narrowBook(int256 l) internal {
        liq.modifyLiquidity(key, ModifyLiquidityParams(-60000, 60000, -1e21, bytes32(0)), "");
        (int24 lo, int24 hi) = monoIsCurrency0 ? (int24(-60), int24(600)) : (int24(-600), int24(60));
        liq.modifyLiquidity(key, ModifyLiquidityParams(lo, hi, l, bytes32(0)), "");
    }

    /// Buys are untouched (§3.3). Only the sell side forks.
    function test_buysAreUntouched() public {
        _arm();
        uint256 potBefore = mono.totalIndex();
        uint256 supplyBefore = mono.totalSupply();

        _swapExactIn(false, 10e18);

        assertEq(mono.totalIndex(), potBefore);
        assertEq(mono.totalSupply(), supplyBefore);
    }

    /// "Sell tax applies to wall fills" — the tax is charged on the whole input before the split,
    /// so a sale the wall takes in full is taxed exactly like one the pool takes in full.
    function test_theSellTaxAppliesToWallFills() public {
        _arm();
        _swapExactIn(true, BIG_SELL);
        // 0.5%, the sell anchor at mNAV 1.0, read from spot before the swap moved anything.
        assertEq(mono.balanceOf(address(hook)), (BIG_SELL * 5_000) / 1e6, "the wall leg must be taxed too");
    }

    // ================================================================ exact output

    /// HANDBOOK §3.3 allows mirroring the split or refusing. We refuse — see `_beforeSwap`.
    function test_exactOutputSellIsRefusedOnceArmed() public {
        _arm();
        vm.expectRevert();
        _swapExactOut(true, 1e18);
    }

    function test_exactOutputSellStillWorksBeforeArming() public {
        _swapExactOut(true, 1e18);
        assertGt(mono.balanceOf(address(hook)), 0, "still taxed on the input token");
    }

    /// The refusal is the SELL side only. An exact-output buy is not a wall path at all.
    function test_exactOutputBuyIsUnaffected() public {
        _arm();
        _swapExactOut(false, 1e18);
        assertGt(idx.balanceOf(address(hook)), 0, "an exact-output buy must still work, and be taxed");
    }

    // ================================================================ the tick

    function test_wallPriceIsNavLessTheTick() public view {
        assertEq(hook.wallTickBips(), 100, "launch default is the spec's 0.99 x NAV");
        assertEq(hook.wallPrice(), (mono.nav() * 9_900) / 10_000);
    }

    function test_theTickIsTimelocked() public {
        vm.expectRevert(IMonoHook.NotTimelocked.selector);
        hook.setWallTickBips(50);

        _timelocked(abi.encodeCall(IMonoHook.setWallTickBips, (50)));
        assertEq(hook.wallTickBips(), 50);
        assertEq(hook.wallPrice(), (mono.nav() * 9_950) / 10_000);
    }

    /// The ceiling is the number governance cannot reach, and zero is refused because a wall at
    /// NAV is floor-neutral — the tick is what makes the outflow accretive.
    function test_theTickHasAHardCeilingAndNoZero() public {
        bytes memory tooHigh = abi.encodeCall(IMonoHook.setWallTickBips, (hook.MAX_WALL_TICK_BIPS() + 1));
        hook.queue(tooHigh);
        vm.warp(block.timestamp + hook.TIMELOCK_DELAY());
        vm.expectRevert(IMonoHook.InvalidWallTick.selector);
        hook.execute(tooHigh);

        bytes memory zero = abi.encodeCall(IMonoHook.setWallTickBips, (0));
        hook.queue(zero);
        vm.warp(block.timestamp + hook.TIMELOCK_DELAY());
        vm.expectRevert(IMonoHook.InvalidWallTick.selector);
        hook.execute(zero);
    }

    /// A wider tick means a deeper discount, so the same sale retires more supply and lifts the
    /// floor further — and the pool is allowed further down before the wall catches it.
    function test_aWiderTickBidsLower() public {
        _timelocked(abi.encodeCall(IMonoHook.setWallTickBips, (1_000)));
        _arm();
        uint256 wall = hook.wallPrice();
        assertEq(wall, (mono.nav() * 9_000) / 10_000);

        _swapExactIn(true, BIG_SELL);
        assertGe(_spot(), wall);
    }

    // ================================================================ cost

    /// What the wall adds to a sell that engages it, over the same sell with the wall unarmed.
    /// A regression guard, not a target: the leg is an inner `swap` plus a vault pull, a burn and
    /// a settle, and it only runs when the book could not take the sale on its own.
    function test_wallOverheadOnAnEngagedSell() public {
        // Warm everything inside this transaction first, or the first measurement pays the cold
        // -access bill for both.
        _swapExactIn(true, 1e16);
        vm.warp(block.timestamp + 60);

        uint256 g = gasleft();
        _swapExactIn(true, BIG_SELL);
        uint256 unarmed = g - gasleft();

        _arm();
        vm.warp(block.timestamp + 60);
        g = gasleft();
        _swapExactIn(true, BIG_SELL);
        uint256 armed = g - gasleft();

        emit log_named_uint("sell, wall unarmed", unarmed);
        emit log_named_uint("sell, wall engaged", armed);
        emit log_named_uint("wall overhead     ", armed - unarmed);
        assertLt(armed - unarmed, 80_000, "the wall got materially more expensive");
    }

    // ================================================================ helpers

    /// @dev The `WallFilled(PoolId,uint256,uint256)` of the swap just recorded, or (0,0).
    function _lastWallFill() internal returns (uint256 burned, uint256 paid) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("WallFilled(bytes32,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == sig) {
                return abi.decode(logs[i].data, (uint256, uint256));
            }
        }
    }
}

/// @notice All of it again with MONO as `currency1`, where the pool quotes MONO per INDEX, a sale
///         pushes the price UP, and the wall's `sqrtPriceLimitX96` is an upper bound instead of a
///         lower one. Nothing in the contract may depend on which way the pair sorted.
contract MonoWallFlippedTest is MonoWallTest {
    function monoFirst() internal pure override returns (bool) {
        return false;
    }
}
