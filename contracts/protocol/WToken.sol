// SPDX-License-Identifier: agpl-3.0
pragma solidity ^0.8.0;

import "../interfaces/IWToken.sol";
import "../interfaces/IIncentivesController.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

abstract contract WToken is IWToken, ERC20 {}