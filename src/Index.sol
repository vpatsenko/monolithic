// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {IIndex} from "./interfaces/IIndex.sol";
import {IUniswapV3Pool} from "./interfaces/IUniswapV3Pool.sol";

/// @dev The one thing the pot needs from Permit2: the domain it hashes intents against.
interface IPermit2 {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

contract Index is IIndex, ERC20, Ownable, ReentrancyGuardTransient {
    using SafeTransferLib for address;

    /// @dev Shares locked forever on the first mint, so the pot can never be emptied back
    ///      to a zero-supply state and re-seeded at a manipulated slice.
    uint256 internal constant MIN_LIQUIDITY = 1e3;
    /// @dev Floors the first mint well above MIN_LIQUIDITY so the locked dust is noise.
    uint256 internal constant MIN_FIRST_MINT = 1e18;
    /// @dev Basis-point denominator. Target weights must sum to exactly this.
    uint256 internal constant BIPS = 10_000;
    /// @dev A feed older than this is treated as no price at all. Not consulted while
    ///      `reallocating` — there the pool stands in for it, see `_price`.
    ///      ponytail: one age for every feed. Per-feed heartbeats if a slow feed ever gets listed.
    uint256 internal constant MAX_FEED_AGE = 1 hours;
    /// @dev Everything is valued in this many decimals of USD before being converted back to token
    ///      amounts, so stocks with different decimals and feeds with different decimals compare.
    uint256 internal constant VALUE_SCALE = 1e18;
    /// @dev Fee denominator. NOT basis points: 100_000 is 100%, so 1755 = 1.755% and 50 = 0.05%.
    uint256 internal constant FEE_SCALE = 100_000;
    /// @dev Notice period on every timelocked change. Not settable — a timelock whose length the
    ///      owner can shorten on demand is not a timelock.
    uint256 public constant override TIMELOCK_DELAY = 2 days;
    /// @dev Hard ceiling on `feeRate`, checked on every set. 5%.
    uint256 internal constant MAX_FEE_RATE = 5_000;
    /// @dev D20 haircut on a deficit deposit. Wider than the worst relative feed error, so the
    ///      oracle cannot dilute holders — a mispricing costs the minter, never the pot.
    uint256 internal constant HAIRCUT_BIPS = 100;

    /// @dev Canonical Permit2, same address on every chain. The pot never approves anyone else.
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    /// @dev Arcus spot settlement on chain 4663 — the only address allowed to be the Permit2
    ///      spender in an armed intent. A constant, not a constructor argument: the contract is
    ///      immutable anyway, so a different chain is a redeploy, and this way it cannot be set
    ///      wrong at deploy time.
    address internal constant ARCUS_SETTLEMENT = 0x006102b16A04c20306A28b652745D3973D7D24fa;
    /// @dev `bytes4(keccak256("isValidSignature(bytes32,bytes)"))`.
    bytes4 internal constant ERC1271_MAGIC = 0x1626ba7e;
    /// @dev Longest an armed intent may stay live. Router quotes expire in about a minute; this
    ///      only has to bound how long a signed commitment can outlive the price it was struck at.
    uint256 internal constant MAX_INTENT_TTL = 15 minutes;
    /// @dev Hard ceiling on a campaign's `maxSlipBips`, so no vote can authorise a giveaway. 3%.
    uint16 internal constant MAX_SALE_SLIP_BIPS = 300;
    /// @dev Hard ceiling on `maxDivergenceBips`. 10% — past that the check is theatre.
    uint16 internal constant MAX_DIVERGENCE_BIPS = 1_000;
    /// @dev Starting feed-vs-pool tolerance. 2%.
    uint16 internal constant DEFAULT_DIVERGENCE_BIPS = 200;

    bytes32 internal constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");
    /// @dev Arcus's witness struct, exactly as the router returns it in a quote's `toSign.types`.
    bytes32 internal constant TAKER_INTENT_TYPEHASH = keccak256(
        "TakerIntent(address taker,address takerSellToken,address takerBuyToken,uint256 sellAmount,uint256 minBuyAmount,bool allowWrapped,uint256 nonce,uint256 deadline)"
    );
    /// @dev Permit2's witness stub with that type string appended. Referenced types follow the
    ///      primary type alphabetically, so `TakerIntent` precedes `TokenPermissions`.
    bytes32 internal constant PERMIT_WITNESS_TYPEHASH = keccak256(
        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,TakerIntent witness)TakerIntent(address taker,address takerSellToken,address takerBuyToken,uint256 sellAmount,uint256 minBuyAmount,bool allowWrapped,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)"
    );

    address[] internal _assets;

