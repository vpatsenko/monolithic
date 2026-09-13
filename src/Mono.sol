// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {IIndex} from "./interfaces/IIndex.sol";
import {IMono} from "./interfaces/IMono.sol";
import {IMonoHook} from "./interfaces/IMonoHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

contract Mono is IMono, ERC20, AccessControl {
    using SafeTransferLib for address;
    using StateLibrary for IPoolManager;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BIPS = 10_000;
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant Q192 = 1 << 192;

    /// @notice The only role that may `mint`. Held by `GenerousAuction` for the life of a sale.
    /// @dev Its admin is `DEFAULT_ADMIN_ROLE`, so a sale is wired up with `grantRole` and torn
    ///      down with `revokeRole` — no ownership transfer, and several sales can hold it at once.
    bytes32 public constant override MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice INDEX. The only thing this vault ever holds.
    IIndex public immutable override index;
    /// @notice Hard ceiling on the one-shot genesis mint, fixed at deploy.
    uint256 public immutable override genesisCap;

    bool public override genesisDone;

    /// @notice The v4 pool this vault is priced from, and the hook that prices it. All set
    ///         together by `setPool`, once, and never again.
    /// @dev The `PoolKey` itself is NOT kept: every read below takes a `PoolId`, so storing the
    ///      key would be four slots nothing ever reads. `monoIsCurrency0` is the one thing the
    ///      key was needed for after validation — which way the pool quotes the pair.
    IPoolManager public override poolManager;
    PoolId public override poolId;
    IMonoHook public override hook;
    bool public override monoIsCurrency0;
    /// @notice The hook that holds this vault's one INDEX allowance. Set once, never again.
    address public override wall;

    constructor(IIndex index_, uint256 genesisCap_) {
        if (address(index_) == address(0) || genesisCap_ == 0) revert InvalidParams();
        index = index_;
        genesisCap = genesisCap_;

        // The deployer holds both to start: admin to wire the sale up, minter to run the genesis
        // mint that sets the opening NAV. It is expected to renounce the minter half straight
        // after — see `agent-docs/Mono.md`.
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
    }

    ////////////////////////////
    ///////// ERC20 ////////////
    ////////////////////////////

    function name() public pure override returns (string memory) {
        return "Monolithic";
    }

    function symbol() public pure override returns (string memory) {
        return "MONO";
    }

    function totalIndex() public view override returns (uint256) {
        return address(index).balanceOf(address(this));
    }

    /// @notice Mint MONO against INDEX paid in. The first call seeds the vault and sets the first price
    /// and the later call rely on that price
    /// @dev `MINTER_ROLE`. Every mint is non-dilutive regardless of who holds it, so the role
    ///      bounds WHO may add supply, never whether NAV can fall.
    function mint(uint256 shares, uint256 assetsIn, address to) external override onlyRole(MINTER_ROLE) {
        if (shares == 0 || assetsIn == 0) revert ZeroShares();

        bool first = !genesisDone;
        if (first) {
            if (shares > genesisCap) revert AboveGenesisCap();
            genesisDone = true;
        } else {
            uint256 supply = totalSupply();
            if (supply == 0) revert NoSupply();
            // Rounding is up, which can only ask the harvester for more.
            if (assetsIn < FixedPointMathLib.fullMulDivUp(totalIndex(), shares, supply)) revert Dilutive();
        }

        address(index).safeTransferFrom(msg.sender, address(this), assetsIn);
        _mint(to, shares);

        emit Minted(to, shares, assetsIn);
    }

    /// @notice Burn your own MONO. Retires a claim without touching the pot, so NAV rises.
    ///         This is how wall fills accrete to every remaining holder.
    function burn(uint256 shares) external override {
        _burn(msg.sender, shares);
        emit Burned(msg.sender, shares);
    }

    /// @notice Backing per MONO, in INDEX, 18 decimals. The floor.
    function nav() public view override returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? WAD : FixedPointMathLib.fullMulDiv(totalIndex(), WAD, supply);
    }

    /// @notice Name the MONO/INDEX v4 pool. One shot: the pool cannot exist before this token
    ///         does, so the constructor cannot take it, but a second call is refused so it is
    ///         immutable from the admin's side too.
    /// @dev This is also what PINS THE HOOK. The pool's hook is inside its `PoolKey` and a pool can
    ///      never be re-hooked, so naming the pool names the oracle — there is no separate setter
    ///      that could later point the price reads at something else.
    function setPool(IPoolManager manager_, PoolKey calldata key_)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (address(poolManager) != address(0)) revert PoolAlreadySet();
        if (address(manager_) == address(0)) revert InvalidParams();

        // A pool that holds anything else prices something else entirely, and this is the one
        // moment the pairing can be checked — after this it is frozen.
        address c0 = Currency.unwrap(key_.currency0);
        address c1 = Currency.unwrap(key_.currency1);
        bool mono0 = c0 == address(this) && c1 == address(index);
        if (!mono0 && !(c1 == address(this) && c0 == address(index))) revert InvalidPool();

        // The hook is the oracle, so it has to be OURS. `MonoHook` names its vault in an
        // immutable; a hook built for a different `Mono` would read a different NAV and tax a
        // different book.
        IMonoHook hook_ = IMonoHook(address(key_.hooks));
        if (address(hook_) == address(0) || address(hook_.mono()) != address(this)) revert InvalidPool();

        PoolId id = key_.toId();
        // Proves `manager_` is the manager this pool actually lives on: an uninitialised pool
        // reads zero, and `MonoHook.afterInitialize` has already refused any foreign pair on the
        // real one. Without it a wrong-but-plausible manager would leave every price read at 0.
        (uint160 sqrtPriceX96,,,) = manager_.getSlot0(id);
        if (sqrtPriceX96 == 0) revert InvalidPool();

        poolManager = manager_;
        poolId = id;
        hook = hook_;
        monoIsCurrency0 = mono0;
        emit PoolSet(address(manager_), PoolId.unwrap(id), address(hook_));
    }

    /// @notice Arm the wall (HANDBOOK §3.3): ONE allowance to the hook, set once, and the only
    ///         outflow this vault will ever have `[LAW]`.
    /// @dev Unbounded on purpose. An allowance is not a budget here — the bound is arithmetic, and
    ///      it lives in the hook: a wall fill pays at most `(1 - wallTick) x NAV` per MONO and
    ///      burns every MONO it buys, and `(I - R*w)/(S - R) > I/S` for any `w < NAV`. So the one
    ///      path out of the pot RAISES the floor it drains, and capping the allowance would only
    ///      brick the wall at an arbitrary cumulative volume. What the cap would buy — protection
    ///      from a hostile hook — is bought instead by this being a one-shot call at a checked
    ///      address: a second `setWall` is refused, so there is no path to re-point it later.
    ///
    ///      `safeApprove` rather than a raw `approve`: INDEX is ours (solady, returns true) but
    ///      this is the single most consequential approval in the protocol and it should not
    ///      depend on that staying true.
    function setWall(address wall_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (wall != address(0)) revert WallAlreadySet();
        if (wall_ == address(0)) revert InvalidParams();
        // The hook names its vault in an immutable, so a hook built for a different `Mono` — or
        // an address that is not a hook at all — cannot be handed the pot. Same argument as
        // `setPool`'s pairing check, and a worse failure if it is skipped: `setPool` misprices,
        // this one would approve a stranger for the whole vault.
        if (address(IMonoHook(wall_).mono()) != address(this)) revert InvalidWall();

        wall = wall_;
        // Solady skips the decrement on a max allowance, so this is granted once and never
        // erodes — which is what "set once" has to mean for a hook that fills on every sell.
        address(index).safeApprove(wall_, type(uint256).max);
        emit WallSet(wall_);
    }

    /// @notice What the market pays for MONO right now, in INDEX per MONO, 18 decimals —
    ///         `nav()`'s unit.
    /// @dev SPOT, and deliberately still so. It is movable inside a single block, which is exactly
    ///      why nothing that mints may gate on it: use `emaPrice` / `emaPremiumBips` for that.
    ///      Spot is the honest answer to "what is the market paying", and the tax reads it on
    ///      purpose (§3.4) — pushing the price toward a cheaper rate IS the taxed trade.
    function poolPrice() public view override returns (uint256) {
        (uint160 sqrtPriceX96,,,) = _manager().getSlot0(poolId);
        return _priceFrom(sqrtPriceX96);
    }

    /// @notice The same price from the hook's EMA over `h` instead of from spot — the reading
    ///         HANDBOOK §4 gates and throttles the harvest on.
    /// @dev Unmovable inside a block by construction: the hook accrues at the price that STOOD,
    ///      so a displacement pushed and released in one block contributes nothing. To move this
    ///      you must hold the price across a block boundary, exposed to arbitrage throughout.
    function emaPrice(IMonoHook.Horizon h) public view override returns (uint256) {
        IMonoHook hook_ = hook;
        if (address(hook_) == address(0)) revert PoolNotSet();
        return _priceFrom(hook_.meanSqrtPriceX96(poolId, h));
    }

    /// @dev A `sqrtPriceX96` from this pool, as INDEX per MONO in WAD.
    function _priceFrom(uint160 sqrtPriceX96) internal view returns (uint256) {
        if (sqrtPriceX96 == 0) revert InvalidPrice();

        // The square only fits as a 512-bit intermediate: `sqrtPriceX96` reaches 2**160, so the
        // product reaches 2**320. This is currency1 per currency0, in Q96.
        uint256 ratioX96 = FixedPointMathLib.fullMulDiv(sqrtPriceX96, sqrtPriceX96, Q96);
        if (ratioX96 == 0) revert InvalidPrice();

        // Both MONO and INDEX are 18 decimals (neither overrides solady's default), so the unit
        // scaling `Index._poolPrice` has to do cancels here and WAD is the only factor left.
        uint256 price = monoIsCurrency0
            // INDEX per MONO already.
            ? FixedPointMathLib.fullMulDiv(ratioX96, WAD, Q96)
            // MONO per INDEX — invert it.
            : FixedPointMathLib.fullMulDiv(WAD, Q96, ratioX96);
        if (price == 0) revert InvalidPrice();
        return price;
    }

    /// @dev The manager, or `PoolNotSet` — every price read funnels through here so the unset
    ///      case answers with one error instead of a zero that looks like a price.
    function _manager() internal view returns (IPoolManager m) {
        m = poolManager;
        if (address(m) == address(0)) revert PoolNotSet();
    }

    /// @notice How far the market sits above the floor, in INDEX per MONO, 18 decimals.
    /// @dev Signed on purpose. A discount is not an error state — it is the condition the wall
    ///      exists to buy into — so flooring it at zero would throw away the only half that is
    ///      actionable.
    function premium() external view override returns (int256) {
        return SafeCastLib.toInt256(poolPrice()) - SafeCastLib.toInt256(nav());
    }

    /// @notice The premium expressed as SUPPLY: how much MONO sold into the pool would push its
    ///         price back down to `nav()`. This is the size of the harvest the gap will support.
    /// @dev Standard v3 single-range math. With MONO as token0 the pool quotes INDEX per MONO and
    ///      selling pushes it down, so the answer is `dx = L x (1/sqrtT - 1/sqrtC)`; with MONO as
    ///      token1 the quote is inverted and selling pushes it up, so it is `dy = L x (sqrtT -
    ///      sqrtC)`. Either way `sqrtT` is `sqrt(nav)` in the pool's own orientation.
    ///
    ///      ponytail: SINGLE RANGE. `liquidity()` is the in-range `L` only, so this is exact while
    ///      the swap stays inside the current tick and UNDERSTATES once it crosses one — real
    ///      books have liquidity outside the active tick that this cannot see. It is a sizing
    ///      heuristic, not a quote. Walking the tick bitmap is the fix if that gap starts to
    ///      matter; it needs far more of the pool's surface than this stub exposes.
    function premiumCloseAmount() external view override returns (uint256) {
        PoolId id = poolId;
        (uint160 sqrtC,,,) = _manager().getSlot0(id);
        if (sqrtC == 0) revert InvalidPrice();
        uint256 floor = nav();
        if (floor == 0) revert InvalidPrice();

        uint128 liq = _manager().getLiquidity(id);
        if (liq == 0) return 0;

        bool monoIsToken0 = monoIsCurrency0;
        // `nav()` is INDEX per MONO. The pool quotes currency1 per currency0, so invert when MONO
        // is currency1. Both legs are 18 decimals, so WAD is the only scaling factor.
        uint256 sqrtT = FixedPointMathLib.sqrt(
            monoIsToken0
                ? FixedPointMathLib.fullMulDiv(floor, Q192, WAD)
                : FixedPointMathLib.fullMulDiv(WAD, Q192, floor)
        );

        if (monoIsToken0) {
            // Selling MONO drives currency1/currency0 down. At or under book: nothing to close.
            if (sqrtT >= sqrtC) return 0;
            // dx = L * 2**96 * (sqrtC - sqrtT) / (sqrtC * sqrtT). Split so the denominator never
            // has to hold `sqrtC * sqrtT`, which reaches 2**320.
            return FixedPointMathLib.fullMulDiv(uint256(liq) << 96, sqrtC - sqrtT, sqrtC) / sqrtT;
        }
        if (sqrtT <= sqrtC) return 0;
        // dy = L * (sqrtT - sqrtC), de-scaled from Q96.
        return FixedPointMathLib.fullMulDiv(liq, sqrtT - sqrtC, Q96);
    }

    /// @notice `premium()` relative to the floor, in basis points — the scale-free form.
    /// @dev A threshold belongs against this, not `premium()`: an absolute gap of 0.15 INDEX means
    ///      15% at a floor of 1.0 and 1.5% at a floor of 10, and the floor only ever ratchets up.
    function premiumBips() external view override returns (int256) {
        uint256 floor = nav();
        // Unreachable while the vault holds anything — there is no outflow — but a zero floor
        // would make the ratio meaningless rather than merely large.
        if (floor == 0) revert InvalidPrice();
        return SafeCastLib.toInt256(FixedPointMathLib.fullMulDiv(poolPrice(), BIPS, floor)) - SafeCastLib.toInt256(BIPS);
    }

    /// @notice `premiumBips()` off the hook's EMA over `h` instead of spot. THIS is what a mint
    ///         gate belongs against (HANDBOOK §4: the gate and the throttle read the 5-minute EMA).
    /// @dev Same unit and sign convention as `premiumBips` — `+1500` is 15% above book — so a
    ///      threshold written for one reads correctly against the other.
    function emaPremiumBips(IMonoHook.Horizon h) external view override returns (int256) {
        uint256 floor = nav();
        if (floor == 0) revert InvalidPrice();
        return SafeCastLib.toInt256(FixedPointMathLib.fullMulDiv(emaPrice(h), BIPS, floor))
            - SafeCastLib.toInt256(BIPS);
    }

    /// @notice how much mono we can mint for the given amount of index
    function maxIssuable(uint256 indexAmount) public view override returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? indexAmount : FixedPointMathLib.fullMulDiv(indexAmount, supply, totalIndex());
    }
}
