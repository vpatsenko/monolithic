// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Review14PreviewBase} from "./Review14_preview_Base.sol";

/// REVIEW 14 / preview lens — `previewWindow()` has NO budget parameter and no internal bound.
/// It walks every window down to the bottom of the book, and `_previewAppend` re-allocates and
/// re-copies the whole accumulated result on every window. Cost is therefore QUADRATIC in the
/// number of windows (memory-expansion dominated), while `sync(maxTicks)` over the same book is
/// linear and chunkable.
contract Review14PreviewGas is Review14PreviewBase {
    /// A node's default `eth_call` gas cap (geth/erigon/reth `--rpc.gascap`, Infura/Alchemy).
    uint256 internal constant ETH_CALL_CAP = 30_000_000;

    function setUp() public {
        // Emission far larger than any book below, so every band runs dry and the sweep walks
        // to the very bottom — the ordinary "a long dry spell left carry" state.
        _deploy(150e18, 0);
    }

    function _actor(uint256 i) internal pure returns (address) {
        return address(uint160(0x10000 + i));
    }

    /// `n` single-tick windows, 10 grid steps apart (the band is 8), one bidder each.
    function _book(uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            _bidCap(_actor(i), P((n - 1 - i) * 10), 0.001e18, 0);
        }
        vm.roll(block.number + K);
    }

    function _previewGas() internal returns (uint256 used, uint256 listed) {
        uint256 g = gasleft();
        (,,, uint256[] memory tokens) = auction.previewWindow();
        used = g - gasleft();
        listed = tokens.length;
    }

    function _measure(uint256 n) internal returns (uint256 used) {
        _book(n);
        uint256 listed;
        (used, listed) = _previewGas();
        emit log_named_uint("ticks", n);
        emit log_named_uint("  previewWindow gas", used);
        emit log_named_uint("  ticks listed", listed);
        assertEq(listed, n, "the preview listed every live tick");
    }

    /// `n` CONSECUTIVE ticks — a dense book, the shape the header calls the target.
    function _bookDense(uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            _bidCap(_actor(i), P(n - 1 - i), 0.0001e18, 0);
        }
        vm.roll(block.number + K);
    }

    function _measureDense(uint256 n) internal returns (uint256 used) {
        _bookDense(n);
        uint256 listed;
        (used, listed) = _previewGas();
        emit log_named_uint("dense ticks", n);
        emit log_named_uint("  previewWindow gas", used);
        emit log_named_uint("  ticks listed", listed);
    }

    function test_dense_0200() public {
        _measureDense(200);
    }

    function test_dense_0400() public {
        _measureDense(400);
    }

    function test_dense_0800() public {
        _measureDense(800);
    }

    function test_scaling_040() public {
        _measure(40);
    }

    function test_scaling_200() public {
        _measure(200);
    }

    function test_scaling_240() public {
        _measure(240);
    }

    function test_scaling_080() public {
        _measure(80);
    }

    function test_scaling_160() public {
        _measure(160);
    }

    function test_scaling_320() public {
        _measure(320);
    }

    function test_scaling_640() public {
        _measure(640);
    }

    /// The bite: a 640-tick sparse book is an ordinary book (the header calls "a few hundred
    /// ticks" the target shape), yet `previewWindow` no longer fits a node's `eth_call` cap —
    /// while a `sync` over the SAME book, chunked at the contract's own `SYNC_TICKS` budget,
    /// settles it in a handful of ordinary transactions.
    ///
    /// FAILS on current code.
    function test_BUG_previewOutOfGasOnAnOrdinaryBook() public {
        _book(640);

        // 1. the view: one staticcall under a node's cap
        (bool ok, bytes memory ret) =
            address(auction).staticcall{gas: ETH_CALL_CAP}(abi.encodeWithSignature("previewWindow()"));
        emit log_named_string("previewWindow() under a 30M eth_call cap", ok ? "OK" : "OUT OF GAS");
        emit log_named_uint("returndata bytes", ret.length);

        // 2. the same book actually settles: bounded, chunked syncs
        uint256 chunks;
        uint256 gasHigh;
        while (auction.due() != 0 && chunks < 64) {
            uint256 g = gasleft();
            auction.sync(128);
            uint256 u = g - gasleft();
            if (u > gasHigh) gasHigh = u;
            ++chunks;
            if (auction.settleCursor() == 0 && auction.due() != 0) break; // carry the book cannot take
        }
        emit log_named_uint("sync(128) chunks to settle the same book", chunks);
        emit log_named_uint("worst single sync(128) gas", gasHigh);

        assertTrue(ok, "previewWindow must fit a node's eth_call gas cap on a book sync can settle");
    }
}