    bool public override reallocating;
    address public override pendingAsset;
    uint256 public override targetAmount;

    mapping(address => Stock) public override stocks;

    /// @dev How far a stock's feed may sit from its pool before a reallocation mint is refused.
    ///      Only consulted while `reallocating`; the pro-rata path reads no prices at all.
    uint16 public override maxDivergenceBips = DEFAULT_DIVERGENCE_BIPS;
    /// @dev P7 in-kind fee, per FEE_SCALE. Starts at 0 — nothing is charged until the owner sets it.
    uint256 public override feeRate;
    /// @dev asset => fee collected and not yet withdrawn. Netted out of `_contractAssetBalance`
    ///      exactly like `reserved`, so an uncollected fee is never counted as backing. Without
    ///      that, NAV would rise as fees accrued and fall again when the owner swept them.
    mapping(address => uint256) public override fees;
    /// @dev keccak256(calldata) => when it was queued. Zero means not queued.
    mapping(bytes32 => uint256) public override queuedAt;

    /// @dev owner => asset => raw units a burn booked to `owner` but could not transfer.
    mapping(address => mapping(address => uint256)) public override owed;
    /// @dev asset => sum of every `owed` entry for it. Netted out of the pot's balance by
    ///      `_contractAssetBalance`, so a booked sliver is never counted as pot property again.
    mapping(address => uint256) public override reserved;

    /// @dev sellToken => the open sale campaign. A zero `buyToken` means none.
    mapping(address => Sale) public override sales;
    /// @dev The one Permit2 digest the pot vouches for, or zero. Exactly one at a time: a second
    ///      live digest is a second clip nobody authorised.
    bytes32 public override armedIntent;

    /// @param stocks_ The pot's stocks, in order. Every entry must have a non-zero asset, non-zero
    ///        allocation, and non-zero feed; allocations must sum to 10_000.
    constructor(Stock[] memory stocks_) Ownable(msg.sender) {
        if (stocks_.length == 0) revert NoAssets();

        uint256 total;
        for (uint256 i; i < stocks_.length; ++i) {
            Stock memory stock = stocks_[i];
            if (stock.asset == address(0)) revert InvalidAsset();
            if (stock.priceFeed == address(0)) revert InvalidPriceFeed();
            if (stock.pool == address(0)) revert InvalidPool();
            if (stocks[stock.asset].asset != address(0)) revert DuplicateAsset();
            if (stock.allocationBips == 0) revert InvalidAllocation();
            for (uint256 j; j < i; ++j) {
                if (stocks_[j].asset == stock.asset) revert DuplicateAsset();
            }

            stocks[stock.asset] = stock;
            _assets.push(stock.asset);

            emit PriceFeedSet(stock.asset, stock.priceFeed, stock.pool);
            total += stock.allocationBips;
        }
        if (total != BIPS) revert InvalidAllocation();
    }

    /// @dev Reachable only through `execute`, which is the only caller that can be `address(this)`.
    ///      So the owner cannot call these directly — they must queue and wait out TIMELOCK_DELAY.
    modifier timelocked() {
        if (msg.sender != address(this)) revert NotTimelocked();
        _;
    }

    ////////////////////////////
    ///////// ERC20 ////////////
    ////////////////////////////
    function name() public pure override returns (string memory) {
        return "Monolithic Index";
    }

    function symbol() public pure override returns (string memory) {
        return "INDEX";
    }

    /// @notice Mints INDEX to to address, if the reallocation mode is enabled then mint will accept only the token which is being added
    /// @param shares INDEX to receive. The caller pays whatever `calculateAmountOfAssetsToMintIndex` says.
    /// @param to the address to mint the INDEX to
    function mint(uint256 shares, address to) external override nonReentrant returns (uint256[] memory paid) {
        if (shares == 0) revert ZeroShares();
        // Deficit-only: the channel never takes more than closes it.
        if (reallocating && shares > deficitToMint()) revert ExceedsDeficit();
        uint256 supply = totalSupply();
        if (supply == 0 && shares < MIN_FIRST_MINT) revert FirstMintTooSmall();

        uint256[] memory feeAmounts;
        (paid, feeAmounts) = _mintQuote(shares);
        for (uint256 i; i < _assets.length; ++i) {
            if (paid[i] == 0) continue;
            _assets[i].safeTransferFrom(msg.sender, address(this), paid[i]);
            // Booked out of the pot on arrival, so the deposit backs the new shares at exactly the
            // pre-existing ratio and NAV does not move.
            if (feeAmounts[i] > 0) fees[_assets[i]] += feeAmounts[i];
        }

        if (supply == 0) {
            // Locked forever: this contract has no path that moves its own INDEX.
            _mint(address(this), MIN_LIQUIDITY);
            _mint(to, shares - MIN_LIQUIDITY);
        } else {
            _mint(to, shares);
        }
        emit Wrapped(msg.sender, to, shares);

        // The deposit that meets the target closes the channel and hands minting back to the
        // pro-rata path. A shortfall below one raw unit per INDEX is rounding, not a deficit.
        if (reallocating && FixedPointMathLib.fullMulDiv(deficit(), VALUE_SCALE, totalSupply()) == 0) {
            reallocating = false;
            emit ReallocationCompleted(pendingAsset, _contractAssetBalance(pendingAsset));
        }
    }

