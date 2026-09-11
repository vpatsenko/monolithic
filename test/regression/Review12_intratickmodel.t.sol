// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Review7ConfigBase} from "./Review7_config_Base.sol";

contract Review12IntraTickModel is Review7ConfigBase {
    // Independent capped proportional allocation: repeatedly remove owners whose whole
    // cap fits within their share, then split the remainder. No heap, kappa or Q128 index.
    function _reference(uint256[] memory weights, uint256[] memory caps, uint256 supply)
        internal
        pure
        returns (uint256[] memory result)
    {
        result = new uint256[](caps.length);
        bool[] memory done = new bool[](caps.length);
        uint256 sum;
        for (uint256 i; i < caps.length; ++i) {
            sum += weights[i];
        }
        while (sum != 0) {
            bool removed;
            for (uint256 i; i < caps.length; ++i) {
                if (!done[i] && caps[i] <= supply * weights[i] / sum) {
                    done[i] = true;
                    result[i] = caps[i];
                    supply -= caps[i];
                    sum -= weights[i];
                    removed = true;
                    break;
                }
            }
            if (!removed) {
                for (uint256 i; i < caps.length; ++i) {
                    if (!done[i]) result[i] = supply * weights[i] / sum;
                }
                break;
            }
        }
    }

    function testFuzz_heapAllocationMatchesIndependentModelAndInsertionOrder(uint256 seed) public {
        _freshMono();
        _deployWith(_defaultConfig());
        uint256 n = 2 + seed % 31;
        uint256[] memory weights = new uint256[](n);
        uint256[] memory caps = new uint256[](n);
        uint256 total;
        for (uint256 i; i < n; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            weights[i] = 1 + r % 100;
            // Include exact ties in cap/stake as well as differently capped owners.
            caps[i] = (seed % 3 == 0 ? weights[i] : 1 + (r >> 16) % 100) * 1e18;
            total += caps[i];
            _stakeFor(address(uint160(0x55000 + i)), weights[i] * 1e18);
        }
        uint256 blocks = 1 + (uint256(keccak256(abi.encode(seed, "supply"))) % (total / 1e18 + 20));
        uint256 supply = blocks * 1e18;
        uint256[] memory expected = _reference(weights, caps, supply);
        uint256 snapshot = vm.snapshotState();
        uint256[] memory first = new uint256[](n);
        for (uint256 order; order < 2; ++order) {
            if (order != 0) assertTrue(vm.revertToState(snapshot));
            for (uint256 j; j < n; ++j) {
                uint256 i = order == 0 ? j : n - 1 - j;
                _bid(address(uint160(0x55000 + i)), 1e18, uint128(caps[i]), 1e18);
            }
            vm.roll(block.number + blocks);
            auction.sync(128);
            assertEq(auction.settleCursor(), 0);
            for (uint256 i; i < n; ++i) {
                uint256 got = _owed(address(uint160(0x55000 + i)));
                assertApproxEqAbs(got, expected[i], n * 4, "heap disagrees with capped proportional model");
                if (order == 0) first[i] = got;
                else assertEq(got, first[i], "reversing insertion order changed an owner's allocation");
            }
        }
    }
}
