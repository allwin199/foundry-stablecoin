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
    error DSCEngine__TransferFailed();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();

    ////////////////////
    // State Variables
    ///////////////////
    mapping(address token => address priceFeed) public s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;

    // Immutable Variables
    DecentralizedStableCoin private immutable i_dsc;

    //////////////
    // Events
    //////////////
    event collateralDeposited(address indexed user, address indexed token, uint256 indexed amount);

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
        }
        i_dsc = DecentralizedStableCoin(_dscAddress);
    }

    //////////////////////
    // External Functions
    //////////////////////

    // people can deposit collateral which is wETH or wBTC and mint our DSC token
    function depositCollateralAndMintDsc() external {}

    /**
     * @notice follows CEI(Checks, Effects, Interactions)
     * @param _tokenCollateralAddress The address of the token to deposit as collateral (eg: wETH or wBTC)
     * @param _amountCollateral The amount of collateral to deposit
     */
    function depositCollateral(address _tokenCollateralAddress, uint256 _amountCollateral)
        external
        moreThanZero(_amountCollateral)
        isAllowedToken(_tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][_tokenCollateralAddress] += _amountCollateral;
        emit collateralDeposited(msg.sender, _tokenCollateralAddress, _amountCollateral);
        bool success = IERC20(_tokenCollateralAddress).transferFrom(msg.sender, address(this), _amountCollateral);
        if (!success) revert DSCEngine__TransferFailed();
    }

    // people can redeem collateral(wETH or wBTC) by using DSC token
    function redeemCollateralForDsc() external {}

    function redeemCollateral() external {}

    function mintDsc() external {}

    // If people have more DSC compared to collateral, they can burn DSC
    function burnDsc() external {}

    function liquidate() external {}

    function getHealthFactor() external view {}
}
