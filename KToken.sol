// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IKToken.sol";

contract KToken is ERC20("Super KingKong Token", "SKK"), IKToken, Ownable {
    function mint(address _to, uint256 _amount) public override onlyOwner {
        _mint(_to, _amount);
    }
}
