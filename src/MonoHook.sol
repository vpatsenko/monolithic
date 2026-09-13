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
/// @dev The mechanism is `agent-docs/MonoHook.md`. Five things a reader needs:
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
///      5. THE WALL DOES NOT COMPUTE THE SPLIT — IT ASKS THE POOL FOR IT. On a sell the hook
///         re-enters `poolManager.swap` on its own pool with `sqrtPriceLimitX96` set to the wall
///         price and lets v4's own engine take whatever it can down to that bound; the remainder
///         comes off the vault. So "the pool never ends below the wall" is enforced by the price
///         limit, exactly, across any liquidity shape — no `dx = L(1/sqrtT - 1/sqrtC)` of our own
///         to get wrong, no single-range assumption (the one `Mono.premiumCloseAmount` carries),
///         and no special case for one-sided POL: with no bid liquidity the inner swap simply
///         takes nothing and the wall fills all of it. The re-entry needs no guard of ours —
///         `Hooks.beforeSwap`/`afterSwap` both open with `if (msg.sender == address(self))
///         return`, so v4 skips a hook's own hooks.
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
    uint256 internal constant Q192 = 1 << 192;

    /// @notice 5% a side. Deliberately not settable: the anchors move forever, the ceiling never.
    uint32 public constant override MAX_TAX_PIPS = 50_000;

    /// @notice The vault can never be voted below half the take. Burning counts as vault-side.
    uint16 public constant override MIN_VAULT_BIPS = 5_000;

    /// @notice The wall can never be voted up to NAV. Strictly under `BIPS` is the whole law —
    ///         10% is simply far more headroom than the 0.5-1% operating range will ever want.
    uint16 public constant override MAX_WALL_TICK_BIPS = 1_000;

    /// @dev Same notice period as `Index`. Not settable — a timelock whose length the owner can
    ///      shorten on demand is not a timelock.
    uint256 public constant override TIMELOCK_DELAY = 2 days;

    IMono public immutable override mono;
    address public immutable override index;

    uint32 public immutable override tauStrike;
    /// @notice The gate's and the throttle's, which HANDBOOK §4 makes one and the same EMA.
    uint32 public immutable override tauSlow;

    mapping(PoolId id => Observation) public override observations;

    Curve public override buyTax;
    Curve public override sellTax;

    uint16 public override vaultShareBips;
    uint16 public override wallTickBips;
    address public override treasury;

    mapping(bytes32 => uint256) public override queuedAt;

    constructor(IPoolManager manager_, IMono mono_, address treasury_, uint32 tauStrike_, uint32 tauSlow_)
        BaseHook(manager_)
        Ownable(msg.sender)
    {
        if (address(mono_) == address(0) || treasury_ == address(0)) revert InvalidParams();
        // Strictly increasing: the two horizons are only meaningful as fast/slow, and a deployment
        // that transposed them would read plausibly and gate wrongly.
        if (tauStrike_ == 0 || tauStrike_ >= tauSlow_) revert InvalidHorizons();

        mono = mono_;
        index = address(mono_.index());
        treasury = treasury_;
        tauStrike = tauStrike_;
        tauSlow = tauSlow_;
        vaultShareBips = 7_000;
        // HANDBOOK 3.2 writes the burn leg as "0.99 x NAV", so 100 bips is the number the spec
        // spells out. `[SIM]` says 0.5-1%; this is the top of that range and timelocked downward.
        wallTickBips = 100;

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
        observations[id] =
            Observation({emaStrike: e, emaSlow: e, lastUpdate: uint32(block.timestamp), initialized: true});
        emit ObservationSeeded(id, tick);
        return IHooks.afterInitialize.selector;
    }

    /// @dev Accrue the oracle at the price that stood, tax an exact-INPUT swap, and stand the wall
    ///      up under a sell.
    ///
    ///      The accrual comes first and reads the pre-swap tick; several swaps in one block reach
    ///      the `dt == 0` case, so the block's closing price is what starts accruing next block.
    ///
    ///      The tax is only charged here when `amountSpecified < 0`. Exact-output swaps do not yet
    ///      know how much input they will consume, so their tax is charged in `_afterSwap`.
    ///
    ///      BUYS ARE UNTOUCHED by the wall and take the same one-line path they always did. Only a
    ///      sell forks, and only into `_wall`.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        _accrue(id);

        bool isSell = Currency.unwrap(params.zeroForOne ? key.currency0 : key.currency1) == address(mono);

        // Exact output: the input amount is not known until the swap has run.
        if (params.amountSpecified >= 0) {
            // HANDBOOK 3.3 allows either mirroring the split or refusing: "Exact-output sells:
            // mirror the split or revert when the wall would engage — never a path that leaves
            // the pool under the wall." We refuse. Mirroring means running the whole split a
            // second time in the output direction and moving the tax out of `_afterSwap` to pay
            // for it, which is a lot of consequential code for a path routers essentially never
            // take on a sell. Buys are unaffected, and so are exact-output sells before the
            // vault arms the wall.
            //
            // ponytail: refusal, not mirroring. Build the mirror if a real integrator turns up
            // needing exact-output sells; until then this is the branch that cannot be wrong.
            if (isSell && wallArmed()) revert ExactOutputSellUnsupported();
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        uint256 amountIn = uint256(-params.amountSpecified);
        // The tax is charged on the WHOLE input before the split, so it applies to the wall leg
        // exactly as HANDBOOK 3.3 requires ("Sell tax applies to wall fills") without the split
        // having to know anything about it.
        uint256 fee = _takeTax(key, id, params.zeroForOne, amountIn);

        // Positive on the SPECIFIED leg: on an exact-input swap the specified currency is the
        // input, so this shrinks what the pool swaps and credits the difference to this hook.
        BeforeSwapDelta taxOnly = toBeforeSwapDelta(SafeCastLib.toInt128(int256(fee)), 0);
        if (!isSell) return (IHooks.beforeSwap.selector, taxOnly, 0);

        (bool engaged, uint256 out) = _wall(key, id, params.zeroForOne, amountIn - fee);
        // Wall stood down (not armed, nothing to sell after tax, vault unpriceable): the plain
        // taxed swap runs, untouched. This is the "never bricks the pool" path, and it is chosen
        // BEFORE anything has moved, so there is nothing to unwind.
        if (!engaged) return (IHooks.beforeSwap.selector, taxOnly, 0);

        // The wall consumed the whole swap: the hook took all the input and owes all the output,
        // so the outer `Pool.swap` is handed `amountToSwap == 0` and returns without touching the
        // pool (it is already exactly where `_wall` left it).
        return (
            IHooks.beforeSwap.selector,
            toBeforeSwapDelta(SafeCastLib.toInt128(int256(amountIn)), -SafeCastLib.toInt128(int256(out))),
            0
        );
    }

    // ---------------------------------------------------------------- wall

    /// @inheritdoc IMonoHook
    function wallPrice() public view override returns (uint256) {
        // Rounding DOWN, so the wall never pays a wei more than `(1 - wallTick) x NAV`.
        return FixedPointMathLib.fullMulDiv(mono.nav(), BIPS - wallTickBips, BIPS);
    }

    /// @inheritdoc IMonoHook
    function wallArmed() public view override returns (bool) {
        // `Mono.setWall` sets this and grants the allowance in the same call, and refuses a
        // second one — so this is an exact reading of "the hook can pull from the vault", with no
        // allowance read needed. Solady does not erode a max allowance, so it never goes stale.
        return mono.wall() == address(this);
    }

    /// @dev The split fill of HANDBOOK 3.3 `[LAW]`, on a MONO -> INDEX sell of `net` (post-tax).
    ///
    ///      Rather than computing how much MONO takes the pool down to the wall, it asks the pool:
    ///      one re-entrant `swap` with the wall price as `sqrtPriceLimitX96`. Whatever the book
    ///      can absorb above the wall, it absorbs; the engine stops dead at the bound. The
    ///      leftover is the wall's, bought at the wall price off the vault's one allowance and
    ///      BURNED in this transaction.
    ///
    ///      WHY THE BURN IS THE LAW AND NOT AN OPTIMISATION. The vault pays `R x (1-t) x NAV` and
    ///      retires `R` shares, so the floor moves from `I/S` to `(I - R*w)/(S - R)`, which is
    ///      strictly greater for any `w < NAV`. Skip the burn and the same code is a redemption
    ///      that drains the pot. It is also why an unbounded allowance is safe: the only thing
    ///      this can do with it is raise NAV.
    /// @return engaged False when the wall stood down and the caller should fall through to a
    ///         plain taxed swap.
    /// @return out INDEX owed to the seller — the pool's leg plus the wall's.
    function _wall(PoolKey calldata key, PoolId id, bool zeroForOne, uint256 net)
        internal
        returns (bool engaged, uint256 out)
    {
        if (net == 0 || !wallArmed()) return (false, 0);
        uint256 price = wallPrice();
        if (price == 0) return (false, 0); // unpriceable vault: no bid to stand behind

        // The vault cannot be short — the bid is under NAV and nobody can sell more MONO than
        // exists, so the worst case is `S x (1-t) x I/S < I`. Checked anyway: this is the one
        // branch where being wrong would revert inside someone else's swap, and HANDBOOK 3.3 is
        // explicit that the wall never bricks the pool. Two reads to make that structural
        // instead of argued.
        if (index.balanceOf(address(mono)) < FixedPointMathLib.fullMulDiv(net, price, WAD)) return (false, 0);

        // And the MANAGER cannot be short either, which is the less obvious half. `take` moves
        // real ERC-20 out of the PoolManager, and the MONO it is holding mid-swap is the pools'
        // RESERVES — the seller's input does not land until the router settles, which happens
        // after every hook has run. So the wall can only buy MONO the manager already has.
        //
        // In the shipped shape this is slack: §3.5's POL is one-sided MONO from NAV up, so the
        // book the wall defends is exactly the book that is full of MONO. It binds when the pool
        // has been bought out into mostly INDEX — and there the pool leg absorbs most of the sale
        // itself, so the fill this has to cover is small. `net` is the worst case (`fill <= net`),
        // and worst-case is all that can be checked here: the split is only known after the inner
        // swap, and by then standing down is no longer free.
        //
        // ponytail: conservative, and it degrades to the plain swap §3.3 prescribes for a failed
        // vault pull rather than to a revert. The exact fix is to take the fill as an ERC-6909
        // claim and redeem it in `crank`, but a claim is not MONO and cannot be burned, so that
        // trades this ceiling for a burn that is no longer same-tx — which is the `[LAW]`. Revisit
        // only with that resolved.
        if (address(mono).balanceOf(address(poolManager)) < net) return (false, 0);

        uint256 consumed;
        uint160 limit = _wallSqrtPriceX96(key, price);
        (uint160 current,,,) = poolManager.getSlot0(id);
        // Only run the pool leg while there is room above the wall. When the pool is already at
        // or past it — which includes the day-0 one-sided book, where there is no bid at all —
        // `Pool.swap` would revert `PriceLimitAlreadyExceeded` rather than no-op, so the leg is
        // skipped entirely and the wall takes the whole sale.
        if (zeroForOne ? current > limit : current < limit) {
            // v4 skips a hook's own `beforeSwap`/`afterSwap` (`Hooks.sol`: `if (msg.sender ==
            // address(self)) return`), so this neither recurses nor double-accrues the oracle.
            BalanceDelta d = poolManager.swap(key, SwapParams(zeroForOne, -int256(net), limit), "");
            // The hook is the swapper here: its input leg is negative, its output leg positive.
            consumed = uint256(uint128(-(zeroForOne ? d.amount0() : d.amount1())));
            out = uint256(uint128(zeroForOne ? d.amount1() : d.amount0()));
        }

        uint256 fill = net - consumed;
        if (fill != 0) {
            uint256 paid = FixedPointMathLib.fullMulDiv(fill, price, WAD);
            // Take the MONO the pool could not absorb. The credit for it arrives with the
            // specified leg of the returned delta, so this is the seller's MONO, now the hook's.
            poolManager.take(zeroForOne ? key.currency0 : key.currency1, address(this), fill);
            // The vault's one allowance, and the only INDEX that ever leaves the pot `[LAW]`.
            index.safeTransferFrom(address(mono), address(this), paid);
            // Same transaction. See the note above: without this the wall is a redemption.
            mono.burn(fill);

            // Hand the seller's half of it to the manager. The pool leg's INDEX is already a
            // credit from the inner swap; only the wall's leg is real tokens we have to pay in.
            poolManager.sync(Currency.wrap(index));
            index.safeTransfer(address(poolManager), paid);
            poolManager.settle();

            out += paid;
            emit WallFilled(id, fill, paid);
        }
        engaged = true;
    }

    /// @dev The wall price as the pool quotes it. `price` is INDEX per MONO in WAD; the pool
    ///      quotes currency1 per currency0, so it inverts when MONO sorted into `currency1`.
    ///      Both legs are 18 decimals, so WAD is the only scaling factor — same shape as
    ///      `Mono.premiumCloseAmount`.
    function _wallSqrtPriceX96(PoolKey calldata key, uint256 price) internal view returns (uint160) {
        bool monoIsCurrency0 = Currency.unwrap(key.currency0) == address(mono);
        uint256 target = monoIsCurrency0
            ? FixedPointMathLib.fullMulDiv(price, Q192, WAD)
            : FixedPointMathLib.fullMulDiv(WAD, Q192, price);
        uint256 sq = FixedPointMathLib.sqrt(target);
        // `sqrt` floors, and a floored bound is a wei on the PERMISSIVE side when MONO is
        // `currency0` — the pool quotes INDEX per MONO there and a sale drives it down, so a
        // lower limit lets it end a wei under the wall (it did: `989999999999999999`). Bump it.
        // When MONO is `currency1` the quote inverts and a sale drives the reading UP, so the
        // same floor is the tight side and is left alone. `sqrt` of a uint256 fits in 128 bits,
        // and the guard keeps `sq * sq` inside 256 even at the absurd end the clamp below eats.
        if (monoIsCurrency0 && sq < type(uint128).max && sq * sq < target) ++sq;
        // `Pool.swap` rejects a limit AT either bound, so clamp inside them. Reaching either end
        // means the wall is further than the tick range goes, which is the same thing as no wall.
        if (sq <= TickMath.MIN_SQRT_PRICE) return TickMath.MIN_SQRT_PRICE + 1;
        if (sq >= TickMath.MAX_SQRT_PRICE) return TickMath.MAX_SQRT_PRICE - 1;
        return uint160(sq);
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
        o.emaSlow = _decay(o.emaSlow, target, dt, tauSlow);
        o.lastUpdate = nowTs;
        observations[id] = o;
    }

    /// @dev `Throttle` and `Gate` are the same reading — §4 gives them the same tau and says so.
    ///      The enum keeps them apart so a call site states which decision it is making.
    function _horizon(Observation memory o, Horizon h) internal view returns (int64 ema, uint32 tau) {
        if (h == Horizon.Strike) return (o.emaStrike, tauStrike);
        return (o.emaSlow, tauSlow);
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
    function setWallTickBips(uint16 bips) external override timelocked {
        // Zero would put the bid exactly AT NAV, where a fill is floor-neutral instead of
        // accretive — the tick is what makes the outflow raise the floor, so it is not optional.
        if (bips == 0 || bips > MAX_WALL_TICK_BIPS) revert InvalidWallTick();
        wallTickBips = bips;
        emit WallTickSet(bips);
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
