// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Review7ConfigBase} from "./Review7_config_Base.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";

contract Review11Arithmetic is Review7ConfigBase {
    function testFuzz_smallBookAcrossWeightRescales(uint256 seed) public {
        _freshMono();
        IGenerousAuction.Config memory c = _defaultConfig();
        uint256[4] memory q = [Q96 / 10, Q96 * 3 / 10, Q96 * 6 / 10, Q96 * 9 / 10];
        c.decayQ = q[seed % 4];
        c.windowTicks = 64;
        c.roundBlocks = 1;
        c.emissionPerRound = 1;
        _deployWith(c);

        uint256 totalCap;
        address[] memory owners = new address[](96);
        for (uint256 i; i < owners.length; ++i) {
            address who = address(uint160(0x11000 + i));
            owners[i] = who;
            uint256 cap = 1 + uint256(keccak256(abi.encode(seed, i))) % 1000;
            uint256 price = 1e18 + i * 1e16;
            uint128 amount = uint128((cap * price + 1e18 - 1) / 1e18);
            _stakeFor(who, 1e18);
            _bid(who, price, amount, i == 0 ? 1e18 : price - 1e16);
            totalCap += uint256(amount) * 1e18 / price;
        }
        vm.roll(block.number + totalCap * 97 / 100);
        uint256 emitted = auction.due();
        auction.sync(10_000);
        uint256 live;
        uint256 owed;
        for (uint256 i; i < owners.length; ++i) {
            (uint256 l, uint256 o) = auction.positionOf(owners[i]);
            live += l;
            owed += o;
        }
        assertLe(auction.tokensSold(), emitted, "distributed more than the schedule");
        assertEq(owed, auction.tokensSold(), "single-seat allocations disagree with sold ledger");
        assertGe(cur.balanceOf(address(auction)), live + auction.currencyRaised(), "unpacked escrow is insolvent");
    }
}
