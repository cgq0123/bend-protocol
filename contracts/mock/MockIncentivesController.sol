// SPDX-License-Identifier: agpl-3.0
pragma solidity ^0.8.0;

import {IIncentivesController} from "../interfaces/IIncentivesController.sol";

contract MockIncentivesController is IIncentivesController {
  bool private _handleActionIsCalled;
  address private _asset;
  uint256 private _totalSupply;
  uint256 private _userBalance;

  /*
   * @dev Returns the configuration of the distribution for a certain asset
   * @param asset The address of the reference asset of the distribution
   * @return The asset index, the emission per second and the last updated timestamp
   **/
  function getAssetData(address asset)
    external
    view
    override
    returns (
      uint256,
      uint256,
      uint256
    )
  {
    asset;
    _asset;
    return (0, 0, 0);
  }

  /**
   * @dev returns the unclaimed rewards of the user
   * @param user the address of the user
   * @param asset The asset to incentivize
   * @return the user index for the asset
   */
  function getUserAssetData(address user, address asset) external view override returns (uint256) {
    user;
    asset;
    _asset;
    return 0;
  }

  /**
   * @dev returns the unclaimed rewards of the user
   * @param user the address of the user
   * @return the unclaimed user rewards
   */
  function getUserUnclaimedRewards(address user) external view override returns (uint256) {
    user;
    _asset;
    return 0;
  }

  /**
   * @dev Called by the corresponding asset on any update that affects the rewards distribution
   * @param asset The address of the user
   * @param totalSupply The total supply of the asset in the lending pool
   * @param userBalance The balance of the user of the asset in the lending pool
   **/
  function handleAction(
    address asset,
    uint256 totalSupply,
    uint256 userBalance
  ) external override {
    _handleActionIsCalled = true;
    _asset = asset;
    _totalSupply = totalSupply;
    _userBalance = userBalance;
  }

  function checkHandleActionIsCorrect(
    address asset,
    uint256 totalSupply,
    uint256 userBalance
  ) public view returns (bool) {
    return _handleActionIsCalled && asset == _asset && totalSupply == _totalSupply && userBalance == _userBalance;
  }

  function checkHandleActionIsCalled() public view returns (bool) {
    return _handleActionIsCalled;
  }

  function resetHandleActionIsCalled() public {
    _handleActionIsCalled = false;
    _asset = address(0);
    _totalSupply = 0;
    _userBalance = 0;
  }

  /**
   * @dev Gets the distribution end timestamp of the emissions
   */
  function DISTRIBUTION_END() external view override returns (uint256) {
    _asset;
    return 0;
  }
}