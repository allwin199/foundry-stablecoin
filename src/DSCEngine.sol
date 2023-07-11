// SPDX-License-Identifier: MIT

// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title DscEngine
 * @author Prince Allwin
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg.
 * This stable coin has the properties
 * - Exogenous Collateral
 * - Dollar Pegged
 * - Algorathmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was only backed by wETH wBTC.
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of all collateral <= the $ backed value of all the DSC.
 *
 * @notice This contract is the core of the DSC system. It handles all the logic for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is very loosely based on the MakerDAO DSS (DAI) system.
 * @notice DSC --> Decentralized Stable Coin.
 */
contract DSCEngine is ReentrancyGuard {
    //////////////
    // Errors
    //////////////
    error DSCEngine__MintFailed();
    error DSCEngine__TransferFailed();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();

    ////////////////////
    // State Variables
    ///////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1;

    mapping(address token => address priceFeed) public s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_dscMinted;
    address[] private s_collateralTokens;

    // Immutable Variables
    DecentralizedStableCoin private immutable i_dsc;

    //////////////
    // Events
    //////////////
    event collateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed user, address indexed token, uint256 indexed amount);

    //////////////
    // Modifiers
    //////////////
    modifier moreThanZero(uint256 _amount) {
        if (_amount <= 0) revert DSCEngine__NeedsMoreThanZero();
        _;
    }

    modifier isAllowedToken(address _token) {
        if (s_priceFeeds[_token] == address(0)) {
            revert DSCEngine__TokenNotAllowed();
        }
        _;
    }

    //////////////
    // Functions
    //////////////

    constructor(address[] memory _tokenAddresses, address[] memory _priceFeedAddresses, address _dscAddress) {
        if (_tokenAddresses.length != _priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        // we need priceFeeds of ETH / USD and BTC / USD
        for (uint256 i = 0; i < _tokenAddresses.length; i++) {
            s_priceFeeds[_tokenAddresses[i]] = _priceFeedAddresses[i];
            s_collateralTokens.push(_tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(_dscAddress);
    }

    //////////////////////
    // External Functions
    //////////////////////

    /**
     * @param _tokenCollateralAddress The address of the token to deposit as collateral
     * @param _amountCollateral The amount of collateral to deposit
     * @param _amountDscToMint The amount of decentralized stablecoin to mint
     * @notice this function will deposit your collateral and mint DSC in one transaction
     */
    function depositCollateralAndMintDsc(
        address _tokenCollateralAddress,
        uint256 _amountCollateral,
        uint256 _amountDscToMint
    ) external {
        depositCollateral(_tokenCollateralAddress, _amountCollateral);
        mintDsc(_amountDscToMint);
    }

    /**
     * @notice follows CEI(Checks, Effects, Interactions)
     * @param _tokenCollateralAddress The address of the token to deposit as collateral (eg: wETH or wBTC)
     * @param _amountCollateral The amount of collateral to deposit
     */
    function depositCollateral(address _tokenCollateralAddress, uint256 _amountCollateral)
        public
        moreThanZero(_amountCollateral)
        isAllowedToken(_tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][_tokenCollateralAddress] += _amountCollateral;
        emit collateralDeposited(msg.sender, _tokenCollateralAddress, _amountCollateral);
        bool success = IERC20(_tokenCollateralAddress).transferFrom(msg.sender, address(this), _amountCollateral);
        if (!success) revert DSCEngine__TransferFailed();
    }

    /**
     *
     * @param _tokenCollateralAddress The collateral address to redeem
     * @param _amountCollateral The amount of collateral to redeem
     * @param _amountDscToBurn The amount of DSC to burn
     * This function burns DSC and redeems underlying collateral in one transaction
     */
    // people can redeem collateral(wETH or wBTC) by using DSC token
    function redeemCollateralForDsc(
        address _tokenCollateralAddress,
        uint256 _amountCollateral,
        uint256 _amountDscToBurn
    ) external {
        burnDsc(_amountDscToBurn);
        redeemCollateral(_tokenCollateralAddress, _amountCollateral);
        // redeemCollateral already check health factor
    }

    // In order to redeem collateral:
    // 1. Health factor must be over 1 AFTER collateral pulled out
    // CEI: Checks, Effects, Interactions
    function redeemCollateral(address _tokenCollateralAddress, uint256 _amountCollateral)
        public
        moreThanZero(_amountCollateral)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][_tokenCollateralAddress] -= _amountCollateral;
        emit CollateralRedeemed(msg.sender, _tokenCollateralAddress, _amountCollateral);

        (bool success) = IERC20(_tokenCollateralAddress).transfer(msg.sender, _amountCollateral);
        if (!success) revert DSCEngine__TransferFailed();
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // After the user deposited the collateral, we can mint the DSC
    // Before minting we have to do some checks
    // 1. Check if the collateral value > DSC amount
    /**
     * follows CEI
     * @param _amountDscToMint The amount of Decentralized Stable Coin(DSC) to Mint
     * @notice they must have more collateral value than the minimum threshold
     */
    function mintDsc(uint256 _amountDscToMint) public moreThanZero(_amountDscToMint) nonReentrant {
        s_dscMinted[msg.sender] += _amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, _amountDscToMint);
        if (!minted) revert DSCEngine__MintFailed();
    }

    // If people have more DSC compared to collateral, they can burn DSC
    function burnDsc(uint256 _amount) public moreThanZero(_amount) {
        s_dscMinted[msg.sender] -= _amount;
        bool success = i_dsc.transferFrom(msg.sender, address(this), _amount);
        if (!success) revert DSCEngine__TransferFailed();
        i_dsc.burn(_amount);
        _revertIfHealthFactorIsBroken(msg.sender); // I don't think this would ever hit
    }

    function liquidate() external {}

    function getHealthFactor() external view {}

    ///////////////////////////////////
    // Private and Internal View Functions
    ///////////////////////////////////

    function _getAccountInformation(address _user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_dscMinted[_user];
        collateralValueInUsd = getAccountCollateralValue(_user);
    }

    /**
     * Returns how close to liquidation a user is
     * If a user goes below 1, then they can get liquidated
     */
    function _healthFactor(address _user) private view returns (uint256) {
        // To determine the Health Factor
        // 1. total DSC s_dscMinted
        // 2. total collateral VALUE
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(_user);
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    // 1. Check health factor (do they have enough collateral?)
    // 2. Revert If they don't have a good health factor
    function _revertIfHealthFactorIsBroken(address _user) internal view {
        uint256 userHealthFactor = _healthFactor(_user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) revert DSCEngine__BreaksHealthFactor(userHealthFactor);
    }

    /////////////////////////////////////
    // Public & External View Functions
    /////////////////////////////////////

    function getAccountCollateralValue(address _user) public view returns (uint256 totalCollateralInUsd) {
        // loop through each collateral token, get the amount they have deposited, and map it to
        // the price, to get the USD value
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[_user][token];
            totalCollateralInUsd = getUsdValue(token, amount);
        }
        return totalCollateralInUsd;
    }

    function getUsdValue(address _token, uint256 _amount) public view returns (uint256) {
        // using AggregatorV3Interface let's get the price of deposited token value in USD
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[_token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // If 1 ETH is  $1000
        // we know chainlink returns a decimal of 8
        // so it will be 1000e8
        // amount give by the user will be in terms of wei
        // we know wei has 18 decimals
        // we have to convert price to 18 decimals
        // ADDITIONAL_FEED_PRECISION is 1e10
        // uint256(price) * ADDITIONAL_FEED_PRECISION will give value of 1ETH in USD
        // multiply with the total amount of ETH
        // since price is e18 and _amount is e18, while multiplying we got e36, so we have to divide by e18
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * _amount) / PRECISION;
    }
}
