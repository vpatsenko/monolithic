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
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {Mono} from "../src/Mono.sol";
import {MonoHook} from "../src/MonoHook.sol";

/// @notice Stands a REAL Uniswap v4 MONO/INDEX pool up, hook and all, and points a `Mono` at it.
///
/// @dev This replaced `MockPool` on the Mono side when `Mono` migrated off the v3 `slot0` stub.
///      (`MockPool` stays: `Index` still prices its STOCK legs through v3 pools, which is a
///      different pile entirely — see `agent-docs/Index.md`.)
///
///      THE POINT OF THE EXACT ARITHMETIC BELOW. These fixtures back ~40 auction tests, many of
///      which assert concrete token amounts derived from `saleSupply = premiumCloseAmount()`.
///      That figure is a function of `slot0().sqrtPriceX96` and the in-range `L`, so if this
///      seeds either of them differently from the mock it silently rewrites the expected numbers
///      in every one of those tests and the suite stops meaning what it meant. So:
///
///        - `_sqrtPriceX96` reproduces `MockPool.setPrice` term for term, and the pool is
///          INITIALISED at that value, which v4 stores verbatim;
///        - liquidity is added with `liquidityDelta == MOCK_LIQUIDITY`, the mock's own default,
///          over a range straddling the opening tick, so `getLiquidity()` returns exactly it.
///
///      The range is deliberately narrow (`tickSpacing` 1, ±10 ticks). Nothing here ever SWAPS in
///      this pool — the auction only ever reads a price off it — so width buys nothing, while a
///      wide one would cost ~1e24 of each token to reach the same `L` and drain the very balances
///      the tests bid with. Narrow costs ~1e21.
abstract contract MonoPoolBase is Test {
    using StateLibrary for IPoolManager;
    using SafeTransferLib for address;

    /// @dev `MockPool.liquidity`'s default. Reproduced, not chosen — see the note above.
    uint128 internal constant MOCK_LIQUIDITY = 1e24;

    uint160 internal constant MONO_HOOK_FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    PoolManager internal monoManager;
    PoolModifyLiquidityTest internal monoLiq;
    MonoHook internal monoHook;
    PoolKey internal monoKey;
    /// @notice Which way the live pool sorted the pair.
    bool internal monoIsC0;

    /// @dev Bumped per pool so a test that stands up two `Mono`s gets two distinct hook addresses.
    uint256 private _hookNonce;

    /// @dev The position this fixture holds, so it can be re-centred when the price is moved and
    ///      resized when a test wants a different depth.
    int24 private _lo;
    int24 private _hi;
    uint128 private _liq;

    /// @notice Stand a live MONO/INDEX v4 pool at `priceWad` INDEX per MONO and name it on `mono`.
    /// @dev The caller must hold MONO and INDEX and be `mono`'s `DEFAULT_ADMIN_ROLE`, which every
    ///      test is: it has just genesis-minted.
    function _standMonoPool(Mono mono, address idx, uint256 priceWad) internal {
        _standMonoPool(mono, idx, priceWad, MOCK_LIQUIDITY);
    }

    /// @notice As above at a chosen depth, for a caller that cannot afford `MOCK_LIQUIDITY`.
    /// @dev Only safe when the test does not read `premiumCloseAmount()`, which is a function of
    ///      this number — see the contract note.
    function _standMonoPool(Mono mono, address idx, uint256 priceWad, uint128 liquidity) internal {
        if (address(monoManager) == address(0)) {
            monoManager = new PoolManager(address(this));
            monoLiq = new PoolModifyLiquidityTest(IPoolManager(address(monoManager)));
        }

        // A v4 hook's permissions are its address, so it has to be deployed to a flagged one.
        // `deployCodeTo` is the test-time stand-in for the CREATE2 mining the real deploy does.
        address flagged = address(uint160((0x4770 + _hookNonce++) << 144) | MONO_HOOK_FLAGS);
        deployCodeTo(
            "MonoHook.sol:MonoHook",
            abi.encode(IPoolManager(address(monoManager)), mono, address(0xFEE), uint32(60), uint32(300)),
            flagged
        );
        monoHook = MonoHook(flagged);

        monoIsC0 = address(mono) < idx;
        (Currency c0, Currency c1) = monoIsC0
            ? (Currency.wrap(address(mono)), Currency.wrap(idx))
            : (Currency.wrap(idx), Currency.wrap(address(mono)));
        // Dynamic fee for the same reason `MonoHook.t.sol` uses it: the flag lives in the key and
        // a static pool can never become dynamic later. Nothing sets a fee — the tax is hook-take.
        monoKey = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 1, IHooks(flagged));

        monoManager.initialize(monoKey, _sqrtPriceX96(priceWad, monoIsC0));

        // The MONO leg comes off the caller's genesis balance (~1e21 of ~1e24, so 0.1%); the
        // INDEX leg is minted fresh, because a test that has just genesis-minted has handed its
        // whole INDEX balance to the vault and has none left to LP with. Faucet mints are how
        // every one of these harnesses gets its INDEX in the first place.
        // Best-effort: the auction harnesses back INDEX with an open-faucet ERC20, while
        // `IndexMono` backs it with the real `Index`, which has no `mint` and whose caller wraps
        // stocks for its own supply instead. Failure here is that second case, not an error.
        (bool faucet,) =
            idx.call(abi.encodeWithSignature("mint(address,uint256)", address(this), uint256(liquidity) / 100));
        faucet; // silence: the failing branch is a supported setup, see above

        address(mono).safeApprove(address(monoLiq), type(uint256).max);
        idx.safeApprove(address(monoLiq), type(uint256).max);

        _recentre(liquidity);

        mono.setPool(IPoolManager(address(monoManager)), monoKey);
    }

    /// @notice Move the pool to `priceWad` INDEX per MONO. The v4 answer to `MockPool.setPrice`.
    /// @dev Writes `slot0` directly rather than swapping there, and that is deliberate. A swap
    ///      would be the "realistic" way, but it runs the tax, moves the caller's balances and
    ///      eats the in-range liquidity on the way — none of which the mock this replaces did. The
    ///      ~40 auction tests behind this fixture assert numbers derived from `premiumCloseAmount`
    ///      at a given price and depth; the honest replacement is the one that changes the price
    ///      and NOTHING else. Real swap behaviour is covered where it belongs, in
    ///      `MonoHook.t.sol` and `MonoWall.t.sol`, against a pool nobody pokes.
    function _setMonoPoolPrice(uint256 priceWad) internal {
        _pokeMonoPoolSpot(priceWad);

        // The price moved; the hook's EMA has not. `meanTick` decays the stored reading toward the
        // LIVE tick over the elapsed seconds, so the reading only follows a poke once time passes
        // — and until it does, `emaPremiumBips` (which the auction's gate reads) still answers
        // with the old price. `expWad` saturates to zero past ~41 time constants, so warping well
        // beyond that leaves the EMA exactly ON the new price, which is what the mock this
        // replaces did instantly. Timestamps are free here: the auction's own schedule is keyed on
        // `block.number`, which this does not touch.
        vm.warp(block.timestamp + 64 * uint256(monoHook.tauSlow()));
    }

    /// @notice Move SPOT and nothing else — no time passes, so the hook's EMA does not follow.
    /// @dev This is a one-block price displacement, the thing HANDBOOK §4 puts the gate on an EMA
    ///      to defeat. Use it to assert that something reads the EMA rather than spot.
    function _pokeMonoPoolSpot(uint256 priceWad) internal {
        uint128 keep = _liq;
        _addLiq(-int256(uint256(keep))); // clear the position, so `pool.liquidity` goes to 0

        uint160 sqrtP = _sqrtPriceX96(priceWad, monoIsC0);
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtP);
        bytes32 slot = keccak256(abi.encodePacked(PoolId.unwrap(monoKey.toId()), StateLibrary.POOLS_SLOT));
        // `Slot0`: 24 empty | 24 lpFee | 24 protocolFee | 24 tick | 160 sqrtPriceX96. The fee bits
        // are read back off the live word so poking the price cannot silently reset them.
        bytes32 cur = vm.load(address(monoManager), slot);
        bytes32 fees = bytes32(uint256(cur) & ~uint256(0) << 184);
        vm.store(
            address(monoManager),
            slot,
            bytes32(uint256(sqrtP) | (uint256(uint24(tick)) << 160)) | fees
        );

        _recentre(keep);
    }

    /// @notice Set the pool's in-range depth. The v4 answer to `MockPool.setLiquidity`.
    function _setMonoPoolLiquidity(uint128 l) internal {
        _addLiq(int256(uint256(l)) - int256(uint256(_liq)));
    }

    /// @dev Put the whole position in a fresh band straddling the live tick.
    function _recentre(uint128 l) private {
        (, int24 tick,,) = IPoolManager(address(monoManager)).getSlot0(monoKey.toId());
        // One tick each side: the narrowest band that still has the live tick strictly inside it,
        // so `getLiquidity()` reports the full `l`. Width is pure cost here — nothing ever swaps
        // in this pool — and a wide band would need ~1e24 of each token to reach `l = 1e24`, which
        // is the entire genesis balance the tests bid with. One tick needs ~1e20.
        _lo = tick - 1;
        _hi = tick + 1;
        _liq = 0;
        _addLiq(int256(uint256(l)));
    }

    function _addLiq(int256 delta) private {
        if (delta == 0) return;
        monoLiq.modifyLiquidity(monoKey, ModifyLiquidityParams(_lo, _hi, delta, bytes32(0)), "");
        _liq = uint128(uint256(int256(uint256(_liq)) + delta));
    }



    /// @dev `MockPool.setPrice`, term for term, for an 18/18 pair. Kept identical on purpose: see
    ///      the contract note. `priceWad` is INDEX per MONO.
    function _sqrtPriceX96(uint256 priceWad, bool monoIsCurrency0) internal pure returns (uint160) {
        uint256 ratioX192 = monoIsCurrency0
            ? FixedPointMathLib.fullMulDiv(priceWad, 1 << 192, 1e18)
            : FixedPointMathLib.fullMulDiv(1e18, 1 << 192, priceWad);
        return uint160(FixedPointMathLib.sqrt(ratioX192));
    }

    /// @notice Drain the pool's in-range liquidity, so `premiumCloseAmount()` reads 0.
    /// @dev The v4 answer to `MockPool.setLiquidity(0)`.
    function _emptyMonoPool() internal {
        (, int24 tick,,) = IPoolManager(address(monoManager)).getSlot0(monoKey.toId());
        monoLiq.modifyLiquidity(
            monoKey, ModifyLiquidityParams(tick - 10, tick + 10, -int256(uint256(MOCK_LIQUIDITY)), bytes32(0)), ""
        );
    }
}
