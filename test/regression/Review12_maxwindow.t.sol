// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Review7ConfigBase} from "./Review7_config_Base.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";

contract Review12MaxWindow is Review7ConfigBase {
    function test_flatMaximumWindowIncludesAll256PricesWithoutIndexCollision() public {
        _freshMono();
        IGenerousAuction.Config memory c = _defaultConfig();
        c.decayQ = Q96;
        c.windowTicks = 255; // inclusive endpoints: 256 prices, indices 0 through 255
        c.emissionPerRound = 256e18;
        _deployWith(c);
        for (uint256 i; i < 256; ++i) {
            address owner = address(uint160(0x66000 + i));
            uint256 price = 1e18 + i * 1e16;
            _stakeFor(owner, 1e18);
            _bid(owner, price, uint128(price), i == 0 ? 1e18 : price - 1e16);
        }
        vm.roll(c.startBlock + 100);
        (,, uint256[] memory prices, uint256[] memory tokens) = auction.previewWindow();
        assertEq(prices.length, 256);
        for (uint256 i; i < 256; ++i) {
            assertEq(prices[i], 1e18 + (255 - i) * 1e16);
            assertEq(tokens[i], 1e18);
        }
        auction.sync(10_000);
        assertEq(auction.tokensSold(), 256e18);
        assertEq(auction.tokensBooked(), 256e18);
        assertEq(auction.due(), 0);
        for (uint256 i; i < 256; ++i) {
            assertEq(_owed(address(uint160(0x66000 + i))), 1e18);
        }
    }
}
