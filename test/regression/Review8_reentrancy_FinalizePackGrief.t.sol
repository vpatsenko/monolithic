// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Review8ReentrancyBase} from "./Review8_reentrancy_Base.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice `finalize` packs "on the way out" through `try this.mintPack() {} catch {}`
///         (GenerousAuction.sol l.516). An external self-call forwards at most 63/64 of the
///         remaining gas (EIP-150), so a caller who meters the outer call can make the INNER
///         pack run out of gas while the outer `finalize` still has its 1/64 to return `true`.
///         `finalized = true` and `Finalized` were already written/emitted before the try; the
///         catch swallows the OOG silently — no event, no revert data — and the doc sentence
///         "for a bounded sale 'finalized' now does mean 'packed'" (agent-docs, Succession,
///         step 3) is false for that call.
///
///         Whether the window is OPEN depends on the reentrancy guard's storage backend:
///           - chainid == 1: solady's guard resets with TSTORE (100 gas, no sentry) — the 1/64
///             remainder is plenty, and the window is ~64k gas wide (measured below).
///           - chainid != 1: the guard resets with SSTORE, and EIP-2200's sentry makes SSTORE
///             fail with < 2300 gas left. The outer therefore dies with the inner unless the
///             pack costs more than 64 * 2300 * 63/64 ~= 145k gas. The pack measured here is
///             ~93k, so on the L2s this repo targets the window is closed — by a 2300-gas
///             accident, with ~52k of margin, not by design.
///
///         All scans snapshot/revert around every metered call, and the reference cost is
///         measured BEFORE the scan from the same snapshot so warm/cold state is comparable.
contract Review8_reentrancy_FinalizePackGrief is Review8ReentrancyBase {
    uint64 internal END;

    function setUp() public {
        END = uint64(block.number) + 3 * K;
        _deploy(100e18, END);
        _stakeFor(aa, 1e18);
        _stakeFor(bb, 1e18);
        _bid(aa, P1, 500e18, FLOOR);
        _bid(bb, P0, 500e18, FLOOR);
        // Past endBlock with the whole 300 tokens un-swept: `finalize` does the sweep and then
        // the pack, exactly the shape the runbook relies on.
        vm.roll(END + 1);
    }

    // ------------------------------------------------------------------ scan helpers

    /// `finalize{gas: g}(128)` as a raw call, so an OOG in the outer frame is a plain `false`.
    function _finalizeWithGas(uint256 g) internal returns (bool ok) {
        (ok,) = address(auction).call{gas: g}(abi.encodeWithSelector(IGenerousAuction.finalize.selector, 128));
    }

    /// Lowest stipend in `[from, to]` (step `step`) at which `finalize` succeeds — and, with
    /// `needPacked`, also minted the pack. 0 when none.
    function _firstOk(uint256 from, uint256 to, uint256 step, bool needPacked) internal returns (uint256) {
        for (uint256 g = from; g <= to; g += step) {
            uint256 s = vm.snapshotState();
            bool ok = _finalizeWithGas(g);
            bool hit = ok && auction.finalized() && (!needPacked || auction.tokensMinted() != 0);
            vm.revertToState(s);
            if (hit) return g;
        }
        return 0;
    }

    /// Coarse then fine: the stipend band `[lo, hi)` where finalize returns true and the pack
    /// is dropped. `hi` is the first stipend that packs; `lo` the first that succeeds at all.
    function _window() internal returns (uint256 lo, uint256 hi, uint256 fullCost) {
        uint256 s = vm.snapshotState();
        uint256 g0 = gasleft();
        bool done = auction.finalize(128);
        fullCost = g0 - gasleft();
        assertTrue(done, "reference finalize completes");
        assertEq(auction.tokensMinted(), auction.tokensBooked(), "reference finalize packs");
        assertGt(auction.tokensBooked(), 0, "there was something to pack");
        vm.revertToState(s);

        lo = _firstOk(fullCost / 2, fullCost + 5_000, 500, false);
        if (lo != 0) lo = _firstOk(lo - 500, lo, 10, false);
        hi = _firstOk(fullCost / 2, fullCost + 5_000, 500, true);
        if (hi != 0) hi = _firstOk(hi - 500, hi, 10, true);
    }

    function _packCost() internal returns (uint256 cost) {
        uint256 s = vm.snapshotState();
        auction.sync(128);
        uint256 g0 = gasleft();
        auction.mintPack();
        cost = g0 - gasleft();
        vm.revertToState(s);
    }

    // ------------------------------------------------------------------ tests

    /// BUG-FORM (mainnet guard backend). The property the docs state: once `finalize` returns
    /// true with the minter role still held, the pack has landed — `tokensMinted == tokensBooked`
    /// — for EVERY stipend that lets `finalize` succeed. FAILS on current code under
    /// chainid 1: a ~64k-gas-wide band of stipends flips `finalized`, emits `Finalized`, and
    /// leaves `tokensMinted == 0`.
    function test_finalizedMeansPacked_forEveryStipend_mainnetGuard() public {
        vm.chainId(1);
        (uint256 lo, uint256 hi, uint256 fullCost) = _window();
        emit log_named_uint("full finalize cost (gas)", fullCost);
        emit log_named_uint("pack cost inside it (gas)", _packCost());
        emit log_named_uint("first stipend where finalize returns true", lo);
        emit log_named_uint("first stipend where finalize also packs", hi);
        emit log_named_uint("griefing window width (gas)", hi > lo ? hi - lo : 0);
        assertEq(hi, lo, "finalize returned true with the pack silently dropped (tokensMinted == 0)");
    }

    /// CHARACTERISATION (L2 guard backend, the deploy target). Same scan under the default
    /// chainid: no window — the guard's SSTORE reset trips EIP-2200's 2300-gas sentry whenever
    /// only 1/64 is left, so the outer OOGs with the inner and the whole call reverts. Pins the
    /// margin: the pack would have to cost > 64 * 2300 * 63 / 64 gas for the window to open.
    function test_noWindow_l2Guard_marginMeasured() public {
        assertTrue(block.chainid != 1, "default chain is not mainnet");
        (uint256 lo, uint256 hi, uint256 fullCost) = _window();
        uint256 pack = _packCost();
        uint256 threshold = 2300 * 63; // R/64 >= 2300 and 63R/64 < pack  =>  pack > 2300 * 63
        emit log_named_uint("full finalize cost (gas)", fullCost);
        emit log_named_uint("pack cost (gas)", pack);
        emit log_named_uint("pack cost at which the L2 window opens (gas)", threshold);
        emit log_named_uint("margin (gas)", threshold > pack ? threshold - pack : 0);
        emit log_named_uint("first stipend where finalize returns true", lo);
        emit log_named_uint("first stipend where finalize also packs", hi);
        assertEq(hi, lo, "no griefing window on the SSTORE guard path");
        assertLt(pack, threshold, "pack is under the sentry threshold");
    }

    /// After the fix `finalize` propagates every inner failure except the revoked-role error, so
    /// there is no stipend at which it returns true without packing — on the TSTORE guard path
    /// (mainnet) as much as anywhere. The window is closed.
    function test_noWindow_mainnetGuard_afterFix() public {
        vm.chainId(1);
        (uint256 lo, uint256 hi,) = _window();
        assertEq(hi, lo, "no stipend finalizes without packing");
        assertTrue(_finalizeWithGas(hi), "the first succeeding stipend packs");
        assertTrue(auction.finalized());
        assertGt(auction.tokensMinted(), 0, "packed");
        assertEq(auction.currencyMinted(), auction.currencyRaised(), "nothing left to pack");
    }

    /// CONTROL. A sale packed before `finalize` has nothing for the try to drop: the scan finds
    /// no window on either backend, so the grief needs exactly the state the runbook creates —
    /// a frozen tail that only `finalize` sells.
    function test_control_prePacked_noWindow() public {
        vm.chainId(1);
        auction.sync(128);
        auction.mintPack();
        assertEq(auction.tokensMinted(), auction.tokensBooked(), "pre-packed");
        uint256 s = vm.snapshotState();
        uint256 g0 = gasleft();
        auction.finalize(128);
        uint256 fullCost = g0 - gasleft();
        vm.revertToState(s);
        uint256 lo = _firstOk(fullCost / 2, fullCost + 5_000, 500, false);
        assertGt(lo, 0, "finalize still succeeds for some stipend");
        // Every succeeding stipend leaves the ledgers consistent: nothing was unpacked to drop.
        uint256 s2 = vm.snapshotState();
        _finalizeWithGas(lo);
        assertEq(auction.tokensMinted(), auction.tokensBooked(), "nothing to drop when nothing is unpacked");
        vm.revertToState(s2);
    }
}
