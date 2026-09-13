// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IMono} from "./IMono.sol";

/// @title IMonoHook
/// @notice Public surface of the MONO/INDEX v4 hook. Two jobs in one contract, because a v4 hook's
///         permissions are its address and a pool can never be re-hooked: the price accumulator of
///         HANDBOOK §3.6, and the trade tax of §3.4.
/// @dev v4 ships no oracle — `grep -i observ` over v4-core finds nothing — so the accumulator is
///      ours to keep. Rulings implemented here are `MONOHOOK-REVIEW.md` (D24).
interface IMonoHook {
    // ---------------------------------------------------------------- types

    /// @notice The read horizons of HANDBOOK §3.6, named for what consumes them.
    /// @dev `Strike` is the money path — the consumer composes `max(spot, strike)`. `Throttle` is
    ///      the accrual rate. `Gate` is the LIVE/PAUSED chatter-damper on the 15% threshold.
    ///
    ///      THREE NAMES, TWO EMAs. HANDBOOK §4 sets gate and throttle to the same 5 minutes and
    ///      says so explicitly — "one EMA for gate+throttle", "gate and throttle read one EMA" —
    ///      so `Throttle` and `Gate` resolve to the same reading. They stay separate members
    ///      because they are separate *decisions* and a call site should say which one it is
    ///      making; if a re-sim ever splits them again, nothing at the call sites moves.
    enum Horizon {
        Strike,
        Throttle,
        Gate
    }

    /// @notice One pool's accumulator. 64*2 + 32 + 8 = 168 bits, so it is a single storage slot.
    /// @dev The EMAs are mean TICKS scaled by `PRECISION`, so the price they imply is a geometric
    ///      mean — the same thing v3's `tickCumulative` averages. There is no stored tick: the
    ///      price standing since `lastUpdate` is the pool's live one, read when needed.
    ///
    ///      `emaSlow` is the gate's and the throttle's, which §4 makes one and the same.
    struct Observation {
        int64 emaStrike;
        int64 emaSlow;
        uint32 lastUpdate;
        bool initialized;
    }

    /// @notice One side of the tax curve: two anchors, linear between them, flat outside.
    /// @dev Continuous by construction — there is no boundary to nudge a trade across, which is
    ///      why this replaced the stepped mNAV zones. Rates are in pips (1e6 = 100%), matching
    ///      v4's own fee unit; `m` is mNAV in WAD, so `1e18` is one times book.
    ///      Exactly one storage slot: 96 + 96 + 32 + 32.
    struct Curve {
        uint96 mStart;
        uint96 mEnd;
        uint32 rateStart;
        uint32 rateEnd;
    }

    // ---------------------------------------------------------------- events

    /// @notice A pool named this hook and was initialised. Fires once per pool.
    event ObservationSeeded(PoolId indexed id, int24 tick);
    event CurveSet(bool indexed isBuy, Curve curve);
    event VaultShareSet(uint16 bips);
    event WallTickSet(uint16 bips);
    /// @notice The wall filled the part of a sell the pool could not take above the wall price.
    /// @param monoBurned MONO bought from the seller and retired in the same tx `[LAW]`.
    /// @param indexPaid INDEX pulled from the vault to pay for it, at `wallPrice()`.
    event WallFilled(PoolId indexed id, uint256 monoBurned, uint256 indexPaid);
    event TreasurySet(address indexed treasury);
    /// @param indexSwept INDEX moved out: the vault's share raises NAV, the rest goes to treasury.
    /// @param monoBurned MONO retired. The treasury's MONO share is the remainder.
    event Cranked(uint256 indexSwept, uint256 monoBurned);
    event Queued(bytes32 indexed id, bytes data, uint256 eta);
    event Cancelled(bytes32 indexed id);
    event Executed(bytes32 indexed id);

    // ---------------------------------------------------------------- errors

    error InvalidHorizons();
    error NotInitialized();
    error InvalidCurve();
    error InvalidShare();
    error InvalidParams();
    error WrongPair();
    error NotTimelocked();
    error AlreadyQueued();
    error NotQueued();
    error TimelockPending();
    error InvalidWallTick();
    /// @notice An exact-OUTPUT sell was attempted while the wall is armed. See `wallTickBips`.
    error ExactOutputSellUnsupported();

    // ---------------------------------------------------------------- config

    /// @notice Fixed-point scale of the stored EMAs, in tick units.
    function PRECISION() external view returns (int256);

    /// @notice Denominator for every tax rate. 1e6 = 100%, v4's own fee unit.
    function PIPS() external view returns (uint256);

    /// @notice Hard ceiling on either side of the curve, in pips. 5%. Not settable, ever.
    function MAX_TAX_PIPS() external view returns (uint32);

    /// @notice Hard ceiling on `wallTickBips`, in bips. 10%. Not settable, ever.
    /// @dev What it really guarantees is that the wall can never reach NAV: the bid is
    ///      `(1 - wallTick) x NAV`, so any ceiling strictly under `BIPS` keeps every fill
    ///      accretive. 10% is two orders of magnitude of headroom over the 0.5-1% operating
    ///      range and still nowhere near the number that would matter.
    function MAX_WALL_TICK_BIPS() external view returns (uint16);

