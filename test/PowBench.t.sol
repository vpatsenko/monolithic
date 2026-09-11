// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Scratch benchmark: what does q^(tau-i) actually cost, and where does it underflow?
// Delete after reading the numbers.

import {Test, console} from "forge-std/Test.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

contract PowBench is Test {
    uint256 constant Q96 = 1 << 96;

    // q = 0.5 and q = 0.9 in Q96
    uint256 constant Q_HALF = Q96 / 2;
    uint256 immutable Q_NINE = (Q96 * 9) / 10;

    /// @dev exponent-by-squaring, the thing we'd write by hand
    function powQ96(uint256 base, uint256 exp) public pure returns (uint256 r) {
        r = Q96;
        while (exp != 0) {
            if (exp & 1 == 1) r = FixedPointMathLib.fullMulDiv(r, base, Q96);
            exp >>= 1;
            if (exp == 0) break; // skip the final wasted squaring
            base = FixedPointMathLib.fullMulDiv(base, base, Q96);
        }
    }

    /// @dev solady's rpow at base Q96 — already in the dependency tree
    function rpowQ96(uint256 base, uint256 exp) public pure returns (uint256) {
        return FixedPointMathLib.rpow(base, exp, Q96);
    }

    /// @dev the alternative: walking the book one tick at a time, no pow at all
    function walk(uint256 w, uint256 q, uint256 steps) public pure returns (uint256) {
        for (uint256 k = 0; k < steps; ++k) {
            w = FixedPointMathLib.fullMulDiv(w, q, Q96);
        }
        return w;
    }

    function noop() public pure returns (uint256) {
        return 1;
    }

    function test_gas_pow_by_exponent() public view {
        uint256 gb = gasleft();
        this.noop();
        console.log("external-call baseline gas:", gb - gasleft());

        uint256[7] memory exps = [uint256(1), 7, 32, 96, 632, 4096, 65535];
        console.log("exp | powQ96 gas | rpow gas");
        for (uint256 i = 0; i < exps.length; ++i) {
            uint256 g0 = gasleft();
            this.powQ96(Q_HALF, exps[i]);
            uint256 gPow = g0 - gasleft();

            g0 = gasleft();
            this.rpowQ96(Q_HALF, exps[i]);
            uint256 gRpow = g0 - gasleft();

            console.log(exps[i], gPow, gRpow);
        }
    }

    function test_gas_walk_vs_pow() public view {
        console.log("steps | walk gas | pow gas");
        uint256[4] memory steps = [uint256(1), 4, 16, 64];
        for (uint256 i = 0; i < steps.length; ++i) {
            uint256 g0 = gasleft();
            this.walk(Q96, Q_HALF, steps[i]);
            uint256 gWalk = g0 - gasleft();

            g0 = gasleft();
            this.powQ96(Q_HALF, steps[i]);
            uint256 gPow = g0 - gasleft();

            console.log(steps[i], gWalk, gPow);
        }
    }

    /// @dev where does the weight round to zero? that bounds the exponent we ever need.
    function test_underflow_window() public view {
        console.log("q=0.5: last nonzero exponent");
        uint256 d = 1;
        while (powQ96(Q_HALF, d) != 0 && d < 5000) ++d;
        console.log(d - 1);

        console.log("q=0.9: last nonzero exponent");
        d = 1;
        while (powQ96(Q_NINE, d) != 0 && d < 20000) ++d;
        console.log(d - 1);

        // representative weights at q=0.9
        console.log("q=0.9 ^100 (Q96):", powQ96(Q_NINE, 100));
        console.log("q=0.9 ^500 (Q96):", powQ96(Q_NINE, 500));
    }

    /// @dev drift: is repeated squaring materially worse than the exact value?
    function test_precision_vs_walk() public view {
        uint256 byPow = powQ96(Q_NINE, 64);
        uint256 byWalk = walk(Q96, Q_NINE, 64);
        console.log("q=0.9^64 via pow :", byPow);
        console.log("q=0.9^64 via walk:", byWalk);
        console.log("abs diff (ulps)  :", byPow > byWalk ? byPow - byWalk : byWalk - byPow);
    }
}
