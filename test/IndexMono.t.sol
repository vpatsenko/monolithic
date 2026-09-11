// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Test} from "forge-std/Test.sol";
import {Index} from "../src/Index.sol";
import {IIndex} from "../src/interfaces/IIndex.sol";
import {Mono} from "../src/Mono.sol";
import {IMono} from "../src/interfaces/IMono.sol";
import {TestERC20} from "./TestERC20.sol";
import {MockPool, MockStable} from "./MockPool.sol";

contract IndexMonoTest is Test {
    Index internal index;
    Mono internal mono;
    TestERC20 internal aapl;
    TestERC20 internal nvda;

    address internal harvest = address(0x11A2);
    MockFeed internal aaplFeed;
    MockFeed internal nvdaFeed;
    MockStable internal usdc;
    MockPool internal aaplPool;
    MockPool internal nvdaPool;
    address internal alice = address(0xA1);
    address internal bob = address(0xB2);

    uint256 internal constant GENESIS_CAP = 1_000_000e18;

    function setUp() public {
        aapl = new TestERC20("Apple", "AAPLx");
        nvda = new TestERC20("Nvidia", "NVDAx");
        aaplFeed = new MockFeed(200e8); // $200
        nvdaFeed = new MockFeed(100e8); // $100
        usdc = new MockStable(6);
        aaplPool = new MockPool(address(aapl), address(usdc), 200e18);
        nvdaPool = new MockPool(address(nvda), address(usdc), 100e18);

        IIndex.Stock[] memory genesis = new IIndex.Stock[](1);
        genesis[0] = IIndex.Stock({
            asset: address(aapl), allocationBips: 10_000, priceFeed: address(aaplFeed), pool: address(aaplPool)
        });
        index = new Index(genesis);
        mono = new Mono(index, GENESIS_CAP);
    }

    function _wrap(address who, uint256 shares) internal {
        uint256[] memory cost = index.calculateAmountOfAssetsToMintIndex(shares);
        for (uint256 i; i < cost.length; ++i) {
            aapl.mint(who, cost[i]);
        }
        vm.startPrank(who);
        aapl.approve(address(index), type(uint256).max);
        index.mint(shares, who);
        vm.stopPrank();
    }

    // ----------------------------------------------------- REALLOCATION

    /// @dev Fills the open channel to the last wei, in one mint.
    function _fill(address who) internal returns (uint256 shares) {
        shares = index.deficitToMint();
        uint256[] memory cost = index.calculateAmountOfAssetsToMintIndex(shares);
        nvda.mint(who, cost[1]);
        vm.startPrank(who);
        nvda.approve(address(index), type(uint256).max);
        index.mint(shares, who);
        vm.stopPrank();
    }

    function _openChannel(uint16 bips) internal {
        _run(abi.encodeCall(IIndex.addStock, (_stock(address(nvda), bips, address(nvdaFeed), address(nvdaPool)))));
    }

    /// @dev Queue and wait out the notice period, re-stamping the feeds the warp would otherwise
    ///      have aged past MAX_FEED_AGE. Leaves the call ready for `execute`, so a test expecting a
    ///      revert can point `vm.expectRevert` at the execute itself.
    function _arm(bytes memory data) internal {
        index.queue(data);
        vm.warp(block.timestamp + index.TIMELOCK_DELAY());
        aaplFeed.touch();
        nvdaFeed.touch();
    }

    function _run(bytes memory data) internal {
        _arm(data);
        index.execute(data);
    }

    function _stock(address asset, uint16 bips, address feed, address pool)
        internal
        pure
        returns (IIndex.Stock memory stock)
    {
        stock = IIndex.Stock({asset: asset, allocationBips: bips, priceFeed: feed, pool: pool});
    }

    function test_channelFillsToTargetThenClosesItself() public {
        _wrap(alice, 100e18); // 100 AAPL @ $200 = $20_000, $200 per INDEX
        _openChannel(4_000);

        assertTrue(index.reallocating());
        assertEq(index.pendingAsset(), address(nvda));
        // The pot is $20_000 of AAPL. To make NVDA 40% of the pot that includes it, add
        // $20_000 x 40/60 = $13_333.33 of it, which at $100 is 133.33 NVDA.
        assertEq(index.targetAmount(), uint256(20_000e18) * 4_000 / 6_000 / 100);
        assertGt(index.deficit(), 0);

        _fill(bob);

        assertFalse(index.reallocating());
        assertEq(index.deficit(), 0);
        // Nothing was sold: the AAPL stock is untouched, exactly as D12 requires.
        assertEq(aapl.balanceOf(address(index)), 100e18);
        // And the new stock landed on its weight, within the haircut.
        uint256 aaplValue = aapl.balanceOf(address(index)) * 200;
        uint256 nvdaValue = nvda.balanceOf(address(index)) * 100;
        assertApproxEqRel(nvdaValue * 10_000 / (aaplValue + nvdaValue), 4_000, 0.02e18);
    }

    function test_mintChargesTheNewStockAloneWhileTheChannelIsOpen() public {
        _wrap(alice, 100e18);
        _openChannel(4_000);

        // Minting still works — it just costs NVDA and nothing else.
        uint256[] memory cost = index.calculateAmountOfAssetsToMintIndex(10e18);
        assertEq(cost[0], 0);
        assertGt(cost[1], 0);

        nvda.mint(alice, cost[1]);
        vm.startPrank(alice);
        nvda.approve(address(index), type(uint256).max);
        index.mint(10e18, alice);
        vm.stopPrank();
        assertEq(nvda.balanceOf(address(index)), cost[1]);
        assertEq(aapl.balanceOf(address(index)), 100e18); // untouched

        // Deficit-only: the channel refuses to overshoot its target.
        uint256 tooMany = index.deficitToMint() + 1e18;
        vm.expectRevert(IIndex.ExceedsDeficit.selector);
        index.mint(tooMany, alice);

        // Redeem stays pro-rata while the channel is open.
        vm.prank(alice);
        index.burn(10e18, alice);
        assertGt(aapl.balanceOf(alice), 0);

        _fill(bob);

        // ...and once it closes, minting takes every stock again.
        cost = index.calculateAmountOfAssetsToMintIndex(10e18);
        assertGt(cost[0], 0);
        assertGt(cost[1], 0);
        aapl.mint(alice, cost[0]);
        nvda.mint(alice, cost[1]);
        uint256 before = index.balanceOf(alice);
        vm.startPrank(alice);
        aapl.approve(address(index), type(uint256).max);
        nvda.approve(address(index), type(uint256).max);
        index.mint(10e18, alice);
        vm.stopPrank();
        assertEq(index.balanceOf(alice), before + 10e18);
    }

    function test_depositorPaysTheHaircut() public {
        _wrap(alice, 100e18);
        _openChannel(4_000);

        uint256 shares = 10e18;
        uint256[] memory cost = index.calculateAmountOfAssetsToMintIndex(shares);
        nvda.mint(bob, cost[1]);
        vm.startPrank(bob);
        nvda.approve(address(index), type(uint256).max);
        index.mint(shares, bob);
        vm.stopPrank();

        // 10 INDEX at $200 each = $2_000, grossed up 1% and bought at $100 a unit.
        assertEq(cost[1], (shares * 200 * 10_000) / (100 * 9_900) + 1); // +1: rounds up, pot never loses
        assertEq(index.balanceOf(bob), shares);
        // Existing holders were not diluted: their slice of the pot is worth no less than before.
        assertEq(aapl.balanceOf(address(index)), 100e18);
    }

    function test_addStock_reverts() public {
        _wrap(alice, 100e18);
        bytes memory bad;

        // Not the owner: cannot even start the clock.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        index.queue(
            abi.encodeCall(IIndex.addStock, (_stock(address(nvda), 4_000, address(nvdaFeed), address(nvdaPool))))
        );

        // The owner cannot bypass the queue either.
        vm.expectRevert(IIndex.NotTimelocked.selector);
        index.addStock(_stock(address(nvda), 4_000, address(nvdaFeed), address(nvdaPool)));

        // The target's own errors still surface, through `execute`.
        bad = abi.encodeCall(IIndex.addStock, (_stock(address(nvda), 4_000, address(0), address(nvdaPool))));
        _arm(bad);
        vm.expectRevert(IIndex.InvalidPriceFeed.selector);
        index.execute(bad);

        bad = abi.encodeCall(IIndex.addStock, (_stock(address(nvda), 0, address(nvdaFeed), address(nvdaPool))));
        _arm(bad);
        vm.expectRevert(IIndex.InvalidAllocation.selector);
        index.execute(bad);

        bad = abi.encodeCall(IIndex.addStock, (_stock(address(nvda), 10_000, address(nvdaFeed), address(nvdaPool))));
        _arm(bad);
        vm.expectRevert(IIndex.InvalidAllocation.selector);
        index.execute(bad);

        bad = abi.encodeCall(IIndex.addStock, (_stock(address(aapl), 4_000, address(aaplFeed), address(aaplPool))));
        _arm(bad);
        vm.expectRevert(IIndex.DuplicateAsset.selector);
        index.execute(bad);

        _run(abi.encodeCall(IIndex.addStock, (_stock(address(nvda), 4_000, address(nvdaFeed), address(nvdaPool)))));
        bad = abi.encodeCall(IIndex.addStock, (_stock(address(0xDEAD), 100, address(nvdaFeed), address(nvdaPool))));
        _arm(bad);
        vm.expectRevert(IIndex.ReallocationActive.selector);
        index.execute(bad);
    }

    // ------------------------------------------------------------- INDEX

    /// Genesis wraps AAPLx 1:1 into INDEX.
    function test_genesisWrapsOneToOne() public {
        _wrap(alice, 1_000e18);
        assertEq(index.balanceOf(alice), 1_000e18 - 1e3, "minus locked dust");
        assertEq(aapl.balanceOf(address(index)), 1_000e18, "pot holds the stock 1:1");
        assertEq(index.totalSupply(), 1_000e18);
    }

    function test_firstMintMustClearTheFloor() public {
        aapl.mint(alice, 1e18);
        vm.startPrank(alice);
        aapl.approve(address(index), type(uint256).max);
        vm.expectRevert(IIndex.FirstMintTooSmall.selector);
        index.mint(1e17, alice);
        vm.stopPrank();
    }

    /// The core wrapper invariant: wrapping then unwrapping can never profit the caller.
    function testFuzz_roundTripNeverProfits(uint96 first, uint96 second, uint96 donation) public {
        first = uint96(bound(first, 1e18, 1e24));
        second = uint96(bound(second, 1e12, 1e24));
        donation = uint96(bound(donation, 0, 1e24));

        _wrap(alice, first);
        if (donation > 0) aapl.mint(address(index), donation); // hostile donation

        uint256[] memory cost = index.calculateAmountOfAssetsToMintIndex(second);
        aapl.mint(bob, cost[0]);
        vm.startPrank(bob);
        aapl.approve(address(index), type(uint256).max);
        index.mint(second, bob);
        uint256 spent = cost[0];
        uint256[] memory got = index.proceedsOfRedeem(index.balanceOf(bob));
        index.burn(index.balanceOf(bob), bob);
        vm.stopPrank();

        assertLe(got[0], spent, "round trip must never return more than it cost");
    }

    /// Redemption is always open — INDEX is never a trap state.
    function test_burnAlwaysOpen() public {
        _wrap(alice, 1_000e18);
        vm.prank(alice);
        index.burn(500e18, alice);
        assertEq(aapl.balanceOf(alice), 500e18);
        assertEq(index.balanceOf(alice), 500e18 - 1e3);
    }

    /// A corporate action arrives as a pot balance change; every holder rescales for free.
    function test_potGrowthAccruesProRata() public {
        _wrap(alice, 1_000e18);
        _wrap(bob, 1_000e18);
        aapl.mint(address(index), 2_000e18); // pot doubles (uiMultiplier / stock split shape)

        uint256[] memory got = index.proceedsOfRedeem(index.balanceOf(alice));
        assertApproxEqRel(got[0], 2_000e18, 1e12, "alice's claim doubled");
    }

    /// NEVER REDUCE (D12) is enforced by absence: no such function exists.
    /// D12 NEVER REDUCE now has exactly one exception: the timelocked `fireEscape`. Nothing else
    /// may shrink the basket, and `fireEscape` itself is unreachable except through queue/execute.
    function test_onlyFireEscapeReducesComposition() public {
        assertEq(index.assetCount(), 1);
        assertTrue(_hasSelector(address(index), "fireEscape(address)"), "the one sanctioned exit");

        // Not callable directly, by the owner or anyone else.
        vm.expectRevert(IIndex.NotTimelocked.selector);
        index.fireEscape(address(aapl));

        // No other reduction or rebalance path exists.
        assertFalse(_hasSelector(address(index), "removeAsset(address)"));
        assertFalse(_hasSelector(address(index), "setRecipe(address,uint256)"));
        assertFalse(_hasSelector(address(index), "rebalance(address,address,uint256)"));
        assertFalse(_hasSelector(address(index), "startRemoval(address)"));
        assertFalse(_hasSelector(address(index), "redeemSurplus(uint256,address)"));
    }

    // -------------------------------------------------------------- MONO

    function test_poolIsSetOnceAndMustHoldBothSides() public {
        assertEq(mono.pool(), address(0), "unset at deploy");
        vm.expectRevert(IMono.PoolNotSet.selector);
        mono.poolPrice();

        // A MONO/AAPL pool prices something else entirely.
        MockPool wrong = new MockPool(address(mono), address(aapl), 1e18);
        vm.expectRevert(IMono.InvalidPool.selector);
        mono.setPool(address(wrong));

        MockPool monoPool = new MockPool(address(mono), address(index), 1.25e18);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0))
        );
        mono.setPool(address(monoPool));

        mono.setPool(address(monoPool));
        assertEq(mono.pool(), address(monoPool));

        // One shot: even the owner cannot repoint it.
        MockPool other = new MockPool(address(mono), address(index), 1e18);
        vm.expectRevert(IMono.PoolAlreadySet.selector);
        mono.setPool(address(other));
    }

    function test_premiumIsMarketMinusFloor() public {
        _genesis(1_000e18, 1_000e18);
        assertEq(mono.nav(), 1e18, "floor is 1 INDEX per MONO");

        MockPool monoPool = new MockPool(address(mono), address(index), 1.25e18);
        mono.setPool(address(monoPool));
        assertApproxEqRel(mono.poolPrice(), 1.25e18, 1e12, "market reads through in NAV's unit");
        assertApproxEqRel(mono.premium(), int256(0.25e18), 1e12, "trading above book");

        // The other side of the pair must give the same answer — which branch runs is an
        // accident of address sort.
        monoPool.flip();
        assertApproxEqRel(mono.poolPrice(), 1.25e18, 1e12, "order-agnostic");

        // Below book is a NEGATIVE premium, not zero: that is the case the wall acts on.
        monoPool.setPrice(0.8e18);
        assertApproxEqRel(mono.premium(), int256(-0.2e18), 1e12, "trading at a discount");

        // The floor ratchets, the market does not follow: a donation lifts NAV and eats the premium.
        _wrap(address(this), 500e18);
        index.transfer(address(mono), 500e18);
        assertEq(mono.nav(), 1.5e18, "donation raised the floor");
        assertLt(mono.premium(), 0, "and pushed the market under it");
    }

    function _genesis(uint256 shares, uint256 assetsIn) internal {
        _wrap(address(this), assetsIn + 1e18); // extra covers the locked MIN_LIQUIDITY dust
        index.approve(address(mono), type(uint256).max);
        mono.mint(shares, assetsIn, address(this));
    }

    function test_genesisSetsOpeningNav() public {
        _genesis(1_000e18, 1_000e18);
        assertEq(mono.nav(), 1e18, "opening NAV is 1 INDEX per MONO");
        assertEq(mono.totalIndex(), 1_000e18);
        assertEq(address(mono.index()), address(index));
        assertEq(address(mono.index()), address(index));
    }

    function test_firstMintIsCapped() public {
        _genesis(1_000e18, 1_000e18);
        assertTrue(mono.genesisDone());

        Mono fresh = new Mono(index, 100e18);
        vm.expectRevert(IMono.AboveGenesisCap.selector);
        fresh.mint(101e18, 101e18, address(this));
    }

    /// The whole thesis: no operation may lower NAV.
    function test_mintCannotDiluteNav() public {
        _genesis(1_000e18, 1_000e18); // NAV 1.0

        _wrap(address(this), 2_000e18);
        index.approve(address(mono), type(uint256).max);

        // Paying exactly NAV is the boundary and is allowed.
        mono.mint(100e18, 100e18, address(this));
        assertEq(mono.nav(), 1e18);

        // One wei below NAV is not.
        vm.expectRevert(IMono.Dilutive.selector);
        mono.mint(100e18, 100e18 - 1, address(this));

        // Above NAV — a real harvest strike — raises it.
        mono.mint(100e18, 150e18, address(this));
        assertGt(mono.nav(), 1e18, "harvest above NAV accretes");
    }

    function testFuzz_navNeverDecreases(uint96[8] calldata shares, uint96[8] calldata premiums) public {
        _genesis(1_000e18, 1_000e18);
        _wrap(address(this), 1e26);
        index.approve(address(mono), type(uint256).max);

        uint256 last = mono.nav();
        for (uint256 i; i < 8; ++i) {
            uint256 s = bound(shares[i], 1e12, 1e20);
            uint256 premium = bound(premiums[i], 0, 1e20);
            // What `mint` will charge for `s` shares: `A*s/S` rounded up, the same figure its
            // own non-dilution check forms.
            uint256 supply = mono.totalSupply();
            uint256 need = (s * mono.totalIndex() + supply - 1) / supply;
            if (need + premium > index.balanceOf(address(this))) break;
            mono.mint(s, need + premium, address(this));
            uint256 now_ = mono.nav();
            assertGe(now_, last, "NAV decreased on issue");
            last = now_;
        }
    }

    /// Burning retires a claim without touching the pot — this is how wall fills accrete.
    function test_burnRaisesNav() public {
        _genesis(1_000e18, 1_000e18);
        mono.burn(100e18);
        assertApproxEqRel(mono.nav(), 1.1111e18, 1e15, "NAV rises as supply shrinks");
        assertEq(mono.totalIndex(), 1_000e18, "pot untouched");
    }

    /// Only the owner may mint.
    function test_onlyMinterRoleMints() public {
        _genesis(1_000e18, 1_000e18);
        // Hoisted: reading it inside `expectRevert`'s argument would consume the prank.
        bytes32 minter = mono.MINTER_ROLE();
        bytes memory denied =
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, minter);

        vm.prank(alice);
        vm.expectRevert(denied);
        mono.mint(1e18, 1e18, alice);

        // The role is the whole gate: granted, alice mints; renounced, she cannot.
        mono.grantRole(minter, alice);
        _wrap(alice, 4e18);
        vm.startPrank(alice);
        index.approve(address(mono), type(uint256).max);
        mono.mint(1e18, 1e18, alice);
        mono.renounceRole(minter, alice);
        vm.expectRevert(denied);
        mono.mint(1e18, 1e18, alice);
        vm.stopPrank();
    }

    /// The one conversion that exists is live and honest.
    function test_maxIssuablePricesTheClaim() public {
        _genesis(1_000e18, 2_000e18); // NAV 2.0

        assertEq(mono.nav(), 2e18);
        assertEq(mono.maxIssuable(2e18), 1e18, "2 INDEX mints at most 1 MONO");
        assertEq(address(mono.index()), address(index), "backed by INDEX");
    }

    /// MONO is a plain ERC-20, deliberately NOT an ERC-4626 vault: there is no deposit and no
    /// redeem, so the standard's entry and exit surface must not exist at all. A vault that is
    /// "conformant but permanently closed" passes every automated check and hands integrators a
    /// liquidation route that always reverts — worse than never claiming the standard.
    function test_noVaultEntryOrExitInBytecode() public view {
        assertFalse(_hasSelector(address(mono), "deposit(uint256,address)"));
        assertFalse(_hasSelector(address(mono), "mint(uint256,address)"));
        assertFalse(_hasSelector(address(mono), "withdraw(uint256,address,address)"));
        assertFalse(_hasSelector(address(mono), "redeem(uint256,address,address)"));
        // No max* either: their presence is what makes a 4626 indexer claim this as a vault.
        assertFalse(_hasSelector(address(mono), "maxDeposit(address)"));
        assertFalse(_hasSelector(address(mono), "maxMint(address)"));
        assertFalse(_hasSelector(address(mono), "maxWithdraw(address)"));
        assertFalse(_hasSelector(address(mono), "maxRedeem(address)"));
    }

    /// The vault has no exit at all — not for admin, not for the issuer, not for anyone.
    function test_vaultHasNoOutflow() public {
        _genesis(1_000e18, 1_000e18);
        assertFalse(_hasSelector(address(mono), "withdrawForWall(uint256)"));
        assertFalse(_hasSelector(address(mono), "rescue(address,uint256)"));
        assertFalse(_hasSelector(address(mono), "sweep(address)"));
        assertEq(mono.totalIndex(), 1_000e18);
    }

    /// A plain transfer in is the tax sweep: NAV rises, nobody is privileged.
    function test_taxSweepRaisesNav() public {
        _genesis(1_000e18, 1_000e18);
        _wrap(alice, 100e18);
        uint256 bal = index.balanceOf(alice);
        vm.prank(alice);
        index.transfer(address(mono), bal);
        assertGt(mono.nav(), 1e18, "donated INDEX accrues to every holder");
    }

    /// The asset list and the `stocks` mapping agree, and the constructor rejects a bad list.
    function test_assetListGuards() public {
        (address asset, uint16 bips, address feed, address pool) = index.stocks(address(aapl));
        assertEq(asset, address(aapl), "genesis stock listed");
        assertEq(bips, 10_000, "100% AAPL at genesis");
        assertEq(feed, address(aaplFeed), "genesis stock feed set at construction");
        assertEq(pool, address(aaplPool), "genesis stock pool set at construction");
        (asset, bips,,) = index.stocks(address(nvda));
        assertEq(asset, address(0), "unlisted stock is not in the basket");
        assertEq(bips, 0);

        IIndex.Stock[] memory split = new IIndex.Stock[](2);
        split[0] = IIndex.Stock({
            asset: address(aapl), allocationBips: 6_000, priceFeed: address(aaplFeed), pool: address(aaplPool)
        });
        split[1] = IIndex.Stock({
            asset: address(nvda), allocationBips: 4_000, priceFeed: address(nvdaFeed), pool: address(nvdaPool)
        });

        // Duplicate stock.
        IIndex.Stock[] memory dupe = new IIndex.Stock[](2);
        dupe[0] = split[0];
        dupe[1] = split[0];
        vm.expectRevert(IIndex.DuplicateAsset.selector);
        new Index(dupe);

        // Zero address stock.
        IIndex.Stock[] memory zeroAsset = new IIndex.Stock[](1);
        zeroAsset[0] = IIndex.Stock({
            asset: address(0), allocationBips: 10_000, priceFeed: address(aaplFeed), pool: address(aaplPool)
        });
        vm.expectRevert(IIndex.InvalidAsset.selector);
        new Index(zeroAsset);

        // Zero price feed.
        IIndex.Stock[] memory zeroFeed = new IIndex.Stock[](1);
        zeroFeed[0] = IIndex.Stock({
            asset: address(aapl), allocationBips: 10_000, priceFeed: address(0), pool: address(aaplPool)
        });
        vm.expectRevert(IIndex.InvalidPriceFeed.selector);
        new Index(zeroFeed);

        // Zero pool: a feed with nothing to check it against is not a listable stock.
        IIndex.Stock[] memory zeroPool = new IIndex.Stock[](1);
        zeroPool[0] = IIndex.Stock({
            asset: address(aapl), allocationBips: 10_000, priceFeed: address(aaplFeed), pool: address(0)
        });
        vm.expectRevert(IIndex.InvalidPool.selector);
        new Index(zeroPool);

        // Empty list.
        vm.expectRevert(IIndex.NoAssets.selector);
        new Index(new IIndex.Stock[](0));

        // Weights that do not sum to 10_000.
        split[1].allocationBips = 3_999;
        vm.expectRevert(IIndex.InvalidAllocation.selector);
        new Index(split);

        // A zero weight is not a stock.
        split[1].allocationBips = 0;
        vm.expectRevert(IIndex.InvalidAllocation.selector);
        new Index(split);

        // The good two-stock case, for contrast.
        split[0].allocationBips = 6_000;
        split[1].allocationBips = 4_000;
        Index pair = new Index(split);
        assertEq(pair.assetCount(), 2);
        (, bips,,) = pair.stocks(address(nvda));
        assertEq(bips, 4_000);
    }

    // ------------------------------------------------- POOL DIVERGENCE

    /// The weekend case. The feed stopped updating at Friday's close, but the market it prices
    /// still agrees with it, so the channel stays open. Age is not consulted while reallocating.
    function test_staleFeedMintsIfThePoolAgrees() public {
        _wrap(alice, 100e18);
        _openChannel(4_000);

        vm.warp(block.timestamp + 3 days); // every feed is far past MAX_FEED_AGE
        _fill(bob);
        assertFalse(index.reallocating(), "a stale feed its pool vouches for still fills");
    }

    /// Stale AND diverging is the case that has to fail, and it fails on the divergence.
    function test_staleFeedRevertsWhenThePoolDisagrees() public {
        _wrap(alice, 100e18);
        _openChannel(4_000);

        vm.warp(block.timestamp + 3 days);
        nvdaPool.setPrice(90e18); // the market moved while the feed sat still

        vm.expectRevert(abi.encodeWithSelector(IIndex.PriceDiverged.selector, address(nvda)));
        index.deficitToMint();
    }

    /// Outside the channel there is no pool to ask, so age is still the guard.
    function test_staleFeedStillBlocksASaleFloor() public {
        _wrap(alice, 100e18);
        _openChannel(4_000);
        _fill(bob); // close the channel, leaving two listed stocks and no pool reads
        _run(abi.encodeCall(IIndex.openSale, (address(aapl), address(nvda), 1e18, 100)));

        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert(IIndex.StalePrice.selector);
        index.saleFloor(address(aapl), 1e18);
    }

    /// A pool that agrees with the feed does not get in the way: the channel fills and closes.
    function test_agreeingPoolLetsTheChannelFill() public {
        _wrap(alice, 100e18);
        _openChannel(4_000);

        // 1.9% under the $100 feed — inside the 2% default.
        nvdaPool.setPrice(98.1e18);
        _fill(bob);
        assertFalse(index.reallocating(), "channel closed with an agreeing pool");
    }

    /// The pending asset's own pool drifting past the tolerance shuts the channel, both ways.
    function test_divergentPendingPoolBlocksTheChannel() public {
        _wrap(alice, 100e18);
        _openChannel(4_000);

        bytes memory err = abi.encodeWithSelector(IIndex.PriceDiverged.selector, address(nvda));

        nvdaPool.setPrice(103e18); // 3% over the $100 feed
        vm.expectRevert(err);
        index.deficitToMint();

        nvdaPool.setPrice(97e18); // 3% under it
        vm.expectRevert(err);
        index.mint(1e18, alice);

        // Back inside tolerance and the channel works again.
        nvdaPool.setPrice(100e18);
        _fill(bob);
        assertFalse(index.reallocating(), "channel closed once the pool agreed again");
    }

    /// Every stock is checked, not just the one being filled: the mint is priced off the whole pot.
    function test_divergentIncumbentPoolBlocksTheChannel() public {
        _wrap(alice, 100e18);
        _openChannel(4_000);

        aaplPool.setPrice(220e18); // 10% over the $200 feed, and AAPL is not the pending asset
        vm.expectRevert(abi.encodeWithSelector(IIndex.PriceDiverged.selector, address(aapl)));
        index.deficitToMint();
    }

    /// Outside reallocation nothing reads a pool at all — the pro-rata path never prices anything.
    function test_poolIsIgnoredOutsideReallocation() public {
        _wrap(alice, 100e18);
        aaplPool.setPrice(1e18); // 99.5% off the feed

        _wrap(bob, 50e18);
        assertEq(index.balanceOf(bob), 50e18, "ordinary mint ignores the pool");

        vm.prank(bob);
        index.burn(50e18, bob);
        assertEq(index.balanceOf(bob), 0, "burn ignores the pool");
    }

    /// The tolerance is what decides, and only the owner may move it.
    function test_maxDivergenceBipsGovernsTheGate() public {
        assertEq(index.maxDivergenceBips(), 200, "2% out of the box");

        _wrap(alice, 100e18);
        _openChannel(4_000);
        nvdaPool.setPrice(103e18); // 3%

        vm.expectRevert(abi.encodeWithSelector(IIndex.PriceDiverged.selector, address(nvda)));
        index.deficitToMint();

        index.setMaxDivergenceBips(400); // widen past the drift
        _fill(bob);
        assertFalse(index.reallocating(), "a wider tolerance admits the same pool");

        vm.expectRevert(IIndex.InvalidDivergence.selector);
        index.setMaxDivergenceBips(0);
        vm.expectRevert(IIndex.InvalidDivergence.selector);
        index.setMaxDivergenceBips(1_001); // past the 10% ceiling

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        index.setMaxDivergenceBips(300);
    }

    /// `_poolPrice` has a branch per token ordering; both must read the same dollar price.
    function test_poolPriceIsOrderAgnostic() public {
        _wrap(alice, 100e18);
        _openChannel(4_000);

        uint256 before = index.deficitToMint();
        nvdaPool.flip();
        aaplPool.flip();
        // A missing inversion would read $0.005 instead of $100 and trip the gate immediately.
        assertEq(index.deficitToMint(), before, "same price whichever side the stock sits on");
    }

    function _hasSelector(address target, string memory sig) internal view returns (bool) {
        bytes4 sel = bytes4(keccak256(bytes(sig)));
        bytes memory code = target.code;
        for (uint256 i; i + 4 <= code.length; ++i) {
            if (code[i] == sel[0] && code[i + 1] == sel[1] && code[i + 2] == sel[2] && code[i + 3] == sel[3]) {
                return true;
            }
        }
        return false;
    }
}

/// @notice Chainlink feed stand-in: one settable answer, 8 decimals.
contract MockFeed {
    int256 internal answer;
    uint256 internal updatedAt;

    constructor(int256 answer_) {
        answer = answer_;
        updatedAt = block.timestamp;
    }

    function setAnswer(int256 answer_) external {
        answer = answer_;
        updatedAt = block.timestamp;
    }

    function setUpdatedAt(uint256 updatedAt_) external {
        updatedAt = updatedAt_;
    }

    /// @dev Re-stamp the round without changing the answer, for tests that warp time.
    function touch() external {
        updatedAt = block.timestamp;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}
