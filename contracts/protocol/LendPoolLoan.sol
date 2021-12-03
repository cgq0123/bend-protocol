// SPDX-License-Identifier: agpl-3.0
pragma solidity ^0.8.0;

import {IBNFT} from "../interfaces/IBNFT.sol";
import {ILendPoolLoan} from "../interfaces/ILendPoolLoan.sol";
import {ILendPool} from "../interfaces/ILendPool.sol";
import {ILendPoolAddressesProvider} from "../interfaces/ILendPoolAddressesProvider.sol";
import {Errors} from "../libraries/helpers/Errors.sol";
import {DataTypes} from "../libraries/types/DataTypes.sol";
import {WadRayMath} from "../libraries/math/WadRayMath.sol";

import {IERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";
import {IERC721ReceiverUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721ReceiverUpgradeable.sol";
import {CountersUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/CountersUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";

contract LendPoolLoan is Initializable, ILendPoolLoan, ContextUpgradeable, IERC721ReceiverUpgradeable {
  using WadRayMath for uint256;
  using CountersUpgradeable for CountersUpgradeable.Counter;

  ILendPoolAddressesProvider private _addressesProvider;
  ILendPool private _pool;

  CountersUpgradeable.Counter private _loanIdTracker;
  mapping(uint256 => DataTypes.LoanData) private _loans;

  // nftAsset + nftTokenId => loanId
  mapping(address => mapping(uint256 => uint256)) private _nftToLoanIds;
  mapping(address => uint256) private _nftTotalCollateral;
  mapping(address => mapping(address => uint256)) private _userNftCollateral;

  /**
   * @dev Only lending pool can call functions marked by this modifier
   **/
  modifier onlyLendPool() {
    require(_msgSender() == address(_getLendPool()), Errors.CT_CALLER_MUST_BE_LEND_POOL);
    _;
  }

  modifier onlyAddressProvider() {
    require(address(_addressesProvider) == msg.sender, Errors.CALLER_NOT_ADDRESS_PROVIDER);
    _;
  }

  // called once by the factory at time of deployment
  function initialize(ILendPoolAddressesProvider provider) external initializer {
    __Context_init();

    _setAddressProvider(provider);

    // Avoid having loanId = 0
    _loanIdTracker.increment();

    emit Initialized(address(_pool));
  }

  function initializeAfterUpgrade(ILendPoolAddressesProvider provider) public onlyAddressProvider {
    _setAddressProvider(provider);

    emit Initialized(address(_pool));
  }

  function _setAddressProvider(ILendPoolAddressesProvider provider) internal {
    _addressesProvider = provider;
    _pool = ILendPool(_addressesProvider.getLendPool());
  }

  function initNft(address nftAsset, address bNftAddress) external override onlyLendPool {
    IERC721Upgradeable(nftAsset).setApprovalForAll(bNftAddress, true);
  }

  /**
   * @inheritdoc ILendPoolLoan
   */
  function createLoan(
    address user,
    address onBehalfOf,
    address nftAsset,
    uint256 nftTokenId,
    address bNftAddress,
    address reserveAsset,
    uint256 amount,
    uint256 borrowIndex
  ) external override onlyLendPool returns (uint256) {
    // index is expressed in Ray, so:
    // amount.wadToRay().rayDiv(index).rayToWad() => amount.rayDiv(index)
    uint256 amountScaled = amount.rayDiv(borrowIndex);

    uint256 loanId = _loanIdTracker.current();
    _loanIdTracker.increment();

    _nftToLoanIds[nftAsset][nftTokenId] = loanId;

    // transfer underlying NFT asset to pool and mint bNFT to onBehalfOf
    IERC721Upgradeable(nftAsset).safeTransferFrom(_msgSender(), address(this), nftTokenId);

    IBNFT(bNftAddress).mint(onBehalfOf, nftTokenId);

    // Save Info
    DataTypes.LoanData storage loanData = _loans[loanId];
    loanData.loanId = loanId;
    loanData.state = DataTypes.LoanState.Active;
    loanData.borrower = onBehalfOf;
    loanData.nftAsset = nftAsset;
    loanData.nftTokenId = nftTokenId;
    loanData.reserveAsset = reserveAsset;
    loanData.scaledAmount = amountScaled;

    _userNftCollateral[onBehalfOf][nftAsset] += 1;

    _nftTotalCollateral[nftAsset] += 1;

    emit LoanCreated(user, onBehalfOf, loanId, nftAsset, nftTokenId, reserveAsset, amount, borrowIndex);

    return (loanId);
  }

  /**
   * @inheritdoc ILendPoolLoan
   */
  function updateLoan(
    address user,
    uint256 loanId,
    uint256 amountAdded,
    uint256 amountTaken,
    uint256 borrowIndex
  ) external override onlyLendPool {
    // Must use storage to change state
    DataTypes.LoanData storage loan = _loans[loanId];
    // Ensure valid loan state
    require(loan.state == DataTypes.LoanState.Active, Errors.LPL_INVALID_LOAN_STATE);

    uint256 amountScaled = 0;

    if (amountAdded > 0) {
      amountScaled = amountAdded.rayDiv(borrowIndex);
      require(amountScaled != 0, Errors.LPL_INVALID_LOAN_AMOUNT);

      loan.scaledAmount += amountScaled;
    }

    if (amountTaken > 0) {
      amountScaled = amountTaken.rayDiv(borrowIndex);
      require(amountScaled != 0, Errors.LPL_INVALID_TAKEN_AMOUNT);

      require(loan.scaledAmount >= amountScaled, Errors.LPL_AMOUNT_OVERFLOW);
      loan.scaledAmount -= amountScaled;
    }

    emit LoanUpdated(
      user,
      loanId,
      loan.nftAsset,
      loan.nftTokenId,
      loan.reserveAsset,
      amountAdded,
      amountTaken,
      borrowIndex
    );
  }

  /**
   * @inheritdoc ILendPoolLoan
   */
  function repayLoan(
    address user,
    uint256 loanId,
    address bNftAddress,
    uint256 borrowIndex
  ) external override onlyLendPool {
    // Must use storage to change state
    DataTypes.LoanData storage loan = _loans[loanId];

    // Ensure valid loan state
    require(loan.state == DataTypes.LoanState.Active, Errors.LPL_INVALID_LOAN_STATE);

    // state changes and cleanup
    // NOTE: these must be performed before assets are released to prevent reentrance
    _loans[loanId].state = DataTypes.LoanState.Repaid;

    _nftToLoanIds[loan.nftAsset][loan.nftTokenId] = 0;

    require(_userNftCollateral[loan.borrower][loan.nftAsset] >= 1, Errors.LP_INVALIED_USER_NFT_AMOUNT);
    _userNftCollateral[loan.borrower][loan.nftAsset] -= 1;

    require(_nftTotalCollateral[loan.nftAsset] >= 1, Errors.LP_INVALIED_NFT_AMOUNT);
    _nftTotalCollateral[loan.nftAsset] -= 1;

    // burn bNFT and transfer underlying NFT asset to user
    IBNFT(bNftAddress).burn(loan.nftTokenId);

    IERC721Upgradeable(loan.nftAsset).safeTransferFrom(address(this), user, loan.nftTokenId);

    emit LoanRepaid(user, loanId, loan.nftAsset, loan.nftTokenId, loan.reserveAsset, loan.scaledAmount, borrowIndex);
  }

  /**
   * @inheritdoc ILendPoolLoan
   */
  function auctionLoan(
    address user,
    uint256 loanId,
    uint256 price
  ) external override onlyLendPool {
    // Must use storage to change state
    DataTypes.LoanData storage loan = _loans[loanId];
    address previousLiquidator = loan.bidLiquidator;
    uint256 previousPrice = loan.bidPrice;

    // Ensure valid loan state
    if (loan.bidStartTimestamp == 0) {
      require(loan.state == DataTypes.LoanState.Active, Errors.LPL_INVALID_LOAN_STATE);

      loan.state = DataTypes.LoanState.Auction;
      loan.bidStartTimestamp = block.timestamp;
    } else {
      require(loan.state == DataTypes.LoanState.Auction, Errors.LPL_INVALID_LOAN_STATE);
      require(price > loan.bidPrice, Errors.LPL_BID_PRICE_TOO_LOW);
    }

    loan.bidLiquidator = user;
    loan.bidPrice = price;

    emit LoanAuctioned(user, loanId, loan.nftAsset, loan.nftTokenId, price, previousLiquidator, previousPrice);
  }

  /**
   * @inheritdoc ILendPoolLoan
   */
  function undoAuctionLoan(address user, uint256 loanId) external override onlyLendPool {
    // Must use storage to change state
    DataTypes.LoanData storage loan = _loans[loanId];
    address previousLiquidator = loan.bidLiquidator;
    uint256 previousPrice = loan.bidPrice;

    require(loan.state == DataTypes.LoanState.Auction, Errors.LPL_INVALID_LOAN_STATE);

    loan.state = DataTypes.LoanState.Active;
    loan.bidStartTimestamp = 0;
    loan.bidLiquidator = address(0);
    loan.bidPrice = 0;

    emit LoanUndoAuctioned(user, loanId, loan.nftAsset, loan.nftTokenId, previousLiquidator, previousPrice);
  }

  /**
   * @inheritdoc ILendPoolLoan
   */
  function liquidateLoan(
    address user,
    uint256 loanId,
    address bNftAddress,
    uint256 borrowIndex
  ) external override onlyLendPool {
    // Must use storage to change state
    DataTypes.LoanData storage loan = _loans[loanId];
    // Ensure valid loan state
    require(loan.state == DataTypes.LoanState.Auction, Errors.LPL_INVALID_LOAN_STATE);

    // state changes and cleanup
    // NOTE: these must be performed before assets are released to prevent reentrance
    _loans[loanId].state = DataTypes.LoanState.Defaulted;

    _nftToLoanIds[loan.nftAsset][loan.nftTokenId] = 0;

    require(_userNftCollateral[loan.borrower][loan.nftAsset] >= 1, Errors.LP_INVALIED_USER_NFT_AMOUNT);
    _userNftCollateral[loan.borrower][loan.nftAsset] -= 1;

    require(_nftTotalCollateral[loan.nftAsset] >= 1, Errors.LP_INVALIED_NFT_AMOUNT);
    _nftTotalCollateral[loan.nftAsset] -= 1;

    // burn bNFT and transfer underlying NFT asset to user
    IBNFT(bNftAddress).burn(loan.nftTokenId);

    IERC721Upgradeable(loan.nftAsset).safeTransferFrom(address(this), user, loan.nftTokenId);

    emit LoanLiquidated(
      user,
      loanId,
      loan.nftAsset,
      loan.nftTokenId,
      loan.reserveAsset,
      loan.scaledAmount,
      borrowIndex
    );
  }

  function onERC721Received(
    address operator,
    address from,
    uint256 tokenId,
    bytes calldata data
  ) external pure override returns (bytes4) {
    operator;
    from;
    tokenId;
    data;
    return IERC721ReceiverUpgradeable.onERC721Received.selector;
  }

  function borrowerOf(uint256 loanId) external view override returns (address) {
    return _loans[loanId].borrower;
  }

  function getCollateralLoanId(address nftAsset, uint256 nftTokenId) external view override returns (uint256) {
    return _nftToLoanIds[nftAsset][nftTokenId];
  }

  function getLoan(uint256 loanId) external view override returns (DataTypes.LoanData memory loanData) {
    return _loans[loanId];
  }

  function getLoanCollateralAndReserve(uint256 loanId)
    external
    view
    override
    returns (
      address nftAsset,
      uint256 nftTokenId,
      address reserveAsset,
      uint256 scaledAmount
    )
  {
    return (
      _loans[loanId].nftAsset,
      _loans[loanId].nftTokenId,
      _loans[loanId].reserveAsset,
      _loans[loanId].scaledAmount
    );
  }

  function getLoanReserveBorrowAmount(uint256 loanId) external view override returns (uint256) {
    uint256 scaledAmount = _loans[loanId].scaledAmount;
    if (scaledAmount == 0) {
      return 0;
    }

    return scaledAmount.rayMul(_pool.getReserveNormalizedVariableDebt(_loans[loanId].reserveAsset));
  }

  function getLoanReserveBorrowScaledAmount(uint256 loanId) external view override returns (uint256) {
    return _loans[loanId].scaledAmount;
  }

  function getNftCollateralAmount(address nftAsset) external view override returns (uint256) {
    return _nftTotalCollateral[nftAsset];
  }

  function getUserNftCollateralAmount(address user, address nftAsset) external view override returns (uint256) {
    return _userNftCollateral[user][nftAsset];
  }

  function _getLendPool() internal view returns (ILendPool) {
    return _pool;
  }
}
