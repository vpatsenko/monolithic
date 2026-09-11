// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Review8LifecycleBase} from "./Review8_lifecycle_Base.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";

/// REVIEW 8 / lifecycle — `finalize`'s `try this.mintPack() {} catch {}` (GenerousAuction.sol:516).
///
/// The try/catch was added so a revoked minter role cannot keep the stake lock closed. But a
/// try/catch around an external self-call swallows EVERY failure, out-of-gas included: the inner
/// call receives 63/64 of what is left, so there is a band of gas limits in which the pack runs
/// out of gas, the catch swallows it, and the outer `finalize` still has its 1/64 to return
/// `true` — `finalized = true` and `Finalized` were already written before the try.
///
/// That band is exactly where `eth_estimateGas` lands: the estimator binary-searches for the
/// LOWEST gas limit at which the transaction does not revert, and the lowest such limit is the
/// bottom of the swallow band, not the full-pack cost. So an honest keeper who sends `finalize`
/// at the wallet's estimate ends a sale that is "finalized" but NOT packed — role intact, no
/// `PackMinted`. The docs promise the opposite ("for a bounded sale 'finalized' now does mean
/// 'packed'") and the succession runbook's revoke step leans on it.
///
/// Whether the band exists depends on the CHAIN, by accident: solady's ReentrancyGuardTransient
/// (`_useTransientReentrancyGuardOnlyOnMainnet() == true`) resets its lock with a 100-gas
/// `tstore` on chainid 1 and with an SSTORE everywhere else. The SSTORE epilogue needs > 2300
/// gas (EIP-2200 sentry) after the catch, which is more than 1/64 of anything that makes the
/// inner call OOG — so on a rollup the outer call dies with `ReentrancySentryOOG` instead of
/// swallowing. On mainnet the 100-gas epilogue leaves the band wide open.
contract Review8LifecycleFinalizeGasWindow is Review8LifecycleBase {
    uint64 internal END;

    function setUp() public {
        _freshMono();
        END = uint64(block.number) + 2 * K;
        _deployWith(_config(100e18, END));
        _stakeFor(aa, 1e18);
        _bid(aa, P(0), 300e18, FLOOR); // absorbs both rounds in full: finalize flips on due()==0
        vm.roll(END + 1);
    }

    /// Does `finalize` succeed at exactly `gas`, and did the pack land? State is rolled back.
    function _tryFinalize(uint256 gas) internal returns (bool ok, bool packed) {
        uint256 snap = vm.snapshotState();
        (ok,) = address(auction).call{gas: gas}(abi.encodeCall(IGenerousAuction.finalize, (200)));
        packed = ok && auction.currencyMinted() == auction.currencyRaised() && auction.currencyMinted() != 0;
        vm.revertToState(snap);
    }

    /// eth_estimateGas: the lowest gas limit at which the call does not revert.
    function _estimate() internal returns (uint256 hi) {
        uint256 lo = 21_000;
        hi = 600_000;
        (bool okHi,) = _tryFinalize(hi);
        assertTrue(okHi, "reference succeeds");
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            (bool ok,) = _tryFinalize(mid);
            if (ok) hi = mid;
            else lo = mid;
        }
    }

    /// The lowest gas limit at which the call succeeds AND the pack lands.
    function _lowestPacking(uint256 from) internal returns (uint256 hi) {
        uint256 lo = from;
        hi = 600_000;
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            (, bool packed) = _tryFinalize(mid);
            if (packed) hi = mid;
            else lo = mid;
        }
    }

    function _measure(string memory label)
        internal
        returns (uint256 estimate, uint256 lowestPacking, bool packedAtEstimate)
    {
        estimate = _estimate();
        (, packedAtEstimate) = _tryFinalize(estimate);
        lowestPacking = _lowestPacking(estimate);
        emit log_string(label);
        emit log_named_uint("  lowest succeeding gas (= eth_estimateGas)", estimate);
        emit log_named_uint("  lowest gas at which the pack lands", lowestPacking);
        emit log_named_uint("  swallow band width (gas)", lowestPacking - estimate);
        emit log_named_string("  packed at the estimate", packedAtEstimate ? "yes" : "NO");
    }

    /// FAILS on current code (chainid 1): an honest `finalize` at eth_estimateGas finalizes the
    /// sale and silently skips the pack, minter role intact.
    function test_BUG_mainnet_finalizeAtEstimateGasDoesNotPack() public {
        vm.chainId(1);
        (uint256 estimate, uint256 lowestPacking, bool packedAtEstimate) = _measure("chainid 1 (tstore guard epilogue)");

        // Show the state the estimate produces.
        (bool ok,) = address(auction).call{gas: estimate}(abi.encodeCall(IGenerousAuction.finalize, (200)));
        assertTrue(ok, "finalize at the estimate succeeds");
        assertTrue(auction.finalized(), "the sale is finalized");
        assertTrue(mono.hasRole(mono.MINTER_ROLE(), address(auction)), "the role was never revoked");
        emit log_named_uint("  tokensBooked", auction.tokensBooked());
        emit log_named_uint("  tokensMinted after the estimate-gas finalize", auction.tokensMinted());
        emit log_named_uint("  band as % of the estimate", (lowestPacking - estimate) * 100 / estimate);

        assertTrue(
            packedAtEstimate, "finalize at the lowest succeeding gas must still pack (docs: finalized == packed)"
        );
    }

    /// Control, PASSES: on any non-mainnet chain (the deploy target 46630 included) solady's
    /// SSTORE epilogue makes the outer call OOG whenever the inner does, so the lowest
    /// succeeding gas already packs. The protection is an accident of the library's chain switch.
    function test_CHAR_rollup_sstoreEpilogueClosesTheBand() public {
        vm.chainId(46630);
        (,, bool packedAtEstimate) = _measure("chainid 46630 (sstore guard epilogue)");
        assertTrue(packedAtEstimate, "no band on a non-mainnet chain");
    }

    /// Consequence on mainnet, characterised: an operator who reads `finalized()` as "packed"
    /// (the docs' wording) and revokes bricks every claim; a re-grant + mintPack recovers.
    function test_CHAR_mainnet_finalizedUnpackedThenRevokeBricksClaims() public {
        vm.chainId(1);
        uint256 estimate = _estimate();
        (bool ok,) = address(auction).call{gas: estimate}(abi.encodeCall(IGenerousAuction.finalize, (200)));
        assertTrue(ok);
        assertTrue(auction.finalized());
        if (auction.currencyMinted() == auction.currencyRaised()) {
            emit log_string("no band on this chain: nothing to characterise");
            return;
        }
        emit log_named_uint(
            "unpacked tokens after the estimate-gas finalize", auction.tokensBooked() - auction.tokensMinted()
        );
        mono.revokeRole(mono.MINTER_ROLE(), address(auction));
        vm.expectRevert();
        auction.claim(aa);
        emit log_named_uint("owed to aa and unclaimable", _owed(aa));
        mono.grantRole(mono.MINTER_ROLE(), address(auction));
        assertGt(auction.mintPack(), 0, "pack lands once the role is back");
        assertGt(auction.claim(aa), 0);
    }

    /// Negative: with the role revoked BEFORE finalize the swallow is the intended behaviour —
    /// the lock lifts, stake moves, and mintPack later recovers (documented trade-off).
    function test_revokedRoleFinalizeLiftsLockAndPacksLater() public {
        mono.revokeRole(mono.MINTER_ROLE(), address(auction));
        assertTrue(auction.finalize(200));
        assertTrue(auction.finalized());
        assertLt(auction.currencyMinted(), auction.currencyRaised(), "unpacked, role gone");
        vm.prank(aa);
        auction.unstake(1e18);
        assertEq(mono.balanceOf(aa), 1e18, "stake lock lifted regardless");
        mono.grantRole(mono.MINTER_ROLE(), address(auction));
        assertGt(auction.mintPack(), 0);
        assertEq(auction.currencyMinted(), auction.currencyRaised());
    }
}
