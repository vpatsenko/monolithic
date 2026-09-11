// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BaseHook} from "v4-periphery/utils/BaseHook.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {IMono} from "./interfaces/IMono.sol";
import {IMonoHook} from "./interfaces/IMonoHook.sol";

/// @title MonoHook
/// @notice The MONO/INDEX hook: the price accumulator of HANDBOOK §3.6 and the trade tax of §3.4,
///         in one contract because a v4 hook's permissions are encoded in its ADDRESS, the address
///         is inside the `PoolKey`, and a pool can never be re-hooked. Anything this hook cannot
///         do on the day it ships, it can never do — see `MONOHOOK-REVIEW.md` §3.
/// @dev The mechanism is `agent-docs/MonoHook.md`. Four things a reader needs:
///
///      1. THE ORACLE IS AN EMA, NOT A RING BUFFER. v3's oracle is an array of `tickCumulative`
///         samples with a binary search over it, and it has to be `grow()`n to span its window —
///         which anyone can grief, and which fails CLOSED (`OLD`) when it has not been grown
///         enough, taking the gate dark. An exponential moving average in tick space is one slot,
///         forever, at any horizon, with nothing to grow and nothing to search.
///
///      2. THE PRICE THAT ACCRUES IS THE PRE-SWAP ONE. `beforeSwap` reads the tick the pool is
///         sitting on — the price that has STOOD since `lastUpdate` — and accrues that over the
///         elapsed seconds. The tick a swap is about to move to has been true for zero seconds and
///         is worth zero. So a price pushed and released inside one block contributes NOTHING: to
///         move this reading you must hold the displacement across a block boundary, exposed to
///         arbitrage the whole time. There is no atomic path, which is the load-bearing half of
///         why τ can be minutes rather than hours.
///
///      3. THE TAX IS A CONTINUOUS CURVE AND IT READS SPOT, NOT A TWAP. Stepped mNAV zones put a
///         front-runnable boundary on the chart; a lerp between two anchors has none. And the
///         rate input is spot over book on purpose: pushing the price towards a cheaper rate IS
///         the taxed trade, so the manipulation pays for itself, while a lagging reference would
///         invent an exploit that the live read does not have.
///
///      4. THE TAX IS TAKEN BY THE HOOK, NOT CHARGED AS AN LP FEE. An LP fee accrues to liquidity
///         providers. That is harmless while the pool is 100% POL and a silent siphon the moment
///         it is not, so the hook takes the fee itself, in the INPUT token, whoever is LPing.
///
///      ponytail: the fee is `take`n as real ERC-20 on every taxed swap rather than minted as an
///      ERC-6909 claim and settled in the crank. Claims would save perhaps 8k gas a swap at the
///      cost of an `unlockCallback` and a second accounting surface; `balanceOf` being the whole
///      ledger is worth more here. Revisit if swap gas ever becomes the binding constraint.
contract MonoHook is IMonoHook, BaseHook, Ownable {
    using StateLibrary for IPoolManager;
    using SafeTransferLib for address;

    /// @dev 1e6 leaves the stored EMAs at most `887272e6` ~ 8.9e11, ten million times inside
    ///      `int64`, while resolving a millionth of a tick — a tick is already only 1bp.
    int256 public constant override PRECISION = 1e6;

    uint256 public constant override PIPS = 1e6;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BIPS = 10_000;
    uint256 internal constant Q96 = 1 << 96;

    /// @notice 5% a side. Deliberately not settable: the anchors move forever, the ceiling never.
    uint32 public constant override MAX_TAX_PIPS = 50_000;

    /// @notice The vault can never be voted below half the take. Burning counts as vault-side.
    uint16 public constant override MIN_VAULT_BIPS = 5_000;

    /// @dev Same notice period as `Index`. Not settable — a timelock whose length the owner can
    ///      shorten on demand is not a timelock.
    uint256 public constant override TIMELOCK_DELAY = 2 days;

    IMono public immutable override mono;
    address public immutable override index;

    uint32 public immutable override tauStrike;
    uint32 public immutable override tauThrottle;
    uint32 public immutable override tauGate;

    mapping(PoolId id => Observation) public override observations;

    Curve public override buyTax;
    Curve public override sellTax;

    uint16 public override vaultShareBips;
    address public override treasury;

    mapping(bytes32 => uint256) public override queuedAt;

    constructor(
        IPoolManager manager_,
        IMono mono_,
        address treasury_,
        uint32 tauStrike_,
        uint32 tauThrottle_,
        uint32 tauGate_
    ) BaseHook(manager_) Ownable(msg.sender) {
        if (address(mono_) == address(0) || treasury_ == address(0)) revert InvalidParams();
        // Strictly increasing: the three horizons are only meaningful as fast/medium/slow, and a
        // deployment that transposed two would read plausibly and gate wrongly.
        if (tauStrike_ == 0 || tauStrike_ >= tauThrottle_ || tauThrottle_ >= tauGate_) revert InvalidHorizons();

        mono = mono_;
        index = address(mono_.index());
        treasury = treasury_;
        tauStrike = tauStrike_;
        tauThrottle = tauThrottle_;
        tauGate = tauGate_;
        vaultShareBips = 7_000;

        // D24 launch anchors. Sell rises with the premium — the profit-taker at 3x book is the
        // primary NAV engine. Buy falls, so the vault is cheapest to enter when it needs entrants
        // most. Round trip: 2.5% at book, 4% at 2x, 6% at 3x and above.
        _setCurve(false, Curve({mStart: 1e18, mEnd: 3e18, rateStart: 5_000, rateEnd: 45_000}));
        _setCurve(true, Curve({mStart: 1e18, mEnd: 1.5e18, rateStart: 20_000, rateEnd: 15_000}));
    }

    /// @dev Reachable only through `execute`, which is the only caller that can be `address(this)`.
    ///      So the owner cannot call these directly — they must queue and wait out TIMELOCK_DELAY.
    modifier timelocked() {
        if (msg.sender != address(this)) revert NotTimelocked();
        _;
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            // Seed from the pool's opening price, so the oracle is live before the first swap
            // rather than dark until one arrives. This is also what retires the old `min(elapsed,
            // target)` bootstrap ramp: there is no warm-up window left for one to cover.
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            // Only for exact-OUTPUT swaps, where the input amount is not knowable until the swap
            // has run. The accumulator itself needs no `afterSwap` — see `_afterSwap`.
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            // The tax. Taking the fee in the input token needs the specified leg on exact-input
            // and the unspecified leg on exact-output, so both bits are load-bearing.
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------- hooks

    /// @dev Refuses any pair that is not this vault's. Without it anyone could stand up a pool on
    ///      this hook and have it tax and price a token it knows nothing about.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        bool paired = (c0 == address(mono) && c1 == index) || (c1 == address(mono) && c0 == index);
        if (!paired) revert WrongPair();

        PoolId id = key.toId();
        int64 e = SafeCastLib.toInt64(int256(tick) * PRECISION);
        observations[id] = Observation({
            emaStrike: e, emaThrottle: e, emaGate: e, lastUpdate: uint32(block.timestamp), initialized: true
        });
        emit ObservationSeeded(id, tick);
        return IHooks.afterInitialize.selector;
    }

    /// @dev Accrue the oracle at the price that stood, then tax an exact-INPUT swap.
    ///
    ///      The accrual comes first and reads the pre-swap tick; several swaps in one block reach
    ///      the `dt == 0` case, so the block's closing price is what starts accruing next block.
    ///
    ///      The tax is only charged here when `amountSpecified < 0`. Exact-output swaps do not yet
    ///      know how much input they will consume, so their tax is charged in `_afterSwap`.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        _accrue(id);

        // Exact output: the input amount is not known until the swap has run.
        if (params.amountSpecified >= 0) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        uint256 fee = _takeTax(key, id, params.zeroForOne, uint256(-params.amountSpecified));
        // Positive on the SPECIFIED leg: on an exact-input swap the specified currency is the
        // input, so this shrinks what the pool swaps and credits the difference to this hook.
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(SafeCastLib.toInt128(int256(fee)), 0), 0);
    }

    /// @dev Exact-OUTPUT swaps only. The accumulator wants nothing from here — the only tick it
    ///      ever needs is the one standing before a swap — but the input amount of an exact-output
    ///      swap is only knowable now, and the tax is charged in the input token.
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        if (params.amountSpecified < 0) return (IHooks.afterSwap.selector, 0);

        // The payer's leg is negative, and on an exact-output swap it is the unspecified one.
        int128 paid = params.zeroForOne ? delta.amount0() : delta.amount1();
        if (paid >= 0) return (IHooks.afterSwap.selector, 0);

        uint256 fee = _takeTax(key, key.toId(), params.zeroForOne, uint256(uint128(-paid)));
        // Positive on the UNSPECIFIED leg, which for an exact-output swap is the input currency.
        // The swapper pays this on top of what the pool charged them.
        return (IHooks.afterSwap.selector, SafeCastLib.toInt128(int256(fee)));
    }

    // ---------------------------------------------------------------- tax

    /// @dev Price the input side of a swap and pull the fee out of the PoolManager.
    ///
    ///      Nothing in here may revert. A tax that can revert is a pool that can be bricked, so
    ///      every input is either bounded by construction (`rate <= MAX_TAX_PIPS`) or degrades to
    ///      a rate rather than an error (`_mNav` answers 0 for an unpriceable vault, which clamps
    ///      both curves to their `mStart` anchor).
    /// @return fee Taken in the input currency and now held by this contract.
    function _takeTax(PoolKey calldata key, PoolId id, bool zeroForOne, uint256 amountIn)
        internal
        returns (uint256 fee)
    {
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        // Buying MONO means paying INDEX in. Selling means paying MONO in.
        bool isBuy = Currency.unwrap(input) == index;

        uint256 rate = _rate(isBuy ? buyTax : sellTax, _mNav(key, id));
        fee = FixedPointMathLib.fullMulDiv(amountIn, rate, PIPS);
        if (fee == 0) return 0;

        // Settles the hook's own delta against the credit the returned delta is about to create.
        // Both legs land inside the same unlock, so the net is zero and nothing is left owed.
        poolManager.take(input, address(this), fee);
    }

    /// @inheritdoc IMonoHook
    function taxRate(bool isBuy, uint256 m) external view override returns (uint256) {
        return _rate(isBuy ? buyTax : sellTax, m);
    }

    /// @dev Linear between the anchors, flat outside them. Signed span, because the buy side falls
    ///      with mNAV while the sell side rises.
    function _rate(Curve memory c, uint256 m) internal pure returns (uint256) {
        if (m <= c.mStart) return c.rateStart;
        if (m >= c.mEnd) return c.rateEnd;
        int256 span = int256(uint256(c.rateEnd)) - int256(uint256(c.rateStart));
        int256 moved = span * int256(m - c.mStart) / int256(uint256(c.mEnd) - uint256(c.mStart));
        return uint256(int256(uint256(c.rateStart)) + moved);
    }

    /// @inheritdoc IMonoHook
    function mNav(PoolKey calldata key) external view override returns (uint256) {
        return _mNav(key, key.toId());
    }

    /// @dev Spot over book, in WAD. Both legs are 18 decimals — MONO and INDEX each take solady's
    ///      default — so the unit scaling cancels and WAD is the only factor left.
    function _mNav(PoolKey calldata key, PoolId id) internal view returns (uint256) {
        uint256 nav = mono.nav();
        if (nav == 0) return 0;

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        if (sqrtPriceX96 == 0) return 0;

        // The square only fits as a 512-bit intermediate: `sqrtPriceX96` reaches 2**160, so the
        // product reaches 2**320. This is currency1 per currency0, in Q96.
        uint256 ratioX96 = FixedPointMathLib.fullMulDiv(sqrtPriceX96, sqrtPriceX96, Q96);
        if (ratioX96 == 0) return 0;

        uint256 spot = Currency.unwrap(key.currency0) == address(mono)
            // INDEX per MONO already.
            ? FixedPointMathLib.fullMulDiv(ratioX96, WAD, Q96)
            // MONO per INDEX — invert it.
            : FixedPointMathLib.fullMulDiv(WAD, Q96, ratioX96);

        return FixedPointMathLib.fullMulDiv(spot, WAD, nav);
    }

    /// @inheritdoc IMonoHook
    function crank() external override returns (uint256 indexSwept, uint256 monoBurned) {
        uint256 share = vaultShareBips;

        indexSwept = index.balanceOf(address(this));
        if (indexSwept != 0) {
            uint256 toVault = FixedPointMathLib.fullMulDiv(indexSwept, share, BIPS);
            // `Mono` has no entry point for INDEX, so a plain transfer is pure backing: supply
            // unchanged, pot larger, NAV up. That is the whole tax-sweep mechanism.
            if (toVault != 0) index.safeTransfer(address(mono), toVault);
            if (indexSwept - toVault != 0) index.safeTransfer(treasury, indexSwept - toVault);
        }

        uint256 held = address(mono).balanceOf(address(this));
        if (held != 0) {
            // The vault may never hold MONO `[LAW]`, so its share is retired instead of banked.
            // Same direction, other side of the ratio: supply down, NAV up.
            monoBurned = FixedPointMathLib.fullMulDiv(held, share, BIPS);
            if (monoBurned != 0) mono.burn(monoBurned);
            if (held - monoBurned != 0) address(mono).safeTransfer(treasury, held - monoBurned);
        }

        emit Cranked(indexSwept, monoBurned);
    }

    // ---------------------------------------------------------------- oracle

    /// @inheritdoc IMonoHook
    function meanTick(PoolId id, Horizon h) public view override returns (int24) {
        Observation memory o = observations[id];
        if (!o.initialized) revert NotInitialized();

        (int64 ema, uint32 tau) = _horizon(o, h);
        uint32 dt;
        unchecked {
            dt = uint32(block.timestamp) - o.lastUpdate;
        }

        int256 settled = int256(ema);
        if (dt != 0) {
            // The same accrual `_beforeSwap` would do, against the same live tick — so a pool
            // nobody has swapped in hours reads as the price actually standing rather than as a
            // stale average, and reading never disagrees with the next swap's write.
            (, int24 tick,,) = poolManager.getSlot0(id);
            settled = int256(_decay(ema, int256(tick) * PRECISION, dt, tau));
        }

        // Round half away from zero. Solidity truncates towards zero, so the sign has to be
        // carried into the bias or negative ticks would round the wrong way.
        int256 half = settled >= 0 ? PRECISION / 2 : -PRECISION / 2;
        return SafeCastLib.toInt24((settled + half) / PRECISION);
    }

    /// @inheritdoc IMonoHook
    function meanSqrtPriceX96(PoolId id, Horizon h) external view override returns (uint160) {
        return TickMath.getSqrtPriceAtTick(meanTick(id, h));
    }

    /// @dev Fold the seconds since `lastUpdate` into every horizon at the price that stood for
    ///      them, then stamp the clock.
    function _accrue(PoolId id) internal {
        Observation memory o = observations[id];

        uint32 nowTs = uint32(block.timestamp);
        uint32 dt;
        // Wraps in 2106, and wraps correctly: modular subtraction still gives the true elapsed
        // seconds unless a pool sits unswapped for 136 years. Same assumption v3 makes.
        unchecked {
            dt = nowTs - o.lastUpdate;
        }

        // `initialized` is always true here — this hook is inside the pool's own key, so
        // `_afterInitialize` ran first — but accruing against a zero tick would silently mean a
        // price of 1:1, which is worth one branch to make impossible.
        if (!o.initialized || dt == 0) return;

        (, int24 tick,,) = poolManager.getSlot0(id);
        int256 target = int256(tick) * PRECISION;
        o.emaStrike = _decay(o.emaStrike, target, dt, tauStrike);
        o.emaThrottle = _decay(o.emaThrottle, target, dt, tauThrottle);
        o.emaGate = _decay(o.emaGate, target, dt, tauGate);
        o.lastUpdate = nowTs;
        observations[id] = o;
    }

    function _horizon(Observation memory o, Horizon h) internal view returns (int64 ema, uint32 tau) {
        if (h == Horizon.Strike) return (o.emaStrike, tauStrike);
        if (h == Horizon.Throttle) return (o.emaThrottle, tauThrottle);
        return (o.emaGate, tauGate);
    }

    /// @dev One EMA step: `ema' = target + (ema - target) * exp(-dt/tau)`.
    ///
    ///      The cheap alternative is the Padé form `tau / (dt + tau)`, which needs no exponential.
    ///      It is not used: it is only first-order, so over a long silence it leaves a residual
    ///      gap of `tau / (dt + tau)` where the truth is `exp(-dt/tau)` — at τ of a minute a pool
    ///      quiet for an hour would still read 1.6% of the way back to an hour-stale price.
    ///      `expWad` is one solady call, already a dependency, and it is exact.
    ///
    ///      `expWad` saturates to 0 below `exp(-41.4)` rather than reverting, which is the right
    ///      behaviour: past ~41 time constants the old reading genuinely is gone.
    function _decay(int64 ema, int256 target, uint32 dt, uint32 tau) internal pure returns (int64) {
        int256 factor = FixedPointMathLib.expWad(-(int256(uint256(dt)) * 1e18) / int256(uint256(tau)));
        // A convex combination of `ema` and `target`, so it is bounded by the wider of the two and
        // cannot leave the tick range both came from.
        return SafeCastLib.toInt64(target + (int256(ema) - target) * factor / 1e18);
    }

    // ---------------------------------------------------------------- timelocked admin

    /// @inheritdoc IMonoHook
    function setCurve(bool isBuy, Curve calldata c) external override timelocked {
        _setCurve(isBuy, c);
    }

    function _setCurve(bool isBuy, Curve memory c) internal {
        // The ceiling is the one number governance cannot reach. Everything else about the shape
        // is theirs to move.
        if (c.rateStart > MAX_TAX_PIPS || c.rateEnd > MAX_TAX_PIPS) revert InvalidCurve();
        // `mStart == mEnd` would divide by zero; `mStart > mEnd` would run the lerp backwards.
        if (c.mStart == 0 || c.mStart >= c.mEnd) revert InvalidCurve();

        if (isBuy) buyTax = c;
        else sellTax = c;
        emit CurveSet(isBuy, c);
    }

    /// @inheritdoc IMonoHook
    function setVaultShareBips(uint16 bips) external override timelocked {
        if (bips < MIN_VAULT_BIPS || bips > BIPS) revert InvalidShare();
        vaultShareBips = bips;
        emit VaultShareSet(bips);
    }

    /// @inheritdoc IMonoHook
    function setTreasury(address treasury_) external override timelocked {
        if (treasury_ == address(0)) revert InvalidParams();
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    /// @inheritdoc IMonoHook
    function queue(bytes calldata data) external override onlyOwner returns (bytes32 id) {
        id = keccak256(data);
        if (queuedAt[id] != 0) revert AlreadyQueued();
        queuedAt[id] = block.timestamp;
        emit Queued(id, data, block.timestamp + TIMELOCK_DELAY);
    }

    /// @inheritdoc IMonoHook
    function cancel(bytes calldata data) external override onlyOwner {
        bytes32 id = keccak256(data);
        if (queuedAt[id] == 0) revert NotQueued();
        delete queuedAt[id];
        emit Cancelled(id);
    }

    /// @inheritdoc IMonoHook
    function execute(bytes calldata data) external override onlyOwner returns (bytes memory result) {
        bytes32 id = keccak256(data);
        uint256 at = queuedAt[id];
        if (at == 0) revert NotQueued();
        if (block.timestamp < at + TIMELOCK_DELAY) revert TimelockPending();
        delete queuedAt[id];

        bool ok;
        (ok, result) = address(this).call(data);
        if (!ok) {
            // Surface the target's own revert, so a change that went stale during the notice
            // period fails with `InvalidCurve` rather than an opaque failure.
            assembly {
                revert(add(result, 0x20), mload(result))
            }
        }
        emit Executed(id);
    }
}
