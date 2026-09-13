// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {HookMiner} from "v4-periphery/utils/HookMiner.sol";

import {MonoHook} from "../src/MonoHook.sol";
import {IMonoHook} from "../src/interfaces/IMonoHook.sol";
import {IIndex} from "../src/interfaces/IIndex.sol";
import {Mono} from "../src/Mono.sol";
import {MockIndex} from "../src/MockIndex.sol";

contract MonoHookTest is Test {
    using StateLibrary for IPoolManager;

    // HANDBOOK §4: strike = the round length; gate and throttle share the slow one.
    uint32 constant TAU_STRIKE = 1 minutes;
    uint32 constant TAU_SLOW = 5 minutes;

    uint160 constant HOOK_FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    PoolManager manager;
    PoolSwapTest swapper;
    PoolModifyLiquidityTest liq;
    MonoHook hook;
    MockIndex idx;
    Mono mono;

    PoolKey key;
    PoolId id;
    bool monoIsCurrency0;

    address treasury = address(0x7EEA);

    /// @dev Overridden by `MonoHookFlippedTest` to run the whole suite with the pair the other way
    ///      round. Nothing in the contract may depend on it.
    function monoFirst() internal pure virtual returns (bool) {
        return true;
    }

    function setUp() public virtual {
        manager = new PoolManager(address(this));
        swapper = new PoolSwapTest(IPoolManager(address(manager)));
        liq = new PoolModifyLiquidityTest(IPoolManager(address(manager)));

        idx = new MockIndex("Index", "INDEX", 1e30);
        // Which side of the pair MONO sorts onto decides whether the pool quotes INDEX per MONO
        // or its inverse, and `_mNav` has to invert in one case and not the other. Redeploy until
        // the ordering is the one this run wants, so `MonoHookFlippedTest` covers the other leg.
        do {
            mono = new Mono(IIndex(address(idx)), 1e27);
        } while ((address(mono) < address(idx)) != monoFirst());

        // Genesis at exactly one INDEX per MONO, so mNAV starts at 1.0 and the launch anchors
        // land on their `mStart` end.
        idx.approve(address(mono), type(uint256).max);
        mono.mint(1e24, 1e24, address(this));
        assertEq(mono.nav(), 1e18, "setup: opening NAV must be 1.0");

        address flagged = address(uint160(0x4444 << 144) | HOOK_FLAGS);
        deployCodeTo(
            "MonoHook.sol:MonoHook",
            abi.encode(IPoolManager(address(manager)), mono, treasury, TAU_STRIKE, TAU_SLOW),
            flagged
        );
        hook = MonoHook(flagged);

        monoIsCurrency0 = address(mono) < address(idx);
        (Currency c0, Currency c1) = monoIsCurrency0
            ? (Currency.wrap(address(mono)), Currency.wrap(address(idx)))
            : (Currency.wrap(address(idx)), Currency.wrap(address(mono)));

        // Dynamic fee at init even though nothing sets one: `updateDynamicLPFee` is gated on the
        // pool having been CREATED dynamic, and the fee lives in the `PoolKey`, so a static pool
        // can never become dynamic. Free now, a POL migration later.
        key = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(flagged));
        id = key.toId();

        idx.approve(address(swapper), type(uint256).max);
        idx.approve(address(liq), type(uint256).max);
        mono.approve(address(swapper), type(uint256).max);
        mono.approve(address(liq), type(uint256).max);

        vm.warp(1_700_000_000);
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        liq.modifyLiquidity(key, ModifyLiquidityParams(-60000, 60000, 1e21, bytes32(0)), "");
    }

    // ---------------------------------------------------------------- helpers

    /// @dev `zeroForOne` is whichever direction pays the token we mean to spend.
    function _dir(bool sellMono) internal view returns (bool) {
        return sellMono == monoIsCurrency0;
    }

    function _swapExactIn(bool sellMono, uint256 amountIn) internal {
        bool zeroForOne = _dir(sellMono);
        swapper.swap(
            key,
            SwapParams(
                zeroForOne, -int256(amountIn), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    function _swapExactOut(bool sellMono, uint256 amountOut) internal {
        bool zeroForOne = _dir(sellMono);
        swapper.swap(
            key,
            SwapParams(
                zeroForOne, int256(amountOut), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    function _liveTick() internal view returns (int24 tick) {
        (, tick,,) = IPoolManager(address(manager)).getSlot0(id);
    }

    function _mean(IMonoHook.Horizon h) internal view returns (int24) {
        return hook.meanTick(id, h);
    }

    /// @dev Tick distance in the direction a MONO sale pushes the pool. Which way that is depends
    ///      on whether MONO sorted into `currency0`, which is an accident of deploy addresses —
    ///      so every price assertion below is written in this frame instead of in raw ticks.
    function _fall(int24 t) internal view returns (int256) {
        return monoIsCurrency0 ? -int256(t) : int256(t);
    }

    function _timelocked(bytes memory data) internal {
        hook.queue(data);
        vm.warp(block.timestamp + hook.TIMELOCK_DELAY());
        hook.execute(data);
    }

    // ================================================================ oracle

    /// The oracle is live from initialize, not from the first swap. This is what retires the old
    /// `min(elapsed, target)` bootstrap ramp — there is no warm-up window left to cover.
    function test_seedsAtInitializeSoThereIsNoDarkWindow() public view {
        assertEq(_mean(IMonoHook.Horizon.Strike), 0);
        assertEq(_mean(IMonoHook.Horizon.Throttle), 0);
        assertEq(_mean(IMonoHook.Horizon.Gate), 0);
    }

    function test_unknownPoolReverts() public {
        PoolKey memory other = key;
        other.tickSpacing = 10;
        vm.expectRevert(IMonoHook.NotInitialized.selector);
        hook.meanTick(other.toId(), IMonoHook.Horizon.Gate);
    }

    /// A pool that is not this vault's pair cannot mount this hook at all.
    function test_foreignPairCannotUseThisHook() public {
        MockIndex stranger = new MockIndex("Stranger", "STR", 1e24);
        (Currency c0, Currency c1) = address(stranger) < address(idx)
            ? (Currency.wrap(address(stranger)), Currency.wrap(address(idx)))
            : (Currency.wrap(address(idx)), Currency.wrap(address(stranger)));
        PoolKey memory foreign = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(hook)));

        vm.expectRevert();
        manager.initialize(foreign, TickMath.getSqrtPriceAtTick(0));
    }

    /// The point of the fast/slow pair: the same displacement reaches them at different speeds.
    function test_strikeLeadsTheSlowHorizon() public {
        _swapExactIn(true, 1e19);
        int24 live = _liveTick();
        assertGt(_fall(live), 100, "setup: price did not move");

        vm.warp(block.timestamp + 2 minutes);
        _swapExactIn(true, 1); // nudge, to force an accrual

        int256 s = _fall(_mean(IMonoHook.Horizon.Strike));
        int256 t = _fall(_mean(IMonoHook.Horizon.Throttle));

        assertGt(s, t, "strike must lead the slow horizon");
        assertGt(t, 0, "the slow horizon must have moved at all");
        assertLt(s, _fall(live), "strike cannot overshoot the live tick");
    }

    /// §4: "gate and throttle read one EMA". Not merely equal at the final values — the SAME
    /// reading, at every point of a displacement, which is what one EMA means.
    function test_gateAndThrottleAreOneEma() public {
        assertEq(_mean(IMonoHook.Horizon.Gate), _mean(IMonoHook.Horizon.Throttle), "at rest");

        _swapExactIn(true, 1e19);
        for (uint256 i; i < 4; ++i) {
            vm.warp(block.timestamp + 90);
            _swapExactIn(true, 1);
            assertEq(
                _mean(IMonoHook.Horizon.Gate), _mean(IMonoHook.Horizon.Throttle), "mid-decay they must not diverge"
            );
        }
    }

    /// A displacement pushed and released inside ONE block moves nothing: the tick that accrues is
    /// the one that STOOD for the elapsed seconds, and this one stood for zero. This is the core
    /// defense — with it there is no atomic manipulation path at any τ.
    function test_intraBlockSpikeCostsTheOracleNothing() public {
        _swapExactIn(true, 1e19);
        assertGt(_fall(_liveTick()), 100, "setup: price did not move");
        _swapExactIn(false, 1e19); // same block, back up

        vm.warp(block.timestamp + 15 minutes);
        // Not exactly 0: a round trip pays the tax twice, so the pool does not land back on tick
        // 0. That residue is real price movement, and a few ticks of it is all there is.
        assertApproxEqAbs(
            _fall(_mean(IMonoHook.Horizon.Gate)), int256(0), 60, "an intra-block round trip must be near-free"
        );
    }

    /// The control for the test above: the SAME displacement, held across a block boundary, does
    /// move the reading — so the test above is measuring intra-block-ness, not a dead oracle.
    function test_heldDisplacementDoesMoveTheReading() public {
        _swapExactIn(true, 1e19);
        int24 live = _liveTick();
        vm.warp(block.timestamp + 15 minutes);
        // 15min against tau = 15min is 1 - exp(-1) = 63% of the way.
        assertGt(_fall(_mean(IMonoHook.Horizon.Gate)), _fall(live) / 2, "a held displacement must move the gate");
    }

    function test_readAccruesWithoutASwap() public {
        _swapExactIn(true, 1e19);
        int256 before = _fall(_mean(IMonoHook.Horizon.Strike));
        vm.warp(block.timestamp + 1 minutes);
        assertGt(_fall(_mean(IMonoHook.Horizon.Strike)), before, "read must accrue on time alone");
    }

    function test_convergesToTheStandingPrice() public {
        _swapExactIn(true, 1e19);
        int24 live = _liveTick();
        vm.warp(block.timestamp + 30 days);
        assertApproxEqAbs(_mean(IMonoHook.Horizon.Gate), live, 1, "gate must converge");
        assertApproxEqAbs(_mean(IMonoHook.Horizon.Strike), live, 1, "strike must converge");
    }

    function test_sqrtPriceMatchesTheMeanTick() public view {
        assertEq(
            hook.meanSqrtPriceX96(id, IMonoHook.Horizon.Gate),
            TickMath.getSqrtPriceAtTick(_mean(IMonoHook.Horizon.Gate))
        );
    }

    /// The view and the write must agree: what `meanTick` shows a second before a swap is exactly
    /// what that swap's `beforeSwap` commits to storage. Otherwise the preview lies.
    function test_readAgreesWithTheNextWrite() public {
        _swapExactIn(true, 1e19);
        vm.warp(block.timestamp + 3 minutes);

        int24 previewed = _mean(IMonoHook.Horizon.Throttle);
        _swapExactIn(true, 1);
        assertEq(_mean(IMonoHook.Horizon.Throttle), previewed, "preview must equal the committed value");
    }

    /// @dev Asserts only that it does not deploy. `BaseHook`'s address check is a base-constructor
    ///      and runs first, so the surfaced error is its one, not `InvalidHorizons`.
    function test_transposedHorizonsDoNotDeploy() public {
        vm.expectRevert();
        this.deployWithHorizons(TAU_SLOW, TAU_STRIKE);
    }

    /// Equal horizons are a collapse, not a configuration: the fast leg would stop being fast and
    /// `max(spot, EMA_1m)` would read a 5-minute price.
    function test_equalHorizonsDoNotDeploy() public {
        vm.expectRevert();
        this.deployWithHorizons(TAU_SLOW, TAU_SLOW);
    }

    /// The §4 numbers, which the old strictly-increasing triple could not express: gate and
    /// throttle are both 5 minutes, so they are one EMA rather than two that must be kept in step.
    function test_horizonsAreTheHandbookNumbers() public view {
        assertEq(hook.tauStrike(), 60);
        assertEq(hook.tauSlow(), 300);
        assertLt(hook.tauStrike(), hook.tauSlow());
    }

    function deployWithHorizons(uint32 s_, uint32 slow_) external {
        deployCodeTo(
            "MonoHook.sol:MonoHook",
            abi.encode(IPoolManager(address(manager)), mono, treasury, s_, slow_),
            address(uint160(0x5555 << 144) | HOOK_FLAGS)
        );
    }

    // ================================================================ tax curve

    /// The launch anchors, checked against the round trips the ruling states.
    function test_launchAnchorsMatchTheRuling() public view {
        // At book: buy 2.0% + sell 0.5% = 2.5%.
        assertEq(hook.taxRate(true, 1e18), 20_000);
        assertEq(hook.taxRate(false, 1e18), 5_000);
        // At 2x: buy flat at 1.5%, sell halfway up its ramp at 2.5% = 4%.
        assertEq(hook.taxRate(true, 2e18), 15_000);
        assertEq(hook.taxRate(false, 2e18), 25_000);
        // At 3x and above: 1.5% + 4.5% = 6%.
        assertEq(hook.taxRate(true, 3e18), 15_000);
        assertEq(hook.taxRate(false, 3e18), 45_000);
    }

    function test_curveClampsFlatOutsideAnchors() public view {
        // Below `mStart` both sides hold their opening rate — including a MONO trading under book.
        assertEq(hook.taxRate(false, 0.5e18), 5_000);
        assertEq(hook.taxRate(true, 0.5e18), 20_000);
        // Above `mEnd` both sides hold their closing rate, forever.
        assertEq(hook.taxRate(false, 100e18), 45_000);
        assertEq(hook.taxRate(true, 100e18), 15_000);
    }

    /// Continuous, with no step anywhere: the reason the stepped zones were dropped.
    function test_curveIsMonotoneAndContinuous() public view {
        uint256 prev = hook.taxRate(false, 1e18);
        for (uint256 m = 1.05e18; m <= 3e18; m += 0.05e18) {
            uint256 r = hook.taxRate(false, m);
            assertGe(r, prev, "sell curve must not fall");
            assertLe(r - prev, 1_100, "no step: 0.05x of mNAV moves the rate by ~0.1%");
            prev = r;
        }
    }

    // ================================================================ tax rate input

    /// The tax reads vault NAV off balances and the pool off spot — never the accumulator. Moving
    /// NAV with a donation must reprice the tax in the same block, while the EMA does not budge.
    function test_taxReadsNavFromBalancesNotTheOracle() public {
        uint256 mBefore = hook.mNav(key);
        int24 emaBefore = _mean(IMonoHook.Horizon.Strike);
        assertEq(mBefore, 1e18, "spot 1:1 over NAV 1.0 is mNAV 1.0");

        // A donation is the one thing that lifts NAV with no swap and no time passing.
        idx.transfer(address(mono), 1e24); // doubles the pot, so NAV doubles
        assertEq(mono.nav(), 2e18, "donation must double NAV");

        assertEq(hook.mNav(key), 0.5e18, "mNAV must halve in the same block");
        assertEq(_mean(IMonoHook.Horizon.Strike), emaBefore, "the oracle must be untouched by it");
        // And the rate follows the new mNAV, clamped to the low anchor.
        assertEq(hook.taxRate(false, hook.mNav(key)), 5_000);
    }

    // ================================================================ collection

    /// Buy tax arrives in INDEX, sell tax in MONO — the input token of each swap, which is what
    /// makes the vault/burn split in `crank` possible at all.
    function test_buyTaxIsTakenInIndex() public {
        _swapExactIn(false, 1e18); // buy MONO with INDEX
        // Exactly 2% of the input at mNAV 1.0 — the buy anchor.
        assertEq(idx.balanceOf(address(hook)), 0.02e18, "buy tax must arrive in INDEX");
        assertEq(mono.balanceOf(address(hook)), 0, "a buy must not collect MONO");
    }

    function test_sellTaxIsTakenInMono() public {
        _swapExactIn(true, 1e18); // sell MONO for INDEX
        // Exactly 0.5% of the input at mNAV 1.0 — the sell anchor.
        assertEq(mono.balanceOf(address(hook)), 0.005e18, "sell tax must arrive in MONO");
        assertEq(idx.balanceOf(address(hook)), 0, "a sell must not collect INDEX");
    }

    /// The exact-OUTPUT path. It cannot be served from `beforeSwap` — the input amount is not
    /// known until the swap has run — so it is the one thing `afterSwap` exists for.
    function test_exactOutputIsAlsoTaxedOnTheInputToken() public {
        _swapExactOut(false, 1e18); // buy exactly 1 MONO, paying INDEX
        uint256 fee = idx.balanceOf(address(hook));
        assertGt(fee, 0, "an exact-output buy must still be taxed");
        assertEq(mono.balanceOf(address(hook)), 0, "and taxed on the INPUT token, not the output");
        // ~2% of the ~1e18 INDEX it took to buy one MONO at book.
        assertApproxEqRel(fee, 0.02e18, 0.02e18, "roughly the 2% buy rate on the input");
    }

    // ================================================================ crank

    function test_crankSendsTheVaultShareOfIndexToBackingAndTheRestToTreasury() public {
        _swapExactIn(false, 1e18);
        uint256 collected = idx.balanceOf(address(hook));
        uint256 potBefore = mono.totalIndex();
        uint256 navBefore = mono.nav();

        (uint256 swept,) = hook.crank();

        assertEq(swept, collected);
        assertEq(mono.totalIndex(), potBefore + (collected * 7_000) / 10_000, "70% must land as backing");
        assertEq(idx.balanceOf(treasury), collected - (collected * 7_000) / 10_000, "30% to treasury");
        assertEq(idx.balanceOf(address(hook)), 0, "nothing left behind");
        assertGt(mono.nav(), navBefore, "the vault share must lift NAV");
    }

    function test_crankBurnsTheVaultShareOfMonoBecauseTheVaultMayNotHoldIt() public {
        _swapExactIn(true, 1e18);
        uint256 collected = mono.balanceOf(address(hook));
        uint256 supplyBefore = mono.totalSupply();
        uint256 navBefore = mono.nav();

        (, uint256 burned) = hook.crank();

        assertEq(burned, (collected * 7_000) / 10_000);
        assertEq(mono.totalSupply(), supplyBefore - burned, "the vault's share is retired, not banked");
        assertEq(mono.balanceOf(treasury), collected - burned, "30% to treasury, in MONO");
        assertEq(mono.balanceOf(address(mono)), 0, "the vault must never hold MONO");
        assertGt(mono.nav(), navBefore, "burning lifts NAV from the other side");
    }

    function test_crankIsPermissionless() public {
        _swapExactIn(false, 1e18);
        vm.prank(address(0xBEEF));
        hook.crank();
        assertEq(idx.balanceOf(address(hook)), 0);
    }

    // ================================================================ timelocked admin

    function test_settersAreUnreachableWithoutTheTimelock() public {
        IMonoHook.Curve memory c = IMonoHook.Curve(1e18, 2e18, 1_000, 2_000);
        vm.expectRevert(IMonoHook.NotTimelocked.selector);
        hook.setCurve(false, c);
        vm.expectRevert(IMonoHook.NotTimelocked.selector);
        hook.setVaultShareBips(6_000);
        vm.expectRevert(IMonoHook.NotTimelocked.selector);
        hook.setTreasury(address(0xABCD));
    }

    function test_executeBeforeTheDelayReverts() public {
        bytes memory data = abi.encodeCall(IMonoHook.setCurve, (false, IMonoHook.Curve(1e18, 2e18, 1_000, 2_000)));
        hook.queue(data);
        vm.warp(block.timestamp + hook.TIMELOCK_DELAY() - 1);
        vm.expectRevert(IMonoHook.TimelockPending.selector);
        hook.execute(data);
    }

    function test_timelockedCurveChangeLands() public {
        _timelocked(abi.encodeCall(IMonoHook.setCurve, (false, IMonoHook.Curve(1e18, 2e18, 1_000, 2_000))));
        assertEq(hook.taxRate(false, 1e18), 1_000);
        assertEq(hook.taxRate(false, 2e18), 2_000);
    }

    /// The ceiling is the one number governance cannot reach, on either anchor.
    function test_curveAboveTheCeilingIsRejected() public {
        bytes memory data = abi.encodeCall(IMonoHook.setCurve, (false, IMonoHook.Curve(1e18, 2e18, 1_000, 50_001)));
        hook.queue(data);
        vm.warp(block.timestamp + hook.TIMELOCK_DELAY());
        vm.expectRevert(IMonoHook.InvalidCurve.selector);
        hook.execute(data);
    }

    function test_invertedAnchorsAreRejected() public {
        bytes memory data = abi.encodeCall(IMonoHook.setCurve, (false, IMonoHook.Curve(2e18, 2e18, 1_000, 2_000)));
        hook.queue(data);
        vm.warp(block.timestamp + hook.TIMELOCK_DELAY());
        vm.expectRevert(IMonoHook.InvalidCurve.selector);
        hook.execute(data);
    }

    function test_vaultShareCannotGoBelowHalf() public {
        bytes memory data = abi.encodeCall(IMonoHook.setVaultShareBips, (4_999));
        hook.queue(data);
        vm.warp(block.timestamp + hook.TIMELOCK_DELAY());
        vm.expectRevert(IMonoHook.InvalidShare.selector);
        hook.execute(data);

        _timelocked(abi.encodeCall(IMonoHook.setVaultShareBips, (5_000)));
        assertEq(hook.vaultShareBips(), 5_000);
    }

    // ================================================================ cost

    /// What the hook costs a swapper, against the identical pair with no hook at all. The bound is
    /// a regression guard, not a target — see `agent-docs/MonoHook.md`.
    function test_hookOverheadPerSwap() public {
        PoolKey memory bare = PoolKey(key.currency0, key.currency1, 0, 60, IHooks(address(0)));
        manager.initialize(bare, TickMath.getSqrtPriceAtTick(0));
        liq.modifyLiquidity(bare, ModifyLiquidityParams(-60000, 60000, 1e21, bytes32(0)), "");

        // Warm every account and slot inside THIS transaction first; otherwise whichever pool is
        // measured first simply pays the cold-access bill for both.
        _swapBare(bare);
        _swapExactIn(true, 1e16);
        vm.warp(block.timestamp + 60);

        uint256 g = gasleft();
        _swapBare(bare);
        uint256 bareGas = g - gasleft();

        vm.warp(block.timestamp + 60);
        g = gasleft();
        _swapExactIn(true, 1e16);
        uint256 hookGas = g - gasleft();

        emit log_named_uint("bare swap  ", bareGas);
        emit log_named_uint("hooked swap", hookGas);
        emit log_named_uint("overhead   ", hookGas - bareGas);
        assertLt(hookGas - bareGas, 60_000, "the hook got materially more expensive");
    }

    function _swapBare(PoolKey memory bare) internal {
        bool zeroForOne = _dir(true);
        swapper.swap(
            bare,
            SwapParams(
                zeroForOne, -int256(1e16), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    /// The address IS the permission set, and `script/DeployMonoHook.s.sol` mines for one specific
    /// flag word. If that word and `getHookPermissions()` ever drift apart, `BaseHook`'s
    /// constructor rejects the mined address — on deploy day, against a pool that can never be
    /// re-hooked. Mining and deploying for real here is what proves they agree.
    function test_theMinedAddressSatisfiesTheHookItDeploys() public {
        // Kept identical to the script's `flags`, and to `agent-docs/MonoHook.md`'s 0x10CC.
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        assertEq(flags, 0x10CC, "the documented flag word");

        bytes memory args = abi.encode(IPoolManager(address(manager)), mono, treasury, TAU_STRIKE, TAU_SLOW);
        (address mined, bytes32 salt) = HookMiner.find(address(this), flags, type(MonoHook).creationCode, args);

        // `BaseHook`'s constructor asserts the deployed address carries exactly the permissions
        // `getHookPermissions()` declares, so this line reverts if the mine was for the wrong set.
        MonoHook fresh = new MonoHook{salt: salt}(IPoolManager(address(manager)), mono, treasury, TAU_STRIKE, TAU_SLOW);
        assertEq(address(fresh), mined, "mined address not hit");
        assertEq(uint160(address(fresh)) & 0x3FFF, flags, "the address does not carry the flags");
    }

    function test_onlyOwnerMayQueue() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        hook.queue(abi.encodeCall(IMonoHook.setVaultShareBips, (6_000)));
    }
}

/// @notice The entire suite again with MONO as `currency1`, so the pool quotes MONO per INDEX and
///         every price read has to invert. Orientation is an accident of deploy addresses in
///         production; here it is both cases.
contract MonoHookFlippedTest is MonoHookTest {
    function monoFirst() internal pure override returns (bool) {
        return false;
    }
}
