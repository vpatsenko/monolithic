// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {IIndex} from "./IIndex.sol";
import {IMonoHook} from "./IMonoHook.sol";

/// @title IMono
/// @notice Public surface of the MONO reserve token and its INDEX vault (HANDBOOK §3.1–3.2).
///         ERC-20 functions come from the token base; everything vault-side is here.
interface IMono {
    event Minted(address indexed to, uint256 shares, uint256 assetsIn);
    event Burned(address indexed from, uint256 shares);
    /// @notice The MONO/INDEX v4 pool was named, and with it the hook that prices it. Fires
    ///         exactly once in the contract's life.
    event PoolSet(address indexed poolManager, bytes32 indexed poolId, address indexed hook);
    /// @notice The wall hook was armed with the vault's one allowance. Fires exactly once.
    event WallSet(address indexed wall);

    error InvalidParams();
    error NoSupply();
    error ZeroShares();
    error AboveGenesisCap();
    error Dilutive();
    error PoolAlreadySet();
    error PoolNotSet();
    error InvalidPool();
    error InvalidPrice();
    error WallAlreadySet();
    error InvalidWall();

    /// @notice The role `mint` requires. Granted to the auction for the life of a sale; its own
    ///         admin is `DEFAULT_ADMIN_ROLE`.
    function MINTER_ROLE() external view returns (bytes32);

    /// @notice The INDEX this vault holds. The only thing that ever backs MONO.
    function index() external view returns (IIndex);
    function genesisCap() external view returns (uint256);
    function genesisDone() external view returns (bool);

    function totalIndex() external view returns (uint256);
    function nav() external view returns (uint256);

    /// @notice The v4 PoolManager the MONO/INDEX pool lives on. Zero until `setPool`.
    function poolManager() external view returns (IPoolManager);
    /// @notice That pool's id — the only handle any of the price reads need.
    function poolId() external view returns (PoolId);
    /// @notice The hook inside that pool's key: the oracle, the tax and the wall.
    /// @dev Named by `setPool` and not separately settable. A pool can never be re-hooked, so
    ///      naming the pool IS naming the oracle.
    function hook() external view returns (IMonoHook);
    /// @notice Which way the pool quotes the pair. True when MONO sorted into `currency0`.
    function monoIsCurrency0() external view returns (bool);

    /// @dev `DEFAULT_ADMIN_ROLE`, and callable exactly once — the pool cannot exist before this
    ///      token does, so it cannot be a constructor immutable, but it is immutable in every
    ///      other sense. Reverts `InvalidPool` unless the key holds exactly MONO and INDEX, its
    ///      hook is a `MonoHook` built for THIS vault, and the pool is live on `manager_`.
    function setPool(IPoolManager manager_, PoolKey calldata key_) external;

    /// @notice The hook holding the vault's one INDEX allowance — the wall (HANDBOOK §3.3). Zero
    ///         until `setWall`, and the wall is inert until then.
    function wall() external view returns (address);

    /// @notice Arm the wall: grant the hook the vault's ONE allowance, the only outflow that
    ///         exists (HANDBOOK §3.1 `[LAW]`).
    /// @dev `DEFAULT_ADMIN_ROLE`, callable exactly once. The allowance is unbounded on purpose —
    ///      what bounds the outflow is the hook's own arithmetic, which can only ever spend
    ///      `(1 - wallTick) x NAV` per MONO and burns every MONO it buys, so each fill RAISES NAV.
    ///      Reverts `InvalidWall` unless `wall_.mono()` is this vault.
    function setWall(address wall_) external;

    /// @notice The pool's MONO price, in INDEX per MONO, 18 decimals. Same unit as `nav()`.
    /// @dev SPOT. Movable within a block; do not gate a mint on it — see `emaPrice`.
    function poolPrice() external view returns (uint256);

    /// @notice The same price off the hook's EMA over `h`. The reading HANDBOOK §4 gates and
    ///         throttles the harvest on, and the one a mint may safely be priced against.
    function emaPrice(IMonoHook.Horizon h) external view returns (uint256);

    /// @notice `premiumBips()` off the hook's EMA over `h`. `+1500` is 15% above book.
    function emaPremiumBips(IMonoHook.Horizon h) external view returns (int256);

    /// @notice `poolPrice() - nav()`. Positive: MONO trades above book. Negative: below, which is
    ///         where the wall bids. In INDEX per MONO, 18 decimals.
    function premium() external view returns (int256);

    /// @notice MONO that would have to be sold into the pool to push its price back down to
    ///         `nav()` — the size of the premium, denominated in supply instead of price. 0 when
    ///         the market is at or below book, or when the pool has no liquidity.
    /// @dev Single-range approximation: exact only while the swap stays inside the current tick.
    ///      Understates once tick boundaries are crossed.
    function premiumCloseAmount() external view returns (uint256);

    /// @notice The same gap as a fraction of the floor, in basis points. `+1500` is MONO trading
    ///         15% above NAV; negative is below it. This is the scale-free form, and the one a
    ///         threshold should be written against.
    function premiumBips() external view returns (int256);

    /// @notice The most MONO `mint` will accept `indexAmount` INDEX for — the inverse of its
    ///         non-dilution check, rounded down.
    function maxIssuable(uint256 indexAmount) external view returns (uint256);

    /// @dev `MINTER_ROLE` only. First call seeds the vault (capped) and sets opening NAV;
    ///      every later call is non-dilutive.
    function mint(uint256 shares, uint256 assetsIn, address to) external;
    function burn(uint256 shares) external;
}