    /// @notice Floor on the vault's share of the tax, in bips. 50%. Not settable, ever.
    /// @dev The burned half of the sell tax counts as vault-side: retiring supply raises NAV.
    function MIN_VAULT_BIPS() external view returns (uint16);

    /// @notice Notice period on every timelocked change.
    function TIMELOCK_DELAY() external view returns (uint256);

    /// @notice The vault this hook taxes for. Fixes both legs of the pair.
    function mono() external view returns (IMono);
    /// @notice `mono.index()`, cached. The currency the buy tax arrives in.
    function index() external view returns (address);

    /// @notice Time constants, in seconds. `tauStrike < tauSlow`.
    /// @dev These are `tau`, not window widths: a displacement held for `t` seconds moves the
    ///      reading `1 - exp(-t/tau)` of the way, so `tau` is roughly the 63% point. HANDBOOK §4
    ///      fixes them at strike 1 min, gate and throttle 5 min; they stay constructor arguments
    ///      so a re-sim needs no new bytecode.
    ///
    ///      There is deliberately no `tauThrottle()`/`tauGate()` pair. Two accessors for one
    ///      number would read as two knobs that happen to agree, and invite a caller to believe
    ///      they can be set apart. `Horizon` is where the distinction lives.
    function tauStrike() external view returns (uint32);
    function tauSlow() external view returns (uint32);

    // ---------------------------------------------------------------- state

    function observations(PoolId id)
        external
        view
        returns (int64 emaStrike, int64 emaSlow, uint32 lastUpdate, bool initialized);

    /// @notice The tax charged on INDEX paid in to buy MONO. Falls as mNAV rises.
    function buyTax() external view returns (uint96 mStart, uint96 mEnd, uint32 rateStart, uint32 rateEnd);
    /// @notice The tax charged on MONO paid in to sell it. Rises as mNAV rises — the profit-taker
    ///         at a high premium is the primary NAV engine (§3.4).
    function sellTax() external view returns (uint96 mStart, uint96 mEnd, uint32 rateStart, uint32 rateEnd);

    /// @notice The vault's share of collected tax, in bips. The remainder is the treasury's.
    function vaultShareBips() external view returns (uint16);

    /// @notice How far under NAV the wall bids, in bips. Timelocked, under `MAX_WALL_TICK_BIPS`.
    function wallTickBips() external view returns (uint16);
    function treasury() external view returns (address);

    /// @notice keccak256(calldata) => when it was queued. Zero means not queued.
    function queuedAt(bytes32 id) external view returns (uint256);

    // ---------------------------------------------------------------- views

    /// @notice The mean tick over `h`, brought up to the current block. Reverts `NotInitialized`
    ///         for a pool this hook has never been named by.
    function meanTick(PoolId id, Horizon h) external view returns (int24);

    /// @notice The same reading as a `sqrtPriceX96` — a drop-in for `slot0`'s, so a consumer's
    ///         existing price math needs no change beyond where it reads from.
    function meanSqrtPriceX96(PoolId id, Horizon h) external view returns (uint160);

    /// @notice Spot price over vault NAV, in WAD. `1e18` is MONO trading exactly at book.
    /// @dev The tax reads THIS, never a TWAP: pushing the price toward a cheaper rate is itself
    ///      the taxed trade, so the manipulation is self-defeating and a lag would only add one.
    function mNav(PoolKey calldata key) external view returns (uint256);

    /// @notice What either side of the curve charges at `m`, in pips.
    function taxRate(bool isBuy, uint256 m) external view returns (uint256);

    /// @notice What the wall pays for MONO: `(1 - wallTick) x NAV`, in INDEX per MONO, 18
    ///         decimals. 0 when the vault is unpriceable, which is also when the wall stands down.
    function wallPrice() external view returns (uint256);

    /// @notice True once `Mono.setWall` has pointed the vault's one allowance at this hook.
    ///         Until then the wall is inert and sells are plain taxed swaps.
    function wallArmed() external view returns (bool);

    // ---------------------------------------------------------------- tax

    /// @notice Pay out everything the tax has collected. Permissionless.
    /// @dev INDEX: the vault's share is transferred to `mono`, which has no entry point, so it
    ///      lands as pure backing and lifts NAV. MONO: the vault's share is BURNED, which lifts
    ///      NAV the other way round — the vault may never hold MONO.
    function crank() external returns (uint256 indexSwept, uint256 monoBurned);

    // ---------------------------------------------------------------- timelocked admin

    function setCurve(bool isBuy, Curve calldata c) external;
    function setVaultShareBips(uint16 bips) external;
    function setWallTickBips(uint16 bips) external;
    function setTreasury(address treasury_) external;

    function queue(bytes calldata data) external returns (bytes32 id);
    function cancel(bytes calldata data) external;
    function execute(bytes calldata data) external returns (bytes memory result);
}