    /// @notice Unwrap INDEX back into its slice of the pot, in kind. Never gated.
    /// @dev A leg that will not transfer — the issuer froze the token, or blocklisted `to` — is
    ///      booked to `to` and collected later via `claim`, never reverted. One frozen stock out of
    ///      ten must not lock all ten, and the redeemer must not have to forfeit the tenth to get
    ///      the nine. Booked or paid, the leg leaves the pot either way: `reserved` rises by exactly
    ///      what the transfer would have moved, so no other holder's slice shifts.
    function burn(uint256 shares, address to) external override nonReentrant returns (uint256[] memory got) {
        if (shares == 0) revert ZeroShares();
        got = proceedsOfRedeem(shares);
        // Burn before paying out: the slice was measured against the pre-burn supply.
        _burn(msg.sender, shares);
        for (uint256 i; i < _assets.length; ++i) {
            uint256 amount = got[i];
            if (amount == 0) continue;
            address asset = _assets[i];
            if (_tryTransfer(asset, to, amount)) continue;

            owed[to][asset] += amount;
            reserved[asset] += amount;
            got[i] = 0;
            emit LegDeferred(to, asset, amount);
        }
        emit Unwrapped(msg.sender, to, shares);
    }

    /// @inheritdoc IIndex
    function claim(address[] calldata assets_, address to)
        external
        override
        nonReentrant
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](assets_.length);
        for (uint256 i; i < assets_.length; ++i) {
            address asset = assets_[i];
            uint256 amount = owed[msg.sender][asset];
            // Zeroed before the transfer, and a zero balance reverts — so the same asset listed
            // twice in one call cannot pay twice.
            if (amount == 0) revert NothingOwed();
            owed[msg.sender][asset] = 0;
            reserved[asset] -= amount;
            amounts[i] = amount;

            // Deliberately the reverting transfer: a leg that still will not move stays booked.
            asset.safeTransfer(to, amount);
            emit Claimed(msg.sender, asset, to, amount);
        }
    }

    ///////////////////////////////
    ///////// External ////////////
    ///////////////////////////////
    /// @inheritdoc IIndex
    function setPriceFeed(address asset, address priceFeed, address pool) external override onlyOwner {
        if (stocks[asset].asset == address(0)) revert InvalidAsset();
        if (priceFeed == address(0)) revert InvalidPriceFeed();
        if (pool == address(0)) revert InvalidPool();
        stocks[asset].priceFeed = priceFeed;
        stocks[asset].pool = pool;
        emit PriceFeedSet(asset, priceFeed, pool);
    }

    /// @inheritdoc IIndex
    function setMaxDivergenceBips(uint16 maxDivergenceBips_) external override onlyOwner {
        if (maxDivergenceBips_ == 0 || maxDivergenceBips_ > MAX_DIVERGENCE_BIPS) revert InvalidDivergence();
        maxDivergenceBips = maxDivergenceBips_;
        emit MaxDivergenceSet(maxDivergenceBips_);
    }

    /// @inheritdoc IIndex
    function queue(bytes calldata data) external override onlyOwner returns (bytes32 id) {
        id = keccak256(data);
        if (queuedAt[id] != 0) revert AlreadyQueued();
        queuedAt[id] = block.timestamp;
        emit Queued(id, data, block.timestamp + TIMELOCK_DELAY);
    }

    /// @inheritdoc IIndex
    function cancel(bytes calldata data) external override onlyOwner {
        bytes32 id = keccak256(data);
        if (queuedAt[id] == 0) revert NotQueued();
        delete queuedAt[id];
        emit Cancelled(id);
    }

    /// @inheritdoc IIndex
    function execute(bytes calldata data) external override onlyOwner returns (bytes memory result) {
        bytes32 id = keccak256(data);
        uint256 at = queuedAt[id];
        if (at == 0) revert NotQueued();
        if (block.timestamp < at + TIMELOCK_DELAY) revert TimelockPending();
        delete queuedAt[id];

        bool ok;
        (ok, result) = address(this).call(data);
        if (!ok) {
            // Surface the target's own revert, so a change that went stale during the notice
            // period fails with `StalePrice` or `DuplicateAsset` rather than an opaque failure.
            assembly {
                revert(add(result, 0x20), mload(result))
            }
        }
        emit Executed(id);
    }

    /// @inheritdoc IIndex
    function fireEscape(address asset) external override timelocked nonReentrant returns (uint256 amount) {
        if (reallocating) revert ReallocationActive();
        if (stocks[asset].asset == address(0)) revert InvalidAsset();
        // A basket of nothing has no NAV and no way back; `_perIndexValue` would revert forever.
        if (_assets.length == 1) revert LastAsset();

        // The NET balance: claimants' `reserved` legs and uncollected `fees` are not the pot's to
        // give away, and both stay claimable afterwards because they read `owed` / `fees`.
        amount = _contractAssetBalance(asset);

        uint16 freed = stocks[asset].allocationBips;
        uint256 i = _indexOf(asset);
        _assets[i] = _assets[_assets.length - 1];
        _assets.pop();
        delete stocks[asset];
        // Same dust convention as `addStock`: the freed weight lands on the first incumbent.
        stocks[_assets[0]].allocationBips += freed;

        address to = owner();
        if (amount > 0) asset.safeTransfer(to, amount);
        emit FireEscaped(asset, to, amount);
    }

    /// @inheritdoc IIndex
    function openSale(address sellToken, address buyToken, uint256 dailyCap, uint16 maxSlipBips)
        external
        override
        timelocked
    {
        if (reallocating) revert ReallocationActive();
        if (stocks[sellToken].asset == address(0)) revert InvalidAsset();
        // The buy leg must be listed too, or the proceeds land outside `_assets`, `_potValue`
        // never counts them, and NAV steps down at settlement — a mint/redeem pump.
        if (stocks[buyToken].asset == address(0)) revert InvalidAsset();
        if (sellToken == buyToken) revert DuplicateAsset();
        if (dailyCap == 0) revert SaleCapExceeded();
        if (maxSlipBips > MAX_SALE_SLIP_BIPS) revert SlippageTooWide();

        sales[sellToken] = Sale({
            buyToken: buyToken, dailyCap: dailyCap, soldToday: 0, windowStart: block.timestamp, maxSlipBips: maxSlipBips
        });

        emit SaleOpened(sellToken, buyToken, dailyCap, maxSlipBips);
    }

    /// @inheritdoc IIndex
    function closeSale(address sellToken) external override timelocked {
        if (sales[sellToken].buyToken == address(0)) revert NoOpenSale();
        delete sales[sellToken];
        // Revoking the campaign must revoke its reach: an intent armed under it dies here, and so
        // does the standing Permit2 allowance that would let the settlement pull the clip.
        _clearIntent(sellToken);
        emit SaleClosed(sellToken);
    }

    /// @inheritdoc IIndex
    function armSale(address sellToken, uint256 sellAmount, uint256 minBuyAmount, uint256 nonce, uint256 deadline)
        external
        override
        onlyOwner
        nonReentrant
        returns (bytes32 digest)
    {
        Sale storage sale = sales[sellToken];
        address buyToken = sale.buyToken;
        if (buyToken == address(0)) revert NoOpenSale();
        if (reallocating) revert ReallocationActive();

        if (deadline <= block.timestamp) revert IntentExpired();
        // A signed commitment outliving its quote is a free option handed to the maker.
        if (deadline - block.timestamp > MAX_INTENT_TTL) revert IntentTooLong();

        // Roll the 24h window before charging against it.
        if (block.timestamp >= sale.windowStart + 1 days) {
            sale.windowStart = block.timestamp;
            sale.soldToday = 0;
        }
        // ponytail: charged at arm time, not at fill — the pot never learns whether a settlement
        // happened. An armed-then-unfilled clip therefore burns budget until the window rolls.
        // Track Permit2's nonce bitmap here if a keeper ever needs to retry within one window.
        uint256 sold = sale.soldToday + sellAmount;
        if (sold > sale.dailyCap) revert SaleCapExceeded();

        // The NET balance: `reserved` legs belong to redeemers mid-exit and `fees` are already
        // earned. Selling into either would be selling something the pot does not own.
        if (sellAmount > _contractAssetBalance(sellToken)) revert SaleExceedsBalance();

        // The floor comes from the pot's own feeds, never from the caller. This is what makes the
        // keeper a scheduler rather than a discretionary seller: it may choose when to sell, and
        // nothing about the price beyond refusing a worse one.
        if (minBuyAmount < saleFloor(sellToken, sellAmount)) revert PriceFloorTooLow();

        sale.soldToday = sold;
        digest = _intentDigest(sellToken, buyToken, sellAmount, minBuyAmount, nonce, deadline);
        armedIntent = digest;
        // Exactly `sellAmount`, so the allowance dies with the clip instead of standing open.
        sellToken.safeApprove(PERMIT2, sellAmount);

        emit SaleArmed(digest, sellToken, buyToken, sellAmount, minBuyAmount, deadline);
    }

    /// @inheritdoc IIndex
    function saleFloor(address sellToken, uint256 sellAmount) public view override returns (uint256) {
        Sale storage sale = sales[sellToken];
        if (sale.buyToken == address(0)) revert NoOpenSale();
        // Rounded up, so the boundary case is refused rather than shaved.
        return _amount(
            sale.buyToken,
            FixedPointMathLib.fullMulDiv(_value(sellToken, sellAmount), BIPS - sale.maxSlipBips, BIPS),
            true
        );
    }

    /// @inheritdoc IIndex
    function disarmSale(address sellToken) external override onlyOwner {
        emit SaleDisarmed(armedIntent);
        _clearIntent(sellToken);
    }

    /// @inheritdoc IIndex
    function isValidSignature(bytes32 hash, bytes calldata) external view override returns (bytes4) {
        // `armedIntent == 0` would otherwise vouch for the zero digest.
        if (armedIntent != 0 && hash == armedIntent) return ERC1271_MAGIC;
        return 0xffffffff;
    }

    /// @inheritdoc IIndex
    function setFeeRate(uint256 feeRate_) external override timelocked {
        if (feeRate_ > MAX_FEE_RATE) revert FeeTooHigh();
        feeRate = feeRate_;
        emit FeeRateSet(feeRate_);
    }

    /// @inheritdoc IIndex
    function withdrawFees(address[] calldata assets_, address to)
        external
        override
        onlyOwner
        nonReentrant
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](assets_.length);
        for (uint256 i; i < assets_.length; ++i) {
            address asset = assets_[i];
            // Only ever `fees[asset]`. The pot's own balance and claimants' `reserved` legs are
            // unreachable from here — there is no path in this contract that sweeps either.
            uint256 amount = fees[asset];
            if (amount == 0) revert NothingOwed();
            fees[asset] = 0;
            amounts[i] = amount;
            asset.safeTransfer(to, amount);
            emit FeesWithdrawn(asset, to, amount);
        }
    }

    /// @notice adds one stock to the index, after adding a stock
    /// @notice mint is possible only using the added stock until the ratio is restored
    function addStock(Stock calldata stock) external override timelocked {
        if (reallocating) revert ReallocationActive();
        if (stock.asset == address(0)) revert InvalidAsset();
        if (stock.priceFeed == address(0)) revert InvalidPriceFeed();
        if (stock.pool == address(0)) revert InvalidPool();
        if (stocks[stock.asset].asset != address(0)) revert DuplicateAsset();
        if (stock.allocationBips == 0 || stock.allocationBips >= BIPS) revert InvalidAllocation();

        if (totalSupply() == 0) revert EmptyPot();

        uint256 remaining = BIPS - stock.allocationBips;
        uint256 scaledTotal;

        for (uint256 i; i < _assets.length; ++i) {
            address asset = _assets[i];
            stocks[asset].allocationBips =
                uint16(FixedPointMathLib.fullMulDiv(stocks[asset].allocationBips, remaining, BIPS));
            scaledTotal += stocks[asset].allocationBips;
        }

        // When rounding we end up with small dust left. We add this dust to the first asset to make sure the total allocation is exactly BIPS
        if (scaledTotal + stock.allocationBips != BIPS) {
            stocks[_assets[0]].allocationBips += uint16(BIPS - scaledTotal - stock.allocationBips);
        }

        stocks[stock.asset] = stock;
        _assets.push(stock.asset);
        emit PriceFeedSet(stock.asset, stock.priceFeed, stock.pool);

        // Struck off the incumbents alone — the pot holds none of the new stock yet, so it adds
        // nothing to `_potValue()`. What is already there IS the whole pot, and the new stock has
        // to be `w` of the pot that INCLUDES it, so the dollars to add are `P x w / (1 - w)`, not
        // `P x w`: at w = 50% it must MATCH the incumbents ($200 AAPL + $100 NVDA -> $300 of MSFT),
        // not half them. A RAW QUANTITY (D19), fixed here and never recomputed, so splits and
        // ordinary mint/burn cannot move the goalposts.
        uint256 value = FixedPointMathLib.fullMulDiv(_potValue(), stock.allocationBips, BIPS - stock.allocationBips);
        targetAmount = _amount(stock.asset, value, false);
        if (targetAmount == 0) revert InvalidAllocation();

        pendingAsset = stock.asset;
        reallocating = true;
        emit StockAdded(stock.asset, stock.allocationBips, stock.priceFeed, targetAmount);
    }

    /// @notice calculates the deficit of the index in the asset being added
    function deficit() public view override returns (uint256) {
        if (!reallocating) return 0;
        uint256 held = _contractAssetBalance(pendingAsset);
        return held >= targetAmount ? 0 : targetAmount - held;
    }

    /// @notice calculates the maximum amount of INDEX that can be minted with the asset being added
    /// @dev Just the inverse of `_mintQuote`'s channel branch over `deficit()`: value the shortfall,
    ///      strip the haircut the depositor pays on top, divide by the pot value per INDEX. Rounds
    ///      down, so the channel is never overshot.
    function deficitToMint() public view override returns (uint256) {
        uint256 shortfall = deficit();
        if (shortfall == 0) return 0;
        uint256 value = FixedPointMathLib.fullMulDiv(_value(pendingAsset, shortfall), BIPS - HAIRCUT_BIPS, BIPS);
        return FixedPointMathLib.fullMulDiv(value, VALUE_SCALE, _perIndexValue(totalSupply()));
    }

    /// @notice returns the list of assets in the index
    function assets() external view override returns (address[] memory) {
        return _assets;
    }

    /// @notice returns the number of assets in the index
    function assetCount() external view override returns (uint256) {
        return _assets.length;
    }

    /// @notice calculates amount of underlying assets necessary to mint one index
    function calculateAmountOfAssetsToMintIndex(uint256 shares)
        public
        view
        override
        returns (uint256[] memory amounts)
    {
        (amounts,) = _mintQuote(shares);
    }

    /// @notice What redeeming `shares` returns, per stock. Rounds down — the pot never loses.
    function proceedsOfRedeem(uint256 shares) public view override returns (uint256[] memory amounts) {
        uint256 supply = totalSupply();
        amounts = new uint256[](_assets.length);
        if (supply == 0) return amounts;
        // No fee on the way out — `feeRate` is charged on mint only. Rounds down: the pot never loses.
        for (uint256 i; i < _assets.length; ++i) {
            amounts[i] = FixedPointMathLib.fullMulDiv(_contractAssetBalance(_assets[i]), shares, supply);
        }
    }

    ///////////////////////////////
    ///////// Internal ////////////
    ///////////////////////////////

    /// @notice What the POT holds of the asset: the raw balance minus the slivers that burns have
    ///         already booked to claimants. Every valuation reads this and never the raw balance —
    ///         a booked sliver belongs to its redeemer, not to the remaining holders, and counting
    ///         it twice would let the next `burn` pay itself out of someone's unclaimed leg.
    /// @dev Floored at zero: a token that claws back or rebases down must not brick every quote.
    function _contractAssetBalance(address asset) internal view returns (uint256) {
        return FixedPointMathLib.zeroFloorSub(asset.balanceOf(address(this)), reserved[asset] + fees[asset]);
    }

    /// @notice Mint cost per stock, split into the pro-rata base and the fee charged on top.
    /// @dev Two carve-outs, both fee-free: a deficit-channel mint (it pays the 1% D20 haircut
    ///      instead, and keeping it separate keeps `deficitToMint` a plain inverse of this) and the
    ///      genesis wrap (an empty pot has no holders, and taxing the founding deposit just
    ///      charges the founder for seeding the thing).
    function _mintQuote(uint256 shares) internal view returns (uint256[] memory amounts, uint256[] memory feeAmounts) {
        uint256 supply = totalSupply();
        amounts = new uint256[](_assets.length);
        feeAmounts = new uint256[](_assets.length);

        if (reallocating) {
            uint256 value = FixedPointMathLib.fullMulDivUp(
                FixedPointMathLib.fullMulDivUp(shares, _perIndexValue(supply), VALUE_SCALE), BIPS, BIPS - HAIRCUT_BIPS
            );
            amounts[_indexOf(pendingAsset)] = _amount(pendingAsset, value, true);
            return (amounts, feeAmounts);
        }

        uint256 rate = supply == 0 ? 0 : feeRate;
        for (uint256 i; i < _assets.length; ++i) {
            // Empty pot: genesis parity, one raw unit per share of every stock.
            uint256 base = supply == 0
                ? shares
                : FixedPointMathLib.fullMulDivUp(_contractAssetBalance(_assets[i]), shares, supply);
            amounts[i] = rate == 0 ? base : FixedPointMathLib.fullMulDivUp(base, FEE_SCALE + rate, FEE_SCALE);
            feeAmounts[i] = amounts[i] - base;
        }
    }

    /// @notice `transfer` that reports failure instead of reverting.
    /// @dev solady has `trySafeTransferFrom` but no `trySafeTransfer`; this mirrors its success
    ///      check — the call succeeded, and returned either nothing or a non-zero word.
    ///      ponytail: forwards all gas, so a token that burns 63/64 of it could starve the rest of
    ///      the loop. Stocks are governance-listed, not arbitrary; add a stipend if that changes.
    function _tryTransfer(address asset, address to, uint256 amount) internal returns (bool) {
        (bool success, bytes memory data) = asset.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        return success && (data.length == 0 || (data.length == 32 && abi.decode(data, (uint256)) != 0));
    }

    /// @notice Position of a stock in `_assets`. Reverts if it is not one.
    function _indexOf(address asset) internal view returns (uint256) {
        for (uint256 i; i < _assets.length; ++i) {
            if (_assets[i] == asset) return i;
        }
        revert InvalidAsset();
    }

    /// @notice Drop the armed digest and take back `sellToken`'s Permit2 allowance.
    /// @dev Clearing `armedIntent` is unconditionally safe, so this does not check that the digest
    ///      belonged to `sellToken` — the worst a mismatched call does is revoke an allowance that
    ///      was about to expire anyway.
    function _clearIntent(address sellToken) internal {
        armedIntent = 0;
        sellToken.safeApprove(PERMIT2, 0);
    }

    /// @notice Rebuild the Permit2 `PermitWitnessTransferFrom` digest for one Arcus intent.
    /// @dev `allowWrapped` is hashed as false and never taken as an argument. Arcus settles
    ///      illiquid names in a wrapped placeholder a maker redeems later, and the pot holds
    ///      canonical stock tokens only — an unlisted wrapper arriving here would be backing that
    ///      `_potValue` cannot see.
    function _intentDigest(
        address sellToken,
        address buyToken,
        uint256 sellAmount,
        uint256 minBuyAmount,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes32) {
        bytes32 witness = keccak256(
            abi.encode(
                TAKER_INTENT_TYPEHASH,
                address(this),
                sellToken,
                buyToken,
                sellAmount,
                minBuyAmount,
                false,
                nonce,
                deadline
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                PERMIT_WITNESS_TYPEHASH,
                keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, sellToken, sellAmount)),
                ARCUS_SETTLEMENT,
                nonce,
                deadline,
                witness
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", IPermit2(PERMIT2).DOMAIN_SEPARATOR(), structHash));
    }

    /// @notice The pot's whole value, in 1e18 USD. Every stock must have a live feed.
    function _potValue() internal view returns (uint256 total) {
        for (uint256 i; i < _assets.length; ++i) {
            total += _value(_assets[i], _contractAssetBalance(_assets[i]));
        }
    }

    /// @notice Pot value backing one INDEX (1e18 shares), in 1e18 USD.
    function _perIndexValue(uint256 supply) internal view returns (uint256 perIndex) {
        perIndex = FixedPointMathLib.fullMulDiv(_potValue(), VALUE_SCALE, supply);
        if (perIndex == 0) revert EmptyPot();
    }

    /// @notice gets price from the price feed
    /// @return price the price of the asset in 1e18 USD
    /// @return unit one unit of the asset with decimals
    function _price(address asset) internal view returns (uint256 price, uint256 unit) {
        address feed = stocks[asset].priceFeed;
        if (feed == address(0)) revert MissingPriceFeed();

        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(feed).latestRoundData();
        if (answer <= 0) revert InvalidPrice();

        price = uint256(answer);
        unit = 10 ** IAggregatorV3(feed).decimals();

        // One guard per path, never both.
        //
        // While the channel is open the pool IS the check. Age is the wrong question there: an
        // equity feed stops updating the moment its market closes, so a Sunday round is old by
        // construction and says nothing about whether the price is still right. A live market
        // that agrees with it does. This is the one path where a mint is priced off the oracle
        // rather than off the pot's own balances, and so the one path a wrong feed can dilute.
        //
        // Everywhere else — `addStock` striking `targetAmount`, `saleFloor` pricing a clip —
        // no pool is read at all, so age is the only guard left and it stays.
        //
        // ponytail: re-read per call, and a reallocation mint calls `_price` several times per
        // stock. Cache it in transient storage if the gas ever bites.
        if (reallocating) {
            _checkPoolDivergence(asset, price, unit);
        } else if (block.timestamp - updatedAt > MAX_FEED_AGE) {
            revert StalePrice();
        }
    }

    /// @notice Reverts unless the feed and the stock's own market agree within `maxDivergenceBips`.
    /// @dev The feed is the reference: divergence is measured as a fraction of the feed's price,
    ///      because the feed is what the mint would actually be charged at.
    function _checkPoolDivergence(address asset, uint256 price, uint256 unit) internal view {
        address pool = stocks[asset].pool;
        if (pool == address(0)) revert MissingPool();

        uint256 feedUsd = FixedPointMathLib.fullMulDiv(price, VALUE_SCALE, unit);
        uint256 poolUsd = _poolPrice(asset, pool);

        uint256 diff = feedUsd > poolUsd ? feedUsd - poolUsd : poolUsd - feedUsd;
        if (FixedPointMathLib.fullMulDiv(diff, BIPS, feedUsd) > maxDivergenceBips) revert PriceDiverged(asset);
    }

    /// @notice Spot price of one whole `asset` from its `asset`/stablecoin pool, in 1e18 USD.
    /// @dev `(sqrtPriceX96 / 2**96)**2` is raw token1 per raw token0; the decimal factors turn that
    ///      into whole-token USD, and the stablecoin leg is taken as exactly $1.
    ///      ponytail: `slot0` is spot, so it is movable inside a single block. Someone minting
    ///      against a feed that has drifted can shove the pool towards it in the same transaction
    ///      and the divergence check will not see it. This is a sanity check on an honest feed, not
    ///      a manipulation-resistant oracle. Swap in the v4 hook's TWAP accumulator (HANDBOOK §3.6)
    ///      when it lands — that is the upgrade this is a placeholder for.
    function _poolPrice(address asset, address pool) internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        if (sqrtPriceX96 == 0) revert InvalidPrice();

        address token0 = IUniswapV3Pool(pool).token0();
        address token1 = IUniswapV3Pool(pool).token1();
        bool assetIsToken0 = token0 == asset;
        // A pool that does not hold the stock prices something else entirely.
        if (!assetIsToken0 && token1 != asset) revert InvalidPool();

        uint256 assetUnit = 10 ** IERC20Metadata(asset).decimals();
        uint256 quoteUnit = 10 ** IERC20Metadata(assetIsToken0 ? token1 : token0).decimals();

        // The square only fits as a 512-bit intermediate: `sqrtPriceX96` reaches 2**160, so the
        // product reaches 2**320. Left shifted by 96, this is the raw ratio in Q96.
        uint256 ratioX96 = FixedPointMathLib.fullMulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 96);
        if (ratioX96 == 0) revert InvalidPrice();

        uint256 scaled = assetIsToken0
            // token1 (the stablecoin) per token0 (the stock) — already the right way round.
            ? FixedPointMathLib.fullMulDiv(ratioX96, VALUE_SCALE, 1 << 96)
            // token1 (the stock) per token0 (the stablecoin) — invert it.
            : FixedPointMathLib.fullMulDiv(VALUE_SCALE, 1 << 96, ratioX96);

        uint256 poolUsd = FixedPointMathLib.fullMulDiv(scaled, assetUnit, quoteUnit);
        if (poolUsd == 0) revert InvalidPrice();
        return poolUsd;
    }

    /// @notice Converts raw units of the asset to 1e18 USD
    function _value(address asset, uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;
        (uint256 price, uint256 unit) = _price(asset);
        uint256 usd = FixedPointMathLib.fullMulDiv(amount, price, unit);
        return FixedPointMathLib.fullMulDiv(usd, VALUE_SCALE, 10 ** IERC20Metadata(asset).decimals());
    }

    /// @notice inverse of the _vaule function. Converts a usd amount to the raw units of the asset
    /// @param asset the asset to convert to
    /// @param value the value in 1e18 USD
    /// @param roundUp whether to round up the result
    function _amount(address asset, uint256 value, bool roundUp) internal view returns (uint256) {
        if (value == 0) return 0;
        (uint256 price, uint256 unit) = _price(asset);
        uint256 decimals = 10 ** IERC20Metadata(asset).decimals();
        if (roundUp) {
            return
                FixedPointMathLib.fullMulDivUp(
                    FixedPointMathLib.fullMulDivUp(value, decimals, VALUE_SCALE), unit, price
                );
        }
        uint256 usd = FixedPointMathLib.fullMulDiv(value, decimals, VALUE_SCALE);
        return FixedPointMathLib.fullMulDiv(usd, unit, price);
    }
}
