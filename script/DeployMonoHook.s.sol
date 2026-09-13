// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {HookMiner} from "v4-periphery/utils/HookMiner.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {Mono} from "../src/Mono.sol";
import {MonoHook} from "../src/MonoHook.sol";

/// @notice Deploys `MonoHook` and hands it the MONO/INDEX pool. Run AFTER `DeployGenerousAuction`'s
///         phase 1 (which deploys `Mono` and sets the opening NAV) and BEFORE its phase 2 (whose
///         constructor reads the premium gate off this hook's EMA).
///
/// @dev Two phases on purpose, and the split is the point:
///
///        `run()`      mines the address, deploys, initialises the pool, and names it on `Mono`.
///                     The wall is INERT after this — `_wall` stands down until the vault arms it
///                     — so the oracle and the tax can be watched on a live pool, with real swaps,
///                     before anything can touch the vault.
///        `armWall()`  the irreversible step: `Mono.setWall`, which grants this hook the vault's
///                     one unbounded INDEX allowance. One shot, forever. Run it deliberately.
///
///      A v4 hook's permissions are encoded in its ADDRESS, so the address has to be MINED. The
///      flags below are the full set this hook will ever have (see `agent-docs/MonoHook.md`), and
///      they cannot be added later: a hook that gains a permission is a different address, which
///      is a different pool, which is a POL migration. `BaseHook`'s constructor asserts the
///      deployed address matches `getHookPermissions()`, so a bad mine reverts here rather than
///      shipping a hook whose bits are wrong.
///
///          forge script script/DeployMonoHook.s.sol --rpc-url chain46630 --broadcast
///          forge script script/DeployMonoHook.s.sol --sig 'armWall()' --rpc-url chain46630 --broadcast
///
///      BEFORE MAINNET: this is a return-delta (custom-curve) hook, which needs the Labs allowlist
///      to auto-route on uniswap.org. D24 spent auto-routing knowingly on LP-siphoning grounds and
///      the wall leans on it harder still. Confirm the 4663 allowlist is actually held — §3's whole
///      point is that none of this can be changed after.
contract DeployMonoHook is Script {
    /// @dev Forge broadcasts a salted `new` through this, so it is the CREATE2 deployer the mine
    ///      has to be run against. Mining against the wrong one yields an address that fails
    ///      `BaseHook`'s check.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @dev HANDBOOK §4: strike 1 min; gate and throttle share the slow one at 5 min. Not four
    ///      separate knobs — see `agent-docs/MonoHook.md`.
    uint32 internal constant TAU_STRIKE = 1 minutes;
    uint32 internal constant TAU_SLOW = 5 minutes;

    /// @dev Must match what `DeployGenerousAuction` builds its `PoolKey` with, or the two hash to
    ///      different pools and `setPool` reverts `InvalidPool`.
    int24 internal constant POOL_TICK_SPACING = 60;

    function run() external returns (MonoHook hook, PoolKey memory key) {
        Mono mono = Mono(vm.envAddress("MONO_ADDRESS"));
        IPoolManager manager = IPoolManager(vm.envAddress("POOL_MANAGER_ADDRESS"));
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        address index = address(mono.index());

        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory args = abi.encode(manager, mono, treasury, TAU_STRIKE, TAU_SLOW);
        (address mined, bytes32 salt) = HookMiner.find(CREATE2_DEPLOYER, flags, type(MonoHook).creationCode, args);
        console.log("hook (mined)     :", mined);
        console.logBytes32(salt);

        vm.startBroadcast(vm.envUint("WALLET_PRIVATE_KEY"));

        hook = new MonoHook{salt: salt}(manager, mono, treasury, TAU_STRIKE, TAU_SLOW);
        require(address(hook) == mined, "mined address not hit");

        // Open at NAV, so mNAV starts at 1.0 and the tax anchors land on their `mStart` end
        // (HANDBOOK §10: day-0 NAV, POL one-sided from NAV up). `afterInitialize` refuses any
        // other pair and seeds the accumulator here, so the oracle is live from this block rather
        // than dark until the first swap.
        bool monoIsCurrency0 = address(mono) < index;
        (Currency c0, Currency c1) = monoIsCurrency0
            ? (Currency.wrap(address(mono)), Currency.wrap(index))
            : (Currency.wrap(index), Currency.wrap(address(mono)));
        // Dynamic fee at init even though nothing sets one: `updateDynamicLPFee` is gated on the
        // pool having been CREATED dynamic and the fee lives in the key, so a static pool can
        // never become one. Free now, a POL migration later.
        key = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, POOL_TICK_SPACING, IHooks(address(hook)));
        manager.initialize(key, _sqrtPriceX96(mono.nav(), monoIsCurrency0));

        // Naming the pool is what pins the hook: it lives in the key, and a v4 pool can never be
        // re-hooked, so there is no separate oracle setter to point elsewhere later.
        mono.setPool(manager, key);

        vm.stopBroadcast();

        console.log("hook             :", address(hook));
        console.log("pool manager     :", address(manager));
        console.log("mono             :", address(mono));
        console.log("index            :", index);
        console.log("wall armed       :", hook.wallArmed()); // false -- `armWall()` is next
    }

    /// @notice Phase 2. Grants this hook the vault's ONE INDEX allowance and turns the wall on.
    /// @dev IRREVERSIBLE and one-shot: `Mono.setWall` refuses a second call, so there is no path to
    ///      re-point it. `Mono` checks `hook.mono()` is itself before granting, because the
    ///      allowance is unbounded and the address it points at is the entire protection.
    function armWall() external {
        Mono mono = Mono(vm.envAddress("MONO_ADDRESS"));
        address hook = vm.envAddress("MONO_HOOK_ADDRESS");

        vm.startBroadcast(vm.envUint("WALLET_PRIVATE_KEY"));
        mono.setWall(hook);
        vm.stopBroadcast();

        console.log("wall armed on    :", mono.wall());
        console.log("wall bids at     :", MonoHook(hook).wallPrice());
    }

    /// @dev `priceWad` INDEX per MONO as the pool quotes the pair. Both legs are 18 decimals, so
    ///      WAD is the only scaling factor.
    function _sqrtPriceX96(uint256 priceWad, bool monoIsCurrency0) internal pure returns (uint160) {
        return uint160(
            FixedPointMathLib.sqrt(
                monoIsCurrency0
                    ? FixedPointMathLib.fullMulDiv(priceWad, 1 << 192, 1e18)
                    : FixedPointMathLib.fullMulDiv(1e18, 1 << 192, priceWad)
            )
        );
    }
}
